#Requires -Version 7.0

<#
.SYNOPSIS
Builds an isolated ACID development bundle from the normal release package.

.DESCRIPTION
The destination must be a new repository-relative path directly below tmp/.
Build staging and the protected session file also remain below that ignored
repository directory.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('ACID')]
  [string] $Tool,

  [Parameter(Mandatory)]
  [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Xml.Linq

if ($env:OS -ne 'Windows_NT') {
  throw 'Development bundles require Windows so the session file can receive a user-only ACL.'
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolDirectoryName = 'com.david303ttl.ACID.xrnx'
$expectedId = 'com.david303ttl.ACID'
$toolRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $toolDirectoryName))
$packageScript = Join-Path $PSScriptRoot 'package.ps1'
$driverDirectory = Join-Path $repoRoot 'tests/renoise/driver'
$driverSource = Join-Path $driverDirectory 'remote_driver.lua'
$repoTempRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'tmp'))
$relativeOutputPath = $OutputDirectory.Replace('\', '/')
$outputSegments = $relativeOutputPath.Split('/')
if ([System.IO.Path]::IsPathRooted($OutputDirectory) -or $outputSegments.Count -ne 2 -or
    -not [string]::Equals($outputSegments[0], 'tmp', [System.StringComparison]::OrdinalIgnoreCase) -or
    [string]::IsNullOrWhiteSpace($outputSegments[1]) -or $outputSegments[1] -eq '.' -or $outputSegments[1] -eq '..') {
  throw 'OutputDirectory must be a repository-relative path directly below tmp/.'
}
$outputFullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $relativeOutputPath))
$repoTempPrefix = $repoTempRoot.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
$workPath = [System.IO.Path]::GetFullPath((Join-Path $repoTempRoot ('acid-dev-package-' + [guid]::NewGuid().ToString('N'))))
$runtimeExtensions = @('.lua', '.xml', '.txt', '.json', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.wav', '.aif', '.aiff', '.flac', '.ogg', '.bin')
$bootstrapMarker = '-- ACID development bootstrap'

function Test-ContainedPath {
  param([string] $Path, [string] $Parent)
  $parentPrefix = [System.IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
  return $Path.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoint {
  param([string] $Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to use reparse point '$Path'."
  }
}

function Assert-NoReparseAncestors {
  param([string] $Path, [string] $StopAt)
  $current = [System.IO.DirectoryInfo]::new($Path)
  $stop = [System.IO.Path]::GetFullPath($StopAt).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
  while ($null -ne $current) {
    if (Test-Path -LiteralPath $current.FullName) { Assert-NoReparsePoint -Path $current.FullName }
    if ($current.FullName.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) -eq $stop) { return }
    $current = $current.Parent
  }
  throw "Path '$Path' is not contained by '$StopAt'."
}

function Get-SourcePayload {
  param([string] $Root)
  $rootPrefix = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
  $manifestPath = Join-Path $Root 'manifest.xml'
  $mainPath = Join-Path $Root 'main.lua'
  $licensePath = Join-Path $Root 'LICENSE'
  foreach ($required in @($manifestPath, $mainPath, $licensePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Tool payload is missing '$required'." }
  }
  Assert-NoReparsePoint -Path $Root
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse)) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Tool payload contains a reparse point '$($item.FullName)'."
    }
  }

  $payload = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse)
  foreach ($file in $files) {
    $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Source file '$fullPath' resolves outside '$Root'."
    }
    $relative = $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
    if ($relative -match '(^|/)(tests?|docs?|sdk|scenarios|fixtures|keyboard|__dev)(/|$)' -or
        $file.Name -match '(^|[._-])(test|spec|fixture|bootstrap|remote_driver|dev_config)([._-]|$)' -or
        $file.Name -match '^(config|acid-test-session)(\.|$)') {
      throw "Tool source contains a development-only asset '$relative'."
    }
    $isPackageFile = $runtimeExtensions -contains $file.Extension.ToLowerInvariant() -or $relative -eq 'LICENSE'
    if (-not $isPackageFile) { continue }
    if ($payload.ContainsKey($relative)) { throw "Source payload contains duplicate path '$relative'." }
    $payload.Add($relative, (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant())
  }
  if (-not ($payload.Keys -ccontains 'manifest.xml') -or -not ($payload.Keys -ccontains 'main.lua') -or -not ($payload.Keys -ccontains 'LICENSE')) {
    throw 'Release payload must contain root manifest.xml, main.lua and LICENSE.'
  }
  return $payload
}

