#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$oraclePath = Join-Path $PSScriptRoot 'fixtures/audio_cases.json'
$validator = Join-Path $PSScriptRoot 'validate_audio_oracle.ps1'
$original = Get-Content -LiteralPath $oraclePath -Raw
$temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ('acid-oracle-' + [guid]::NewGuid().ToString('N') + '.json')
$mutations = @(
  @{ name = 'missing qualification'; change = { param($o) ($o.cases | Where-Object id -eq 'up_slide').Remove('qualification') }; error = 'explicit qualification blockers' },
  @{ name = 'silence across attack'; change = { param($o) $o.cases[0].expected.silence_windows[0].start_step = 0 }; error = 'silence window overlaps expected onset' },
  @{ name = 'invalid TIME'; change = { param($o) $o.cases[0].source.time[0] = 'X' }; error = 'invalid TIME command' },
  @{ name = 'profile mismatch'; change = { param($o) $o.cases[0].profile.id = 'wrong' }; error = 'reference profile mismatch' },
  @{ name = 'missing window coordinate'; change = { param($o) $o.cases[0].expected.pitch_windows[0].Remove('start_step') }; error = 'finite nonnegative number' },
  @{ name = 'unknown control'; change = { param($o) $o.cases[0].controls[0].id = 'missing-control' }; error = 'unresolved control reference' },
  @{ name = 'unknown semantic fixture'; change = { param($o) $o.cases[0].source.reference_fixture = 'tests/acid/fixtures/loop_cases.json#missing-id' }; error = 'Semantic fixture ID does not exist' }
)
try {
  & $validator -Path $oraclePath
  $authored = $original | ConvertFrom-Json -AsHashtable
  $gateCases = @(
    @{ name='one_shot_note_tail'; on=@(0); off=@(0.5) },
    @{ name='one_shot_tie_tail'; on=@(0); off=@(1.5) },
    @{ name='one_shot_two_ties_tail'; on=@(0); off=@(2.5) },
    @{ name='tie_before_fresh_note'; on=@(0,2); off=@(1.5,2.5) },
    @{ name='two_ties_before_fresh_note'; on=@(0,3); off=@(2.5,3.5) },
    @{ name='repeat_note_rest_seam'; on=@(0,2,4,6); off=@(1,3,5,7) },
    @{ name='repeat_tie_rest_seam'; on=@(0,3,6,9); off=@(2,5,8,11) }
  )
  foreach ($definition in $gateCases) {
    foreach ($bpm in @(90,120,150)) {
      $id = "$($definition.name)_bpm_$bpm"
      $case = $authored.cases | Where-Object id -eq $id
      if ($null -eq $case -or $case.capture.bpm -ne $bpm -or
          $case.status -cne 'planned' -or $case.qualification.protocol_status -cne 'authored' -or
          @($case.expected.onsets).Count -ne $definition.on.Count -or
          @($case.expected.release_edges).Count -ne $definition.off.Count) {
        throw "$id must retain independently authored attacks, successor OFF edges and unverified status"
      }
      for ($index = 0; $index -lt $definition.on.Count; $index++) {
        if ([double]$case.expected.onsets[$index].at_step -ne [double]$definition.on[$index]) {
          throw "$id has an incorrect authored attack"
        }
      }
      for ($index = 0; $index -lt $definition.off.Count; $index++) {
        if ([double]$case.expected.release_edges[$index].off_at_step -ne [double]$definition.off[$index]) {
          throw "$id has an incorrect authored successor OFF"
        }
      }
      foreach ($edge in $case.expected.release_edges) {
        $tailMs = ($edge.silence_starts_at_step - $edge.off_at_step) * 60000 / ($bpm * 4)
        if ([Math]::Abs($tailMs - 10) -gt 0.000001) {
          throw "$id must preserve its 10 ms acoustic release deadline across tempos"
        }
      }
      if ($definition.name -like 'repeat_*' -and
          (-not $case.playback.looping -or $case.playback.cold_cycles -ne 1 -or
           $case.playback.steady_cycles -ne 3)) {
        throw "$id must measure cold-to-steady and steady-to-steady seams"
      }
    }
  }
  foreach ($id in @('isolated_note', 'note_tie', 'note_tie_tie', 'ending_rest')) {
    $case = $authored.cases | Where-Object id -eq $id
    $restStep = [array]::IndexOf([object[]]$case.source.time, 'R')
    if ([double]$case.expected.release.off_at_step -ne $restStep) {
      throw "$id must release at the REST boundary"
    }
  }
  foreach ($length in @(16, 17, 32, 33, 48, 49, 64)) {
    $case = $authored.cases | Where-Object id -eq "repeat_slide_seam_length_$length"
    if (@($case.expected.onsets).Count -ne 1 -or
        @($case.expected.continuity_windows).Count -ne 3 -or
        @($case.expected.no_attack_windows).Count -lt 3 -or
        $case.qualification.protocol_status -cne 'blocked') {
      throw "Slide seam length $length needs one cold attack, three explicit connections and qualification blockers"
    }
  }
  foreach ($mutation in $mutations) {
    $oracle = $original | ConvertFrom-Json -AsHashtable
    & $mutation.change $oracle
    $oracle | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    $failure = $null
    try { & $validator -Path $temporaryPath } catch { $failure = $_.Exception.Message }
    if ($null -eq $failure -or $failure -notlike ('*' + $mutation.error + '*')) {
      throw "Oracle mutation '$($mutation.name)' produced unexpected result: $failure"
    }
  }
  Write-Output "Audio oracle tests passed: valid fixture and $($mutations.Count) rejected mutations."
} finally {
  if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
}
