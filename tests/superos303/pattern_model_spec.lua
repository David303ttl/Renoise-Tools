-- Offline SuperOS-303 pattern and poly codec regressions.
assert(dofile("tests/bootstrap.lua")("superos303"))
local C = require("constants")
local p = require("protocol")
local model = require("pattern_model")
local function eq(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end

local raw = {}
for i = 1, C.PATTERN_SIZE do raw[i] = 0 end
raw[1], raw[2], raw[33], raw[52] =
  p.pitch(2, 1, true, false), p.pitch(5, 2, false, true), 1 + 4 * 2 + 16, 16
local mono = {type = "pattern", raw = raw, length = 16, pattern = 4, variation = 1}
eq(model.step_label(mono, 0), "01 D0  A")
eq(model.step(mono, 1).time, 2)
eq(model.step(mono, 2).semitone, 5)

local new_raw = model.with_step(mono, 2, 1, p.pitch(10, 1, false, false))
eq(new_raw[2], p.pitch(10, 1, false, false))
eq(raw[2], p.pitch(5, 2, false, true)) -- no mutation of received snapshot

new_raw = model.with_metadata(mono, 3, true, -7)
eq(new_raw[41], 11)
eq(new_raw[50], 249)
local updated = {type = "pattern", raw = new_raw, length = 16}
eq(model.metadata(updated).transpose, -7)
eq(model.metadata(updated).direction, 3)
assert(model.metadata(updated).triplet)
local impossible, issue = model.with_metadata(mono, 0, true, 0)
assert(impossible ~= nil) -- 16 steps still valid for triplets
local long = {type = "pattern", raw = raw, length = 32}
assert(model.with_metadata(long, 0, true, 0) == nil)
local setscale = model.with_scale(mono, 4095, true)
local scale = model.scale({type = "pattern", raw = setscale})
eq(scale.mask, 4095)
assert(scale.enabled)
eq(raw[42], 0)

local masked = {}
for i, byte in ipairs(raw) do masked[i] = byte end
masked[43] = 0x70 -- stale non-scale bits must not survive the firmware's scale setter
local normalized = model.with_scale({type = "pattern", raw = masked}, 0xABC, true)
eq(normalized[42], 0xBC)
eq(normalized[43], 0x8A)
eq(model.preset_mask(0, 4), 1193) -- C minor pentatonic
eq(model.preset_mask(2, 4), 677) -- D minor pentatonic

local body = p.write_blob(mono, new_raw)
eq(body[2], C.COMMAND.WRITE_BLOB)
eq(body[#body], 1)
eq(#body, 5 + C.PACKED_PATTERN_SIZE + 1)

local function reply(command, pattern, source)
  local xor = p.checksum(source)
  local result = {0x7D, command, pattern, xor % 128, math.floor(xor / 128)}
  for _, value in ipairs(p.pack7(source)) do result[#result + 1] = value end
  return p.frame(result)
end
local parsed = assert(p.decode(reply(0x11, 4, new_raw)))
eq(parsed.type, "pattern")
eq(parsed.variation, 0)

local poly_raw = {}
for i = 1, C.POLY_SIZE do poly_raw[i] = 0 end
poly_raw[1] = 0x10 -- voice 1 = C0, low two bits of voice 2
poly_raw[2] = 0xF8 -- voice 2 = C1, voice 3 = empty
poly_raw[3] = 0xFF -- voice 3 and 4 = empty
poly_raw[97] = 1
poly_raw[105] = 1
poly_raw[109] = 1
poly_raw[113] = 1
poly_raw[115] = 16
local poly = assert(p.decode(reply(0x25, 4, poly_raw)))
eq(poly.type, "poly")
eq(poly.length, 16)
local chord = model.poly_step(poly, 0)
eq(chord.time, 1)
eq(chord.voices[1], 0x10)
eq(chord.voices[2], 0x20)
assert(chord.accent and chord.slide)

local wire = model.with_poly_step(poly, 0, 1, {0x10, 0x20, 63, 63}, true, false)
eq(wire[2], 0x27)
eq(wire[10], 1)
local damaged = {}
for i, value in ipairs(poly_raw) do damaged[i] = value end
damaged[115] = 33
local invalid, err = p.decode(reply(0x25, 4, damaged))
assert(invalid == nil and err == "invalid poly pattern size")

local prob_raw = {}
for i = 1, C.PROBABILITY_SIZE do prob_raw[i] = 0 end
prob_raw[1], prob_raw[2], prob_raw[3] = 13 + 8 * 16, 2 + 10 * 16, 1
local probability = assert(p.decode(reply(C.COMMAND.PROBABILITY_REPLY, 4, prob_raw)))
eq(probability.type, "probability")
local values = model.probability(probability.raw, 0)
eq(values.accent, 13)
eq(values.slide, 8)
eq(values.down, 2)
eq(values.up, 10)
assert(values.double)
local prob_write = p.write_probability(4, 0, 13, 8, 2, 10, true)
eq(prob_write[2], C.COMMAND.PROBABILITY)
eq(prob_write[8], 3) -- both nibble bytes carry bit 7
print("SuperOS-303 extended pattern protocol tests passed")
