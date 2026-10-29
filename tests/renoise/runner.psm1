#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-RenoiseExecutable {
    param([string]$ConfiguredPath)
    if ($ConfiguredPath) {
        $candidate = [IO.Path]::GetFullPath($ConfiguredPath)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Renoise executable does not exist: $candidate" }
        return $candidate
    }

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($keyPath in $registryPaths) {
        foreach ($entry in @(Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue)) {
            if ($entry.PSObject.Properties['DisplayName'] -and [string]$entry.DisplayName -match '^Renoise(?:\s|$)') {
                foreach ($property in @('InstallLocation', 'DisplayIcon', 'UninstallString')) {
                    if (-not $entry.PSObject.Properties[$property]) { continue }
                    $raw = [string]$entry.$property
                    if (-not $raw) { continue }
                    $pathMatch = [regex]::Match($raw, '(?i)([A-Z]:\\[^\"]*?Renoise\.exe)')
                    if ($pathMatch.Success) { [void]$candidates.Add($pathMatch.Groups[1].Value); continue }
                    if (Test-Path -LiteralPath $raw -PathType Container) { [void]$candidates.Add((Join-Path $raw 'Renoise.exe')) }
                }
            }
        }
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw 'Could not discover Renoise.exe from registered Renoise installation metadata. Pass -RenoiseExe or set RenoiseExe in TestEnvironment.'
}

function Get-RenoiseSessionConfig {
    param([Parameter(Mandatory)][string]$Path)
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2 -or $values.ContainsKey($parts[0])) { throw 'Development session configuration is malformed.' }
        $values[$parts[0]] = $parts[1]
    }
    if (@($values.Keys | Where-Object { $_ -notin @('bind_address','port','token','nonce') }).Count -gt 0 -or
        @('bind_address','port','token','nonce' | Where-Object { -not $values.ContainsKey($_) }).Count -gt 0 -or
        $values.bind_address -cne '127.0.0.1' -or $values.port -notmatch '^\d+$' -or
        [int]$values.port -lt 1 -or [int]$values.port -gt 65535 -or
        $values.token -notmatch '^[0-9a-f]{64}$' -or $values.nonce -notmatch '^[0-9a-f]{64}$') {
        throw 'Development session configuration failed validation.'
    }
    return [pscustomobject]@{ Address = $values.bind_address; Port = [int]$values.port; Token = $values.token; Nonce = $values.nonce }
}

function Connect-RenoiseDriver {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][scriptblock]$ProcessCheck
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        & $ProcessCheck
        $client = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
        try {
            $connect = $client.ConnectAsync([Net.IPAddress]::Loopback, $Session.Port)
            if (-not $connect.Wait([Math]::Min(500, [Math]::Max(1, [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)))) {
                $client.Dispose()
                continue
            }
            [void]$connect.GetAwaiter().GetResult()
            $client.NoDelay = $true
            return $client
        }
        catch {
            $client.Dispose()
            Start-Sleep -Milliseconds 200
        }
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for the Renoise loopback listener."
}

function Invoke-RenoiseDriverRequest {
    param(
        [Parameter(Mandatory)][Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][scriptblock]$ProcessCheck
    )
    & $ProcessCheck
    $stream = $Client.GetStream()
    $requestId = 'ps-' + [guid]::NewGuid().ToString('N')
    $request = [ordered]@{ id = $requestId; op = $Operation; args = $Arguments; token = $Session.Token } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($request + "`n")
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $responseBytes = [Collections.Generic.List[byte]]::new()
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        & $ProcessCheck
        if ($Client.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $Client.Client.Available -eq 0) { throw 'Renoise closed the transport before returning a terminal response.' }
        if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 50; continue }
        $buffer = [byte[]]::new(4096)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { throw 'Renoise closed the transport before returning a terminal response.' }
        for ($index = 0; $index -lt $read; $index++) {
            if ($buffer[$index] -eq 10) {
                $line = [Text.UTF8Encoding]::new($false, $true).GetString($responseBytes.ToArray()).TrimEnd("`r")
                $response = $line | ConvertFrom-Json -Depth 16
                if ($null -eq $response -or $response -is [array] -or
                    -not $response.PSObject.Properties['id'] -or $response.id -isnot [string] -or
                    -not $response.PSObject.Properties['ok'] -or $response.ok -isnot [bool]) {
                    throw 'Renoise returned an invalid response envelope.'
                }
                if ($response.id -cne $requestId) { throw 'Renoise returned a response for an unexpected request ID.' }
                if ($response.ok) {
                    if (-not $response.PSObject.Properties['result']) { throw 'Renoise returned an invalid response envelope.' }
                } else {
                    if (-not $response.PSObject.Properties['error']) { throw 'Renoise returned an invalid response envelope.' }
                    $code = if ($response.error.code) { [string]$response.error.code } else { 'host_error' }
                    throw "Renoise command '$Operation' failed ($code): $($response.error.message)"
                }
                return $response.result
            }
            $responseBytes.Add($buffer[$index])
            if ($responseBytes.Count -gt 262144) { throw 'Renoise response exceeded the protocol size limit.' }
        }
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for terminal response to '$Operation'."
}

