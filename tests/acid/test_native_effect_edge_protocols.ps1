#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'fixtures/native_effect_edge_cases.json'
$oracle = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
if ($oracle.format -cne 'ACID-AUDIO-ORACLE-1') { throw 'Unsupported edge protocol format' }
if ($oracle.cases.Count -ne 10) { throw "Expected ten native and writer edge protocols; found $($oracle.cases.Count)" }
$ids = @($oracle.cases | ForEach-Object id)
if (@($ids | Select-Object -Unique).Count -ne 10) { throw 'Protocol IDs must be unique' }

function Test-SyntheticTrajectory([double[]]$Progress, [double]$MinimumDelta = 0.08) {
  return $Progress.Count -eq 3 -and
    $Progress[0] -lt $Progress[1] -and $Progress[1] -lt $Progress[2] -and
    ($Progress[2] - $Progress[0]) -ge $MinimumDelta -and
    $Progress[1] -ge 0.05 -and $Progress[1] -le 0.95
}

foreach ($bpm in 90,150) {
  foreach ($rate in 8,32,64) {
    $id = "native_0g$('{0:X2}' -f $rate)_bpm_$bpm"
    $case = @($oracle.cases | Where-Object id -CEQ $id) | Select-Object -First 1
    if (!$case -or $case.status -cne 'ready') { throw "Missing ready protocol '$id'" }
    $commandLines = [Math]::Ceiling(4.0 * 16.0 / $rate)
    $duration = $commandLines / 2.0
    if ([int]$case.source.command_lines_to_target -ne $commandLines) { throw "Command-line coverage differs for '$id'" }
    if ([Math]::Abs([double]$case.expected.glide_window.end_step - [double]$case.expected.glide_window.start_step - $duration) -gt 0.00001) {
      throw "Duration prediction differs for '$id'"
    }
    $sampleTimes = @(0.10,0.26,0.42)
    $positive = @($sampleTimes | ForEach-Object { [Math]::Min(1.0, $_ / $duration) })
    if (-not (Test-SyntheticTrajectory $positive ([double]$case.expected.glide_window.minimum_progress_delta))) { throw "Synthetic continuous sweep should qualify '$id'" }
    if (Test-SyntheticTrajectory @(1.0,1.0,1.0)) { throw "Instantaneous jump must fail '$id'" }
    if (Test-SyntheticTrajectory @(0.0,0.0,0.0)) { throw "No-motion trace must fail '$id'" }
    if (Test-SyntheticTrajectory @(0.5,0.3,0.1)) { throw "Reverse-polarity trace must fail '$id'" }
  }
}

$rest = @($oracle.cases | Where-Object id -CEQ 'native_0g08_rest_cancels_glide') | Select-Object -First 1
$fresh = @($oracle.cases | Where-Object id -CEQ 'native_0g08_fresh_note_after_glide') | Select-Object -First 1
 $gated = @($oracle.cases | Where-Object id -CEQ 'native_0g08_gated_fresh_note_after_glide') | Select-Object -First 1
$writer = @($oracle.cases | Where-Object id -CEQ 'writer_0g20_rest_gated_fresh_note') | Select-Object -First 1
if (!$rest -or !$fresh -or !$gated -or !$writer) { throw 'REST cancellation, gated fresh-NOTE, and actual-writer controls are required' }
if (@($rest.expected.silence_windows).Count -ne 1 -or @($rest.expected.onsets).Count -ne 1) { throw 'REST cancellation must require post-REST silence without a later NOTE' }
if (@($fresh.expected.onsets).Count -ne 2 -or [double]$fresh.expected.onsets[1].at_step -ne 6) { throw 'Post-glide NOTE must require a fresh attack at step 6' }
if (@($gated.expected.onsets).Count -ne 2 -or [double]$gated.source.note_off_step -ne 5.5) { throw 'Gated native control must release before the fresh NOTE' }
if ($writer.playback.renderer -cne 'acid-writer' -or $writer.playback.looping -or
    ($writer.source.time -join ',') -cne 'N,T,N,T,N,T,R' -or
    ($writer.source.pitches -join ',') -cne '48,52,48' -or
    ($writer.source.slide_pitch_indices -join ',') -cne '1') { throw 'Actual writer source differs from the gated fresh-NOTE protocol' }

Write-Output 'PASS: six BPM/rate protocols, partial REST cancellation, ungated and gated fresh-NOTE controls, actual-writer source, and instantaneous/no-motion/reverse synthetic negatives.'
Write-Output 'Synthetic tests validate authored trajectory discrimination only; they do not simulate Renoise playback.'
