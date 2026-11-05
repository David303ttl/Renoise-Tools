#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scratchRoot = Join-Path $repositoryRoot 'tmp/acid-audio-capture-tests'
$null = New-Item -ItemType Directory -Path $scratchRoot -Force
$scratch = Join-Path $scratchRoot ([Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch

function Write-ControlWav([string]$Path) {
  $sampleRate = 48000
  $frameCount = 4800
  $channels = 2
  $blockAlign = $channels * 2
  $dataBytes = $frameCount * $blockAlign
  $riffBytes = 4 + 8 + 16 + 8 + $dataBytes
  $writer = [IO.BinaryWriter]::new([IO.File]::Create($Path))
  try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
    $writer.Write([int]$riffBytes)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $writer.Write([int]16)
    $writer.Write([int16]1)
    $writer.Write([int16]$channels)
    $writer.Write([int]$sampleRate)
    $writer.Write([int]($sampleRate * $blockAlign))
    $writer.Write([int16]$blockAlign)
    $writer.Write([int16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
    $writer.Write([int]$dataBytes)
    for ($frame = 0; $frame -lt $frameCount; $frame++) {
      $phase = 2.0 * [Math]::PI * 240.0 * $frame / $sampleRate
      $writer.Write([int16][Math]::Round(32767.0 * 0.25 * [Math]::Sin($phase)))
      $writer.Write([int16][Math]::Round(32767.0 * 0.125 * [Math]::Sin($phase)))
    }
  } finally { $writer.Dispose() }
}

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
  $rejected = $false
  try { & $Action | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw $Message }
}

try {
  $path = Join-Path $scratch 'capture.wav'
  Write-ControlWav $path
  $audio = Read-ArticulationWav $path
  if ($audio.SampleRate -ne 48000 -or $audio.Channels -ne 2 -or $audio.FrameCount -ne 4800) {
    throw 'Capture layout was read incorrectly'
  }
  if ([Math]::Abs($audio.DurationMs - 100.0) -gt 0.000001) { throw 'Capture duration was read incorrectly' }
  if ($audio.Left.Length -ne $audio.FrameCount -or $audio.Right.Length -ne $audio.FrameCount) {
    throw 'Capture channel samples are incomplete'
  }
  if ($audio.Left[50] -eq $audio.Right[50]) { throw 'Stereo channel samples were not kept separate' }
  if ($audio.Sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Capture SHA-256 is missing or malformed' }

  $expectedLeft = 0.25 / [Math]::Sqrt(2.0)
  $expectedRight = 0.125 / [Math]::Sqrt(2.0)
  $leftRms = Get-SampleRms $audio.Left $audio.SampleRate 0 $audio.DurationMs
  $rightRms = Get-SampleRms $audio.Right $audio.SampleRate 0 $audio.DurationMs
  if ([Math]::Abs($leftRms - $expectedLeft) -gt 0.0001) { throw "Left-channel RMS is inaccurate: $leftRms" }
  if ([Math]::Abs($rightRms - $expectedRight) -gt 0.0001) { throw "Right-channel RMS is inaccurate: $rightRms" }

  $badPath = Join-Path $scratch 'bad-header.wav'
  $badBytes = [IO.File]::ReadAllBytes($path)
  [BitConverter]::GetBytes([uint32]4).CopyTo($badBytes, 4)
  [IO.File]::WriteAllBytes($badPath, $badBytes)
  Assert-Rejected { Read-ArticulationWav $badPath } 'Malformed RIFF size was accepted'
  Write-Output 'Audio capture controls passed: PCM WAV layout, stereo samples, SHA-256, RMS and malformed RIFF rejection.'
} finally {
  $resolved = [IO.Path]::GetFullPath($scratch)
  $prefix = [IO.Path]::GetFullPath($scratchRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch cleanup escaped the audio capture test directory'
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
