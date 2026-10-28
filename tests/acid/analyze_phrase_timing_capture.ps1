# Measure the full onset schedule of a single-trigger phrase timing render.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$WavPath,
  [Parameter(Mandatory=$true)][ValidateSet('straight','triplet')][string]$Mode,
  [Parameter(Mandatory=$true)][ValidateRange(1,64)][int]$Steps,
  [Parameter(Mandatory=$true)][ValidateRange(32,999)][int]$Bpm,
  [Parameter(Mandatory=$true)][ValidateRange(1,256)][int]$SongLpb,
  [Parameter(Mandatory=$true)][string]$RunReceiptPath,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$wav = (Resolve-Path -LiteralPath $WavPath).Path
$sidecarPath = "$wav.render.txt"
$modulePath = Join-Path $PSScriptRoot 'audio_analyzer.psm1'
Import-Module $modulePath -Force

function Read-KeyValueFile([string]$Path) {
  $values = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) { $values[$line.Substring(0,$separator)] = $line.Substring($separator + 1) }
  }
  return $values
}

if (-not (Test-Path -LiteralPath $sidecarPath)) { throw "Missing Renoise render sidecar '$sidecarPath'" }
$sidecar = Read-KeyValueFile $sidecarPath
$runReceipt = Read-KeyValueFile $RunReceiptPath
$runToken = [string]$runReceipt.run_id -replace '^.*_', ''
$preparedId = '{0}_{1:00}_r{2}_bpm{3:000}_lpb{4:00}' -f $Mode,$Steps,$runToken,$Bpm,$SongLpb
$preparedLine = Get-Content -LiteralPath $RunReceiptPath | Where-Object {
  $_.StartsWith("prepared=$preparedId;", [System.StringComparison]::Ordinal)
} | Select-Object -First 1
if (-not $preparedLine) {
  $legacyPreparedId = '{0}_{1}_bpm{2:000}_lpb{3:00}' -f $Mode,$Steps,$Bpm,$SongLpb
  $preparedLine = Get-Content -LiteralPath $RunReceiptPath | Where-Object {
    $_.StartsWith("prepared=$legacyPreparedId;", [System.StringComparison]::Ordinal)
  } | Select-Object -First 1
  if ($preparedLine) { $preparedId = $legacyPreparedId }
}
if (-not $preparedLine) { throw "Timing run receipt has no prepared-case record for '$preparedId'" }
$prepared = $preparedLine.Substring('prepared='.Length)
$preparedFields = @{}
foreach ($field in @('host_note','host_off','pre_roll_lines','hold_lines',
    'pattern_boundary_lines','pattern_count','cycle_beats')) {
  $match = [regex]::Match($prepared, '(?:^|;)' + [regex]::Escape($field) + '=([^;]+)')
  $preparedFields[$field] = if ($match.Success) { $match.Groups[1].Value } else { $null }
}
if ($sidecar.status -cne 'completed' -or $sidecar.duration_check -cne 'passed') {
  throw 'Renoise render sidecar is incomplete or its duration check failed'
}
if ([int]$sidecar.bpm -ne $Bpm -or [int]$sidecar.lpb -ne $SongLpb -or
    [int]$sidecar.tpl -ne 12 -or [int]$sidecar.sample_rate -ne 48000 -or
    [int]$sidecar.bit_depth -ne 24 -or $sidecar.interpolation -cne 'precise') {
  throw 'Render sidecar does not match the requested BPM/LPB/48 kHz PCM24 configuration'
}
if ($runReceipt.status -cne 'completed' -or $runReceipt.timing_mode -cne $Mode -or
    [int]$runReceipt.steps -ne $Steps -or [int]$runReceipt.phrase_lpb -ne $(if ($Mode -eq 'straight') { 8 } else { 6 }) -or
    [int]$runReceipt.phrase_shuffle -ne 0 -or [int]$runReceipt.traversals -ne 4) {
  throw 'Timing run receipt does not match the requested phrase fixture'
}

