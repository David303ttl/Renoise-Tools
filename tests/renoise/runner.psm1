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
        [Parameter(Mandatory)][double]$TimeoutSeconds,
        [Parameter(Mandatory)][scriptblock]$ProcessCheck,
        [scriptblock]$CreateClient = { [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork) }
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        & $ProcessCheck
        $client = & $CreateClient
        try {
            $remainingMilliseconds = [Math]::Max(1, [int][Math]::Ceiling(($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))
            $connect = $client.ConnectAsync([Net.IPAddress]::Loopback, $Session.Port)
            if (-not $connect.Wait($remainingMilliseconds)) {
                $client.Dispose()
                break
            }
            [void]$connect.GetAwaiter().GetResult()
        }
        catch {
            $client.Dispose()
            if ([DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
            continue
        }
        try {
            & $ProcessCheck
            $client.NoDelay = $true
        }
        catch {
            $client.Dispose()
            throw
        }
        return $client
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for the Renoise loopback listener."
}

function Test-RenoiseTransportFailure {
    param([Exception]$Exception)
    $current=$Exception
    while ($current) {
        if ($current -is [IO.IOException] -or $current -is [Net.Sockets.SocketException]) { return $true }
        $current=$current.InnerException
    }
    return $false
}

function Invoke-RenoiseDriverBootstrap {
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][pscustomobject]$Identity,
        [Parameter(Mandatory)][int]$StartupTimeoutSeconds,
        [Parameter(Mandatory)][int]$CommandTimeoutSeconds,
        [Parameter(Mandatory)][scriptblock]$ProcessCheck,
        [scriptblock]$GetListeners = { param($Port) Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop },
        [scriptblock]$CheckIdentity = { param($Value) Assert-RenoiseProcessIdentity -Identity $Value },
        [ValidateRange(1,3)][int]$MaximumAttempts = 3
    )
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $lastTransportFailure=$null
    $attemptDiagnostics = [Collections.Generic.List[object]]::new()
    for ($attempt=1; $attempt -le $MaximumAttempts -and [DateTimeOffset]::UtcNow -lt $deadline; $attempt++) {
        $diagnostic = [ordered]@{
            attempt = $attempt
            connect_ms = $null
            listener_owner_ms = $null
            ping_ms = $null
            post_ping_owner_ms = $null
            outcome = $null
            error_type = $null
        }
        & $ProcessCheck
        $remaining=($deadline-[DateTimeOffset]::UtcNow).TotalSeconds
        if ($remaining -le 0) { break }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $client=Connect-RenoiseDriver -Session $Session -TimeoutSeconds $remaining -ProcessCheck $ProcessCheck
        }
        catch {
            $timer.Stop()
            $diagnostic.connect_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
            $diagnostic.outcome = 'connect_failed'
            $diagnostic.error_type = $_.Exception.GetType().FullName
            $attemptDiagnostics.Add([pscustomobject]$diagnostic)
            $failure = $_.Exception
            $failure.Data['bootstrap_attempt_diagnostics'] = @($attemptDiagnostics)
            throw
        }
        $timer.Stop()
        $diagnostic.connect_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
        $timer.Restart()
        try {
            Assert-RenoiseListenerOwner -Client $client -Identity $Identity -GetListeners $GetListeners -CheckIdentity $CheckIdentity
        }
        catch {
            $timer.Stop()
            $diagnostic.listener_owner_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
            $diagnostic.outcome = 'listener_owner_failed'
            $diagnostic.error_type = $_.Exception.GetType().FullName
            $client.Dispose()
            $attemptDiagnostics.Add([pscustomobject]$diagnostic)
            $_.Exception.Data['bootstrap_attempt_diagnostics'] = @($attemptDiagnostics)
            throw
        }
        $timer.Stop()
        $diagnostic.listener_owner_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
        $pingTimeout=[Math]::Min($CommandTimeoutSeconds,($deadline-[DateTimeOffset]::UtcNow).TotalSeconds)
        if ($pingTimeout -le 0) {
            $client.Dispose()
            $diagnostic.outcome = 'startup_budget_expired_before_ping'
            $attemptDiagnostics.Add([pscustomobject]$diagnostic)
            break
        }
        $timer.Restart()
        try {
            $ping=Invoke-RenoiseDriverRequest -Client $client -Session $Session -Operation 'ping' -Arguments @{} -TimeoutSeconds $pingTimeout -ProcessCheck $ProcessCheck
        }
        catch {
            $timer.Stop()
            $diagnostic.ping_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
            $diagnostic.outcome = 'ping_failed'
            $diagnostic.error_type = $_.Exception.GetType().FullName
            $failure=$_.Exception
            $client.Dispose()
            $attemptDiagnostics.Add([pscustomobject]$diagnostic)
            $failure.Data['bootstrap_attempt_diagnostics'] = @($attemptDiagnostics)
            if (-not (Test-RenoiseTransportFailure -Exception $failure) -and
                $failure -isnot [TimeoutException]) { throw }
            $lastTransportFailure=$failure
            if ($attempt -ge $MaximumAttempts -or [DateTimeOffset]::UtcNow -ge $deadline) { break }
            continue
        }
        $timer.Stop()
        $diagnostic.ping_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
        $timer.Restart()
        try {
            Assert-RenoiseListenerOwner -Client $client -Identity $Identity -GetListeners $GetListeners -CheckIdentity $CheckIdentity
        }
        catch {
            $timer.Stop()
            $diagnostic.post_ping_owner_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
            $diagnostic.outcome = 'post_ping_listener_owner_failed'
            $diagnostic.error_type = $_.Exception.GetType().FullName
            $attemptDiagnostics.Add([pscustomobject]$diagnostic)
            $client.Dispose()
            $_.Exception.Data['bootstrap_attempt_diagnostics'] = @($attemptDiagnostics)
            throw
        }
        $timer.Stop()
        $diagnostic.post_ping_owner_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 1)
        $diagnostic.outcome = 'passed'
        $attemptDiagnostics.Add([pscustomobject]$diagnostic)
        return [pscustomobject]@{Client=$client;Ping=$ping;Attempts=$attempt;AttemptDiagnostics=@($attemptDiagnostics)}
    }
    $diagnosticText = ($attemptDiagnostics | ForEach-Object {
        $parts = [Collections.Generic.List[string]]::new()
        foreach ($stage in @('connect_ms', 'listener_owner_ms', 'ping_ms', 'post_ping_owner_ms')) {
            if ($null -ne $_.$stage) { $parts.Add($stage.Replace('_ms', '') + '=' + $_.$stage + 'ms') }
        }
        if ($_.error_type) { $parts.Add('error=' + $_.error_type) }
        'attempt ' + $_.attempt + ' ' + $_.outcome + ': ' + ($parts -join ', ')
    }) -join '; '
    $diagnosticSuffix = if ($diagnosticText) { ' Bootstrap attempts: ' + $diagnosticText } else { '' }
    if ($lastTransportFailure) {
        $lastTransportFailure.Data['bootstrap_attempt_diagnostics'] = @($attemptDiagnostics)
        if ($lastTransportFailure -is [TimeoutException]) {
            $diagnosticFailure = [TimeoutException]::new($lastTransportFailure.Message + $diagnosticSuffix, $lastTransportFailure)
            $diagnosticFailure.Data['bootstrap_attempt_diagnostics'] = @($attemptDiagnostics)
            throw $diagnosticFailure
        }
        throw $lastTransportFailure
    }
    throw [TimeoutException]::new("Timed out after $StartupTimeoutSeconds seconds completing the Renoise authenticated startup ping.$diagnosticSuffix")
}

