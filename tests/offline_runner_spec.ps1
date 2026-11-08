#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('renoise-offline-runner-' + [guid]::NewGuid().ToString('N'))
$logPath = Join-Path $fixtureRoot 'checks.log'
$previousLogPath = $env:OFFLINE_TEST_LOG
$previousFailTool = $env:OFFLINE_TEST_FAIL_TOOL

function Write-FixtureScript {
    param([string]$RelativePath, [string]$Contents)
    $path = Join-Path $fixtureRoot $RelativePath
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Set-Content -LiteralPath $path -Value $Contents -Encoding utf8
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'scripts') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tests') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/run_offline_tests.ps1') -Destination (Join-Path $fixtureRoot 'scripts/run_offline_tests.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/tool_discovery.psm1') -Destination (Join-Path $fixtureRoot 'scripts/tool_discovery.psm1')

    $commonScripts = @{
        'tests/lua_interpreter_spec.ps1' = 'common:interpreter'
        'scripts/run_tests.ps1' = 'common:lua'
        'tests/package_license_spec.ps1' = 'common:release'
        'tests/tool_discovery_spec.ps1' = 'common:tool-discovery'
        'tests/offline_runner_spec.ps1' = 'common:offline-regression'
    }
    foreach ($entry in $commonScripts.GetEnumerator()) {
        $script = "param([string]`$LuaCommand = 'lua')`nAdd-Content -LiteralPath `$env:OFFLINE_TEST_LOG -Value '$($entry.Value)'`nexit 0"
        Write-FixtureScript -RelativePath $entry.Key -Contents $script
    }

    foreach ($toolName in @('alpha', 'zeta', 'acid')) {
        $toolRoot = Join-Path $fixtureRoot "com.example.$($toolName.ToUpperInvariant()).xrnx"
        New-Item -ItemType Directory -Path $toolRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $toolRoot 'main.lua') -Value '-- fixture' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $toolRoot 'manifest.xml') -Value '<tool/>' -Encoding utf8
        if ($toolName -eq 'acid') { continue }
        $toolScript = "param([string]`$LuaCommand = 'lua')`nAdd-Content -LiteralPath `$env:OFFLINE_TEST_LOG -Value 'tool:$toolName'`nif (`$env:OFFLINE_TEST_FAIL_TOOL -eq '$toolName') { exit 7 }`nexit 0"
        Write-FixtureScript -RelativePath "tests/$toolName/offline.ps1" -Contents $toolScript
    }

    foreach ($path in @(
        'tests/renoise/runner_spec.ps1',
        'tests/renoise/test_package_dev.ps1',
        'scripts/test_host_preflight.ps1',
        'tests/acid/validate_loop_oracle.ps1'
    )) {
        $marker = "Add-Content -LiteralPath `$env:OFFLINE_TEST_LOG -Value 'acid-only:$path'`nexit 0"
        Write-FixtureScript -RelativePath $path -Contents $marker
    }

    $env:OFFLINE_TEST_LOG = $logPath
    Remove-Item Env:OFFLINE_TEST_FAIL_TOOL -ErrorAction SilentlyContinue
    $pwsh = Get-Command -Name 'pwsh' -ErrorAction Stop
    $expected = @('common:interpreter', 'common:lua', 'common:release', 'common:tool-discovery', 'common:offline-regression', 'tool:alpha', 'tool:zeta')

    $runnerOutput = & $pwsh.Source -NoProfile -File (Join-Path $fixtureRoot 'scripts/run_offline_tests.ps1') -LuaCommand fixture-lua 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Offline runner returned $LASTEXITCODE for successful entrypoints: $($runnerOutput -join '; ')" }
    $actual = @(Get-Content -LiteralPath $logPath)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw "Unexpected successful-run order or selection. Expected [$($expected -join ', ')], got [$($actual -join ', ')]."
    }

    Remove-Item -LiteralPath $logPath
    $env:OFFLINE_TEST_FAIL_TOOL = 'alpha'
    $runnerOutput = & $pwsh.Source -NoProfile -File (Join-Path $fixtureRoot 'scripts/run_offline_tests.ps1') -LuaCommand fixture-lua 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'Offline runner returned success after a tool entrypoint failed.' }
    $actual = @(Get-Content -LiteralPath $logPath)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw "Unexpected failure-run order or selection. Expected [$($expected -join ', ')], got [$($actual -join ', ')]."
    }

    Write-Host 'Offline runner discovery, ordering, tool isolation, and failure propagation passed.'
}
finally {
    if ($null -eq $previousLogPath) { Remove-Item Env:OFFLINE_TEST_LOG -ErrorAction SilentlyContinue }
    else { $env:OFFLINE_TEST_LOG = $previousLogPath }
    if ($null -eq $previousFailTool) { Remove-Item Env:OFFLINE_TEST_FAIL_TOOL -ErrorAction SilentlyContinue }
    else { $env:OFFLINE_TEST_FAIL_TOOL = $previousFailTool }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
