#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
$oracle = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\audio_cases.json') -Raw | ConvertFrom-Json -AsHashtable

Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class AcidSyntheticWave
{
    public static void Write(
        string path,
        int sampleRate,
        int frames,
        int bits,
        double originMs,
        double stepMs,
        double[] onsetSteps,
        int[] onsetNotes,
        double baseFrequency,
        int rootNote,
        double pitchOffsetCents,
        double driftMsPerEvent,
        double offAtMs,
        double amplitudeScale,
        double gapStartMs,
        double gapEndMs,
        double glideStartMs,
        double glideEndMs,
        int glideFromNote,
        int glideToNote,
        bool addGlideRetrigger,
        double gateFraction,
        bool instantGlide)
    {
        int extraCount = addGlideRetrigger ? 1 : 0;
        double[] eventTimes = new double[onsetSteps.Length + extraCount];
        int[] eventNotes = new int[onsetNotes.Length + extraCount];
        for (int index = 0; index < onsetSteps.Length; index++)
        {
            eventTimes[index] = originMs + onsetSteps[index] * stepMs + index * driftMsPerEvent;
            eventNotes[index] = onsetNotes[index];
        }
        if (addGlideRetrigger)
        {
            eventTimes[eventTimes.Length - 1] = originMs + glideStartMs;
            eventNotes[eventNotes.Length - 1] = glideToNote;
            Array.Sort(eventTimes, eventNotes);
        }

        using (FileStream stream = File.Create(path))
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            int bytesPerSample = bits / 8;
            int dataBytes = frames * bytesPerSample;
            writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(36 + dataBytes);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
            writer.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
            writer.Write(16);
            writer.Write((short)1);
            writer.Write((short)1);
            writer.Write(sampleRate);
            writer.Write(sampleRate * bytesPerSample);
            writer.Write((short)bytesPerSample);
            writer.Write((short)bits);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
            writer.Write(dataBytes);

            int eventIndex = -1;
            int currentNote = rootNote;
            double attackStartMs = double.NegativeInfinity;
            double phase = 0.0;
            for (int frame = 0; frame < frames; frame++)
            {
                double timeMs = 1000.0 * frame / sampleRate;
                while (eventIndex + 1 < eventTimes.Length && timeMs >= eventTimes[eventIndex + 1])
                {
                    eventIndex++;
                    currentNote = eventNotes[eventIndex];
                    attackStartMs = eventTimes[eventIndex];
                    phase = 0.0;
                }

                double semitone = currentNote;
                if (instantGlide && glideStartMs >= 0.0 && timeMs >= originMs + glideStartMs)
                {
                    semitone = glideToNote;
                }
                else if (glideEndMs > glideStartMs && timeMs >= originMs + glideStartMs && timeMs < originMs + glideEndMs)
                {
                    double progress = (timeMs - originMs - glideStartMs) / (glideEndMs - glideStartMs);
                    semitone = glideFromNote + (glideToNote - glideFromNote) * progress;
                }
                else if (glideEndMs > glideStartMs && timeMs >= originMs + glideEndMs)
                {
                    semitone = glideToNote;
                }
                double frequency = baseFrequency * Math.Pow(2.0, (semitone - rootNote + pitchOffsetCents / 100.0) / 12.0);
                phase += frequency / sampleRate;
                if (phase >= 1.0) phase -= Math.Floor(phase);

                double envelope = 0.0;
                if (!double.IsNegativeInfinity(attackStartMs))
                {
                    double ageMs = timeMs - attackStartMs;
                    if (ageMs < 10.0) envelope = Math.Max(0.0, ageMs / 10.0);
                    else if (ageMs < 30.0) envelope = 1.0 - (1.0 - 0.65) * ((ageMs - 10.0) / 20.0);
                    else envelope = 0.65;
                }
                if (gateFraction > 0.0 && eventIndex >= 0)
                {
                    double gateMs = stepMs * gateFraction;
                    double eventAgeMs = timeMs - eventTimes[eventIndex];
                    if (eventAgeMs >= gateMs)
                    {
                        envelope = eventAgeMs < gateMs + 5.0
                            ? 0.65 * (1.0 - (eventAgeMs - gateMs) / 5.0)
                            : 0.0;
                    }
                }
                if (offAtMs >= 0.0 && timeMs >= offAtMs)
                {
                    envelope = timeMs < offAtMs + 5.0 ? 0.65 * (1.0 - (timeMs - offAtMs) / 5.0) : 0.0;
                }

                double sample = (2.0 * phase - 1.0) * 0.35 * envelope * amplitudeScale;
                if (timeMs >= gapStartMs && timeMs < gapEndMs) sample = 0.0;
                sample = Math.Max(-1.0, Math.Min(1.0, sample));
                if (bits == 16)
                {
                    writer.Write((short)Math.Round(sample * 32767.0));
                }
                else
                {
                    int value = (int)Math.Round(sample * 8388607.0);
                    writer.Write((byte)(value & 0xff));
                    writer.Write((byte)((value >> 8) & 0xff));
                    writer.Write((byte)((value >> 16) & 0xff));
                }
            }
        }
    }
}
'@

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tempRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'tmp/acid-audio-oracle-tests'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$testDirectory = Join-Path $tempRoot "run-$PID"
if (Test-Path -LiteralPath $testDirectory) { throw "Refusing to reuse test directory '$testDirectory'" }
New-Item -ItemType Directory -Path $testDirectory | Out-Null