$stepFactor = if ($Mode -eq 'straight') { 1.0 } else { 4.0 / 3.0 }
$stepsPerBeat = if ($Mode -eq 'straight') { 4.0 } else { 3.0 }
$cycleSteps = $Steps * $stepFactor
$cycleBeats = $Steps / $stepsPerBeat
$expectedCycleMs = 60000.0 * $Steps / ($Bpm * $stepsPerBeat)
$expectedOnsets = @(
  for ($cycle = 0; $cycle -lt 4; $cycle++) {
    for ($step = 0; $step -lt $Steps; $step++) {
      [ordered]@{ at_step=($cycle * $cycleSteps + $step * $stepFactor); tolerance_ms=5 }
    }
  }
)
$case = @{
  id = "phrase_${Mode}_${Steps}_bpm${Bpm}_lpb${SongLpb}"
  status = 'ready'
  source = @{ length=$cycleSteps }
  capture = @{ sample_rate=48000; bpm=$Bpm; song_lpb=$SongLpb; tpl=12; minimum_tail_ms=1000; profile=@{id='acid-reference-168-frame-saw'} }
  profile = @{ id='acid-reference-168-frame-saw'; root_note=48; base_frequency_hz=262.5 }
  analysis = @{ onset_floor_dbfs=-60; onset_window_ms=10; onset_refractory_ms=40; onset_tolerance_ms=5; pitch_tolerance_cents=15; silence_dbfs=-60 }
  expected = @{ onsets=$expectedOnsets; pitch_windows=@(); silence_windows=@(); continuity_windows=@(); no_attack_windows=@(); glide_window=$null; settled_window=$null; release=$null }
}

