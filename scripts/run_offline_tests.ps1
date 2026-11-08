#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$LuaCommand = 'lua'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = Get-Command -Name 'pwsh' -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'tool_discovery.psm1') -Force
$discovery = Get-DiscoveredTools -RepositoryRoot $repoRoot
$tools = @($discovery.Tools | Sort-Object Name)

$commonChecks = @(
    [pscustomobject]@{ Name = 'Lua interpreter policy'; Script = 'tests/lua_interpreter_spec.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Lua specs'; Script = 'scripts/run_tests.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Release package'; Script = 'tests/package_license_spec.ps1'; Arguments = @() }
    [pscustomobject]@{ Name = 'Tool discovery regression'; Script = 'tests/tool_discovery_spec.ps1'; Arguments = @('-LuaCommand', $LuaCommand) }
    [pscustomobject]@{ Name = 'Offline runner regression'; Script = 'tests/offline_runner_spec.ps1'; Arguments = @() }
)
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Invoke-OfflineCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Arguments = @()
    )

    $scriptPath = Join-Path $repoRoot $Script
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Offline check '$Name' does not exist: $Script"
    }

    Write-Host "==> $Script"
    & $pwsh.Source -NoProfile -File $scriptPath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $failures.Add("$Name (exit $exitCode)")
        return
    }
    $script:passed++
}

Push-Location $repoRoot
try {
    foreach ($check in $commonChecks) {
        Invoke-OfflineCheck -Name $check.Name -Script $check.Script -Arguments $check.Arguments
    }

    foreach ($tool in $tools) {
        if ([string]::IsNullOrWhiteSpace($tool.OfflinePath)) { continue }
        $offlinePath = Join-Path $repoRoot $tool.OfflinePath
        $offlineScript = [System.IO.Path]::GetRelativePath($repoRoot, $offlinePath).Replace('\', '/')
        Invoke-OfflineCheck -Name "$($tool.Name) offline checks" -Script $offlineScript -Arguments @('-LuaCommand', $LuaCommand)
    }
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
finally {
    Pop-Location
}

if ($failures.Count -gt 0) {
    Write-Error ("Offline checks failed: " + ($failures -join ', ')) -ErrorAction Continue
    exit 1
}

Write-Host "$passed offline check groups passed."
