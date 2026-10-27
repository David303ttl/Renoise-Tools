param(
 [string]$OutputPath = 'tests/acid/fixtures/moving_repeat_glide_cases.json',
 [string]$AudioCasesPath = 'tests/acid/fixtures/audio_cases.json'
)
$ErrorActionPreference='Stop'
function Get-SettlingOffset([int]$Target,[int]$Bpm,[bool]$RequireFortyMs) {
 if(-not $RequireFortyMs){return 0.25}
 $stepMs=60000.0/($Bpm*4.0)
 return [Math]::Max(0.25,41.0/$stepMs)
}
function New-Case([int]$Target,[string]$Id,[int]$Bpm=120,[bool]$RequireFortyMs=$false) {
 $notes=@(@{at_step=0;note=48;tolerance_ms=5})
 $noAttack=[System.Collections.Generic.List[object]]::new()
 $continuity=[System.Collections.Generic.List[object]]::new()
 $pitches=[System.Collections.Generic.List[object]]::new()
 $pitches.Add(@{start_step=0.25;end_step=(0.25+[Math]::Max(0.4,50.0/(60000.0/($Bpm*4.0))));note=48})
 for($cycle=0;$cycle -lt 4;$cycle++) {
  foreach($entry in @(@{start=$cycle*8+4;note=$Target;from=48},@{start=$cycle*8+8;note=48;from=$Target})) {
   if($entry.start -ge 32){continue}
   $start=[double]$entry.start
   $noAttack.Add(@{start_step=[Math]::Round($start-0.16,2);end_step=[Math]::Round($start+0.16,2)})
   $continuity.Add(@{start_step=[Math]::Round($start-0.16,2);end_step=[Math]::Round($start+0.16,2);baseline_start_step=[Math]::Round($start-0.7,2);baseline_end_step=[Math]::Round($start-0.3,2)})
   $settleOffset=[Math]::Abs($Target-48)/4.0+(Get-SettlingOffset $Target $Bpm $RequireFortyMs)
   if($start+$settleOffset -lt 32) {$pitches.Add(@{start_step=$start+$settleOffset;end_step=$start+$settleOffset+[Math]::Max(0.4,50.0/(60000.0/($Bpm*4.0)));note=$entry.note})}
  }
 }
 $window=[Math]::Abs($Target-48)/4.0
 $settleStep=4+$window+(Get-SettlingOffset $Target $Bpm $RequireFortyMs)
 $progressThreshold=if([Math]::Abs($Target-48) -ge 12){0.08}else{0.12}
 $noAttacks=@($noAttack | Where-Object {$_.start_step -ge 3.84 -and $_.start_step -lt 4.16})
 $noAttacks += @($noAttack | Where-Object {$_.start_step -ge 7.84})
 # The analyzer glide estimator samples the first upward transition only.
 $settled=@{start_step=$settleStep;duration_ms=40;note=$Target}
 return [ordered]@{
  id=$Id
  source=@{entry_mode='extended';length=8;pitch_length=2;pitches=@(48,$Target);time=@('N','T','T','T','N','T','T','T');slide_pitch_indices=@(1,2);accent_pitch_indices=@()}
  phrase="Independent bidirectional moving Repeat glide $Id"
  capture=@{sample_rate=48000;sample_format='PCM24';channels='mono-or-dual-mono-stereo';tpl=12;song_lpb=8;bpm=$Bpm;minimum_tail_ms=500}
  analysis=@{pitch_tolerance_cents=15;minimum_pitch_window_ms=40;maximum_continuity_dip_ms=4;maximum_continuity_dip_db=6;onset_floor_dbfs=-60;silence_dbfs=-60;onset_tolerance_ms=5;onset_refractory_ms=90}
  playback=@{renderer='native-probe';trigger_mode='selective';phrase_lpb=8;lines_per_step=2;looping=$true;cold_cycles=1;steady_cycles=3;note_off_step=32}
  trigger='Single host NOTE at step zero and host OFF after four 8-step phrase passes.'
  expected=@{onsets=@($notes);pitch_windows=@($pitches);no_attack_windows=@($noAttacks);continuity_windows=@($continuity);glide_window=@{from_note=48;to_note=$Target;rate=32;start_step=4;end_step=(4+$window);analysis_window_steps=0.24;interpretation='first upward transition in a four-pass bidirectional Repeat phrase';minimum_progress_delta=$progressThreshold;minimum_intermediate_progress=0.05;maximum_intermediate_progress=0.95};settled_window=$settled;release_edges=@(@{off_at_step=32;silence_starts_at_step=32.08;maximum_tail_ms=10});release=@{off_at_step=32;silence_starts_at_step=32.08;maximum_tail_ms=10};silence_windows=@(@{start_step=32.08;end_step=32.4})}
  profile=@{id='acid-reference-168-frame-saw';root_note=48;sample_rate=44100;sample_frames=168;envelope='attack 10 ms, decay 20 ms to 0.65 sustain, release 5 ms';base_frequency_hz=262.5}
  purpose='independent-native-repeat-glide'
  status='ready'
  qualification=@{protocol_status='ready';acoustic_status='unverified';blockers=@('No native or actual writer capture acceptance is implied by protocol readiness.')}
 }
}
$nativeFour=New-Case 52 'native_repeat_glide_four_semitones'
$nativeOctave=New-Case 60 'native_repeat_glide_octave'
function New-WriterCase($Native,[string]$Id) {
 $writer=ConvertFrom-Json -AsHashtable (ConvertTo-Json -InputObject $Native -Depth 30)
 $writer.id=$Id
 $writer.phrase="Actual ACID writer bidirectional moving Repeat glide $Id"
 $writer.playback.renderer='acid-writer'
 $writer.qualification.blockers=@('Actual writer behavior is separate from the independent native probe; three unchanged writer renders must pass.')
 return $writer
}
$writerFour=New-WriterCase $nativeFour 'writer_repeat_glide_four_semitones'
$writerOctave=New-WriterCase $nativeOctave 'writer_repeat_glide_octave'
function New-TailHoldWriterCase([int]$Target,[string]$Id,[int]$Bpm=120,[bool]$RequireFortyMs=$false) {
 $stepCount=9
 $phraseSpan=$stepCount*4
 $noAttack=[System.Collections.Generic.List[object]]::new()
 $continuity=[System.Collections.Generic.List[object]]::new()
 $pitches=[System.Collections.Generic.List[object]]::new()
 $pitches.Add(@{start_step=0.25;end_step=(0.25+[Math]::Max(0.4,50.0/(60000.0/($Bpm*4.0))));note=48})
 for($cycle=0;$cycle -lt 4;$cycle++) {
  foreach($entry in @(@{start=$cycle*$stepCount+4;note=$Target},@{start=$cycle*$stepCount+9;note=48})) {
   if($entry.start -ge $phraseSpan){continue}
   $start=[double]$entry.start
   $noAttack.Add(@{start_step=[Math]::Round($start-0.16,2);end_step=[Math]::Round($start+0.16,2)})
   $continuity.Add(@{start_step=[Math]::Round($start-0.16,2);end_step=[Math]::Round($start+0.16,2);baseline_start_step=[Math]::Round($start-0.7,2);baseline_end_step=[Math]::Round($start-0.3,2)})
   $settleOffset=[Math]::Abs($Target-48)/4.0+(Get-SettlingOffset $Target $Bpm $RequireFortyMs)
   $pitchWidth=[Math]::Max(0.4,50.0/(60000.0/($Bpm*4.0)))
   if($start+$settleOffset+$pitchWidth -lt $phraseSpan){$pitches.Add(@{start_step=$start+$settleOffset;end_step=$start+$settleOffset+$pitchWidth;note=$entry.note})}
  }
 }
 $window=[Math]::Abs($Target-48)/4.0
 $settlingOffset=Get-SettlingOffset $Target $Bpm $RequireFortyMs
 $progressThreshold=if([Math]::Abs($Target-48) -ge 12){0.08}else{0.12}
 return [ordered]@{
  id=$Id
  source=@{entry_mode='extended';length=$stepCount;pitch_length=2;pitches=@(48,$Target);time=@('N','T','T','T','N','T','T','T','T');slide_pitch_indices=@(1,2);accent_pitch_indices=@()}
  phrase="Actual ACID writer bidirectional moving Repeat glide with trailing tie $Id"
  capture=@{sample_rate=48000;sample_format='PCM24';channels='mono-or-dual-mono-stereo';tpl=12;song_lpb=8;bpm=$Bpm;minimum_tail_ms=500}
  analysis=@{pitch_tolerance_cents=15;minimum_pitch_window_ms=40;maximum_continuity_dip_ms=4;maximum_continuity_dip_db=6;onset_floor_dbfs=-60;silence_dbfs=-60;onset_tolerance_ms=5;onset_refractory_ms=90}
  playback=@{renderer='acid-writer';trigger_mode='selective';phrase_lpb=8;lines_per_step=2;looping=$true;cold_cycles=1;steady_cycles=3;note_off_step=$phraseSpan}
  trigger='Single host NOTE at step zero and host OFF after four 9-step phrase passes; the final step is a TIE.'
  expected=@{onsets=@(@{at_step=0;note=48;tolerance_ms=5});pitch_windows=@($pitches);no_attack_windows=@($noAttack);continuity_windows=@($continuity);glide_window=@{from_note=48;to_note=$Target;rate=32;start_step=4;end_step=(4+$window);analysis_window_steps=0.24;interpretation='first upward transition in a four-pass bidirectional Repeat phrase';minimum_progress_delta=$progressThreshold;minimum_intermediate_progress=0.05;maximum_intermediate_progress=0.95};settled_window=@{start_step=(4+$window+$settlingOffset);duration_ms=40;note=$Target};release_edges=@(@{off_at_step=$phraseSpan;silence_starts_at_step=($phraseSpan+0.08);maximum_tail_ms=10});release=@{off_at_step=$phraseSpan;silence_starts_at_step=($phraseSpan+0.08);maximum_tail_ms=10};silence_windows=@(@{start_step=($phraseSpan+0.08);end_step=($phraseSpan+0.4)})}
  profile=@{id='acid-reference-168-frame-saw';root_note=48;sample_rate=44100;sample_frames=168;envelope='attack 10 ms, decay 20 ms to 0.65 sustain, release 5 ms';base_frequency_hz=262.5}
  purpose='actual-writer-repeat-glide-trailing-tie'
  status='ready'
  qualification=@{protocol_status='ready';acoustic_status='unverified';blockers=@('Three actual writer renders are required before accepting the trailing-tie phrase variant.')}
 }
}
$writerFourTailHold=New-TailHoldWriterCase 52 'writer_repeat_glide_four_semitones_tail_hold'
$writerOctaveTailHold=New-TailHoldWriterCase 60 'writer_repeat_glide_octave_tail_hold'
function New-HoldCase([int]$Note,[string]$Id,[int]$Bpm=120) {
 $noAttack=[System.Collections.Generic.List[object]]::new()
 $continuity=[System.Collections.Generic.List[object]]::new()
 $pitches=[System.Collections.Generic.List[object]]::new()
 $pitchWidth=[Math]::Max(0.4,50.0/(60000.0/($Bpm*4.0)))
 foreach($start in @(0,7,15,23,31)){$pitches.Add(@{start_step=$start+0.25;end_step=$start+0.25+$pitchWidth;note=$Note})}
 foreach($start in @(8,16,24)){
  $noAttack.Add(@{start_step=$start-0.16;end_step=$start+0.16})
  $continuity.Add(@{start_step=$start-0.16;end_step=$start+0.16;baseline_start_step=$start-0.7;baseline_end_step=$start-0.3})
 }
 return [ordered]@{
  id=$Id;source=@{entry_mode='extended';length=8;pitch_length=1;pitches=@($Note);time=@('N','T','T','T','T','T','T','T');slide_pitch_indices=@();accent_pitch_indices=@()}
  phrase="Pitch-matched held NOTE control $Note"
  capture=@{sample_rate=48000;sample_format='PCM24';channels='mono-or-dual-mono-stereo';tpl=12;song_lpb=8;bpm=$Bpm;minimum_tail_ms=500}
  analysis=@{pitch_tolerance_cents=15;minimum_pitch_window_ms=40;maximum_continuity_dip_ms=4;maximum_continuity_dip_db=6;onset_floor_dbfs=-60;silence_dbfs=-60;onset_tolerance_ms=5;onset_refractory_ms=90}
  playback=@{renderer='native-probe';trigger_mode='selective';phrase_lpb=8;lines_per_step=2;looping=$true;cold_cycles=1;steady_cycles=3;note_off_step=32}
  trigger='Single host NOTE at step zero and host OFF after four 8-step passes; phrase NOTE is followed by a TIE-only loop.'
  expected=@{onsets=@(@{at_step=0;note=$Note;tolerance_ms=5});pitch_windows=@($pitches);no_attack_windows=@($noAttack);continuity_windows=@($continuity);release_edges=@(@{off_at_step=32;silence_starts_at_step=32.08;maximum_tail_ms=10});release=@{off_at_step=32;silence_starts_at_step=32.08;maximum_tail_ms=10};silence_windows=@(@{start_step=32.08;end_step=32.4})}
  profile=@{id='acid-reference-168-frame-saw';root_note=48;sample_rate=44100;sample_frames=168;envelope='attack 10 ms, decay 20 ms to 0.65 sustain, release 5 ms';base_frequency_hz=262.5}
  purpose='pitch-matched-native-repeat-control';status='ready'
  qualification=@{protocol_status='ready';acoustic_status='unverified';blockers=@('Pitch-matched native hold captures are required before glide continuity interpretation.')}
 }
}
$hold48=New-HoldCase 48 'native_repeat_hold_pitch_48'
$hold52=New-HoldCase 52 'native_repeat_hold_pitch_52'
$hold60=New-HoldCase 60 'native_repeat_hold_pitch_60'
$audioOracle=Get-Content -LiteralPath $AudioCasesPath -Raw | ConvertFrom-Json -AsHashtable
$samePitchSource=@($audioOracle.cases | Where-Object {$_.id -ceq 'repeat_slide_seam_length_16'}) | Select-Object -First 1
if($null -eq $samePitchSource){throw "Source case 'repeat_slide_seam_length_16' is missing from $AudioCasesPath"}
function New-SamePitchTempoCase($Source,[int]$Bpm,[string]$Id) {
 $case=ConvertFrom-Json -AsHashtable (ConvertTo-Json -InputObject $Source -Depth 40)
 $case.id=$Id
 $case.phrase="Actual ACID writer same-pitch Repeat seam $Id"
 $case.capture.bpm=$Bpm
 $stepMs=60000.0/($Bpm*4.0)
 $pitchOffset=[Math]::Max(0.08,50.0/$stepMs)
 $pitchWidth=[Math]::Max(0.32,50.0/$stepMs)
 foreach($window in $case.expected.pitch_windows){$base=[Math]::Floor([double]$window.start_step);$window.start_step=$base+$pitchOffset;$window.end_step=$window.start_step+$pitchWidth}
 $release=$case.expected.release
 $release.silence_starts_at_step=[Math]::Round([double]$release.off_at_step+[Math]::Max(0.12,([double]$release.maximum_tail_ms+2.0)/$stepMs),6)
 foreach($edge in $case.expected.release_edges){$edge.silence_starts_at_step=$release.silence_starts_at_step}
 $case.expected.silence_windows[0].start_step=$release.silence_starts_at_step
 $case.expected.silence_windows[0].end_step=[Math]::Round($release.silence_starts_at_step+0.4,6)
 $case.qualification=[ordered]@{protocol_status='ready';acoustic_status='unverified';blockers=@("No actual ACID writer capture is recorded for this same-pitch seam case at $Bpm BPM.")}
 return $case
}
$nativeFour.controls=@(@{id=$hold48.id;measurement='pitch-matched held NOTE at source pitch'},@{id=$hold52.id;measurement='pitch-matched held NOTE at connected target pitch'})
$nativeOctave.controls=@(@{id=$hold48.id;measurement='pitch-matched held NOTE at source pitch'},@{id=$hold60.id;measurement='pitch-matched held NOTE at octave target pitch'})
$writerFour.controls=$nativeFour.controls
$writerOctave.controls=$nativeOctave.controls
$writerFourTailHold.controls=$nativeFour.controls
$writerOctaveTailHold.controls=$nativeOctave.controls
$additionalCases=[System.Collections.Generic.List[object]]::new()
$samePitchTempoCases=[System.Collections.Generic.List[object]]::new()
foreach($bpm in @(90,150)) {
 $suffix="bpm_$bpm"
 $nativeFourTempo=New-Case 52 "native_repeat_glide_four_semitones_$suffix" $bpm $true
 $nativeOctaveTempo=New-Case 60 "native_repeat_glide_octave_$suffix" $bpm $true
 $writerFourTempo=New-WriterCase $nativeFourTempo "writer_repeat_glide_four_semitones_$suffix"
 $writerOctaveTempo=New-WriterCase $nativeOctaveTempo "writer_repeat_glide_octave_$suffix"
 $tailFourTempo=New-TailHoldWriterCase 52 "writer_repeat_glide_four_semitones_tail_hold_$suffix" $bpm $true
 $tailOctaveTempo=New-TailHoldWriterCase 60 "writer_repeat_glide_octave_tail_hold_$suffix" $bpm $true
 $hold48Tempo=New-HoldCase 48 "native_repeat_hold_pitch_48_$suffix" $bpm
 $hold52Tempo=New-HoldCase 52 "native_repeat_hold_pitch_52_$suffix" $bpm
 $hold60Tempo=New-HoldCase 60 "native_repeat_hold_pitch_60_$suffix" $bpm
 $samePitchTempo=New-SamePitchTempoCase $samePitchSource $bpm "repeat_slide_seam_length_16_bpm_$bpm"
 $samePitchTempo.controls=@(@{id=$hold48Tempo.id;measurement='pitch-matched held NOTE across same-pitch Repeat seams'})
 $nativeFourTempo.controls=@(@{id=$hold48Tempo.id;measurement='pitch-matched held NOTE at source pitch'},@{id=$hold52Tempo.id;measurement='pitch-matched held NOTE at connected target pitch'})
 $nativeOctaveTempo.controls=@(@{id=$hold48Tempo.id;measurement='pitch-matched held NOTE at source pitch'},@{id=$hold60Tempo.id;measurement='pitch-matched held NOTE at octave target pitch'})
 $writerFourTempo.controls=$nativeFourTempo.controls
 $writerOctaveTempo.controls=$nativeOctaveTempo.controls
 $tailFourTempo.controls=$nativeFourTempo.controls
 $tailOctaveTempo.controls=$nativeOctaveTempo.controls
 foreach($case in @($nativeFourTempo,$nativeOctaveTempo,$writerFourTempo,$writerOctaveTempo,$tailFourTempo,$tailOctaveTempo,$hold48Tempo,$hold52Tempo,$hold60Tempo)) {$additionalCases.Add($case)}
 $samePitchTempoCases.Add($samePitchTempo)
}
$allCases=@($nativeFour,$nativeOctave,$writerFour,$writerOctave,$writerFourTailHold,$writerOctaveTailHold,$hold48,$hold52,$hold60)+@($additionalCases.ToArray())+@($samePitchTempoCases.ToArray())
$fixture=[ordered]@{format='ACID-AUDIO-ORACLE-1';profile=@{id='acid-reference-168-frame-saw';sample_rate=44100;sample_fundamental_hz=262.5;sample_frames=168;root_note=48;envelope=@{attack_ms=10;decay_ms=20;sustain=0.65;release_ms=5}};analysis_defaults=@{silence_rms_dbfs=-60;release_tail_tolerance_ms=5;onset_tolerance_ms=5;pitch_tolerance_cents=15};status='Independent semantic windows cover the fixed diagnostic reference profile at 90, 120, and 150 BPM; non-120 BPM settling windows begin at least 40 ms after the final glide command line. Analyzer readiness is not acoustic acceptance.';index_base=0;step_unit='one straight TIME sixteenth; 1 step = 2 phrase lines at phrase LPB 8';capture_requirements=@{sample_rate=48000;preferred_channels=1;allowed_channels=@(1,2);preferred_pcm_bits=24;allowed_pcm_bits=@(16,24,32);peak_ceiling_dbfs=-6;calibration_case='grid_calibration_all_note_pitch_span_16';align_once_to_first_onset=$true;no_per_cycle_realign=$true};cases=$allCases}
$json=ConvertTo-Json -InputObject $fixture -Depth 30
Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8NoBOM
Write-Output "Wrote $($allCases.Count) native-probe, actual-writer, and pitch-matched control protocols to $OutputPath"






