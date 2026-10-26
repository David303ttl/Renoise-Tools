dofile('tests/bootstrap.lua')('acid')
-- Run from repo root: texlua tests/acid/acid_sequencer_spec.lua
local sequencer = require("model.sequencer")
local pattern = sequencer.new_pattern()
assert(pattern.length == 16)
assert(#pattern.pitch_events == 64 and #pattern.time_events == 0)
for i=1,64 do
  assert(pattern.pitch_events[i].note==36)
  assert(pattern.pitch_events[i].key==0 and pattern.pitch_events[i].octave==0)
  assert(not pattern.pitch_events[i].accent and not pattern.pitch_events[i].slide)
end
assert(sequencer.validate(pattern))
assert(sequencer.new_pattern(8).length == 8)
assert(sequencer.validate({length = 17, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 65, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 16, pitch_events = {}}))
assert(sequencer.describe(pattern) == "Draft state: 16 time slots, 64 pitch entries, 0 time events")

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

print("ACID pitch/time memory checks passed")
