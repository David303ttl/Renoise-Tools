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
    $exeInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($RenoiseExe)
    $knownAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $renoiseProcesses = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^Renoise(?:\..*)?$' })
    $activeDesktop = [RenoiseTestHost.DesktopProbe]::IsVisibleInputDesktop($process.SessionId)
    [pscustomobject]@{
        UserSid = $identity.User.Value
        AppDataPath = $env:APPDATA
        KnownAppDataPath = $knownAppData
        UserInteractive = [Environment]::UserInteractive
        SessionId = $process.SessionId
        InteractiveDesktopVerified = $activeDesktop
        RenoiseProductName = $exeInfo.ProductName
        RenoiseCompanyName = $exeInfo.CompanyName
        RenoiseProductVersion = $exeInfo.ProductVersion
        RenoiseProcesses = $renoiseProcesses
    }
}

function Test-RenoiseHostPreflightCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][pscustomobject]$Context
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $required = @('DedicatedUserSid', 'DedicatedSessionId', 'ProfileMarkerPath', 'ProfileMarkerValue', 'RenoiseExe', 'AppDataPath', 'ToolsPath', 'ToolInstallPath', 'TemporaryDirectory', 'DirtyDocumentFlowVerified', 'AsyncDocumentLifecycleVerified', 'WindowActivationVerified')
    foreach ($name in $required) {
        if (-not $Configuration.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Configuration.$name)) {
            $errors.Add("Configuration field '$name' must be explicitly set.")
        }
    }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ Passed = $false; Errors = @($errors) } }

    try {
        $configuredAppData = Get-CanonicalPath $Configuration.AppDataPath
        $actualAppData = Get-CanonicalPath $Context.AppDataPath
        $knownAppData = Get-CanonicalPath $Context.KnownAppDataPath
        if (-not [string]::Equals($configuredAppData, $actualAppData, [System.StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($configuredAppData, $knownAppData, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('Configured APPDATA must match both this process and the Windows ApplicationData known folder.')
        }
        if (-not [string]::Equals($Context.UserSid, $Configuration.DedicatedUserSid, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('Current Windows user SID is not the explicitly configured dedicated test user.')
        }
        if (-not $Context.UserInteractive -or [int]$Context.SessionId -le 0 -or [int]$Context.SessionId -ne [int]$Configuration.DedicatedSessionId -or -not $Context.InteractiveDesktopVerified) {
            $errors.Add('The explicitly configured active interactive desktop session could not be established.')
        }

        $markerPath = Get-CanonicalPath $Configuration.ProfileMarkerPath
        if (-not (Test-PathWithin -Path $markerPath -Parent $configuredAppData)) {
            $errors.Add('Profile marker must be inside the configured APPDATA profile.')
        }
        elseif (-not (Test-NoReparsePoint -Path $markerPath)) {
            $errors.Add('Profile marker path contains a reparse point.')
        }
        elseif (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            $errors.Add('Dedicated test profile marker is missing.')
        }
        elseif ((Get-Content -LiteralPath $markerPath -Raw).Trim() -cne [string]$Configuration.ProfileMarkerValue) {
            $errors.Add('Dedicated test profile marker does not match the configured value.')
        }

        $exePath = Get-CanonicalPath $Configuration.RenoiseExe
        if (-not (Test-Path -LiteralPath $exePath -PathType Leaf) -or [System.IO.Path]::GetFileName($exePath) -ine 'Renoise.exe') {
            $errors.Add('Configured Renoise executable is missing or is not Renoise.exe.')
        }
        elseif (-not (Test-NoReparsePoint -Path $exePath)) {
            $errors.Add('Configured Renoise executable path contains a reparse point.')
        }
        elseif ($Context.RenoiseProductName -notmatch 'Renoise' -or $Context.RenoiseCompanyName -notmatch 'Renoise') {
            $errors.Add('Configured executable metadata does not identify Renoise.')
        }
        else {
            $versionText = [string]$Context.RenoiseProductVersion
            $versionMatch = [regex]::Match($versionText, '(\d+)\.(\d+)(?:\.(\d+))?')
            if (-not $versionMatch.Success -or ([version]("{0}.{1}.{2}" -f $versionMatch.Groups[1].Value, $versionMatch.Groups[2].Value, $(if ($versionMatch.Groups[3].Success) { $versionMatch.Groups[3].Value } else { '0' }))) -lt [version]'3.5.0') {
                $errors.Add('Renoise executable version must be 3.5 or newer.')
            }
        }

        $appDataPrefix = $configuredAppData + [System.IO.Path]::DirectorySeparatorChar
        $toolsPath = Get-CanonicalPath $Configuration.ToolsPath
        if (-not $toolsPath.StartsWith($appDataPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('Tools directory must be beneath the configured APPDATA profile.')
        }
        else {
            $relative = $toolsPath.Substring($appDataPrefix.Length)
            if ($relative -notmatch '^Renoise[\\/]V\d+\.\d+\.\d+[\\/]Scripts[\\/]Tools$') {
                $errors.Add('Tools directory must be APPDATA\Renoise\Vx.y.z\Scripts\Tools.')
            }
            elseif ($relative -notmatch '^Renoise[\\/]V3\.(?:[5-9]|[1-9]\d+)\.') {
                $errors.Add('Renoise Tools profile directory must target version 3.5 or newer.')
            }
        }
        if (-not (Test-NoReparsePoint -Path $toolsPath)) {
            $errors.Add('Tools directory path contains a reparse point.')
        }
        $expectedToolPath = Get-CanonicalPath ([System.IO.Path]::Combine($toolsPath, 'com.david303ttl.ACID.xrnx'))
        $configuredToolPath = Get-CanonicalPath $Configuration.ToolInstallPath
        if (-not [string]::Equals($configuredToolPath, $expectedToolPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add('ACID install target must be the exact tool directory under the isolated Tools path.')
        }
        if (-not (Test-NoReparsePoint -Path $configuredToolPath)) {
            $errors.Add('ACID install target path contains a reparse point.')
        }

        if (@($Context.RenoiseProcesses).Count -gt 0) {
            $errors.Add('A Renoise process already exists; process ownership cannot be inferred.')
        }
        foreach ($name in @('DirtyDocumentFlowVerified', 'AsyncDocumentLifecycleVerified', 'WindowActivationVerified')) {
            if ($Configuration.$name -isnot [bool] -or -not $Configuration.$name) {
                $errors.Add("Host behavior attestation '$name' is missing or false.")
            }
        }

        if ($errors.Count -gt 0) {
            return [pscustomobject]@{ Passed = $false; Errors = @($errors) }
        }

        $tempPath = Get-CanonicalPath $Configuration.TemporaryDirectory
        if (-not (Test-Path -LiteralPath $tempPath -PathType Container)) {
            $errors.Add('Configured temporary directory does not exist.')
        }
        elseif (-not (Test-NoReparsePoint -Path $tempPath)) {
            $errors.Add('Configured temporary directory path contains a reparse point.')
        }
        else {
            $probe = Join-Path $tempPath ('.renoise-preflight-' + [guid]::NewGuid().ToString('N'))
            try {
                $stream = [System.IO.File]::Open($probe, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $stream.Dispose()
            }
            catch { $errors.Add('Configured temporary directory is not writable.') }
            finally { if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force } }
        }
    }
    catch { $errors.Add("Preflight inspection failed closed: $($_.Exception.Message)") }

    [pscustomobject]@{ Passed = ($errors.Count -eq 0); Errors = @($errors) }
}

function Test-RenoiseHostPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Configuration)

    $required = @('DedicatedUserSid', 'DedicatedSessionId', 'ProfileMarkerPath', 'ProfileMarkerValue', 'RenoiseExe', 'AppDataPath', 'ToolsPath', 'ToolInstallPath', 'TemporaryDirectory', 'DirtyDocumentFlowVerified', 'AsyncDocumentLifecycleVerified', 'WindowActivationVerified')
    $configurationErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $required) {
        if (-not $Configuration.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Configuration.$name)) {
            $configurationErrors.Add("Configuration field '$name' must be explicitly set.")
        }
    }
    foreach ($name in @('DirtyDocumentFlowVerified', 'AsyncDocumentLifecycleVerified', 'WindowActivationVerified')) {
        if ($Configuration.PSObject.Properties[$name] -and ($Configuration.$name -isnot [bool] -or -not $Configuration.$name)) {
            $configurationErrors.Add("Host behavior attestation '$name' must be true.")
        }
    }
    if ($configurationErrors.Count -gt 0) {
        return [pscustomobject]@{ Passed = $false; Errors = @($configurationErrors) }
    }
    try {
        $context = Get-HostContext -RenoiseExe $Configuration.RenoiseExe
        Test-RenoiseHostPreflightCore -Configuration $Configuration -Context $context
    }
    catch {
        [pscustomobject]@{ Passed = $false; Errors = @("Could not verify the live Windows host; refusing to continue: $($_.Exception.Message)") }
    }
}

Export-ModuleMember -Function Test-RenoiseHostPreflight
