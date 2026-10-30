#Requires -Version 7.0
[CmdletBinding()]
param(
  [string] $LuaCommand = 'lua'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($env:OS -ne 'Windows_NT') {
  throw 'Package development tests require Windows ACL support.'
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$repoTempRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'tmp'))
$repoTempPrefix = $repoTempRoot.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
$testRoot = Join-Path $repoTempRoot ('renoise-package-dev-spec-日本語-' + [guid]::NewGuid().ToString('N'))
$sourceToolName = 'com.david303ttl.ACID.xrnx'
$runtimeExtensions = @('.lua', '.xml', '.txt', '.json', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.wav', '.aif', '.aiff', '.flac', '.ogg', '.bin')
$bootstrapMarker = '-- ACID development bootstrap'
$luaCommandInfo = Get-Command -Name $LuaCommand -ErrorAction Stop
$luaVersion = (& $luaCommandInfo.Source -v 2>&1 | Out-String).Trim()
if ($luaVersion -notmatch 'Lua 5\.1(?:\.|\s)') {
  throw "Lua 5.1 is required to check generated entrypoint syntax. '$LuaCommand' reported: $luaVersion"
}

function Assert-True {
  param([bool] $Condition, [string] $Message)
  if (-not $Condition) { throw $Message }
}

function Get-RelativePath {
  param([string] $Root, [string] $Path)
  $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "'$Path' is outside '$Root'." }
  return $full.Substring($prefix.Length).Replace('\', '/')
}

function Get-TreeHashes {
  param([string] $Root)
  $hashes = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
    $relative = Get-RelativePath -Root $Root -Path $file.FullName
    if ($relative -match '^tmp(/|$)') { continue }
    $hashes.Add($relative, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
  }
  return $hashes
}

function Get-EntryHash {
  param([System.IO.Compression.ZipArchiveEntry] $Entry)
  $stream = $Entry.Open()
  try { return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
  finally { $stream.Dispose() }
}

function Invoke-PackageDev {
  param([string] $FixtureRoot, [string] $OutputPath, [switch] $TransportOnly)
  $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
  $script = Join-Path $FixtureRoot 'scripts/package_dev.ps1'
  $arguments = @('-NoProfile', '-File', $script, '-Tool', 'ACID', '-OutputDirectory', $OutputPath)
  if ($TransportOnly) { $arguments += '-TransportOnly' }
  $output = @(& $pwsh @arguments 2>&1)
  $exitCode = $LASTEXITCODE
  return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output | Out-String) }
}

function Assert-Lua51Syntax {
  param([string] $MainPath, [string] $Context)
  $previousLocation = Get-Location
  try {
    Set-Location -LiteralPath (Split-Path -Parent $MainPath)
    $checker = @'
local chunk, compile_error = loadfile("main.lua")
if not chunk then
  io.stderr:write(compile_error, "\n")
  os.exit(1)
end
'@
    $output = @($checker | & $luaCommandInfo.Source - 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    Set-Location $previousLocation
  }
  if ($exitCode -ne 0) {
    throw "$Context failed Lua 5.1 syntax validation:$([string][char]10)$($output | Out-String)"
  }
}

function New-FixtureRepository {
  param([string] $Root)
  $sourceToolName = 'com.david303ttl.ACID.xrnx'
  New-Item -ItemType Directory -Path $Root | Out-Null
  $paths = @(
    'scripts'
    'tests/renoise/driver'
    'tests/renoise/fixtures'
    'tests/renoise/acid/fixtures'
    'tests/renoise/acid/scenarios'
    'tests/renoise/keyboard'
    'sdk/example'
    'tmp'
    "$sourceToolName/model"
    "$sourceToolName/data"
  )
  foreach ($relative in $paths) { New-Item -ItemType Directory -Path (Join-Path $Root $relative) -Force | Out-Null }
  Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/package.ps1') -Destination (Join-Path $Root 'scripts/package.ps1')
  Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/package_dev.ps1') -Destination (Join-Path $Root 'scripts/package_dev.ps1')
  Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/renoise/driver/remote_driver.lua') -Destination (Join-Path $Root 'tests/renoise/driver/remote_driver.lua')
  Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/renoise/driver/json.lua') -Destination (Join-Path $Root 'tests/renoise/driver/json.lua')

  $toolRoot = Join-Path $Root $sourceToolName
  $manifest = @'
<?xml version="1.0" encoding="UTF-8"?>
<RenoiseScriptingTool doc_version="0">
  <ApiVersion>6.2</ApiVersion>
  <Id>com.david303ttl.ACID</Id>
  <Version>0.1</Version>
  <Name>ACID fixture</Name>
</RenoiseScriptingTool>
'@
  [System.IO.File]::WriteAllText((Join-Path $toolRoot 'manifest.xml'), $manifest, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $toolRoot 'main.lua'), [string]::Join([string][char]10, @('-- fixture entrypoint', 'local fixture_entrypoint = true', '')), [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $toolRoot 'LICENSE'), 'Fixture license text', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $toolRoot 'model/compiler.lua'), 'return {compile = function() return true end}', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $toolRoot 'data/settings.json'), '{"schema":1,"enabled":true}', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $toolRoot 'README.md'), 'excluded documentation', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllBytes((Join-Path $Root 'tests/renoise/acid/fixtures/smoke.xrns'), [byte[]](0x50, 0x4B, 0x03, 0x04, 0x41, 0x43, 0x49, 0x44))
  [System.IO.File]::WriteAllText((Join-Path $Root 'tests/renoise/fixtures/smoke.json'), '{"outside":"tool"}', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $Root 'tests/renoise/acid/scenarios/smoke.lua'), 'return true', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $Root 'tests/renoise/keyboard/input.ahk'), 'Send "F5"', [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText((Join-Path $Root 'sdk/example/api.lua'), 'return {}', [System.Text.UTF8Encoding]::new($false))
  return $Root
}

