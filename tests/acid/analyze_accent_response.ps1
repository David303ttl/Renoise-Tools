#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('native_accent_alternating','native_accent_consecutive','alternating_accents','consecutive_accents','native_tied_accent','writer_tied_accent')][string]$CaseId,
  [Parameter(Mandatory=$true)][ValidateCount(3,3)][string[]]$WavPath,
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [string]$OraclePath=(Join-Path $PSScriptRoot 'fixtures\audio_cases.json'),
  [Parameter(Mandatory=$true)][string]$WriterRecord
)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputPath){throw "Refusing to overwrite '$OutputPath'"}
Import-Module (Join-Path $PSScriptRoot 'audio_analyzer.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'accent_response.psm1') -Force
$native=$CaseId.StartsWith('native_')
$tied=$CaseId -match 'tied_accent$'
$record=Get-Content -LiteralPath $WriterRecord -Raw
$accentIndices=if($tied){@(2)}elseif($CaseId -match 'alternating'){@(2,4)}else{@(2,3)}
$metadataCaseId=($record -split "`r?`n"|Where-Object {$_ -match '^case_id='}|Select-Object -First 1) -replace '^case_id=',''
if($metadataCaseId -cne $CaseId){throw "Capture metadata case '$metadataCaseId' differs from requested '$CaseId'"}
$oracle=Get-Content -LiteralPath $OraclePath -Raw|ConvertFrom-Json -AsHashtable
if($native){
  foreach($required in @('mapping.map_velocity_to_volume=true','sample.modulation_set_index=0','accent_velocity_cells=89,255')){if(!$record.Contains($required)){throw "Native metadata missing '$required'"}}
  $eventCount=if($CaseId -match 'alternating'){4}else{3}
  $expectedNotes=@(for($i=0;$i -lt $eventCount;$i++){48})
  if($tied){$expectedVolumes=@(89,255,89)}elseif($CaseId -match 'alternating'){$expectedVolumes=@(89,255,89,255)}else{$expectedVolumes=@(89,255,255)}
}else{
  if(!$record.Contains("case_id=$CaseId")){throw 'Writer metadata case ID does not match'}
  if(!$record.Contains('mapping.map_velocity_to_volume=true') -or !$record.Contains('sample.modulation_set_index=0')){throw 'Writer capture must use flat mapped velocity'}
  $oracleToRead=if($tied){Join-Path $PSScriptRoot 'fixtures\tied_accent_case.json'}else{$OraclePath}
  $oracle=Get-Content -LiteralPath $oracleToRead -Raw|ConvertFrom-Json -AsHashtable
  $case=@($oracle.cases|Where-Object id -CEQ $CaseId)|Select-Object -First 1
  if(!$case){throw "Missing oracle case '$CaseId'"}
  $expectedNotes=@($case.source.pitches)
  $eventCount=$expectedNotes.Count
  $accentSet=@{}; foreach($index in $accentIndices){$accentSet[$index]=$true}
  $expectedVolumes=@(for($i=1;$i -le $eventCount;$i++){if($accentSet.ContainsKey($i)){255}else{89}})
}
$noteCells=@(Read-AccentNoteCells $record $native)
if($noteCells.Count -ne $eventCount){throw "Expected $eventCount generated NOTE cells; found $($noteCells.Count)"}
for($i=0;$i -lt $eventCount;$i++){
  if($noteCells[$i].note -ne $expectedNotes[$i] -or $noteCells[$i].volume -ne $expectedVolumes[$i]){throw "Emitted note/volume differs at event $($i+1)"}
}
if($tied){
  $expectedLines=@(1,5,9)
  if((@($noteCells|ForEach-Object {$_.line}) -join ',') -cne ($expectedLines -join ',')){throw 'Tied-accent NOTE cells must be authored at phrase lines 1, 5 and 9'}
  $tieLines=@(3,7,11)
  foreach($line in $tieLines){
    if($record -notmatch "(?m)^phrase\.line\.$line=121,"){throw "Expected an empty TIE cell at phrase line $line"}
  }
  foreach($line in @(4,8,13)){if($record -notmatch "(?m)^phrase\.line\.$line=120,"){throw "Expected a midpoint or final OFF at phrase line $line"}}
}
$onsetOffsetsMs=if($tied){@(0.0,250.0,500.0)}else{@(0..($eventCount-1)|ForEach-Object {$_*125.0})}
$runResults=[System.Collections.Generic.List[object]]::new()
foreach($path in $WavPath){
  $audio=Read-ArticulationWav $path
  if($audio.SampleRate -ne 48000 -or $audio.Channels -ne 2 -or $audio.BitsPerSample -ne 24){throw "Capture must be 48 kHz stereo PCM24: $path"}
  if($audio.PeakDbfs -ge -6.0){throw "Capture peak exceeds -6 dBFS: $path"}
  if($audio.StereoDifferenceDb -gt -60.0){throw "Stereo difference exceeds -60 dB: $path"}
  $detectedOnsets=[double[]](Find-AudioOnsets $audio.Left $audio.SampleRate -60.0 10 90.0)
  if($detectedOnsets.Length -eq 0){throw "Could not align the first authored NOTE in $path"}
  $origin=$detectedOnsets[0]
  $usedOnsets=[double[]]@($onsetOffsetsMs|ForEach-Object {$origin+$_})
  for($i=0;$i -lt $eventCount;$i++){
    if([Math]::Abs($usedOnsets[$i]-($origin+$onsetOffsetsMs[$i])) -gt 5){throw "Unexpected onset timing in $path"}
    $frequency=Get-FundamentalHz $audio.Left $audio.SampleRate ($usedOnsets[$i]+12.0) ($usedOnsets[$i]+52.0) 40.0
    $cents=1200.0*[Math]::Log2($frequency/262.5)
    if([Math]::Abs($cents) -gt 15.0){throw "Pitch differs by $([Math]::Round($cents,2)) cents in $path"}
  }
  $delta=Measure-AccentEventDelta $audio.Left $audio.SampleRate $usedOnsets $accentIndices 15.0 50.0
  $tieLevels=@()
  $tieRetention=$null
  if($tied){
    $tieOffsets=@(125.0,375.0,625.0)
    $tieErrors=[System.Collections.Generic.List[double]]::new()
    for($i=0;$i -lt $tieOffsets.Count;$i++){
      $noteLevel=Get-DbRms $audio.Left $audio.SampleRate ($usedOnsets[$i]+15.0) ($usedOnsets[$i]+50.0)
      $tieLevel=Get-DbRms $audio.Left $audio.SampleRate ($origin+$tieOffsets[$i]+15.0) ($origin+$tieOffsets[$i]+50.0)
      $errorDb=$tieLevel-$noteLevel
      $tieLevels+=,[ordered]@{step=$i*2+2;level_dbfs=$tieLevel;preceding_note_dbfs=$noteLevel;difference_db=$errorDb}
      $tieErrors.Add($errorDb)
    }
    $tieRetention=Test-TiedAccentRetention ([double[]]$tieErrors.ToArray()) 0.5
    if(!$tieRetention.passed){throw "Tied accent retention failed in $path`: $($tieRetention | ConvertTo-Json -Compress)"}
  }
  $runResults.Add([ordered]@{path=(Resolve-Path -LiteralPath $path).Path;sha256=$audio.Sha256;peak_dbfs=$audio.PeakDbfs;stereo_difference_db=$audio.StereoDifferenceDb;origin_ms=$origin;detected_onsets_ms=$detectedOnsets;authored_note_grid_ms=$usedOnsets;normal_events_dbfs=$delta.normal_events;accent_events_dbfs=$delta.accent_events;delta_db=$delta.delta_db;tie_retention=$tieRetention;tie_windows=$tieLevels})
}
$acceptance=Test-AccentResponseAcceptance ([double[]]@($runResults|ForEach-Object {[double]$_.delta_db})) 3.156 0.5 0.5
$report=[ordered]@{format='ACID-ACCENT-RESPONSE-1';case_id=$CaseId;profile=if($native){'reference_flat_mapped_velocity'}else{'reference_flat_mapped_velocity_actual_writer'};writer_record=(Resolve-Path -LiteralPath $WriterRecord).Path;expected_delta_db=3.156;measurement_window_ms=@(15,50);tie_level_tolerance_db=if($tied){0.5}else{$null};acceptance=$acceptance;runs=@($runResults)}
Set-Content -LiteralPath $OutputPath -Value (ConvertTo-Json $report -Depth 10)
$status=if($acceptance.passed){'PASS'}else{'FAIL'}
Write-Output ("{0}: {1}; measured {2:N3} dB expected {3:N3} dB, spread {4:N3} dB" -f $CaseId,$status,$acceptance.mean_delta_db,$acceptance.expected_delta_db,$acceptance.spread_db)
Write-Output "Report: $OutputPath"
if(!$acceptance.passed){exit 1}
