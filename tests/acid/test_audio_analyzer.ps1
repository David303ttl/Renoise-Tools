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
    $path, $sampleRate, $frames, 24, $originMs, $stepMs, $onsetSteps, $onsetNotes,
    [double]$case.profile.base_frequency_hz, [int]$case.profile.root_note,
    $PitchOffsetCents, $DriftMsPerEvent, $offAtMs, $AmplitudeScale,
    $gapStartMs, $gapEndMs, $glideStartMs, $glideEndMs, $glideFrom, $glideTo,
    [bool]$AddGlideRetrigger.IsPresent, $gateFraction, [bool]$InstantGlide.IsPresent)

  $audio = Read-ArticulationWav $path
  $result = Measure-ArticulationCase $audio $case
  if ($ExpectPass -and $result.Status -ne 'pass') {
    throw "$Label should pass but failed: $($result.Issues -join '; '). Detected onsets: $($result.Measurements.detected_onsets_ms -join ', ')"
  }
  if (-not $ExpectPass -and $result.Status -ne 'fail') {
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
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'positive_calibration' -ExpectPass $true
  Invoke-SyntheticCase 'same_pitch_retrigger_control' 'positive_retrigger_control' -ExpectPass $true
  Invoke-SyntheticCase 'held_note_reference' 'positive_release' -ExpectPass $true
  Invoke-SyntheticCase 'slide_rate_20' 'positive_glide' -ExpectPass $true
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_pitch' -PitchOffsetCents 70 -ExpectPass $false
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_drift' -DriftMsPerEvent 0.15 -ExpectPass $false
  Invoke-SyntheticCase 'grid_calibration_all_note_pitch_span_16' 'negative_clipping' -AmplitudeScale 4 -ExpectPass $false
  Invoke-SyntheticCase 'slide_rate_20' 'negative_retrigger' -AddGlideRetrigger -ExpectPass $false
  Invoke-SyntheticCase 'slide_rate_20' 'negative_gap' -GapOffsetStep 2.02 -GapDurationMs 18 -ExpectPass $false
  Invoke-SyntheticCase 'held_note_reference' 'negative_early_release' -ReleaseOffsetMs -500 -ExpectPass $false
  Invoke-SyntheticCase 'held_note_reference' 'negative_near_off_release' -ReleaseOffsetMs -12 -ExpectPass $false
  Invoke-SyntheticCase 'slide_rate_20' 'negative_instant_glide' -InstantGlide -ExpectPass $false
  foreach ($jumpOffset in @(20, 35, 50)) {
    Invoke-SyntheticCase 'slide_rate_20' "negative_delayed_jump_$jumpOffset" -InstantGlide -InstantGlideOffsetMs $jumpOffset -ExpectPass $false
  }
  Write-Output 'Audio analyzer synthetic acceptance passed: 4 positive controls, 20 held pitches, and 11 seeded failures.'
} finally {
  $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectory)
  $tempPrefix = $tempRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedTestDirectory.StartsWith($tempPrefix,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove test directory outside the repository scratch directory: '$resolvedTestDirectory'"
  }
  Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
}
