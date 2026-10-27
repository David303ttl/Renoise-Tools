#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$WavPath,
  [Parameter(Mandatory=$true)][string]$CaseId,
  [string]$OraclePath = (Join-Path $PSScriptRoot 'fixtures\audio_cases.json'),
  [string]$OutputPath,
  [string]$NormalizationProvenancePath,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
$oracle = Get-Content -LiteralPath $OraclePath -Raw | ConvertFrom-Json -AsHashtable
if ($oracle.format -cne 'ACID-AUDIO-ORACLE-1') { throw "Unsupported audio oracle format '$($oracle.format)'" }
$case = @($oracle.cases | Where-Object { $_.id -ceq $CaseId }) | Select-Object -First 1
if ($null -eq $case) { throw "Unknown audio case '$CaseId'" }
if ($case.ContainsKey('status') -and $case.status -ne 'ready') {
  $unsupported = [ordered]@{ format='ACID-AUDIO-RESULT-1'; case_id=$CaseId; status='unsupported'; issues=@('case is planned and has no qualified analyzer protocol'); audio=@{path=$WavPath} }
  if ($OutputPath) {
    if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite analysis result '$OutputPath'" }
    Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json -InputObject $unsupported -Depth 30) -Encoding utf8
  }
  if ($Json) { ConvertTo-Json -InputObject $unsupported -Depth 30 } else { Write-Output "${CaseId}: UNSUPPORTED — $($unsupported.issues[0])" }
  exit 2
}

try {
  $audio = Read-ArticulationWav $WavPath
  $normalization = $null
  if ($NormalizationProvenancePath) {
    $normalization = Get-Content -LiteralPath $NormalizationProvenancePath -Raw | ConvertFrom-Json -AsHashtable
    if ($normalization.format -cne 'ACID-AUDIO-NORMALIZATION-1') { throw 'Unsupported normalization provenance format' }
    if ($normalization.output.sha256 -cne $audio.Sha256) { throw 'Normalized WAV SHA-256 differs from provenance' }
    $provenanceDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $NormalizationProvenancePath).Path
    $originalPath = Join-Path $provenanceDirectory $normalization.source.path
    if ((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $normalization.source.sha256) { throw 'Original WAV SHA-256 differs from normalization provenance' }
  }
} catch {
  $invalid = [ordered]@{
    format='ACID-AUDIO-RESULT-1'
    case_id=$CaseId
    status='invalid'
    issues=@($_.Exception.Message)
    audio=@{ path=$WavPath }
  }
  if ($OutputPath) {
    if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite analysis result '$OutputPath'" }
    Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json -InputObject $invalid -Depth 30) -Encoding utf8
  }
  if ($Json) { ConvertTo-Json -InputObject $invalid -Depth 30 } else { Write-Error "INVALID: $($_.Exception.Message)" }
  exit 2
}