function Get-ArchiveManifest {
  param([System.IO.Compression.ZipArchive] $Archive)
  $entry = $Archive.GetEntry('manifest.xml')
  if ($null -eq $entry) { throw 'Release archive has no root manifest.xml.' }
  $stream = $entry.Open()
  try {
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($stream, $settings)
    try { $document = [System.Xml.Linq.XDocument]::Load($reader) }
    finally { $reader.Dispose() }
  }
  finally { $stream.Dispose() }
  if ($null -eq $document.Root -or $document.Root.Name.LocalName -ne 'RenoiseScriptingTool') {
    throw 'Release archive has an unexpected manifest root.'
  }
  $idNode = $document.Root.Element('Id')
  $versionNode = $document.Root.Element('Version')
  return [pscustomobject]@{
    Id = if ($null -eq $idNode) { '' } else { $idNode.Value }
    Version = if ($null -eq $versionNode) { '' } else { $versionNode.Value }
  }
}

function Expand-VerifiedArchive {
  param(
    [string] $ArchivePath,
    [string] $Destination,
    [System.Collections.Generic.Dictionary[string, string]] $ExpectedPayload
  )
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $entriesByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
      $raw = [string]$entry.FullName
      if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Contains('\') -or $raw.StartsWith('/') -or $raw.Contains(':') -or $raw.Contains([char]0) -or $raw.EndsWith('/')) {
        throw "Release archive contains an unsafe or unexpected path '$raw'."
      }
      $segments = $raw.Split('/')
      if (@($segments | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "Release archive contains an unsafe path '$raw'."
      }
      if (-not ($ExpectedPayload.Keys -ccontains $raw)) {
        throw "Release archive entry '$raw' has noncanonical casing or path separators."
      }
      $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
      $dosAttributes = $entry.ExternalAttributes -band 0xFFFF
      if ($unixType -eq 0xA000 -or ($dosAttributes -band 0x400) -ne 0) {
        throw "Release archive contains a link or reparse entry '$raw'."
      }
      if ($entriesByPath.ContainsKey($raw)) { throw "Release archive contains duplicate path '$raw'." }
      if (-not $ExpectedPayload.ContainsKey($raw)) { throw "Release archive contains unapproved file '$raw'." }
      $entriesByPath.Add($raw, $entry)
    }

    if ($entriesByPath.Count -ne $ExpectedPayload.Count) {
      $missing = @($ExpectedPayload.Keys | Where-Object { -not $entriesByPath.ContainsKey($_) })
      throw "Release archive payload differs from approved source files; missing: $($missing -join ', ')."
    }
    $manifest = Get-ArchiveManifest -Archive $archive
    if ($manifest.Id -cne $expectedId) { throw "Release archive has unexpected tool ID '$($manifest.Id)'." }
    if ($manifest.Version -notmatch '^[0-9]+(?:\.[0-9A-Za-z-]+)*$') { throw "Release archive has invalid version '$($manifest.Version)'." }

    foreach ($relative in $entriesByPath.Keys) {
      $entry = $entriesByPath[$relative]
      $stream = $entry.Open()
      try {
        $digest = [System.Security.Cryptography.SHA256]::HashData($stream)
        $actualHash = [System.Convert]::ToHexString($digest).ToLowerInvariant()
      }
      finally { $stream.Dispose() }
      if ($actualHash -cne $ExpectedPayload[$relative]) {
        throw "Release archive hash differs from source file '$relative'."
      }
    }

    $destinationFull = [System.IO.Path]::GetFullPath($Destination)
    $destinationPrefix = $destinationFull.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
    New-Item -ItemType Directory -Path $destinationFull -ErrorAction Stop | Out-Null
    foreach ($relative in $entriesByPath.Keys) {
      $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destinationFull ($relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))))
      if (-not $targetPath.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Archive entry '$relative' resolves outside the extraction directory."
      }
      $targetDirectory = Split-Path -Parent $targetPath
      New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
      $input = $entriesByPath[$relative].Open()
      try {
        $output = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose() }
      }
      finally { $input.Dispose() }
    }
    return $manifest
  }
  finally { $archive.Dispose() }
}

