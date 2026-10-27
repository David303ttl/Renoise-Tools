#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class AcidMovingGlideSyntheticWave
{
    public static void Write(
        string path,
        int sampleRate,
        double originMs,
        double stepMs,
        int phraseLength,
        int targetNote,
        bool moving,
        bool instantJump,
        bool retrigger,
        double pitchOffsetCents,
        double gapStartMs,
        double gapEndMs)
    {
        double hostOffStep = phraseLength * 4.0;
        int frames = (int)Math.Ceiling((originMs + (hostOffStep + 1.0) * stepMs + 500.0) * sampleRate / 1000.0);
        using (FileStream stream = File.Create(path))
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            int dataBytes = frames * 2 * 3;
            writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(36 + dataBytes);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
            writer.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
            writer.Write(16);
            writer.Write((short)1);
            writer.Write((short)2);
            writer.Write(sampleRate);
            writer.Write(sampleRate * 6);
            writer.Write((short)6);
            writer.Write((short)24);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
            writer.Write(dataBytes);

            double phase = 0.0;
            double attackStart = double.PositiveInfinity;
            for (int frame = 0; frame < frames; frame++)
            {
                double timeMs = 1000.0 * frame / sampleRate;
                double step = (timeMs - originMs) / stepMs;
                double envelope = 0.0;
                double note = 48.0;
                if (step >= 0.0 && step < hostOffStep)
                {
                    if (double.IsPositiveInfinity(attackStart)) attackStart = originMs;
                    if (!moving)
                    {
                        note = targetNote;
                    }
                    else
                    {
                        int eventIndex = 0;
                        double eventStart = 0.0;
                        double nextEventStart = Math.Floor(phraseLength / 2.0);
                        while (nextEventStart <= step)
                        {
                            eventIndex++;
                            eventStart = nextEventStart;
                            nextEventStart = Math.Floor((eventIndex + 1) * phraseLength / 2.0);
                        }
                        double fromNote = (eventIndex % 2 == 1) ? 48.0 : targetNote;
                        double toNote = (eventIndex % 2 == 1) ? targetNote : 48.0;
                        if (eventIndex == 0) {
                            note = 48.0;
                        } else {
                            double duration = Math.Abs(toNote - fromNote) / 4.0;
                            double progress = instantJump
                                ? 1.0
                                : Math.Max(0.0, Math.Min(1.0, (step - eventStart) / duration));
                            note = fromNote + (toNote - fromNote) * progress;
                        }
                        if (retrigger && eventIndex > 0 && timeMs >= originMs + eventStart * stepMs)
                            attackStart = originMs + eventStart * stepMs;
                    }

                    double age = timeMs - attackStart;
                    envelope = age < 10.0
                        ? Math.Max(0.0, age / 10.0)
                        : age < 30.0
                            ? 1.0 - 0.35 * ((age - 10.0) / 20.0)
                            : 0.65;
                }
                else if (step >= hostOffStep && step < hostOffStep + 5.0 / stepMs)
                {
                    envelope = 0.65 * (1.0 - (step - hostOffStep) * stepMs / 5.0);
                }

                if (timeMs >= gapStartMs && timeMs < gapEndMs) envelope = 0.0;
                double frequency = 262.5 * Math.Pow(2.0,
                    (note - 48.0 + pitchOffsetCents / 100.0) / 12.0);
                phase += frequency / sampleRate;
                phase -= Math.Floor(phase);
                int value = (int)Math.Round(Math.Max(-1.0, Math.Min(1.0,
                    (2.0 * phase - 1.0) * 0.35 * envelope)) * 8388607.0);
                for (int channel = 0; channel < 2; channel++)
                {
                    writer.Write((byte)(value & 255));
                    writer.Write((byte)((value >> 8) & 255));
                    writer.Write((byte)((value >> 16) & 255));
                }
            }
        }
    }
}
'@

$oraclePath = Join-Path $PSScriptRoot 'fixtures/moving_repeat_glide_cases.json'
$oracle = Get-Content -LiteralPath $oraclePath -Raw | ConvertFrom-Json -AsHashtable
$caseById = @{}
foreach ($case in $oracle.cases) { $caseById[$case.id] = $case }
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tempRoot = Join-Path $repositoryRoot 'tmp/acid-moving-glide-tests'
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$runPath = Join-Path $tempRoot "run-$PID"
New-Item -ItemType Directory -Path $runPath | Out-Null

