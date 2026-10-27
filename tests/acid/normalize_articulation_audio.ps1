#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$WavPath,
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [string]$ProvenancePath,
  [double]$TargetPeakDbfs = -6.1,
  [double]$GainDb,
  [switch]$Mono
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
if (-not $ProvenancePath) { $ProvenancePath = "$OutputPath.normalization.json" }
if ($TargetPeakDbfs -gt -6.0 -or $TargetPeakDbfs -lt -60 -or [double]::IsNaN($TargetPeakDbfs)) { throw 'Target peak must be between -60 and -6 dBFS' }
$sourcePath = (Resolve-Path -LiteralPath $WavPath).Path
$destination = [IO.Path]::GetFullPath($OutputPath)
$provenanceDestination = [IO.Path]::GetFullPath($ProvenancePath)
if ($destination -eq $sourcePath -or $provenanceDestination -eq $sourcePath -or $destination -eq $provenanceDestination) { throw 'Source, normalized WAV and provenance must be distinct files' }
foreach ($path in $destination,$provenanceDestination) {
  if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite '$path'" }
  $parent = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output directory does not exist: '$parent'" }
}
$audio = Read-ArticulationWav $sourcePath
if ($Mono -and $audio.Channels -eq 2 -and $audio.StereoDifferenceDb -gt -40.0) { throw 'Stereo mismatch exceeds -40 dB; refusing mono conversion that could hide contamination' }
$peak = 0.0
$clippingLimit = if ($audio.FormatCode -eq 1) { 1.0 - 1.0 / [Math]::Pow(2.0,$audio.BitsPerSample - 1) } else { 1.0 }
foreach ($channel in @($audio.Left,$audio.Right)) {
  if ($null -eq $channel) { continue }
  foreach ($sample in $channel) {
    $magnitude = [Math]::Abs($sample)
    if ($magnitude -ge $clippingLimit) { throw 'Source reaches digital full scale; clipped captures cannot be repaired by normalization' }
    $peak = [Math]::Max($peak,$magnitude)
  }
}
if ($peak -le 0) { throw 'Cannot normalize digital silence' }
$gain = [Math]::Pow(10.0,$TargetPeakDbfs / 20.0) / $peak
if ($PSBoundParameters.ContainsKey('GainDb')) {
  if ([double]::IsNaN($GainDb) -or [double]::IsInfinity($GainDb)) { throw 'Gain must be finite' }
  $gain = [Math]::Pow(10.0,$GainDb / 20.0)
  if ($peak * $gain -gt [Math]::Pow(10.0,-6.0 / 20.0)) { throw 'Requested fixed gain exceeds the -6 dBFS output ceiling' }
}
if ($gain -le 0 -or [double]::IsInfinity($gain) -or $peak * $gain -lt 1.0 / 8388608.0) { throw 'Requested gain cannot produce finite nonzero PCM24 audio' }
$left = $audio.Left
$right = $audio.Right
if ($Mono -and $audio.Channels -eq 2) {
  $left = [double[]]::new($audio.FrameCount)
  for ($frame = 0; $frame -lt $audio.FrameCount; $frame++) { $left[$frame] = ($audio.Left[$frame] + $audio.Right[$frame]) / 2.0 }
  $right = $null
}
if (-not ('AcidPcm24Normalizer' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class AcidPcm24Normalizer {
  public static double Write(string path, double[] left, double[] right, int rate, double gain) {
    int channels = right == null ? 1 : 2;
    int bytes = checked(left.Length * channels * 3);
    double peak = 0;
    using (var writer = new BinaryWriter(new FileStream(path, FileMode.CreateNew))) {
      writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + bytes);
      writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
      writer.Write((short)1); writer.Write((short)channels); writer.Write(rate);
      writer.Write(rate * channels * 3); writer.Write((short)(channels * 3)); writer.Write((short)24);
      writer.Write(System.Text.Encoding.ASCII.GetBytes("data")); writer.Write(bytes);
      for (int frame = 0; frame < left.Length; frame++) {
        for (int channel = 0; channel < channels; channel++) {
          double sample = (channel == 0 ? left[frame] : right[frame]) * gain;
          int value = checked((int)Math.Round(sample * 8388608.0, MidpointRounding.ToEven));
          if (value < -8388608 || value > 8388607) throw new InvalidOperationException("Normalized sample exceeds PCM24 range");
          writer.Write((byte)(value & 255)); writer.Write((byte)((value >> 8) & 255)); writer.Write((byte)((value >> 16) & 255));
          peak = Math.Max(peak, Math.Abs(value / 8388608.0));
        }
      }
    }
    return peak;
  }
}
'@
}
$outputPeak = [AcidPcm24Normalizer]::Write($destination,$left,$right,$audio.SampleRate,$gain)
$metadataDirectory = Split-Path -Parent $provenanceDestination
$provenance = [ordered]@{
  format='ACID-AUDIO-NORMALIZATION-1'
  operation='one common linear gain; no resampling, limiting or trimming'
  channel_conversion=if ($Mono -and $audio.Channels -eq 2) {'arithmetic mean of L/R'} else {'preserve channels'}
  source=@{ path=[IO.Path]::GetRelativePath($metadataDirectory,$sourcePath).Replace('\','/'); sha256=$audio.Sha256; peak_dbfs=$audio.PeakDbfs; bits_per_sample=$audio.BitsPerSample; channels=$audio.Channels; stereo_difference_db=$audio.StereoDifferenceDb }
  output=@{ path=[IO.Path]::GetRelativePath($metadataDirectory,$destination).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant(); peak_dbfs=20.0*[Math]::Log10($outputPeak); bits_per_sample=24; channels=if ($null -eq $right) {1} else {2} }
  sample_rate=$audio.SampleRate; frames=$audio.FrameCount
  gain_policy=if ($PSBoundParameters.ContainsKey('GainDb')) {'explicit fixed gain'} else {'per-file peak'}
  gain_linear=$gain; gain_db=20.0*[Math]::Log10($gain); target_peak_dbfs=$TargetPeakDbfs
}
$json = ConvertTo-Json -InputObject $provenance -Depth 10
$stream = [IO.File]::Open($provenanceDestination,[IO.FileMode]::CreateNew)
try { $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false)); $writer.WriteLine($json); $writer.Flush() } finally { $stream.Dispose() }
Write-Output $json