function New-SessionValue {
  param([int] $ByteCount)
  $bytes = [byte[]]::new($ByteCount)
  $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $generator.GetBytes($bytes) }
  finally { $generator.Dispose() }
  return [System.Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Get-FreeLoopbackPort {
  for ($attempt = 0; $attempt -lt 8; $attempt++) {
    $first = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
      $first.Start()
      $port = ([System.Net.IPEndPoint]$first.LocalEndpoint).Port
    }
    finally { $first.Stop() }

    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    try {
      $probe.Start()
      return $port
    }
    catch [System.Net.Sockets.SocketException] {
      continue
    }
    finally { $probe.Stop() }
  }
  throw 'Could not reserve a free loopback test port after repeated collision checks.'
}

function Set-UserOnlyFileAcl {
  param([string] $Path)
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  if ($null -eq $identity.User) { throw 'Could not identify the current Windows user for the session-file ACL.' }
  $acl = [System.Security.AccessControl.FileSecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
  $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $identity.User,
    $rights,
    [System.Security.AccessControl.AccessControlType]::Allow
  )
  $acl.AddAccessRule($rule)
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-UserOnlyDirectoryAcl {
  param([string] $Path)
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  if ($null -eq $identity.User) { throw 'Could not identify the current Windows user for the session-directory ACL.' }
  $acl = [System.Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
  $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $identity.User,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    $inheritance,
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow
  )
  $acl.AddAccessRule($rule)
  Set-Acl -LiteralPath $Path -AclObject $acl
}

if (-not (Test-Path -LiteralPath $toolRoot -PathType Container)) { throw "ACID source directory '$toolRoot' was not found." }
if (-not (Test-Path -LiteralPath $packageScript -PathType Leaf)) { throw "Release packager '$packageScript' was not found." }
if (-not (Test-Path -LiteralPath $driverDirectory -PathType Container)) { throw "Development driver directory '$driverDirectory' was not found." }
$driverFiles = @(Get-ChildItem -LiteralPath $driverDirectory -Force -Recurse)
if ($driverFiles.Count -ne 1 -or $driverFiles[0].Name -cne 'remote_driver.lua' -or $driverFiles[0].PSIsContainer) {
  throw "Development driver directory must contain exactly one file named 'remote_driver.lua'."
}
Assert-NoReparsePoint -Path $driverDirectory
Assert-NoReparsePoint -Path $driverSource

if (-not $outputFullPath.StartsWith($repoTempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "OutputDirectory '$OutputDirectory' resolves outside repository tmp/."
}
Assert-NoReparseAncestors -Path $repoTempRoot -StopAt $repoRoot
if (-not (Test-Path -LiteralPath $repoTempRoot -PathType Container)) {
  New-Item -ItemType Directory -Path $repoTempRoot -ErrorAction Stop | Out-Null
}
Assert-NoReparsePoint -Path $repoTempRoot
if (Test-Path -LiteralPath $outputFullPath) {
  throw "OutputDirectory '$OutputDirectory' already exists; refusing stale development files."
}
$outputParent = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw "OutputDirectory parent '$outputParent' is missing." }
Assert-NoReparseAncestors -Path $outputParent -StopAt $repoTempRoot

$sourcePayload = Get-SourcePayload -Root $toolRoot
$mainSourcePath = Join-Path $toolRoot 'main.lua'
$sourceMainText = [System.IO.File]::ReadAllText($mainSourcePath)
if ($sourceMainText.Contains($bootstrapMarker)) { throw 'The tracked ACID entrypoint already contains the development bootstrap marker.' }

$workCreated = $false
$outputCreated = $false
try {
  New-Item -ItemType Directory -Path $workPath -ErrorAction Stop | Out-Null
  $workCreated = $true
  Assert-NoReparsePoint -Path $workPath
  $releaseDirectory = Join-Path $workPath 'release'
  $stageParent = Join-Path $workPath 'stage'
  $stagedToolPath = Join-Path $stageParent $toolDirectoryName
  New-Item -ItemType Directory -Path $stageParent | Out-Null

  & $packageScript -Tool $Tool -OutputDirectory $releaseDirectory | Out-Null
  $manifestSource = Get-Content -LiteralPath (Join-Path $toolRoot 'manifest.xml') -Raw
  $manifestDocument = [System.Xml.Linq.XDocument]::Parse($manifestSource)
  $version = $manifestDocument.Root.Element('Version').Value
  $releaseArchive = Join-Path $releaseDirectory ("$($expectedId)_$version.xrnx")
  if (-not (Test-Path -LiteralPath $releaseArchive -PathType Leaf)) { throw "Expected release archive '$releaseArchive' was not created." }

  $releaseManifest = Expand-VerifiedArchive -ArchivePath $releaseArchive -Destination $stagedToolPath -ExpectedPayload $sourcePayload
  if ($releaseManifest.Id -cne $expectedId) { throw "Unexpected release ID '$($releaseManifest.Id)'." }

  $originalMain = [System.IO.File]::ReadAllBytes((Join-Path $stagedToolPath 'main.lua'))
  $mainText = [System.Text.Encoding]::UTF8.GetString($originalMain)
  if ($mainText.Contains($bootstrapMarker)) { throw 'Release main.lua already contains a development bootstrap.' }
  $driverDirectoryInTool = Join-Path $stagedToolPath '__dev'
  New-Item -ItemType Directory -Path $driverDirectoryInTool | Out-Null
  Copy-Item -LiteralPath $driverSource -Destination (Join-Path $driverDirectoryInTool 'remote_driver.lua')

  $sessionPath = Join-Path $outputFullPath 'acid-test-session.conf'
  $port = Get-FreeLoopbackPort
  $token = New-SessionValue -ByteCount 32
  $nonce = New-SessionValue -ByteCount 32
  $sessionText = @(
    'bind_address=127.0.0.1'
    "port=$port"
    "token=$token"
    "nonce=$nonce"
  ) -join [string][char]10
  $sessionDirectory = Join-Path $workPath 'session'
  New-Item -ItemType Directory -Path $sessionDirectory | Out-Null
  Set-UserOnlyDirectoryAcl -Path $sessionDirectory
  $sessionTempPath = Join-Path $sessionDirectory 'acid-test-session.conf'
  [System.IO.File]::WriteAllText($sessionTempPath, $sessionText, [System.Text.UTF8Encoding]::new($false))
  Set-UserOnlyFileAcl -Path $sessionTempPath

  $bundleDriver = 'renoise.tool().bundle_path .. "\\__dev\\remote_driver.lua"'
  $bootstrap = [string]::Join([string][char]10, @(
    ''
    $bootstrapMarker
    'do'
    "  local driver = dofile($bundleDriver)"
    '  driver.start(renoise.tool().bundle_path .. "\\..\\acid-test-session.conf")'
    'end'
    ''
  ))
  $bootstrapBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($bootstrap)
  $combinedMain = [byte[]]::new($originalMain.Length + $bootstrapBytes.Length)
  [System.Buffer]::BlockCopy($originalMain, 0, $combinedMain, 0, $originalMain.Length)
  [System.Buffer]::BlockCopy($bootstrapBytes, 0, $combinedMain, $originalMain.Length, $bootstrapBytes.Length)
  [System.IO.File]::WriteAllBytes((Join-Path $stagedToolPath 'main.lua'), $combinedMain)

  $expectedDevFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($relative in $sourcePayload.Keys) { [void]$expectedDevFiles.Add($relative) }
  [void]$expectedDevFiles.Add('__dev/remote_driver.lua')
  $actualDevFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $stagePrefix = [System.IO.Path]::GetFullPath($stagedToolPath).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
  foreach ($file in @(Get-ChildItem -LiteralPath $stagedToolPath -File -Recurse)) {
    $full = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $full.StartsWith($stagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Staged file '$full' resolves outside the dev bundle." }
    $relative = $full.Substring($stagePrefix.Length).Replace('\', '/')
    if (-not $actualDevFiles.Add($relative)) { throw "Staged dev bundle contains duplicate path '$relative'." }
    if (-not $expectedDevFiles.Contains($relative)) { throw "Staged dev bundle contains unexpected file '$relative'." }
    if ($relative -eq 'main.lua') {
      $stagedBytes = [System.IO.File]::ReadAllBytes($full)
      if ($stagedBytes.Length -le $originalMain.Length) { throw 'Staged main.lua does not contain the development bootstrap.' }
      for ($index = 0; $index -lt $originalMain.Length; $index++) {
        if ($stagedBytes[$index] -ne $originalMain[$index]) { throw 'Staged main.lua changed production entrypoint bytes before the bootstrap.' }
      }
      $stagedText = [System.Text.Encoding]::UTF8.GetString($stagedBytes)
      if (([regex]::Matches($stagedText, [regex]::Escape($bootstrapMarker))).Count -ne 1) {
        throw 'Staged main.lua must contain exactly one development bootstrap.'
      }
    }
    else {
      $expectedHash = if ($relative -eq '__dev/remote_driver.lua') {
        (Get-FileHash -LiteralPath $driverSource -Algorithm SHA256).Hash.ToLowerInvariant()
      }
      else { $sourcePayload[$relative] }
      $actualHash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -cne $expectedHash) { throw "Staged file '$relative' differs from its expected source hash." }
    }
  }
  if ($actualDevFiles.Count -ne $expectedDevFiles.Count) {
    $missing = @($expectedDevFiles | Where-Object { -not $actualDevFiles.Contains($_) })
    throw "Staged dev bundle is missing files: $($missing -join ', ')."
  }
  $configSessionAcl = Get-Acl -LiteralPath $sessionTempPath
  if (-not $configSessionAcl.AreAccessRulesProtected) { throw 'Development session file inherited permissions instead of using a protected ACL.' }
  $accessRules = @($configSessionAcl.Access | Where-Object { -not $_.IsInherited })
  $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $ruleSids = @(
    foreach ($rule in $accessRules) {
      $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
  )
  if ($accessRules.Count -ne 1 -or $ruleSids[0] -ne $currentSid) {
    throw 'Development session file ACL is not limited to the current Windows user.'
  }
  $sourcePayloadAfter = Get-SourcePayload -Root $toolRoot
  if ($sourcePayloadAfter.Count -ne $sourcePayload.Count) { throw 'The ACID source payload changed while the development bundle was being built.' }
  foreach ($relative in $sourcePayload.Keys) {
    if (-not $sourcePayloadAfter.ContainsKey($relative) -or $sourcePayloadAfter[$relative] -cne $sourcePayload[$relative]) {
      throw "ACID source file '$relative' changed while the development bundle was being built."
    }
  }

  New-Item -ItemType Directory -Path $outputFullPath -ErrorAction Stop | Out-Null
  $outputCreated = $true
  Assert-NoReparsePoint -Path $outputFullPath
  Move-Item -LiteralPath $stagedToolPath -Destination (Join-Path $outputFullPath $toolDirectoryName)
  Move-Item -LiteralPath $sessionTempPath -Destination $sessionPath

  Write-Output "Development ACID bundle: $(Join-Path $relativeOutputPath $toolDirectoryName)"
  Write-Output "Protected test session: $(Join-Path $relativeOutputPath 'acid-test-session.conf')"
  Write-Output "Loopback port: $port"
}
catch {
  if ($outputCreated -and (Test-Path -LiteralPath $outputFullPath)) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($outputFullPath)
    if (-not (Test-ContainedPath -Path $resolvedOutput -Parent $repoTempRoot)) {
      throw "Output path '$resolvedOutput' escaped repository tmp/; refusing cleanup."
    }
    Remove-Item -LiteralPath $resolvedOutput -Recurse -Force
  }
  throw
}
finally {
  if ($workCreated -and (Test-Path -LiteralPath $workPath)) {
    $resolvedWork = [System.IO.Path]::GetFullPath($workPath)
    if (-not (Test-ContainedPath -Path $resolvedWork -Parent $repoTempRoot)) {
      throw "Temporary build path '$resolvedWork' escaped repository tmp/; refusing cleanup."
    }
    Remove-Item -LiteralPath $resolvedWork -Recurse -Force
  }
}
