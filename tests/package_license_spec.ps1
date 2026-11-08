#Requires -Version 7.0
# Verify that every standalone XRNX archive carries the repository GPLv3 text.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
$licensePath = Join-Path $repoRoot 'LICENSE'
$expected = [System.IO.File]::ReadAllText($licensePath)
if (-not $expected.StartsWith("GNU GENERAL PUBLIC LICENSE")) {
  throw 'Root LICENSE is not the expected full GPLv3 license text.'
}
$toolDirs = @(Get-ChildItem -LiteralPath $repoRoot -Directory -Filter '*.xrnx')
if ($toolDirs.Count -eq 0) { throw 'No XRNX tool directories found.' }

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('renoise-license-' + [guid]::NewGuid().ToString('N'))
try {
  & (Join-Path $repoRoot 'scripts/package.ps1') -OutputDirectory $tempDir | Out-Host
  foreach ($toolDir in $toolDirs) {
    $toolLicense = Join-Path $toolDir.FullName 'LICENSE'
    if (-not (Test-Path -LiteralPath $toolLicense -PathType Leaf)) {
      throw "Missing LICENSE in $($toolDir.Name)"
    }
    if ([System.IO.File]::ReadAllText($toolLicense) -cne $expected) {
      throw "LICENSE differs from root text in $($toolDir.Name)"
    }
    [xml] $manifest = Get-Content -LiteralPath (Join-Path $toolDir.FullName 'manifest.xml') -Raw
    if ($manifest.RenoiseScriptingTool.License -cne 'GPL-3.0-only' -or
        $manifest.RenoiseScriptingTool.LicensePath -cne 'LICENSE') {
      throw "Missing GPL-3.0-only license metadata in $($toolDir.Name)"
    }
    $id = $manifest.RenoiseScriptingTool.Id
    $version = $manifest.RenoiseScriptingTool.Version
    $package = Join-Path $tempDir ($id + '_' + $version + '.xrnx')
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
      throw "Missing packaged XRNX for $($toolDir.Name)"
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($package)
    try {
      $manifestEntry = $archive.GetEntry('manifest.xml')
      if ($null -eq $manifestEntry) { throw "Missing manifest.xml in $package" }
      $manifestReader = [System.IO.StreamReader]::new($manifestEntry.Open(), [System.Text.Encoding]::UTF8)
      try { [xml] $packagedManifest = $manifestReader.ReadToEnd() }
      finally { $manifestReader.Dispose() }
      if ($packagedManifest.RenoiseScriptingTool.License -cne 'GPL-3.0-only' -or
          $packagedManifest.RenoiseScriptingTool.LicensePath -cne 'LICENSE') {
        throw "Missing GPL-3.0-only license metadata in packaged manifest $package"
      }
      $entry = $archive.GetEntry('LICENSE')
      if ($null -eq $entry) { throw "Missing archive-root LICENSE in $package" }
      $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
      try { $actual = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if ($actual -cne $expected) { throw "LICENSE content differs in $package" }
    }
    finally { $archive.Dispose() }
  }
  Write-Host "$($toolDirs.Count) XRNX archive licenses verified."
}
finally {
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
  }
}
