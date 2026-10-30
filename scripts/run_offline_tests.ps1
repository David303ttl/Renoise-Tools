#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$LuaCommand = 'lua'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = Get-Command -Name 'pwsh' -ErrorAction Stop
$checks = @(
    [pscustomobject]@{ Name = 'Lua interpreter policy'; Script = 'tests/lua_interpreter_spec.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Lua specs'; Script = 'scripts/run_tests.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Host preflight'; Script = 'scripts/test_host_preflight.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Renoise runner'; Script = 'tests/renoise/runner_spec.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Development package'; Script = 'tests/renoise/test_package_dev.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Release package'; Script = 'tests/package_license_spec.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Audio analyzer'; Script = 'tests/acid/test_audio_analyzer.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Audio normalization'; Script = 'tests/acid/test_audio_normalization.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Audio oracle'; Script = 'tests/acid/test_audio_oracle.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Host lifecycle cases'; Script = 'tests/acid/test_host_lifecycle_cases.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Moving repeat glide protocols'; Script = 'tests/acid/test_moving_repeat_glide_protocols.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Native effect edge protocols'; Script = 'tests/acid/test_native_effect_edge_protocols.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Repeat seam analyzer'; Script = 'tests/acid/test_repeat_seam_analyzer.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Successor gate analyzer'; Script = 'tests/acid/test_successor_gate_analyzer.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Accent response'; Script = 'tests/acid/accent_response_spec.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Audio oracle validation'; Script = 'tests/acid/validate_audio_oracle.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Loop oracle validation'; Script = 'tests/acid/validate_loop_oracle.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Reference tempo validation'; Script = 'tests/acid/validate_reference_tempo_cases.ps1'; Arguments = @() }
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
    Write-Error ("Offline checks failed: " + ($failures -join ', ')) -ErrorAction Continue
    exit 1
}

Write-Host "$($checks.Count) offline check groups passed."
