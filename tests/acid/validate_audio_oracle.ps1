#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Path = (Join-Path $PSScriptRoot 'fixtures\audio_cases.json')
)

$ErrorActionPreference = 'Stop'
$oracle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
if ($oracle.format -cne 'ACID-AUDIO-ORACLE-1') { throw "Unsupported audio oracle format '$($oracle.format)'" }
if ([int]$oracle.index_base -ne 0) { throw 'Audio oracle event positions must use zero-based steps' }
$captureSampleRate = [int]$oracle.capture_requirements.sample_rate
if ($captureSampleRate -le 0) { throw 'Audio oracle capture rate must be positive' }
if ([string]::IsNullOrWhiteSpace([string]$oracle.profile.id)) { throw 'Reference profile ID is required' }
if ([double]$oracle.profile.sample_fundamental_hz -le 0) { throw 'Reference fundamental must be positive' }
if ([double]$oracle.profile.envelope.attack_ms -le 0 -or
    [double]$oracle.profile.envelope.decay_ms -le 0 -or
    [double]$oracle.profile.envelope.release_ms -le 0 -or
    [double]$oracle.profile.envelope.sustain -le 0 -or
    [double]$oracle.profile.envelope.sustain -ge 1) {
  throw 'Reference envelope requires positive stage lengths and sustain in (0,1)'
}

$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$calibrationId = [string]$oracle.capture_requirements.calibration_case
$calibrationCount = 0
foreach ($case in $oracle.cases) {
  $id = [string]$case.id
  if ([string]::IsNullOrWhiteSpace($id) -or -not $ids.Add($id)) { throw "Missing or duplicate case ID '$id'" }
  if ([double]$case.capture.bpm -le 0) { throw "$id`: BPM must be positive" }
  if ([int]$case.capture.sample_rate -ne $captureSampleRate) { throw "$id`: capture sample rate must match the shared oracle requirement ($captureSampleRate Hz)" }
  if ([int]$case.profile.sample_frames -ne 168 -or [int]$case.profile.root_note -ne 48) { throw "$id`: unexpected reference sample geometry" }
  if ([double]$case.analysis.onset_floor_dbfs -ge 0 -or
      [double]$case.analysis.pitch_tolerance_cents -le 0 -or
      [double]$case.analysis.silence_dbfs -ge 0) { throw "$id`: invalid analyzer thresholds" }

  foreach ($event in @($case.expected.onsets)) {
    if ([double]$event.at_step -lt 0 -or [int]$event.note -lt 0 -or [int]$event.note -gt 119 -or [double]$event.tolerance_ms -le 0) {
      throw "$id`: invalid expected onset window"
    }
  }
  foreach ($window in @($case.expected.pitch_windows)) {
    if ([double]$window.end_step -le [double]$window.start_step -or
        ([double]$window.end_step - [double]$window.start_step) * 60000 / ([double]$case.capture.bpm * 4) + 0.000001 -lt [double]$case.analysis.minimum_pitch_window_ms -or
        [int]$window.note -lt 0 -or [int]$window.note -gt 119) {
      throw "$id`: invalid or too-short pitch window"
    }
  }
  foreach ($window in @($case.expected.silence_windows)) {
    if ([double]$window.end_step -le [double]$window.start_step) { throw "$id`: invalid silence window" }
  }
  foreach ($window in @($case.expected.continuity_windows | Where-Object { $null -ne $_ })) {
    if ([double]$window.end_step -le [double]$window.start_step -or
        [double]$window.baseline_end_step -le [double]$window.baseline_start_step) {
      throw "$id`: invalid continuity window"
    }
  }
  foreach ($window in @($case.expected.no_attack_windows | Where-Object { $null -ne $_ })) {
    if ([double]$window.end_step -le [double]$window.start_step) { throw "$id`: invalid no-attack window" }
  }
  if ($case.expected.glide_window) {
    if ([double]$case.expected.glide_window.end_step -le [double]$case.expected.glide_window.start_step -or
        [int]$case.expected.glide_window.rate -lt 1 -or [int]$case.expected.glide_window.rate -gt 254) {
      throw "$id`: invalid glide experiment window or rate"
    }
    if (-not $case.expected.settled_window -or
        [double]$case.expected.settled_window.duration_ms -lt 40 -or
        [int]$case.expected.settled_window.note -ne [int]$case.expected.glide_window.to_note) {
      throw "$id`: glide needs a 40 ms target-pitch window at the settled note"
    }
  }
  if ($case.expected.release) {
    $release = $case.expected.release
    if ([double]$release.off_at_step -le 0 -or [double]$release.maximum_tail_ms -le 0 -or
        [double]$release.silence_starts_at_step -lt [double]$release.off_at_step) {
      throw "$id`: invalid release timing"
    }
    if ($release.ContainsKey('confirmation_ms') -and [double]$release.confirmation_ms -lt 2) {
      throw "$id`: release confirmation must cover at least 2 ms"
    }
  }
  if ($id -ceq $calibrationId) {
    $calibrationCount = @($case.expected.onsets).Count
    if ($calibrationCount -ne 68) { throw "Calibration needs 68 explicit cold and steady-cycle onsets; found $calibrationCount" }
    if (@($case.expected.pitch_windows).Count -ne 68) { throw 'Calibration needs one explicit pitch window per expected onset' }
    if ($case.source.reference_fixture -notlike 'tests/acid/fixtures/loop_cases.json#*') { throw 'Calibration must cite a semantic loop fixture' }
    if (@($case.expected.silence_windows).Count -ne $calibrationCount) { throw 'Calibration needs one gated silence window per onset' }
    if ([double]$case.playback.calibration_marker_gate_fraction -ne 0.5) { throw 'Calibration marker gate must be one half-step' }
    for ($index = 0; $index -lt $calibrationCount; $index++) {
      $onset = $case.expected.onsets[$index]
      $pitch = $case.expected.pitch_windows[$index]
      $silence = $case.expected.silence_windows[$index]
      $expectedNote = 36 + (($index % 17) % 16)
      if ([double]$onset.at_step -ne $index -or [int]$onset.note -ne $expectedNote -or
          [int]$pitch.note -ne $expectedNote -or [double]$pitch.start_step -lt $index -or
          [double]$pitch.end_step -gt ($index + 0.5) -or
          [double]$silence.start_step -lt ($index + 0.5) -or [double]$silence.end_step -gt ($index + 1)) {
        throw "Calibration event $index must preserve the 17-step pitch wrap and half-step marker gate"
      }
    }
  }
}
if (-not $ids.Contains($calibrationId)) { throw "Calibration case '$calibrationId' is missing" }
if (@($oracle.cases | Where-Object { $_.expected.glide_window }).Count -ne 3) { throw 'Expected the three authored 0G08/0G20/0G40 glide experiments' }
if (@($oracle.cases | Where-Object { $_.expected.release }).Count -lt 3) { throw 'Expected release, retrigger and REST controls' }

Write-Output "Audio oracle valid: $($oracle.cases.Count) cases; $calibrationCount explicit calibration onsets."
