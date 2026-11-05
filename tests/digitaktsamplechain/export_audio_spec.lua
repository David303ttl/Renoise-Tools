dofile('tests/bootstrap.lua')('digitaktsamplechain')
local runner = require('export_runner')
local settings = require('chain_options')
local host = require('host_stub')
local RATE, HEADER_BYTES, PCM_SCALE = 48000, 44, 32768
local MAX_TICKS = 100

local function uint(bytes, offset, count)
  local value = 0
  for index = offset + count - 1, offset, -1 do value = value * 256 + bytes:byte(index) end
  return value
end

local function decode(bytes)
  assert(bytes:sub(1, 4) == 'RIFF' and bytes:sub(9, 12) == 'WAVE')
  assert(uint(bytes, 5, 4) == #bytes - 8)
  assert(uint(bytes, 21, 2) == 1 and uint(bytes, 23, 2) == 1)
  assert(uint(bytes, 25, 4) == RATE and uint(bytes, 35, 2) == 16)
  assert(uint(bytes, 41, 4) == #bytes - HEADER_BYTES)
  local frames = {}
  for offset = HEADER_BYTES + 1, #bytes, 2 do
    local value = uint(bytes, offset, 2)
    frames[#frames + 1] = value >= PCM_SCALE and value - 2 * PCM_SCALE or value
  end
  return frames
end

local function export(source, options)
  local tool = host.host(source)
  local path = host.temp_path()
  local result, failure
  local job = assert(runner.start(source, options, path, {
    on_finish = function(info) result = info end,
    on_error = function(err) failure = err end,
  }))
  local temporary = job.output.temporary
  local ticks = 0
  while next(tool.timers) do
    next(tool.timers)()
    ticks = ticks + 1
    assert(ticks < MAX_TICKS, 'export did not terminate')
  end
  assert(job.finished and result and not failure, failure)
  local bytes = host.read_file(path)
  assert(os.remove(path))
  assert(not io.exists(temporary), 'staging file leaked')
  return decode(bytes), result, bytes
end

-- Decode every frame, including padding and unused fixed slots, independently
-- of the layout and PCM encoder implementations.
for _, mode in ipairs({ 'chain', 'spaced' }) do
  local division_choices = mode == 'spaced' and { 4, 8, 16, 32, 64 } or { 4 }
  for _, divisions in ipairs(division_choices) do
    for _, padded in ipairs({ false, true }) do
      for _, mono in ipairs({ 'average', 'left', 'right' }) do
        local source = host.instrument({
          host.buffer(3, RATE, 1, function(_, frame) return frame / 8 end),
          host.buffer(5, RATE, 2, function(channel, frame)
            return (channel == 1 and frame or -frame / 2) / 8
          end),
        })
        local options = settings.defaults()
        options.mode, options.mono, options.zero_pad = mode, mono, padded
        options.slot_count = divisions
        local pcm, info = export(source, options)
        local edge = mode == 'spaced' and padded and 64 or 0
        local width = 5 + 2 * edge
        local count = mode == 'chain' and 2 or divisions
        local expected = mode == 'chain' and 8 or count * width
        assert(#pcm == expected and info.frames == expected and info.slot_count == count)
        assert(info.total_sec == expected / RATE)
        assert(info.slot_sec == (mode == 'chain' and 4 or width) / RATE)
        for frame = 1, expected do
          local slot, position
          if mode == 'chain' then
            slot, position = frame <= 3 and 1 or 2, frame <= 3 and frame or frame - 3
          else
            slot = math.floor((frame - 1) / width) + 1
            position = (frame - 1) % width + 1 - edge
          end
          local value = 0
          if slot == 1 and position >= 1 and position <= 3 then value = position / 8 end
          if slot == 2 and position >= 1 and position <= 5 then
            value = position / 8 * (mono == 'left' and 1 or mono == 'right' and -0.5 or 0.25)
          end
          assert(pcm[frame] == value * PCM_SCALE, 'incorrect audio or slot boundary')
        end
      end
    end
  end
end

-- Empty slots are skipped; populated sample buffers, including slice aliases,
-- retain instrument order rather than being reordered by marker position.
do
  local source = host.instrument({ host.buffer(0), host.buffer(2, RATE, 1,
    function() return 0.5 end), host.buffer(0), host.buffer(1, RATE, 1,
    function() return -0.25 end) })
  source.samples[2].slice_markers = { 2 }
  source.samples[4].is_slice_alias = true
  local options = settings.defaults()
  options.mode = 'chain'
  local pcm = export(source, options)
  assert(#pcm == 3 and pcm[1] == 16384 and pcm[2] == 16384 and pcm[3] == -8192)
end

for _, length in ipairs({ 1, 2, 3 }) do
  for _, mode in ipairs({ 'chain', 'spaced' }) do
    for _, dither in ipairs({ false, true }) do
      local source = host.instrument({ host.buffer(length, RATE, 1, function() return 0.5 end) })
      local options = settings.defaults()
      options.mode, options.fade, options.dither = mode, true, dither
      local pcm, _, first = export(source, options)
      local _, _, second = export(source, options)
      assert(first == second, 'unchanged export must be byte-identical')
      for frame = 1, length do
        local expected = length == 1 and 0 or 16384 * (length - frame) / (length - 1)
        assert(math.abs(pcm[frame] - expected) <= (dither and 1 or 0))
      end
      assert(pcm[length] == 0, 'fade must end in digital silence')
    end
  end
end

-- Numerical pitch and alias checks use decoded output, including quantization.
local RATES, DEPTHS = { 44100, 48000, 96000, 192000 }, { 16, 24, 32, 16 }
local DURATION, TONE_HZ, LEVEL = 0.05, 1000, 0.5
local OUTPUT_LENGTH = RATE * DURATION
for _, alias in ipairs({ false, true }) do
  local buffers, originals = {}, {}
  for index, rate in ipairs(RATES) do
    local frequency = alias and rate > RATE and 36000 or TONE_HZ
    local values = {}
    for frame = 1, rate * DURATION do
      values[frame] = LEVEL * math.sin(2 * math.pi * frequency * (frame - 1) / rate)
    end
    originals[index] = values
    local buffer = host.buffer(#values, rate, 1, function(_, frame) return values[frame] end)
    buffer.bit_depth = DEPTHS[index]
    buffer.set_sample_data = function() error('source audio was modified') end
    buffers[index] = buffer
  end
  local options = settings.defaults()
  options.mode = 'chain'
  local pcm, info = export(host.instrument(buffers), options)
  assert(#pcm == #RATES * OUTPUT_LENGTH and info.total_sec == #RATES * DURATION)
  for index, buffer in ipairs(buffers) do
    local energy = 0
    for frame = 200, OUTPUT_LENGTH - 200 do
      local actual = pcm[(index - 1) * OUTPUT_LENGTH + frame] / PCM_SCALE
      local expected = alias and RATES[index] > RATE and 0 or
        LEVEL * math.sin(2 * math.pi * TONE_HZ * (frame - 1) / RATE)
      energy = energy + (actual - expected) ^ 2
    end
    assert(math.sqrt(energy / (OUTPUT_LENGTH - 399)) < 0.002, 'pitch or alias suppression failed')
    assert(buffer.sample_rate == RATES[index] and buffer.bit_depth == DEPTHS[index])
    assert(buffer.number_of_frames == #originals[index] and buffer.number_of_channels == 1)
    for frame, value in ipairs(originals[index]) do
      assert(buffer:sample_data(1, frame) == value, 'source audio changed')
    end
  end
end
print('DigitaktSampleChain decoded export geometry, fades, ordering and mixed-rate audio specs passed')
