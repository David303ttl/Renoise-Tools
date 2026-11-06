#Requires -Version 7.0
param([string]$LuaCommand = 'lua')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$runner = Join-Path $repoRoot 'scripts/run_tests.ps1'
$bootstrap = Join-Path $repoRoot 'tests/bootstrap.lua'
$discoveryModule = Join-Path $repoRoot 'scripts/tool_discovery.psm1'
Import-Module $discoveryModule -Force
$luaHelper = Join-Path $repoRoot 'scripts/lua_interpreter.ps1'
. $luaHelper
$lua = Resolve-LuaInterpreter -LuaCommand $LuaCommand
$current = Get-DiscoveredTools -RepositoryRoot $repoRoot
$currentAcid = Get-DiscoveredTool -Discovery $current -Name 'ACID'
$currentAllCount = @($current.Tools | ForEach-Object { $_.Specs } | Where-Object { $null -ne $_ }).Count + $current.HostSpecs.Count
if ($currentAllCount -lt 71 -or $currentAcid.Specs.Count + $current.HostSpecs.Count -ne 63 -or
    $current.HostSpecs.Count -ne 5) {
    throw "Existing suite selection changed: All=$currentAllCount, ACID=$($currentAcid.Specs.Count + $current.HostSpecs.Count), Renoise=$($current.HostSpecs.Count)."
}
$fixture = Join-Path $repoRoot ('tmp/tool-discovery-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)

function New-FixtureTool([string]$Name, [string]$ModuleValue, [string[]]$SpecPaths) {
    $rootName = "com.example.$Name.xrnx"
    $toolRoot = Join-Path $fixture $rootName
    [void][IO.Directory]::CreateDirectory($toolRoot)
    [IO.File]::WriteAllText((Join-Path $toolRoot 'manifest.xml'), '<manifest />')
    [IO.File]::WriteAllText((Join-Path $toolRoot 'main.lua'), 'return true')
    [IO.File]::WriteAllText((Join-Path $toolRoot 'same.lua'), "return '$ModuleValue'")
    $testRoot = Join-Path (Join-Path $fixture 'tests') $Name.ToLowerInvariant()
    [void][IO.Directory]::CreateDirectory($testRoot)
    [IO.File]::WriteAllText((Join-Path $testRoot 'config.lua'), "return { runtime_root = `"$rootName`" }")
    foreach ($specPath in $SpecPaths) {
        $fullSpecPath = Join-Path $testRoot $specPath
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fullSpecPath))
        $luaName = $Name.ToLowerInvariant()
        [IO.File]::WriteAllText($fullSpecPath, "dofile('tests/bootstrap.lua')('$luaName')`nassert(require('same') == '$ModuleValue')")
    }
}

function Invoke-Runner([string]$SelectedTool = 'All') {
    $output = @(& $pwsh -NoProfile -File $runner -RepositoryRoot $fixture -Tool $SelectedTool -LuaCommand $lua.Source 2>&1 | ForEach-Object { $_.ToString() })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output -join "`n" }
}

