function Get-DbRms([double[]]$Samples,[int]$SampleRate,[double]$StartMs,[double]$EndMs) {
  if ($StartMs -lt 0 -or $EndMs -le $StartMs) { throw 'Invalid RMS interval' }
  $first=[Math]::Max(0,[int][Math]::Floor($StartMs*$SampleRate/1000))
  $last=[Math]::Min($Samples.Length,[int][Math]::Floor($EndMs*$SampleRate/1000))
  if ($last -le $first) { throw 'RMS interval contains no audio samples' }
  $sum=0.0
  for ($i=$first;$i -lt $last;$i++) { $sum+=$Samples[$i]*$Samples[$i] }
  $rms=[Math]::Sqrt($sum/($last-$first))
  if ($rms -le 0) { return -300.0 }
  return 20.0*[Math]::Log10($rms)
}

function Measure-AccentEventDelta([double[]]$Samples,[int]$SampleRate,[double[]]$OnsetsMs,[int[]]$AccentEventIndices,[double]$WindowStartMs=15.0,[double]$WindowEndMs=50.0) {
  if ($OnsetsMs.Length -notin 3,4 -or $AccentEventIndices.Length -eq 0) { throw 'Accent measurement requires three or four event onsets and accent event indices' }
  $accentSet=@{}
  foreach ($index in $AccentEventIndices) {
    if ($index -lt 1 -or $index -gt $OnsetsMs.Length) { throw 'Accent event index is out of range' }
    $accentSet[$index]=$true
  }
  $normal= [System.Collections.Generic.List[double]]::new()
  $accent= [System.Collections.Generic.List[double]]::new()
  for ($index=0;$index -lt $OnsetsMs.Length;$index++) {
    $start=$OnsetsMs[$index]+$WindowStartMs
    $end=$OnsetsMs[$index]+$WindowEndMs
    $level=Get-DbRms $Samples $SampleRate $start $end
    if ($accentSet.ContainsKey($index+1)) { $accent.Add($level) } else { $normal.Add($level) }
  }
  if ($normal.Count -eq 0 -or $accent.Count -eq 0) { throw 'Both normal and accented events are required' }
  $normalSorted=[double[]]$normal.ToArray(); [Array]::Sort($normalSorted)
  $accentSorted=[double[]]$accent.ToArray(); [Array]::Sort($accentSorted)
  $normalMedian=if($normalSorted.Length%2){$normalSorted[[int]($normalSorted.Length/2)]}else{($normalSorted[[int]($normalSorted.Length/2)-1]+$normalSorted[[int]($normalSorted.Length/2)])/2}
  $accentMedian=if($accentSorted.Length%2){$accentSorted[[int]($accentSorted.Length/2)]}else{($accentSorted[[int]($accentSorted.Length/2)-1]+$accentSorted[[int]($accentSorted.Length/2)])/2}
  return [pscustomobject]@{ normal_dbfs=$normalMedian; accent_dbfs=$accentMedian; delta_db=$accentMedian-$normalMedian; normal_events=$normal.ToArray(); accent_events=$accent.ToArray() }
}

function Test-AccentResponseAcceptance([double[]]$MeasuredDeltasDb,[double]$ExpectedDeltaDb=3.156,[double]$ToleranceDb=0.5,[double]$MaximumSpreadDb=0.5) {
  if ($MeasuredDeltasDb.Length -ne 3) { throw 'Acceptance requires exactly three unchanged captures' }
  $minimum=($MeasuredDeltasDb|Measure-Object -Minimum).Minimum
  $maximum=($MeasuredDeltasDb|Measure-Object -Maximum).Maximum
  $spread=$maximum-$minimum
  $mean=($MeasuredDeltasDb|Measure-Object -Average).Average
  $passed=[Math]::Abs($mean-$ExpectedDeltaDb) -le $ToleranceDb -and $spread -le $MaximumSpreadDb
  return [pscustomobject]@{expected_delta_db=$ExpectedDeltaDb; mean_delta_db=$mean; spread_db=$spread; passed=$passed}
}

function Test-TiedAccentRetention([double[]]$TieLevelDifferencesDb,[double]$ToleranceDb=0.5) {
  if($TieLevelDifferencesDb.Length -ne 3){throw 'Tied-accent retention requires all three authored TIE windows'}
  $maximumError=($TieLevelDifferencesDb|ForEach-Object {[Math]::Abs($_)}|Measure-Object -Maximum).Maximum
  $passed=$maximumError -le $ToleranceDb
  return [pscustomobject]@{tie_level_tolerance_db=$ToleranceDb;maximum_tie_level_error_db=$maximumError;passed=$passed}
}

function Read-AccentNoteCells([string]$Record,[bool]$Native) {
  $cells=@{}
  foreach($line in ($Record -split "`r?`n")) {
    if($line -match '^phrase\.line\.(\d+)=(.*)$'){$cells[[int]$Matches[1]]=@($Matches[2].Split(','))}
  }
  $events=[System.Collections.Generic.List[object]]::new()
  foreach($lineNumber in ($cells.Keys|Sort-Object)) {
    $cell=$cells[$lineNumber]
    if([int]$cell[0] -ge 120){continue}
    $volumeField=if($Native){1}else{2}
    if($cell.Count -le $volumeField){throw "Phrase line $lineNumber has no volume value"}
    $events.Add([pscustomobject]@{line=$lineNumber;note=[int]$cell[0];volume=[int]$cell[$volumeField]})
  }
  return $events.ToArray()
}

Export-ModuleMember -Function Get-DbRms,Measure-AccentEventDelta,Test-AccentResponseAcceptance,Test-TiedAccentRetention,Read-AccentNoteCells
