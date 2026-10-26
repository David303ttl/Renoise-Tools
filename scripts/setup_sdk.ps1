#Requires -Version 7.0

<#
.SYNOPSIS
Downloads and installs Renoise's pinned Lua API 6.2 starter pack.

.DESCRIPTION
Downloads the official API-6.2 release asset, verifies its SHA-256 digest, checks
archive paths, and installs definitions, offline documentation, and example tools
under sdk/renoise-api-6.2. A verified existing installation is left in place.

.EXAMPLE
./scripts/setup_sdk.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sdkParent = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'sdk'))
$destination = [System.IO.Path]::GetFullPath((Join-Path $sdkParent 'renoise-api-6.2'))
$downloadUrl = 'https://github.com/renoise/xrnx/releases/download/API-6.2/XRNX_Starter_Pack.zip'
$expectedSha256 = '575d6447dc1f2b3746fbf123df08f262abc027e04a5139caf892d7ce9189c49f'
$markerName = '.renoise-api-6.2.sha256'
$filesMarkerName = '.renoise-api-6.2.files.sha256'

function Test-ContainedPath {
    param([string]$Path, [string]$Parent)
    $parentPrefix = $Parent.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SdkInstallation {
    param([string]$Path)
    $marker = Join-Path $Path $markerName
    $filesMarker = Join-Path $Path $filesMarkerName
    $required = @(
        (Join-Path $Path 'definitions/plugin.lua'),
        (Join-Path $Path 'docs/index.html')
    )
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or -not (Test-Path -LiteralPath $filesMarker -PathType Leaf)) { return $false }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne $expectedSha256) { return $false }
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    }
    $examples = Join-Path $Path 'tools'
    if (-not (Test-Path -LiteralPath $examples -PathType Container)) { return $false }
    if (@(Get-ChildItem -LiteralPath $examples -File -Recurse).Count -eq 0) { return $false }

    $expectedFiles = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($filesMarker)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9a-fA-F]{64}$') { return $false }
        $relative = $parts[1].Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
        $file = [System.IO.Path]::GetFullPath((Join-Path $Path $relative))
        $prefix = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $file.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        if ($expectedFiles.ContainsKey($file)) { return $false }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $parts[0]) { return $false }
        $expectedFiles[$file] = $true
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object { $_.Name -ne $markerName -and $_.Name -ne $filesMarkerName })
    if ($actualFiles.Count -ne $expectedFiles.Count) { return $false }
    return $true
}

if (-not (Test-ContainedPath -Path $destination -Parent $sdkParent)) {
    throw "SDK destination '$destination' is outside the repository SDK directory."
}
if (Test-Path -LiteralPath $sdkParent -PathType Container) {
    $sdkParentItem = Get-Item -LiteralPath $sdkParent -Force
    if (($sdkParentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "SDK directory '$sdkParent' is a reparse point; refusing to write through it."
    }
}
elseif (Test-Path -LiteralPath $sdkParent) {
    throw "SDK path '$sdkParent' exists but is not a directory."
}
if (Test-Path -LiteralPath $destination -PathType Container) {
    $existing = Get-Item -LiteralPath $destination -Force
    if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "SDK destination '$destination' is a reparse point; refusing to replace it."
    }
    if (Test-SdkInstallation -Path $destination) {
        Write-Output "Renoise API 6.2 starter pack is already installed at '$destination'."
        return
    }
}
elseif (Test-Path -LiteralPath $destination) {
    throw "SDK destination '$destination' exists but is not a directory."
}

New-Item -ItemType Directory -Path $sdkParent -Force | Out-Null
$stageName = '.renoise-api-6.2.setup-' + [guid]::NewGuid().ToString('N')
$stagePath = [System.IO.Path]::GetFullPath((Join-Path $sdkParent $stageName))
$backupName = '.renoise-api-6.2.backup-' + [guid]::NewGuid().ToString('N')
$backupPath = [System.IO.Path]::GetFullPath((Join-Path $sdkParent $backupName))
$tempZip = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ('renoise-api-6.2-' + [guid]::NewGuid().ToString('N') + '.zip')))

if (-not (Test-ContainedPath -Path $stagePath -Parent $sdkParent) -or -not (Test-ContainedPath -Path $backupPath -Parent $sdkParent)) {
    throw 'Generated SDK staging path escaped the repository SDK directory.'
}

$installed = $false
try {
    if ($env:OS -eq 'Windows_NT') {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
    $actualSha256 = (Get-FileHash -LiteralPath $tempZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "Starter pack checksum mismatch. Expected $expectedSha256, got $actualSha256."
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
    try {
        New-Item -ItemType Directory -Path $stagePath -Force | Out-Null
        $stagePrefix = $stagePath.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($entryName) -or [System.IO.Path]::IsPathRooted($entryName) -or $entryName -match '(^|[\\/])\.\.([\\/]|$)' -or $entryName.Contains(':')) {
                throw "Starter pack contains an unsafe archive path '$($entry.FullName)'."
            }
            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $stagePath $entryName))
            if (-not $targetPath.StartsWith($stagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Starter pack entry '$($entry.FullName)' escapes the installation directory."
            }
            if ($entry.FullName.EndsWith('/')) {
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                continue
            }
            $targetDirectory = Split-Path -Parent $targetPath
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
            $inputStream = $entry.Open()
            try {
                $outputStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            }
            finally { $inputStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }

    Set-Content -LiteralPath (Join-Path $stagePath $markerName) -Value $expectedSha256 -NoNewline -Encoding ASCII
    $stagePrefix = $stagePath.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
    $fileRecords = @(
        Get-ChildItem -LiteralPath $stagePath -File -Recurse |
            Where-Object { $_.Name -ne $markerName -and $_.Name -ne $filesMarkerName } |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($stagePrefix.Length).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
                "{0}`t{1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relativePath
            }
    )
    [System.IO.File]::WriteAllLines((Join-Path $stagePath $filesMarkerName), $fileRecords, [System.Text.Encoding]::ASCII)
    if (-not (Test-SdkInstallation -Path $stagePath)) {
        throw 'The verified starter pack is missing API definitions, offline docs, or example tools.'
    }

    if (Test-Path -LiteralPath $destination -PathType Container) {
        $existing = Get-Item -LiteralPath $destination -Force
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "SDK destination '$destination' became a reparse point; refusing to replace it."
        }
        Move-Item -LiteralPath $destination -Destination $backupPath
        try {
            Move-Item -LiteralPath $stagePath -Destination $destination
            $installed = $true
        }
        catch {
            if (-not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $destination
            }
            throw
        }
        if (Test-Path -LiteralPath $backupPath) {
            if (-not (Test-ContainedPath -Path ([System.IO.Path]::GetFullPath($backupPath)) -Parent $sdkParent)) {
                throw "Backup path '$backupPath' is outside the SDK directory."
            }
            Remove-Item -LiteralPath $backupPath -Recurse -Force
        }
    }
    else {
        Move-Item -LiteralPath $stagePath -Destination $destination
        $installed = $true
    }

    Write-Output "Installed verified Renoise API 6.2 starter pack at '$destination'."
}
finally {
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }
    if (Test-Path -LiteralPath $stagePath) {
        if (-not (Test-ContainedPath -Path ([System.IO.Path]::GetFullPath($stagePath)) -Parent $sdkParent)) {
            throw "Staging path '$stagePath' is outside the SDK directory; refusing cleanup."
        }
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
    if ($installed -and (Test-Path -LiteralPath $backupPath)) {
        Remove-Item -LiteralPath $backupPath -Recurse -Force
    }
}
