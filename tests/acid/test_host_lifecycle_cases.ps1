#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
$fixturePath = Join-Path $PSScriptRoot 'fixtures\host_lifecycle_cases.json'
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable
$runId = [guid]::NewGuid().ToString('N')
$outputRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "tmp/acid-articulation/host-lifecycle/synthetic/$runId"
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class HostLifecycleWave
{
    public static void Write(
        string path,
        int sampleRate,
        int frames,
        double originMs,
        double stepMs,
        double[] onsetSteps,
        int[] onsetNotes,
        double offStep,
        string fault)
    {
        const int bits = 24;
        const int bytesPerSample = bits / 8;
        int dataBytes = frames * bytesPerSample;
        double offMs = originMs + offStep * stepMs;
        if (fault == "delayed-off") offMs += 15.0;

        using (FileStream stream = File.Create(path))
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
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
            int note = 48;
            double attackStart = double.NegativeInfinity;
            double phase = 0.0;
            for (int frame = 0; frame < frames; frame++)
            {
                double timeMs = 1000.0 * frame / sampleRate;
                while (eventIndex + 1 < onsetSteps.Length &&
                    timeMs >= originMs + onsetSteps[eventIndex + 1] * stepMs)
                {
                    eventIndex++;
                    if (fault == "missing-retrigger" && eventIndex > 0) continue;
                    note = onsetNotes[eventIndex];
                    if (fault == "wrong-pitch" && eventIndex == onsetSteps.Length - 1) note += 2;
                    attackStart = originMs + onsetSteps[eventIndex] * stepMs;
                }

                double envelope = 0.0;
                double ageMs = timeMs - attackStart;
                if (eventIndex >= 0 && ageMs >= 0.0 && timeMs < offMs)
                {
                    if (ageMs < 10.0) envelope = ageMs / 10.0;
                    else if (ageMs < 30.0) envelope = 1.0 - 0.35 * (ageMs - 10.0) / 20.0;
                    else envelope = 0.65;
                }
                else if (timeMs >= offMs && timeMs < offMs + 5.0)
                {
                    envelope = 0.65 * (1.0 - (timeMs - offMs) / 5.0);
                }

                double frequency = 262.5 * Math.Pow(2.0, (note - 48) / 12.0);
                phase += frequency / sampleRate;
                phase -= Math.Floor(phase);
                double sample = (2.0 * phase - 1.0) * 0.35 * envelope;
                int quantized = (int)Math.Round(Math.Max(-1.0, Math.Min(1.0, sample)) * 8388607.0);
                writer.Write((byte)(quantized & 0xff));
                writer.Write((byte)((quantized >> 8) & 0xff));
                writer.Write((byte)((quantized >> 16) & 0xff));
            }
        }
    }
}
'@

