#Requires -Version 7.0

<#
.SYNOPSIS
Runs the standalone Lua specs for one or all Renoise tools.

.DESCRIPTION
Starts every spec in a separate Lua process from the repository root. This
keeps module caches and mocked Renoise APIs isolated between specs.

.PARAMETER Tool
Select ARP, ACID, Renoise, or All (the default). ACID also includes the offline
Renoise harness specs. DigitaktSampleChain currently has no automated Lua
specs; selecting it reports that clearly.

.PARAMETER LuaCommand
Executable command used to run specs. Defaults to lua.

.PARAMETER SpecTimeoutSeconds
Maximum runtime for each isolated spec, including interpreter startup. Defaults
to 30 seconds. Optimize expensive fixtures instead of masking them with a larger limit.

.EXAMPLE
./scripts/run_tests.ps1

.EXAMPLE
./scripts/run_tests.ps1 -Tool ACID -LuaCommand lua5.1
#>
param(
    [ValidateSet("All", "ARP", "ACID", "Renoise", "DigitaktSampleChain")]
    [string]$Tool = "All",
    [string]$LuaCommand = "lua",
    [ValidateRange(1, 3600)]
    [int]$SpecTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lua_interpreter.ps1')
$lua = Resolve-LuaInterpreter -LuaCommand $LuaCommand

if ($Tool -eq "DigitaktSampleChain") {
    throw "DigitaktSampleChain has no automated Lua specs. Select ARP, ACID, Renoise, or All."
}

$specRoots = switch ($Tool) {
    "All" { @("tests/arp", "tests/acid", "tests/renoise") }
    "ARP" { @("tests/arp") }
    "ACID" { @("tests/acid", "tests/renoise") }
    "Renoise" { @("tests/renoise") }
}
$specs = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($specRoot in $specRoots) {
    $rootPath = Join-Path $repoRoot $specRoot
    $recurse = $specRoot -eq "tests/renoise"
    foreach ($spec in Get-ChildItem -LiteralPath $rootPath -Filter "*_spec.lua" -File -Recurse:$recurse) {
        $specs.Add($spec)
    }
}
$specs = @($specs | Sort-Object FullName)

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