function Invoke-RenoiseDriverRequest {
    param(
        [Parameter(Mandatory)][Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][double]$TimeoutSeconds,
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
        if ($Client.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $Client.Client.Available -eq 0) {
            throw [IO.EndOfStreamException]::new('Renoise closed the transport before returning a terminal response.')
        }
        if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 50; continue }
        $buffer = [byte[]]::new(4096)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { throw [IO.EndOfStreamException]::new('Renoise closed the transport before returning a terminal response.') }
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
    throw [TimeoutException]::new("Timed out after $TimeoutSeconds seconds waiting for terminal response to '$Operation'.")
}

function Get-RenoiseProcessIdentity {
    param(
        [Parameter(Mandatory)][int]$Id,
        [ValidateRange(0,10000)][int]$WaitMilliseconds = 0,
        [scriptblock]$ReadProcess = { param($ProcessId) Get-Process -Id $ProcessId -ErrorAction Stop }
    )
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($WaitMilliseconds)
    do {
        $process = & $ReadProcess $Id
        if (-not [string]::IsNullOrWhiteSpace($process.Path)) {
            $path = [IO.Path]::GetFullPath($process.Path)
            $start = $process.StartTime.ToUniversalTime()
            return [pscustomobject]@{ Id = $process.Id; Path = $path; StartTimeUtc = $start; SessionId = $process.SessionId }
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Executable path is unavailable for process $Id." }
        Start-Sleep -Milliseconds 25
    } while ($true)
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

function Get-AcidKeyboardConfiguration {
    param([Parameter(Mandatory)][object]$Environment)
    $keyboard = if ($Environment.PSObject.Properties['Keyboard']) { $Environment.Keyboard } else { $null }
    if ($keyboard -isnot [Collections.IDictionary]) {
        throw 'Keyboard mapping is missing: set TestEnvironment.Keyboard.ShowShortcut to the shortcut assigned to Global:ACID:Show in Renoise Preferences > Keys. The runner will not edit the keymap.'
    }
    foreach ($key in $keyboard.Keys) {
        if ($key -cnotin @('ShowShortcut','AutoHotkeyPath','TimeoutSeconds')) {
            throw "Unsupported TestEnvironment.Keyboard property '$key'."
        }
    }
    $shortcut = if ($keyboard.Contains('ShowShortcut')) { [string]$keyboard['ShowShortcut'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($shortcut)) {
        throw 'Keyboard mapping is missing: set TestEnvironment.Keyboard.ShowShortcut to the shortcut assigned to Global:ACID:Show in Renoise Preferences > Keys. The runner will not edit the keymap.'
    }
    if ($shortcut.Length -gt 128 -or $shortcut -cnotmatch '^[A-Za-z0-9\^!+#{}]+$') {
        throw 'TestEnvironment.Keyboard.ShowShortcut must be a 1–128 character AutoHotkey v2 key sequence.'
    }
    $timeoutSeconds = 10
    if ($keyboard.Contains('TimeoutSeconds')) {
        $value = $keyboard['TimeoutSeconds']
        if ($value -is [bool] -or ($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 30) {
            throw 'TestEnvironment.Keyboard.TimeoutSeconds must be an integer from 1 to 30.'
        }
        $timeoutSeconds = $value
    }
    $autoHotkeyPath = if ($keyboard.Contains('AutoHotkeyPath')) { [string]$keyboard['AutoHotkeyPath'] } else { '' }
    return [pscustomobject]@{
        ShowShortcut = $shortcut
        AutoHotkeyPath = $autoHotkeyPath
        TimeoutSeconds = $timeoutSeconds
    }
}

function Find-AutoHotkeyV2Executable {
    param([string]$ConfiguredPath)
    if ($ConfiguredPath) {
        if (-not (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf)) {
            throw "Configured AutoHotkey executable does not exist: $ConfiguredPath"
        }
        return [IO.Path]::GetFullPath($ConfiguredPath)
    }
    foreach ($name in @('AutoHotkey64.exe','AutoHotkey.exe')) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return [IO.Path]::GetFullPath($command.Source) }
    }
    throw 'AutoHotkey v2 was not found. Install AutoHotkey v2 or set TestEnvironment.Keyboard.AutoHotkeyPath; Native runs do not require it.'
}

function Invoke-AcidKeyboardHelper {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$HelperScript,
        [ValidateSet('Send','Version','SelfTestWrongPid','SelfTestFocusMismatch')][string]$Mode = 'Send',
        [int]$ProcessId = 0,
        [string]$Keys,
        [Parameter(Mandatory)][scriptblock]$ProcessCheck,
        [switch]$AllowFocusActivation,
        [ValidateRange(1,30)][int]$TimeoutSeconds = 5
    )
    if ($Mode -eq 'Send') {
        if ($ProcessId -le 0) { throw 'Keyboard input requires the explicitly selected Renoise process ID.' }
        if ([string]::IsNullOrEmpty($Keys)) { throw 'Keyboard input sequence cannot be empty.' }
        & $ProcessCheck
    }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "AutoHotkey executable does not exist: $Executable" }
    if (-not (Test-Path -LiteralPath $HelperScript -PathType Leaf)) { throw "AutoHotkey helper does not exist: $HelperScript" }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [IO.Path]::GetFullPath($Executable)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add([IO.Path]::GetFullPath($HelperScript))
    switch ($Mode) {
        'Version' { $startInfo.ArgumentList.Add('--version') }
        'SelfTestWrongPid' {
            $startInfo.ArgumentList.Add('--self-test')
            $startInfo.ArgumentList.Add('wrong-pid')
        }
        'SelfTestFocusMismatch' {
            if ($ProcessId -le 0) { throw 'Focus-mismatch self-test requires a selected Renoise PID.' }
            & $ProcessCheck
            $startInfo.ArgumentList.Add('--self-test')
            $startInfo.ArgumentList.Add('focus-mismatch')
            $startInfo.ArgumentList.Add('--pid')
            $startInfo.ArgumentList.Add([string]$ProcessId)
        }
        'Send' {
            $startInfo.ArgumentList.Add('--pid')
            $startInfo.ArgumentList.Add([string]$ProcessId)
            $startInfo.ArgumentList.Add('--keys')
            $startInfo.ArgumentList.Add($Keys)
            $startInfo.ArgumentList.Add('--focus-timeout')
            $startInfo.ArgumentList.Add([string]$TimeoutSeconds)
            if ($AllowFocusActivation) { $startInfo.ArgumentList.Add('--allow-activation') }
        }
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { throw 'Could not start AutoHotkey.' }
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $processDeadlineSeconds = $TimeoutSeconds + 3
        if (-not $process.WaitForExit($processDeadlineSeconds * 1000)) {
            try { $process.Kill($true) } catch {}
            throw "AutoHotkey helper timed out after $processDeadlineSeconds seconds (focus budget $TimeoutSeconds seconds)."
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult().Trim()
            StdErr = $stderrTask.GetAwaiter().GetResult().Trim()
        }
    }
    finally { $process.Dispose() }
}

