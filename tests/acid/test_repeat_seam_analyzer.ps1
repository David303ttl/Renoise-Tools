#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
$oracle = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\audio_cases.json') -Raw | ConvertFrom-Json -AsHashtable

Add-Type -TypeDefinition @'
using System;

public static class RepeatSeamSignal
{
    public static double[] Create(
        int sampleRate,
        int frameCount,
        double originMs,
        double retriggerMs,
        double offMs,
        double gapStartMs,
        double gapEndMs,
        double frequency)
    {
        double[] samples = new double[frameCount];
        double phase = 0.0;
        double attackStart = originMs;
        bool retriggered = false;

        for (int frame = 0; frame < samples.Length; frame++)
        {
            double timeMs = 1000.0 * frame / sampleRate;
            if (!retriggered && retriggerMs >= 0.0 && timeMs >= retriggerMs)
            {
                attackStart = retriggerMs;
                retriggered = true;
            }

            double ageMs = timeMs - attackStart;
            double envelope = 0.0;
            if (ageMs >= 0.0)
            {
                if (ageMs < 10.0) envelope = ageMs / 10.0;
                else if (ageMs < 30.0) envelope = 1.0 - 0.35 * (ageMs - 10.0) / 20.0;
                else envelope = 0.65;
            }
            if (timeMs >= offMs)
            {
                envelope = timeMs < offMs + 5.0 ? 0.65 * (1.0 - (timeMs - offMs) / 5.0) : 0.0;
            }
            if (timeMs >= gapStartMs && timeMs < gapEndMs) envelope = 0.0;

            phase += frequency / sampleRate;
            phase -= Math.Floor(phase);
            samples[frame] = (2.0 * phase - 1.0) * 0.35 * envelope;
        }

        return samples;
    }
}
'@

$originMs = 1000.0
$sampleRate = 48000
$stepMs = 60000.0 / (120.0 * 4.0)
$frequency = 262.5
$lengths = @(17, 32, 33, 48, 49, 64)

foreach ($length in $lengths) {
  $caseId = "repeat_slide_seam_length_$length"
  $case = @($oracle.cases | Where-Object { $_.id -ceq $caseId }) | Select-Object -First 1
  if ($null -eq $case) { throw "Missing same-pitch Repeat case '$caseId'" }
  $case = $case | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable
  $case.status = 'ready'

  $offStep = [double]$case.expected.release.off_at_step
  $tailMs = [double]$case.capture.minimum_tail_ms
  $frameCount = [int][Math]::Ceiling(($originMs + $offStep * $stepMs + $tailMs + 100.0) * $sampleRate / 1000.0)
  $seamMs = $originMs + $length * $stepMs
  $seamWindow = $case.expected.continuity_windows[0]
  $gapStartMs = $seamMs + 2.0
  $gapEndMs = $gapStartMs + 18.0

  foreach ($fault in 'none', 'gap', 'retrigger') {
    $retriggerMs = if ($fault -eq 'retrigger') { $seamMs } else { -1.0 }
    $gapStart = if ($fault -eq 'gap') { $gapStartMs } else { -1.0 }
    $gapEnd = if ($fault -eq 'gap') { $gapEndMs } else { -1.0 }
    $samples = [RepeatSeamSignal]::Create(
      $sampleRate, $frameCount, $originMs, $retriggerMs,
      $originMs + $offStep * $stepMs, $gapStart, $gapEnd, $frequency)
    $audio = [pscustomobject]@{
      Left = $samples
      SampleRate = $sampleRate
      Channels = 1
      BitsPerSample = 24
      PeakDbfs = -9.12
      StereoDifferenceDb = $null
      DurationMs = 1000.0 * $samples.Length / $sampleRate
      Sha256 = "synthetic-$caseId-$fault"
    }
    $result = Measure-ArticulationCase $audio $case

    if ($fault -eq 'none') {
      if ($result.Status -ne 'pass') { throw "$caseId positive signal failed: $($result.Issues -join '; ')" }
    } elseif ($result.Status -eq 'pass') {
      throw "$caseId seeded $fault at the first Repeat seam passed"
    }
    if ($fault -eq 'gap' -and @($result.Measurements.continuity_windows | Where-Object { -not $_.passed }).Count -eq 0) {
      throw "$caseId seeded seam gap was not reported by continuity analysis"
    }
    if ($fault -eq 'retrigger' -and @($result.Measurements.no_attack_windows | Where-Object { -not $_.passed }).Count -eq 0) {
      throw "$caseId seeded seam retrigger was not reported by the no-attack analysis"
    }
    Write-Output ("{0} {1}: {2}" -f $caseId, $fault.ToUpperInvariant(), $result.Status.ToUpperInvariant())
  }
}

Write-Output 'Same-pitch Repeat seam analyzer controls passed for six lengths: continuous seam positives, seeded gap negatives and seeded retrigger negatives.'
