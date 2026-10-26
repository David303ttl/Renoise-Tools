-- Run at repository root: lua tests/acid/acid_sequencer_spec.lua
dofile("tests/bootstrap.lua")("acid")
local sequencer = require("model.sequencer")

local pattern = sequencer.new_pattern()
assert(pattern.length == 16)
assert(#pattern.pitch_events == 0 and #pattern.time_events == 0)
assert(sequencer.validate(pattern))
assert(sequencer.new_pattern(8).length == 8)
assert(not sequencer.validate({length = 17, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 16, pitch_events = {}}))
assert(sequencer.describe(pattern) == "Draft state: 16 time slots, 0 pitch entries, 0 time events")

print("ACID draft-state checks passed")
