#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-HostContext {
    param([string]$RenoiseExe, [int]$RenoiseProcessId = 0)
    $selected = @()
    if ($RenoiseProcessId -gt 0) {
        $process = Get-Process -Id $RenoiseProcessId -ErrorAction Stop
        $selected = @([pscustomobject]@{
            Id = $process.Id
            Path = $process.Path
            StartTimeUtc = $process.StartTime.ToUniversalTime()
        })
    }
    [pscustomobject]@{
        RenoiseProductVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($RenoiseExe).ProductVersion
        RenoiseProcesses = $selected
    }
}

function Test-RenoiseHostPreflightCore {
    param([pscustomobject]$Configuration, [pscustomobject]$Context)
    $errors = [Collections.Generic.List[string]]::new()
    try {
        $exe = [IO.Path]::GetFullPath($Configuration.RenoiseExe)
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Executable not found: $exe" }
        $version = [regex]::Match([string]$Context.RenoiseProductVersion, '\d+\.\d+\.\d+')
        if (-not $version.Success -or [version]$version.Value -lt [version]'3.5.0') { throw 'Renoise 3.5 or newer is required.' }
        $selectedId = [int]$Configuration.RenoiseProcessId
        if ($selectedId -lt 0) { throw 'RenoiseProcessId must be zero or a positive PID.' }
        if ($selectedId -gt 0) {
            $selected = @($Context.RenoiseProcesses | Where-Object { $_.Id -eq $selectedId })
            if ($selected.Count -ne 1 -or -not $selected[0].StartTimeUtc -or
                -not [string]::Equals([IO.Path]::GetFullPath($selected[0].Path), $exe, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Selected PID does not match the Renoise executable and start time.'
            }
        }
        $temp = [IO.Path]::GetFullPath($Configuration.TemporaryDirectory)
        if (-not (Test-Path -LiteralPath $temp -PathType Container)) { throw "Temporary directory not found: $temp" }
        $probe = Join-Path $temp ('.renoise-preflight-' + [guid]::NewGuid().ToString('N'))
        try { [IO.File]::WriteAllText($probe, '') }
        finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe } }
    }
    catch { $errors.Add($_.Exception.Message) }
    [pscustomobject]@{
        Passed = $errors.Count -eq 0
        Mode = $Configuration.Mode
        # Readiness does not grant permission to replace a song or installation.
        ExecutionAuthorized = $false
        InstallReplacementAuthorized = $errors.Count -eq 0
        Errors = @($errors)
    }
}

function Test-RenoiseHostPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Configuration,
          [ValidateSet('Execution','Safety')][string]$Mode = 'Safety')
    try {
        $selectedId = if ($Configuration.PSObject.Properties['RenoiseProcessId']) { [int]$Configuration.RenoiseProcessId } else { 0 }
        $context = Get-HostContext -RenoiseExe $Configuration.RenoiseExe -RenoiseProcessId $selectedId
        $core = [pscustomobject]@{
            RenoiseExe = $Configuration.RenoiseExe
            TemporaryDirectory = $Configuration.TemporaryDirectory
            RenoiseProcessId = $selectedId
            Mode = $Mode
        }
        Test-RenoiseHostPreflightCore -Configuration $core -Context $context
    }
    catch {
        [pscustomobject]@{ Passed = $false; Mode = $Mode; ExecutionAuthorized = $false; InstallReplacementAuthorized = $false; Errors = @($_.Exception.Message) }
    }
}

Export-ModuleMember -Function Test-RenoiseHostPreflight