function New-ArchiveVariant {
  param([string] $FixtureRoot, [string] $ArchivePath, [ValidateSet('Traversal', 'Duplicate', 'UnexpectedId')] [string] $Variant)
  $toolRoot = Join-Path $FixtureRoot $sourceToolName
  $prefix = [System.IO.Path]::GetFullPath($toolRoot).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
  $stream = [System.IO.File]::Open($ArchivePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
      $files = @(Get-ChildItem -LiteralPath $toolRoot -File -Recurse | Where-Object {
        $_.Extension.ToLowerInvariant() -in $runtimeExtensions -or $_.Name -eq 'LICENSE'
      })
      foreach ($file in $files) {
        $relative = [System.IO.Path]::GetFullPath($file.FullName).Substring($prefix.Length).Replace('\', '/')
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        if ($Variant -eq 'UnexpectedId' -and $relative -eq 'manifest.xml') {
          $text = [System.Text.Encoding]::UTF8.GetString($bytes).Replace('com.david303ttl.ACID', 'com.example.Other')
          $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
        }
        $entry = $archive.CreateEntry($relative)
        $target = $entry.Open()
        try { $target.Write($bytes, 0, $bytes.Length) } finally { $target.Dispose() }
      }
      if ($Variant -eq 'Traversal') {
        $entry = $archive.CreateEntry('../escape.lua')
        $target = $entry.Open()
        try { $target.WriteByte(0x41) } finally { $target.Dispose() }
      }
      if ($Variant -eq 'Duplicate') {
        $entry = $archive.CreateEntry('main.lua')
        $target = $entry.Open()
        try { $target.WriteByte(0x42) } finally { $target.Dispose() }
      }
    }
    finally { $archive.Dispose() }
  }
  finally { $stream.Dispose() }
}

