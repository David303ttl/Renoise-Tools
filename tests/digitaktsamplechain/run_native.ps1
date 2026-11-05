#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RenoiseExe,
    [ValidateRange(10,600)][int]$StartupTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolsModulePath = Join-Path $repoRoot 'tests/renoise/runner.psm1'
$sourceBundlePath = Join-Path $repoRoot 'com.david303ttl.DigitaktSampleChain.xrnx'
$probeSourcePath = Join-Path $PSScriptRoot 'native_probe.lua'
$jsonSourcePath = Join-Path $repoRoot 'tests/renoise/driver/json.lua'
$probeBundleName = 'com.david303ttl.DigitaktSampleChainNativeTests.xrnx'
$reportName = 'native-report.json'
$pollIntervalMilliseconds = 250
$shutdownGraceMilliseconds = 5000
$runId = [guid]::NewGuid().ToString('N')
$nonce = [guid]::NewGuid().ToString('D')
$stagingRoot = Join-Path $repoRoot ('tmp/digitakt-native-' + $runId)
$stagedBundlePath = Join-Path $stagingRoot 'bundle'
$reportPath = Join-Path $stagingRoot $reportName
$installedBundlePath = $null
$installedBundleHash = $null
$ownedProcess = $null
$ownedIdentity = $null
$ownedIdentityVerified = $false
$module = $null

function Get-RenoiseProcesses {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Renoise(?:\..*)?$' })
}

function Assert-NoRenoiseProcesses {
    $processes = @(Get-RenoiseProcesses)
    if ($processes.Count -gt 0) {
        throw 'A Renoise process is already running; refusing to install or launch the native probe.'
    }
}