function Wait-AcidObservedState {
    param(
        [Parameter(Mandatory)][scriptblock]$ReadState,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][scriptblock]$ProcessCheck,
        [ValidateRange(1,60)][int]$TimeoutSeconds = 10,
        [ValidateRange(10,1000)][int]$PollMilliseconds = 100
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastState = $null
    try {
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            & $ProcessCheck
            $remainingSeconds = [Math]::Max(1, [Math]::Ceiling($TimeoutSeconds - $clock.Elapsed.TotalSeconds))
            $lastState = & $ReadState $remainingSeconds
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            if (& $Condition $lastState) { return $lastState }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
    finally { $clock.Stop() }
    throw "Timed out after $TimeoutSeconds seconds waiting for the observed condition. Last state: $(ConvertTo-Json -InputObject $lastState -Compress -Depth 4)"
}

function Invoke-AcidKeyboardJourney {
    param(
        [Parameter(Mandatory)][Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$HelperScript,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][scriptblock]$ProcessCheck,
        [switch]$AllowFocusActivation,
        [ValidateRange(1,300)][int]$CommandTimeoutSeconds = 10
    )
    $stateReadTimeout = [Math]::Min($CommandTimeoutSeconds, $Configuration.TimeoutSeconds)
    $readGuiState = ({
        param([int]$ReadTimeoutSeconds = $stateReadTimeout)
        Invoke-RenoiseDriverRequest -Client $Client -Session $Session -Operation 'gui.state' -Arguments @{} -TimeoutSeconds ([Math]::Min($ReadTimeoutSeconds, $CommandTimeoutSeconds)) -ProcessCheck $ProcessCheck
    }).GetNewClosure()
    $readSongSnapshot = ({
        param([int]$ReadTimeoutSeconds = $stateReadTimeout)
        Invoke-RenoiseDriverRequest -Client $Client -Session $Session -Operation 'song.snapshot' -Arguments @{} -TimeoutSeconds ([Math]::Min($ReadTimeoutSeconds, $CommandTimeoutSeconds)) -ProcessCheck $ProcessCheck
    }).GetNewClosure()
    $keyboardActions = [Collections.Generic.List[object]]::new()
    $sendKeys = ({
        param([string]$Keys, [string]$Action)
        $sendResult = Invoke-AcidKeyboardHelper -Executable $Executable -HelperScript $HelperScript -Mode Send -ProcessId $ProcessId -Keys $Keys -ProcessCheck $ProcessCheck -AllowFocusActivation:$AllowFocusActivation -TimeoutSeconds ([Math]::Min(30, $Configuration.TimeoutSeconds))
        if ($sendResult.ExitCode -ne 0) {
            $message = if ($sendResult.StdErr) { $sendResult.StdErr } else { $sendResult.StdOut }
            throw "Keyboard action '$Action' was refused or failed (exit $($sendResult.ExitCode)): $message"
        }
        $keyboardActions.Add([pscustomobject]@{ action = $Action; keys = $Keys; output = $sendResult.StdOut })
    }).GetNewClosure()
    $waitCondition = ({
        param([scriptblock]$Condition)
        Wait-AcidObservedState -ReadState $readGuiState -Condition $Condition -ProcessCheck $ProcessCheck -TimeoutSeconds $Configuration.TimeoutSeconds
    }).GetNewClosure()

    $state = & $readGuiState
    if ($null -eq $state.show_invocations -or $state.show_invocations -lt 0) {
        throw 'Keyboard development driver did not expose a valid ACID Show invocation count.'
    }
    if ($state.show_keybinding_registered -ne $true) {
        throw 'ACID has not registered the production Global:ACID:Show keybinding in the selected Renoise process.'
    }
    if ($state.dialog_visible) {
        & $sendKeys '{Esc}' 'close pre-existing ACID dialog'
        $closed = & $waitCondition { param($observed) $observed.dialog_visible -eq $false }
        if ($closed.dialog_visible) { throw 'ACID dialog remained visible after Escape.' }
    }

    try {
        Wait-AcidObservedState -ReadState $readGuiState -Condition { param($observed) $false } -ProcessCheck $ProcessCheck -TimeoutSeconds 1 -PollMilliseconds 50
        throw 'The observed-state timeout guard unexpectedly accepted an impossible condition.'
    }
    catch {
        if ($_.Exception.Message -notmatch '^Timed out after \d+ seconds waiting for the observed condition\.') { throw }
    }

    $showInvocationsBeforeShortcut = [int]$state.show_invocations
    & $sendKeys $Configuration.ShowShortcut 'open ACID with the configured shortcut'
    try {
        $visible = & $waitCondition {
            param($observed)
            $observed.dialog_visible -eq $true -and $observed.show_invocations -gt $showInvocationsBeforeShortcut
        }
    }
    catch {
        $sentActions = @($keyboardActions | ForEach-Object { "$($_.action) [$($_.keys)]: $($_.output)" }) -join '; '
        throw "ACID Show shortcut did not open the dialog after [$sentActions]: $($_.Exception.Message)"
    }
    if (-not $visible.dialog_visible) { throw 'Configured shortcut did not open the ACID dialog.' }

    & $sendKeys '{Esc}' 'close ACID dialog before native instrument navigation'
    $closed = & $waitCondition { param($observed) $observed.dialog_visible -eq $false }
    if ($closed.dialog_visible) { throw 'ACID dialog remained visible before native instrument navigation.' }

    $setup = Invoke-RenoiseDriverRequest -Client $Client -Session $Session -Operation 'song.prepare_instrument_navigation' -Arguments @{} -TimeoutSeconds $CommandTimeoutSeconds -ProcessCheck $ProcessCheck
    if ($setup.instrument_count -lt 2) { throw 'Instrument navigation setup did not produce two instruments.' }
    $before = & $readSongSnapshot
    $startIndex = [int]$before.selected_instrument_index
    $instrumentCount = [int]$before.instrument_count
    if ($instrumentCount -lt 2 -or $startIndex -lt 1 -or $startIndex -gt $instrumentCount) {
        throw 'Song snapshot returned an invalid instrument selection for native navigation.'
    }
    if ($startIndex -lt $instrumentCount) {
        $navigationKeys = '!{Down}'
        $navigationName = 'Alt+Down'
        $expectedIndex = $startIndex + 1
    }
    else {
        $navigationKeys = '!{Up}'
        $navigationName = 'Alt+Up'
        $expectedIndex = $startIndex - 1
    }
    & $sendKeys $navigationKeys "native $navigationName instrument navigation"
    $selection = Wait-AcidObservedState -ReadState $readSongSnapshot -Condition { param($observed) $observed.selected_instrument_index -eq $expectedIndex } -ProcessCheck $ProcessCheck -TimeoutSeconds $Configuration.TimeoutSeconds
    if ($selection.selected_instrument_index -ne $expectedIndex) {
        throw 'Native instrument navigation readback did not match the expected selection.'
    }

    return [pscustomobject]@{
        dialog_open_observed = $true
        dialog_closed_observed = $true
        shortcut = $Configuration.ShowShortcut
        navigation = $navigationName
        instrument_count = $instrumentCount
        selected_instrument_before = $startIndex
        selected_instrument_after = [int]$selection.selected_instrument_index
        keyboard_actions = @($keyboardActions)
        show_invocations = [int]$visible.show_invocations
        gui_timeout_guard = 'PASS'
    }
}

function Get-AcidScenarioCatalog {
    param([Parameter(Mandatory)][string]$Directory)
    $pathPattern = '^[A-Za-z_][A-Za-z0-9_]*(\.(?:[A-Za-z_][A-Za-z0-9_]*|\d+))*$'
    $topLevelKeys = @('name','fixture','assertions','description','preconditions','expects','expected_diffs','actions','waits','unchanged')
    $scenarios = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File | Sort-Object Name) {
        $scenario = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        if ($scenario -isnot [Collections.IDictionary] -or
            -not $scenario.Contains('name') -or $scenario['name'] -isnot [string] -or $scenario['name'] -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or
            -not $scenario.Contains('fixture') -or $scenario['fixture'] -isnot [string] -or $scenario['fixture'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.xrns$' -or
            -not $scenario.Contains('assertions') -or $scenario['assertions'] -isnot [array] -or $scenario['assertions'].Count -eq 0 -or
            -not $scenario.Contains('actions') -or -not $scenario.Contains('waits') -or
            -not $scenario.Contains('unchanged') -or
            $scenario['actions'] -isnot [array] -or $scenario['waits'] -isnot [array] -or
            $scenario['unchanged'] -isnot [array] -or $scenario['unchanged'].Count -eq 0) {
            throw "Scenario definition is malformed: $($file.Name)"
        }
        foreach ($key in @($scenario.Keys)) {
            if ($key -cnotin $topLevelKeys) { throw "Scenario definition contains an unknown key '$key': $($file.Name)" }
        }
        if ($scenario.Contains('description') -and $scenario.description -isnot [string]) {
            throw "Scenario description must be a string: $($file.Name)"
        }
        $requiredActions = @('document.new','fixture.load','song.snapshot','song.snapshot')
        $requiredWaits = @('document.changed','inventory.settled','snapshot.stable')
        if (($scenario.actions -join "`n") -cne ($requiredActions -join "`n")) {
            throw "Scenario actions must use the fixed read-only sequence: $($file.Name)"
        }
        if (($scenario.waits -join "`n") -cne ($requiredWaits -join "`n")) {
            throw "Scenario waits must use the fixed native observation sequence: $($file.Name)"
        }
        if (-not $scenario.Contains('preconditions') -or $scenario.preconditions -isnot [Collections.IDictionary]) {
            throw "Scenario inventory wait requires a preconditions object: $($file.Name)"
        }

        $expects = 'pass'
        if ($scenario.Contains('expects')) {
            if ($scenario.expects -isnot [string] -or $scenario.expects -cnotin @('pass','fail')) {
                throw "Scenario expects must be 'pass' or 'fail': $($file.Name)"
            }
            $expects = $scenario.expects
        }

        if ($scenario.Contains('preconditions')) {
            $preconditions = $scenario.preconditions
            if ($preconditions -isnot [Collections.IDictionary]) {
                throw "Scenario preconditions must be an object: $($file.Name)"
            }
            foreach ($key in @($preconditions.Keys)) {
                if ($key -cnotin @('instrument_count','phrase_count')) {
                    throw "Scenario precondition contains an unknown key '$key': $($file.Name)"
                }
                $value = $preconditions[$key]
                if ($value -is [bool] -or ($value -isnot [int] -and $value -isnot [long]) -or [long]$value -lt 0) {
                    throw "Scenario precondition '$key' must be a non-negative integer: $($file.Name)"
                }
            }
        }

        if ($scenario.Contains('expected_diffs')) {
            if ($expects -cne 'fail') {
                throw "Scenario expected_diffs is only allowed when expects is 'fail': $($file.Name)"
            }
            if ($scenario.expected_diffs -isnot [array] -or $scenario.expected_diffs.Count -eq 0) {
                throw "Scenario expected_diffs must be a non-empty array: $($file.Name)"
            }
            foreach ($diff in $scenario.expected_diffs) {
                if ($diff -isnot [Collections.IDictionary] -or
                    @($diff.Keys | Where-Object { $_ -cnotin @('path','expected','actual') }).Count -gt 0 -or
                    -not $diff.Contains('path') -or -not $diff.Contains('expected') -or -not $diff.Contains('actual') -or
                    $diff.path -isnot [string] -or $diff.path -cnotmatch $pathPattern) {
                    throw "Scenario expected diff is malformed: $($file.Name)"
                }
            }
        } elseif ($expects -ceq 'fail') {
            throw "Scenario expects 'fail' requires non-empty expected_diffs: $($file.Name)"
        }

        foreach ($assertion in $scenario.assertions) {
            if ($assertion -isnot [Collections.IDictionary] -or
                $assertion.path -isnot [string] -or $assertion.path -cnotmatch $pathPattern -or
                -not $assertion.Contains('expected')) {
                throw "Scenario assertion is malformed: $($file.Name)"
            }
        }
        $assertionPaths = @($scenario.assertions | ForEach-Object { [string]$_.path })
        if (@($assertionPaths | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
            throw "Scenario assertion paths must be unique: $($file.Name)"
        }
        if ($expects -ceq 'fail') {
            $expectedDiffPaths = @($scenario.expected_diffs | ForEach-Object { [string]$_.path })
            if (@($expectedDiffPaths | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
                throw "Scenario expected diff paths must be unique: $($file.Name)"
            }
        }
        foreach ($path in $scenario.unchanged) {
            if ($path -isnot [string] -or $path -cnotmatch $pathPattern) {
                throw "Scenario unchanged path is malformed: $($file.Name)"
            }
        }
        $unchangedPaths = @($scenario.unchanged | ForEach-Object { [string]$_ })
        if (@($unchangedPaths | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
            throw "Scenario unchanged paths must be unique: $($file.Name)"
        }
        $scenario['expects'] = $expects
        $scenario.source_path = $file.FullName
        $scenarios.Add($scenario)
    }
    $duplicates = @($scenarios | Group-Object { $_.name } | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) { throw "Scenario names must be unique: $($duplicates[0].Name)" }
    return ,$scenarios.ToArray()
}

function Get-AcidInteractiveScenarioSelection {
    param(
        [string]$Scenario,
        [Parameter(Mandatory)][string]$Directory
    )
    if ($Scenario -ceq 'transport') { return }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Native scenario catalog 'tests/renoise/acid/scenarios' is missing; the fixture set is required for the interactive suite."
    }
    $catalog = Get-AcidScenarioCatalog -Directory $Directory
    if ($catalog.Count -eq 0 -and -not $Scenario) {
        throw 'Native scenario catalog is empty; a Native run cannot pass without a registered scenario.'
    }
    if ($Scenario) {
        $selected = @($catalog | Where-Object { $_.name -ceq $Scenario })
        if ($selected.Count -eq 0) {
            $names = @($catalog | ForEach-Object { [string]$_.name })
            throw "Scenario '$Scenario' is not registered. Available: $((@('transport') + $names) -join ', ')"
        }
        return $selected
    }
    return @($catalog | Sort-Object { $_.name })
}

function Assert-AcidScenarioFixtures {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][object[]]$Scenarios)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Staged fixture directory is missing: $Directory"
    }
    $fixtureNames = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fixtureFile in Get-ChildItem -LiteralPath $Directory -Filter '*.xrns' -File) {
        if ($fixtureNames.ContainsKey($fixtureFile.Name)) {
            throw "Staged fixture names are ambiguous: '$($fixtureNames[$fixtureFile.Name])' and '$($fixtureFile.Name)'"
        }
        $fixtureNames.Add($fixtureFile.Name, $fixtureFile.Name)
    }
    foreach ($scenario in $Scenarios) {
        $fixture = [string](Get-AcidScenarioProperty $scenario 'fixture')
        if (-not $fixtureNames.ContainsKey($fixture)) {
            throw "Scenario '$(Get-AcidScenarioProperty $scenario 'name')' requires missing staged fixture '$fixture'."
        }
    }
    return $fixtureNames.Count
}

