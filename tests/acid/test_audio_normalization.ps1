#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scratchRoot = Join-Path $repositoryRoot 'tmp/acid-audio-normalization-tests'
$null = New-Item -ItemType Directory -Path $scratchRoot -Force
$scratch = Join-Path $scratchRoot ([Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
function Write-Control([string]$Path,[double]$Amplitude,[double]$RightScale=1.0) {
  $writer = [IO.BinaryWriter]::new([IO.File]::Create($Path))
  try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int]19236)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
    $writer.Write([int16]1); $writer.Write([int16]2); $writer.Write([int]48000)
    $writer.Write([int]192000); $writer.Write([int16]4); $writer.Write([int16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]19200)
    for ($frame=0; $frame -lt 4800; $frame++) {
      $value = [int16][Math]::Round(32767.0*$Amplitude*[Math]::Sin(2*[Math]::PI*240*$frame/48000))
      $writer.Write($value); $writer.Write([int16][Math]::Round($value*$RightScale))
    }
  } finally { $writer.Dispose() }
}
function Assert-Rejected([scriptblock]$Action,[string]$Message) {
  $rejected=$false
  try { & $Action | Out-Null } catch { $rejected=$true }
  if (-not $rejected) { throw $Message }
}
try {
  $raw=Join-Path $scratch 'source.wav'
  $normalized=Join-Path $scratch 'normalized.wav'
  $repeat=Join-Path $scratch 'repeat.wav'
  $mono=Join-Path $scratch 'mono.wav'
  Write-Control $raw 0.02
  $sourceHash=(Get-FileHash -LiteralPath $raw).Hash
  $receipt = & (Join-Path $PSScriptRoot 'normalize_articulation_audio.ps1') -WavPath $raw -OutputPath $normalized | ConvertFrom-Json
  $inputAudio=Read-ArticulationWav $raw
  $outputAudio=Read-ArticulationWav $normalized
  if ($outputAudio.Channels -ne 2 -or $outputAudio.FrameCount -ne 4800 -or $outputAudio.SampleRate -ne 48000 -or $outputAudio.BitsPerSample -ne 24) { throw 'Normalization changed layout or rate' }
  if ([Math]::Abs($outputAudio.PeakDbfs + 6.1) -gt 0.00001) { throw 'Normalized peak differs from target' }
  for ($frame=0; $frame -lt 4800; $frame++) {
    if ([Math]::Abs($outputAudio.Left[$frame]-$inputAudio.Left[$frame]*$receipt.gain_linear) -gt 0.5/8388608.0) { throw 'Normalization changed waveform beyond PCM24 rounding' }
    if ($outputAudio.Left[$frame] -ne $outputAudio.Right[$frame]) { throw 'Equal stereo channels changed independently' }
  }
  $frequency=Get-FundamentalHz $outputAudio.Left 48000 0 100
  if ([Math]::Abs($frequency-240) -gt 0.01) { throw 'Normalization changed frequency' }
  if ((Get-FileHash -LiteralPath $raw).Hash -ne $sourceHash) { throw 'Normalization modified source' }
  $null = & (Join-Path $PSScriptRoot 'normalize_articulation_audio.ps1') -WavPath $raw -OutputPath $repeat -GainDb $receipt.gain_db
  if ((Get-FileHash -LiteralPath $repeat).Hash -ne (Get-FileHash -LiteralPath $normalized).Hash) { throw 'Fixed-gain output is not deterministic' }
  $null = & (Join-Path $PSScriptRoot 'normalize_articulation_audio.ps1') -WavPath $raw -OutputPath $mono -GainDb $receipt.gain_db -Mono
  $monoAudio=Read-ArticulationWav $mono
  if ($monoAudio.Channels -ne 1 -or $monoAudio.Left[100] -ne $outputAudio.Left[100]) { throw 'Explicit mono average changed equal-channel signal' }
  Assert-Rejected { & (Join-Path $PSScriptRoot 'normalize_articulation_audio.ps1') -WavPath $raw -OutputPath $normalized } 'Output overwrite was accepted'
  Assert-Rejected { & (Join-Path $PSScriptRoot 'normalize_articulation_audio.ps1') -WavPath $raw -OutputPath (Join-Path $scratch 'too_loud.wav') -GainDb 60 } 'Excessive fixed gain was accepted'
  $mismatch=Join-Path $scratch 'mismatch.wav'; Write-Control $mismatch 0.02 0.5
  Assert-Rejected { & (Join-Path $PSScriptRoot 'normalize_articulation_audio.ps1') -WavPath $mismatch -OutputPath (Join-Path $scratch 'hidden.wav') -Mono } 'Contaminated stereo was averaged'
  $clipped=Join-Path $scratch 'clipped.wav'; Write-Control $clipped 1.0
  Assert-Rejected { & (Join-Path $PSScriptRoot 'normalize_articulation_audio.ps1') -WavPath $clipped -OutputPath (Join-Path $scratch 'repaired.wav') } 'Clipped source was accepted'
  Write-Output 'Audio normalization controls: PASS (waveform, pitch, source/hash preservation, deterministic fixed gain, mono, overwrite, headroom, contamination and clipping)'
} finally {
  $resolved=[IO.Path]::GetFullPath($scratch)
  if (-not $resolved.StartsWith([IO.Path]::GetFullPath($scratchRoot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Scratch cleanup escaped intended directory' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
