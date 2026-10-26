#Requires -Version 7.0

<#
.SYNOPSIS
Packages Renoise tool directories as installable .xrnx archives.

.DESCRIPTION
Reads each tool's ID and version from its root manifest.xml. Archives contain
manifest.xml, Lua files, and supported runtime assets. Markdown and development
files are left out. Supported runtime assets are XML, TXT, JSON, SVG, common
image/audio formats, and BIN files; extend $runtimeExtensions when a tool adds
another runtime file type.

.PARAMETER Tool
Optional short name (ARP), manifest ID (com.david303ttl.ARP), or tool directory
name (com.david303ttl.ARP.xrnx). Omit to package every root .xrnx directory.

.PARAMETER OutputDirectory
Destination directory. Defaults to the repository's dist directory.

.EXAMPLE
.\scripts\package.ps1
Packages all tools into dist\.

.EXAMPLE
.\scripts\package.ps1 -Tool ARP
Packages only ARP.
#>
[CmdletBinding()]
param(
  # Accept a directory name (for example com.david303ttl.ARP.xrnx), a
  # manifest ID (com.david303ttl.ARP), or a short name (ARP).
  [Parameter(Position = 0)]
  [string[]] $Tool = @(),

  [string] $OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Xml.Linq

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $repoRoot 'dist'
}
$toolDirectories = @(Get-ChildItem -LiteralPath $repoRoot -Directory -Filter '*.xrnx' | Sort-Object Name)
if ($toolDirectories.Count -eq 0) {
  throw "No .xrnx tool directories found under '$repoRoot'."
}

