#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/lua_interpreter.ps1')

foreach ($version in @('Lua 5.1', 'Lua 5.2', 'Lua 5.3', 'Lua 5.4', 'Lua 5.5', 'Lua 5.10', 'Lua 6.0')) {
    Assert-LuaLanguageVersion -Version $version
}
foreach ($version in @('Lua 5.0', 'Lua 4.1', 'Lua 4.9', 'LuaJIT 2.1', '', 'Lua 5.4 extra')) {
    $rejected = $false
    try { Assert-LuaLanguageVersion -Version $version }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Unexpectedly accepted _VERSION '$version'." }
}
# LuaJIT exposes Lua 5.1 through _VERSION, rather than its own banner.
Assert-LuaLanguageVersion -Version 'Lua 5.1'
Write-Host 'Lua minimum-version policy checks passed.'