function Invoke-Analyzer {
  param([string]$WavPath, [string]$CaseId, [string]$ResultPath)
  $pwshPath = (Get-Command pwsh).Source
  $analyzer = Join-Path $PSScriptRoot 'analyze_articulation_audio.ps1'
  $output = & $pwshPath -NoProfile -File $analyzer -WavPath $WavPath -CaseId $CaseId `
    -OraclePath $fixturePath -OutputPath $ResultPath -Json 2>&1
  $exitCode = $LASTEXITCODE
  if (-not (Test-Path -LiteralPath $ResultPath)) {
    throw "Analyzer did not write a result for $CaseId (exit $exitCode): $($output -join ' ')"
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json -AsHashtable
  }
}

$sampleRate = 48000
$originMs = 1000.0
$stepMs = 60000.0 / (120.0 * 4.0)
$passed = 0
foreach ($case in $fixture.cases) {
  if ($case.status -cne 'ready' -or $case.qualification.protocol_status -cne 'ready' -or
      $case.qualification.acoustic_status -cne 'unverified' -or
      [double]$case.capture.minimum_tail_ms -lt 500.0) {
    throw "$($case.id) must be analyzer-ready with at least 500 ms of tail and unverified acoustic status"
  }
  $onsets = @($case.expected.onsets)
  $pitchWindows = @($case.expected.pitch_windows)
  if ($onsets.Count -ne $pitchWindows.Count -or $onsets.Count -eq 0) {
    throw "$($case.id) needs one settled pitch window for every authored attack"
  }
  for ($index = 0; $index -lt $onsets.Count; $index++) {
    if ([double]$onsets[$index].at_step -ne [double]$case.protocol.host_events[$index].at_step -or
        [int]$pitchWindows[$index].note -ne 48 -or
        [int]$case.protocol.host_events[$index].pattern_line -ne (1 + 2 * [int]$case.protocol.silent_preroll_steps + 2 * [int]$onsets[$index].at_step)) {
      throw "$($case.id) has an attack/pitch expectation that differs from its independent host-event record"
    }
  }
  $edge = $case.expected.release_edges | Select-Object -Last 1
  if ([double]$edge.off_at_step -ne [double]$case.protocol.final_host_off_step -or
      [double]$edge.maximum_tail_ms -gt 10.0 -or
      [double]$case.expected.silence_windows[0].start_step -lt [double]$edge.off_at_step -or
      [int]($case.protocol.host_events | Where-Object event -eq 'OFF' | Select-Object -Last 1).pattern_line -ne
        (1 + 2 * [int]$case.protocol.silent_preroll_steps + 2 * [int]$case.protocol.final_host_off_step)) {
    throw "$($case.id) must test final host OFF, a <=10 ms release, and a later silence window"
  }

  $lastExpectedStep = [double](($case.expected.silence_windows | Measure-Object end_step -Maximum).Maximum)
  $normalFrames = [int][Math]::Ceiling(($originMs + $lastExpectedStep * $stepMs + 500.0 + 100.0) * $sampleRate / 1000.0)
  $eventSteps = [double[]]@($onsets | ForEach-Object { [double]$_.at_step })
  $eventNotes = [int[]]@($onsets | ForEach-Object { [int]$_.note })

  foreach ($fault in @('none', 'delayed-off', 'wrong-pitch') + $(if ($case.id -eq 'fresh_retrigger_native') { @('missing-retrigger') } else { @() })) {
    $frames = $normalFrames
    if ($fault -eq 'short-tail') {
      $frames = [int][Math]::Ceiling(($originMs + [double]$edge.off_at_step * $stepMs + 300.0) * $sampleRate / 1000.0)
    }
    $wav = Join-Path $outputRoot ("{0}-{1}.wav" -f $case.id,$fault)
    $resultPath = Join-Path $outputRoot ("{0}-{1}.result.json" -f $case.id,$fault)
    [HostLifecycleWave]::Write($wav,$sampleRate,$frames,$originMs,$stepMs,$eventSteps,$eventNotes,
      [double]$edge.off_at_step,$fault)
    $analysis = Invoke-Analyzer -WavPath $wav -CaseId $case.id -ResultPath $resultPath
    if ($fault -eq 'none') {
      if ($analysis.ExitCode -ne 0 -or $analysis.Result.status -cne 'pass') {
        throw "$($case.id) synthetic positive failed: $($analysis.Result.issues -join '; ')"
      }
      $passed++
      continue
    }
    if ($analysis.ExitCode -eq 0 -or $analysis.Result.status -ceq 'pass') {
      throw "$($case.id) seeded $fault fault passed"
    }
    if ($fault -eq 'delayed-off' -and
        @($analysis.Result.measurements.release_edges | Where-Object { $_.passed }).Count -gt 0) {
      throw "$($case.id) delayed host OFF was not caught by the release deadline"
    }
  }

  $shortWav = Join-Path $outputRoot ("{0}-short-tail.wav" -f $case.id)
  $shortResultPath = Join-Path $outputRoot ("{0}-short-tail.result.json" -f $case.id)
  $shortFrames = [int][Math]::Ceiling(($originMs + [double]$edge.off_at_step * $stepMs + 300.0) * $sampleRate / 1000.0)
  [HostLifecycleWave]::Write($shortWav,$sampleRate,$shortFrames,$originMs,$stepMs,$eventSteps,$eventNotes,
    [double]$edge.off_at_step,'none')
  $short = Invoke-Analyzer -WavPath $shortWav -CaseId $case.id -ResultPath $shortResultPath
  if ($short.ExitCode -ne 2 -or $short.Result.status -cne 'invalid' -or
      (@($short.Result.issues | Where-Object { $_ -match 'needs .* tail' }).Count -eq 0)) {
    throw "$($case.id) capture shorter than the 500 ms tail was not rejected"
  }
}

Write-Output "Native host lifecycle fixture synthetic controls passed for $passed protocols; delayed OFF, pitch error, retrigger omission, and short tails were rejected. No result establishes acoustic acceptance."
