-- Protocol tests run without Renoise, MIDI ports or hardware.
assert(dofile("tests/bootstrap.lua")("superos303"))
local p = require("protocol")
local function eq(a, b, label)
  assert(a == b, (label or "mismatch") .. ": " .. tostring(a) .. " vs " .. tostring(b))
end

local original = {}
for i = 1, 60 do original[i] = (i * 29 + 201) % 256 end
original[52] = 16
original[41] = 0
local packed = p.pack7(original)
eq(#packed, 69, "packed length")
local decoded = assert(p.unpack7(packed, 60))
for i = 1, 60 do eq(decoded[i], original[i], "roundtrip byte " .. i) end

local sum = p.checksum(original)
local msg = {0x7D, 0x11, 3, sum % 128, math.floor(sum / 128)}
for _, v in ipairs(packed) do msg[#msg + 1] = v end
msg[#msg + 1] = 1
local event = assert(p.decode(p.frame(msg)))
eq(event.type, "pattern")
eq(event.pattern, 3)
eq(event.variation, 1)
eq(event.length, 16)

for _, index in ipairs({6, 7}) do
  local saved = msg[index]
  -- Flip one bit: multiple MSB flips can cancel in the XOR checksum.
  msg[index] = saved + (saved % 2 == 0 and 1 or -1)
  local invalid, err = p.decode(p.frame(msg))
  assert(invalid == nil, "corrupted packed byte " .. index .. " must be rejected")
  eq(err, "checksum mismatch", "corrupted packed byte " .. index)
  msg[index] = saved
end
local short = assert(p.decode({0xF0, 0x7D, 0x21, 1, 3, 0, 8, 2, 3, 0xF7}))
eq(short.type, "config")
eq(short.var3_channel, 3)

local active = assert(p.decode(p.frame({0x7D, 0x1E, 8, 2})))
eq(active.type, "active")
eq(active.pattern, 8)
eq(active.group, 2)
local position = assert(p.decode(p.frame({0x7D, 0x15, 8, 17, 2})))
eq(position.type, "position")
eq(position.step, 17)
eq(position.group, 2)
for _, body in ipairs({
  {0x7D, 0x15, 8, 0}, {0x7D, 0x15, 8, 32, 2},
  {0x7D, 0x15, 8, 0, 4}, {0x7D, 0x1E, 8, 4}
}) do
  local invalid, issue = p.decode(p.frame(body))
  assert(invalid == nil)
  eq(issue, "invalid pattern selection")
end

for _, edit in ipairs({
  {{0x7D, 0x16, 0, 0, 0, 0, 1}, 0},
  {{0x7D, 0x16, 0, 0, 0, 0, 1, 1}, 1},
  {{0x7D, 0x18, 0, 8, 2}, 2},
  {{0x7D, 0x28, 0, 0, 2}, 0},
  {{0x7D, 0x29, 0, 1}, 2},
  {{0x7D, 0x2A, 0, 0, 0, 1, 1}, 1}
}) do
  local changed = assert(p.decode(p.frame(edit[1])))
  eq(changed.type, "changed")
  eq(changed.variation, edit[2], "hardware edit variation")
end
for _, body in ipairs({{0x7D, 0x16}, {0x7D, 0x16, 0, 0, 0, 0, 1, 3}}) do
  local invalid, issue = p.decode(p.frame(body))
  assert(invalid == nil)
  eq(issue, "invalid hardware edit")
end

local cfg = p.write_config({flags = 12, direction = 2},
  {channel = 0, clock = true, thru = false,
   brightness = 8, var2_channel = 5, var3_channel = 6})
eq(cfg[4], 13, "preserve disabled SysEx flags")
eq(cfg[3], 0, "omni channel")
local write = p.write_step(3, 0, 1, p.pitch(12, 3, true, true))
eq(write[5], 124, "pitch low 7")
eq(write[6], 1, "pitch high 1")
eq(write[7], 1, "time note")

local pattern = {raw = {}, length = 4}
for i = 1, 60 do pattern.raw[i] = 0 end
pattern.raw[1] = p.pitch(2, 1, true, false)
pattern.raw[2] = p.pitch(5, 2, false, true)
pattern.raw[33] = 1 + 2 * 4 + 1 * 16 -- NOTE TIE NOTE REST
pattern.raw[53] = 2 * 16
local first = p.step(pattern, 0)
eq(first.semitone, 2)
assert(first.accent)
local tie = p.step(pattern, 1)
eq(tie.time, 2)
local third = p.step(pattern, 2)
eq(third.semitone, 5)
assert(third.slide)
eq(third.ratchet, 2)

local ok = pcall(function() p.write_length(0, 25, true) end)
assert(not ok, "triplet length 25 must fail")
ok = pcall(function() p.frame({0x7D, 0x4A}) end)
assert(ok, "generic framer deliberately does not choose opcodes")
print("SuperOS-303 protocol spec passed")
