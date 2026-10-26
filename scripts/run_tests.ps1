#Requires -Version 7.0

<#
.SYNOPSIS
Runs the standalone Lua specs for one or all Renoise tools.

.DESCRIPTION
Starts every spec in a separate Lua process from the repository root. This
keeps module caches and mocked Renoise APIs isolated between specs.

.PARAMETER Tool
Select ARP, ACID, or All (the default). DigitaktSampleChain currently has no
automated Lua specs; selecting it reports that clearly.

.PARAMETER LuaCommand
Executable command used to run specs. Defaults to lua.

.EXAMPLE
./scripts/run_tests.ps1

.EXAMPLE
./scripts/run_tests.ps1 -Tool ACID -LuaCommand lua5.1
#>
param(
    [ValidateSet("All", "ARP", "ACID", "DigitaktSampleChain")]
    [string]$Tool = "All",
    [string]$LuaCommand = "lua"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$lua = Get-Command $LuaCommand -ErrorAction SilentlyContinue
if (-not $lua) {
    throw "Lua command '$LuaCommand' was not found. Install Lua or pass -LuaCommand with its executable name."
}

if ($Tool -eq "DigitaktSampleChain") {
    throw "DigitaktSampleChain has no automated Lua specs. Select ARP, ACID, or All."
}

$toolNames = if ($Tool -eq "All") { @("arp", "acid") } else { @($Tool.ToLowerInvariant()) }
$specs = @(
    foreach ($toolName in $toolNames) {
        Get-ChildItem (Join-Path $repoRoot "tests/$toolName") -Filter "*_spec.lua" -File
    }
) | Sort-Object FullName

if ($specs.Count -eq 0) {
    throw "No Lua specs found for '$Tool' under tests/arp or tests/acid."
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