function Get-AcidSnapshotPathValue {
    param([Parameter(Mandatory)][object]$Snapshot, [Parameter(Mandatory)][string]$Path)
    $value = $Snapshot
    foreach ($segment in $Path.Split('.')) {
        if ($segment -match '^\d+$') {
            $index = [int]$segment
            if ($value -isnot [array] -or $index -ge $value.Count) { return [pscustomobject]@{ Found = $false; Value = $null } }
            $value = $value[$index]
        } elseif ($value -is [Collections.IDictionary]) {
            if (-not $value.Contains($segment)) { return [pscustomobject]@{ Found = $false; Value = $null } }
            $value = $value[$segment]
        } elseif ($null -ne $value -and $value.PSObject.Properties[$segment]) {
            $value = $value.$segment
        } else {
            return [pscustomobject]@{ Found = $false; Value = $null }
        }
    }
    return [pscustomobject]@{ Found = $true; Value = $value }
}

function ConvertTo-AcidCanonicalJson {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    $canonical = ConvertTo-AcidCanonicalValue $Value
    return ConvertTo-Json -InputObject $canonical -Depth 64 -Compress
}

function Get-AcidOrdinalSortedStrings {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Values)
    $sorted = [string[]]@($Values)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return ,$sorted
}

function ConvertTo-AcidCanonicalValue {
    param([AllowNull()][object]$Value)
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in (Get-AcidOrdinalSortedStrings -Values @($Value.Keys | ForEach-Object { [string]$_ }))) {
            $ordered[$key] = ConvertTo-AcidCanonicalValue $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [pscustomobject]) {
        $ordered = [ordered]@{}
        $properties = @($Value.PSObject.Properties)
        $propertyNames = Get-AcidOrdinalSortedStrings -Values @($properties | ForEach-Object { [string]$_.Name })
        foreach ($name in $propertyNames) {
            $ordered[$name] = ConvertTo-AcidCanonicalValue $Value.PSObject.Properties[$name].Value
        }
        return $ordered
    }
    if ($Value -is [array]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-AcidCanonicalValue $item)) }
        return ,$items.ToArray()
    }
    return $Value
}

