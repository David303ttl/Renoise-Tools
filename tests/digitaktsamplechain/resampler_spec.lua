dofile('tests/bootstrap.lua')('digitaktsamplechain')
local resampler = require("resampler")
local OUTPUT_RATE, DOWNSAMPLE_RATE = 48000, 96000
local TONE_SOURCE_FRAMES, ALIAS_SOURCE_FRAMES = 20000, 96000
local MEASURE_FIRST_FRAME, MEASURE_LAST_FRAME = 1000, 2000
local MEASURE_FRAMES = MEASURE_LAST_FRAME - MEASURE_FIRST_FRAME + 1
local TEST_PHASE_RADIANS, DC_VALUE = 0.37, 0.7
local SINC_ZERO_TOLERANCE, SYMMETRY_TOLERANCE, DC_TOLERANCE = 1e-12, 1e-12, 1e-10
local PASSBAND_RMS_TOLERANCE, ALIAS_RMS_TOLERANCE = 0.002, 0.001
local IMPULSE_TOLERANCE = 0.003
local function sinc(value)
  return math.abs(value) < SINC_ZERO_TOLERANCE and 1 or math.sin(math.pi * value) / (math.pi * value)
end

local function assert_tone(source_rate, frequency)
  local source = function(frame)
    return math.sin(2 * math.pi * frequency * (frame - 1) / source_rate + TEST_PHASE_RADIANS)
  end
  local read = resampler.reader(source, TONE_SOURCE_FRAMES, source_rate, OUTPUT_RATE)
  local error_sum = 0
  for frame = MEASURE_FIRST_FRAME, MEASURE_LAST_FRAME do
    local expected = math.sin(2 * math.pi * frequency * (frame - 1) / OUTPUT_RATE + TEST_PHASE_RADIANS)
    error_sum = error_sum + (read(frame) - expected) ^ 2
  end
  assert(math.sqrt(error_sum / MEASURE_FRAMES) < PASSBAND_RMS_TOLERANCE,
    "pass-band tone changed pitch or amplitude")
end

for _, rate in ipairs({ 22050, 44100, 88200, 96000, 192000 }) do
  assert_tone(rate, 997)
end
for _, rate in ipairs({ 44100, 96000, 192000 }) do
  assert_tone(rate, 6000)
end

local impulse = resampler.reader(function(frame) return frame == 80 and 1 or 0 end,
  160, DOWNSAMPLE_RATE, OUTPUT_RATE)
for offset, distance in ipairs({ 3, 1, 1, 3 }) do
  local frame = 38 + offset
  local expected = 0.5 * sinc(distance * 0.5)
  assert(math.abs(impulse(frame) - expected) < IMPULSE_TOLERANCE,
    "decimation impulse response differs from ideal low-pass reference")
end
assert(math.abs(impulse(39) - impulse(42)) < SYMMETRY_TOLERANCE, "impulse response must be symmetric")
assert(math.abs(impulse(40) - impulse(41)) < SYMMETRY_TOLERANCE, "impulse response must be symmetric")

for _, frequency in ipairs({ 30000, 36000, 42000 }) do
  local source = function(frame)
    return math.sin(2 * math.pi * frequency * (frame - 1) / DOWNSAMPLE_RATE + TEST_PHASE_RADIANS)
  end
  local read = resampler.reader(source, ALIAS_SOURCE_FRAMES, DOWNSAMPLE_RATE, OUTPUT_RATE)
  local energy = 0
  for frame = MEASURE_FIRST_FRAME, MEASURE_LAST_FRAME do energy = energy + read(frame) ^ 2 end
  assert(math.sqrt(energy / MEASURE_FRAMES) < ALIAS_RMS_TOLERANCE,
    "downsampling must suppress out-of-band aliases")
end

for _, test in ipairs({
  { source_rate = 8000, output_frames = 18 },
  { source_rate = 44100, output_frames = 3 },
  { source_rate = 96000, output_frames = 2 },
  { source_rate = 192000, output_frames = 1 },
}) do
  assert(resampler.frame_count(3, test.source_rate, OUTPUT_RATE) == test.output_frames,
    "output frame count must round duration to the nearest frame")
  local edge = resampler.reader(function(frame)
    assert(frame >= 1 and frame <= 3, "resampler read outside source endpoints")
    return DC_VALUE
  end, 3, test.source_rate, OUTPUT_RATE)
  for frame = 1, test.output_frames do
    assert(math.abs(edge(frame) - DC_VALUE) < DC_TOLERANCE, "constant endpoint extension must preserve DC")
  end
  local single = resampler.reader(function(frame) assert(frame == 1); return DC_VALUE end,
    1, test.source_rate, OUTPUT_RATE)
  for frame = 1, resampler.frame_count(1, test.source_rate, OUTPUT_RATE) do
    assert(math.abs(single(frame) - DC_VALUE) < DC_TOLERANCE, "single-frame source must preserve DC")
  end
end

local original = function(frame) return frame end
assert(resampler.reader(original, 10, OUTPUT_RATE, OUTPUT_RATE) == original)
print("DigitaktSampleChain resampler analytical reference specs passed")
