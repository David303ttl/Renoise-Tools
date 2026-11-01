#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RenoiseExe,
    [string]$OutputName = 'phrase-inventory.xrns',
    [switch]$Force,
    [switch]$ApproveInstall,
    [ValidateRange(5,600)][int]$StartupTimeoutSeconds = 90,
    [ValidateRange(10,300)][int]$SaveTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$probeSource = Join-Path $PSScriptRoot 'probe'
$bundleName = 'com.david303ttl.ACID.xrnx'
$sidecarName = 'acid-fixture-probe.conf'
$payloadPath = Join-Path $repoRoot 'tests/acid/fixtures/pattern_store.txt'
$fixturesDirectory = Join-Path $PSScriptRoot 'fixtures'
$outputPath = Join-Path $fixturesDirectory $OutputName
$runId = [guid]::NewGuid().ToString('N')
$stagingRoot = Join-Path (Join-Path $repoRoot 'tmp') ('acid-fixture-probe-' + $runId)
$stagedBundle = Join-Path $stagingRoot $bundleName
$stagedSidecar = Join-Path $stagingRoot $sidecarName
$targetPath = Join-Path $stagingRoot 'phrase-inventory.xrns'
$manifestPath = Join-Path $stagingRoot 'content-manifest.txt'
$markerPath = $targetPath + '.done'
$backupRoot = Join-Path $stagingRoot 'backup'
$nonce = [guid]::NewGuid().ToString('N')