function Compare-AcidScenarioSnapshot {
    param([Parameter(Mandatory)][object]$Scenario, [Parameter(Mandatory)][object]$Snapshot,
          [object[]]$Assertions = $null)
    if ($null -eq $Assertions) { $Assertions = @($Scenario.assertions) }
    $diffs = [Collections.Generic.List[object]]::new()
    foreach ($assertion in $Assertions) {
        $observed = Get-AcidSnapshotPathValue -Snapshot $Snapshot -Path $assertion.path
        $expectedJson = ConvertTo-AcidCanonicalJson $assertion.expected
        $actualJson = if ($observed.Found) { ConvertTo-AcidCanonicalJson $observed.Value } else { '<missing>' }
        if (-not $observed.Found -or $expectedJson -cne $actualJson) {
            $diffs.Add([pscustomobject]@{
                path = $assertion.path
                expected = $assertion.expected
                actual = if ($observed.Found) { $observed.Value } else { '<missing>' }
            })
        }
    }
    return [pscustomobject]@{ passed = ($diffs.Count -eq 0); diff = @($diffs) }
}

function Get-AcidScenarioReportDiff {
    param([Parameter(Mandatory)][object]$Result)
    $observation = Get-AcidScenarioProperty $Result 'observation'
    if (Test-AcidScenarioProperty $observation 'expected_diffs') {
        return [pscustomobject]@{
            expected = @(Get-AcidScenarioProperty $observation 'expected_diffs')
            observed = @(Get-AcidScenarioProperty $observation 'observed_diffs')
        }
    }
    $diff = Get-AcidScenarioProperty $Result 'diff'
    if (@($diff).Count -gt 0) {
        return [pscustomobject]@{ expected = $null; observed = @($diff) }
    }
    return $null
}

function Test-AcidScenarioProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-AcidScenarioProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-AcidTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}

function Test-AcidNonNegativeIntegerValue {
    param([AllowNull()][object]$Value)
    return ($Value -is [int] -or $Value -is [long]) -and $Value -ge 0
}