function Get-Case([string]$Id) {
  $case = @($oracle.cases | Where-Object { $_.id -ceq $Id }) | Select-Object -First 1
  if ($null -eq $case) { throw "Test case '$Id' is missing from audio_cases.json" }
  return $case
}

function Invoke-SyntheticCase(
  [string]$CaseId,
  [string]$Label,
  [double]$PitchOffsetCents = 0.0,
  [double]$DriftMsPerEvent = 0.0,
  [double]$AmplitudeScale = 1.0,
  [double]$GapOffsetStep = -1.0,
  [double]$GapDurationMs = 0.0,
  [double]$ReleaseOffsetMs = 0.0,
  [switch]$AddGlideRetrigger,
  [switch]$InstantGlide,
  [double]$InstantGlideOffsetMs = 0.0,
  [int]$BitDepth = 24,
  [switch]$OmitLastOnset,
  [bool]$ExpectPass
) {
  $case = Get-Case $CaseId
  $sampleRate = [int]$case.capture.sample_rate
  $stepMs = 60000.0 / ([double]$case.capture.bpm * 4.0)
  $expectedEndStep = 0.0
  foreach ($event in @($case.expected.onsets)) { $expectedEndStep = [Math]::Max($expectedEndStep,[double]$event.at_step) }
  foreach ($window in @($case.expected.pitch_windows)) { $expectedEndStep = [Math]::Max($expectedEndStep,[double]$window.end_step) }
  foreach ($window in @($case.expected.silence_windows)) { $expectedEndStep = [Math]::Max($expectedEndStep,[double]$window.end_step) }
  foreach ($window in @($case.expected.continuity_windows)) { $expectedEndStep = [Math]::Max($expectedEndStep,[double]$window.end_step) }
  if ($case.expected.release) { $expectedEndStep = [Math]::Max($expectedEndStep,[double]$case.expected.release.off_at_step) }
  if ($case.expected.settled_window) { $expectedEndStep = [Math]::Max($expectedEndStep,[double]$case.expected.settled_window.start_step + [double]$case.expected.settled_window.duration_ms / $stepMs) }

  $originMs = 1000.0
  $tailMs = if ($case.capture.minimum_tail_ms) { [double]$case.capture.minimum_tail_ms } else { 500.0 }
  $frames = [int][Math]::Ceiling(($originMs + $expectedEndStep * $stepMs + $tailMs + 50.0) * $sampleRate / 1000.0)
  $onsetSteps = [double[]]@($case.expected.onsets | ForEach-Object { [double]$_.at_step })
  $onsetNotes = [int[]]@($case.expected.onsets | ForEach-Object { [int]$_.note })
  if ($OmitLastOnset) {
    $onsetSteps = $onsetSteps[0..($onsetSteps.Length - 2)]
    $onsetNotes = $onsetNotes[0..($onsetNotes.Length - 2)]
  }
  $offAtMs = if ($case.expected.release) { $originMs + [double]$case.expected.release.off_at_step * $stepMs + $ReleaseOffsetMs } else { -1.0 }
  $gapStartMs = -1.0
  $gapEndMs = -1.0
  if ($GapOffsetStep -ge 0) { $gapStartMs = $originMs + $GapOffsetStep * $stepMs; $gapEndMs = $gapStartMs + $GapDurationMs }
  $glide = $case.expected.glide_window
  $glideStartMs = if ($glide) { [double]$glide.start_step * $stepMs } else { -1.0 }
  if ($InstantGlide) { $glideStartMs += $InstantGlideOffsetMs }
  $glideEndMs = if ($glide) { [double]$case.expected.settled_window.start_step * $stepMs } else { -1.0 }
  $glideFrom = if ($glide) { [int]$glide.from_note } else { 48 }
  $glideTo = if ($glide) { [int]$glide.to_note } else { 55 }
  $gateFraction = if ($case.playback['calibration_marker_gate_fraction']) { [double]$case.playback['calibration_marker_gate_fraction'] } else { 0.0 }
  $path = Join-Path $testDirectory "$Label.wav"

  [AcidSyntheticWave]::Write(
    $path, $sampleRate, $frames, $BitDepth, $originMs, $stepMs, $onsetSteps, $onsetNotes,
    [double]$case.profile.base_frequency_hz, [int]$case.profile.root_note,
    $PitchOffsetCents, $DriftMsPerEvent, $offAtMs, $AmplitudeScale,
    $gapStartMs, $gapEndMs, $glideStartMs, $glideEndMs, $glideFrom, $glideTo,
    [bool]$AddGlideRetrigger.IsPresent, $gateFraction, [bool]$InstantGlide.IsPresent)

  $audio = Read-ArticulationWav $path
  $result = Measure-ArticulationCase $audio $case
  if ($ExpectPass -and $result.Status -ne 'pass') {
    throw "$Label should pass but failed: $($result.Issues -join '; '). Detected onsets: $($result.Measurements.detected_onsets_ms -join ', ')"
  }
  $expectedFailureStatus = if ($Label -in 'negative_clipping','negative_silent','negative_drift') { 'invalid' } else { 'fail' }
  if (-not $ExpectPass -and $result.Status -ne $expectedFailureStatus) {
    throw "$Label should fail but returned '$($result.Status)'"
  }
  if ($Label -eq 'positive_glide') {
    if (-not $result.Measurements.glide_trajectory.monotonic -or -not $result.Measurements.glide_settle.passed) {
      throw 'Positive glide did not prove monotonic movement and settling'
    }
  }
  if ($Label -in @('negative_early_release','negative_near_off_release') -and $result.Measurements.release.passed) {
    throw 'Early release incorrectly passed the pre-OFF sustain check'
  }
  if ($InstantGlide -and $result.Measurements.glide_trajectory.monotonic) {
    throw 'Instantaneous pitch jump incorrectly passed the measurable-glide check'
  }
  if ($Label -eq 'negative_retrigger') {
    if (@($result.Measurements.no_attack_windows | Where-Object { -not $_.passed }).Count -eq 0) {
      throw 'Seeded retrigger was not reported in a forbidden attack window'
    }
  }
  if ($Label -eq 'negative_gap') {
    if (@($result.Measurements.continuity_windows | Where-Object { -not $_.passed }).Count -eq 0) {
      throw 'Seeded gap was not reported by the continuity measurement'
    }
  }
  if ($Label -eq 'negative_pitch') {
    if (@($result.Measurements.pitch_windows | Where-Object { -not $_.passed }).Count -eq 0) {
      throw 'Seeded pitch error was not reported by pitch measurement'
    }
  }
  if ($Label -eq 'negative_clipping' -and $audio.PeakDbfs -le -6.0) { throw 'Seeded clipping did not exceed the peak ceiling' }
  Write-Output ("{0}: {1}" -f $Label,$result.Status.ToUpperInvariant())
}

