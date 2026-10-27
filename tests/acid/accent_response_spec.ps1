$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'accent_response.psm1') -Force
$nativeCells=@(Read-AccentNoteCells "phrase.line.1=48,89`nphrase.line.2=120,255`nphrase.line.3=48,255`nphrase.line.4=120,255" $true)
if($nativeCells.Count -ne 2 -or $nativeCells[0].volume -ne 89 -or $nativeCells[1].volume -ne 255){throw 'Native two-column volume metadata was parsed incorrectly'}
$writerCells=@(Read-AccentNoteCells "phrase.line.1=48,255,89,255,0,0,0`nphrase.line.2=120,255,255,255,0,0,0`nphrase.line.3=48,255,255,255,0,0,0" $false)
if($writerCells.Count -ne 2 -or $writerCells[0].volume -ne 89 -or $writerCells[1].volume -ne 255){throw 'Writer seven-column volume metadata was parsed incorrectly'}
$rate=48000
$durationMs=600
$samples=[double[]]::new([int]($rate*$durationMs/1000))
$frequency=262.5
$expected=20*[Math]::Log10(128.0/89.0)
$accentPatterns=@(@(2,4),@(2,3))
foreach($pattern in $accentPatterns){
  for($take=0;$take -lt 3;$take++){
    for($index=0;$index -lt $samples.Length;$index++){
      $timeMs=$index*1000.0/$rate
      $step=[int][Math]::Floor($timeMs/125.0)
      if($step-ge 4){continue}
      $within=$timeMs-$step*125.0
      if($within-ge 62.5){continue}
      $velocity=if(($pattern -contains ($step+1))){128.0}else{89.0}
      $samples[$index]=($velocity/89.0)*[Math]::Sin(2*[Math]::PI*$frequency*$timeMs/1000.0)*0.25
    }
    $onsets=[double[]]@(0,125,250,375)
    $result=Measure-AccentEventDelta $samples $rate $onsets $pattern 15 50
    if([Math]::Abs($result.delta_db-$expected)-gt 0.15){throw "Positive control diverged: $($result.delta_db)"}
  }
}
$threeEventResult=Measure-AccentEventDelta $samples $rate ([double[]]@(0,125,250)) ([int[]]@(2,3)) 15 50
if([Math]::Abs($threeEventResult.delta_db-$expected)-gt 0.15){throw 'Three-event consecutive control was not distinguished'}
$low=$expected - 0.1
$high=$expected + 0.1
$accepted=Test-AccentResponseAcceptance ([double[]]@($low,$expected,$high)) $expected 0.5 0.5
if(!$accepted.passed){throw 'Three-take positive acceptance failed'}
$rejected=Test-AccentResponseAcceptance ([double[]]@(($expected - 0.6),($expected - 0.7),($expected - 0.5))) $expected 0.5 0.5
if($rejected.passed){throw 'Out-of-tolerance accent response was accepted'}
$spreadRejected=Test-AccentResponseAcceptance ([double[]]@(($expected - 0.4),$expected,($expected + 0.4))) $expected 0.5 0.5
if($spreadRejected.passed){throw 'Unstable three-take response was accepted'}
$tiePositive=Test-TiedAccentRetention ([double[]]@(0.08,-0.12,0.04)) 0.5
if(!$tiePositive.passed){throw 'Stable early-TIE level windows were rejected'}
$tieLevelRejected=Test-TiedAccentRetention ([double[]]@(0.05,-0.62,-0.08)) 0.5
if($tieLevelRejected.passed){throw 'A seeded early TIE level drop above 0.5 dB was accepted'}
$tieAttackRejected=Test-TiedAccentRetention ([double[]]@(0.05,0.71,-0.08)) 0.5
if($tieAttackRejected.passed){throw 'A seeded TIE attack level excursion above 0.5 dB was accepted'}
$tieBadShapeRejected=$false
try { [void](Test-TiedAccentRetention ([double[]]@(0.0,0.0)) 0.5) } catch { $tieBadShapeRejected=$true }
if(!$tieBadShapeRejected){throw 'Missing TIE level windows were accepted'}