function Invoke-AcidNativeScenario {
    param(
        [Parameter(Mandatory)][object]$Scenario,
        [Parameter(Mandatory)][scriptblock]$SendRequest,
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [int]$ResetTimeoutSeconds = 120,
        [int]$CommandTimeoutSeconds = 30
    )
    $name = [string](Get-AcidScenarioProperty $Scenario 'name')
    $fixture = [string](Get-AcidScenarioProperty $Scenario 'fixture')
    $expects = if (Test-AcidScenarioProperty $Scenario 'expects') { [string](Get-AcidScenarioProperty $Scenario 'expects') } else { 'pass' }
    $preconditions = if (Test-AcidScenarioProperty $Scenario 'preconditions') { Get-AcidScenarioProperty $Scenario 'preconditions' } else { $null }
    $actions = if (Test-AcidScenarioProperty $Scenario 'actions') { @(Get-AcidScenarioProperty $Scenario 'actions') } else { @('document.new','fixture.load','song.snapshot','song.snapshot') }
    $waits = if (Test-AcidScenarioProperty $Scenario 'waits') {
        @(Get-AcidScenarioProperty $Scenario 'waits')
    } elseif ($null -ne $preconditions) {
        @('document.changed','inventory.settled','snapshot.stable')
    } else {
        @('document.changed','snapshot.stable')
    }
    $unchanged = if (Test-AcidScenarioProperty $Scenario 'unchanged') { @(Get-AcidScenarioProperty $Scenario 'unchanged') } else { @() }
    $diffs = @()
    $observation = [ordered]@{
        document_epoch_initial = $null
        document_epoch_reset = $null
        document_epoch_loaded = $null
        document_epoch_final = $null
        snapshot_sha256 = @()
        preconditions = $preconditions
        actions_executed = @()
        waits_observed = @()
        unchanged_paths = $unchanged
        settled = $false
        failure_reason = $null
    }
    function New-Failure {
        param([string]$Reason)
        $observation.failure_reason = $Reason
        [pscustomobject]@{ name = $name; status = 'FAIL'; expects = $expects; diff = @($diffs); observation = $observation }
    }
    function New-Error {
        param([string]$Reason)
        $observation.failure_reason = $Reason
        [pscustomobject]@{ name = $name; status = 'ERROR'; expects = $expects; diff = @($diffs); observation = $observation }
    }
    try {
        New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
        $requiredWaits = if ($null -ne $preconditions) { "document.changed`ninventory.settled`nsnapshot.stable" } else { "document.changed`nsnapshot.stable" }
        if (($actions -join "`n") -cne "document.new`nfixture.load`nsong.snapshot`nsong.snapshot" -or
            ($waits -join "`n") -cne $requiredWaits) {
            return New-Failure 'scenario action or wait contract is unsupported'
        }

        $initial = & $SendRequest 'diagnostics' @{}
        $epochInitial = Get-AcidScenarioProperty $initial 'document_epoch'
        $observation.document_epoch_initial = $epochInitial
        $initialPending = Get-AcidScenarioProperty $initial 'pending_commands'
        $initialQueued = Get-AcidScenarioProperty $initial 'queued_commands'
        $initialUncertain = Get-AcidScenarioProperty $initial 'document_transition_uncertain'
        if ((Get-AcidScenarioProperty $initial 'document_ready') -ne $true -or
            $initialPending -ne 0 -or $initialQueued -ne 0 -or
            -not ($initialUncertain -is [bool] -and $initialUncertain -eq $false)) {
            return New-Failure 'host not settled'
        }
        if (-not (Test-AcidNonNegativeIntegerValue $epochInitial)) {
            return New-Failure 'initial document epoch is missing or invalid'
        }

        $resetResult = & $SendRequest 'document.new' @{ timeout_ms = $ResetTimeoutSeconds * 1000 }
        $epochReset = Get-AcidScenarioProperty $resetResult 'document_epoch'
        $observation.document_epoch_reset = $epochReset
        if ((Get-AcidScenarioProperty $resetResult 'operation') -cne 'document.new' -or
            -not (Test-AcidNonNegativeIntegerValue $epochReset) -or $epochReset -le $epochInitial) {
            return New-Failure 'new-document reset was not confirmed'
        }
        $observation.actions_executed += 'document.new'

        $loadResult = & $SendRequest 'document.load_fixture' @{
            root = 'fixtures'
            name = $fixture
            timeout_ms = $ResetTimeoutSeconds * 1000
        }
        $epochLoaded = Get-AcidScenarioProperty $loadResult 'document_epoch'
        $observation.document_epoch_loaded = $epochLoaded
        if ((Get-AcidScenarioProperty $loadResult 'operation') -cne 'document.load_fixture' -or
            -not (Test-AcidNonNegativeIntegerValue $epochLoaded) -or $epochLoaded -le $epochReset) {
            return New-Failure 'fixture load did not advance the document epoch'
        }
        $observation.actions_executed += 'fixture.load'
        $observation.waits_observed += 'document.changed'

        if ($null -ne $preconditions -and $preconditions -is [Collections.IDictionary]) {
            $instrumentCount = if ($preconditions.Contains('instrument_count')) { [int]$preconditions['instrument_count'] } else { $null }
            $phraseCount = if ($preconditions.Contains('phrase_count')) { [int]$preconditions['phrase_count'] } else { $null }
            if ($null -eq $instrumentCount -or $null -eq $phraseCount) {
                $inventorySnapshot = & $SendRequest 'song.snapshot' @{}
                if ($null -eq $instrumentCount) {
                    $observedCount = Get-AcidScenarioProperty $inventorySnapshot 'instrument_count'
                    if (-not (Test-AcidNonNegativeIntegerValue $observedCount)) { return New-Failure 'fixture inventory snapshot has a missing or invalid instrument_count' }
                    $instrumentCount = [int]$observedCount
                }
                if ($null -eq $phraseCount) {
                    $observedCount = Get-AcidScenarioProperty $inventorySnapshot 'phrase_count'
                    if (-not (Test-AcidNonNegativeIntegerValue $observedCount)) { return New-Failure 'fixture inventory snapshot has a missing or invalid phrase_count' }
                    $phraseCount = [int]$observedCount
                }
            }
            $inventoryWait = & $SendRequest 'wait.condition' @{
                condition = 'native_inventory_matches'
                instrument_count = $instrumentCount
                phrase_count = $phraseCount
                timeout_ms = 15000
            }
            $waitInstrumentCount = Get-AcidScenarioProperty $inventoryWait 'instrument_count'
            $waitPhraseCount = Get-AcidScenarioProperty $inventoryWait 'phrase_count'
            if ((Get-AcidScenarioProperty $inventoryWait 'condition') -cne 'native_inventory_matches' -or
                -not (Test-AcidNonNegativeIntegerValue $waitInstrumentCount) -or $waitInstrumentCount -ne $instrumentCount -or
                -not (Test-AcidNonNegativeIntegerValue $waitPhraseCount) -or $waitPhraseCount -ne $phraseCount) {
                return New-Failure 'fixture inventory did not match its preconditions'
            }
            $observation.waits_observed += 'inventory.settled'
        }

        $snapshot1 = & $SendRequest 'song.snapshot' @{}
        $observation.actions_executed += 'song.snapshot'
        $canonical1 = ConvertTo-AcidCanonicalJson $snapshot1
        [IO.File]::WriteAllText((Join-Path $ArtifactDirectory ($name + '-snapshot-1.json')), $canonical1, [Text.UTF8Encoding]::new($false))
        $comparison = Compare-AcidScenarioSnapshot -Scenario $Scenario -Snapshot $snapshot1
        $diffs = @($comparison.diff)

        $snapshot2 = & $SendRequest 'song.snapshot' @{}
        $observation.actions_executed += 'song.snapshot'
        $canonical2 = ConvertTo-AcidCanonicalJson $snapshot2
        [IO.File]::WriteAllText((Join-Path $ArtifactDirectory ($name + '-snapshot-2.json')), $canonical2, [Text.UTF8Encoding]::new($false))

        $observation.snapshot_1_sha256 = Get-AcidTextSha256 $canonical1
        $observation.snapshot_2_sha256 = Get-AcidTextSha256 $canonical2
        $observation.snapshot_sha256 = @($observation.snapshot_1_sha256, $observation.snapshot_2_sha256)

        $unchangedDiffs = [Collections.Generic.List[object]]::new()
        foreach ($path in $unchanged) {
            $firstValue = Get-AcidSnapshotPathValue -Snapshot $snapshot1 -Path ([string]$path)
            $secondValue = Get-AcidSnapshotPathValue -Snapshot $snapshot2 -Path ([string]$path)
            $firstCanonical = if ($firstValue.Found) { ConvertTo-AcidCanonicalJson $firstValue.Value } else { '<missing>' }
            $secondCanonical = if ($secondValue.Found) { ConvertTo-AcidCanonicalJson $secondValue.Value } else { '<missing>' }
            if (-not $firstValue.Found -or -not $secondValue.Found -or $firstCanonical -cne $secondCanonical) {
                $unchangedDiffs.Add([pscustomobject]@{
                    path = [string]$path
                    expected = if ($firstValue.Found) { $firstValue.Value } else { '<missing>' }
                    actual = if ($secondValue.Found) { $secondValue.Value } else { '<missing>' }
                })
            }
        }
        if ($unchangedDiffs.Count -gt 0) {
            $diffs = @($unchangedDiffs)
            return New-Failure 'declared unchanged values changed between snapshots'
        }

        if ($canonical1 -cne $canonical2) { return New-Failure 'snapshot instability' }
        $observation.waits_observed += 'snapshot.stable'

        $canUndo = Get-AcidScenarioProperty $snapshot1 'can_undo'
        $canRedo = Get-AcidScenarioProperty $snapshot1 'can_redo'
        $undoRedoing = Get-AcidScenarioProperty $snapshot1 'is_undo_redoing'
        if (-not ($canUndo -is [bool] -and $canUndo -eq $false) -or
            -not ($canRedo -is [bool] -and $canRedo -eq $false) -or
            -not ($undoRedoing -is [bool] -and $undoRedoing -eq $false)) {
            return New-Failure 'read-only inspection created undo history'
        }

        $selectionInstrument1 = Get-AcidScenarioProperty $snapshot1 'selected_instrument_index'
        $selectionInstrument2 = Get-AcidScenarioProperty $snapshot2 'selected_instrument_index'
        $selectionPhrase1 = Get-AcidScenarioProperty $snapshot1 'selected_phrase_index'
        $selectionPhrase2 = Get-AcidScenarioProperty $snapshot2 'selected_phrase_index'
        if ($selectionInstrument1 -ne $selectionInstrument2 -or $selectionPhrase1 -ne $selectionPhrase2) {
            return New-Failure 'selection changed between snapshots'
        }

        $final = & $SendRequest 'diagnostics' @{}
        $finalPending = Get-AcidScenarioProperty $final 'pending_commands'
        $finalQueued = Get-AcidScenarioProperty $final 'queued_commands'
        $finalUncertain = Get-AcidScenarioProperty $final 'document_transition_uncertain'
        $finalEpoch = Get-AcidScenarioProperty $final 'document_epoch'
        $observation.document_epoch_final = $finalEpoch
        if ($finalPending -ne 0 -or $finalQueued -ne 0 -or
            -not ($finalUncertain -is [bool] -and $finalUncertain -eq $false) -or
            -not (Test-AcidNonNegativeIntegerValue $finalEpoch) -or $finalEpoch -ne $epochLoaded) {
            return New-Failure 'diagnostics state leaked between commands'
        }
        $observation.settled = $true

        if ($expects -ceq 'pass') {
            if ($diffs.Count -eq 0) {
                return [pscustomobject]@{ name = $name; status = 'PASS'; expects = $expects; diff = @($diffs); observation = $observation }
            }
            return New-Failure 'assertion diffs observed'
        }

        $expectedDiffs = @(Get-AcidScenarioProperty $Scenario 'expected_diffs')
        $observedSorted = @($diffs | Sort-Object -Property path)
        $expectedSorted = @($expectedDiffs | ForEach-Object {
            [pscustomobject]@{
                path = Get-AcidScenarioProperty $_ 'path'
                expected = Get-AcidScenarioProperty $_ 'expected'
                actual = Get-AcidScenarioProperty $_ 'actual'
            }
        } | Sort-Object -Property path)
        $observation.expected_diffs = @($expectedSorted)
        $observation.observed_diffs = @($observedSorted)
        $matches = ($observedSorted.Count -eq $expectedSorted.Count)
        if ($matches) {
            for ($index = 0; $index -lt $observedSorted.Count; $index++) {
                if ((ConvertTo-AcidCanonicalJson (Get-AcidScenarioProperty $observedSorted[$index] 'path')) -cne (ConvertTo-AcidCanonicalJson (Get-AcidScenarioProperty $expectedSorted[$index] 'path')) -or
                    (ConvertTo-AcidCanonicalJson (Get-AcidScenarioProperty $observedSorted[$index] 'expected')) -cne (ConvertTo-AcidCanonicalJson (Get-AcidScenarioProperty $expectedSorted[$index] 'expected')) -or
                    (ConvertTo-AcidCanonicalJson (Get-AcidScenarioProperty $observedSorted[$index] 'actual')) -cne (ConvertTo-AcidCanonicalJson (Get-AcidScenarioProperty $expectedSorted[$index] 'actual'))) {
                    $matches = $false
                    break
                }
            }
        }
        if ($matches) {
            return [pscustomobject]@{ name = $name; status = 'PASS'; expects = $expects; diff = @($diffs); observation = $observation }
        }
        return New-Failure 'expected diffs did not match observed diffs'
    }
    catch {
        return New-Error ("scenario error: " + $_.Exception.Message)
    }
}

