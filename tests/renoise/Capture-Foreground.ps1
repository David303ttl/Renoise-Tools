#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$RenoiseProcessId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(10, 3600)][int]$DurationSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('RenoiseTestHost.ForegroundProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace RenoiseTestHost {
    public static class ForegroundProbe {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    }
}
'@
}

$renoise = Get-Process -Id $RenoiseProcessId -ErrorAction Stop
if ($renoise.ProcessName -notmatch '^Renoise(?:\..*)?$' -or -not $renoise.Path) {
    throw 'The supplied PID is not a running Renoise process with a readable executable path.'
}
$currentSessionId = (Get-Process -Id $PID).SessionId
if ($renoise.SessionId -ne $currentSessionId) {
    throw 'The Renoise process is not in the current interactive session.'
}
$processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $RenoiseProcessId"
$owner = Invoke-CimMethod -InputObject $processInfo -MethodName GetOwner
if ($owner.ReturnValue -ne 0) {
    throw 'Could not verify the Renoise process owner.'
}
$ownerSid = ([System.Security.Principal.NTAccount]::new($owner.Domain, $owner.User)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($ownerSid -ne $identity.User.Value) {
    throw 'The Renoise process is not owned by the current Windows user.'
}
$processStartTimeUtc = $renoise.StartTime.ToUniversalTime().ToString('o')
$exePath = [System.IO.Path]::GetFullPath($renoise.Path)
$exeHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "Output directory does not exist: $parent"
}

$stream = [System.IO.File]::Open($outputFullPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
$writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
try {
    $lastState = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = [RenoiseTestHost.ForegroundProbe]::GetForegroundWindow()
        [uint32]$foregroundPid = 0
        if ($window -ne [IntPtr]::Zero) {
            [void][RenoiseTestHost.ForegroundProbe]::GetWindowThreadProcessId($window, [ref]$foregroundPid)
        }
        $isRenoiseForeground = $foregroundPid -eq [uint32]$RenoiseProcessId
        $state = if ($isRenoiseForeground) { 'foreground' } else { 'background' }
        if ($state -ne $lastState) {
            $record = [ordered]@{
                flow = 'window_activation'
                result = 'observed'
                observedAtUtc = [DateTime]::UtcNow.ToString('o')
                details = [ordered]@{
                    state = $state
                    foregroundWindow = ('0x{0:X}' -f $window.ToInt64())
                    foregroundProcessId = $foregroundPid
                    targetProcessId = $RenoiseProcessId
                    targetExecutablePath = $exePath
                    targetExecutableSha256 = $exeHash
                    targetProcessStartTimeUtc = $processStartTimeUtc
                    userSid = $identity.User.Value
                    appDataPath = [Environment]::GetEnvironmentVariable('APPDATA')
                    sessionId = $currentSessionId
                }
            }
            $writer.WriteLine(($record | ConvertTo-Json -Compress -Depth 5))
            $writer.Flush()
            $lastState = $state
        }
        Start-Sleep -Milliseconds 100
        $renoise.Refresh()
        if ($renoise.HasExited) { throw 'The observed Renoise process exited during capture.' }
    }
}
finally {
    $writer.Dispose()
}

Write-Output "Foreground transitions recorded to $outputFullPath"
