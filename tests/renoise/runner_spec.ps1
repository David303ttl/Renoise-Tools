#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/runner.psm1" -Force
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected rejection: $Pattern"
}
# A separate runspace supplies real fragmented TCP responses without Renoise.
foreach ($mode in @('valid','wrong','invalid','string-ok','numeric-ok','missing-ok','missing-result','false-missing-error','lost','timeout','shutdown','shutdown-missing')) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $client = Connect-RenoiseDriver -Session ([pscustomobject]@{Port=$listener.LocalEndpoint.Port}) -TimeoutSeconds 2 -ProcessCheck {}
    Assert ($client -is [Net.Sockets.TcpClient]) 'connector returned unexpected pipeline output'
    $peer = $listener.AcceptTcpClient()
    $worker = [PowerShell]::Create()
    $sessionPath = Join-Path ([IO.Path]::GetTempPath()) ('runner-stop-' + [guid]::NewGuid().ToString('N'))
    $session = [pscustomobject]@{Token='test';Nonce='test-run-nonce'}
    [void]$worker.AddScript({ param($Peer,$Mode,$SessionPath,$Nonce)
        $stream = $Peer.GetStream()
        $reader = [IO.StreamReader]::new($stream)
        $request = $reader.ReadLine() | ConvertFrom-Json
        if ($Mode -eq 'lost') { $Peer.Dispose(); return }
        if ($Mode -eq 'timeout') { Start-Sleep -Seconds 2; return }
        $id = if ($Mode -eq 'wrong') { 'wrong' } else { $request.id }
        $result = if ($Mode -like 'shutdown*') { @{shutdown_requested=$true} } else { @{value=42} }
        $ok = if ($Mode -eq 'string-ok') { 'true' } elseif ($Mode -eq 'numeric-ok') { 1 } elseif ($Mode -eq 'false-missing-error') { $false } else { $true }
        $envelope = @{id=$id;ok=$ok;result=$result}
        if ($Mode -eq 'missing-ok') { $envelope.Remove('ok') }
        if ($Mode -eq 'missing-result') { $envelope.Remove('result') }
        $line = if ($Mode -eq 'invalid') { "bad-json`n" } else { ($envelope | ConvertTo-Json -Compress) + "`n" }
        foreach ($byte in [Text.Encoding]::UTF8.GetBytes($line)) { $stream.WriteByte($byte); $stream.Flush(); Start-Sleep -Milliseconds 2 }
        if ($Mode -eq 'shutdown') { [IO.File]::WriteAllText($SessionPath + '.' + $Nonce + '.stopped', $Nonce) }
    }).AddArgument($peer).AddArgument($mode).AddArgument($sessionPath).AddArgument($session.Nonce)
    $pending = $worker.BeginInvoke()
    try {
        $action = { Invoke-RenoiseDriverRequest -Client $client -Session ([pscustomobject]@{Token='test'}) -Operation ping -Arguments @{} -TimeoutSeconds $(if ($mode -eq 'timeout') { 1 } else { 5 }) -ProcessCheck {} }
        if ($mode -eq 'shutdown') {
            Assert (Stop-RenoiseDriver -Client $client -Session $session -SessionPath $sessionPath -TimeoutSeconds 5 -ProcessCheck {}) 'shutdown completion not verified'
            Assert (-not (Test-Path ($sessionPath + '.' + $session.Nonce + '.stopped'))) 'shutdown marker not cleaned'
        }
        elseif ($mode -eq 'shutdown-missing') {
            Reject { Stop-RenoiseDriver -Client $client -Session $session -SessionPath $sessionPath -TimeoutSeconds 5 -ProcessCheck {} } 'finish shutdown'
        }
        elseif ($mode -eq 'valid') { Assert ((& $action).value -eq 42) 'fragmented response failed' }
        else { Reject $action (@{wrong='unexpected request ID';invalid='JSON';'string-ok'='invalid response envelope';'numeric-ok'='invalid response envelope';'missing-ok'='invalid response envelope';'missing-result'='invalid response envelope';'false-missing-error'='invalid response envelope';lost='closed the transport';timeout='Timed out'}[$mode]) }
        $identity = [pscustomobject]@{Id=123;StartTimeUtc=[datetime]::UtcNow}
        Assert-RenoiseListenerOwner -Client $client -Identity $identity -CheckIdentity {} -GetListeners { param($Port) [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=123} }
        Reject { Assert-RenoiseListenerOwner -Client $client -Identity $identity -CheckIdentity {} -GetListeners { [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=456} } } 'ownership'
    } finally { $client.Dispose(); $listener.Stop(); $worker.EndInvoke($pending); $worker.Dispose(); $peer.Dispose() }
}
$closedListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$closedListener.Start()
$closedPort = $closedListener.LocalEndpoint.Port
$closedListener.Stop()
$checkCounter = [pscustomobject]@{ Count = 0 }
Reject { Connect-RenoiseDriver -Session ([pscustomobject]@{Port=$closedPort}) -TimeoutSeconds 1 -ProcessCheck { $checkCounter.Count++ } } 'Timed out.*loopback listener'
Assert ($checkCounter.Count -gt 0) 'startup retry did not revalidate the selected Renoise process'
$guardListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$guardListener.Start()
$guardClient = Connect-RenoiseDriver -Session ([pscustomobject]@{Port=$guardListener.LocalEndpoint.Port}) -TimeoutSeconds 2 -ProcessCheck {}
$guardPeer = $guardListener.AcceptTcpClient()
try {
    Reject { Invoke-RenoiseDriverRequest -Client $guardClient -Session ([pscustomobject]@{Token='test'}) -Operation ping -Arguments @{} -TimeoutSeconds 2 -ProcessCheck { throw 'identity changed' } } 'identity changed'
    Assert (-not $guardPeer.GetStream().DataAvailable) 'request bytes were sent after process identity validation failed'
} finally { $guardClient.Dispose(); $guardPeer.Dispose(); $guardListener.Stop() }
$root = Join-Path ([IO.Path]::GetTempPath()) ('runner-spec-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
function Add-Trace { param($Operation,$Status,$Details) }
function Set-UserOnlyFileAcl { param($Path) }
try {
 foreach ($case in @('unchanged','changed','partial','failed-launch','bad-backup')) {
    $toolsPath = Join-Path $root $case
    $artifactRoot = Join-Path $toolsPath 'artifacts'
    New-Item -ItemType Directory $artifactRoot -Force | Out-Null
    $artifactId = [guid]::NewGuid().ToString('N')
    $devToolName='tool'; $sessionName='session.conf'
    $devToolPath=Join-Path $toolsPath 'source'; New-Item -ItemType Directory $devToolPath | Out-Null
    Set-Content (Join-Path $devToolPath 'main.lua') 'development'
    $sessionSourcePath=Join-Path $toolsPath 'source.conf'; Set-Content $sessionSourcePath 'token'
    $installedToolPath=Join-Path $toolsPath $devToolName; New-Item -ItemType Directory $installedToolPath | Out-Null
    Set-Content (Join-Path $installedToolPath 'main.lua') 'developer edits'
    $originalHash=Get-DirectoryHash $installedToolPath
    $sessionTargetPath=Join-Path $toolsPath $sessionName; Set-Content $sessionTargetPath 'original'
    $localBackupToolPath=$localBackupSessionPath=$null
    $toolDeployed=$sessionDeployed=$false
    if ($case -eq 'bad-backup') {
        function Copy-Item {
            param($LiteralPath,$Destination,[switch]$Recurse)
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse:$Recurse
            if ($Destination -eq (Join-Path $artifactRoot 'previous-ACID.xrnx')) { Set-Content (Join-Path $Destination 'main.lua') 'corrupted' }
        }
        try { . ([scriptblock]::Create((Get-RenoiseDeploymentOperation))); throw 'expected backup rejection' }
        catch { if ($_.Exception.Message -notmatch 'backup copy did not verify') { throw } }
        finally { Remove-Item Function:Copy-Item }
        Assert ((Get-DirectoryHash $installedToolPath) -eq $originalHash) 'bad backup changed original installation'
        continue
    }
    if ($case -eq 'partial') {
        function Move-Item { param($LiteralPath,$Destination) if ($Destination -eq $sessionTargetPath) { throw 'injected deployment failure' }; Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination }
        try { . ([scriptblock]::Create((Get-RenoiseDeploymentOperation))); throw 'expected failure' } catch { if ($_.Exception.Message -notmatch 'injected') { throw } }
        Remove-Item Function:Move-Item
    } else { . ([scriptblock]::Create((Get-RenoiseDeploymentOperation))) }
    if ($case -eq 'failed-launch') {
        try { throw 'injected launch failure' }
        catch { . ([scriptblock]::Create((Get-RenoiseRestorationOperation))) }
        Assert ((Get-DirectoryHash $installedToolPath) -eq $originalHash) 'failed launch lost original'
        continue
    }
    Assert ((Get-DirectoryHash $backupToolPath) -eq $originalHash) 'backup not verified'
    if ($case -eq 'changed') {
        Set-Content (Join-Path $installedToolPath 'main.lua') 'changed during run'
        Reject { . ([scriptblock]::Create((Get-RenoiseRestorationOperation))) } 'changed during'
        Assert (Test-Path $localBackupToolPath) 'changed installation lost backup'
    } else {
        . ([scriptblock]::Create((Get-RenoiseRestorationOperation)))
        Assert ((Get-DirectoryHash $installedToolPath) -eq $originalHash) "restoration failed: $case"
        Assert ((Get-Content $sessionTargetPath) -eq 'original') 'sidecar restoration failed'
    }
 }
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
# Exercise the real script's early refusal and report path without starting Renoise.
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$invocation = & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/run_interactive_tests.ps1') -Suite Keyboard 2>&1
Assert ($LASTEXITCODE -ne 0) 'required keyboard skip returned success'
$reportLine = @($invocation | ForEach-Object { [string]$_ } | Where-Object { $_ -like 'Run report: *' })
Assert ($reportLine.Count -eq 1) 'runner failed to emit a report'
$runReport = Get-Content -LiteralPath $reportLine[0].Substring(12) -Raw | ConvertFrom-Json
Assert ($runReport.status -eq 'FAIL' -and $runReport.scenarios[0].status -eq 'SKIP') 'required skip missing from report'
Write-Output 'PASS runner transport, ownership and installation lifecycle'
