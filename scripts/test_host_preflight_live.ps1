#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RenoiseExe,
    [int]$RenoiseProcessId = 0,
    [string]$BehaviorEvidencePath,
    [switch]$RequireSafetyPass
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'tests/renoise/host_preflight.psm1') -Force
$module = Get-Module host_preflight
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('renoise-preflight-live-' + [guid]::NewGuid().ToString('N'))
$temp = Join-Path $root 'Temp'
New-Item -ItemType Directory -Path $temp -Force | Out-Null

$snapshot = {
    param([string]$Path)
    @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop |
        ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } |
        Sort-Object)
}

try {
    $exe = $RenoiseExe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Live context probe executable is unavailable: $exe" }

    $live = & $module {
        param($Executable)
        Get-HostContext -RenoiseExe $Executable
    } $exe
    $isRenoiseExecutable = $true
    if ($isRenoiseExecutable) {
        $fileInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
        $versionMatch = [regex]::Match([string]$fileInfo.ProductVersion, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
        if ($fileInfo.ProductName -notmatch 'Renoise' -or $fileInfo.CompanyName -notmatch 'Renoise' -or
            -not $versionMatch.Success -or
            $live.RenoiseProductVersion -cne $fileInfo.ProductVersion -or
            $live.RenoiseExeSha256 -cne (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw 'Live Renoise executable product metadata, version, or SHA-256 did not match the collected context.'
        }
        Write-Output "PASS collected Renoise executable metadata and SHA-256 for version $($fileInfo.ProductVersion)"
    }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $process = Get-Process -Id $PID
    $knownAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if ($live.UserSid -cne $identity.User.Value -or
        $live.AppDataPath -cne $env:APPDATA -or
        $live.KnownAppDataPath -cne $knownAppData -or
        [int]$live.SessionId -ne [int]$process.SessionId -or
        $live.RenoiseExeSha256 -notmatch '^[0-9a-f]{64}$' -or
        $live.RenoiseProcesses -isnot [array] -or
        $live.InteractiveDesktopVerified -isnot [bool]) {
        throw 'Live Windows context did not return the expected identity, session, desktop, executable, and process fields.'
    }
    Write-Output 'PASS collected current SID, APPDATA known folder, session, desktop, executable hash, and Renoise process list from Windows'

    $configuration = [pscustomobject]@{ RenoiseExe = $exe; TemporaryDirectory = $temp; RenoiseProcessId = $RenoiseProcessId }
    $before = @(& $snapshot $temp)
    $result = Test-RenoiseHostPreflight -Configuration $configuration -Mode Safety
    $after = @(& $snapshot $temp)
    if ($result.ExecutionAuthorized) { throw 'Safety mode authorized execution without behavior evidence.' }
    if (Compare-Object $before $after) { throw 'Live preflight modified its temporary directory before completing its safety checks.' }
    if ($RequireSafetyPass -and -not $result.Passed) {
        throw "Current desktop failed live safety preflight: $($result.Errors -join '; ')"
    }
    if ($result.Passed) {
        Write-Output 'PASS live safety preflight accepted the current desktop without authorizing execution'
    }
    else {
        Write-Output "PASS live safety preflight rejected this host before writes: $($result.Errors -join '; ')"
    }
    $badConfiguration = $configuration.PSObject.Copy()
    $badConfiguration.RenoiseProcessId = [int]::MaxValue
    $rejected = Test-RenoiseHostPreflight -Configuration $badConfiguration -Mode Safety
    if ($rejected.Passed -or $rejected.ExecutionAuthorized) { throw 'Live preflight accepted an absent selected PID.' }
    Write-Output 'PASS live preflight rejects an absent selected PID'
    if ($BehaviorEvidencePath) {
        $configuration | Add-Member -NotePropertyName BehaviorEvidencePath -NotePropertyValue $BehaviorEvidencePath
        $execution = Test-RenoiseHostPreflight -Configuration $configuration
        if (-not $execution.Passed -or -not $execution.ExecutionAuthorized) { throw "Live execution evidence failed: $($execution.Errors -join '; ')" }
        Write-Output 'PASS live execution preflight accepts the observed host evidence'
        foreach ($caseName in @('session mismatch','source hash mismatch')) {
            $candidate = Get-Content -LiteralPath $BehaviorEvidencePath -Raw | ConvertFrom-Json -Depth 12
            if ($caseName -eq 'session mismatch') { $candidate.Environment.SessionId = [int]$candidate.Environment.SessionId + 1 }
            else { $candidate.Files[0].Sha256 = '0' * 64 }
            $candidatePath = Join-Path $temp ($caseName.Replace(' ','-') + '.json')
            $candidate | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $candidatePath
            $candidateConfiguration = $configuration.PSObject.Copy()
            $candidateConfiguration.BehaviorEvidencePath = $candidatePath
            $beforeRejection = @(& $snapshot $temp)
            $candidateResult = Test-RenoiseHostPreflight -Configuration $candidateConfiguration
            if ($candidateResult.Passed -or $candidateResult.ExecutionAuthorized) { throw "Live execution gate accepted $caseName." }
            if (Compare-Object $beforeRejection @(& $snapshot $temp)) { throw "Rejected $caseName after writes." }
            Write-Output "PASS live execution preflight rejects $caseName before writes"
        }
    }
}
finally {
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $cleanupRoot = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $temporaryPrefix = $temporaryRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $cleanupRoot.StartsWith($temporaryPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($cleanupRoot) -notmatch '^renoise-preflight-live-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected live preflight test directory '$cleanupRoot'."
    }
    Remove-Item -LiteralPath $cleanupRoot -Recurse -Force
}