$minimumTailMs = if ($case.capture.minimum_tail_ms) { [double]$case.capture.minimum_tail_ms } else { 500.0 }
$expectedEndStep = 0.0
foreach ($onset in @($case.expected.onsets)) { $expectedEndStep=[Math]::Max($expectedEndStep,[double]$onset.at_step) }
foreach ($window in @($case.expected.pitch_windows)) { $expectedEndStep=[Math]::Max($expectedEndStep,[double]$window.end_step) }
foreach ($window in @($case.expected.silence_windows)) { $expectedEndStep=[Math]::Max($expectedEndStep,[double]$window.end_step) }
foreach ($window in @($case.expected.continuity_windows)) { $expectedEndStep=[Math]::Max($expectedEndStep,[double]$window.end_step) }
foreach ($window in @($case.expected.no_attack_windows)) { $expectedEndStep=[Math]::Max($expectedEndStep,[double]$window.end_step) }
if ($case.expected.glide_window) { $expectedEndStep=[Math]::Max($expectedEndStep,[double]$case.expected.glide_window.end_step) }
$stepMs = 60000.0 / ([double]$case.capture.bpm * 4.0)
if ($case.expected.settled_window) {
  $expectedEndStep=[Math]::Max($expectedEndStep,[double]$case.expected.settled_window.start_step + [double]$case.expected.settled_window.duration_ms / $stepMs)
}
if ($case.expected.release) {
  $release = $case.expected.release
  $expectedEndStep=[Math]::Max($expectedEndStep,[double]$release.off_at_step)
  $minimumTailMs=[Math]::Max($minimumTailMs,[double]$release.maximum_tail_ms + [double]$(if ($release.confirmation_ms) {$release.confirmation_ms} else {8.0}))
}
$onsetWindowMs = if ($case.analysis.onset_window_ms) { [int]$case.analysis.onset_window_ms } else { 10 }
$onsetRefractoryMs = if ($case.analysis.onset_refractory_ms) { [double]$case.analysis.onset_refractory_ms } else { 40.0 }
$detectedOnsets = [double[]](Find-AudioOnsets $audio.Left $audio.SampleRate ([double]$case.analysis.onset_floor_dbfs) $onsetWindowMs $onsetRefractoryMs)
$firstExpected = @($case.expected.onsets | Sort-Object { [double]$_.at_step } | Select-Object -First 1)
$originGuess = if ($firstExpected.Count -gt 0 -and $detectedOnsets.Count -gt 0) {
  [double]$detectedOnsets[0] - [double]$firstExpected[0].at_step * $stepMs
} else { 0.0 }
$requiredEndMs = $originGuess + $expectedEndStep * $stepMs + $minimumTailMs
if ($firstExpected.Count -gt 0 -and $detectedOnsets.Count -eq 0) {
  $invalid = [ordered]@{
    format='ACID-AUDIO-RESULT-1'; case_id=$CaseId; status='invalid'
    issues=@('capture has no detectable onset from which to establish one-time alignment')
    audio=@{sha256=$audio.Sha256;sample_rate=$audio.SampleRate;channels=$audio.Channels;duration_ms=[Math]::Round($audio.DurationMs,3);peak_dbfs=[Math]::Round($audio.PeakDbfs,2)}
  }
  if ($OutputPath) {
    if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite analysis result '$OutputPath'" }
    Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json -InputObject $invalid -Depth 30) -Encoding utf8
  }
  if ($Json) { ConvertTo-Json -InputObject $invalid -Depth 30 } else { Write-Error $invalid.issues[0] }
  exit 2
}
if ($audio.DurationMs -lt $requiredEndMs) {
  $invalid = [ordered]@{
    format='ACID-AUDIO-RESULT-1'; case_id=$CaseId; status='invalid'
    issues=@(('capture ends at {0:N0} ms; aligned case needs {1:N0} ms for the expected windows and tail' -f $audio.DurationMs,$requiredEndMs))
    audio=@{sha256=$audio.Sha256;sample_rate=$audio.SampleRate;channels=$audio.Channels;duration_ms=[Math]::Round($audio.DurationMs,3);peak_dbfs=[Math]::Round($audio.PeakDbfs,2)}
  }
  if ($OutputPath) {
    if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite analysis result '$OutputPath'" }
    Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json -InputObject $invalid -Depth 30) -Encoding utf8
  }
  if ($Json) { ConvertTo-Json -InputObject $invalid -Depth 30 } else { Write-Error $invalid.issues[0] }
  exit 2
}

$result = Measure-ArticulationCase $audio $case
$report = [ordered]@{
  format='ACID-AUDIO-RESULT-1'
  case_id=$result.CaseId
  status=$result.Status
  issues=@($result.Issues)
  measurements=$result.Measurements
  audio=$result.Audio
  capture=@{ bpm=[double]$case.capture.bpm; song_lpb=[int]$case.capture.song_lpb; tpl=[int]$case.capture.tpl; profile_id=[string]$case.profile.id }
  normalization=$normalization
}
if ($OutputPath) {
  if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite analysis result '$OutputPath'" }
  $outputDirectory = Split-Path -Parent $OutputPath
  if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory | Out-Null }
  Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json -InputObject $report -Depth 40) -Encoding utf8
}
if ($Json) {
  ConvertTo-Json -InputObject $report -Depth 40
} else {
  $peakText = '{0:N2} dBFS' -f $audio.PeakDbfs
  Write-Output ("{0}: {1} — {2} Hz, {3} ch, peak {4}" -f $CaseId,$result.Status.ToUpperInvariant(),$audio.SampleRate,$audio.Channels,$peakText)
  foreach ($issue in $result.Issues) { Write-Output "  FAIL: $issue" }
  Write-Output ("  Onsets: {0}; pitch windows: {1}; silence windows: {2}; continuity windows: {3}" -f @($result.Measurements.onsets).Count,@($result.Measurements.pitch_windows).Count,@($result.Measurements.silence_windows).Count,@($result.Measurements.continuity_windows).Count)
  foreach ($kind in 'onsets','pitch_windows','silence_windows','no_attack_windows','continuity_windows') {
    foreach ($window in @($result.Measurements[$kind])) {
      if ($null -ne $window) { Write-Output ("  {0}: {1}" -f $kind,($window | ConvertTo-Json -Compress -Depth 8)) }
    }
  }
  foreach ($kind in 'glide_trajectory','glide_settle','release') {
    if ($result.Measurements.Contains($kind)) { Write-Output ("  {0}: {1}" -f $kind,($result.Measurements[$kind] | ConvertTo-Json -Compress -Depth 8)) }
  }
  if ($OutputPath) { Write-Output "  Machine-readable result: $OutputPath" }
}
if ($result.Status -in 'invalid','unsupported') { exit 2 }
if ($result.Status -ne 'pass') { exit 1 }
