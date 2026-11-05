dofile('tests/bootstrap.lua')('digitaktsamplechain')
local options = require("chain_options")

local mode_labels = options.export_mode_labels()
assert(#mode_labels == 2 and mode_labels[1]:find("Grid") and mode_labels[2]:find("Concatenated"))

local mono_labels = options.mono_mode_labels()
assert(#mono_labels == 3 and mono_labels[1]:find("Average") and mono_labels[3]:find("Right"))

local slot_labels = options.slot_count_labels()
assert(#slot_labels == 5)
local expected_labels = { "4", "8", "16", "32", "64" }
for i, label in ipairs(expected_labels) do
  assert(slot_labels[i] == label, "slot label " .. i .. ": " .. tostring(slot_labels[i]))
end

assert(options.export_mode(1) == "spaced" and options.export_mode(2) == "chain")
assert(options.export_mode(3) == nil and options.export_mode(0) == nil)

assert(options.mono_mode(1) == "average" and options.mono_mode(2) == "left"
  and options.mono_mode(3) == "right" and options.mono_mode(4) == nil)

assert(options.slot_count(1) == 4 and options.slot_count(2) == 8
  and options.slot_count(3) == 16 and options.slot_count(4) == 32
  and options.slot_count(5) == 64 and options.slot_count(6) == nil)
for _, count in ipairs({ 4, 8, 16, 32, 64 }) do
  assert(options.is_grid_division(count))
end
assert(not options.is_grid_division(nil) and not options.is_grid_division(2))

local defaults = options.defaults()
assert(defaults.mode == "spaced" and defaults.mono == "average"
  and defaults.slot_count == 4 and defaults.fade == false
  and defaults.dither == false and defaults.zero_pad == false)

local valid, err = options.validate(defaults)
assert(valid and not err, tostring(err))
assert(valid.mode == "spaced" and valid.mono == "average" and valid.slot_count == 4)

assert(not options.validate({}))
assert(select(2, options.validate({ mode = "nope", mono = "average", fade = true, dither = false, zero_pad = false })):find("export mode"))
assert(select(2, options.validate({ mode = "spaced", mono = "sum", fade = true, dither = false, zero_pad = false })):find("mono"))
assert(select(2, options.validate({ mode = "spaced", mono = "average", slot_count = 0, fade = true, dither = false, zero_pad = false })):find("grid division"))
assert(select(2, options.validate({ mode = "spaced", mono = "average", slot_count = 2.5, fade = true, dither = false, zero_pad = false })):find("slot count"))
for _, invalid in ipairs({ math.huge, -math.huge, 0/0, "4", 30 }) do
  local input = options.defaults()
  input.slot_count = invalid
  assert(not options.validate(input))
end
assert(select(2, options.validate({ mode = "spaced", mono = "average", slot_count = 4, fade = 1, dither = false, zero_pad = false })):find("fade"))
local missing_division = options.defaults()
missing_division.slot_count = nil
assert(select(2, options.validate(missing_division)):find("grid division"))
local concatenated = options.defaults()
concatenated.mode = "chain"
concatenated.slot_count = nil
assert(options.validate(concatenated).slot_count == nil)
concatenated.slot_count = 64 -- Grid selection is irrelevant to Concatenated mode.
assert(options.validate(concatenated).slot_count == nil)
assert(options.validate(nil) == nil)

-- Validation returns an independent copy.
local source = { mode = "spaced", mono = "left", slot_count = 8, fade = true, dither = true, zero_pad = true }
local copy = assert(options.validate(source))
source.slot_count = 4
assert(copy.slot_count == 8)

print("DigitaktSampleChain chain_options spec passed")
