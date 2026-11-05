#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$LuaCommand = 'lua'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pwsh = Get-Command -Name 'pwsh' -ErrorAction Stop
$checks = @(
    [pscustomobject]@{ Name = 'Host preflight'; Script = 'scripts/test_host_preflight.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Renoise runner'; Script = 'tests/renoise/runner_spec.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Development package'; Script = 'tests/renoise/test_package_dev.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Loop oracle validation'; Script = 'tests/acid/validate_loop_oracle.ps1'; Arguments = @() }
)
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

Push-Location $repoRoot
try {
    foreach ($check in $checks) {
        $scriptPath = Join-Path $repoRoot $check.Script
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Offline check '$($check.Name)' does not exist: $($check.Script)"
        }

        Write-Host "==> $($check.Script)"
        $childArguments = @('-NoProfile', '-File', $scriptPath) + $check.Arguments
        & $pwsh.Source @childArguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $failures.Add("$($check.Name) (exit $exitCode)")
        }
        else {
            $passed++
        }
    }
}
finally {
    Pop-Location
}

if ($failures.Count -gt 0) {
    Write-Error ("ACID offline checks failed: " + ($failures -join ', ')) -ErrorAction Continue
    exit 1
}

Write-Host "$passed ACID offline check groups passed."
