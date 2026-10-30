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

.EXAMPLE
./scripts/run_tests.ps1

.EXAMPLE
./scripts/run_tests.ps1 -Tool ACID -LuaCommand lua5.1
#>
param(
    [ValidateSet("All", "ARP", "ACID", "Renoise", "DigitaktSampleChain")]
    [string]$Tool = "All",
    [string]$LuaCommand = "lua"
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

$previousLocation = Get-Location
$failed = [System.Collections.Generic.List[string]]::new()
try {
    Set-Location $repoRoot
    foreach ($spec in $specs) {
        $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $spec.FullName).Replace('\', '/')
        Write-Host "==> $relativePath"
        & $lua.Source $relativePath
        if ($LASTEXITCODE -ne 0) {
            $failed.Add("$relativePath (exit $LASTEXITCODE)")
        }
    }
}
finally {
    Set-Location $previousLocation
}

if ($failed.Count -gt 0) {
    Write-Error ("Lua specs failed: " + ($failed -join ", "))
    exit 1
}

Write-Host "$($specs.Count) Lua specs passed (selection: $Tool)."
