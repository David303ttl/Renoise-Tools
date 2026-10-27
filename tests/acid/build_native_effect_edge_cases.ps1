#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$OutputPath = (Join-Path $PSScriptRoot 'fixtures/native_effect_edge_cases.json'),
  [switch]$UpdateFixture
)

$ErrorActionPreference = 'Stop'
$stepRates = 90, 150
$cases = [System.Collections.Generic.List[object]]::new()
function New-BaseCase([string]$Id, [int]$Bpm, [int]$Length, [string]$Phrase, [string]$Purpose) {
  return [ordered]@{
    id = $Id
    source = @{ length=$Length; pitch_length=2; pitches=@(48,52); slide_pitch_indices=@(1,2); accent_pitch_indices=@() }
    phrase = $Phrase
    capture = @{ tpl=12; sample_rate=48000; minimum_tail_ms=500; song_lpb=8; bpm=$Bpm; channels='mono-or-dual-mono-stereo'; sample_format='PCM24' }
    analysis = @{ onset_floor_dbfs=-60; maximum_continuity_dip_db=6; maximum_continuity_dip_ms=4; minimum_pitch_window_ms=40; silence_dbfs=-60; onset_tolerance_ms=5; onset_refractory_ms=90; pitch_tolerance_cents=15 }
    playback = @{ trigger_mode='selective'; lines_per_step=2; note_off_step=$Length; looping=$false; renderer='native-probe'; phrase_lpb=8; steady_cycles=0; cold_cycles=1 }
    profile = @{ sample_frames=168; sample_rate=44100; base_frequency_hz=262.5; root_note=48; id='acid-reference-168-frame-saw'; envelope='attack 10 ms, decay 20 ms to 0.65 sustain, release 5 ms' }
    purpose = $Purpose
    status = 'ready'
    qualification = @{ protocol_status='ready'; acoustic_status='unverified'; blockers=@('Capture three unchanged native renders at the declared tempo before accepting this protocol.') }
  }
}

foreach ($bpm in $stepRates) {
  $stepMs = 60000.0 / ($bpm * 4.0)
  foreach ($rate in 8,32,64) {
    $commandLines = [Math]::Ceiling(4.0 * 16.0 / $rate)
    $durationSteps = $commandLines / 2.0
    $start = 2.0
    $end = $start + $durationSteps
    $case = New-BaseCase "native_0g$('{0:X2}' -f $rate)_bpm_${bpm}" $bpm 12 "ACID 0G$('{0:X2}' -f $rate) RATE SWEEP" 'native-effect-rate-sweep'
    $case.source.time = @('N','T','N') + @('T') * 9
    $case.source.glide_rate = $rate
    $case.source.command_lines_to_target = $commandLines
    $case.source.glide_start_step = $start
    $case.source.glide_target_step = $end
    $case.trigger = "One host NOTE at phrase start; NOTE 48 at step 0, then NOTE 52 with 0G$('{0:X2}' -f $rate) at step 2; host OFF at step 12."
    $case.expected = @{
      onsets = @(@{at_step=0;note=48;tolerance_ms=5})
      pitch_windows = @(
        @{start_step=0.25;end_step=0.65;note=48},
        @{start_step=($end+0.3);end_step=($end+0.3+[Math]::Max(0.25,40.0/$stepMs));note=52}
      )
      no_attack_windows = @(@{start_step=($start-0.16);end_step=($start+0.16)})
      glide_window = @{from_note=48;to_note=52;rate=$rate;start_step=$start;end_step=$end;analysis_window_steps=0.24;interpretation='native 0G rate against four-semitone target; duration is the declared rate prediction, not a runtime support claim';minimum_progress_delta=[Math]::Min(0.08,0.32/$durationSteps*0.9);minimum_intermediate_progress=0.05;maximum_intermediate_progress=0.95}
      settled_window = @{start_step=($end+0.3);duration_ms=40;note=52}
      release = @{off_at_step=12;silence_starts_at_step=12.08;maximum_tail_ms=10}
      silence_windows = @(@{start_step=12.08;end_step=12.4})
    }
    $cases.Add($case)
  }
}

