Set-StrictMode -Version Latest

function Read-ArticulationWav([string]$Path) {
  $fullPath = (Resolve-Path -LiteralPath $Path).Path
  $bytes = [System.IO.File]::ReadAllBytes($fullPath)
  if ($bytes.Length -lt 44) { throw 'WAV is shorter than a header' }
  $stream = [System.IO.MemoryStream]::new($bytes, $false)
  $reader = [System.IO.BinaryReader]::new($stream)
  try {
    $riff = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
    $riffSize = $reader.ReadUInt32()
    $wave = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
    if ($riff -ne 'RIFF' -or $wave -ne 'WAVE') { throw 'Input is not a RIFF/WAVE file' }
    if ([long]$riffSize + 8 -ne $bytes.Length) { throw 'RIFF declared size differs from file length' }

    $format = $null
    $data = $null
    while ($stream.Position + 8 -le $stream.Length) {
      $chunkId = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
      $chunkLength = [long]$reader.ReadUInt32()
      if ($chunkLength -gt [int]::MaxValue -or $stream.Position + $chunkLength -gt $stream.Length) {
        throw "Invalid WAV chunk '$chunkId' length"
      }
      if ($chunkId -eq 'fmt ') {
        if ($null -ne $format -or $chunkLength -lt 16) { throw 'WAV requires one complete fmt chunk' }
        $chunk = $reader.ReadBytes([int]$chunkLength)
        $format = @{
          code = [BitConverter]::ToUInt16($chunk, 0)
          channels = [BitConverter]::ToUInt16($chunk, 2)
          sample_rate = [BitConverter]::ToUInt32($chunk, 4)
          byte_rate = [BitConverter]::ToUInt32($chunk, 8)
          block_align = [BitConverter]::ToUInt16($chunk, 12)
          bits = [BitConverter]::ToUInt16($chunk, 14)
        }
      } elseif ($chunkId -eq 'data') {
        if ($null -ne $data) { throw 'WAV contains multiple data chunks' }
        $data = $reader.ReadBytes([int]$chunkLength)
      } else {
        [void]$reader.ReadBytes([int]$chunkLength)
      }
      if (($chunkLength % 2) -ne 0 -and $stream.Position -lt $stream.Length) { [void]$reader.ReadByte() }
    }
    if ($stream.Position -ne $stream.Length) { throw 'WAV contains an incomplete chunk header' }
    if ($null -eq $format -or $null -eq $data) { throw 'WAV must contain fmt and data chunks' }
    if ($format.code -ne 1 -or $format.bits -ne 16) { throw 'Audio capture must use 16-bit integer PCM' }
    if ($format.sample_rate -le 0) { throw 'WAV sample rate must be positive' }
    if ($format.channels -notin 1, 2) { throw "Expected mono or stereo WAV; received $($format.channels) channels" }
    $expectedAlign = 2 * $format.channels
    if ($format.block_align -ne $expectedAlign) { throw 'Unexpected WAV block alignment' }
    if ($format.byte_rate -ne $format.sample_rate * $expectedAlign) { throw 'Unexpected WAV byte rate' }
    if ($data.Length -eq 0) { throw 'WAV contains no audio frames' }
    if (($data.Length % $expectedAlign) -ne 0) { throw 'WAV data does not end on a complete frame' }

    $frameCount = [int]($data.Length / $expectedAlign)
    $left = [double[]]::new($frameCount)
    $right = if ($format.channels -eq 2) { [double[]]::new($frameCount) } else { $null }
    for ($frame = 0; $frame -lt $frameCount; $frame++) {
      $offset = $frame * $expectedAlign
      $left[$frame] = [double][BitConverter]::ToInt16($data, $offset) / 32768.0
      if ($format.channels -eq 2) {
        $right[$frame] = [double][BitConverter]::ToInt16($data, $offset + 2) / 32768.0
      }
    }
    return [pscustomobject]@{
      SampleRate = [int]$format.sample_rate
      Channels = [int]$format.channels
      FrameCount = $frameCount
      DurationMs = 1000.0 * $frameCount / [double]$format.sample_rate
      Left = $left
      Right = $right
      Sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Get-SampleRms([double[]]$Samples, [int]$SampleRate, [double]$StartMs, [double]$EndMs) {
  if ($SampleRate -le 0 -or $StartMs -lt 0 -or $EndMs -le $StartMs) { throw 'Invalid RMS window' }
  $start = [Math]::Min($Samples.Length, [int][Math]::Floor($StartMs * $SampleRate / 1000.0))
  $end = [Math]::Min($Samples.Length, [int][Math]::Floor($EndMs * $SampleRate / 1000.0))
  if (($end - $start) -lt 1) { return 0.0 }
  $sum = 0.0
  for ($index = $start; $index -lt $end; $index++) { $sum += $Samples[$index] * $Samples[$index] }
  return [Math]::Sqrt($sum / ($end - $start))
}

Export-ModuleMember -Function Read-ArticulationWav,Get-SampleRms
