#Requires -Version 7.0
param([string]$LuaCommand = 'lua')
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

$lua = Resolve-LuaInterpreter -LuaCommand $LuaCommand
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporary = Join-Path $root ('tmp/lua-runner-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $spec = Join-Path $temporary 'isolated spec.lua'
    [IO.File]::WriteAllText($spec, 'io.stdout:write("out"); io.stderr:write("err"); os.exit(7)')
    $result = Invoke-LuaSpec -LuaSource $lua.Source -SpecPath $spec -WorkingDirectory $root -TimeoutSeconds 5
    if ($result.TimedOut -or $result.ExitCode -ne 7 -or $result.Output -notmatch 'out' -or $result.ErrorOutput -notmatch 'err') {
        throw 'Isolated runner lost output, stderr, exit status or path quoting.'
    }
    [IO.File]::WriteAllText($spec, 'for i=1,10000 do io.stdout:write("out\n"); io.stderr:write("err\n") end')
    $result = Invoke-LuaSpec -LuaSource $lua.Source -SpecPath $spec -WorkingDirectory $root -TimeoutSeconds 5
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or $result.Output.Length -lt 40000 -or $result.ErrorOutput.Length -lt 40000) {
        throw 'Verbose output deadlocked or was truncated.'
    }
    [IO.File]::WriteAllText($spec, 'while true do end')
    $result = Invoke-LuaSpec -LuaSource $lua.Source -SpecPath $spec -WorkingDirectory $root -TimeoutSeconds 1
    if (-not $result.TimedOut -or $result.Seconds -gt 5) { throw 'Runaway spec was not stopped promptly.' }
    if (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue) { throw 'Timed-out spec process survived cancellation.' }
    if ($IsWindows) {
        $wrapper = Join-Path $temporary 'forward interpreter.cmd'
        [IO.File]::WriteAllText($wrapper, "@echo off`r`ncall `"$($lua.Source)`" %*`r`nexit /b %errorlevel%`r`n")
        [IO.File]::WriteAllText($spec, 'io.stdout:write("out"); io.stderr:write("err"); os.exit(7)')
        $result = Invoke-LuaSpec -LuaSource $wrapper -SpecPath $spec -WorkingDirectory $root -TimeoutSeconds 5
        if ($result.TimedOut -or $result.OutputIncomplete -or $result.ExitCode -ne 7 -or $result.Output.Trim() -ne 'out' -or $result.ErrorOutput.Trim() -ne 'err') {
            throw 'Forwarding command wrapper lost arguments, output or exit status.'
        }
        $missing = Join-Path $temporary 'missing interpreter.cmd'
        $result = Invoke-LuaSpec -LuaSource $missing -SpecPath $spec -WorkingDirectory $root -TimeoutSeconds 5
        if ($result.TimedOut -or $result.ExitCode -eq 0) { throw 'Missing interpreter did not fail promptly.' }
    }
    Write-Host 'Isolated Lua output, wrapper, failure and timeout checks passed.'
}
finally { [IO.Directory]::Delete($temporary, $true) }