if ($Tool.Count -gt 0) {
  $selected = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
  foreach ($requested in $Tool) {
    $matches = @($toolDirectories | Where-Object {
      $_.Name -eq $requested -or
      $_.Name -eq "$requested.xrnx" -or
      $_.Name.EndsWith(".$requested.xrnx", [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -ne 1) {
      throw "Tool '$requested' matched $($matches.Count) tool directories. Use a directory name such as com.david303ttl.ARP.xrnx."
    }
    if (@($selected | Where-Object FullName -eq $matches[0].FullName).Count -gt 0) {
      throw "Tool '$requested' was selected more than once."
    }
    $selected.Add($matches[0])
  }
  $toolDirectories = @($selected)
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputFullPath -Force | Out-Null
$packages = [System.Collections.Generic.List[object]]::new()
$runtimeExtensions = @('.lua', '.xml', '.txt', '.json', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.wav', '.aif', '.aiff', '.flac', '.ogg', '.bin')

foreach ($toolDirectory in $toolDirectories) {
  $toolRoot = [System.IO.Path]::GetFullPath($toolDirectory.FullName).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
  $manifestPath = Join-Path $toolDirectory.FullName 'manifest.xml'
  $mainPath = Join-Path $toolDirectory.FullName 'main.lua'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $mainPath -PathType Leaf)) {
    throw "Tool '$($toolDirectory.Name)' must contain manifest.xml and main.lua at its root."
  }

  $settings = [System.Xml.XmlReaderSettings]::new()
  $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
  $settings.XmlResolver = $null
  $reader = [System.Xml.XmlReader]::Create($manifestPath, $settings)
  try {
    $manifest = [System.Xml.Linq.XDocument]::Load($reader)
  }
  finally {
    $reader.Dispose()
  }
  $idElement = $manifest.Root.Element('Id')
  $versionElement = $manifest.Root.Element('Version')
  $id = if ($null -eq $idElement) { '' } else { $idElement.Value }
  $version = if ($null -eq $versionElement) { '' } else { $versionElement.Value }
  if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "Tool '$($toolDirectory.Name)' has an invalid or missing manifest Id '$id'."
  }
  if ($version -notmatch '^[0-9]+(?:\.[0-9A-Za-z-]+)*$') {
    throw "Tool '$($toolDirectory.Name)' has an invalid or missing manifest Version '$version'."
  }

  $files = @(Get-ChildItem -LiteralPath $toolDirectory.FullName -File -Recurse | Where-Object {
    $_.Name -ne 'manifest.xml' -and $runtimeExtensions -contains $_.Extension.ToLowerInvariant()
  })
  $files += Get-Item -LiteralPath $manifestPath
  if (-not ($files | Where-Object { $_.FullName -eq [System.IO.Path]::GetFullPath($mainPath) })) {
    throw "Tool '$($toolDirectory.Name)' has no packageable main.lua."
  }

  $entries = [System.Collections.Generic.List[object]]::new()
  foreach ($file in $files) {
    $full = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $full.StartsWith($toolRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Runtime file '$full' resolves outside tool '$($toolDirectory.Name)'."
    }
    $relative = $full.Substring($toolRoot.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or $relative -match '(^|/)\.\.(/|$)') {
      throw "Unsafe archive path '$relative' in tool '$($toolDirectory.Name)'."
    }
    $entries.Add([pscustomobject]@{ Path = $relative; File = $full })
  }
  $duplicatePaths = @($entries | Group-Object Path | Where-Object Count -gt 1)
  if ($duplicatePaths.Count -gt 0) {
    throw "Tool '$($toolDirectory.Name)' contains duplicate package paths: $($duplicatePaths.Name -join ', ')."
  }
  if (-not ($entries | Where-Object Path -eq 'manifest.xml') -or -not ($entries | Where-Object Path -eq 'main.lua')) {
    throw "Package for '$($toolDirectory.Name)' must put manifest.xml and main.lua at archive root."
  }

  $archiveName = "${id}_${version}.xrnx"
  if ($archiveName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "Unsafe archive filename '$archiveName'."
  }
  $archivePath = Join-Path $outputFullPath $archiveName
  if (@($packages | Where-Object ArchivePath -eq $archivePath).Count -gt 0) {
    throw "Multiple tools would produce the same archive '$archiveName'."
  }
  $packages.Add([pscustomobject]@{ Tool = $toolDirectory.Name; ArchivePath = $archivePath; Entries = @($entries) })
}

foreach ($package in $packages) {
  $tempPath = "$($package.ArchivePath).$([guid]::NewGuid().ToString('N')).tmp"
  try {
    $stream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::CreateNew)
    try {
      $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
      try {
        foreach ($entry in $package.Entries) {
          $zipEntry = $archive.CreateEntry($entry.Path, [System.IO.Compression.CompressionLevel]::Optimal)
          $input = [System.IO.File]::OpenRead($entry.File)
          try {
            $target = $zipEntry.Open()
            try { $input.CopyTo($target) } finally { $target.Dispose() }
          }
          finally { $input.Dispose() }
        }
      }
      finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    try {
      $check = [System.IO.Compression.ZipFile]::OpenRead($tempPath)
      try {
        $names = @($check.Entries | ForEach-Object FullName)
        if ($names -notcontains 'manifest.xml' -or $names -notcontains 'main.lua') {
          throw "Created archive '$($package.ArchivePath)' failed root-entry validation."
        }
        if (@($names | Where-Object { $_.StartsWith('/') -or $_ -match '(^|/)\.\.(/|$)' }).Count -gt 0) {
          throw "Created archive '$($package.ArchivePath)' contains an unsafe entry path."
        }
      }
      finally { $check.Dispose() }

      if (Test-Path -LiteralPath $package.ArchivePath) {
        # The temporary archive shares the destination volume, so replacement
        # leaves the previous package intact unless validation has succeeded.
        $backupPath = "$($package.ArchivePath).$([guid]::NewGuid().ToString('N')).bak"
        [System.IO.File]::Replace($tempPath, $package.ArchivePath, $backupPath)
        if (Test-Path -LiteralPath $backupPath) {
          Remove-Item -LiteralPath $backupPath -Force
        }
      }
      else {
        [System.IO.File]::Move($tempPath, $package.ArchivePath)
      }
    }
    finally {
      if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
      }
    }
  }
  catch {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force
    }
    throw
  }
  Write-Output "Packaged $($package.Tool) -> $($package.ArchivePath) ($($package.Entries.Count) runtime files)"
}