Export-ModuleMember -Function Get-RenoiseExecutable, Get-RenoiseSessionConfig, Connect-RenoiseDriver, Invoke-RenoiseDriverBootstrap, Invoke-RenoiseDriverRequest, Get-RenoiseProcessIdentity, Assert-RenoiseProcessIdentity, Import-RenoiseTestEnvironment, Get-AcidKeyboardConfiguration, Find-AutoHotkeyV2Executable, Invoke-AcidKeyboardHelper, Wait-AcidObservedState, Invoke-AcidKeyboardJourney, Get-AcidScenarioCatalog, Get-AcidInteractiveScenarioSelection, Assert-AcidScenarioFixtures, Get-AcidSnapshotPathValue, ConvertTo-AcidCanonicalJson, Compare-AcidScenarioSnapshot, Get-AcidScenarioReportDiff, Invoke-AcidNativeScenario

function Get-DirectoryHash {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    Assert-DirectoryHasNoReparsePoints -Path $root
    $records = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object { $_.FullName.Substring($root.Length) } | ForEach-Object {
        $relativePath = $_.FullName.Substring($root.Length).TrimStart('\','/').Replace('\','/')
        if ($_.PSIsContainer) {
            [pscustomobject]@{ Path = $relativePath; Kind = 'directory' }
        } else {
            [pscustomobject]@{ Path = $relativePath; Kind = 'file'; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    })
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records | ConvertTo-Json -Compress)))).ToLowerInvariant()
}

