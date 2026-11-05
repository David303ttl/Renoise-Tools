dofile('tests/bootstrap.lua')('digitaktsamplechain')
local extractor = require("sample_extractor")
local host = require("host_stub")

local buffer = host.buffer(3, 48000, 2, function(channel, frame)
  return channel == 1 and frame / 10 or -frame / 20
end)
local snapshot = assert(extractor.snapshot(host.instrument({ buffer })))
assert(snapshot.rate == 48000 and #snapshot.buffers == 1)
assert(buffer.reads == 0, "metadata discovery must not copy audio")
local entry = snapshot.buffers[1]
assert(extractor.reader(entry, "left")(2) == 0.2)
assert(extractor.reader(entry, "right")(2) == -0.1)
assert(extractor.reader(entry, "average")(2) == 0.05)

local mono = assert(extractor.snapshot(host.instrument({ host.buffer(3) }))).buffers[1]
for _, mode in ipairs({ "left", "right", "average" }) do
  assert(extractor.reader(mono, mode)(1) == 0.25)
end
local empty = setmetatable({ has_sample_data = false }, {
  __index = function() error("accessed an invalid empty-buffer property") end,
})
local usable = assert(extractor.snapshot(host.instrument({ empty, buffer })))
assert(#usable.buffers == 1 and usable.buffers[1].frames == 3)
local none, err = extractor.snapshot(host.instrument({ empty }))
assert(not none and err:find("no sample data"))
none, err = extractor.snapshot(host.instrument({}))
assert(not none and err:find("no samples"))
assert(not extractor.snapshot(nil))

for _, rate in ipairs({ 8000, 22050, 44100, 88200, 96000, 192000 }) do
  local converted = assert(extractor.snapshot(host.instrument({ host.buffer(rate, rate) })))
  local source = converted.buffers[1]
  assert(source.frames == rate and source.output_frames == 48000)
  assert(math.abs(extractor.reader(source, "average")(24000) - 0.25) < 1e-10)
end
local mixed = assert(extractor.snapshot(host.instrument({ buffer, host.buffer(2, 44100) })))
assert(#mixed.buffers == 2 and mixed.buffers[2].source_rate == 44100)
local invalid, why = extractor.snapshot(host.instrument({ host.buffer(2, 48000, 3) }))
assert(not invalid and why:find("invalid audio buffer"))
print("DigitaktSampleChain source metadata and mono streaming specs passed")
