dofile('tests/bootstrap.lua')('acid')
local sequencer = require("model.sequencer")
local pattern = sequencer.new_pattern()
assert(pattern.length == 16)
assert(pattern.entry_mode == "original" and pattern.pitch_length == 16)
assert(pattern.playback == "loop")
assert(#pattern.pitch_events == 64 and #pattern.time_events == 0)
for i=1,64 do
  assert(pattern.pitch_events[i].note==36)
  assert(pattern.pitch_events[i].key==0 and pattern.pitch_events[i].octave==0)
  assert(not pattern.pitch_events[i].accent and not pattern.pitch_events[i].slide)
end
assert(sequencer.validate(pattern))
pattern.playback="one_shot"
assert(sequencer.validate(pattern))
pattern.playback="loop"
assert(sequencer.new_pattern(8).length == 8)
assert(not sequencer.validate({length = 17, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 65, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 16, pitch_events = {}}))
assert(sequencer.describe(pattern) == "Draft state: 16 original time slots, 16 active pitch entries, 64 stored pitch entries, 0 time events")

pattern.pitch_events[1] = sequencer.new_pitch(0,0,false,true)
pattern.pitch_events[2] = sequencer.new_pitch(0,1,true,false)
pattern.time_events = {"N", "T", "R"}
assert(sequencer.validate(pattern))
pattern.time_events[2] = "X"
assert(not sequencer.validate(pattern))
pattern.time_events[2] = "T"
pattern.pitch_events[1].note = 120
assert(not sequencer.validate(pattern))
pattern.pitch_events[1] = sequencer.new_pitch(0,0,false,true)
pattern.pitch_events[1].accent = 1
assert(not sequencer.validate(pattern))
pattern.pitch_events[1].accent = false
assert(sequencer.validate(pattern))
pattern.time_events[5] = "N" -- hole at 4 must not pass validation
assert(not sequencer.validate(pattern))

local extended=sequencer.new_pattern(64,"extended")
assert(extended.entry_mode=="extended" and extended.pitch_length==64)
assert(extended.playback=="loop")
assert(sequencer.validate(extended))
assert(not pcall(sequencer.new_pattern,17))
assert(not sequencer.set_entry_mode(extended,"original"))
assert(sequencer.set_pitch_length(extended,3))
assert(not sequencer.set_entry_mode(extended,"original"))
local source=sequencer.new_pattern(16)
assert(sequencer.set_time(source,1,"T")=="N")
assert(source.time_events[1]=="N")
assert(not sequencer.set_time(source,17,"N"))
assert(not sequencer.validate({length=16,pitch_events=pattern.pitch_events,
  time_events={},pitch_length=16,playback="one_shot"}))

print("ACID pitch/time memory checks passed")