try {
    Import-Module $toolsModulePath -Force
    $module = Get-Module -Name runner
    if (-not $module) { throw 'Could not import the shared Renoise runner module.' }

    Assert-NoRenoiseProcesses
    $resolvedExe = Get-RenoiseExecutable -ConfiguredPath $RenoiseExe
    foreach ($requiredPath in @($sourceBundlePath, $probeSourcePath, $jsonSourcePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $requiredPath -PathType Container)) {
            throw "Required native-test input is missing: $requiredPath"
        }
    }

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedExe)
    $versionMatch = [regex]::Match([string]$versionInfo.ProductVersion, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
    if (-not $versionMatch.Success) { throw 'Could not resolve Renoise version from executable metadata.' }
    $version = [version]::new([int]$versionMatch.Groups[1].Value, [int]$versionMatch.Groups[2].Value, [int]$versionMatch.Groups[3].Value)
    $appData = [IO.Path]::GetFullPath([Environment]::GetEnvironmentVariable('APPDATA'))
    $toolsPath = Join-Path $appData ('Renoise/V{0}/Scripts/Tools' -f $version.ToString(3))
    if (-not (Test-Path -LiteralPath $toolsPath -PathType Container)) {
        throw "Version-matched Renoise Tools directory is missing: $toolsPath"
    }

    $installedBundlePath = Join-Path $toolsPath $probeBundleName
    if (Test-Path -LiteralPath $installedBundlePath) {
        throw "Native probe already exists; refusing to replace it: $installedBundlePath"
    }
    if (Test-Path -LiteralPath $stagingRoot) { throw "Unique staging path already exists: $stagingRoot" }
    New-Item -ItemType Directory -Path $stagedBundlePath -Force | Out-Null

    foreach ($luaFile in Get-ChildItem -LiteralPath $sourceBundlePath -Filter '*.lua' -File) {
        $targetName = if ($luaFile.Name -ceq 'main.lua') { 'production_main.lua' } else { $luaFile.Name }
        Copy-Item -LiteralPath $luaFile.FullName -Destination (Join-Path $stagedBundlePath $targetName)
    }
    Copy-Item -LiteralPath $probeSourcePath -Destination (Join-Path $stagedBundlePath 'main.lua')
    Copy-Item -LiteralPath $jsonSourcePath -Destination (Join-Path $stagedBundlePath 'native_json.lua')
    $manifest = @'
<?xml version="1.0" encoding="UTF-8"?>
<RenoiseScriptingTool doc_version="0">
  <ApiVersion>6.2</ApiVersion>
  <Id>com.david303ttl.DigitaktSampleChainNativeTests</Id>
  <Version>1.0</Version>
  <Author>Native Test Runner</Author>
  <Name>DigitaktSampleChain Native Tests</Name>
  <Category>Test</Category>
  <Description>Temporary native tests for DigitaktSampleChain</Description>
  <License>GPL-3.0-only</License>
</RenoiseScriptingTool>
'@
    [IO.File]::WriteAllText((Join-Path $stagedBundlePath 'manifest.xml'), $manifest, [Text.UTF8Encoding]::new($false))
    $runDirectory = [IO.Path]::GetFullPath($stagingRoot).Replace('\', '/')
    $nativeConfig = [ordered]@{ run_directory = $runDirectory; nonce = $nonce } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $stagedBundlePath 'native-config.json'), $nativeConfig, [Text.UTF8Encoding]::new($false))

    $stagedBundleHash = Get-DirectoryHash -Path $stagedBundlePath
    Assert-DirectoryHasNoReparsePoints -Path $stagedBundlePath
    Assert-NoRenoiseProcesses
    if (Test-Path -LiteralPath $installedBundlePath) {
        throw "Native probe appeared during staging; refusing to replace it: $installedBundlePath"
    }
    $installedBundleHash = $stagedBundleHash
    Copy-Item -LiteralPath $stagedBundlePath -Destination $installedBundlePath -Recurse
    if ((Get-DirectoryHash -Path $installedBundlePath) -cne $installedBundleHash) {
        throw 'Installed native probe does not match the staged bundle.'
    }

    Assert-NoRenoiseProcesses
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedExe
    $startInfo.UseShellExecute = $false
    $ownedProcess = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $ownedProcess) { throw 'Could not start the Renoise native-test process.' }
    $ownedIdentity = Get-RenoiseProcessIdentity -Id $ownedProcess.Id -WaitMilliseconds 5000
    if (-not [string]::Equals($ownedIdentity.Path, $resolvedExe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Started Renoise process does not match the discovered executable.'
    }
    $ownedIdentityVerified = $true

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $report = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Assert-RenoiseProcessIdentity -Identity $ownedIdentity
        $ownedProcess.Refresh()
        if ($ownedProcess.HasExited) { throw "Renoise exited before writing the native report (exit code $($ownedProcess.ExitCode))." }
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            try {
                $candidateReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -Depth 32 -ErrorAction Stop
            }
            catch {
                Start-Sleep -Milliseconds $pollIntervalMilliseconds
                continue
            }
            if ($null -eq $candidateReport -or $candidateReport -is [array] -or
                -not $candidateReport.PSObject.Properties['nonce'] -or
                $candidateReport.nonce -isnot [string] -or $candidateReport.nonce -cne $nonce) {
                throw 'Native report nonce does not match this run.'
            }
            if (-not $candidateReport.PSObject.Properties['status'] -or
                $candidateReport.status -cnotin @('RUNNING','PASS','FAIL')) {
                throw 'Native report contains an invalid status.'
            }
            if ($candidateReport.status -cne 'RUNNING') {
                $report = $candidateReport
                break
            }
        }
        Start-Sleep -Milliseconds $pollIntervalMilliseconds
    }
    if ($null -eq $report) { throw "Timed out after $StartupTimeoutSeconds seconds waiting for a terminal native report: $reportPath" }
    if ($report.status -ceq 'FAIL') {
        $failedCases = @($report.cases | Where-Object { $_.status -cne 'PASS' })
        $failureDetails = if ($failedCases.Count -gt 0) {
            ($failedCases | ForEach-Object { '{0}: {1}' -f $_.name, $_.detail }) -join [Environment]::NewLine
        } else { 'The probe reported FAIL without failed case details.' }
        Write-Output "DigitaktSampleChain native tests: FAIL"
        Write-Output "Report: $reportPath"
        throw "Native cases failed:$([Environment]::NewLine)$failureDetails"
    }
    $cases = @($report.cases)
    if ($cases.Count -eq 0 -or @($cases | Where-Object { $_.status -cne 'PASS' }).Count -gt 0) {
        throw 'Native report must contain one or more cases, all with status PASS.'
    }
    Write-Output ("DigitaktSampleChain native tests: PASS ({0} cases)" -f $cases.Count)
    Write-Output "Report: $reportPath"
}
finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    $processStoppedConfirmed = $null -eq $ownedProcess
    if ($ownedProcess) {
        try {
            $ownedProcess.Refresh()
            if ($ownedProcess.HasExited) {
                $processStoppedConfirmed = $true
            } else {
                if (-not $ownedIdentityVerified) { throw 'Owned Renoise process identity is unverified; refusing to stop it or remove the probe.' }
                Assert-RenoiseProcessIdentity -Identity $ownedIdentity
                [void]$ownedProcess.CloseMainWindow()
                if (-not $ownedProcess.WaitForExit($shutdownGraceMilliseconds)) {
                    Assert-RenoiseProcessIdentity -Identity $ownedIdentity
                    $ownedProcess.Kill()
                    [void]$ownedProcess.WaitForExit($shutdownGraceMilliseconds)
                }
                $ownedProcess.Refresh()
                if (-not $ownedProcess.HasExited) { throw 'Owned Renoise process did not stop within the shutdown timeout.' }
                $processStoppedConfirmed = $true
            }
        }
        catch { $cleanupErrors.Add("Could not safely stop the owned Renoise process: $($_.Exception.Message)") }
        $ownedProcess.Dispose()
    }
    if ($installedBundlePath -and $installedBundleHash -and (Test-Path -LiteralPath $installedBundlePath -PathType Container)) {
        try {
            if (-not $processStoppedConfirmed) { throw 'Owned Renoise process stop is unconfirmed; preserving the installed native probe.' }
            if ((Get-DirectoryHash -Path $installedBundlePath) -cne $installedBundleHash) {
                throw 'Installed probe changed during the run; preserving it and refusing removal.'
            }
            Invoke-RenoiseVerifiedDirectoryRemoval -Path $installedBundlePath -ExpectedHash $installedBundleHash | Out-Null
        }
        catch { $cleanupErrors.Add("Could not safely remove the installed native probe: $($_.Exception.Message)") }
    }
    if ($module) { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
    if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join [Environment]::NewLine) }
}
