#Requires -Version 7.0

Set-StrictMode -Version Latest

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($fullPath.TrimEnd($separators), $rootPath.TrimEnd($separators), [System.StringComparison]::OrdinalIgnoreCase)) { return $rootPath }
    return $fullPath.TrimEnd($separators)
}

function Test-PathWithin {
    param([string]$Path, [string]$Parent)
    $canonicalPath = Get-CanonicalPath $Path
    $canonicalParent = Get-CanonicalPath $Parent
    $prefix = $canonicalParent + [System.IO.Path]::DirectorySeparatorChar
    return $canonicalPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-NoReparsePoint {
    param([string]$Path)
    $current = Get-CanonicalPath $Path
    while ($true) {
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        catch {
            if ($_.CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return $false }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return $true
}

if (-not ('RenoiseTestHost.DesktopProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace RenoiseTestHost {
    public static class DesktopProbe {
        const int UOI_FLAGS = 1;
        const int UOI_NAME = 2;
        const int WSF_VISIBLE = 1;
        const int WTS_CONNECTSTATE_CLASS = 8;
        const int WTSActive = 0;
        const uint DESKTOP_READOBJECTS = 0x0001;

        [StructLayout(LayoutKind.Sequential)]
        struct USEROBJECTFLAGS { public int fInherit; public int fReserved; public int dwFlags; }

        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr GetProcessWindowStation();
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr GetThreadDesktop(uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool GetUserObjectInformation(IntPtr handle, int index, ref USEROBJECTFLAGS info, uint length, out uint needed);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder info, uint length, out uint needed);
        [DllImport("kernel32.dll")]
        static extern uint GetCurrentThreadId();
        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool WTSQuerySessionInformation(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out uint bytesReturned);
        [DllImport("wtsapi32.dll")]
        static extern void WTSFreeMemory(IntPtr memory);

        static string Name(IntPtr handle) {
            uint needed;
            var buffer = new StringBuilder(256);
            if (!GetUserObjectInformation(handle, UOI_NAME, buffer, (uint)(buffer.Capacity * sizeof(char)), out needed))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return buffer.ToString();
        }

        public static bool IsActiveSession(int sessionId) {
            IntPtr buffer;
            uint bytes;
            if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, WTS_CONNECTSTATE_CLASS, out buffer, out bytes))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try { return Marshal.ReadInt32(buffer) == WTSActive; }
            finally { WTSFreeMemory(buffer); }
        }

        public static bool IsVisibleInputDesktop(int sessionId) {
            if (!IsActiveSession(sessionId)) return false;
            IntPtr station = GetProcessWindowStation();
            if (station == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            USEROBJECTFLAGS flags = new USEROBJECTFLAGS();
            uint needed;
            if (!GetUserObjectInformation(station, UOI_FLAGS, ref flags, (uint)Marshal.SizeOf(typeof(USEROBJECTFLAGS)), out needed))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            if ((flags.dwFlags & WSF_VISIBLE) == 0 || !String.Equals(Name(station), "WinSta0", StringComparison.OrdinalIgnoreCase)) return false;

            IntPtr threadDesktop = GetThreadDesktop(GetCurrentThreadId());
            if (threadDesktop == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            IntPtr inputDesktop = OpenInputDesktop(0, false, DESKTOP_READOBJECTS);
            if (inputDesktop == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try {
                return String.Equals(Name(threadDesktop), Name(inputDesktop), StringComparison.OrdinalIgnoreCase);
            }
            finally { CloseDesktop(inputDesktop); }
        }
    }
}
'@
}

function Get-HostContext {
    param([string]$RenoiseExe)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $process = Get-Process -Id $PID
    $profileKey = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($identity.User.Value)" -Name ProfileImagePath -ErrorAction Stop
    $profileRoot = [Environment]::ExpandEnvironmentVariables([string]$profileKey.ProfileImagePath)
    $exeInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($RenoiseExe)
    $exeHash = (Get-FileHash -LiteralPath $RenoiseExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $knownAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $renoiseProcesses = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^Renoise(?:\..*)?$' } | ForEach-Object {
        $path = $null
        $startTimeUtc = $null
        $ownerSid = $null
        try { $path = [System.IO.Path]::GetFullPath($_.Path) } catch { }
        try { $startTimeUtc = $_.StartTime.ToUniversalTime().ToString('o') } catch { }
        try {
            $processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction Stop
            $owner = Invoke-CimMethod -InputObject $processInfo -MethodName GetOwner -ErrorAction Stop
            if ($owner.ReturnValue -eq 0) { $ownerSid = ([Security.Principal.NTAccount]::new($owner.Domain, $owner.User)).Translate([Security.Principal.SecurityIdentifier]).Value }
        } catch { }
        [pscustomobject]@{ Id = $_.Id; SessionId = $_.SessionId; Path = $path; StartTimeUtc = $startTimeUtc; OwnerSid = $ownerSid }
    })
    $activeDesktop = [RenoiseTestHost.DesktopProbe]::IsVisibleInputDesktop($process.SessionId)
    [pscustomobject]@{
        UserSid = $identity.User.Value
        AppDataPath = $env:APPDATA
        KnownAppDataPath = $knownAppData
        ProfileAppDataPath = (Join-Path $profileRoot 'AppData\Roaming')
        UserInteractive = [Environment]::UserInteractive
        SessionId = $process.SessionId
        InteractiveDesktopVerified = $activeDesktop
        RenoiseProductName = $exeInfo.ProductName
        RenoiseCompanyName = $exeInfo.CompanyName
        RenoiseProductVersion = $exeInfo.ProductVersion
        RenoiseExeSha256 = $exeHash
        RenoiseProcesses = $renoiseProcesses
    }
}

function Get-HostVersion {
    param([Parameter(Mandatory)][string]$VersionText)
    $match = [regex]::Match($VersionText, '(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)')
    if (-not $match.Success) { throw "Cannot resolve a three-part Renoise version from '$VersionText'." }
    return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Get-DirectoryContentHash {
    param([Parameter(Mandatory)][string]$Path)
    $root = Get-CanonicalPath $Path
    $records = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object { $_.FullName.Substring($root.Length) } | ForEach-Object {
        [pscustomobject]@{ Path = $_.FullName.Substring($root.Length).TrimStart('\','/').Replace('\','/'); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $bytes = [Text.Encoding]::UTF8.GetBytes(($records | ConvertTo-Json -Compress))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-NoReparsePointTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-NoReparsePoint $Path)) { return $false }
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    return $true
}

function Test-SpikeObservations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$ApiRecords, [Parameter(Mandatory)][object[]]$ForegroundRecords,
        [Parameter(Mandatory)][pscustomobject]$Context, [Parameter(Mandatory)][pscustomobject]$SelectedProcess)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($operation in @('new_song','load_song')) {
        foreach ($choice in @('Cancel','Save','Discard')) {
            $eventName = 'dirty_prompt_' + $choice.ToLowerInvariant()
            if (@($ApiRecords | Where-Object { $_.flow -ceq 'dirty_document' -and $_.event -ceq $eventName -and $_.result -ceq 'observed' -and [string]$_.details -match "operation=$operation;choice=$choice(?:;|$)" }).Count -eq 0) { $errors.Add("Missing observed dirty prompt event '$operation / $choice'.") }
        }
    }
    foreach ($eventName in @('request_new_song','request_load_song')) {
        if (@($ApiRecords | Where-Object { $_.event -ceq $eventName -and $_.result -ceq 'requested' }).Count -eq 0) { $errors.Add("Missing requested lifecycle event '$eventName'.") }
    }
    foreach ($eventName in @('app_release_document','app_new_document','app_saved_document','clean_lifecycle_probe_complete','tool_will_unload','tool_finished_loading')) {
        if (@($ApiRecords | Where-Object { $_.event -ceq $eventName -and $_.result -ceq 'observed' }).Count -eq 0) { $errors.Add("Missing observed lifecycle event '$eventName'.") }
    }
    if (@($ApiRecords | Where-Object { $_.event -ceq 'app_new_document' -and [string]$_.details -match 'generationAdvanced=true' }).Count -eq 0) { $errors.Add('No release/new-document callback pair advanced the document generation.') }
    $details = @($ForegroundRecords | Where-Object { $_.flow -ceq 'window_activation' -and $_.result -ceq 'observed' } | ForEach-Object { $_.details })
    foreach ($detail in $details) {
        if ([string]$detail.userSid -cne [string]$Context.UserSid -or
            -not [string]::Equals((Get-CanonicalPath ([string]$detail.appDataPath)), (Get-CanonicalPath ([string]$Context.AppDataPath)), [StringComparison]::OrdinalIgnoreCase) -or
            [int]$detail.sessionId -ne [int]$Context.SessionId -or [int]$detail.targetProcessId -ne [int]$SelectedProcess.Id -or
            [DateTimeOffset]$detail.targetProcessStartTimeUtc -ne [DateTimeOffset]$SelectedProcess.StartTimeUtc -or
            -not [string]::Equals((Get-CanonicalPath ([string]$detail.targetExecutablePath)), (Get-CanonicalPath ([string]$SelectedProcess.Path)), [StringComparison]::OrdinalIgnoreCase) -or
            [string]$detail.targetExecutableSha256 -ine [string]$Context.RenoiseExeSha256) { $errors.Add('Foreground trace does not match the selected Renoise process and current profile.'); break }
    }
    $states = @($details | ForEach-Object { [string]$_.state })
    $sawForeground = $false; $sawBackground = $false; $sawReturn = $false
    foreach ($state in $states) {
        if (-not $sawForeground -and $state -ceq 'foreground') { $sawForeground = $true; continue }
        if ($sawForeground -and -not $sawBackground -and $state -ceq 'background') { $sawBackground = $true; continue }
        if ($sawBackground -and $state -ceq 'foreground') { $sawReturn = $true; break }
    }
    if (-not $sawReturn) { $errors.Add('Foreground trace must show foreground, background, then foreground again.') }
    [pscustomobject]@{ Passed = ($errors.Count -eq 0); Errors = @($errors) }
}

function Test-BehaviorEvidence {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][pscustomobject]$SelectedProcess, [Parameter(Mandatory)][string]$RenoiseExe,
        [Parameter(Mandatory)][string]$ToolsPath)
    $evidence = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 12
    $environment = $evidence.Environment
    $version = Get-HostVersion ([string]$Context.RenoiseProductVersion)
    if ([int]$evidence.SchemaVersion -ne 1 -or [string]$environment.UserSid -cne [string]$Context.UserSid -or
        [int]$environment.SessionId -ne [int]$Context.SessionId -or
        -not [string]::Equals((Get-CanonicalPath ([string]$environment.AppDataPath)), (Get-CanonicalPath ([string]$Context.AppDataPath)), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-CanonicalPath ([string]$environment.KnownAppDataPath)), (Get-CanonicalPath ([string]$Context.KnownAppDataPath)), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-CanonicalPath ([string]$environment.ProfileAppDataPath)), (Get-CanonicalPath ([string]$Context.ProfileAppDataPath)), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-CanonicalPath ([string]$environment.RenoiseExePath)), (Get-CanonicalPath $RenoiseExe), [StringComparison]::OrdinalIgnoreCase) -or
        [string]$environment.RenoiseExeSha256 -ine [string]$Context.RenoiseExeSha256 -or [string]$environment.RenoiseVersion -cne $version.ToString(3) -or
        -not [string]::Equals((Get-CanonicalPath ([string]$environment.ToolsPath)), (Get-CanonicalPath $ToolsPath), [StringComparison]::OrdinalIgnoreCase) -or
        [int]$environment.RenoiseProcessId -ne [int]$SelectedProcess.Id -or [DateTimeOffset]$environment.RenoiseProcessStartTimeUtc -ne [DateTimeOffset]$SelectedProcess.StartTimeUtc) {
        throw 'Behavior evidence does not match the current SID, session, Renoise executable, profile, and selected process.'
    }
    $requiredSources = @('main.lua','manifest.xml','Capture-Foreground.ps1')
    $fileRecords = @($evidence.Files)
    foreach ($requiredName in $requiredSources) {
        if (@($fileRecords | Where-Object { [IO.Path]::GetFileName([string]$_.Path) -ceq $requiredName }).Count -eq 0) { throw "Behavior evidence does not include source '$requiredName'." }
    }
    foreach ($record in $fileRecords) {
        if (-not (Test-Path -LiteralPath $record.Path -PathType Leaf) -or -not (Test-NoReparsePoint $record.Path) -or [string]$record.Sha256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $record.Path -Algorithm SHA256).Hash -ine [string]$record.Sha256) { throw "Behavior evidence source hash does not match '$($record.Path)'." }
    }
    foreach ($tracePath in @($evidence.ApiTracePath, $evidence.ForegroundTracePath)) {
        if (@($fileRecords | Where-Object { [string]::Equals((Get-CanonicalPath ([string]$_.Path)), (Get-CanonicalPath ([string]$tracePath)), [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { throw "Trace '$tracePath' is not included in the hashed evidence files." }
    }
    if ((Get-FileHash -LiteralPath $evidence.ApiTracePath -Algorithm SHA256).Hash -ine [string]$evidence.ApiTraceSha256 -or
        (Get-FileHash -LiteralPath $evidence.ForegroundTracePath -Algorithm SHA256).Hash -ine [string]$evidence.ForegroundTraceSha256) { throw 'Raw observation trace hashes do not match the evidence record.' }
    $api = @(Get-Content -LiteralPath $evidence.ApiTracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 8 })
    $foreground = @(Get-Content -LiteralPath $evidence.ForegroundTracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -Depth 8 })
    $observations = Test-SpikeObservations -ApiRecords $api -ForegroundRecords $foreground -Context $Context -SelectedProcess $SelectedProcess
    if (-not $observations.Passed) { throw ($observations.Errors -join '; ') }
    return $true
}

function Test-RenoiseHostPreflightCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Configuration, [Parameter(Mandatory)][pscustomobject]$Context)
    $errors = [System.Collections.Generic.List[string]]::new()
    $executionAuthorized = $false
    $installReplacementAuthorized = $false
    foreach ($name in @('RenoiseExe','TemporaryDirectory')) {
        if (-not $Configuration.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Configuration.$name)) { $errors.Add("Configuration field '$name' is required.") }
    }
    if ($errors.Count) { return [pscustomobject]@{ Passed = $false; Mode = $Configuration.Mode; ExecutionAuthorized = $false; Errors = @($errors) } }
    try {
        $appData = Get-CanonicalPath $Context.AppDataPath
        if (-not [string]::Equals($appData, (Get-CanonicalPath $Context.KnownAppDataPath), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($appData, (Get-CanonicalPath $Context.ProfileAppDataPath), [StringComparison]::OrdinalIgnoreCase)) { $errors.Add('APPDATA does not match the Windows known folder and profile registered to the current SID.') }
        if (-not $Context.UserInteractive -or [int]$Context.SessionId -le 0 -or -not $Context.InteractiveDesktopVerified) { $errors.Add('An active interactive desktop session could not be established.') }
        $exePath = Get-CanonicalPath $Configuration.RenoiseExe
        if (-not (Test-Path -LiteralPath $exePath -PathType Leaf) -or [IO.Path]::GetFileName($exePath) -ine 'Renoise.exe' -or -not (Test-NoReparsePoint $exePath)) { $errors.Add('Renoise executable is missing, invalid, or reached through a reparse point.') }
        if ($Context.RenoiseProductName -notmatch 'Renoise' -or $Context.RenoiseCompanyName -notmatch 'Renoise') { $errors.Add('Executable metadata does not identify Renoise.') }
        $exeVersion = Get-HostVersion ([string]$Context.RenoiseProductVersion)
        if ($exeVersion -lt [version]'3.5.0') { $errors.Add('Renoise 3.5.0 or newer is required.') }
        $toolsPath = Get-CanonicalPath (Join-Path $appData ('Renoise/V{0}/Scripts/Tools' -f $exeVersion))
        if (-not (Test-Path -LiteralPath $toolsPath -PathType Container) -or -not (Test-NoReparsePoint $toolsPath)) { $errors.Add('Version-matched Renoise Tools directory must exist without reparse points.') }
        $target = Join-Path $toolsPath 'com.david303ttl.ACID.xrnx'
        $installReplacementAuthorized = $true
        if (Test-Path -LiteralPath $target) {
            $expectedBundle = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'com.david303ttl.ACID.xrnx'
            if (-not (Test-Path -LiteralPath $target -PathType Container) -or -not (Test-NoReparsePointTree $target) -or
                -not (Test-Path -LiteralPath $expectedBundle -PathType Container) -or -not (Test-NoReparsePointTree $expectedBundle) -or
                -not [string]::Equals((Get-DirectoryContentHash $target), (Get-DirectoryContentHash $expectedBundle), [StringComparison]::OrdinalIgnoreCase)) { $installReplacementAuthorized = $false }
        }
        $selectedProcessId = if ($Configuration.PSObject.Properties['RenoiseProcessId']) { [int]$Configuration.RenoiseProcessId } else { 0 }
        $selected = @($Context.RenoiseProcesses | Where-Object { [int]$_.Id -eq $selectedProcessId })
        if ($selectedProcessId -gt 0) {
            if ($selected.Count -ne 1 -or [int]$selected[0].SessionId -ne [int]$Context.SessionId -or
                [string]$selected[0].OwnerSid -cne [string]$Context.UserSid -or
                -not [string]::Equals((Get-CanonicalPath ([string]$selected[0].Path)), $exePath, [StringComparison]::OrdinalIgnoreCase) -or
                -not $selected[0].StartTimeUtc) { $errors.Add('Selected Renoise PID is missing or does not match the current session, executable, and process start time.') }
            if (@($Context.RenoiseProcesses | Where-Object { [int]$_.Id -ne $selectedProcessId }).Count -gt 0) { $errors.Add('Other Renoise processes exist; the selected process cannot be isolated.') }
        }
        elseif (@($Context.RenoiseProcesses).Count -gt 0) { $errors.Add('A Renoise process exists but no PID was explicitly selected.') }
        if ($Configuration.Mode -eq 'Execution') {
            if ($selectedProcessId -le 0 -or $selected.Count -ne 1) { $errors.Add('Execution mode requires one explicitly selected Renoise process.') }
            elseif (-not $Configuration.BehaviorEvidencePath) { $errors.Add('Execution mode requires local behavior evidence.') }
            else { $executionAuthorized = Test-BehaviorEvidence -Path $Configuration.BehaviorEvidencePath -Context $Context -SelectedProcess $selected[0] -RenoiseExe $exePath -ToolsPath $toolsPath }
        }
        if ($errors.Count) { return [pscustomobject]@{ Passed = $false; Mode = $Configuration.Mode; ExecutionAuthorized = $false; InstallReplacementAuthorized = $false; Errors = @($errors) } }
        $temp = Get-CanonicalPath $Configuration.TemporaryDirectory
        if (-not (Test-Path -LiteralPath $temp -PathType Container) -or -not (Test-NoReparsePoint $temp)) { $errors.Add('Temporary directory is missing or contains a reparse point.') }
        else {
            $probe = Join-Path $temp ('.renoise-preflight-' + [guid]::NewGuid().ToString('N'))
            try { $stream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None); $stream.Dispose() }
            catch { $errors.Add('Temporary directory is not writable.') }
            finally { if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force } }
        }
    }
    catch { $errors.Add("Preflight inspection failed closed: $($_.Exception.Message)") }
    [pscustomobject]@{ Passed = ($errors.Count -eq 0); Mode = $Configuration.Mode; ExecutionAuthorized = (($errors.Count -eq 0) -and $executionAuthorized); InstallReplacementAuthorized = (($errors.Count -eq 0) -and $installReplacementAuthorized); Errors = @($errors) }
}