function Get-RenoiseProcessIdentity {
    param([Parameter(Mandatory)][int]$Id)
    $process = Get-Process -Id $Id -ErrorAction Stop
    $path = [IO.Path]::GetFullPath($process.Path)
    $start = $process.StartTime.ToUniversalTime()
    [pscustomobject]@{ Id = $process.Id; Path = $path; StartTimeUtc = $start; SessionId = $process.SessionId }
}

function Assert-RenoiseProcessIdentity {
    param([Parameter(Mandatory)][pscustomobject]$Identity)
    $current = Get-RenoiseProcessIdentity -Id $Identity.Id
    if ($current.SessionId -ne $Identity.SessionId -or $current.StartTimeUtc -ne $Identity.StartTimeUtc -or
        -not [string]::Equals($current.Path, $Identity.Path, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The selected Renoise process changed identity during the run.'
    }
}

function Import-RenoiseTestEnvironment {
    param([string]$Path)
    if (-not $Path) { return [pscustomobject]@{} }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "TestEnvironment file does not exist: $Path" }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 8
    if ($config -isnot [System.Collections.IDictionary]) { throw 'TestEnvironment must contain a JSON object.' }
    $allowed = @('RenoiseExe','Keyboard')
    foreach ($key in $config.Keys) { if ($key -notin $allowed) { throw "Unsupported TestEnvironment property '$key'." } }
    return [pscustomobject]$config
}

Export-ModuleMember -Function Get-RenoiseExecutable, Get-RenoiseSessionConfig, Connect-RenoiseDriver, Invoke-RenoiseDriverRequest, Get-RenoiseProcessIdentity, Assert-RenoiseProcessIdentity, Import-RenoiseTestEnvironment

function Get-DirectoryHash {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $records = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object { $_.FullName.Substring($root.Length) } | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName.Substring($root.Length).TrimStart('\','/').Replace('\','/'); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records | ConvertTo-Json -Compress)))).ToLowerInvariant()
}


function Assert-RenoiseListenerOwner {
    param([Net.Sockets.TcpClient]$Client, [pscustomobject]$Identity,
          [scriptblock]$GetListeners = { param($Port) Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop },
          [scriptblock]$CheckIdentity = { param($Value) Assert-RenoiseProcessIdentity -Identity $Value })
    & $CheckIdentity $Identity
    $endpoint = $Client.Client.RemoteEndPoint
    $listeners = @(& $GetListeners $endpoint.Port | Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0') })
    if ($listeners.Count -ne 1 -or $listeners[0].OwningProcess -ne $Identity.Id) {
        throw 'Loopback listener ownership does not match the selected Renoise process.'
    }
    & $CheckIdentity $Identity
}

# Dot-source these operations in the caller so partial failures preserve recovery state.
function Get-RenoiseDeploymentOperation {
    return {
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
    }
}
function Get-RenoiseRestorationOperation {
    return {
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
}
Export-ModuleMember -Function Get-DirectoryHash, Assert-RenoiseListenerOwner, Get-RenoiseDeploymentOperation, Get-RenoiseRestorationOperation

function Stop-RenoiseDriver {
    param([Net.Sockets.TcpClient]$Client, [pscustomobject]$Session, [string]$SessionPath,
          [int]$TimeoutSeconds, [scriptblock]$ProcessCheck)
    $response = Invoke-RenoiseDriverRequest -Client $Client -Session $Session -Operation shutdown -Arguments @{} -TimeoutSeconds $TimeoutSeconds -ProcessCheck $ProcessCheck
    if ($response.shutdown_requested -ne $true) { throw 'Renoise test driver did not accept shutdown.' }
    $marker = $SessionPath + '.' + $Session.Nonce + '.stopped'
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            if ([IO.File]::ReadAllText($marker) -ceq $Session.Nonce) {
                Remove-Item -LiteralPath $marker
                return $true
            }
        }
        & $ProcessCheck
        Start-Sleep -Milliseconds 50
    }
    throw 'Timed out waiting for the Renoise test driver to finish shutdown.'
}
Export-ModuleMember -Function Stop-RenoiseDriver
