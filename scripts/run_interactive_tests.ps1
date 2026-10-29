#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('ACID')][string]$Tool = 'ACID',
    [ValidateSet('Native','Keyboard','All')][string]$Suite = 'Native',
    [string]$Scenario,
    [string]$RenoiseExe,
    [int]$RenoiseProcessId = 0,
    [string]$TestEnvironment,
    [ValidateRange(5,600)][int]$StartupTimeoutSeconds = 90,
    [ValidateRange(1,300)][int]$CommandTimeoutSeconds = 30,
    [switch]$ApproveDisposableSong,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactId = [guid]::NewGuid().ToString('N')
$repoTemp = Join-Path $repoRoot 'tmp'
$null = New-Item -ItemType Directory -Path $repoTemp -Force
$artifactRoot = Join-Path $repoTemp ('interactive-' + $artifactId)
$devOutputName = 'tmp/acid-dev-' + $artifactId
$devOutput = Join-Path $repoRoot $devOutputName.Replace('/', [IO.Path]::DirectorySeparatorChar)
$devToolName = 'com.david303ttl.ACID.xrnx'
$sessionName = 'acid-test-session.conf'
$startedProcess = $null
$startedIdentity = $null
$selectedIdentity = $null
$installedToolPath = $null
$backupToolPath = $null
$localBackupToolPath = $null
$sessionTargetPath = $null
$sessionBackupPath = $null
$localBackupSessionPath = $null
$deploymentStageRoot = $null
$deploymentStageToolPath = $null
$deploymentStageSessionPath = $null
$deploymentStageToolHash = $null
$deploymentStageSessionHash = $null
$installedDirectoryHash = $null
$installedSessionHash = $null
$deploymentStarted = $false
$safeToRestore = $false
$driverMayBeLoaded = $false
$startedProcessForceStopped = $false
$toolDeployed = $false
$sessionDeployed = $false
$exeVersionTriplet = $null
$session = $null
$keyboardOnlySkipped = $false
$lastExpected = 'Runner preflight completes without changing developer-owned Renoise state'
$lastActual = $null
$lastDiff = $null
$inventoryDiff = $null
$report = [ordered]@{
    schema_version = 1
    run_id = $artifactId
    tool = $Tool
    suite = $Suite
    scenario = if ($Scenario) { $Scenario } else { 'transport' }
    status = 'ERROR'
    source_commit = $null
    host = $null
    tool_version = $null
    document_epoch = $null
    elapsed_ms = 0
    operation_trace = @()
    scenarios = @()
    error = $null
}
$clock = [Diagnostics.Stopwatch]::StartNew()

function Add-Trace {
    param([string]$Operation, [string]$Status, [object]$Details = $null)
    $script:report.operation_trace += [pscustomobject]@{
        operation = $Operation
        status = $Status
        elapsed_ms = $script:clock.ElapsedMilliseconds
        details = $Details
    }
}

