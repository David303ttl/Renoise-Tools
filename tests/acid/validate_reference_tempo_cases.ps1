#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Path = (Join-Path $PSScriptRoot 'fixtures\reference_tempo_cases.json')
)

$ErrorActionPreference = 'Stop'
$oracle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
if ($oracle.format -cne 'ACID-AUDIO-ORACLE-1' -or [int]$oracle.index_base -ne 0) {
  throw 'Unsupported tempo reference oracle format or event index base'
}
$releaseTailMs = [double]$oracle.profile.envelope.release_ms + [double]$oracle.analysis_defaults.release_tail_tolerance_ms
$ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$required = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($bpm in 90, 150) {
  foreach ($sourceId in 'grid_calibration_all_note_pitch_span_16', 'held_note_reference', 'same_pitch_retrigger_control', 'rest_release_control') {
    [void]$required.Add("${sourceId}_bpm_${bpm}")
  }
}

foreach ($case in $oracle.cases) {
  $id = [string]$case.id
  if (-not $ids.Add($id)) { throw "Duplicate tempo protocol '$id'" }
  if (-not $required.Contains($id)) { throw "Unexpected tempo protocol '$id'" }
  $parts = $id -split '_bpm_'
  $bpm = [int]$parts[-1]
  if ($bpm -notin @(90, 150) -or [int]$case.capture.bpm -ne $bpm -or
      [int]$case.capture.sample_rate -ne [int]$oracle.capture_requirements.sample_rate) {
    throw "$id`: BPM and capture rate must match the tempo protocol"
  }
  if ($case.status -cne 'ready' -or $case.qualification.protocol_status -cne 'ready' -or
      $case.qualification.acoustic_status -cne 'unverified' -or @($case.qualification.blockers).Count -eq 0) {
    throw "$id`: readiness must remain separate from acoustic acceptance"
  }

  $stepMs = 60000.0 / ($bpm * 4.0)
  if ($id.StartsWith('grid_calibration_all_note_pitch_span_16', [StringComparison]::Ordinal)) {
    if (@($case.expected.onsets).Count -ne 68 -or @($case.expected.pitch_windows).Count -ne 68 -or
        @($case.expected.silence_windows).Count -ne 68 -or
        [double]$case.playback.calibration_marker_gate_fraction -ne 0.5) {
      throw "$id`: calibration requires 68 explicit marker events and half-step gates"
    }
    for ($index = 0; $index -lt 68; $index++) {
      $expectedNote = 36 + (($index % 17) % 16)
      $onset = $case.expected.onsets[$index]
      $pitch = $case.expected.pitch_windows[$index]
      $silence = $case.expected.silence_windows[$index]
      $expectedSilence = [Math]::Round($index + 0.5 + $releaseTailMs / $stepMs, 6)
      $pitchWindowMs = ([double]$pitch.end_step - [double]$pitch.start_step) * $stepMs
      $windowInvalid = $pitchWindowMs + 0.001 -lt [double]$case.analysis.minimum_pitch_window_ms -or
        [double]$pitch.start_step -lt $index -or [double]$pitch.end_step -gt ($index + 0.5)
      if ([double]$onset.at_step -ne $index -or [int]$onset.note -ne $expectedNote -or
          [int]$pitch.note -ne $expectedNote -or $windowInvalid -or
          [Math]::Abs([double]$silence.start_step - $expectedSilence) -gt 0.000001 -or
          [double]$silence.end_step -gt ($index + 1)) {
        throw "$id`: calibration event $index has incorrect timing, pitch or release window"
      }
    }
  } else {
    if (@($case.expected.onsets).Count -lt 1 -or @($case.expected.pitch_windows).Count -lt 1 -or
        @($case.expected.silence_windows).Count -ne 1 -or -not $case.expected.release) {
      throw "$id`: native control needs onset, pitch, release and silence expectations"
    }
    $release = $case.expected.release
    $silence = $case.expected.silence_windows[0]
    $expectedSilence = [Math]::Round([double]$release.off_at_step + $releaseTailMs / $stepMs, 6)
    if ([Math]::Abs([double]$release.silence_starts_at_step - $expectedSilence) -gt 0.000001 -or
        [Math]::Abs([double]$silence.start_step - $expectedSilence) -gt 0.000001 -or
        [double]$silence.end_step -le [double]$silence.start_step) {
      throw "$id`: silence window must begin after the nominal release deadline"
    }
    foreach ($window in $case.expected.pitch_windows) {
      if ((([double]$window.end_step - [double]$window.start_step) * $stepMs + 0.001) -lt [double]$case.analysis.minimum_pitch_window_ms) {
        throw "$id`: pitch window is shorter than the analyzer minimum"
      }
    }
  }
}

if ($ids.Count -ne $required.Count) { throw "Expected $($required.Count) tempo protocols, found $($ids.Count)" }
foreach ($id in $required) { if (-not $ids.Contains($id)) { throw "Required tempo protocol '$id' is missing" } }
if ($oracle.calibration_case_by_bpm.'90' -cne 'grid_calibration_all_note_pitch_span_16_bpm_90' -or
    $oracle.calibration_case_by_bpm.'150' -cne 'grid_calibration_all_note_pitch_span_16_bpm_150') {
  throw 'Tempo calibration index is inconsistent'
}
Write-Output "Tempo reference protocols valid: $($oracle.cases.Count) cases at 90 and 150 BPM."
