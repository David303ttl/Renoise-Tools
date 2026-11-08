#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPort,
    [Parameter(Mandatory)][string]$OutputPort,
    [string]$LuaCommand = 'lua5.1',
    [ValidateRange(2, 30)][int]$CaptureSeconds = 4,
    [switch]$StartTransport
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$runRoot = Join-Path $repoRoot ('tmp/superos-hardware-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot | Out-Null
Add-Type -Path (Join-Path $PSScriptRoot 'native_midi.cs')
Push-Location $repoRoot
$midi = $null
$plan = $null
$writeAttempted = $false
$startedTransport = $false
$MidiStart = 0xFA
$MidiStop = 0xFC
function Invoke-Probe([string]$Action, [string]$Path) {
    $response = & $LuaCommand tests/superos303/hardware_probe.lua $Action $Path
    if ($LASTEXITCODE -ne 0) { throw "Protocol probe failed: $Action" }
    ConvertFrom-Json -InputObject ($response -join "`n") -Depth 32
}
function Save-Json([string]$Name, $Value) {
    $path = Join-Path $runRoot ($Name + '.json')
    ConvertTo-Json -InputObject $Value -Depth 32 | Set-Content -LiteralPath $path
    return $path
}
function Capture([string]$Name) {
    Start-Sleep -Seconds $CaptureSeconds
    $events = [Collections.Generic.List[object]]::new()
    $item = $null
    while ($midi.Events.TryDequeue([ref]$item)) { $events.Add($item) }
    Save-Json $Name $events.ToArray()
}
try {
    $settings = Invoke-Probe settings
    $midi = [SuperOsMidi]::new($InputPort, $OutputPort)
    $midi.Send([byte[]]$settings.config)
    $baseline = Invoke-Probe inspect (Capture baseline)
    if ($baseline.notes.Count -eq 0 -and $StartTransport) {
        $startedTransport = $true
        $midi.SendRealtime($MidiStart)
        $baseline = Invoke-Probe inspect (Capture started)
    }
    if (-not $baseline.PSObject.Properties['active'] -or $baseline.notes.Count -eq 0) {
        throw 'No running pattern identified. Start hardware playback before running this test.'
    }
    $active = $baseline.active
    $request = Invoke-Probe request ([string]$active.pattern)
    $midi.Send([byte[]]$request)
    $plan = Invoke-Probe plan (Capture original)
    Save-Json plan $plan | Out-Null
    Write-Output "Running group $($active.group + 1), pattern $($active.pattern + 1), step $($plan.step + 1)"
    $writeAttempted = $true
    $midi.Send([byte[]]$plan.write)
    $midi.Send([byte[]]$request)
    $writtenEvents = Get-Content -LiteralPath (Capture written) -Raw | ConvertFrom-Json -Depth 32
    $verification = Invoke-Probe verify (Save-Json verify @{events = $writtenEvents; plan = $plan; restore = $false})
    Save-Json written-result $verification | Out-Null
    Write-Output "Readback matches: $($verification.matches); changed bytes: $($verification.changed_bytes -join ', '); new channel:note values: $($verification.new_notes -join ', '); MIDI errors: $($verification.errors.Count)"
    if (-not $verification.matches) { throw 'Live step write did not match hardware readback.' }
    if ($verification.errors.Count -gt 0) { throw 'MIDI capture contains invalid messages; inspect written-result.json.' }
}
finally {
    try {
        if ($writeAttempted) {
            $midi.Send([byte[]]$plan.restore)
            $midi.Send([byte[]]$request)
            $restoredEvents = Get-Content -LiteralPath (Capture restored) -Raw | ConvertFrom-Json -Depth 32
            $restored = Invoke-Probe verify (Save-Json restore-verify @{events = $restoredEvents; plan = $plan; restore = $true})
            Save-Json restored-result $restored | Out-Null
            if (-not $restored.matches) { throw "Original pattern restoration failed. Backup: $runRoot" }
            Write-Output 'Restored and verified every original pattern byte.'
        }
    } finally {
        try {
            if ($startedTransport -and $null -ne $midi) { $midi.SendRealtime($MidiStop) }
        } finally {
            if ($null -ne $midi) { $midi.Dispose() }
            Pop-Location
            Write-Output "Capture: $runRoot"
        }
    }
}