function Test-Protocol(
    [string]$Name,
    [string]$CaseId,
    [bool]$ExpectPass,
    [bool]$InstantJump = $false,
    [bool]$Retrigger = $false,
    [double]$PitchOffsetCents = 0.0,
    [bool]$Gap = $false,
    [double]$GapOffsetStep = 4.25,
    [double]$GapDurationMs = 10.0,
    [bool]$Moving = $true) {

    $case = $caseById[$CaseId]
    $stepMs = 60000.0 / ([double]$case.capture.bpm * 4.0)
    $gapStartMs = -1.0
    $gapEndMs = -1.0
    if ($Gap) {
        $gapStartMs = 1000.0 + $GapOffsetStep * $stepMs
        $gapEndMs = $gapStartMs + $GapDurationMs
    }
    $wavPath = Join-Path $runPath "$Name.wav"
    $targetNote = if ($case.expected.ContainsKey('glide_window')) {
        [int]$case.expected.glide_window.to_note
    } else {
        [int]$case.expected.onsets[0].note
    }
    [AcidMovingGlideSyntheticWave]::Write(
        $wavPath, 48000, 1000.0, $stepMs,
        [int]$case.source.length,
        $targetNote, $Moving, $InstantJump, $Retrigger, $PitchOffsetCents,
        $gapStartMs, $gapEndMs)
    $reportPath = Join-Path $runPath "$Name.json"
    $null = & (Join-Path $PSScriptRoot 'analyze_articulation_audio.ps1') `
        -CaseId $CaseId -OraclePath $oraclePath -WavPath $wavPath -OutputPath $reportPath
    $result = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $passed = $result.status -ceq 'pass'
    if ($passed -ne $ExpectPass) {
        throw "$Name expected pass=$ExpectPass but got $($result.status): $($result.issues -join '; ')"
    }
    Write-Output "$Name`: $($result.status)"
}

Test-Protocol 'four_semitone_glide' 'native_repeat_glide_four_semitones' $true
Test-Protocol 'octave_glide' 'native_repeat_glide_octave' $true
Test-Protocol 'four_semitone_tail_hold' 'writer_repeat_glide_four_semitones_tail_hold' $true
Test-Protocol 'octave_tail_hold' 'writer_repeat_glide_octave_tail_hold' $true
Test-Protocol 'hold_pitch_48' 'native_repeat_hold_pitch_48' $true -Moving $false
Test-Protocol 'hold_pitch_52' 'native_repeat_hold_pitch_52' $true -Moving $false
Test-Protocol 'hold_pitch_60' 'native_repeat_hold_pitch_60' $true -Moving $false
Test-Protocol 'instant_pitch_jump' 'native_repeat_glide_four_semitones' $false -InstantJump $true
Test-Protocol 'restarted_envelope' 'native_repeat_glide_four_semitones' $false -Retrigger $true
Test-Protocol 'continuity_gap' 'native_repeat_glide_four_semitones' $false -Gap $true
Test-Protocol 'wrong_pitch' 'native_repeat_glide_four_semitones' $false -PitchOffsetCents 100.0

foreach ($bpm in @(90, 150)) {
    $suffix = "bpm_$bpm"
    Test-Protocol "four_semitone_glide_$suffix" "native_repeat_glide_four_semitones_$suffix" $true
    Test-Protocol "octave_glide_$suffix" "native_repeat_glide_octave_$suffix" $true
    Test-Protocol "four_semitone_tail_hold_$suffix" "writer_repeat_glide_four_semitones_tail_hold_$suffix" $true
    Test-Protocol "octave_tail_hold_$suffix" "writer_repeat_glide_octave_tail_hold_$suffix" $true
    foreach ($note in @(48, 52, 60)) {
        Test-Protocol "hold_pitch_${note}_$suffix" "native_repeat_hold_pitch_${note}_$suffix" $true -Moving $false
    }
    Test-Protocol "instant_pitch_jump_$suffix" "native_repeat_glide_four_semitones_$suffix" $false -InstantJump $true
    Test-Protocol "restarted_envelope_$suffix" "native_repeat_glide_four_semitones_$suffix" $false -Retrigger $true
    Test-Protocol "continuity_gap_$suffix" "native_repeat_glide_four_semitones_$suffix" $false -Gap $true
    Test-Protocol "wrong_pitch_$suffix" "native_repeat_glide_four_semitones_$suffix" $false -PitchOffsetCents 100.0
    Test-Protocol "same_pitch_repeat_seams_$suffix" "repeat_slide_seam_length_16_bpm_$bpm" $true -Moving $false
    Test-Protocol "same_pitch_repeat_seam_gap_$suffix" "repeat_slide_seam_length_16_bpm_$bpm" $false `
        -Moving $false -Gap $true -GapOffsetStep 15.95 -GapDurationMs 18.0
}