$audio = Read-ArticulationWav $wav
$measurement = Measure-ArticulationCase $audio $case
$preRollLines = if ($preparedFields.pre_roll_lines) {
  [int]$preparedFields.pre_roll_lines
} else {
  [int][Math]::Ceiling(2 * $Bpm * $SongLpb / 60.0 - 0.0000001)
}
$holdLines = if ($preparedFields.hold_lines) {
  [int]$preparedFields.hold_lines
} elseif ($runReceipt.hold_lines) {
  [int]$runReceipt.hold_lines
} else {
  [int][Math]::Floor(($Steps / $stepsPerBeat) * 4 * $SongLpb + 0.0000001)
}
$patternBoundaryLines = if ($preparedFields.pattern_boundary_lines) {
  [int]$preparedFields.pattern_boundary_lines
} elseif ($runReceipt.pattern_boundary_lines -match '^\d+$') {
  [int]$runReceipt.pattern_boundary_lines
} else { 512 }
$patternCount = if ($preparedFields.pattern_count) {
  [int]$preparedFields.pattern_count
} else {
  [int][Math]::Ceiling(([int]$sidecar.rendered_lines - $preRollLines) / $patternBoundaryLines)
}
$receiptCycleBeats = if ($preparedFields.cycle_beats) {
  [double]$preparedFields.cycle_beats
} else { [double]$cycleBeats }
$cycleStarts = for ($cycle = 0; $cycle -lt 4; $cycle++) {
  $measurement.Measurements.onsets[$cycle * $Steps]
}
$cycleDurations = for ($cycle = 1; $cycle -lt 4; $cycle++) {
  [double]$cycleStarts[$cycle].measured_ms - [double]$cycleStarts[$cycle - 1].measured_ms
}
$cycleErrors = @($cycleDurations | ForEach-Object { [Math]::Round($_ - $expectedCycleMs,3) })
$onsetErrors = @($measurement.Measurements.onsets | ForEach-Object { [Math]::Abs([double]$_.error_ms) })
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
$installedRuntime = Join-Path $env:APPDATA 'Renoise\V3.5.4\Scripts\Tools\com.david303ttl.ACID.xrnx'
$packageArchive = Join-Path $repoRoot 'dist/com.david303ttl.ACID_0.1.xrnx'
$packageHash = if (Test-Path -LiteralPath $packageArchive) {
  (Get-FileHash -LiteralPath $packageArchive -Algorithm SHA256).Hash.ToLowerInvariant()
} else { $null }
$report = [ordered]@{
  format = 'ACID-PHRASE-TIMING-RESULT-1'
  case_id = $case.id
  status = $measurement.Status
  issues = @($measurement.Issues)
  provenance = @{
    commit = $commit
    installed_package_sha256 = $packageHash
    installed_runtime_directory = $installedRuntime
    renoise_version = $sidecar.renoise_version
    instrument = $runReceipt.instrument
    global_instrument_slot = [int]$runReceipt.global_instrument_slot
    phrase_program = [int]$runReceipt.phrase_program
    phrase_name = $runReceipt.phrase_name
    phrase_playback_mode = $runReceipt.phrase_playback_mode
    phrase_lpb = [int]$runReceipt.phrase_lpb
    phrase_shuffle = [double]$runReceipt.phrase_shuffle
    phrase_line_count = [int]$runReceipt.phrase_line_count
    phrase_loop_start = [int]$runReceipt.phrase_loop_start
    phrase_loop_end = [int]$runReceipt.phrase_loop_end
    source_note_value = [int]$runReceipt.source_note_value
    meter_beats_per_bar = [int]$runReceipt.meter_beats_per_bar
    meter_lines_per_beat = [int]$runReceipt.meter_lines_per_beat
    configured_pattern_boundary_lines = $runReceipt.pattern_boundary_lines
    pre_roll_alignment_lines = $runReceipt.pre_roll_alignment_lines
    host_note_position = $preparedFields.host_note
    host_off_position = $preparedFields.host_off
    pre_roll_lines = $preRollLines
    hold_lines = $holdLines
    pattern_boundary_lines = $patternBoundaryLines
    arrangement_pattern_count = $patternCount
    receipt_cycle_beats = $receiptCycleBeats
    wav_path = $wav
    wav_sha256 = $audio.Sha256
    render_sidecar_path = $sidecarPath
    render_sidecar_sha256 = (Get-FileHash -LiteralPath $sidecarPath -Algorithm SHA256).Hash.ToLowerInvariant()
    timing_run_receipt_path = (Resolve-Path -LiteralPath $RunReceiptPath).Path
  }
  timing = @{
    mode = $Mode
    steps = $Steps
    traversals = 4
    bpm = $Bpm
    song_lpb = $SongLpb
    tpl = 12
    cycle_beats = [Math]::Round($cycleBeats,6)
    expected_cycle_ms = [Math]::Round($expectedCycleMs,3)
    measured_cycle_durations_ms = @($cycleDurations | ForEach-Object { [Math]::Round($_,3) })
    cycle_duration_errors_ms = $cycleErrors
    max_absolute_onset_error_ms = if ($onsetErrors.Count) { [Math]::Round(($onsetErrors | Measure-Object -Maximum).Maximum,3) } else { $null }
    max_absolute_cycle_error_ms = if ($cycleErrors.Count) { [Math]::Round((@($cycleErrors | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum),3) } else { $null }
  }
  measurements = $measurement.Measurements
  audio = $measurement.Audio
}

if (-not $OutputPath) { $OutputPath = [System.IO.Path]::ChangeExtension($wav, 'timing_report.json') }
if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite '$OutputPath'" }
$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
  New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json -InputObject $report -Depth 40) -Encoding utf8
Write-Output ("{0}: {1}; {2} onsets; expected cycle {3:N3} ms; measured cycles {4}; max onset error {5:N3} ms; WAV SHA-256 {6}" -f
  $case.id, $measurement.Status.ToUpperInvariant(), $expectedOnsets.Count,
  $expectedCycleMs, (($cycleDurations | ForEach-Object { '{0:N3}' -f $_ }) -join ', '),
  $report.timing.max_absolute_onset_error_ms, $audio.Sha256)
Write-Output "Report: $OutputPath"