function Set-UserOnlyFileAcl {
    param([Parameter(Mandatory)][string]$Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.User) { throw 'Could not identify the current Windows user for the session-file ACL.' }
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity.User,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-DirectoryHash {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $records = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object { $_.FullName.Substring($root.Length) } | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName.Substring($root.Length).TrimStart('\','/').Replace('\','/'); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records | ConvertTo-Json -Compress)))).ToLowerInvariant()
}

function Get-VersionTriplet {
    param([Parameter(Mandatory)][string]$Value)
    $match = [regex]::Match($Value, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
    if (-not $match.Success) { throw "Could not resolve Renoise version from '$Value'." }
    return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Assert-RunnerProcess {
    if ($null -ne $script:startedIdentity) { Assert-RenoiseProcessIdentity -Identity $script:startedIdentity }
    elseif ($null -ne $script:selectedIdentity) { Assert-RenoiseProcessIdentity -Identity $script:selectedIdentity }
}

function Get-Preflight {
    param([int]$SelectedId)
    $configuration = [pscustomobject]@{
        RenoiseExe = $script:resolvedExe
        RenoiseProcessId = $SelectedId
        TemporaryDirectory = [IO.Path]::GetTempPath()
    }
    $result = Test-RenoiseHostPreflight -Configuration $configuration -Mode Safety
    if (-not $result.Passed) { throw "Renoise host preflight failed: $($result.Errors -join '; ')" }
    return $result
}

function Test-DriverListenerClosed {
    param([Parameter(Mandatory)][int]$Port)
    $probe = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try {
        $connect = $probe.ConnectAsync([Net.IPAddress]::Loopback, $Port)
        if (-not $connect.Wait(1000)) { return 'Unknown' }
        $connect.GetAwaiter().GetResult()
        return 'Open'
    }
    catch {
        $socketError = $_.Exception
        while ($socketError -and $socketError -isnot [Net.Sockets.SocketException]) { $socketError = $socketError.InnerException }
        if ($socketError -is [Net.Sockets.SocketException] -and $socketError.SocketErrorCode -eq [Net.Sockets.SocketError]::ConnectionRefused) { return 'Closed' }
        return 'Unknown'
    }
    finally { $probe.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $artifactRoot -ErrorAction Stop | Out-Null
    if ($Suite -eq 'Keyboard') {
        $keyboardOnlySkipped = $true
        $report.status = 'FAIL'
        $report.error = 'The required Keyboard suite is not implemented yet.'
        $report.scenarios = @([pscustomobject]@{
            name = if ($Scenario) { $Scenario } else { 'keyboard' }
            suite = 'Keyboard'
            status = 'SKIP'
            reason = 'Keyboard input adapter and journeys are implemented in T0.6.'
            expected = 'Verified shortcut, dialog focus, and native selection journey'
            actual = $null
            diff = @{ required_suite_skipped = $true }
        })
        Add-Trace -Operation 'suite.keyboard' -Status 'SKIP' -Details @{ reason = 'Keyboard input adapter and journeys are not implemented.' }
        throw 'Required Keyboard suite skipped.'
    }
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::UserInteractive) { throw 'Interactive Renoise runs require the current Windows desktop session.' }
    $lastExpected = 'RenoiseProcessId is zero or identifies the exact developer-owned process'
    if ($RenoiseProcessId -lt 0) { throw 'RenoiseProcessId must be a positive process ID.' }
    $lastExpected = 'Requested scenario is registered for the selected suite'
    if ($Scenario -and $Scenario -cne 'transport') { throw "Scenario '$Scenario' is not registered. Available in T0.4: transport." }
    $lastExpected = 'Developer approves replacing the open document with a disposable new song'
    if (-not $ApproveDisposableSong) { throw 'Pass -ApproveDisposableSong only after confirming the open Renoise document can be replaced by a new empty document for this run.' }

    Import-Module (Join-Path $repoRoot 'tests/renoise/runner.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests/renoise/host_preflight.psm1') -Force
    $environment = Import-RenoiseTestEnvironment -Path $TestEnvironment
    $environmentExe = if ($environment.PSObject.Properties['RenoiseExe']) { [string]$environment.RenoiseExe } else { '' }
    if ($RenoiseExe -and $environmentExe -and
        -not [string]::Equals([IO.Path]::GetFullPath($RenoiseExe), [IO.Path]::GetFullPath($environmentExe), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RenoiseExe conflicts with the TestEnvironment RenoiseExe value.'
    }
    $configuredExe = if ($RenoiseExe) { $RenoiseExe } elseif ($environmentExe) { $environmentExe } else { '' }
    if ($RenoiseProcessId -gt 0 -and -not $configuredExe) {
        $selectedIdentity = Get-RenoiseProcessIdentity -Id $RenoiseProcessId
        $configuredExe = $selectedIdentity.Path
    }
    $script:resolvedExe = Get-RenoiseExecutable -ConfiguredPath $configuredExe
    $preflight = Get-Preflight -SelectedId $RenoiseProcessId
    Add-Trace -Operation 'host.preflight' -Status 'PASS' -Details @{ selected_process_id = $RenoiseProcessId; current_user_desktop = $true }

    $sourceCommit = & git -C $repoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $report.source_commit = [string]$sourceCommit }
    $exeInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($script:resolvedExe)
    $toolVersion = [xml](Get-Content -LiteralPath (Join-Path $repoRoot 'com.david303ttl.ACID.xrnx/manifest.xml') -Raw)
    $report.tool_version = [string]$toolVersion.RenoiseScriptingTool.Version
    $report.host = [ordered]@{
        renoise_version = [string]$exeInfo.ProductVersion
        executable_sha256 = (Get-FileHash -LiteralPath $script:resolvedExe -Algorithm SHA256).Hash.ToLowerInvariant()
        process_id = $RenoiseProcessId
    }

    & (Join-Path $repoRoot 'scripts/package_dev.ps1') -Tool ACID -OutputDirectory $devOutputName | Out-Null
    Add-Trace -Operation 'bundle.build' -Status 'PASS' -Details @{ output = $devOutputName }
    $devToolPath = Join-Path $devOutput $devToolName
    $sessionSourcePath = Join-Path $devOutput $sessionName
    $session = Get-RenoiseSessionConfig -Path $sessionSourcePath

    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $exeVersionTriplet = Get-VersionTriplet -Value ([string]$exeInfo.ProductVersion)
    $renoiseVersion = $exeVersionTriplet.ToString(3)
    $toolsPath = Join-Path $appData "Renoise/V$renoiseVersion/Scripts/Tools"
    $installedToolPath = Join-Path $toolsPath $devToolName
    $sessionTargetPath = Join-Path $toolsPath $sessionName
    $lastExpected = 'Explicit install consent and a verified restoration path are present'
    if (-not $Install) { throw "ACID installation is required to load this development bundle. Re-run with -Install to authorize a restorable temporary installation under '$toolsPath'." }
    if (Test-Path -LiteralPath $installedToolPath) {
        if (-not $preflight.InstallReplacementAuthorized) { throw 'Host preflight rejected the existing ACID installation as an unrecognized replacement target.' }
        foreach ($entry in @(Get-ChildItem -LiteralPath $installedToolPath -Force -Recurse)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Existing ACID installation contains a reparse point; refusing replacement.' }
        }
        if ((Get-Item -LiteralPath $installedToolPath -Force).PSIsContainer -ne $true) { throw 'Existing ACID installation is not a directory.' }
        $productionToolPath = Join-Path $repoRoot $devToolName
        if ((Get-DirectoryHash -Path $installedToolPath) -cne (Get-DirectoryHash -Path $productionToolPath)) { throw 'Existing ACID installation changed after host preflight; refusing replacement.' }
    }
    if (Test-Path -LiteralPath $sessionTargetPath) {
        $sessionPrecheck = Get-Item -LiteralPath $sessionTargetPath -Force
        if ($sessionPrecheck.PSIsContainer -or ($sessionPrecheck.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Existing session sidecar path is not a plain file; refusing replacement.' }
    }
    $deploymentStarted = $true
    $deploymentStageRoot = Join-Path $toolsPath ('.acid-stage-' + $artifactId)
    $deploymentStageToolPath = Join-Path $deploymentStageRoot $devToolName
    $deploymentStageSessionPath = Join-Path $deploymentStageRoot $sessionName
    foreach ($path in @($deploymentStageRoot, (Join-Path $toolsPath ('.acid-restore-' + $artifactId)), (Join-Path $toolsPath ('.acid-session-restore-' + $artifactId + '.conf')))) {
        if (Test-Path -LiteralPath $path) { throw 'A unique temporary deployment path already exists; refusing to reuse it.' }
    }
    New-Item -ItemType Directory -Path $deploymentStageRoot | Out-Null
    Copy-Item -LiteralPath $devToolPath -Destination $deploymentStageToolPath -Recurse
    Copy-Item -LiteralPath $sessionSourcePath -Destination $deploymentStageSessionPath
    Set-UserOnlyFileAcl -Path $deploymentStageSessionPath
    $deploymentStageToolHash = Get-DirectoryHash -Path $deploymentStageToolPath
    $deploymentStageSessionHash = (Get-FileHash -LiteralPath $deploymentStageSessionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (Test-Path -LiteralPath $installedToolPath) {
        $item = Get-Item -LiteralPath $installedToolPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $item.PSIsContainer) { throw 'Existing ACID installation is not a plain directory; refusing replacement.' }
        $backupToolPath = Join-Path $artifactRoot 'previous-ACID.xrnx'
        Copy-Item -LiteralPath $installedToolPath -Destination $backupToolPath -Recurse
        if ((Get-DirectoryHash -Path $installedToolPath) -cne (Get-DirectoryHash -Path $backupToolPath)) { throw 'ACID backup copy did not verify; refusing replacement.' }
        $localBackupToolPath = Join-Path $toolsPath ('.acid-restore-' + $artifactId)
        Move-Item -LiteralPath $installedToolPath -Destination $localBackupToolPath
        Add-Trace -Operation 'install.backup' -Status 'PASS' -Details @{ backup = 'run artifact directory' }
    }
    if (Test-Path -LiteralPath $sessionTargetPath) {
        $sessionBackupPath = Join-Path $artifactRoot 'previous-session.conf'
        Copy-Item -LiteralPath $sessionTargetPath -Destination $sessionBackupPath
        if ((Get-FileHash -LiteralPath $sessionTargetPath -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $sessionBackupPath -Algorithm SHA256).Hash) { throw 'Session sidecar backup did not verify; refusing replacement.' }
        $localBackupSessionPath = Join-Path $toolsPath ('.acid-session-restore-' + $artifactId + '.conf')
        Move-Item -LiteralPath $sessionTargetPath -Destination $localBackupSessionPath
    }
    $installedDirectoryHash = $deploymentStageToolHash
    $installedSessionHash = $deploymentStageSessionHash
    Move-Item -LiteralPath $deploymentStageToolPath -Destination $installedToolPath
    $toolDeployed = $true
    Move-Item -LiteralPath $deploymentStageSessionPath -Destination $sessionTargetPath
    $sessionDeployed = $true
    Add-Trace -Operation 'install.dev_bundle' -Status 'PASS' -Details @{ target = 'version-matched user Renoise Tools' }

    if ($RenoiseProcessId -gt 0) {
        $selectedIdentity = if ($selectedIdentity) { $selectedIdentity } else { Get-RenoiseProcessIdentity -Id $RenoiseProcessId }
        Assert-RenoiseProcessIdentity -Identity $selectedIdentity
        $driverMayBeLoaded = $true
        Write-Information 'ACID development files are installed. In the selected Renoise window, reload the ACID tool if it is already loaded; do not restart that process.' -InformationAction Continue
        $processIdentity = $selectedIdentity
    }
    else {
        $startedProcess = Start-Process -FilePath $script:resolvedExe -PassThru
        $capturedStartedIdentity = Get-RenoiseProcessIdentity -Id $startedProcess.Id
        if (-not [string]::Equals($capturedStartedIdentity.Path, $script:resolvedExe, [StringComparison]::OrdinalIgnoreCase)) { throw 'Started Renoise process does not match the verified executable.' }
        $startedIdentity = $capturedStartedIdentity
        $driverMayBeLoaded = $true
        $processIdentity = $startedIdentity
        $report.host.process_id = $startedIdentity.Id
        $report.host.process_start_time_utc = $startedIdentity.StartTimeUtc.ToString('o')
        Add-Trace -Operation 'process.start' -Status 'PASS' -Details @{ pid = $startedIdentity.Id; start_time_utc = $startedIdentity.StartTimeUtc.ToString('o') }
        $postLaunchPreflight = Get-Preflight -SelectedId $startedIdentity.Id
    }

    $processCheck = { Assert-RenoiseProcessIdentity -Identity $processIdentity }
    $client = Connect-RenoiseDriver -Session $session -TimeoutSeconds $StartupTimeoutSeconds -ProcessCheck $processCheck
    try {
        $ping = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'ping' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $lastExpected = 'Authenticated ping uses protocol version 1 and the current run nonce'
        $lastActual = @{ protocol_version = $ping.protocol_version; nonce_matches = ($ping.session -ceq $session.Nonce) }
        if ($ping.protocol_version -ne 1 -or $ping.session -cne $session.Nonce) { throw 'Authenticated handshake reported the wrong protocol or run nonce.' }
        Add-Trace -Operation 'driver.ping' -Status 'PASS' -Details @{ protocol_version = $ping.protocol_version; authenticated = $true }
        $capabilities = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'capabilities' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        if ($capabilities.protocol_version -ne 1 -or 'song.snapshot' -notin @($capabilities.operations)) { throw 'Renoise driver capabilities are incomplete.' }
        $runtimeVersion = Get-VersionTriplet -Value ([string]$capabilities.renoise_version)
        $runtimeApiVersion = [string]$capabilities.api_version
        $manifestApiVersion = [string]$toolVersion.RenoiseScriptingTool.ApiVersion
        if ($runtimeApiVersion -cne $manifestApiVersion) { throw "Renoise API $runtimeApiVersion does not match ACID manifest API $manifestApiVersion." }
        if ($runtimeVersion -ne $exeVersionTriplet) { throw "Connected Renoise runtime $runtimeVersion does not match selected executable $exeVersionTriplet." }
        $report.host.renoise_runtime_version = [string]$capabilities.renoise_version
        $report.host.api_version = $runtimeApiVersion
        Add-Trace -Operation 'driver.capabilities' -Status 'PASS' -Details @{ operation_count = @($capabilities.operations).Count }

        $before = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'diagnostics' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        if (-not $before.document_ready -or $before.pending_commands -ne 0 -or $before.queued_commands -ne 0 -or $before.document_transition_uncertain) {
            throw 'Renoise host is not in a settled, ready document state; no document reset was attempted.'
        }
        Write-Information 'Creating a new empty Renoise document. If Renoise shows a dirty-song prompt, handle it yourself; the runner will not choose Save or Discard.' -InformationAction Continue
        $resetTimeoutMs = [Math]::Min(120000, $CommandTimeoutSeconds * 1000)
        $lastExpected = 'document.new completes only after release and new-document epoch barriers'
        $lastActual = @{ starting_epoch = $before.document_epoch; terminal_response = $false }
        $lastDiff = @{ terminal_response_received = $false; expected_epoch_greater_than = $before.document_epoch }
        $resetResponseTimeout = [Math]::Min(123, [Math]::Ceiling($resetTimeoutMs / 1000) + 3)
        $reset = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'document.new' -Arguments @{ timeout_ms = $resetTimeoutMs } -TimeoutSeconds $resetResponseTimeout -ProcessCheck $processCheck
        $lastActual = @{ starting_epoch = $before.document_epoch; observed_epoch = $reset.document_epoch; terminal_response = $true; operation = $reset.operation }
        $lastDiff = @{ terminal_response_received = $true; operation_matches = ($reset.operation -ceq 'document.new'); epoch_advanced = ($reset.document_epoch -gt $before.document_epoch) }
        if ($reset.operation -cne 'document.new' -or $reset.document_epoch -le $before.document_epoch) { throw 'New-document command did not return an advanced observed document epoch.' }
        Add-Trace -Operation 'document.new' -Status 'PASS' -Details @{ previous_epoch = $before.document_epoch; observed_epoch = $reset.document_epoch }
        $snapshotBefore = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'song.snapshot' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $lastExpected = 'new document has self-consistent instrument/phrase inventory and no phrases'
        $lastActual = @{ instrument_count = $snapshotBefore.instrument_count; phrase_count = $snapshotBefore.phrase_count; document_epoch = $snapshotBefore.document_epoch }
        $reportedInstrumentCount = [int]$snapshotBefore.instrument_count
        $reportedPhraseCount = [int]$snapshotBefore.phrase_count
        $actualInstrumentCount = @($snapshotBefore.instruments).Count
        $actualPhraseCount = 0
        foreach ($instrument in @($snapshotBefore.instruments)) { $actualPhraseCount += @($instrument.phrases).Count }
        $inventoryDiff = @{
            instrument_count_matches_inventory = ($reportedInstrumentCount -eq $actualInstrumentCount)
            phrase_count_matches_inventory = ($reportedPhraseCount -eq $actualPhraseCount)
            unexpected_phrases = ($actualPhraseCount -ne 0)
        }
        $lastDiff = $inventoryDiff
        if ($reportedInstrumentCount -ne $actualInstrumentCount -or $reportedPhraseCount -ne $actualPhraseCount -or $actualPhraseCount -ne 0) {
            throw 'New document inventory did not match its native instrument/phrase inventory or contains unexpected phrases.'
        }
        $snapshotBeforeJson = $snapshotBefore | ConvertTo-Json -Depth 20 -Compress
        $snapshotBeforeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($snapshotBeforeJson))).ToLowerInvariant()
        $snapshotAfter = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'song.snapshot' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $snapshotAfterJson = $snapshotAfter | ConvertTo-Json -Depth 20 -Compress
        $snapshotAfterHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($snapshotAfterJson))).ToLowerInvariant()
        $after = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'diagnostics' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        $lastExpected = 'Read-only snapshots match and document epoch and queues remain settled'
        $lastActual = @{ before_sha256 = $snapshotBeforeHash; after_sha256 = $snapshotAfterHash; before_epoch = $before.document_epoch; after_epoch = $after.document_epoch; pending = $after.pending_commands; queued = $after.queued_commands; transition_uncertain = $after.document_transition_uncertain }
        $lastDiff = @{
            snapshot_changed = ($snapshotBeforeHash -cne $snapshotAfterHash)
            epoch_changed = ($after.document_epoch -ne $reset.document_epoch)
            pending = $after.pending_commands
            queued = $after.queued_commands
            transition_uncertain = $after.document_transition_uncertain
            instrument_count_matches_inventory = $inventoryDiff.instrument_count_matches_inventory
            phrase_count_matches_inventory = $inventoryDiff.phrase_count_matches_inventory
            unexpected_phrases = $inventoryDiff.unexpected_phrases
        }
        $lastExpected = 'New document release/new epoch observed; consistent instrument inventory, zero phrases, stable snapshots, and zero pending commands'
        if ($snapshotBeforeHash -cne $snapshotAfterHash -or $after.document_epoch -ne $reset.document_epoch -or
            $after.pending_commands -ne 0 -or $after.queued_commands -ne 0 -or $after.document_transition_uncertain) {
            throw 'Reset document snapshot or diagnostics did not match the expected settled state.'
        }
        $report.document_epoch = $after.document_epoch
        Add-Trace -Operation 'song.snapshot' -Status 'PASS' -Details @{ sha256 = $snapshotAfterHash; document_epoch = $after.document_epoch }
        $scenarioResults = [Collections.Generic.List[object]]::new()
        if ($Suite -in @('Native','All')) {
            $scenarioResults.Add([pscustomobject]@{ name = 'transport'; suite = 'Native'; status = 'PASS'; expected = $lastExpected; actual = "protocol=$($ping.protocol_version); instruments=$($snapshotAfter.instrument_count); phrases=$($snapshotAfter.phrase_count); epoch=$($after.document_epoch)"; diff = $lastDiff })
        }
        if ($Suite -in @('Keyboard','All')) {
            $scenarioResults.Add([pscustomobject]@{ name = 'keyboard'; suite = 'Keyboard'; status = 'SKIP'; reason = 'Keyboard input adapter and journeys are implemented in T0.6.'; expected = 'Keyboard E2E'; actual = $null; diff = $null })
        }
        $report.scenarios = @($scenarioResults)
        if (@($scenarioResults | Where-Object { $_.status -ne 'PASS' }).Count -eq 0) { $report.status = 'PASS' }
        else { $report.status = 'FAIL' }
        $disconnect = Invoke-RenoiseDriverRequest -Client $client -Session $session -Operation 'disconnect' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $processCheck
        if ($disconnect.disconnected -ne $true) { throw 'Renoise driver did not confirm disconnect.' }
        Add-Trace -Operation 'driver.disconnect' -Status 'PASS' -Details @{ acknowledged = ($disconnect.disconnected -eq $true) }
    }
    finally {
        if ($client) { $client.Dispose() }
    }

    if ($startedIdentity) {
        Assert-RenoiseProcessIdentity -Identity $startedIdentity
        $startedProcess.Refresh()
        if (-not $startedProcess.HasExited) {
            [void]$startedProcess.CloseMainWindow()
            if (-not $startedProcess.WaitForExit(10000)) {
                Assert-RenoiseProcessIdentity -Identity $startedIdentity
                Stop-Process -Id $startedIdentity.Id -Force -ErrorAction Stop
                if (-not $startedProcess.WaitForExit(5000)) { throw 'Runner-launched Renoise did not terminate after identity-checked cleanup.' }
                $startedProcessForceStopped = $true
                Add-Trace -Operation 'process.force_stop' -Status 'PASS' -Details @{ runner_launched_process_only = $true; disposable_song_approved = $true }
            }
        }
        $safeToRestore = $true
        Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ launched_process_closed_cleanly = (-not $startedProcessForceStopped); force_stopped = $startedProcessForceStopped }
    }
    else {
        Write-Information 'The selected Renoise process remains open. Disable or reload the temporary ACID development tool now; the runner will restore files only after the listener is observed closed.' -InformationAction Continue
        $unloadDeadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
        $listenerState = 'Unknown'
        while ([DateTimeOffset]::UtcNow -lt $unloadDeadline -and $listenerState -ne 'Closed') {
            $listenerState = Test-DriverListenerClosed -Port $session.Port
            if ($listenerState -eq 'Closed') { break }
            Start-Sleep -Milliseconds 200
        }
        if ($listenerState -ne 'Closed') { throw "ACID test driver unload was not verified (listener state: $listenerState). The existing Renoise process was left open and its installation backup was retained." }
        $safeToRestore = $true
        Add-Trace -Operation 'driver.unload' -Status 'PASS' -Details @{ selected_process_left_open = $true }
    }
}
catch {
    if (-not $keyboardOnlySkipped) {
        $failureMessage = $_.Exception.Message
        $report.status = 'ERROR'
        $report.error = $failureMessage
        $failureScenario = [pscustomobject]@{
            name = if ($Scenario) { $Scenario } else { 'transport' }
            suite = if ($Suite -eq 'All') { 'Native' } else { $Suite }
            status = 'ERROR'
            expected = $lastExpected
            actual = if ($null -ne $lastActual) { $lastActual } else { $failureMessage }
            diff = if ($null -ne $lastDiff) { $lastDiff } else { @{ error = $failureMessage } }
        }
        if (@($report.scenarios).Count -eq 0) { $report.scenarios = @($failureScenario) }
        else { $report.scenarios = @($report.scenarios) + @([pscustomobject]@{
            name = 'runner-cleanup'
            suite = $Suite
            status = 'ERROR'
            expected = 'Session, process, and temporary installation cleanup completes safely'
            actual = $failureMessage
            diff = @{ cleanup_error = $failureMessage }
        }) }
        Add-Trace -Operation 'runner' -Status 'ERROR' -Details @{ message = $failureMessage }
    }
}
finally {
    if ($deploymentStarted -and -not $driverMayBeLoaded) {
        if (-not $startedProcess) { $safeToRestore = $true }
        else {
            try {
                $startedProcess.Refresh()
                if ($startedProcess.HasExited) {
                    $safeToRestore = $true
                    Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ launched_process_exited_before_identity_validation = $true }
                }
                else {
                    Add-Trace -Operation 'install.restore_deferred' -Status 'ERROR' -Details @{ reason = 'Runner-launched process is active but its identity could not be validated.'; backup_retained = $true }
                }
            }
            catch {
                Add-Trace -Operation 'install.restore_deferred' -Status 'ERROR' -Details @{ reason = $_.Exception.Message; backup_retained = $true }
            }
        }
    }
    if ($startedIdentity -and -not $safeToRestore) {
        try {
            $startedProcess.Refresh()
            if ($startedProcess.HasExited) {
                $safeToRestore = $true
                Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ runner_launched_process_exited = $true }
            }
            else {
                Assert-RenoiseProcessIdentity -Identity $startedIdentity
                [void]$startedProcess.CloseMainWindow()
                if ($startedProcess.WaitForExit(10000)) {
                    $safeToRestore = $true
                    Add-Trace -Operation 'process.shutdown' -Status 'PASS' -Details @{ launched_process_closed_cleanly_after_error = $true }
                }
                else {
                    Assert-RenoiseProcessIdentity -Identity $startedIdentity
                    Stop-Process -Id $startedIdentity.Id -Force -ErrorAction Stop
                    if (-not $startedProcess.WaitForExit(5000)) { throw 'Runner-launched Renoise did not terminate after identity-checked error cleanup.' }
                    $safeToRestore = $true
                    $startedProcessForceStopped = $true
                    Add-Trace -Operation 'process.force_stop' -Status 'PASS' -Details @{ runner_launched_process_only = $true; disposable_song_approved = $true; after_error = $true }
                }
            }
        }
        catch { Add-Trace -Operation 'process.shutdown' -Status 'ERROR' -Details @{ message = $_.Exception.Message } }
    }
    if ($deploymentStarted -and $safeToRestore) {
      try {
        if ($toolDeployed -and $installedToolPath -and (Test-Path -LiteralPath $installedToolPath)) {
            if (-not $installedDirectoryHash -or (Get-DirectoryHash -Path $installedToolPath) -cne $installedDirectoryHash) {
                throw 'Installed ACID files changed during the run; keeping the current directory and restoration backup untouched.'
            }
            Remove-Item -LiteralPath $installedToolPath -Recurse -Force
        }
        if ($localBackupToolPath -and (Test-Path -LiteralPath $localBackupToolPath)) {
            if (Test-Path -LiteralPath $installedToolPath) { throw 'ACID target is occupied; keeping the same-volume original and verified run backup untouched.' }
            Move-Item -LiteralPath $localBackupToolPath -Destination $installedToolPath
        }
        if ($sessionDeployed -and $sessionTargetPath -and (Test-Path -LiteralPath $sessionTargetPath)) {
            if (-not $installedSessionHash -or (Get-FileHash -LiteralPath $sessionTargetPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $installedSessionHash) {
                throw 'Development session sidecar changed during the run; keeping it and the restoration backup untouched.'
            }
            Remove-Item -LiteralPath $sessionTargetPath -Force
        }
        if ($localBackupSessionPath -and (Test-Path -LiteralPath $localBackupSessionPath)) {
            if (Test-Path -LiteralPath $sessionTargetPath) { throw 'Session sidecar target is occupied; keeping the same-volume original and verified run backup untouched.' }
            Move-Item -LiteralPath $localBackupSessionPath -Destination $sessionTargetPath
        }
        if ($deploymentStageRoot -and (Test-Path -LiteralPath $deploymentStageRoot)) {
            $stageToolExists = Test-Path -LiteralPath $deploymentStageToolPath -PathType Container
            $stageSessionExists = Test-Path -LiteralPath $deploymentStageSessionPath -PathType Leaf
            if (($stageToolExists -and (Get-DirectoryHash -Path $deploymentStageToolPath) -cne $deploymentStageToolHash) -or
                ($stageSessionExists -and (Get-FileHash -LiteralPath $deploymentStageSessionPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $deploymentStageSessionHash)) {
                throw 'Staged ACID files changed; preserving the staging directory for recovery.'
            }
            Remove-Item -LiteralPath $deploymentStageRoot -Recurse -Force
        }
        if ($installedToolPath) { Add-Trace -Operation 'install.restore' -Status 'PASS' -Details @{ original_installation_restored = $true } }
    }
      catch {
        if ($report.status -eq 'PASS') { $report.status = 'ERROR' }
        if (-not $report.error) { $report.error = "ACID installation restoration failed: $($_.Exception.Message)" }
        $report.scenarios = @($report.scenarios) + @([pscustomobject]@{
            name = 'runner-cleanup'
            suite = $Suite
            status = 'ERROR'
            expected = 'Temporary installation is removed and the prior installation restored without overwriting changed files'
            actual = $_.Exception.Message
            diff = @{ restoration_failed = $true }
        })
        Add-Trace -Operation 'install.restore' -Status 'ERROR' -Details @{
            message = $_.Exception.Message
            artifact_backup = if ($backupToolPath -and (Test-Path -LiteralPath $backupToolPath)) { $backupToolPath } else { $null }
            same_volume_restore_path = if ($localBackupToolPath -and (Test-Path -LiteralPath $localBackupToolPath)) { $localBackupToolPath } else { $null }
            session_backup = if ($sessionBackupPath -and (Test-Path -LiteralPath $sessionBackupPath)) { $sessionBackupPath } else { $null }
            same_volume_session_restore_path = if ($localBackupSessionPath -and (Test-Path -LiteralPath $localBackupSessionPath)) { $localBackupSessionPath } else { $null }
        }
      }
    }
    elseif ($deploymentStarted) {
        if ($report.status -eq 'PASS') { $report.status = 'ERROR' }
        $retainedMessage = 'Temporary install was retained because the development driver/process did not reach a verified clean shutdown.'
        if ($report.error) { $report.error = "$($report.error) $retainedMessage" } else { $report.error = $retainedMessage }
        $report.scenarios = @($report.scenarios) + @([pscustomobject]@{
            name = 'runner-cleanup'
            suite = $Suite
            status = 'SKIP'
            reason = 'Host or process shutdown was not verified; restoration was withheld to avoid replacing a live or changed installation.'
            expected = 'Temporary installation is restored only after verified shutdown'
            actual = @{ install_retained = $true; process_id = $report.host.process_id }
            diff = @{ restoration_withheld = $true }
        })
        Add-Trace -Operation 'install.restore' -Status 'SKIP' -Details @{
            reason = 'shutdown not verified'
            install_target = $installedToolPath
            artifact_backup = $backupToolPath
            same_volume_restore_path = $localBackupToolPath
            session_backup = $sessionBackupPath
            same_volume_session_restore_path = $localBackupSessionPath
        }
    }
    $clock.Stop()
    $report.elapsed_ms = $clock.ElapsedMilliseconds
    if (Test-Path -LiteralPath $artifactRoot -PathType Container) {
        $reportPath = Join-Path $artifactRoot 'report.json'
        $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
        Write-Output "Run report: $reportPath"
    }
}

if ($report.status -eq 'PASS') {
    Write-Output 'PASS interactive Renoise runner'
    exit 0
}
Write-Error "Interactive Renoise runner $($report.status): $($report.error)"
exit 1
