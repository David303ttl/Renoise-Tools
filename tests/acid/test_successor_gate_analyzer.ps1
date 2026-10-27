#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
$oracle = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\audio_cases.json') -Raw | ConvertFrom-Json -AsHashtable

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;

public sealed class GateVoice
{
    public double StartMs;
    public double OffMs;
    public double Frequency;
    public double Scale;
    public double PhaseOffset;
}

public static class SuccessorGateSignal
{
    public static double[] Create(int sampleRate, int frameCount, double originMs, List<GateVoice> voices)
    {
        double[] samples = new double[frameCount];
        for (int frame = 0; frame < samples.Length; frame++)
        {
            double timeMs = 1000.0 * frame / sampleRate;
            double value = 0.0;
            foreach (GateVoice voice in voices)
            {
                double ageMs = timeMs - (originMs + voice.StartMs);
                if (ageMs < 0.0) continue;
                double offAgeMs = timeMs - (originMs + voice.OffMs);
                double envelope;
                if (offAgeMs >= 5.0) continue;
                if (offAgeMs >= 0.0) envelope = 0.65 * (1.0 - offAgeMs / 5.0);
                else if (ageMs < 10.0) envelope = ageMs / 10.0;
                else if (ageMs < 30.0) envelope = 1.0 - 0.35 * (ageMs - 10.0) / 20.0;
                else envelope = 0.65;
                double phase = voice.Frequency * ageMs / 1000.0 + voice.PhaseOffset;
                phase -= Math.Floor(phase);
                value += (2.0 * phase - 1.0) * 0.35 * envelope * voice.Scale;
            }
            samples[frame] = value;
        }
        return samples;
    }
}
'@

function New-GateAudio($Case, [string]$Fault) {
  $sampleRate = 48000
  $stepMs = 60000.0 / ([double]$Case.capture.bpm * 4.0)
  $originMs = 1000.0
  $voices = [System.Collections.Generic.List[GateVoice]]::new()
  $faultAtMs = $null
  $onsets = @($Case.expected.onsets)
  $edges = @($Case.expected.release_edges)
  if ($onsets.Count -ne $edges.Count) { throw "$($Case.id) needs one release edge per fresh NOTE" }
  for ($index = 0; $index -lt $onsets.Count; $index++) {
    $start = [double]$onsets[$index].at_step
    $off = [double]$edges[$index].off_at_step
    if ($Fault -eq 'delayed-off') { $off += 0.25 }
    $note = [double]$onsets[$index].note
    $frequency = [double]$Case.profile.base_frequency_hz * [Math]::Pow(2.0, ($note - [double]$Case.profile.root_note) / 12.0)
    $voices.Add([GateVoice]@{ StartMs=$start * $stepMs; OffMs=$off * $stepMs; Frequency=$frequency; Scale=1.0; PhaseOffset=0.0 })
  }
  if ($Fault -eq 'extra-attack') {
    $tieIndex = [array]::IndexOf([object[]]$Case.source.time, 'T')
    $restIndex = [array]::IndexOf([object[]]$Case.source.time, 'R')
    $faultStep = if ($tieIndex -ge 0) { $tieIndex + 0.5 } elseif ($restIndex -ge 0) { $restIndex + 0.25 } else { 0.5 }
    $faultAtMs = $faultStep * $stepMs
    $note = [double]$onsets[0].note
    $frequency = [double]$Case.profile.base_frequency_hz * [Math]::Pow(2.0, ($note - [double]$Case.profile.root_note) / 12.0)
    $voices.Add([GateVoice]@{ StartMs=$faultStep * $stepMs; OffMs=($faultStep + 0.35) * $stepMs; Frequency=$frequency; Scale=1.5; PhaseOffset=0.25 })
  }
  $lastEndStep = [double](($Case.expected.silence_windows | Measure-Object end_step -Maximum).Maximum)
  $frameCount = [int][Math]::Ceiling(($originMs + ($lastEndStep + 0.2) * $stepMs) * $sampleRate / 1000.0)
  $samples = [SuccessorGateSignal]::Create($sampleRate, $frameCount, $originMs, $voices)
  if ($null -ne $faultAtMs) {
    $firstMuted = [Math]::Max(0, [int][Math]::Floor(($originMs + $faultAtMs - 24.0) * $sampleRate / 1000.0))
    $lastMuted = [Math]::Min($samples.Length, [int][Math]::Floor(($originMs + $faultAtMs) * $sampleRate / 1000.0))
    for ($frame = $firstMuted; $frame -lt $lastMuted; $frame++) { $samples[$frame] = 0.0 }
  }
  return [pscustomobject]@{
    Left=$samples; SampleRate=$sampleRate; Channels=1; BitsPerSample=24
    PeakDbfs=-9.0; StereoDifferenceDb=$null
    DurationMs=1000.0 * $samples.Length / $sampleRate
    Sha256="synthetic-$($Case.id)-$Fault"
  }
}

$definitions = @(
  @{ prefix='tie_before_fresh_note'; faults=@('delayed-off','extra-attack') },
  @{ prefix='two_ties_before_fresh_note'; faults=@('delayed-off','extra-attack') },
  @{ prefix='repeat_note_rest_seam'; faults=@('delayed-off','extra-attack') },
  @{ prefix='repeat_tie_rest_seam'; faults=@('delayed-off','extra-attack') }
)
$tested = 0
foreach ($definition in $definitions) {
  foreach ($bpm in @(90,120,150)) {
    $id = "$($definition.prefix)_bpm_$bpm"
    $case = $oracle.cases | Where-Object id -ceq $id | Select-Object -First 1
    if ($null -eq $case) { throw "Missing gate protocol '$id'" }
    if ($case.status -cne 'ready' -or $case.qualification.protocol_status -cne 'ready' -or $case.qualification.acoustic_status -cne 'unverified') {
      throw "$id must be analyzer ready while acoustic status remains unverified"
    }
    $positive = Measure-ArticulationCase (New-GateAudio $case 'none') $case
    if ($positive.Status -cne 'pass') { throw "$id positive failed: $($positive.Issues -join '; ')" }
    foreach ($fault in $definition.faults) {
      $result = Measure-ArticulationCase (New-GateAudio $case $fault) $case
      if ($result.Status -ceq 'pass') { throw "$id seeded $fault fault passed" }
      if ($fault -ceq 'delayed-off' -and @($result.Measurements.release_edges | Where-Object { -not $_.passed }).Count -eq 0) {
        throw "$id delayed OFF was not reported by release analysis"
      }
      if ($fault -ceq 'extra-attack' -and @($result.Measurements.no_attack_windows | Where-Object { -not $_.passed }).Count -eq 0 -and
          @($result.Measurements.silence_windows | Where-Object { -not $_.passed }).Count -eq 0 -and
          @($result.Measurements.unexpected_onsets_ms).Count -eq 0) {
        throw "$id extra attack was not reported by attack/silence analysis"
      }
    }
    $tested++
    Write-Output "$id positive PASS; delayed OFF and extra attack NEGATIVE"
  }
}
Write-Output "Successor gate analyzer controls passed for $tested protocols; synthetic results do not establish Renoise playback."
