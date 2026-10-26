-- Run from repo root: texlua tests/tb303_sequencer_spec.lua
local sequencer = dofile("com.david303ttl.TB303.xrnx/sequencer.lua")

local pattern = sequencer.new_pattern()
assert(pattern.length == 16)
assert(#pattern.pitch_events == 0 and #pattern.time_events == 0)
assert(sequencer.validate(pattern))
assert(sequencer.new_pattern(8).length == 8)
assert(not sequencer.validate({length = 17, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 16, pitch_events = {}}))
assert(sequencer.describe(pattern) == "Draft state: 16 time slots, 0 pitch entries, 0 time events")

pattern.pitch_events = {{note=36, slide=true}, {note=48, accent=true}}
pattern.time_events = {"N", "T", "R"}
assert(sequencer.validate(pattern))
pattern.time_events[2] = "X"
assert(not sequencer.validate(pattern))
pattern.time_events[2] = "T"
pattern.pitch_events[1].note = 120
assert(not sequencer.validate(pattern))
pattern.pitch_events[1].note = 36
pattern.pitch_events[1].accent = 1
assert(not sequencer.validate(pattern))
pattern.pitch_events[1].accent = false
assert(sequencer.validate(pattern))
pattern.time_events[5] = "N" -- hole at 4 must not pass validation
assert(not sequencer.validate(pattern))

print("TB303 pitch/time memory checks passed")
