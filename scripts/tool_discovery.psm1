function Get-DiscoveredTools {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $toolsRoot = [IO.DirectoryInfo]::new($root)
    $toolDirectories = @(Get-ChildItem -LiteralPath $toolsRoot.FullName -Directory -Filter '*.xrnx' | Sort-Object Name)
    $byName = @{}
    foreach ($directory in $toolDirectories) {
        if ($directory.Name -notmatch '^.+\.([A-Za-z0-9][A-Za-z0-9_-]*)\.xrnx$') {
            throw "Tool root '$($directory.Name)' must follow the <publisher>.<tool>.xrnx convention."
        }
        $name = $Matches[1]
        if ($name -in @('All', 'Renoise')) { throw "Tool name '$name' is reserved for test suite selection." }
        foreach ($entry in @('main.lua', 'manifest.xml')) {
            if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName $entry) -PathType Leaf)) {
                throw "Tool root '$($directory.Name)' is missing '$entry'."
            }
        }
        $key = $name.ToLowerInvariant()
        if ($byName.ContainsKey($key)) {
            throw "Ambiguous tool roots '$($byName[$key].Root)' and '$($directory.Name)' both identify tool '$name'."
        }
        $byName[$key] = [pscustomobject]@{
            Name = $name
            Root = $directory.Name
            TestRoot = Join-Path 'tests' $name.ToLowerInvariant()
            ConfigPath = Join-Path (Join-Path 'tests' $name.ToLowerInvariant()) 'config.lua'
            OfflinePath = $null
            Directory = $directory
            Specs = @()
        }
    }

    $testsRoot = Join-Path $root 'tests'
    if (-not (Test-Path -LiteralPath $testsRoot -PathType Container)) {
        throw "Test root '$testsRoot' does not exist."
    }
    foreach ($testDirectory in Get-ChildItem -LiteralPath $testsRoot -Directory | Sort-Object Name) {
        if ($testDirectory.Name -ieq 'renoise') { continue }
        $key = $testDirectory.Name.ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) {
            throw "Orphaned test directory 'tests/$($testDirectory.Name)' has no matching root .xrnx tool."
        }
        $tool = $byName[$key]
        $specs = @(Get-ChildItem -LiteralPath $testDirectory.FullName -Filter '*_spec.lua' -File -Recurse | Sort-Object FullName)
        $tool.Specs = $specs
        if ($specs.Count -gt 0) {
            if ($testDirectory.Name -cne $tool.Name.ToLowerInvariant()) {
                throw "Test directory '$($testDirectory.Name)' must use the canonical lowercase tool name '$($tool.Name.ToLowerInvariant())'."
            }
            if (-not (Test-Path -LiteralPath (Join-Path $testDirectory.FullName 'config.lua') -PathType Leaf)) {
                throw "Tool '$($tool.Name)' has Lua specs but is missing '$($tool.ConfigPath)'."
            }
            Assert-ToolConfig -ConfigPath (Join-Path $testDirectory.FullName 'config.lua') -ExpectedRuntimeRoot $tool.Root
        }
        $offlinePath = Join-Path $testDirectory.FullName 'offline.ps1'
        if (Test-Path -LiteralPath $offlinePath -PathType Leaf) { $tool.OfflinePath = Join-Path $tool.TestRoot 'offline.ps1' }
    }

    $hostRoot = Join-Path $testsRoot 'renoise'
    $hostSpecs = @()
    if (Test-Path -LiteralPath $hostRoot -PathType Container) {
        $hostSpecs = @(Get-ChildItem -LiteralPath $hostRoot -Filter '*_spec.lua' -File -Recurse | Sort-Object FullName)
    }

    [pscustomobject]@{
        Tools = @($byName.Values | Sort-Object Name)
        HostTestRoot = 'tests/renoise'
        HostSpecs = $hostSpecs
    }
}

function Assert-ToolConfig {
    param([string]$ConfigPath, [string]$ExpectedRuntimeRoot)

    $contents = Get-Content -LiteralPath $ConfigPath -Raw
    $pattern = '^\s*return\s*\{\s*runtime_root\s*=\s*(?<quote>["''])(?<root>[^"'']+)\k<quote>\s*,?\s*\}\s*(?:--[^\r\n]*)?$'
    if ($contents -cnotmatch $pattern) {
        throw "Tool config '$ConfigPath' must use: return { runtime_root = '<matching .xrnx root>' }. A trailing comma is allowed."
    }
    $runtimeRoot = $Matches.root
    if ($runtimeRoot -notmatch '^[A-Za-z0-9_.-]+\.xrnx$' -or $runtimeRoot -match '(^|\.)\.($|\.)') {
        throw "Tool config '$ConfigPath' has an invalid runtime_root '$runtimeRoot'."
    }
    if ($runtimeRoot -cne $ExpectedRuntimeRoot) {
        throw "Tool config '$ConfigPath' points to '$runtimeRoot'; expected '$ExpectedRuntimeRoot'."
    }
}

function Resolve-DiscoveredTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Discovery,
        [Parameter(Mandatory)][string]$Name
    )
    $tool = @($Discovery.Tools | Where-Object { $_.Name -ieq $Name })
    if ($tool.Count -ne 1) { throw "Unknown tool selector '$Name'." }
    $tool[0]
}

function Get-DiscoveredTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Discovery,
        [Parameter(Mandatory)][string]$Name
    )
    Resolve-DiscoveredTool -Discovery $Discovery -Name $Name
}

Export-ModuleMember -Function Get-DiscoveredTools, Get-DiscoveredTool, Resolve-DiscoveredTool