$rest = New-BaseCase 'native_0g08_rest_cancels_glide' 120 8 'ACID 0G08 REST CANCEL' 'native-effect-rest-cancellation'
$rest.source.time = @('N','N','R','T','T','T','T','T')
$rest.source.glide_rate = 8
$rest.trigger = 'One host NOTE; NOTE 48 at step 0, NOTE 52 with 0G08 at step 1, REST/NOTE OFF at step 2; no later NOTE.'
$rest.expected = @{
  onsets=@(@{at_step=0;note=48;tolerance_ms=5})
  pitch_windows=@(@{start_step=0.25;end_step=0.65;note=48})
  no_attack_windows=@(@{start_step=0.84;end_step=1.16})
  glide_window=@{from_note=48;to_note=52;rate=8;start_step=1;end_step=2;analysis_window_steps=0.24;interpretation='partial 0G08 trajectory before REST interrupts the moving connection';minimum_progress_delta=0.08;minimum_intermediate_progress=0.05;maximum_intermediate_progress=0.95}
  silence_windows=@(@{start_step=2.2;end_step=7.8})
  release=@{off_at_step=2;silence_starts_at_step=2.2;maximum_tail_ms=10}
}
$cases.Add($rest)

$fresh = New-BaseCase 'native_0g08_fresh_note_after_glide' 120 8 'ACID 0G08 FRESH NOTE' 'native-unflagged-note-after-glide'
$fresh.source.time = @('N','N','T','T','T','T','N','T')
$fresh.source.glide_rate = 8
$fresh.trigger = 'One host NOTE; NOTE 48 at step 0, NOTE 52 with 0G08 at step 1, then unflagged NOTE 48 at step 6.'
$fresh.expected = @{
  onsets=@(@{at_step=0;note=48;tolerance_ms=5},@{at_step=6;note=48;tolerance_ms=5})
  pitch_windows=@(@{start_step=0.25;end_step=0.65;note=48},@{start_step=5.25;end_step=5.65;note=52},@{start_step=6.25;end_step=6.65;note=48})
  no_attack_windows=@(@{start_step=0.84;end_step=1.16})
  glide_window=@{from_note=48;to_note=52;rate=8;start_step=1;end_step=5;analysis_window_steps=0.24;interpretation='complete 0G08 connection followed by a distinct unflagged NOTE attack';minimum_progress_delta=0.08;minimum_intermediate_progress=0.05;maximum_intermediate_progress=0.95}
  settled_window=@{start_step=5.3;duration_ms=40;note=52}
  release=@{off_at_step=8;silence_starts_at_step=8.08;maximum_tail_ms=10}
  silence_windows=@(@{start_step=8.08;end_step=8.4})
}
$cases.Add($fresh)

$gated = New-BaseCase 'native_0g08_gated_fresh_note_after_glide' 120 8 'ACID 0G08 GATED FRESH NOTE' 'native-glide-note-off-cancellation-and-fresh-note'
$gated.source.time = @('N','N','T','T','T','R','N','T')
$gated.source.glide_rate = 8
$gated.source.note_off_step = 5.5
$gated.trigger = 'One host NOTE; NOTE 48 step 0, NOTE 52 with 0G08 step 1, explicit NOTE OFF at phrase line 12 / step 5.5 with no effect, then unflagged NOTE 48 step 6.'
$gated.expected = @{
  onsets=@(@{at_step=0;note=48;tolerance_ms=5},@{at_step=6;note=48;tolerance_ms=5})
  pitch_windows=@(@{start_step=0.25;end_step=0.65;note=48},@{start_step=5.1;end_step=5.42;note=52},@{start_step=6.25;end_step=6.65;note=48})
  no_attack_windows=@(@{start_step=0.84;end_step=1.16})
  glide_window=@{from_note=48;to_note=52;rate=8;start_step=1;end_step=5;analysis_window_steps=0.24;interpretation='complete 0G08 connection released by explicit NOTE OFF before an unflagged fresh NOTE';minimum_progress_delta=0.08;minimum_intermediate_progress=0.05;maximum_intermediate_progress=0.95}
  settled_window=@{start_step=5.1;duration_ms=40;note=52}
  silence_windows=@(@{start_step=5.7;end_step=5.9},@{start_step=8.08;end_step=8.4})
  release=@{off_at_step=8;silence_starts_at_step=8.08;maximum_tail_ms=10}
  release_edges=@(@{off_at_step=5.5;silence_starts_at_step=5.7;maximum_tail_ms=10})
}
$cases.Add($gated)

