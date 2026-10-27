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
  if ($case.status -cnotin @('ready', 'planned')) { throw "$id`: missing qualification status" }
  if ($case.status -ceq 'planned') {
    if ($case.qualification.protocol_status -cnotin @('authored', 'blocked') -or
        $case.qualification.acoustic_status -cne 'unverified' -or
        @($case.qualification.blockers).Count -eq 0) {
      throw "$id`: planned protocol requires explicit qualification blockers"
    }
  }
  $source = $case.source
  if ($source.entry_mode -cnotin @('original', 'extended') -or
      $source.length -lt 1 -or $source.length -gt 64 -or
      @($source.time).Count -ne $source.length -or
      $source.pitch_length -lt 1 -or $source.pitch_length -gt 64 -or
      @($source.pitches).Count -lt $source.pitch_length) { throw "$id`: invalid canonical source" }
  foreach ($command in $source.time) {
    if ($command -cnotin @('N', 'T', 'R')) { throw "$id`: invalid TIME command" }
  }
  if ($source.time[0] -ceq 'T') { throw "$id`: source cannot begin with TIE" }
  foreach ($note in $source.pitches) {
    if ($null -eq $note -or $note -is [string] -or -not [double]::IsFinite([double]$note) -or
        $note -lt 0 -or $note -gt 119 -or [double]$note -ne [int]$note) { throw "$id`: invalid PITCH note" }
  }
  if ($case.profile.id -cne $oracle.profile.id) { throw "$id`: reference profile mismatch" }
  if ($case.playback.trigger_mode -cnotin @('selective', 'keymapped') -or
      [string]::IsNullOrWhiteSpace($case.playback.renderer) -or
      [string]::IsNullOrWhiteSpace($case.trigger)) { throw "$id`: playback/trigger context is required" }
  foreach ($group in @('onsets', 'pitch_windows', 'silence_windows')) {
    if (-not $case.expected.ContainsKey($group)) { throw "$id`: missing expected $group" }
  }
  foreach ($group in @('onsets', 'pitch_windows', 'silence_windows', 'continuity_windows', 'no_attack_windows')) {
    foreach ($window in @($case.expected[$group] | Where-Object { $null -ne $_ })) {
      $fields = if ($group -eq 'onsets') { @('at_step', 'note', 'tolerance_ms') } else { @('start_step', 'end_step') }
      foreach ($field in $fields) {
        $value = $window[$field]
        if ($null -eq $value -or $value -is [string] -or -not [double]::IsFinite([double]$value) -or $value -lt 0) {
          throw "$id`: $group.$field must be a finite nonnegative number"
        }
      }
    }
  }
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
    foreach ($onset in @($case.expected.onsets)) {
      if ([double]$onset.at_step -ge [double]$window.start_step -and
          [double]$onset.at_step -lt [double]$window.end_step) { throw "$id`: silence window overlaps expected onset" }
    }
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
foreach ($required in @('isolated_note', 'note_tie', 'note_tie_tie', 'adjacent_equal_notes',
    'adjacent_different_notes', 'all_rest', 'ending_rest', 'trailing_tie_fresh_note',
    'trailing_tie_slide', 'one_step_repeat', 'outgoing_slide_flag', 'incoming_slide_flag',
    'same_note_slide', 'up_slide', 'down_slide', 'octave_slide', 'short_slide',
    'tied_long_slide', 'slide_interrupted_rest', 'alternating_accents',
    'consecutive_accents', 'connected_accent_change', 'host_off', 'fresh_retrigger',
    'transport_stop_start', 'transport_seek', 'keymapped_trigger')) {
  if (-not $ids.Contains($required)) { throw "Required articulation case '$required' is missing" }
}
foreach ($length in @(1, 16, 17, 32, 33, 48, 49, 64)) {
  if ($length -notin @($oracle.cases | ForEach-Object { $_.source.length })) { throw "Required structural length $length is missing" }
}

foreach ($case in $oracle.cases) {
  foreach ($control in @($case.controls)) {
    if (-not $ids.Contains([string]$control.id) -or [string]::IsNullOrWhiteSpace($control.measurement)) {
      throw "$($case.id): unresolved control reference or missing measurement"
    }
  }
  if ($case.source.reference_fixture) {
    $parts = $case.source.reference_fixture -split '#', 2
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $fixturePath = Join-Path $repositoryRoot $parts[0]
    if ($parts.Count -ne 2 -or -not (Test-Path -LiteralPath $fixturePath)) { throw 'Invalid semantic fixture reference' }
    $semantic = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
    if ($parts[1] -cnotin @($semantic.cases.id)) { throw 'Semantic fixture ID does not exist' }
  }
}

Write-Output "Audio oracle valid: $($oracle.cases.Count) cases; $calibrationCount explicit calibration onsets."