$script:toolsPath = $null
$script:installedToolPath = $null
$script:installedSidecarPath = $null
$script:deploymentStarted = $false
$script:deploymentStageRoot = $null
$script:deploymentStageToolPath = $null
$script:deploymentStageSidecarPath = $null
$script:localBackupToolPath = $null
$script:localBackupSidecarPath = $null
$script:backupToolPath = $null
$script:backupSidecarPath = $null
$script:stageToolHash = $null
$script:stageSidecarHash = $null
$script:installedDirectoryHash = $null
$script:installedSidecarHash = $null
$script:toolDeployed = $false
$script:sidecarDeployed = $false
$script:startedProcess = $null
$script:startedIdentity = $null

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FixtureOutputBoundary {
    $repositoryPath = [IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $repositoryPrefix = $repositoryPath + [IO.Path]::DirectorySeparatorChar
    $fixturesPath = [IO.Path]::GetFullPath($fixturesDirectory)
    if (-not $fixturesPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixture output directory resolves outside the repository.'
    }
    $ancestorPath = $fixturesPath
    while (-not [string]::Equals($ancestorPath, $repositoryPath, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $ancestorPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fixture output directory ancestry escapes the repository.'
        }
        if (Test-Path -LiteralPath $ancestorPath) {
            $ancestorItem = Get-Item -LiteralPath $ancestorPath -Force
            if (-not $ancestorItem.PSIsContainer -or ($ancestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Fixture output directory ancestry is not plain; refusing to write through it.'
            }
        }
        $ancestorPath = [IO.Path]::GetDirectoryName($ancestorPath)
    }
    $resolvedOutputPath = [IO.Path]::GetFullPath($outputPath)
    if (-not $resolvedOutputPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($resolvedOutputPath), $fixturesPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixture output path is not a direct repository child of the fixture directory.'
    }
    if (Test-Path -LiteralPath $resolvedOutputPath) {
        $outputItem = Get-Item -LiteralPath $resolvedOutputPath -Force
        if ($outputItem.PSIsContainer -or ($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Fixture output is not a plain file; refusing to replace it.'
        }
    }
}

function Get-VersionTriplet {
    param([Parameter(Mandatory)][string]$Value)
    $match = [regex]::Match($Value, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
    if (-not $match.Success) { throw "Could not resolve Renoise version from '$Value'." }
    return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Copy-ProbeBundle {
    param([Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $probeSource 'manifest.xml') -Destination (Join-Path $Destination 'manifest.xml')
    Copy-Item -LiteralPath (Join-Path $probeSource 'main.lua') -Destination (Join-Path $Destination 'main.lua')
}

function Invoke-ProbeDeployment {
    $script:deploymentStarted = $true
    $script:deploymentStageRoot = Join-Path $script:toolsPath ('.acid-fixture-probe-stage-' + $runId)
    $script:deploymentStageToolPath = Join-Path $script:deploymentStageRoot $bundleName
    $script:deploymentStageSidecarPath = Join-Path $script:deploymentStageRoot $sidecarName
    $script:localBackupToolPath = Join-Path $script:toolsPath ('.acid-fixture-probe-restore-' + $runId)
    $script:localBackupSidecarPath = Join-Path $script:toolsPath ('.acid-fixture-probe-restore-' + $runId + '.conf')

    foreach ($path in @($script:deploymentStageRoot, $script:localBackupToolPath, $script:localBackupSidecarPath)) {
        if (Test-Path -LiteralPath $path) { throw 'A unique temporary deployment path already exists; refusing to reuse it.' }
    }

    New-Item -ItemType Directory -Path $script:deploymentStageRoot | Out-Null
    Copy-ProbeBundle -Destination $script:deploymentStageToolPath
    Copy-Item -LiteralPath $stagedSidecar -Destination $script:deploymentStageSidecarPath
    $script:stageToolHash = Get-DirectoryHash -Path $script:deploymentStageToolPath
    $script:stageSidecarHash = Get-FileSha256 -Path $script:deploymentStageSidecarPath
    if ($script:stageToolHash -cne (Get-DirectoryHash -Path $stagedBundle)) { throw 'Staged probe bundle copy did not verify; refusing installation.' }
    if ($script:stageSidecarHash -cne (Get-FileSha256 -Path $stagedSidecar)) { throw 'Staged probe sidecar copy did not verify; refusing installation.' }

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    if (Test-Path -LiteralPath $script:installedToolPath) {
        $installed = Get-Item -LiteralPath $script:installedToolPath -Force
        if (($installed.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $installed.PSIsContainer) {
            throw 'Existing probe installation is not a plain directory; refusing replacement.'
        }
        $script:backupToolPath = Join-Path $backupRoot ('previous-' + $bundleName)
        Copy-Item -LiteralPath $script:installedToolPath -Destination $script:backupToolPath -Recurse
        if ((Get-DirectoryHash -Path $script:installedToolPath) -cne (Get-DirectoryHash -Path $script:backupToolPath)) {
            throw 'Probe backup copy did not verify; refusing replacement.'
        }
        Move-Item -LiteralPath $script:installedToolPath -Destination $script:localBackupToolPath
    }

    if (Test-Path -LiteralPath $script:installedSidecarPath) {
        $sidecar = Get-Item -LiteralPath $script:installedSidecarPath -Force
        if ($sidecar.PSIsContainer -or ($sidecar.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Existing probe sidecar is not a plain file; refusing replacement.'
        }
        $script:backupSidecarPath = Join-Path $backupRoot ('previous-' + $sidecarName)
        Copy-Item -LiteralPath $script:installedSidecarPath -Destination $script:backupSidecarPath
        if ((Get-FileSha256 -Path $script:installedSidecarPath) -cne (Get-FileSha256 -Path $script:backupSidecarPath)) {
            throw 'Probe sidecar backup copy did not verify; refusing replacement.'
        }
        Move-Item -LiteralPath $script:installedSidecarPath -Destination $script:localBackupSidecarPath
    }

    $script:installedDirectoryHash = $script:stageToolHash
    $script:installedSidecarHash = $script:stageSidecarHash
    Move-Item -LiteralPath $script:deploymentStageToolPath -Destination $script:installedToolPath
    $script:toolDeployed = $true
    Move-Item -LiteralPath $script:deploymentStageSidecarPath -Destination $script:installedSidecarPath
    $script:sidecarDeployed = $true
}

function Close-ProbeProcess {
    if (-not $script:startedProcess) { return }
    $script:startedProcess.Refresh()
    if ($script:startedProcess.HasExited) { return }
    if (-not $script:startedIdentity) { throw 'Launched Renoise process identity was not verified; leaving it untouched.' }
    Assert-RenoiseProcessIdentity -Identity $script:startedIdentity
    [void]$script:startedProcess.CloseMainWindow()
    if ($script:startedProcess.WaitForExit(10000)) { return }
    Assert-RenoiseProcessIdentity -Identity $script:startedIdentity
    Stop-Process -Id $script:startedIdentity.Id -Force -ErrorAction Stop
    if (-not $script:startedProcess.WaitForExit(5000)) { throw 'Launched Renoise process did not terminate after identity-checked cleanup.' }
}

function Invoke-ProbeRestoration {
    $problems = [Collections.Generic.List[string]]::new()

    if ($script:toolDeployed -and $script:installedToolPath -and (Test-Path -LiteralPath $script:installedToolPath)) {
        if (-not $script:installedDirectoryHash -or (Get-DirectoryHash -Path $script:installedToolPath) -cne $script:installedDirectoryHash) {
            $problems.Add('Deployed probe bundle changed during the run; keeping it and the restoration backup untouched.')
        } else {
            Remove-Item -LiteralPath $script:installedToolPath -Recurse -Force
        }
    }
    if ($script:localBackupToolPath -and (Test-Path -LiteralPath $script:localBackupToolPath)) {
        if (Test-Path -LiteralPath $script:installedToolPath) {
            $problems.Add('Probe installation target is occupied; keeping the same-volume original and verified run backup untouched.')
        } else {
            Move-Item -LiteralPath $script:localBackupToolPath -Destination $script:installedToolPath
        }
    }

    if ($script:sidecarDeployed -and $script:installedSidecarPath -and (Test-Path -LiteralPath $script:installedSidecarPath)) {
        if (-not $script:installedSidecarHash -or (Get-FileSha256 -Path $script:installedSidecarPath) -cne $script:installedSidecarHash) {
            $problems.Add('Deployed probe sidecar changed during the run; keeping it and the restoration backup untouched.')
        } else {
            Remove-Item -LiteralPath $script:installedSidecarPath -Force
        }
    }
    if ($script:localBackupSidecarPath -and (Test-Path -LiteralPath $script:localBackupSidecarPath)) {
        if (Test-Path -LiteralPath $script:installedSidecarPath) {
            $problems.Add('Probe sidecar target is occupied; keeping the same-volume original and verified run backup untouched.')
        } else {
            Move-Item -LiteralPath $script:localBackupSidecarPath -Destination $script:installedSidecarPath
        }
    }

    if ($script:deploymentStageRoot -and (Test-Path -LiteralPath $script:deploymentStageRoot)) {
        if ((Test-Path -LiteralPath $script:deploymentStageToolPath) -and
            (Get-DirectoryHash -Path $script:deploymentStageToolPath) -cne $script:stageToolHash) {
            $problems.Add('Staged probe bundle changed; preserving the staging directory for recovery.')
        } elseif ((Test-Path -LiteralPath $script:deploymentStageSidecarPath) -and
            (Get-FileSha256 -Path $script:deploymentStageSidecarPath) -cne $script:stageSidecarHash) {
            $problems.Add('Staged probe sidecar changed; preserving the staging directory for recovery.')
        } else {
            Remove-Item -LiteralPath $script:deploymentStageRoot -Recurse -Force
        }
    }

    if ($problems.Count -gt 0) {
        $retained = [Collections.Generic.List[string]]::new()
        if ($script:backupToolPath -and (Test-Path -LiteralPath $script:backupToolPath)) { $retained.Add("run bundle backup: $($script:backupToolPath)") }
        if ($script:backupSidecarPath -and (Test-Path -LiteralPath $script:backupSidecarPath)) { $retained.Add("run sidecar backup: $($script:backupSidecarPath)") }
        if ($script:localBackupToolPath -and (Test-Path -LiteralPath $script:localBackupToolPath)) { $retained.Add("same-volume bundle restore: $($script:localBackupToolPath)") }
        if ($script:localBackupSidecarPath -and (Test-Path -LiteralPath $script:localBackupSidecarPath)) { $retained.Add("same-volume sidecar restore: $($script:localBackupSidecarPath)") }
        if ($script:deploymentStageRoot -and (Test-Path -LiteralPath $script:deploymentStageRoot)) { $retained.Add("Tools staging directory: $($script:deploymentStageRoot)") }
        throw ('Installation restoration did not complete: ' + ($problems -join ' ') + ' Retained: ' + ($retained -join '; '))
    }
}

if ($OutputName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.xrns$') {
    throw "OutputName must be a plain .xrns file name: $OutputName"
}
Assert-FixtureOutputBoundary
if (Test-Path -LiteralPath $outputPath) {
    if (-not $Force) { throw "Fixture output already exists; pass -Force to replace it: $outputPath" }
}

$payloadText = [IO.File]::ReadAllText($payloadPath, [Text.UTF8Encoding]::new($false))
$payloadText = $payloadText -replace "`r`n", "`n"
if (-not $payloadText.StartsWith("ACID-PITCH-TIME-1`n", [StringComparison]::Ordinal)) {
    throw 'Tool data fixture does not start with the required header.'
}
$sourceRows = @($payloadText -split "`n" | Where-Object { $_.StartsWith('2|repeat|24|triplet|3|17|', [StringComparison]::Ordinal) })
if ($sourceRows.Count -lt 1) { throw 'Tool data fixture is missing the committed ID 2 source row.' }
$payloadBytes = [Text.Encoding]::UTF8.GetBytes($payloadText)
$toolDataHex = [Convert]::ToHexString($payloadBytes).ToLowerInvariant()
$payloadLength = $payloadBytes.Length
if ($payloadLength -le 0) { throw 'Tool data fixture is empty.' }

Import-Module (Join-Path $repoRoot 'tests/renoise/runner.psm1') -Force
Import-Module (Join-Path $repoRoot 'tests/renoise/host_preflight.psm1') -Force

$resolvedExe = Get-RenoiseExecutable -ConfiguredPath $RenoiseExe
$preflight = Test-RenoiseHostPreflight -Configuration ([pscustomobject]@{
    RenoiseExe = $resolvedExe
    RenoiseProcessId = 0
    TemporaryDirectory = [IO.Path]::GetTempPath()
}) -Mode Safety
if (-not $preflight.Passed) { throw "Renoise host preflight failed: $($preflight.Errors -join '; ')" }

$runningRenoise = @(Get-Process -Name 'Renoise' -ErrorAction SilentlyContinue)
if ($runningRenoise.Count -gt 0) {
    throw 'Close all running Renoise instances before building the fixture; the builder launches and closes its own instance.'
}

$exeInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedExe)
$versionTriplet = Get-VersionTriplet -Value ([string]$exeInfo.ProductVersion)
$appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
if (-not $appData) { throw 'Could not resolve the current user ApplicationData directory.' }
$script:toolsPath = Join-Path $appData ("Renoise/V$($versionTriplet.ToString(3))/Scripts/Tools")
$script:installedToolPath = Join-Path $script:toolsPath $bundleName
$script:installedSidecarPath = Join-Path $script:toolsPath $sidecarName

if (-not $ApproveInstall) {
    throw "Installing the development probe requires -ApproveInstall. Target Tools directory: $($script:toolsPath)"
}
New-Item -ItemType Directory -Path $script:toolsPath -Force | Out-Null

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
Copy-ProbeBundle -Destination $stagedBundle
$sidecarText = @(
    "target=$targetPath",
    "manifest=$manifestPath",
    "tool_data_hex=$toolDataHex",
    "nonce=$nonce"
) -join "`n"
[IO.File]::WriteAllText($stagedSidecar, $sidecarText + "`n", [Text.UTF8Encoding]::new($false))

try {
    Invoke-ProbeDeployment

    $script:startedProcess = Start-Process -FilePath $resolvedExe -WindowStyle Hidden -PassThru
    $script:startedIdentity = Get-RenoiseProcessIdentity -Id $script:startedProcess.Id
    if (-not [string]::Equals($script:startedIdentity.Path, $resolvedExe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Started Renoise process does not match the verified executable.'
    }

    $startupDeadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $startupDeadline) {
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) { break }
        $script:startedProcess.Refresh()
        if ($script:startedProcess.HasExited) {
            throw "Renoise exited during startup (exit code $($script:startedProcess.ExitCode))."
        }
        if ($script:startedProcess.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 500
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($SaveTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) { break }
        $script:startedProcess.Refresh()
        if ($script:startedProcess.HasExited) {
            throw "Renoise exited before writing the completion marker (exit code $($script:startedProcess.ExitCode))."
        }
        Start-Sleep -Seconds 2
    }
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Timed out after $SaveTimeoutSeconds seconds waiting for the probe completion marker."
    }

    $markerValues = @{}
    foreach ($line in [IO.File]::ReadAllLines($markerPath)) {
        $trimmed = $line.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $parts = $trimmed.Split([char[]]@('='), 2)
        if ($parts.Count -ne 2) { throw 'Probe completion marker is malformed.' }
        if ($markerValues.ContainsKey($parts[0])) { throw 'Probe completion marker contains a duplicate key.' }
        $markerValues[$parts[0]] = $parts[1]
    }
    if (-not $markerValues.ContainsKey('status')) { throw 'Probe completion marker is missing its status.' }
    if (-not $markerValues.ContainsKey('nonce') -or $markerValues.nonce -cne $nonce) {
        throw 'Probe completion marker does not match the run nonce.'
    }
    if ($markerValues.status -cne 'ok') {
        $detail = if ($markerValues.ContainsKey('detail')) { $markerValues.detail } else { '' }
        throw "Probe reported $($markerValues.status): $detail"
    }

    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw 'Probe reported success but the XRNS file is missing.' }
    $outputItem = Get-Item -LiteralPath $targetPath
    if ($outputItem.Length -le 0) { throw 'Probe reported success but the XRNS file is empty.' }
    New-Item -ItemType Directory -Path $fixturesDirectory -Force | Out-Null
    $stagedOutput = Join-Path $stagingRoot ('publish-' + $OutputName)
    Copy-Item -LiteralPath $targetPath -Destination $stagedOutput
    $stagedOutputHash = Get-FileSha256 -Path $stagedOutput
    if ((Get-Item -LiteralPath $stagedOutput).Length -ne $outputItem.Length -or
        $stagedOutputHash -cne (Get-FileSha256 -Path $targetPath)) {
        throw 'Staged fixture copy did not verify.'
    }

    $previousOutput = Join-Path $stagingRoot ('previous-' + $OutputName)
    $publishedOutput = $false
    $hadPreviousOutput = Test-Path -LiteralPath $outputPath
    try {
        if ($hadPreviousOutput) {
            if (-not $Force) { throw "Fixture output appeared during generation; refusing replacement: $outputPath" }
            [IO.File]::Replace($stagedOutput, $outputPath, $previousOutput, $true)
            $publishedOutput = $true
        } else {
            Move-Item -LiteralPath $stagedOutput -Destination $outputPath
            $publishedOutput = $true
        }
        if ((Get-FileSha256 -Path $outputPath) -cne $stagedOutputHash) {
            throw 'Published fixture hash does not match the verified staged copy.'
        }
    } catch {
        if ($publishedOutput -and (Test-Path -LiteralPath $outputPath)) {
            if ($hadPreviousOutput -and (Test-Path -LiteralPath $previousOutput)) {
                $failedOutput = Join-Path $stagingRoot ('failed-' + $OutputName)
                [IO.File]::Replace($previousOutput, $outputPath, $failedOutput, $true)
            } else {
                Remove-Item -LiteralPath $outputPath -Force
            }
        }
        throw
    }
    $copied = Get-Item -LiteralPath $outputPath

    $relativeOutput = [IO.Path]::GetRelativePath($repoRoot, $outputPath)
    $relativeManifest = [IO.Path]::GetRelativePath($repoRoot, $manifestPath)
    Write-Output "Output: $relativeOutput"
    Write-Output "Bytes: $($copied.Length)"
    Write-Output "SHA256: $(Get-FileSha256 -Path $outputPath)"
    Write-Output "Content manifest: $relativeManifest"
}
finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try { Close-ProbeProcess }
    catch { $cleanupErrors.Add("Process cleanup failed: $($_.Exception.Message)") }
    try { Invoke-ProbeRestoration }
    catch { $cleanupErrors.Add($_.Exception.Message) }
    if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join ' ') }
}