$writer = New-BaseCase 'writer_0g20_rest_gated_fresh_note' 120 7 'Actual ACID writer: NOTE/TIE/NOTE/TIE/NOTE/TIE/REST; one connected 0G20 glide, gated fresh NOTE' 'actual-writer-rest-cancels-glide-before-fresh-note'
$writer.source.length = 7
$writer.source.pitch_length = 3
$writer.source.pitches = @(48,52,48)
$writer.source.time = @('N','T','N','T','N','T','R')
$writer.source.slide_pitch_indices = @(1)
$writer.playback.renderer = 'acid-writer'
$writer.playback.note_off_step = 8
$writer.playback.looping = $false
$writer.trigger = 'Generate with the ACID phrase writer in slide mode. One host NOTE at step 0 and host OFF at step 8. Source NOTE/TIE/NOTE/TIE/NOTE/TIE/REST has pitches 48,52,48; pitch 1 has outgoing slide. The first NOTE is gated off at step 3.5 before the unflagged NOTE at step 4; REST releases the last NOTE at step 6.'
$writer.expected = @{
  onsets=@(@{at_step=0;note=48;tolerance_ms=5},@{at_step=4;note=48;tolerance_ms=5})
  pitch_windows=@(@{start_step=0.25;end_step=0.65;note=48},@{start_step=3.15;end_step=3.47;note=52},@{start_step=4.25;end_step=4.65;note=48})
  no_attack_windows=@(@{start_step=1.84;end_step=2.16})
  continuity_windows=@(@{baseline_start_step=1.3;start_step=1.84;baseline_end_step=1.7;end_step=2.16})
  glide_window=@{from_note=48;to_note=52;rate=32;start_step=2;end_step=3;analysis_window_steps=0.24;interpretation='ACID writer fixed 0G20 connected NOTE transition before the gated fresh NOTE';minimum_progress_delta=0.08;minimum_intermediate_progress=0.05;maximum_intermediate_progress=0.95}
  settled_window=@{start_step=3.15;duration_ms=40;note=52}
  silence_windows=@(@{start_step=3.58;end_step=3.9},@{start_step=6.08;end_step=6.4})
  release=@{off_at_step=6;silence_starts_at_step=6.08;maximum_tail_ms=10}
  release_edges=@(@{off_at_step=3.5;silence_starts_at_step=3.58;maximum_tail_ms=10},@{off_at_step=6;silence_starts_at_step=6.08;maximum_tail_ms=10})
}
$cases.Add($writer)

$oracle = [ordered]@{
  format='ACID-AUDIO-ORACLE-1'
  status='Independent native 0G rate, REST-interruption, and post-glide NOTE protocols. Ready means the windows are authored; native playback is unverified.'
  index_base=0
  step_unit='one straight TIME sixteenth; 1 step = 2 phrase lines at phrase LPB 8'
  capture_requirements=@{sample_rate=48000;preferred_channels=1;allowed_channels=@(1,2);preferred_pcm_bits=24;allowed_pcm_bits=@(16,24,32);peak_ceiling_dbfs=-6;calibration_case='grid_calibration_all_note_pitch_span_16';align_once_to_first_onset=$true;no_per_cycle_realign=$true}
  profile=@{sample_rate=44100;sample_fundamental_hz=262.5;sample_frames=168;root_note=48;id='acid-reference-168-frame-saw';envelope=@{attack_ms=10;decay_ms=20;sustain=0.65;release_ms=5}}
  analysis_defaults=@{silence_rms_dbfs=-60;release_tail_tolerance_ms=5;onset_tolerance_ms=5;pitch_tolerance_cents=15}
  sweep_model='Four-semitone coverage prediction: ceil(4*16/effect-amount) command lines, each 7500/BPM ms at LPB8/TPL12; two phrase lines per straight step. Compare native 0G08/20/40 at 90 and 150 BPM. This is a protocol prediction based on the existing independent native control, not a runtime support claim.'
  cases=@($cases)
}
$fullPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not $fullPath.StartsWith([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures')), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Output must remain under tests/acid/fixtures' }
if ((Test-Path -LiteralPath $fullPath) -and -not $UpdateFixture) { throw "Refusing to overwrite '$fullPath'; use -UpdateFixture to regenerate authored protocols." }
Set-Content -LiteralPath $fullPath -Value (ConvertTo-Json -InputObject $oracle -Depth 30) -Encoding utf8
Write-Output "Wrote $($cases.Count) native edge protocols to $fullPath"
