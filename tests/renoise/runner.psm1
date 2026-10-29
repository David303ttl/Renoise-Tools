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
            if ([string]$entry.DisplayName -match '^Renoise(?:\s|$)') {
                foreach ($raw in @([string]$entry.InstallLocation, [string]$entry.DisplayIcon, [string]$entry.UninstallString)) {
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
            $connect.GetAwaiter().GetResult()
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
        if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 50; continue }
        $buffer = [byte[]]::new(4096)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { throw 'Renoise closed the transport before returning a terminal response.' }
        for ($index = 0; $index -lt $read; $index++) {
            if ($buffer[$index] -eq 10) {
                $line = [Text.UTF8Encoding]::new($false, $true).GetString($responseBytes.ToArray()).TrimEnd("`r")
                $response = $line | ConvertFrom-Json -Depth 16
                if ([string]$response.id -cne $requestId) { throw 'Renoise returned a response for an unexpected request ID.' }
                if ($response.ok -ne $true) {
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