function Test-RenoiseHostPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Configuration, [ValidateSet('Execution','Safety')][string]$Mode = 'Execution')
    $errors = [System.Collections.Generic.List[string]]::new()
    $allowed = @('RenoiseExe','TemporaryDirectory','RenoiseProcessId','BehaviorEvidencePath')
    foreach ($property in $Configuration.PSObject.Properties) { if ($property.Name -notin $allowed) { $errors.Add("Configuration field '$($property.Name)' is not accepted.") } }
    foreach ($name in @('RenoiseExe','TemporaryDirectory')) { if (-not $Configuration.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Configuration.$name)) { $errors.Add("Configuration field '$name' is required.") } }
    if ($Mode -eq 'Execution' -and (-not $Configuration.PSObject.Properties['BehaviorEvidencePath'] -or [string]::IsNullOrWhiteSpace([string]$Configuration.BehaviorEvidencePath))) { $errors.Add('Execution mode requires BehaviorEvidencePath.') }
    if ($errors.Count) { return [pscustomobject]@{ Passed = $false; Mode = $Mode; ExecutionAuthorized = $false; Errors = @($errors) } }
    try {
        $context = Get-HostContext -RenoiseExe $Configuration.RenoiseExe
        $processId = if ($Configuration.PSObject.Properties['RenoiseProcessId']) { [int]$Configuration.RenoiseProcessId } else { 0 }
        $evidencePath = if ($Configuration.PSObject.Properties['BehaviorEvidencePath']) { [string]$Configuration.BehaviorEvidencePath } else { '' }
        $coreConfig = [pscustomobject]@{ RenoiseExe = $Configuration.RenoiseExe; TemporaryDirectory = $Configuration.TemporaryDirectory; RenoiseProcessId = $processId; BehaviorEvidencePath = $evidencePath; Mode = $Mode }
        Test-RenoiseHostPreflightCore -Configuration $coreConfig -Context $context
    }
    catch { [pscustomobject]@{ Passed = $false; Mode = $Mode; ExecutionAuthorized = $false; Errors = @("Could not verify the live Windows host; refusing to continue: $($_.Exception.Message)") } }
}

Export-ModuleMember -Function Test-RenoiseHostPreflight
