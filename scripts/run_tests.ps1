#Requires -Version 7.0

<#
.SYNOPSIS
Runs the standalone Lua specs for one or all Renoise tools.

.DESCRIPTION
Discovers root .xrnx tools and matching test suites. Starts every spec in a
separate Lua process from the repository root to isolate module caches and mocks.

.PARAMETER Tool
Select a discovered tool, Renoise, or All (the default). ACID also includes the
reserved Renoise host suite. Tools without specs are skipped by All and fail
when selected directly.

.PARAMETER LuaCommand
Executable command used to run specs. Defaults to lua.

.PARAMETER SpecTimeoutSeconds
Maximum runtime for each isolated spec, including interpreter startup. Defaults
to 30 seconds. Optimize expensive fixtures instead of masking them with a larger limit.

.EXAMPLE
./scripts/run_tests.ps1

.EXAMPLE
./scripts/run_tests.ps1 -Tool ACID -LuaCommand lua5.1

.PARAMETER RepositoryRoot
Repository root to scan. Intended for isolated discovery regressions.
#>
param(
    [string]$Tool = "All",
    [string]$LuaCommand = "lua",
    [ValidateRange(1, 3600)]
    [int]$SpecTimeoutSeconds = 30,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
$repoRoot = if ($RepositoryRoot) { [IO.Path]::GetFullPath($RepositoryRoot) } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'lua_interpreter.ps1')
$lua = Resolve-LuaInterpreter -LuaCommand $LuaCommand
Import-Module (Join-Path $PSScriptRoot 'tool_discovery.psm1') -Force
$discovery = Get-DiscoveredTools -RepositoryRoot $repoRoot
$specs = @()
if ($Tool -ieq 'All') {
    foreach ($untested in @($discovery.Tools | Where-Object { $_.Specs.Count -eq 0 })) {
        Write-Host "Skipping $($untested.Name): no automated Lua specs."
    }
    $specs = @($discovery.Tools | Where-Object { $_.Specs.Count -gt 0 } | ForEach-Object { $_.Specs }) + @($discovery.HostSpecs)
}
elseif ($Tool -ieq 'Renoise') {
    $specs = @($discovery.HostSpecs)
}
else {
    $selected = Get-DiscoveredTool -Discovery $discovery -Name $Tool
    if ($selected.Specs.Count -eq 0) { throw "Tool '$($selected.Name)' has no automated Lua specs." }
    $specs = @($selected.Specs)
    if ($selected.Name -ieq 'ACID') { $specs += @($discovery.HostSpecs) }
}
$specs = @($specs | Sort-Object FullName -Unique)

if ($specs.Count -eq 0) {
    throw "No Lua specs found for '$Tool' under the selected test roots."
}

$failed = [System.Collections.Generic.List[string]]::new()
$total = [Diagnostics.Stopwatch]::StartNew()
foreach ($spec in $specs) {
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $spec.FullName).Replace('\', '/')
    Write-Host "==> $relativePath"
    $result = Invoke-LuaSpec -LuaSource $lua.Source -SpecPath $relativePath `
        -WorkingDirectory $repoRoot -TimeoutSeconds $SpecTimeoutSeconds
    if ($result.Output) { Write-Host $result.Output.TrimEnd() }
    if ($result.ErrorOutput) { Write-Host $result.ErrorOutput.TrimEnd() }
    if ($result.TimedOut) {
        Write-Host ('    TIMEOUT after {0:F2}s; process tree stopped' -f $result.Seconds)
        $failed.Add("$relativePath (timeout after ${SpecTimeoutSeconds}s; process tree stopped)")
    }
    elseif ($result.OutputIncomplete) {
        Write-Host ('    FAIL in {0:F2}s (output pipe did not close)' -f $result.Seconds)
        $failed.Add("$relativePath (output pipe did not close)")
    }
    elseif ($result.ExitCode -ne 0) {
        Write-Host ('    FAIL in {0:F2}s (exit {1})' -f $result.Seconds, $result.ExitCode)
        $failed.Add("$relativePath (exit $($result.ExitCode))")
    }
    else { Write-Host ('    PASS in {0:F2}s' -f $result.Seconds) }
}
Write-Host ('Completed {0} specs in {1:F2}s; {2} failed.' -f $specs.Count, $total.Elapsed.TotalSeconds, $failed.Count)

if ($failed.Count -gt 0) {
    Write-Error ("Lua specs failed: " + ($failed -join ", ")) -ErrorAction Continue
    exit 1
}

Write-Host "$($specs.Count) Lua specs passed (selection: $Tool)."
