#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$SourcePath = (Join-Path $PSScriptRoot 'fixtures\audio_cases.json'),
  [string]$OutputPath = (Join-Path $PSScriptRoot 'fixtures\reference_tempo_cases.json')
)

$ErrorActionPreference = 'Stop'
$sourceOracle = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json -AsHashtable
if ($sourceOracle.format -cne 'ACID-AUDIO-ORACLE-1') { throw 'Unsupported source audio oracle format' }

function Copy-Case($Case) {
  return ($Case | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable)
}

$cases = [System.Collections.Generic.List[object]]::new()
$sourceIds = @(
  'grid_calibration_all_note_pitch_span_16',
  'held_note_reference',
  'same_pitch_retrigger_control',
  'rest_release_control'
)
$releaseTailMs = [double]$sourceOracle.profile.envelope.release_ms +
  [double]$sourceOracle.analysis_defaults.release_tail_tolerance_ms

foreach ($bpm in 90, 150) {
  $stepMs = 60000.0 / ($bpm * 4.0)
  foreach ($sourceId in $sourceIds) {
    $sourceCase = @($sourceOracle.cases | Where-Object { $_.id -ceq $sourceId }) | Select-Object -First 1
    if ($null -eq $sourceCase) { throw "Source case '$sourceId' is missing" }
    $case = Copy-Case $sourceCase
    $case.id = "${sourceId}_bpm_${bpm}"
    $case.capture.bpm = $bpm
    $case.qualification = [ordered]@{
      protocol_status = 'ready'
      acoustic_status = 'unverified'
      blockers = @("No independent native capture is recorded for this protocol at ${bpm} BPM.")
    }

    if ($sourceId -ceq 'grid_calibration_all_note_pitch_span_16') {
      foreach ($window in $case.expected.pitch_windows) {
        $startStep = [double]$window.start_step
        $minimumWidthSteps = [double]$case.analysis.minimum_pitch_window_ms / $stepMs
        $widthSteps = [Math]::Max([double]$window.end_step - $startStep, $minimumWidthSteps)
        $window.end_step = [Math]::Round($startStep + $widthSteps, 6)
      }
      $case.expected.silence_windows = @(
        foreach ($index in 0..67) {
          @{
            start_step = [Math]::Round($index + [double]$case.playback.calibration_marker_gate_fraction + $releaseTailMs / $stepMs, 6)
            end_step = $index + 1
          }
        }
      )
    } else {
      $release = $case.expected.release
      $silenceStart = [Math]::Round([double]$release.off_at_step + $releaseTailMs / $stepMs, 6)
      $silenceWidth = [double]$case.expected.silence_windows[0].end_step - [double]$case.expected.silence_windows[0].start_step
      $release.silence_starts_at_step = $silenceStart
      $case.expected.silence_windows[0].start_step = $silenceStart
      $case.expected.silence_windows[0].end_step = [Math]::Round($silenceStart + $silenceWidth, 6)
    }
    $cases.Add($case)
  }
}

$oracle = [ordered]@{
  format = 'ACID-AUDIO-ORACLE-1'
  status = 'Reference calibration and control protocols for tempo-specific acoustic qualification; protocol readiness does not imply acoustic acceptance.'
  index_base = 0
  step_unit = $sourceOracle.step_unit
  capture_requirements = $sourceOracle.capture_requirements
  profile = $sourceOracle.profile
  analysis_defaults = $sourceOracle.analysis_defaults
  calibration_case_by_bpm = [ordered]@{
    '90' = 'grid_calibration_all_note_pitch_span_16_bpm_90'
    '150' = 'grid_calibration_all_note_pitch_span_16_bpm_150'
  }
  cases = @($cases)
}

Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json -InputObject $oracle -Depth 60) -Encoding utf8
Write-Output "Wrote $($cases.Count) tempo-qualified reference protocols to $OutputPath"