try {
  # Every supported calibration pitch must remain one attack during a held saw.
  foreach ($note in 36..55) {
    $held = [double[]]::new(24000)
    $frequency = 262.5 * [Math]::Pow(2.0, ($note - 48) / 12.0)
    for ($frame = 4800; $frame -lt $held.Length; $frame++) {
      $held[$frame] = 0.1 * (2.0 * (($frame * $frequency / 48000.0) % 1.0) - 1.0)
    }
    $attacks = Find-AudioOnsets $held 48000 -60
    if ($attacks.Count -ne 1 -or [Math]::Abs($attacks[0] - 100.0) -gt 1.0) {
      throw "Held saw note $note produced false attacks or a biased onset: $($attacks -join ', ')"
    }
  }
  Write-Output 'Held saw onset controls: PASS (20 pitches)'
  # Envelope resets must be distinguishable from carrier beating and smooth glide.
  foreach ($note in 36, 43, 48, 55) {
    foreach ($gain in 0.03, 0.2) {
      $attackMs = 10.0
      foreach ($reset in $false, $true) {
        $signal = [double[]]::new(28800)
        $phase = 0.0
        for ($frame = 4800; $frame -lt $signal.Length; $frame++) {
          $time = $frame / 48.0
          $age = if ($reset -and $time -ge 350) { $time - 350 } else { $time - 100 }
          $envelope = if ($age -lt $attackMs) { $age / $attackMs } elseif ($age -lt ($attackMs + 20)) { 1 - 0.35 * ($age - $attackMs) / 20 } else { 0.65 }
          $pitch = $note + $(if (-not $reset) { 7 * [Math]::Min(1, [Math]::Max(0, ($time - 300) / 100)) } else { 0 })
          $frequency = 262.5 * [Math]::Pow(2, ($pitch - 48) / 12)
          $phase += $frequency / 48000
          $signal[$frame] = $gain * $envelope * (2 * ($phase % 1) - 1)
        }
        $attacks = Find-AudioOnsets $signal 48000 -60
        $count = if ($reset) { 2 } else { 1 }
        if ($attacks.Count -ne $count) { throw "Envelope reset/glide note $note gain $gain reset $reset detected $($attacks -join ', ')" }
        if ($reset -and [Math]::Abs(($attacks[1] - $attacks[0]) - 250) -gt 10) { throw "Envelope reset timing note $note attacks $($attacks -join ', ')" }
      }
    }
  }
  Write-Output 'Envelope reset and continuous glide controls: PASS (four pitches, two gains)'
  $scaledSignal = [double[]]::new(48000)
  for ($frame = 0; $frame -lt $scaledSignal.Length; $frame++) {
    $timeMs = 1000.0 * $frame / 48000.0
    $eventStartMs = if ($timeMs -lt 450.0) { 100.0 } else { 450.0 }
    if ($timeMs -lt 100.0 -or $timeMs -ge 850.0) { continue }
    $ageMs = $timeMs - $eventStartMs
    $envelope = if ($ageMs -lt 10.0) { $ageMs / 10.0 } elseif ($ageMs -lt 30.0) { 1.0 - 0.35 * ($ageMs - 10.0) / 20.0 } else { 0.65 }
    $scaledSignal[$frame] = 0.05 * $envelope * [Math]::Sin(2.0 * [Math]::PI * 220.0 * $ageMs / 1000.0)
  }
  $gain = 4.0
  $gainDb = 20.0 * [Math]::Log10($gain)
  $scaledSignalCopy = [double[]]@($scaledSignal | ForEach-Object { $_ * $gain })
  $sourceAttacks = [double[]](Find-AudioOnsets $scaledSignal 48000 -60.0 10 40.0)
  $copyAttacks = [double[]](Find-AudioOnsets $scaledSignalCopy 48000 (-60.0 + $gainDb) 10 40.0)
  if ($sourceAttacks.Count -ne 2 -or $copyAttacks.Count -ne $sourceAttacks.Count) { throw 'Gain-scaled retrigger control changed the detected attack count' }
  for ($index = 0; $index -lt $sourceAttacks.Count; $index++) {
    if ([Math]::Abs($sourceAttacks[$index] - $copyAttacks[$index]) -gt 1.0) { throw 'Gain-compensated onset floor changed a detected attack time' }
  }
  Write-Output 'Normalization-aware onset controls: PASS (attack and retrigger scale invariance)'
  foreach ($shape in 'attack_decay','flat','attack_only','truncated') {
    $signal = [double[]]::new($(if ($shape -eq 'truncated') { 2000 } else { 4800 }))
    for ($frame=0; $frame -lt $signal.Length; $frame++) {
      $age = $frame / 48.0
      $envelope = if ($shape -eq 'flat') { 0.65 } elseif ($age -lt 10) { $age / 10.0 } elseif ($shape -eq 'attack_only') { 1.0 } elseif ($age -lt 30) { 1.0 - 0.35 * ($age - 10.0) / 20.0 } else { 0.65 }
      $signal[$frame] = 0.3 * $envelope * [Math]::Sin(2.0 * [Math]::PI * 240.0 * $frame / 48000.0)
    }
    $signature = Measure-AttackSignature $signal 48000 0
    if ($signature.matched -ne ($shape -eq 'attack_decay')) { throw "Attack signature misclassified $shape" }
    if (-not $signature.matched -and $signature.status -ne 'inconclusive') { throw 'Ambiguous attack signature was not inconclusive' }
  }
  Write-Output 'Attack signature controls: PASS (attack/decay, flat hold, missing decay, truncated)'
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'positive_calibration' -ExpectPass $true
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'positive_pcm16' -BitDepth 16 -ExpectPass $true
  Invoke-SyntheticCase 'same_pitch_retrigger_control' 'positive_retrigger_control' -ExpectPass $true
  Invoke-SyntheticCase 'held_note_reference' 'positive_release' -ExpectPass $true
  Invoke-SyntheticCase 'one_shot_note_tail_bpm_120' 'positive_writer_tail' -ExpectPass $true
  Invoke-SyntheticCase 'one_shot_note_tail_bpm_120' 'negative_writer_tail_late' -ReleaseOffsetMs 25 -ExpectPass $false
  Invoke-SyntheticCase 'one_shot_note_tail_bpm_120' 'negative_writer_tail_early' -ReleaseOffsetMs -25 -ExpectPass $false
  foreach ($family in 'note','tie','two_ties') {
    foreach ($bpm in 90,120,150) {
      $id="one_shot_${family}_tail_bpm_$bpm"
      Invoke-SyntheticCase $id "positive_$id" -ExpectPass $true
      Invoke-SyntheticCase $id "negative_late_$id" -ReleaseOffsetMs 25 -ExpectPass $false
      Invoke-SyntheticCase $id "negative_early_$id" -ReleaseOffsetMs -25 -ExpectPass $false
    }
  }
  Invoke-SyntheticCase 'slide_rate_20' 'positive_glide' -ExpectPass $true
  Invoke-SyntheticCase 'repeat_slide_seam_length_16' 'positive_repeat_same_pitch' -ExpectPass $true
  Invoke-SyntheticCase 'repeat_slide_seam_length_16' 'negative_repeat_same_pitch_gap' -GapOffsetStep 15.95 -GapDurationMs 18 -ExpectPass $false
  Invoke-SyntheticCase 'one_shot_four_semitone_slide' 'positive_writer_glide' -ExpectPass $true
  Invoke-SyntheticCase 'one_shot_four_semitone_slide' 'negative_writer_glide_retrigger' -AddGlideRetrigger -ExpectPass $false
  Invoke-SyntheticCase 'one_shot_four_semitone_slide' 'negative_writer_glide_pitch' -PitchOffsetCents 75 -ExpectPass $false
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_pitch' -PitchOffsetCents 70 -ExpectPass $false
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_drift' -DriftMsPerEvent 0.15 -ExpectPass $false
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_missing_onset' -OmitLastOnset -ExpectPass $false
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_silent' -AmplitudeScale 0 -ExpectPass $false
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_clipping' -AmplitudeScale 4 -ExpectPass $false
  Invoke-SyntheticCase 'slide_rate_20' 'negative_retrigger' -AddGlideRetrigger -ExpectPass $false
  Invoke-SyntheticCase 'slide_rate_20' 'negative_gap' -GapOffsetStep 2.02 -GapDurationMs 18 -ExpectPass $false
  Invoke-SyntheticCase 'held_note_reference' 'negative_early_release' -ReleaseOffsetMs -500 -ExpectPass $false
  Invoke-SyntheticCase 'held_note_reference' 'negative_near_off_release' -ReleaseOffsetMs -12 -ExpectPass $false
  Invoke-SyntheticCase 'slide_rate_20' 'negative_instant_glide' -InstantGlide -ExpectPass $false
  foreach ($jumpOffset in @(20, 35, 50)) {
    Invoke-SyntheticCase 'slide_rate_20' "negative_delayed_jump_$jumpOffset" -InstantGlide -InstantGlideOffsetMs $jumpOffset -ExpectPass $false
  }
  # Author two independent releases so a later valid edge cannot hide an earlier failure.
  foreach ($fault in 'none','first_early','first_late','second_early','second_late','first_silent') {
    $case = (Get-Case 'held_note_reference') | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
    $case.expected.onsets = @(@{at_step=0;note=48;tolerance_ms=5},@{at_step=4;note=48;tolerance_ms=5})
    $case.expected.pitch_windows = @()
    $case.expected.silence_windows = @()
    $case.expected.release_edges = @(@{off_at_step=2;maximum_tail_ms=10},@{off_at_step=6;maximum_tail_ms=10})
    $samples = [double[]]::new(96000)
    for ($frame=0; $frame -lt $samples.Length; $frame++) {
      $ms=$frame/48.0
      $voice=if ($ms -lt 1500) {0} else {1}
      $start=1000.0+500*$voice
      $off=$start+250
      if (($fault -eq 'first_early' -and $voice -eq 0) -or ($fault -eq 'second_early' -and $voice -eq 1)) {$off-=30}
      if (($fault -eq 'first_late' -and $voice -eq 0) -or ($fault -eq 'second_late' -and $voice -eq 1)) {$off+=30}
      $age=$ms-$start
      $env=if ($age -lt 0) {0} elseif ($ms -ge $off) {[Math]::Max(0,1-($ms-$off)/5)} else {[Math]::Min(1,$age/10)}
      if ($fault -eq 'first_silent' -and $voice -eq 0) {$env=0}
      $samples[$frame]=0.2*$env*[Math]::Sin(2*[Math]::PI*262.5*$age/1000)
    }
    $audio=[pscustomobject]@{Left=$samples;SampleRate=48000;Channels=1;BitsPerSample=24;PeakDbfs=-13;StereoDifferenceDb=$null;DurationMs=2000;Sha256='synthetic independent release edges'}
    $result=Measure-ArticulationCase $audio $case
    if ($fault -eq 'none') {
      if ($result.Status -ne 'pass' -or $result.Measurements.release_edges.Count -ne 2) {throw "Independent releases should pass: $($result.Issues -join '; ')"}
    } else {
      $index=if ($fault.StartsWith('second')) {1} else {0}
      if ($result.Status -eq 'pass' -or ($fault -ne 'first_silent' -and $result.Measurements.release_edges[$index].passed)) {throw "Independent release fault escaped: $fault"}
    }
  }
  Write-Output 'Independent release edges: PASS (two edges; early, late and silent faults)'
  $goodBytes = [System.IO.File]::ReadAllBytes((Join-Path $testDirectory 'positive_pcm16.wav'))
  foreach ($corruption in 'riff_size','zero_sample_rate','byte_rate','incomplete_fmt') {
    $badBytes = [byte[]]$goodBytes.Clone()
    switch ($corruption) {
      'riff_size' { [BitConverter]::GetBytes([uint32]4).CopyTo($badBytes,4) }
      'zero_sample_rate' { [BitConverter]::GetBytes([uint32]0).CopyTo($badBytes,24) }
      'byte_rate' { [BitConverter]::GetBytes([uint32]1).CopyTo($badBytes,28) }
      'incomplete_fmt' { [BitConverter]::GetBytes([uint32]8).CopyTo($badBytes,16) }
    }
    $badPath = Join-Path $testDirectory "$corruption.wav"
    [System.IO.File]::WriteAllBytes($badPath,$badBytes)
    $rejected = $false
    try { $null = Read-ArticulationWav $badPath } catch { $rejected = $true }
    if (-not $rejected) { throw "Malformed WAV $corruption was accepted" }
  }
  Write-Output 'Malformed WAV controls: PASS (4 headers)'
  Write-Output 'Audio analyzer synthetic acceptance passed: native-reference discrimination, writer tail controls, independent release edges and seeded failures.'
} finally {
  $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectory)
  $tempPrefix = $tempRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedTestDirectory.StartsWith($tempPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove test directory outside the repository scratch directory: '$resolvedTestDirectory'"
  }
  Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
}