function Assert-DirectoryHasNoReparsePoints {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path)
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Directory contains a reparse point or is not a plain directory; refusing recursive removal.'
    }

    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Directory contains a reparse point; refusing recursive removal.'
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
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
    $deploymentStageFixturesPath = Join-Path $deploymentStageRoot 'fixtures'
    foreach ($path in @($deploymentStageRoot, (Join-Path $toolsPath ('.acid-restore-' + $artifactId)), (Join-Path $toolsPath ('.acid-session-restore-' + $artifactId + '.conf')), (Join-Path $toolsPath ('.acid-fixtures-restore-' + $artifactId)))) {
        if (Test-Path -LiteralPath $path) { throw 'A unique temporary deployment path already exists; refusing to reuse it.' }
    }
    New-Item -ItemType Directory -Path $deploymentStageRoot | Out-Null
    Copy-Item -LiteralPath $devToolPath -Destination $deploymentStageToolPath -Recurse
    Copy-Item -LiteralPath $sessionSourcePath -Destination $deploymentStageSessionPath
    Set-UserOnlyFileAcl -Path $deploymentStageSessionPath
    $deploymentStageToolHash = Get-DirectoryHash -Path $deploymentStageToolPath
    $deploymentStageSessionHash = (Get-FileHash -LiteralPath $deploymentStageSessionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($fixturesSourcePath) {
        if (-not (Test-Path -LiteralPath $fixturesSourcePath -PathType Container)) { throw 'Staged native fixtures directory is missing.' }
        Copy-Item -LiteralPath $fixturesSourcePath -Destination $deploymentStageFixturesPath -Recurse
        $deploymentStageFixturesHash = Get-DirectoryHash -Path $deploymentStageFixturesPath
    }
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
    if ($fixturesSourcePath -and (Test-Path -LiteralPath $installedFixturesPath)) {
        $fixturesItem = Get-Item -LiteralPath $installedFixturesPath -Force
        if (($fixturesItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $fixturesItem.PSIsContainer) { throw 'Existing ACID fixtures path is not a plain directory; refusing replacement.' }
        $fixturesBackupPath = Join-Path $artifactRoot 'previous-fixtures'
        Copy-Item -LiteralPath $installedFixturesPath -Destination $fixturesBackupPath -Recurse
        if ((Get-DirectoryHash -Path $installedFixturesPath) -cne (Get-DirectoryHash -Path $fixturesBackupPath)) { throw 'ACID fixtures backup copy did not verify; refusing replacement.' }
        $localBackupFixturesPath = Join-Path $toolsPath ('.acid-fixtures-restore-' + $artifactId)
        Move-Item -LiteralPath $installedFixturesPath -Destination $localBackupFixturesPath
        Add-Trace -Operation 'install.fixtures_backup' -Status 'PASS' -Details @{ backup = 'run artifact directory' }
    }
    $installedDirectoryHash = $deploymentStageToolHash
    $installedSessionHash = $deploymentStageSessionHash
    Move-Item -LiteralPath $deploymentStageToolPath -Destination $installedToolPath
    $toolDeployed = $true
    Move-Item -LiteralPath $deploymentStageSessionPath -Destination $sessionTargetPath
    $sessionDeployed = $true
    if ($fixturesSourcePath) {
        $installedFixturesHash = $deploymentStageFixturesHash
        Move-Item -LiteralPath $deploymentStageFixturesPath -Destination $installedFixturesPath
        $fixturesDeployed = $true
        Add-Trace -Operation 'install.fixtures' -Status 'PASS' -Details @{ target = 'user Renoise Tools fixtures' }
    }
    Add-Trace -Operation 'install.dev_bundle' -Status 'PASS' -Details @{ target = 'version-matched user Renoise Tools' }
    }
}
function Get-RenoiseRestorationOperation {
    return {
        if ($toolDeployed -and $installedToolPath -and (Test-Path -LiteralPath $installedToolPath)) {
            if (-not $installedDirectoryHash -or (Get-DirectoryHash -Path $installedToolPath) -cne $installedDirectoryHash) {
                throw 'Installed ACID files changed during the run; keeping the current directory and restoration backup untouched.'
            }
            Assert-DirectoryHasNoReparsePoints -Path $installedToolPath
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
        if ($fixturesDeployed -and $installedFixturesPath -and (Test-Path -LiteralPath $installedFixturesPath)) {
            if (-not $installedFixturesHash -or (Get-DirectoryHash -Path $installedFixturesPath) -cne $installedFixturesHash) {
                throw 'Installed ACID fixtures changed during the run; keeping the current directory and restoration backup untouched.'
            }
            Assert-DirectoryHasNoReparsePoints -Path $installedFixturesPath
            Remove-Item -LiteralPath $installedFixturesPath -Recurse -Force
        }
        if ($localBackupFixturesPath -and (Test-Path -LiteralPath $localBackupFixturesPath)) {
            if (Test-Path -LiteralPath $installedFixturesPath) { throw 'ACID fixtures target is occupied; keeping the same-volume original and verified run backup untouched.' }
            Move-Item -LiteralPath $localBackupFixturesPath -Destination $installedFixturesPath
        }
        if ($deploymentStageRoot -and (Test-Path -LiteralPath $deploymentStageRoot)) {
            $stageToolExists = Test-Path -LiteralPath $deploymentStageToolPath -PathType Container
            $stageSessionExists = Test-Path -LiteralPath $deploymentStageSessionPath -PathType Leaf
            $stageFixturesExists = $deploymentStageFixturesPath -and (Test-Path -LiteralPath $deploymentStageFixturesPath -PathType Container)
            if (($stageToolExists -and (Get-DirectoryHash -Path $deploymentStageToolPath) -cne $deploymentStageToolHash) -or
                ($stageSessionExists -and (Get-FileHash -LiteralPath $deploymentStageSessionPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $deploymentStageSessionHash) -or
                ($stageFixturesExists -and (-not $deploymentStageFixturesHash -or (Get-DirectoryHash -Path $deploymentStageFixturesPath) -cne $deploymentStageFixturesHash))) {
                throw 'Staged ACID files changed; preserving the staging directory for recovery.'
            }
            Assert-DirectoryHasNoReparsePoints -Path $deploymentStageRoot
            Remove-Item -LiteralPath $deploymentStageRoot -Recurse -Force
        }
        if ($installedToolPath) { Add-Trace -Operation 'install.restore' -Status 'PASS' -Details @{ original_installation_restored = $true } }
    }
}
Export-ModuleMember -Function Get-DirectoryHash, Assert-DirectoryHasNoReparsePoints, Assert-RenoiseListenerOwner, Get-RenoiseDeploymentOperation, Get-RenoiseRestorationOperation

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
