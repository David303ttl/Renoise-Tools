Set-StrictMode -Version Latest

function ConvertTo-Db([double]$Value) {
  if ($Value -le 0) { return -300.0 }
  return 20.0 * [Math]::Log10($Value)
}

function Read-ArticulationWav([string]$Path) {
  $fullPath = (Resolve-Path -LiteralPath $Path).Path
  $bytes = [System.IO.File]::ReadAllBytes($fullPath)
  if ($bytes.Length -lt 44) { throw "WAV is shorter than a header: $fullPath" }
  $stream = [System.IO.MemoryStream]::new($bytes, $false)
  $reader = [System.IO.BinaryReader]::new($stream)
  try {
    $riff = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
    $riffSize = $reader.ReadUInt32()
    $wave = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
    if ($riff -ne 'RIFF' -or $wave -ne 'WAVE') { throw 'Input is not a RIFF/WAVE file' }
    $riffBoundary = [long]$riffSize + 8
    if ($riffBoundary -ne $bytes.Length) { throw 'RIFF declared size differs from file length' }

    $format = $null
    $data = $null
    while ($stream.Position + 8 -le $stream.Length) {
      $chunkId = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
      $chunkLength = [int]$reader.ReadUInt32()
      if ($chunkLength -lt 0 -or $stream.Position + $chunkLength -gt $stream.Length) {
        throw "Invalid WAV chunk '$chunkId' length"
      }
      if ($chunkId -eq 'fmt ') {
        if ($null -ne $format -or $chunkLength -lt 16) { throw 'WAV requires one complete fmt chunk' }
        $chunk = $reader.ReadBytes($chunkLength)
        $format = [ordered]@{
          code = [BitConverter]::ToUInt16($chunk, 0)
          channels = [BitConverter]::ToUInt16($chunk, 2)
          sample_rate = [BitConverter]::ToUInt32($chunk, 4)
          byte_rate = [BitConverter]::ToUInt32($chunk, 8)
          block_align = [BitConverter]::ToUInt16($chunk, 12)
          bits = [BitConverter]::ToUInt16($chunk, 14)
        }
      } elseif ($chunkId -eq 'data') {
        if ($null -ne $data) { throw 'WAV contains multiple data chunks' }
        $data = $reader.ReadBytes($chunkLength)
      } else {
        [void]$reader.ReadBytes($chunkLength)
      }
      if (($chunkLength % 2) -ne 0 -and $stream.Position -lt $stream.Length) { [void]$reader.ReadByte() }
    }
    if ($null -eq $format -or $null -eq $data) { throw 'WAV must contain fmt and data chunks' }
    if ($format.sample_rate -le 0) { throw 'WAV sample rate must be positive' }
    if ($format.code -notin 1, 3) { throw "Unsupported WAV encoding $($format.code); use integer PCM or IEEE float" }
    if ($format.channels -notin 1, 2) { throw "Expected mono or stereo WAV; received $($format.channels) channels" }
    if ($format.bits -notin 16, 24, 32) { throw "Unsupported WAV bit depth $($format.bits); use 16, 24 or 32 bits" }
    if ($format.code -eq 3 -and $format.bits -ne 32) { throw 'Only 32-bit IEEE float WAV is supported' }
    if ($format.code -eq 1 -and $format.bits -eq 32 -and $format.block_align -ne 4 * $format.channels) {
      throw 'Invalid 32-bit PCM block alignment'
    }
    $bytesPerSample = [int]($format.bits / 8)
    if ($format.block_align -ne $bytesPerSample * $format.channels) { throw 'Unexpected WAV block alignment' }
    if ($format.byte_rate -ne $format.sample_rate * $format.block_align) { throw 'Unexpected WAV byte rate' }
    if ($data.Length -eq 0) { throw 'WAV contains no audio frames' }
    if (($data.Length % $format.block_align) -ne 0) { throw 'WAV data does not end on a complete frame' }

    $frameCount = [int]($data.Length / $format.block_align)
    $left = [double[]]::new($frameCount)
    $right = if ($format.channels -eq 2) { [double[]]::new($frameCount) } else { $null }
    $peakLeft = 0.0
    $peakRight = 0.0
    $sumLeftSquared = 0.0
    $sumRightSquared = 0.0
    $sumDifferenceSquared = 0.0
    for ($frame = 0; $frame -lt $frameCount; $frame++) {
      $baseOffset = $frame * $format.block_align
      $values = [double[]]::new($format.channels)
      for ($channel = 0; $channel -lt $format.channels; $channel++) {
        $offset = $baseOffset + $channel * $bytesPerSample
        if ($format.code -eq 3) {
          $value = [double][BitConverter]::ToSingle($data, $offset)
        } elseif ($format.bits -eq 16) {
          $value = [double][BitConverter]::ToInt16($data, $offset) / 32768.0
        } elseif ($format.bits -eq 24) {
          $raw = [int]$data[$offset] -bor ([int]$data[$offset + 1] -shl 8) -bor ([int]$data[$offset + 2] -shl 16)
          if (($raw -band 0x800000) -ne 0) { $raw -= 0x1000000 }
          $value = [double]$raw / 8388608.0
        } else {
          $value = [double][BitConverter]::ToInt32($data, $offset) / 2147483648.0
        }
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw 'WAV contains a non-finite sample' }
        $values[$channel] = $value
      }
      $left[$frame] = $values[0]
      $peakLeft = [Math]::Max($peakLeft, [Math]::Abs($values[0]))
      $sumLeftSquared += $values[0] * $values[0]
      if ($format.channels -eq 2) {
        $right[$frame] = $values[1]
        $peakRight = [Math]::Max($peakRight, [Math]::Abs($values[1]))
        $sumRightSquared += $values[1] * $values[1]
        $difference = $values[0] - $values[1]
        $sumDifferenceSquared += $difference * $difference
      }
    }
    $rmsLeft = [Math]::Sqrt($sumLeftSquared / [Math]::Max(1, $frameCount))
    $rmsRight = if ($format.channels -eq 2) { [Math]::Sqrt($sumRightSquared / [Math]::Max(1, $frameCount)) } else { $null }
    $differenceDb = if ($format.channels -eq 2) {
      ConvertTo-Db ([Math]::Sqrt($sumDifferenceSquared / [Math]::Max(1, $frameCount)) / [Math]::Max([Math]::Max($rmsLeft, $rmsRight), 1e-12))
    } else { $null }
    $riffBoundary = [long]$riffSize + 8
    if ($riffBoundary -gt $bytes.Length) { throw 'RIFF declared size exceeds file length' }
    return [pscustomobject]@{
      Path = $fullPath
      SampleRate = [int]$format.sample_rate
      BitsPerSample = [int]$format.bits
      FormatCode = [int]$format.code
      Channels = [int]$format.channels
      BlockAlign = [int]$format.block_align
      FrameCount = $frameCount
      DurationMs = 1000.0 * $frameCount / [double]$format.sample_rate
      Left = $left
      Right = $right
      PeakDbfs = ConvertTo-Db ([Math]::Max($peakLeft, $peakRight))
      StereoDifferenceDb = $differenceDb
      Sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Get-SampleRms([double[]]$Samples, [int]$SampleRate, [double]$StartMs, [double]$EndMs) {
  if ($StartMs -lt 0 -or $EndMs -le $StartMs) { throw 'Invalid RMS window' }
  $start = [Math]::Min($Samples.Length, [int][Math]::Floor($StartMs * $SampleRate / 1000.0))
  $end = [Math]::Min($Samples.Length, [int][Math]::Floor($EndMs * $SampleRate / 1000.0))
  if (($end - $start) -lt 1) { return 0.0 }
  $sum = 0.0
  for ($index = $start; $index -lt $end; $index++) { $sum += $Samples[$index] * $Samples[$index] }
  return [Math]::Sqrt($sum / ($end - $start))
}

function Get-RmsSeries([double[]]$Samples, [int]$SampleRate, [int]$WindowMs = 5, [int]$HopMs = 1) {
  $window = [Math]::Max(1, [int][Math]::Round($SampleRate * $WindowMs / 1000.0))
  $hop = [Math]::Max(1, [int][Math]::Round($SampleRate * $HopMs / 1000.0))
  $count = [int][Math]::Floor(($Samples.Length - $window) / [double]$hop) + 1
  $values = [double[]]::new([Math]::Max(0, $count))
  for ($item = 0; $item -lt $values.Length; $item++) {
    $start = $item * $hop
    $sum = 0.0
    for ($index = $start; $index -lt $start + $window; $index++) { $sum += $Samples[$index] * $Samples[$index] }
    $values[$item] = [Math]::Sqrt($sum / $window)
  }
  return [pscustomobject]@{ Values = $values; HopMs = 1000.0 * $hop / $SampleRate; WindowMs = 1000.0 * $window / $SampleRate }
}

function Get-Median([double[]]$Values) {
  if ($Values.Length -eq 0) { return 0.0 }
  $sorted = [double[]]$Values.Clone()
  [Array]::Sort($sorted)
  $middle = [int][Math]::Floor($sorted.Length / 2.0)
  if (($sorted.Length % 2) -eq 1) { return $sorted[$middle] }
  return ($sorted[$middle - 1] + $sorted[$middle]) / 2.0
}

function Find-AudioOnsets(
  [double[]]$Samples,
  [int]$SampleRate,
  [double]$FloorDbfs = -45.0,
  [int]$WindowMs = 10,
  [double]$RefractoryMs = 40.0
) {
  if ($WindowMs -lt 1 -or $WindowMs -gt 100) { throw 'Onset RMS window must be between 1 and 100 ms' }
  if ($RefractoryMs -lt 0.0) { throw 'Onset refractory interval cannot be negative' }
  # Cover more than one reference waveform cycle to suppress pitch-period RMS dips.
  $series = Get-RmsSeries $Samples $SampleRate $WindowMs 1
  $values = $series.Values
  $onsets = [System.Collections.Generic.List[double]]::new()
  $floor = [Math]::Pow(10.0, $FloorDbfs / 20.0)
  $refractory = $RefractoryMs
  $nextAllowed = -$refractory
  for ($index = 0; $index -lt $values.Length; $index++) {
    $timeMs = $index * $series.HopMs
    if ($timeMs -lt $nextAllowed) { continue }
    $previous = if ($index -gt 0) { $values[$index - 1] } else { 0.0 }
    $current = $values[$index]
    $candidate = $false
    if ($previous -lt $floor -and $current -ge $floor) {
      $candidate = $true
    } elseif ($index -ge 8 -and $index + 1 -lt $values.Length) {
      $baselineValues = [double[]]::new(5)
      for ($back = 0; $back -lt 5; $back++) { $baselineValues[$back] = $values[$index - 7 + $back] }
      $baseline = Get-Median $baselineValues
      if ($baseline -gt $floor * 2.0) {
        $trough = [Math]::Min($current, $values[$index + 1])
        $rise = $false
        $last = [Math]::Min($values.Length - 1, $index + 10)
        for ($forward = $index + 1; $forward -le $last; $forward++) {
          if ($values[$forward] -ge $trough * 1.4 -and $values[$forward] -ge $floor) { $rise = $true; break }
        }
        if ($trough -le $baseline * 0.75 -and $rise) { $candidate = $true }
      }
    }
    if ($candidate) {
      # RMS windows look ahead; report the attack edge rather than the window start.
      $onsets.Add($timeMs + $series.WindowMs - $series.HopMs)
      $nextAllowed = $timeMs + $refractory
    }
  }
  return ,$onsets.ToArray()
}

function Measure-AttackSignature([double[]]$Samples, [int]$SampleRate, [double]$OnsetMs) {
  # Compare nonoverlapping envelope regions; carrier periods are averaged by RMS.
  $early = Get-SampleRms $Samples $SampleRate $OnsetMs ($OnsetMs + 5.0)
  $peak = Get-SampleRms $Samples $SampleRate ($OnsetMs + 8.0) ($OnsetMs + 18.0)
  $sustain = Get-SampleRms $Samples $SampleRate ($OnsetMs + 32.0) ($OnsetMs + 52.0)
  $riseRatio = if ($peak -gt 0) { $early / $peak } else { 0.0 }
  $decayRatio = if ($peak -gt 0) { $sustain / $peak } else { 0.0 }
  $complete = ($OnsetMs + 52.0) * $SampleRate / 1000.0 -le $Samples.Length
  $matched = $complete -and $peak -gt 0.001 -and $riseRatio -lt 0.75 -and $decayRatio -ge 0.45 -and $decayRatio -le 0.90
  return [pscustomobject]@{ onset_ms=$OnsetMs; early_to_peak=$riseRatio; sustain_to_peak=$decayRatio; matched=$matched; status=if ($matched) {'match'} else {'inconclusive'}; qualification='diagnostic only; native controls must qualify thresholds before acceptance' }
}
function Get-FundamentalHz([double[]]$Samples, [int]$SampleRate, [double]$StartMs, [double]$EndMs, [double]$MinimumMs = 40.0) {
  $start = [Math]::Max(0, [int][Math]::Floor($StartMs * $SampleRate / 1000.0))
  $end = [Math]::Min($Samples.Length, [int][Math]::Floor($EndMs * $SampleRate / 1000.0))
  if (($end - $start) -lt [int]($SampleRate * $MinimumMs / 1000.0)) { return $null }
  $crossings = [System.Collections.Generic.List[double]]::new()
  for ($index = $start + 1; $index -lt $end; $index++) {
    $a = $Samples[$index - 1]
    $b = $Samples[$index]
    if ($a -le 0 -and $b -gt 0) {
      $fraction = if ($b -eq $a) { 0.0 } else { -$a / ($b - $a) }
      $crossings.Add(($index - 1) + $fraction)
    }
  }
  if ($crossings.Count -lt 4) { return $null }
  $periods = [double[]]::new($crossings.Count - 1)
  for ($index = 1; $index -lt $crossings.Count; $index++) {
    $periods[$index - 1] = $crossings[$index] - $crossings[$index - 1]
  }
  $periodSamples = Get-Median $periods
  if ($periodSamples -le 0) { return $null }
  return $SampleRate / $periodSamples
}

function Get-StepMs($Case) {
  return 60000.0 / ([double]$Case.capture.bpm * 4.0)
}

function Get-WindowMs($StepValue, [double]$StepMs) {
  return [double]$StepValue * $StepMs
}

function Measure-ArticulationCase($Audio, $Case) {
  $issues = [System.Collections.Generic.List[string]]::new()
  $measurements = [ordered]@{}
  if ($Case.ContainsKey('status') -and $Case.status -ne 'ready') {
    return [pscustomobject]@{ CaseId=[string]$Case.id; Status='unsupported'; Issues=@('case is planned and has no qualified analyzer protocol'); Measurements=$measurements; Audio=@{sha256=$Audio.Sha256} }
  }
  if ($Audio.SampleRate -ne [int]$Case.capture.sample_rate) { $issues.Add("sample rate $($Audio.SampleRate) differs from expected $($Case.capture.sample_rate)") }
  if ($Audio.Channels -eq 2 -and $Audio.StereoDifferenceDb -gt -60.0) { $issues.Add(('stereo channels differ by {0:N1} dB; expected at most -60 dB' -f $Audio.StereoDifferenceDb)) }
  if ($Audio.PeakDbfs -gt -6.0) { $issues.Add(('peak {0:N2} dBFS exceeds the -6 dBFS ceiling' -f $Audio.PeakDbfs)) }
  $captureInvalid = $issues.Count -gt 0
  $samples = $Audio.Left
  $stepMs = Get-StepMs $Case
  $onsetWindowMs = if ($Case.analysis['onset_window_ms']) { [int]$Case.analysis['onset_window_ms'] } else { 10 }
  $onsetRefractoryMs = if ($Case.analysis['onset_refractory_ms']) { [double]$Case.analysis['onset_refractory_ms'] } else { 40.0 }
  $onsets = [double[]](Find-AudioOnsets $samples $Audio.SampleRate ([double]$Case.analysis.onset_floor_dbfs) $onsetWindowMs $onsetRefractoryMs)
  $expectedOnsets = @($Case.expected.onsets)
  if ($expectedOnsets.Count -gt 0 -and $onsets.Count -eq 0) { $captureInvalid = $true }
  $measurements.detected_onsets_ms = @($onsets | ForEach-Object { [Math]::Round($_, 3) })
  if ($expectedOnsets.Count -gt 0 -and $onsets.Count -lt $expectedOnsets.Count) {
    $issues.Add("detected $($onsets.Count) onsets; expected at least $($expectedOnsets.Count)")
  }
  $firstExpectedStep = if ($expectedOnsets.Count -gt 0) { [double]$expectedOnsets[0].at_step } else { 0.0 }
  $origin = if ($expectedOnsets.Count -gt 0 -and $onsets.Count -gt 0) {
    [double]$onsets[0] - (Get-WindowMs $firstExpectedStep $stepMs)
  } else { 0.0 }
  $measurements.alignment_origin_ms = [Math]::Round($origin, 3)
  $onsetResults = [System.Collections.Generic.List[object]]::new()
  $claimed = [System.Collections.Generic.HashSet[int]]::new()
  foreach ($expected in $expectedOnsets) {
    $expectedMs = $origin + (Get-WindowMs $expected.at_step $stepMs)
    $tolerance = [double]$expected.tolerance_ms
    $bestIndex = -1
    $bestError = [double]::PositiveInfinity
    for ($index = 0; $index -lt $onsets.Count; $index++) {
      if ($claimed.Contains($index)) { continue }
      $errorMs = [Math]::Abs([double]$onsets[$index] - $expectedMs)
      if ($errorMs -lt $bestError) { $bestError = $errorMs; $bestIndex = $index }
    }
    $passed = $bestIndex -ge 0 -and $bestError -le $tolerance
    if ($passed) { [void]$claimed.Add($bestIndex) } else {
      $issues.Add(('onset at step {0} expected {1:N2} ms ±{2:N2}, nearest error {3:N2} ms' -f $expected.at_step,$expectedMs,$tolerance,$bestError))
    }
    $onsetResults.Add([pscustomobject]@{ at_step=$expected.at_step; expected_ms=[Math]::Round($expectedMs,3); measured_ms=if ($bestIndex -ge 0) {[Math]::Round($onsets[$bestIndex],3)} else {$null}; error_ms=if ($bestIndex -ge 0) {[Math]::Round($bestError,3)} else {$null}; passed=$passed })
  }
  $measurements.onsets = @($onsetResults)
  $signatures = @($onsetResults | Where-Object { $null -ne $_.measured_ms } | ForEach-Object { Measure-AttackSignature $samples $Audio.SampleRate $_.measured_ms })
  $measurements.attack_signatures = $signatures
  # Repeated positions retain their offsets from the single initial alignment.
  $driftResults = [System.Collections.Generic.List[object]]::new()
  if ($Case.source.ContainsKey('length') -and [double]$Case.source.length -gt 0) {
    $length = [double]$Case.source.length
    $groups = @($onsetResults | Where-Object { $null -ne $_.measured_ms -and $_.error_ms -lt $stepMs / 4.0 } | Group-Object { [Math]::Round([double]$_.at_step % $length, 6) })
    foreach ($group in $groups) {
      $ordered = @($group.Group | Sort-Object { [double]$_.at_step })
      if ($ordered.Count -lt 2) { continue }
      $first = $ordered[0]; $last = $ordered[-1]
      $offset = ($last.measured_ms - $last.expected_ms) - ($first.measured_ms - $first.expected_ms)
      $passed = [Math]::Abs($offset) -le 5.0
      if (-not $passed) { $captureInvalid=$true; $issues.Add(('cycle drift at source step {0} is {1:N2} ms; maximum is 5 ms' -f $group.Name,$offset)) }
      $driftResults.Add([pscustomobject]@{ source_step=[double]$group.Name; first_step=$first.at_step; last_step=$last.at_step; drift_ms=[Math]::Round($offset,3); passed=$passed })
    }
  }
  $measurements.cycle_drift = @($driftResults)
  if ($onsets.Count -gt $expectedOnsets.Count) {
    $extra = [System.Collections.Generic.List[double]]::new()
    for ($index = 0; $index -lt $onsets.Count; $index++) {
      if (-not $claimed.Contains($index)) { $extra.Add([double]$onsets[$index]) }
    }
    if ($extra.Count -gt 0) { $issues.Add("detected $($extra.Count) unexpected onset(s)") }
    $measurements.unexpected_onsets_ms = @($extra | ForEach-Object { [Math]::Round($_,3) })
  }

  $pitchResults = [System.Collections.Generic.List[object]]::new()
  foreach ($window in @($Case.expected.pitch_windows)) {
    $startMs = $origin + (Get-WindowMs $window.start_step $stepMs)
    $endMs = $origin + (Get-WindowMs $window.end_step $stepMs)
    $actualHz = Get-FundamentalHz $samples $Audio.SampleRate $startMs $endMs
    $targetHz = [double]$Case.profile.base_frequency_hz * [Math]::Pow(2.0, ([double]$window.note - [double]$Case.profile.root_note) / 12.0)
    $cents = if ($null -eq $actualHz -or $actualHz -le 0) { $null } else { 1200.0 * [Math]::Log($actualHz / $targetHz, 2.0) }
    $passed = $null -ne $cents -and [Math]::Abs($cents) -le [double]$Case.analysis.pitch_tolerance_cents
    if (-not $passed) { $issues.Add(('pitch window {0:N2}–{1:N2} ms expected note {2}, measured {3}, error {4}' -f $startMs,$endMs,$window.note,$actualHz,$cents)) }
    $pitchResults.Add([pscustomobject]@{ start_ms=[Math]::Round($startMs,3); end_ms=[Math]::Round($endMs,3); expected_note=[int]$window.note; target_hz=[Math]::Round($targetHz,4); measured_hz=if ($null -eq $actualHz) {$null} else {[Math]::Round($actualHz,4)}; error_cents=if ($null -eq $cents) {$null} else {[Math]::Round($cents,2)}; passed=$passed })
  }
  $measurements.pitch_windows = @($pitchResults)

  $silenceResults = [System.Collections.Generic.List[object]]::new()
  foreach ($window in @($Case.expected.silence_windows)) {
    $startMs = $origin + (Get-WindowMs $window.start_step $stepMs)
    $endMs = $origin + (Get-WindowMs $window.end_step $stepMs)
    $rms = Get-SampleRms $samples $Audio.SampleRate $startMs $endMs
    $db = ConvertTo-Db $rms
    $passed = $db -le [double]$Case.analysis.silence_dbfs
    if (-not $passed) { $issues.Add(('silence window {0:N2}–{1:N2} ms has RMS {2:N2} dBFS' -f $startMs,$endMs,$db)) }
    $silenceResults.Add([pscustomobject]@{ start_ms=[Math]::Round($startMs,3); end_ms=[Math]::Round($endMs,3); rms_dbfs=[Math]::Round($db,2); passed=$passed })
  }
  $measurements.silence_windows = @($silenceResults)

  $noAttackResults = [System.Collections.Generic.List[object]]::new()
  $noAttackWindows = @()
  if ($Case.expected.ContainsKey('no_attack_windows')) {
    $noAttackWindows = @($Case.expected.no_attack_windows | Where-Object { $null -ne $_ })
  }
  foreach ($window in $noAttackWindows) {
    $startMs = $origin + (Get-WindowMs $window.start_step $stepMs)
    $endMs = $origin + (Get-WindowMs $window.end_step $stepMs)
    $unexpected = @($onsets | Where-Object { $_ -ge $startMs -and $_ -lt $endMs })
    $passed = $unexpected.Count -eq 0
    if (-not $passed) { $issues.Add(('detected an attack in forbidden window {0:N2}–{1:N2} ms' -f $startMs,$endMs)) }
    $noAttackResults.Add([pscustomobject]@{ start_ms=[Math]::Round($startMs,3); end_ms=[Math]::Round($endMs,3); detected_onsets_ms=@($unexpected); passed=$passed })
  }
  $measurements.no_attack_windows = @($noAttackResults)

  $continuityResults = [System.Collections.Generic.List[object]]::new()
  $continuityWindows = @()
  if ($Case.expected.ContainsKey('continuity_windows')) {
    $continuityWindows = @($Case.expected.continuity_windows | Where-Object { $null -ne $_ })
  }
  foreach ($window in $continuityWindows) {
    $startMs = $origin + (Get-WindowMs $window.start_step $stepMs)
    $endMs = $origin + (Get-WindowMs $window.end_step $stepMs)
    $detectedInWindow = @($onsets | Where-Object { $_ -ge $startMs -and $_ -lt $endMs })
    $baselineStart = $origin + (Get-WindowMs $window.baseline_start_step $stepMs)
    $baselineEnd = $origin + (Get-WindowMs $window.baseline_end_step $stepMs)
    $baselineRms = Get-SampleRms $samples $Audio.SampleRate $baselineStart $baselineEnd
    $baselineDb = ConvertTo-Db $baselineRms
    $series = Get-RmsSeries $samples $Audio.SampleRate 5 1
    $minimumDb = 0.0
    $longestDipMs = 0.0
    $dipMs = 0.0
    for ($index = 0; $index -lt $series.Values.Length; $index++) {
      $time = $index * $series.HopMs
      if ($time -lt $startMs -or $time -ge $endMs) { continue }
      $relativeDb = ConvertTo-Db ($series.Values[$index] / [Math]::Max($baselineRms,1e-12))
      $minimumDb = [Math]::Min($minimumDb,$relativeDb)
      if ($relativeDb -lt -6.0) { $dipMs += $series.HopMs; $longestDipMs=[Math]::Max($longestDipMs,$dipMs) } else { $dipMs=0.0 }
    }
    $passed = $detectedInWindow.Count -eq 0 -and $longestDipMs -lt [double]$Case.analysis.maximum_continuity_dip_ms
    if ($detectedInWindow.Count -gt 0) { $issues.Add(('unexpected onset in continuity window {0:N2}–{1:N2} ms' -f $startMs,$endMs)) }
    if ($longestDipMs -ge [double]$Case.analysis.maximum_continuity_dip_ms) { $issues.Add(('continuity dip {0:N2} ms exceeds the limit' -f $longestDipMs)) }
    $continuityResults.Add([pscustomobject]@{ start_ms=[Math]::Round($startMs,3); end_ms=[Math]::Round($endMs,3); baseline_dbfs=[Math]::Round($baselineDb,2); minimum_relative_db=[Math]::Round($minimumDb,2); longest_dip_ms=[Math]::Round($longestDipMs,2); detected_onsets_ms=@($detectedInWindow); passed=$passed })
  }
  $measurements.continuity_windows = @($continuityResults)

  $glideWindow = if ($Case.expected.ContainsKey('glide_window')) { $Case.expected.glide_window } else { $null }
  if ($glideWindow) {
    $window = $glideWindow
    $widthSteps = [double]$window.analysis_window_steps
    $glideStartStep = [double]$window.start_step
    $sampleOffsets = [double[]]::new(3)
    $sampleOffsets[0] = $glideStartStep + 0.10
    $sampleOffsets[1] = $glideStartStep + 0.26
    $sampleOffsets[2] = $glideStartStep + 0.42
    $trajectory = [System.Collections.Generic.List[object]]::new()
    $targetFromHz = [double]$Case.profile.base_frequency_hz * [Math]::Pow(2.0, ([double]$window.from_note - [double]$Case.profile.root_note) / 12.0)
    $targetToHz = [double]$Case.profile.base_frequency_hz * [Math]::Pow(2.0, ([double]$window.to_note - [double]$Case.profile.root_note) / 12.0)
    foreach ($offset in $sampleOffsets) {
      $centerMs = $origin + (Get-WindowMs $offset $stepMs)
      $halfWindowMs = (Get-WindowMs ($widthSteps / 2.0) $stepMs)
      $actualHz = Get-FundamentalHz $samples $Audio.SampleRate ($centerMs - $halfWindowMs) ($centerMs + $halfWindowMs) 20.0
      $ratio = if ($null -eq $actualHz) { $null } else { [Math]::Log($actualHz / $targetFromHz, 2.0) / [Math]::Log($targetToHz / $targetFromHz, 2.0) }
      $trajectory.Add([pscustomobject]@{ center_ms=[Math]::Round($centerMs,3); measured_hz=if ($null -eq $actualHz) {$null} else {[Math]::Round($actualHz,3)}; progress=if ($null -eq $ratio) {$null} else {[Math]::Round($ratio,3)} })
    }
    $progress = @($trajectory | ForEach-Object { $_.progress })
    $minimumProgress = if ($window['minimum_progress_delta']) { [double]$window['minimum_progress_delta'] } else { 0.12 }
    $minimumIntermediate = if ($window['minimum_intermediate_progress']) { [double]$window['minimum_intermediate_progress'] } else { 0.05 }
    $maximumIntermediate = if ($window['maximum_intermediate_progress']) { [double]$window['maximum_intermediate_progress'] } else { 0.95 }
    $measurableGlide = $progress.Count -eq 3 -and $null -notin $progress -and
      $progress[0] -lt $progress[1] -and $progress[1] -lt $progress[2] -and
      ($progress[2] - $progress[0]) -ge $minimumProgress -and
      $progress[1] -ge $minimumIntermediate -and $progress[1] -le $maximumIntermediate
    # A jump can smear into an intermediate median in overlapping pitch windows.
    # Require multiple actual waveform periods at intermediate frequencies.
    $glideStartMs = $origin + (Get-WindowMs $window.start_step $stepMs)
    $glideEndMs = $origin + (Get-WindowMs $window.end_step $stepMs)
    $firstFrame = [Math]::Max(1, [int][Math]::Floor($glideStartMs * $Audio.SampleRate / 1000.0))
    $lastFrame = [Math]::Min($samples.Length, [int][Math]::Floor($glideEndMs * $Audio.SampleRate / 1000.0))
    $lastCrossing = $null
    $intermediatePeriods = [System.Collections.Generic.List[double]]::new()
    for ($frame = $firstFrame; $frame -lt $lastFrame; $frame++) {
      $a = $samples[$frame - 1]
      $b = $samples[$frame]
      if ($a -gt 0 -or $b -le 0) { continue }
      $crossing = ($frame - 1) - $a / ($b - $a)
      if ($null -ne $lastCrossing) {
        $periodHz = $Audio.SampleRate / ($crossing - $lastCrossing)
        $periodProgress = [Math]::Log($periodHz / $targetFromHz, 2.0) / [Math]::Log($targetToHz / $targetFromHz, 2.0)
        if ($periodProgress -ge $minimumIntermediate -and $periodProgress -le $maximumIntermediate) {
          $intermediatePeriods.Add($periodProgress)
        }
      }
      $lastCrossing = $crossing
    }
    $periodMovement = if ($intermediatePeriods.Count -ge 3) {
      $intermediatePeriods[$intermediatePeriods.Count - 1] - $intermediatePeriods[0]
    } else { 0.0 }
    $measurableGlide = $measurableGlide -and $intermediatePeriods.Count -ge 3 -and $periodMovement -ge $minimumProgress
    if (-not $measurableGlide) { $issues.Add('glide pitch trajectory did not show measurable intermediate movement in the requested direction') }
    $measurements.glide_trajectory = @{ rate=[int]$window.rate; monotonic=$measurableGlide; samples=@($trajectory); minimum_progress_delta=$minimumProgress; intermediate_period_count=$intermediatePeriods.Count; period_progress_delta=[Math]::Round($periodMovement,3); interpretation=$window.interpretation }
    $settled = if ($Case.expected.ContainsKey('settled_window')) { $Case.expected.settled_window } else { $null }
    if ($settled) {
      $settleStart = $origin + (Get-WindowMs $settled.start_step $stepMs)
      $settleEnd = $settleStart + [double]$settled.duration_ms
      $settledHz = Get-FundamentalHz $samples $Audio.SampleRate $settleStart $settleEnd
      $settledTargetHz = [double]$Case.profile.base_frequency_hz * [Math]::Pow(2.0, ([double]$settled.note - [double]$Case.profile.root_note) / 12.0)
      $settledCents = if ($null -eq $settledHz -or $settledHz -le 0) { $null } else { 1200.0 * [Math]::Log($settledHz / $settledTargetHz, 2.0) }
      $settledPassed = $null -ne $settledCents -and [Math]::Abs($settledCents) -le [double]$Case.analysis.pitch_tolerance_cents
      if (-not $settledPassed) { $issues.Add(('glide was not within {0:N1} cents of note {1} by step {2:N2} for {3:N1} ms' -f $Case.analysis.pitch_tolerance_cents,$settled.note,$settled.start_step,$settled.duration_ms)) }
      $measurements.glide_settle = @{ start_ms=[Math]::Round($settleStart,3); duration_ms=[double]$settled.duration_ms; target_note=[int]$settled.note; measured_hz=if ($null -eq $settledHz) {$null} else {[Math]::Round($settledHz,3)}; error_cents=if ($null -eq $settledCents) {$null} else {[Math]::Round($settledCents,2)}; passed=$settledPassed }
    }
  }

  $releaseExpectation = if ($Case.expected.ContainsKey('release')) { $Case.expected.release } else { $null }
  if ($releaseExpectation) {
    $release = $releaseExpectation
    $offMs = $origin + (Get-WindowMs $release.off_at_step $stepMs)
    $baselineRms = Get-SampleRms $samples $Audio.SampleRate ($offMs - 45.0) ($offMs - 10.0)
    $baselineDb = ConvertTo-Db $baselineRms
    $minimumSustainMarginDb = if ($release['minimum_pre_off_margin_db']) { [double]$release['minimum_pre_off_margin_db'] } else { 3.0 }
    $minimumSustainDb = [Math]::Max([double]$Case.analysis.silence_dbfs + $minimumSustainMarginDb, $baselineDb - 6.0)
    $baselineAudible = $baselineDb -ge $minimumSustainDb
    # Require sustain through the final pre-OFF interval, not just an earlier average.
    $minimumPreOffDb = $baselineDb
    for ($sustainMs = $offMs - 45.0; $sustainMs -le $offMs - 10.0; $sustainMs += 5.0) {
      $sustainDb = ConvertTo-Db (Get-SampleRms $samples $Audio.SampleRate $sustainMs ($sustainMs + 5.0))
      $minimumPreOffDb = [Math]::Min($minimumPreOffDb, $sustainDb)
    }
    $baselineAudible = $baselineAudible -and $minimumPreOffDb -ge $minimumSustainDb
    if (-not $baselineAudible) {
      $issues.Add(('minimum pre-OFF sustain is {0:N2} dBFS; expected at least {1:N2} dBFS' -f $minimumPreOffDb,$minimumSustainDb))
    }
    $thresholdDb = [Math]::Min([double]$Case.analysis.silence_dbfs,$baselineDb - 40.0)
    $threshold = [Math]::Pow(10.0,$thresholdDb / 20.0)
    $crossingMs = $null
    $confirmationMs = if ($release['confirmation_ms']) { [double]$release['confirmation_ms'] } else { 8.0 }
    for ($timeMs = [Math]::Max(0.0,$offMs - 5.0); $timeMs -le $offMs + [double]$release.maximum_tail_ms; $timeMs += 1.0) {
      if ((Get-SampleRms $samples $Audio.SampleRate $timeMs ($timeMs + 2.0)) -gt $threshold) { continue }
      $confirmed = $true
      for ($checkMs = $timeMs + 1.0; $checkMs -lt $timeMs + $confirmationMs; $checkMs += 1.0) {
        if ((Get-SampleRms $samples $Audio.SampleRate $checkMs ($checkMs + 2.0)) -gt $threshold) { $confirmed = $false; break }
      }
      if ($confirmed) { $crossingMs=$timeMs; break }
    }
    $releaseError = if ($null -eq $crossingMs) { $null } else { [double]$crossingMs - $offMs }
    $releasePassed = $baselineAudible -and $null -ne $crossingMs -and $releaseError -ge -5.0 -and $releaseError -le [double]$release.maximum_tail_ms
    if (-not $releasePassed) { $issues.Add(('release did not reach the declared silence threshold within {0:N1} ms of OFF' -f $release.maximum_tail_ms)) }
    $measurements.release = @{ off_at_ms=[Math]::Round($offMs,3); pre_off_sustain_dbfs=[Math]::Round($baselineDb,2); minimum_pre_off_sustain_dbfs=[Math]::Round($minimumPreOffDb,2); minimum_pre_off_dbfs=[Math]::Round($minimumSustainDb,2); silence_threshold_dbfs=[Math]::Round($thresholdDb,2); confirmation_ms=$confirmationMs; threshold_crossing_ms=if ($null -eq $crossingMs) {$null} else {[Math]::Round($crossingMs,3)}; tail_ms=if ($null -eq $releaseError) {$null} else {[Math]::Round($releaseError,3)}; passed=$releasePassed }
  }

  return [pscustomobject]@{
    CaseId = [string]$Case.id
    Status = if ($captureInvalid) { 'invalid' } elseif ($issues.Count -eq 0) { 'pass' } else { 'fail' }
    Issues = @($issues)
    Measurements = $measurements
    Audio = [ordered]@{ sha256=$Audio.Sha256; sample_rate=$Audio.SampleRate; channels=$Audio.Channels; bits_per_sample=$Audio.BitsPerSample; duration_ms=[Math]::Round($Audio.DurationMs,3); peak_dbfs=[Math]::Round($Audio.PeakDbfs,2); stereo_difference_db=if ($null -eq $Audio.StereoDifferenceDb) {$null} else {[Math]::Round($Audio.StereoDifferenceDb,2)} }
  }
}

Export-ModuleMember -Function Measure-AttackSignature,Read-ArticulationWav,Get-SampleRms,Get-RmsSeries,Find-AudioOnsets,Get-FundamentalHz,Measure-ArticulationCase
