#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$LuaCommand = 'lua'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = Get-Command -Name 'pwsh' -ErrorAction Stop
$checks = @(
    [pscustomobject]@{ Name = 'Lua interpreter policy'; Script = 'tests/lua_interpreter_spec.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Lua specs'; Script = 'scripts/run_tests.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Host preflight'; Script = 'scripts/test_host_preflight.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Renoise runner'; Script = 'tests/renoise/runner_spec.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Development package'; Script = 'tests/renoise/test_package_dev.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Release package'; Script = 'tests/package_license_spec.ps1'; Arguments = @() }
)
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($check in $checks) {
    $scriptPath = Join-Path $repoRoot $check.Script
    Write-Host "==> $($check.Script)"
    $childArguments = @('-NoProfile', '-File', $scriptPath) + @($check.Arguments)
    & $pwsh.Source @childArguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $failures.Add("$($check.Name) (exit $exitCode)")
    }
}

if ($failures.Count -gt 0) {
    Write-Error ("Offline checks failed: " + ($failures -join ', '))
    exit 1
}

Write-Host "$($checks.Count) offline check groups passed."