try {
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'tests'))
    [IO.File]::Copy($bootstrap, (Join-Path (Join-Path $fixture 'tests') 'bootstrap.lua'))
    New-FixtureTool -Name 'Alpha' -ModuleValue 'alpha' -SpecPaths @('one_spec.lua', 'nested/two_spec.lua')
    New-FixtureTool -Name 'Beta' -ModuleValue 'beta' -SpecPaths @('three_spec.lua')
    New-FixtureTool -Name 'Empty' -ModuleValue 'empty' -SpecPaths @()
    New-FixtureTool -Name 'ACID' -ModuleValue 'acid' -SpecPaths @('acid_spec.lua')
    $hostRoot = Join-Path (Join-Path $fixture 'tests') 'renoise'
    [void][IO.Directory]::CreateDirectory($hostRoot)
    [IO.File]::WriteAllText((Join-Path $hostRoot 'host_spec.lua'), 'assert(true)')

    $result = Invoke-Runner
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'Completed 5 specs' -or $result.Output -notmatch '5 Lua specs passed') {
        throw "Synthetic discovered tools did not execute all nested, host and overlapping-module specs:`n$($result.Output)"
    }
    if ($result.Output -notmatch 'Skipping Empty: no automated Lua specs') {
        throw 'All did not report the discovered tool without a Lua suite.'
    }
    $result = Invoke-Runner 'Empty'
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'no automated Lua specs') {
        throw 'Selecting a discovered tool without specs did not fail clearly.'
    }
    $result = Invoke-Runner 'Missing'
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'Unknown tool selector') {
        throw 'Unknown tool selector did not fail clearly.'
    }
    $result = Invoke-Runner 'ACID'
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'Completed 2 specs' -or $result.Output -notmatch 'tests/renoise/host_spec.lua') {
        throw "ACID selection did not retain the host suite relationship:`n$($result.Output)"
    }

    $configPath = Join-Path (Join-Path (Join-Path $fixture 'tests') 'alpha') 'config.lua'
    $invalidCases = @(
        @{ Text = 'return { runtime_root = '; Diagnostic = 'must use:' },
        @{ Text = 'return "not a table"'; Diagnostic = 'must use:' },
        @{ Text = 'RETURN { runtime_root = "com.example.Alpha.xrnx" }'; Diagnostic = 'must use:' },
        @{ Text = 'return { RUNTIME_ROOT = "com.example.Alpha.xrnx" }'; Diagnostic = 'must use:' },
        @{ Text = 'return { runtime_root = "com.example.Alpha.xrnx'' }'; Diagnostic = 'must use:' },
        @{ Text = 'return { runtime_root = "../escape.xrnx" }'; Diagnostic = 'invalid runtime_root' }
    )
    foreach ($invalidCase in $invalidCases) {
        $invalidConfig = $invalidCase.Text
        [IO.File]::WriteAllText($configPath, $invalidConfig)
        $result = Invoke-Runner 'Alpha'
        if ($result.ExitCode -eq 0 -or $result.Output -notmatch [regex]::Escape($invalidCase.Diagnostic)) {
            throw "Invalid config was accepted or had an unexpected diagnostic: $invalidConfig`n$($result.Output)"
        }
    }
    [IO.File]::WriteAllText($configPath, 'return { runtime_root = "com.example.Alpha.xrnx" }')
    Remove-Item -LiteralPath $configPath
    $result = Invoke-Runner 'Alpha'
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'missing.*config.lua') { throw 'Missing tool config did not fail clearly.' }
    [IO.File]::WriteAllText($configPath, 'return { runtime_root = "com.example.Alpha.xrnx" }')
    [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $fixture 'tests') 'beta') 'config.lua'), 'return { runtime_root = "com.example.Alpha.xrnx" }')
    $result = Invoke-Runner
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'points to') { throw 'Mismatched runtime_root was accepted.' }
    [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $fixture 'tests') 'beta') 'config.lua'), 'return { runtime_root = "com.example.Beta.xrnx" }')

    $orphan = Join-Path (Join-Path $fixture 'tests') 'orphan'
    [void][IO.Directory]::CreateDirectory($orphan)
    $result = Invoke-Runner
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'Orphaned test directory') { throw 'Orphaned test directory was accepted.' }
    [IO.Directory]::Delete($orphan, $true)

    $duplicateRoot = Join-Path $fixture 'com.other.Alpha.xrnx'
    [void][IO.Directory]::CreateDirectory($duplicateRoot)
    [IO.File]::WriteAllText((Join-Path $duplicateRoot 'manifest.xml'), '<manifest />')
    [IO.File]::WriteAllText((Join-Path $duplicateRoot 'main.lua'), 'return true')
    $result = Invoke-Runner
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'Ambiguous tool roots') { throw 'Ambiguous tool roots were accepted.' }
    [IO.Directory]::Delete($duplicateRoot, $true)

    New-FixtureTool -Name 'All' -ModuleValue 'reserved' -SpecPaths @()
    $result = Invoke-Runner
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'reserved for test suite selection') {
        throw 'A tool root using the reserved All selector was accepted.'
    }

    Write-Host 'Tool discovery, configuration validation, nested specs and module isolation checks passed.'
}
finally {
    if (Test-Path -LiteralPath $fixture) { [IO.Directory]::Delete($fixture, $true) }
}
