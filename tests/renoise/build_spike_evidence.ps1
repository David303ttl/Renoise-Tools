#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$RenoiseProcessId,
    [Parameter(Mandatory)][string]$ApiTracePath,
    [Parameter(Mandatory)][string]$ForegroundTracePath,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanonicalPath([string]$Path) {
    [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Read-JsonLines([string]$Path) {
    $records = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records.Add(($line | ConvertFrom-Json -Depth 12 -ErrorAction Stop)) }
        catch { throw "Invalid JSON in '$Path' at line $lineNumber`: $($_.Exception.Message)" }
    }
    return ,$records.ToArray()
}

function Get-ObservedEvents([object[]]$Records, [string]$Flow) {
    @($Records | Where-Object { [string]$_.flow -ceq $Flow -and [string]$_.result -ceq 'observed' } | ForEach-Object { [string]$_.event } | Sort-Object -Unique)
}

$process = Get-Process -Id $RenoiseProcessId -ErrorAction Stop
if ($process.ProcessName -notmatch '^Renoise(?:\..*)?$' -or -not $process.Path) { throw 'Selected PID is not a running Renoise process with a readable executable path.' }
$currentSessionId = (Get-Process -Id $PID).SessionId
if ($process.SessionId -ne $currentSessionId) { throw 'Selected Renoise process is not in the current Windows session.' }
$processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $RenoiseProcessId"
$owner = Invoke-CimMethod -InputObject $processInfo -MethodName GetOwner
if ($owner.ReturnValue -ne 0) { throw 'Could not resolve the selected Renoise process owner.' }
$ownerSid = ([System.Security.Principal.NTAccount]::new($owner.Domain, $owner.User)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($ownerSid -ne $identity.User.Value) { throw 'Selected Renoise process is not owned by the current Windows user.' }
$processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
$exePath = Get-CanonicalPath $process.Path
$exeHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
$exeInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
if ($exeInfo.ProductName -notmatch 'Renoise' -or $exeInfo.CompanyName -notmatch 'Renoise') { throw 'Selected executable metadata does not identify Renoise.' }
$versionMatch = [regex]::Match([string]$exeInfo.ProductVersion, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
if (-not $versionMatch.Success) { throw 'Could not resolve a three-part Renoise version from executable metadata.' }
$version = [version]::new([int]$versionMatch.Groups[1].Value, [int]$versionMatch.Groups[2].Value, [int]$versionMatch.Groups[3].Value)
$appData = Get-CanonicalPath ([Environment]::GetEnvironmentVariable('APPDATA'))
$knownAppData = Get-CanonicalPath ([Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData))
$profileKey = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($identity.User.Value)" -ErrorAction Stop
$profileRoot = [Environment]::ExpandEnvironmentVariables([string]$profileKey.ProfileImagePath)
$profileAppData = Get-CanonicalPath (Join-Path $profileRoot 'AppData\Roaming')
if ($appData -ine $knownAppData -or $appData -ine $profileAppData) { throw 'Current APPDATA does not match Windows known-folder and user-profile paths.' }
$toolsPath = Get-CanonicalPath (Join-Path $appData ('Renoise/V{0}/Scripts/Tools' -f $version.ToString(3)))
if (-not (Test-Path -LiteralPath $toolsPath -PathType Container)) { throw 'Version-matched Renoise Tools directory is missing.' }

$apiPath = Get-CanonicalPath $ApiTracePath
$foregroundPath = Get-CanonicalPath $ForegroundTracePath
$spikeBundlePath = Split-Path -Parent $apiPath
$mainPath = Get-CanonicalPath (Join-Path $spikeBundlePath 'main.lua')
$manifestPath = Get-CanonicalPath (Join-Path $spikeBundlePath 'manifest.xml')
$capturePath = Get-CanonicalPath (Join-Path $PSScriptRoot 'Capture-Foreground.ps1')
foreach ($path in @($apiPath, $foregroundPath, $mainPath, $manifestPath, $capturePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required evidence input is missing: $path" }
}

$apiRecords = Read-JsonLines $apiPath
$foregroundRecords = Read-JsonLines $foregroundPath
if ($apiRecords.Count -eq 0 -or $foregroundRecords.Count -eq 0) { throw 'Both raw observation traces must contain records.' }
$dirtyEvents = @($apiRecords | Where-Object { $_.flow -ceq 'dirty_document' -and $_.result -ceq 'observed' })
foreach ($operation in @('new_song', 'load_song')) {
    foreach ($choice in @('Cancel', 'Save', 'Discard')) {
        $matches = @($dirtyEvents | Where-Object { [string]$_.event -eq ('dirty_prompt_' + $choice.ToLowerInvariant()) -and [string]$_.details -match "operation=$operation;choice=$choice(?:;|$)" })
        if ($matches.Count -eq 0) { throw "Missing operator-observed dirty prompt record for $operation / $choice." }
    }
}
$asyncEvents = Get-ObservedEvents $apiRecords 'async_document_lifecycle'
foreach ($eventName in @('app_release_document','app_new_document','app_saved_document','clean_lifecycle_probe_complete','tool_will_unload','tool_finished_loading')) {
    if ($eventName -notin $asyncEvents) { throw "Missing observed async lifecycle event '$eventName'." }
}
$foregroundEvents = @($foregroundRecords | Where-Object { $_.flow -ceq 'window_activation' -and $_.result -ceq 'observed' })
$foregroundStates = @($foregroundEvents | ForEach-Object { [string]$_.details.state })
$sawForeground = $false
$sawBackground = $false
$sawReturn = $false
foreach ($state in $foregroundStates) {
    if (-not $sawForeground -and $state -ceq 'foreground') { $sawForeground = $true; continue }
    if ($sawForeground -and -not $sawBackground -and $state -ceq 'background') { $sawBackground = $true; continue }
    if ($sawBackground -and $state -ceq 'foreground') { $sawReturn = $true; break }
}
if (-not $sawReturn) { throw 'Foreground trace must show Renoise foreground, background, and foreground again.' }
foreach ($record in $foregroundEvents) {
    $details = $record.details
    if ([int]$details.targetProcessId -ne $RenoiseProcessId -or [string]$details.targetExecutableSha256 -ine $exeHash -or
        [string]$details.userSid -ine $identity.User.Value -or [int]$details.sessionId -ne $currentSessionId -or
        (Get-CanonicalPath ([string]$details.appDataPath)) -ine $appData -or
        [DateTimeOffset]$details.targetProcessStartTimeUtc -ne [DateTimeOffset]$processStartTimeUtc) {
        throw 'Foreground trace contains a record not bound to the selected Renoise process and current session.'
    }
}

$files = @(
    [pscustomobject]@{ Name = 'api-observations.jsonl'; Path = $apiPath; Sha256 = (Get-FileHash -LiteralPath $apiPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ Name = 'foreground-observations.jsonl'; Path = $foregroundPath; Sha256 = (Get-FileHash -LiteralPath $foregroundPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ Name = 'spike-main.lua'; Path = $mainPath; Sha256 = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ Name = 'spike-manifest.xml'; Path = $manifestPath; Sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ Name = 'foreground-capture.ps1'; Path = $capturePath; Sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash.ToLowerInvariant() }
)
$flows = @(
    [pscustomobject]@{ Flow = 'dirty_document'; Events = @($dirtyEvents | ForEach-Object { [string]$_.event } | Sort-Object -Unique) },
    [pscustomobject]@{ Flow = 'async_document_lifecycle'; Events = $asyncEvents },
    [pscustomobject]@{ Flow = 'window_activation'; Events = @($foregroundEvents | ForEach-Object { [string]$_.details.state } | Sort-Object -Unique) }
)
$evidence = [ordered]@{
    SchemaVersion = 1
    CollectedAtUtc = [DateTime]::UtcNow.ToString('o')
    Environment = [ordered]@{
        UserSid = $identity.User.Value
        SessionId = $currentSessionId
        AppDataPath = $appData
        KnownAppDataPath = $knownAppData
        ProfileAppDataPath = $profileAppData
        RenoiseExePath = $exePath
        RenoiseExeSha256 = $exeHash
        RenoiseVersion = $version.ToString(3)
        ToolsPath = $toolsPath
        RenoiseProcessId = $RenoiseProcessId
        RenoiseProcessStartTimeUtc = $processStartTimeUtc
    }
    ApiTracePath = $apiPath
    ApiTraceSha256 = $files[0].Sha256
    ForegroundTracePath = $foregroundPath
    ForegroundTraceSha256 = $files[1].Sha256
    Files = $files
    Flows = $flows
    ApiRecords = $apiRecords
    ForegroundRecords = $foregroundRecords
}
$outputFullPath = Get-CanonicalPath $OutputPath
$outputParent = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw 'Evidence output directory must already exist.' }
$stream = [System.IO.File]::Open($outputFullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
try {
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
    $writer.WriteLine(($evidence | ConvertTo-Json -Depth 12))
    $writer.Flush()
}
finally { $stream.Dispose() }

Write-Output "Raw observation evidence written to $outputFullPath"
