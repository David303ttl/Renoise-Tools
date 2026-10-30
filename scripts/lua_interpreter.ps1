#Requires -Version 7.0

function Assert-LuaLanguageVersion {
    param([string]$Version)

    if ($Version -notmatch '^Lua (\d+)\.(\d+)$') {
        throw "Cannot determine Lua language version from _VERSION: $Version."
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 5 -or ($major -eq 5 -and $minor -lt 1)) {
        throw "Lua 5.1 or newer is required; _VERSION reports $Version."
    }
}

function Resolve-LuaInterpreter {
    param([string]$LuaCommand = 'lua')

    $command = Get-Command -Name $LuaCommand -CommandType Application -ErrorAction Stop
    $probe = Invoke-LuaSpec -LuaSource $command.Source -Arguments @('-e', 'print(_VERSION)') `
        -WorkingDirectory (Get-Location).Path -TimeoutSeconds 5
    $version = $probe.Output.Trim()
    if ($probe.TimedOut -or $probe.OutputIncomplete -or $probe.ExitCode -ne 0) {
        throw "Cannot query _VERSION for '$LuaCommand': $version $($probe.ErrorOutput) (exit $($probe.ExitCode), timeout $($probe.TimedOut))."
    }
    Assert-LuaLanguageVersion -Version $version
    Write-Host "Lua interpreter: $($command.Source) ($version)"
    return [pscustomobject]@{ Source = $command.Source; Version = $version }
}

function Invoke-LuaSpec {
    param(
        [Parameter(Mandatory)][string]$LuaSource,
        [string]$SpecPath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    if ($SpecPath) { $Arguments = @($SpecPath) + @($Arguments) }
    if ($IsWindows -and [IO.Path]::GetExtension($LuaSource) -in @('.cmd', '.bat')) {
        $start.FileName = (Get-Process -Id $PID).Path
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand')) {
            $start.ArgumentList.Add($argument)
        }
        $command = '$ErrorActionPreference="Stop"; $arguments=@(ConvertFrom-Json $env:RENOISE_TEST_ARGUMENTS); & $env:RENOISE_TEST_LUA @arguments; if ($null -eq $LASTEXITCODE) { exit 127 }; exit $LASTEXITCODE'
        $start.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
        $start.Environment['RENOISE_TEST_LUA'] = $LuaSource
        $start.Environment['RENOISE_TEST_ARGUMENTS'] = ConvertTo-Json -InputObject @($Arguments) -Compress
    }
    else {
        $start.FileName = $LuaSource
        foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        # Drain both pipes concurrently so verbose failures cannot deadlock.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            try { $process.Kill($true) }
            catch { if (-not $process.HasExited) { throw } }
        }
        if (-not $process.WaitForExit(1000)) { throw 'Spec process did not terminate after cancellation.' }
        $drained = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 1000)
        $errorOutput = if ($stderr.IsCompletedSuccessfully) { $stderr.Result } else { '' }
        if (-not $drained) { $errorOutput += 'Spec output did not close after process termination; incomplete output is unavailable.' }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            ProcessId = $process.Id
            TimedOut = $timedOut
            OutputIncomplete = -not $drained
            Output = $(if ($stdout.IsCompletedSuccessfully) { $stdout.Result } else { '' })
            ErrorOutput = $errorOutput
            Seconds = $clock.Elapsed.TotalSeconds
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true) }
            catch { if (-not $process.HasExited) { Write-Warning "Could not terminate spec process $($process.Id): $_" } }
            [void]$process.WaitForExit(1000)
        }
        $process.Dispose()
    }
}
