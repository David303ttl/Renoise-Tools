dofile('tests/bootstrap.lua')('digitaktsamplechain')
local resampler = require("resampler")
local function tone(frequency, rate)
  return function(frame) return math.sin(2 * math.pi * frequency * (frame - 1) / rate) end
end
for _, rate in ipairs({ 22050, 44100, 88200, 96000, 192000 }) do
  local read = resampler.reader(tone(1000, rate), rate, rate, 48000)
  local expected = tone(1000, 48000)
  local error_sum = 0
  for frame = 1000, 2000 do error_sum = error_sum + (read(frame) - expected(frame)) ^ 2 end
  assert(math.sqrt(error_sum / 1001) < 0.002, "pitch or amplitude changed")
end
local read = resampler.reader(tone(36000, 96000), 96000, 96000, 48000)
local energy = 0
for frame = 1000, 2000 do energy = energy + read(frame) ^ 2 end
assert(math.sqrt(energy / 1001) < 0.001, "downsampling must suppress aliasing")
for _, rate in ipairs({ 8000, 44100, 96000, 192000 }) do
  local length = resampler.frame_count(1, rate, 48000)
  local short = resampler.reader(function(frame) assert(frame == 1); return 0.7 end, 1, rate, 48000)
  for frame = 1, length do assert(math.abs(short(frame) - 0.7) < 1e-10) end
end
local original = function(frame) return frame end
assert(resampler.reader(original, 10, 48000, 48000) == original)
print("DigitaktSampleChain resampling duration, pitch and anti-alias specs passed")