function Install-ArchiveCopyStub {
  param([string] $FixtureRoot)
  $stub = @'
param([string[]] $Tool, [string] $OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Copy-Item -LiteralPath $env:PACKAGE_DEV_TEST_ARCHIVE -Destination (Join-Path $OutputDirectory 'com.david303ttl.ACID_0.1.xrnx')
'@
  [System.IO.File]::WriteAllText((Join-Path $FixtureRoot 'scripts/package.ps1'), $stub, [System.Text.UTF8Encoding]::new($false))
}

function Assert-ChildFailure {
  param([pscustomobject] $Result, [string] $Context)
  if ($Result.ExitCode -eq 0) { throw "$Context unexpectedly succeeded.$([string][char]10)$($Result.Output)" }
}

function Remove-TestRoot {
  if (-not (Test-Path -LiteralPath $testRoot)) { return }
  $resolved = [System.IO.Path]::GetFullPath($testRoot)
  if (-not $resolved.StartsWith($repoTempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Test cleanup path '$resolved' is outside repository tmp/."
  }
  if (((Get-Item -LiteralPath $resolved -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Test cleanup target became a reparse point.'
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Remove-RepositoryTempOutput {
  param([string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $resolved = [System.IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith($repoTempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Integration cleanup path '$resolved' is outside repository tmp/."
  }
  if (((Get-Item -LiteralPath $resolved -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Integration cleanup target became a reparse point.'
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Test-RealDevelopmentBundle {
  $outputRelative = 'tmp/acid-dev-integration-' + [guid]::NewGuid().ToString('N')
  $outputPath = Join-Path $repoRoot $outputRelative
  try {
    $result = Invoke-PackageDev -FixtureRoot $repoRoot -OutputPath $outputRelative
    if ($result.ExitCode -ne 0) { throw "Real ACID development bundle build failed:$([string][char]10)$($result.Output)" }

    $devTool = Join-Path $outputPath $sourceToolName
    $sessionPath = Join-Path $outputPath 'acid-test-session.conf'
    $fixtureDirectory = Join-Path $outputPath 'fixtures'
    Assert-True (Test-Path -LiteralPath $devTool -PathType Container) 'Real ACID development tool folder is missing.'
    Assert-True (Test-Path -LiteralPath $sessionPath -PathType Leaf) 'Real ACID development session file is missing.'
    Assert-True (Test-Path -LiteralPath $fixtureDirectory -PathType Container) 'Real native fixture sibling directory is missing.'

    $sourceFixtureDirectory = Join-Path $repoRoot 'tests/renoise/acid/fixtures'
    $sourceFixtures = @(Get-ChildItem -LiteralPath $sourceFixtureDirectory -File | Sort-Object Name)
    $deployedFixtures = @(Get-ChildItem -LiteralPath $fixtureDirectory -File | Sort-Object Name)
    Assert-True ($sourceFixtures.Count -gt 0 -and $deployedFixtures.Count -eq $sourceFixtures.Count) 'Real development build did not deploy the complete fixture set.'
    for ($fixtureIndex = 0; $fixtureIndex -lt $sourceFixtures.Count; $fixtureIndex++) {
      Assert-True ($deployedFixtures[$fixtureIndex].Name -ceq $sourceFixtures[$fixtureIndex].Name) 'Real development fixture names differ from source.'
      Assert-True ((Get-FileHash -LiteralPath $deployedFixtures[$fixtureIndex].FullName -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $sourceFixtures[$fixtureIndex].FullName -Algorithm SHA256).Hash) "Real development fixture '$($sourceFixtures[$fixtureIndex].Name)' differs from source."
    }

    $toolRoot = Join-Path $repoRoot $sourceToolName
    $sourceFiles = @(Get-ChildItem -LiteralPath $toolRoot -File -Recurse | Where-Object {
      $_.Extension.ToLowerInvariant() -in $runtimeExtensions -or $_.Name -eq 'LICENSE'
    })
    $expectedPaths = @($sourceFiles | ForEach-Object { Get-RelativePath -Root $toolRoot -Path $_.FullName })
    $expectedPaths += '__dev/remote_driver.lua'
    $expectedPaths += '__dev/json.lua'
    $actualPaths = @(Get-ChildItem -LiteralPath $devTool -File -Recurse | ForEach-Object {
      Get-RelativePath -Root $devTool -Path $_.FullName
    } | Sort-Object)
    $expectedPaths = @($expectedPaths | Sort-Object)
    Assert-True (($actualPaths -join '|') -ceq ($expectedPaths -join '|')) 'Real ACID development bundle has an unexpected or missing payload file.'

    $mainSource = Join-Path $toolRoot 'main.lua'
    $mainDev = Join-Path $devTool 'main.lua'
    $sourceBytes = [System.IO.File]::ReadAllBytes($mainSource)
    $devBytes = [System.IO.File]::ReadAllBytes($mainDev)
    Assert-True ($devBytes.Length -gt $sourceBytes.Length) 'Real ACID development entrypoint has no appended bootstrap.'
    for ($index = 0; $index -lt $sourceBytes.Length; $index++) {
      Assert-True ($devBytes[$index] -eq $sourceBytes[$index]) 'Real ACID production entrypoint bytes changed in the development bundle.'
    }
    $mainText = [System.Text.Encoding]::UTF8.GetString($devBytes)
    Assert-True (([regex]::Matches($mainText, [regex]::Escape($bootstrapMarker))).Count -eq 1) 'Real ACID development bootstrap is missing or duplicated.'
    Assert-Lua51Syntax -MainPath $mainDev -Context 'Real ACID development entrypoint'
  }
  finally {
    Remove-RepositoryTempOutput -Path $outputPath
  }
}

if (-not (Test-Path -LiteralPath $repoTempRoot -PathType Container)) {
  New-Item -ItemType Directory -Path $repoTempRoot | Out-Null
}
if (((Get-Item -LiteralPath $repoTempRoot -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'Repository tmp directory must not be a reparse point.'
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $fixture = New-FixtureRepository -Root (Join-Path $testRoot 'repo')
  $toolRoot = Join-Path $fixture $sourceToolName
  $sourceHashesBefore = Get-TreeHashes -Root $fixture

  $releaseDirectory = Join-Path $testRoot 'release'
  & (Join-Path $fixture 'scripts/package.ps1') -Tool ACID -OutputDirectory $releaseDirectory | Out-Null
  $releaseArchivePath = Join-Path $releaseDirectory 'com.david303ttl.ACID_0.1.xrnx'
  Assert-True (Test-Path -LiteralPath $releaseArchivePath -PathType Leaf) 'Normal release archive was not created.'
  $expectedPayload = Get-ChildItem -LiteralPath $toolRoot -File -Recurse | Where-Object {
    $_.Extension.ToLowerInvariant() -in $runtimeExtensions -or $_.Name -eq 'LICENSE'
  } | ForEach-Object { Get-RelativePath -Root $toolRoot -Path $_.FullName }
  $expectedPayload = @($expectedPayload | Sort-Object)
  $releaseArchive = [System.IO.Compression.ZipFile]::OpenRead($releaseArchivePath)
  try {
    $releaseNames = @($releaseArchive.Entries | ForEach-Object FullName | Sort-Object)
    Assert-True (($releaseNames -join '|') -ceq ($expectedPayload -join '|')) 'Release archive does not match the approved runtime payload.'
    Assert-True (-not ($releaseNames | Where-Object { $_ -match '(^|/)(__dev|tests?|docs?|sdk|scenarios|fixtures|keyboard)(/|$)|remote_driver|bootstrap|config|\.ahk$' })) 'Release archive contains a development-only file.'
    $manifestEntry = $releaseArchive.GetEntry('manifest.xml')
    Assert-True ($null -ne $manifestEntry) 'Release archive is missing root manifest.xml.'
    Assert-True ((Get-EntryHash $manifestEntry) -ceq (Get-FileHash (Join-Path $toolRoot 'manifest.xml') -Algorithm SHA256).Hash.ToLowerInvariant()) 'Release manifest differs from source bytes.'
  }
  finally { $releaseArchive.Dispose() }

  $devOutputOneRelative = 'tmp/dev-one'
  $devOutputOne = Join-Path $fixture $devOutputOneRelative
  $resultOne = Invoke-PackageDev -FixtureRoot $fixture -OutputPath $devOutputOneRelative
  if ($resultOne.ExitCode -ne 0) { throw "Development bundle build failed:$([string][char]10)$($resultOne.Output)" }
  Assert-True (-not $resultOne.Output.Contains($fixture)) 'Development package output disclosed the absolute fixture path.'
  Assert-True (-not $resultOne.Output.Contains($repoRoot)) 'Development package output disclosed the absolute repository path.'
  $devToolOne = Join-Path $devOutputOne $sourceToolName
  $sessionPathOne = Join-Path $devOutputOne 'acid-test-session.conf'
  $fixtureOutputOne = Join-Path $devOutputOne 'fixtures'
  Assert-True (Test-Path -LiteralPath $devToolOne -PathType Container) 'Development tool folder is missing.'
  Assert-True (Test-Path -LiteralPath $sessionPathOne -PathType Leaf) 'Protected development session file is missing.'
  Assert-True (Test-Path -LiteralPath $fixtureOutputOne -PathType Container) 'Development fixture sibling directory is missing.'
  $sourceFixturesOne = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'tests/renoise/acid/fixtures') -File | Sort-Object Name)
  $deployedFixturesOne = @(Get-ChildItem -LiteralPath $fixtureOutputOne -File | Sort-Object Name)
  Assert-True ($deployedFixturesOne.Count -eq $sourceFixturesOne.Count) 'Development fixture set is incomplete or has extra files.'
  for ($fixtureIndex = 0; $fixtureIndex -lt $sourceFixturesOne.Count; $fixtureIndex++) {
    Assert-True ($deployedFixturesOne[$fixtureIndex].Name -ceq $sourceFixturesOne[$fixtureIndex].Name) 'Development fixture names differ from source.'
    Assert-True ((Get-FileHash -LiteralPath $deployedFixturesOne[$fixtureIndex].FullName -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $sourceFixturesOne[$fixtureIndex].FullName -Algorithm SHA256).Hash) "Development fixture '$($sourceFixturesOne[$fixtureIndex].Name)' differs from source."
  }

  $sourcePayloadFiles = @(Get-ChildItem -LiteralPath $toolRoot -File -Recurse | Where-Object {
    $_.Extension.ToLowerInvariant() -in $runtimeExtensions -or $_.Name -eq 'LICENSE'
  })
  $expectedDevPaths = @($sourcePayloadFiles | ForEach-Object { Get-RelativePath -Root $toolRoot -Path $_.FullName })
  $expectedDevPaths += '__dev/remote_driver.lua'
  $expectedDevPaths += '__dev/json.lua'
  $actualDevPaths = @(Get-ChildItem -LiteralPath $devToolOne -File -Recurse | ForEach-Object { Get-RelativePath -Root $devToolOne -Path $_.FullName } | Sort-Object)
  $expectedDevPaths = @($expectedDevPaths | Sort-Object)
  Assert-True (($actualDevPaths -join '|') -ceq ($expectedDevPaths -join '|')) 'Development bundle contains an unexpected or missing file.'

  $mainSourcePath = Join-Path $toolRoot 'main.lua'
  $mainDevPath = Join-Path $devToolOne 'main.lua'
  $mainSourceBytes = [System.IO.File]::ReadAllBytes($mainSourcePath)
  $mainDevBytes = [System.IO.File]::ReadAllBytes($mainDevPath)
  Assert-True ($mainDevBytes.Length -gt $mainSourceBytes.Length) 'Development main.lua has no appended bootstrap.'
  for ($index = 0; $index -lt $mainSourceBytes.Length; $index++) {
    Assert-True ($mainDevBytes[$index] -eq $mainSourceBytes[$index]) 'Development main.lua changed production bytes before the bootstrap.'
  }
  $mainDevText = [System.Text.Encoding]::UTF8.GetString($mainDevBytes)
  $bootstrapText = [System.Text.Encoding]::UTF8.GetString($mainDevBytes, $mainSourceBytes.Length, $mainDevBytes.Length - $mainSourceBytes.Length)
  Assert-True (([regex]::Matches($mainDevText, [regex]::Escape($bootstrapMarker))).Count -eq 1) 'Development bootstrap is missing or duplicated.'
  Assert-True ($mainDevText.Contains('renoise.tool().bundle_path')) 'Development bootstrap does not resolve the staged driver from the tool bundle.'
  Assert-True ($mainDevText.Contains('driver.start(')) 'Development bootstrap does not start the staged driver.'
  $expectedBootstrap = [string]::Join([string][char]10, @(
    ''
    $bootstrapMarker
    'do'
    '  local driver = dofile(renoise.tool().bundle_path .. "\\__dev\\remote_driver.lua")'
    '  local original_gui_show = gui.show'
    '  local show_invocations = 0'
    '  gui.show = function(...)'
    '    show_invocations = show_invocations + 1'
    '    return original_gui_show(...)'
    '  end'
    '  driver.start(renoise.tool().bundle_path .. "\\..\\acid-test-session.conf", function()'
    '    local state = gui.get_ui_state()'
    '    state.show_invocations = show_invocations'
    '    state.show_keybinding_registered = renoise.tool():has_keybinding("Global:ACID:Show")'
    '    return state'
    '  end)'
    'end'
    ''
  ))
  Assert-True ($bootstrapText -ceq $expectedBootstrap) 'Development bootstrap contains unexpected or machine-specific data.'
  Assert-True (-not $bootstrapText.Contains($devOutputOne)) 'Development bootstrap contains its temporary output path.'
  Assert-Lua51Syntax -MainPath $mainDevPath -Context 'Synthetic development entrypoint'

  foreach ($file in $sourcePayloadFiles) {
    $relative = Get-RelativePath -Root $toolRoot -Path $file.FullName
    if ($relative -eq 'main.lua') { continue }
    $devPath = Join-Path $devToolOne ($relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    Assert-True (Test-Path -LiteralPath $devPath -PathType Leaf) "Development production file '$relative' is missing."
    Assert-True ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $devPath -Algorithm SHA256).Hash) "Development production file '$relative' differs from source."
  }
  $driverDevPath = Join-Path $devToolOne '__dev/remote_driver.lua'
  Assert-True ((Get-FileHash -LiteralPath (Join-Path $fixture 'tests/renoise/driver/remote_driver.lua') -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $driverDevPath -Algorithm SHA256).Hash) 'Development driver differs from its source.'
  $codecDevPath = Join-Path $devToolOne '__dev/json.lua'
  Assert-True ((Get-FileHash -LiteralPath (Join-Path $fixture 'tests/renoise/driver/json.lua') -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $codecDevPath -Algorithm SHA256).Hash) 'Development JSON codec differs from its source.'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $devToolOne 'acid-test-session.conf'))) 'Session test secrets were copied into the tool bundle.'

  $sessionTextOne = [System.IO.File]::ReadAllText($sessionPathOne)
  $sessionValuesOne = @{}
  foreach ($line in ($sessionTextOne -split '\r?\n')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '=', 2
    Assert-True ($parts.Count -eq 2 -and -not $sessionValuesOne.ContainsKey($parts[0])) 'Session file has malformed or duplicate fields.'
    $sessionValuesOne[$parts[0]] = $parts[1]
  }
  Assert-True ($sessionValuesOne.Count -eq 4) 'Session file must contain exactly four fields.'
  $sessionKeys = @($sessionValuesOne.Keys | Sort-Object)
  Assert-True (($sessionKeys -join '|') -ceq 'bind_address|nonce|port|token') 'Session file contains a user or desktop identifier.'
  Assert-True ($sessionValuesOne['bind_address'] -ceq '127.0.0.1') 'Session is not restricted to IPv4 loopback.'
  Assert-True ($sessionValuesOne['port'] -match '^\d+$' -and [int]$sessionValuesOne['port'] -ge 1024 -and [int]$sessionValuesOne['port'] -le 65535) 'Session port is invalid.'
  Assert-True ($sessionValuesOne['token'] -match '^[0-9a-f]{64}$') 'Session token is missing or predictable.'
  Assert-True ($sessionValuesOne['nonce'] -match '^[0-9a-f]{64}$') 'Session nonce is missing or predictable.'
  $sessionAcl = Get-Acl -LiteralPath $sessionPathOne
  Assert-True $sessionAcl.AreAccessRulesProtected 'Session file ACL inherits broader temporary-directory permissions.'
  $sessionRules = @($sessionAcl.Access | Where-Object { -not $_.IsInherited })
  $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $sessionRuleSids = @($sessionRules | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
  Assert-True ($sessionRules.Count -eq 1 -and $sessionRuleSids[0] -eq $currentSid) 'Session file ACL is not limited to the current user.'
  $requiredSessionRights = [System.Security.AccessControl.FileSystemRights]::FullControl
  Assert-True (($sessionRules[0].FileSystemRights -band $requiredSessionRights) -eq $requiredSessionRights) 'Session file ACL does not allow the current user to read and clean up the session file.'
  $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, [int]$sessionValuesOne['port'])
  try { $portProbe.Start() }
  catch { throw 'Generated loopback port was already occupied during the availability check.' }
  finally { $portProbe.Stop() }

  $devOutputTwoRelative = Join-Path 'tmp' 'dev-two'
  $devOutputTwo = Join-Path $fixture $devOutputTwoRelative
  $resultTwo = Invoke-PackageDev -FixtureRoot $fixture -OutputPath $devOutputTwoRelative
  if ($resultTwo.ExitCode -ne 0) { throw "Repeated development bundle build failed:$([string][char]10)$($resultTwo.Output)" }
  $sessionTextTwo = [System.IO.File]::ReadAllText((Join-Path $devOutputTwo 'acid-test-session.conf'))
  Assert-True (-not $sessionTextTwo.Contains($sessionValuesOne['token'])) 'Repeated development build reused the previous token.'
  Assert-True (-not $sessionTextTwo.Contains($sessionValuesOne['nonce'])) 'Repeated development build reused the previous nonce.'

  $sourceHashesAfter = Get-TreeHashes -Root $fixture
  Assert-True ($sourceHashesBefore.Count -eq $sourceHashesAfter.Count) 'Development packaging changed the fixture source tree.'
  foreach ($relative in $sourceHashesBefore.Keys) {
    Assert-True ($sourceHashesAfter.ContainsKey($relative) -and $sourceHashesAfter[$relative] -ceq $sourceHashesBefore[$relative]) "Development packaging changed source file '$relative'."
  }

  $absoluteOutput = Join-Path $testRoot 'absolute-output'
  $absoluteOutputResult = Invoke-PackageDev -FixtureRoot $fixture -OutputPath $absoluteOutput
  Assert-ChildFailure -Result $absoluteOutputResult -Context 'Absolute output path case'
  Assert-True (-not (Test-Path -LiteralPath $absoluteOutput)) 'Absolute output path case created a directory.'

  $traversalOutput = Join-Path $fixture 'escaped'
  $traversalOutputResult = Invoke-PackageDev -FixtureRoot $fixture -OutputPath 'tmp/../escaped'
  Assert-ChildFailure -Result $traversalOutputResult -Context 'Output traversal case'
  Assert-True (-not (Test-Path -LiteralPath $traversalOutput)) 'Output traversal case escaped repository tmp/.'

  $missingDriverRepo = New-FixtureRepository -Root (Join-Path $testRoot 'missing-driver-repo')
  Remove-Item -LiteralPath (Join-Path $missingDriverRepo 'tests/renoise/driver/remote_driver.lua') -Force
  $missingOutputRelative = 'tmp/missing-driver-output'
  $missingOutput = Join-Path $missingDriverRepo $missingOutputRelative
  $missingResult = Invoke-PackageDev -FixtureRoot $missingDriverRepo -OutputPath $missingOutputRelative
  Assert-ChildFailure -Result $missingResult -Context 'Missing driver case'
  Assert-True (-not (Test-Path -LiteralPath $missingOutput)) 'Missing driver case left a development output behind.'

  foreach ($fixtureCase in @('empty', 'nested', 'unsupported')) {
    $invalidFixtureRepo = New-FixtureRepository -Root (Join-Path $testRoot ('fixture-' + $fixtureCase))
    $assetRoot = Join-Path $invalidFixtureRepo 'tests/renoise/acid/fixtures'
    switch ($fixtureCase) {
      'empty' { Remove-Item -LiteralPath (Join-Path $assetRoot 'smoke.xrns') }
      'nested' { New-Item -ItemType Directory -Path (Join-Path $assetRoot 'nested') | Out-Null }
      'unsupported' { [IO.File]::WriteAllText((Join-Path $assetRoot 'notes.txt'), 'not a fixture') }
    }
    $invalidOutput = 'tmp/rejected-fixtures'
    $invalidResult = Invoke-PackageDev -FixtureRoot $invalidFixtureRepo -OutputPath $invalidOutput
    Assert-ChildFailure -Result $invalidResult -Context ("Invalid fixture inventory: " + $fixtureCase)
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidFixtureRepo $invalidOutput))) 'Invalid fixture inventory left a development output behind.'
  }

  $transportOnlyRepo = New-FixtureRepository -Root (Join-Path $testRoot 'transport-only-repo')
  Remove-Item -LiteralPath (Join-Path $transportOnlyRepo 'tests/renoise/acid/fixtures') -Recurse -Force
  $transportScenarioDirectory = Join-Path $transportOnlyRepo 'tests/renoise/acid/scenarios'
  [System.IO.File]::WriteAllText((Join-Path $transportScenarioDirectory 'broken.json'), '{', [System.Text.UTF8Encoding]::new($false))
  $transportOutputRelative = 'tmp/transport-only-output'
  $transportOutput = Join-Path $transportOnlyRepo $transportOutputRelative
  $transportResult = Invoke-PackageDev -FixtureRoot $transportOnlyRepo -OutputPath $transportOutputRelative -TransportOnly
  if ($transportResult.ExitCode -ne 0) { throw "Transport-only development bundle build required native fixtures:$([string][char]10)$($transportResult.Output)" }
  Assert-True (Test-Path -LiteralPath (Join-Path $transportOutput $sourceToolName) -PathType Container) 'Transport-only development tool folder is missing.'
  Assert-True (Test-Path -LiteralPath (Join-Path $transportOutput 'acid-test-session.conf') -PathType Leaf) 'Transport-only development session file is missing.'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $transportOutput 'fixtures'))) 'Transport-only development bundle staged native fixtures.'

  $duplicateDriverRepo = New-FixtureRepository -Root (Join-Path $testRoot 'duplicate-driver-repo')
  $duplicateDirectory = Join-Path $duplicateDriverRepo 'tests/renoise/driver/duplicate'
  New-Item -ItemType Directory -Path $duplicateDirectory | Out-Null
  Copy-Item -LiteralPath (Join-Path $duplicateDriverRepo 'tests/renoise/driver/remote_driver.lua') -Destination (Join-Path $duplicateDirectory 'remote_driver.lua')
  $duplicateOutputRelative = 'tmp/duplicate-driver-output'
  $duplicateOutput = Join-Path $duplicateDriverRepo $duplicateOutputRelative
  $duplicateResult = Invoke-PackageDev -FixtureRoot $duplicateDriverRepo -OutputPath $duplicateOutputRelative
  Assert-ChildFailure -Result $duplicateResult -Context 'Duplicate driver case'
  Assert-True (-not (Test-Path -LiteralPath $duplicateOutput)) 'Duplicate driver case left a development output behind.'

  $developmentLeakRepo = New-FixtureRepository -Root (Join-Path $testRoot 'development-leak-repo')
  $leakDirectory = Join-Path $developmentLeakRepo "$sourceToolName/tests"
  New-Item -ItemType Directory -Path $leakDirectory | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $leakDirectory 'smoke.lua'), 'return true')
  $developmentLeakOutputRelative = 'tmp/development-leak-output'
  $developmentLeakOutput = Join-Path $developmentLeakRepo $developmentLeakOutputRelative
  $developmentLeakResult = Invoke-PackageDev -FixtureRoot $developmentLeakRepo -OutputPath $developmentLeakOutputRelative
  Assert-ChildFailure -Result $developmentLeakResult -Context 'Development-only source file case'
  Assert-True (-not (Test-Path -LiteralPath $developmentLeakOutput)) 'Development-only source file case left a development output behind.'

  $staleRepo = New-FixtureRepository -Root (Join-Path $testRoot 'stale-repo')
  $staleOutputRelative = 'tmp/stale-output'
  $staleOutput = Join-Path $staleRepo $staleOutputRelative
  New-Item -ItemType Directory -Path $staleOutput | Out-Null
  $staleFile = Join-Path $staleOutput 'acid-test-session.conf'
  [System.IO.File]::WriteAllText($staleFile, 'stale')
  $staleResult = Invoke-PackageDev -FixtureRoot $staleRepo -OutputPath $staleOutputRelative
  Assert-ChildFailure -Result $staleResult -Context 'Stale dev-file case'
  Assert-True ([System.IO.File]::ReadAllText($staleFile) -ceq 'stale') 'Stale output was modified after rejection.'

  foreach ($variant in @('Traversal', 'Duplicate', 'UnexpectedId')) {
    $archiveRepo = New-FixtureRepository -Root (Join-Path $testRoot ($variant.ToLowerInvariant() + '-repo'))
    $archivePath = Join-Path $testRoot ($variant.ToLowerInvariant() + '.xrnx')
    New-ArchiveVariant -FixtureRoot $archiveRepo -ArchivePath $archivePath -Variant $variant
    Install-ArchiveCopyStub -FixtureRoot $archiveRepo
    $env:PACKAGE_DEV_TEST_ARCHIVE = $archivePath
    try {
      $archiveOutputRelative = "tmp/$($variant.ToLowerInvariant())-output"
      $badArchiveResult = Invoke-PackageDev -FixtureRoot $archiveRepo -OutputPath $archiveOutputRelative
    }
    finally { Remove-Item Env:PACKAGE_DEV_TEST_ARCHIVE -ErrorAction SilentlyContinue }
    Assert-ChildFailure -Result $badArchiveResult -Context "$variant archive case"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $archiveRepo $archiveOutputRelative))) "$variant archive left a development output behind."
  }

  Test-RealDevelopmentBundle

  Write-Output 'Development package checks passed: release exclusion, dev payload and fixture hashes, session ACL, Lua 5.1 entrypoint syntax, real ACID integration build, bootstrap, Unicode paths, port availability, output path rejection, repeat builds and archive rejection cases.'
}
finally {
  Remove-TestRoot
}
