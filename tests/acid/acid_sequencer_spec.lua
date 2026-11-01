dofile('tests/bootstrap.lua')('acid')
local sequencer = require("model.sequencer")
local pattern = sequencer.new_pattern()
assert(pattern.length == 16)
assert(pattern.pitch_length == 16)
assert(#pattern.pitch_events == 32 and #pattern.time_events == 32)
for i=1,32 do assert(pattern.time_events[i]=="N") end
for i=1,32 do
  assert(pattern.pitch_events[i].note==36)
  assert(pattern.pitch_events[i].key==0 and pattern.pitch_events[i].octave==0)
  assert(not pattern.pitch_events[i].accent and not pattern.pitch_events[i].slide)
end
assert(sequencer.validate(pattern))
local fresh=sequencer.new_pattern()
assert(sequencer.same_source(pattern,fresh))
pattern.pitch_events[32]=sequencer.new_pitch(11,1,true,true)
pattern.time_events[32]="R"
pattern.timing_mode="triplet"
local frozen=sequencer.copy_source(pattern)
assert(sequencer.same_source(pattern,frozen),"copy preserves inactive canonical memories")
assert(not rawequal(pattern,frozen) and not rawequal(pattern.pitch_events,frozen.pitch_events)
  and not rawequal(pattern.pitch_events[32],frozen.pitch_events[32])
  and not rawequal(pattern.time_events,frozen.time_events),"source copies detach nested memories")
pattern.pitch_events[32].accent=false
pattern.time_events[32]="N"
assert(frozen.pitch_events[32].accent and frozen.time_events[32]=="R")
assert(fresh.pitch_events[32].note==36 and fresh.time_events[32]=="N"
  and fresh.timing_mode=="straight","new defaults do not share mutable memories")
pattern=sequencer.new_pattern()
local note_only=sequencer.new_pattern(1)
note_only.pitch_events[1]={note=36,accent=false,slide=false}
local note_only_ok,note_only_error=sequencer.validate(note_only)
assert(not note_only_ok and note_only_error:find("keyboard/octave",1,true))
local extra_field=sequencer.new_pattern(1)
extra_field.unused=true
assert(not sequencer.validate(extra_field))
assert(sequencer.new_pattern(8).length == 8)
assert(sequencer.new_pattern(32).length == 32)
assert(not pcall(sequencer.new_pattern,33))
local oversized=sequencer.new_pattern(1)
oversized.pitch_events[33]=sequencer.new_pitch(0,0)
assert(not sequencer.validate(oversized))
oversized=sequencer.new_pattern(1)
oversized.time_events[33]="N"
assert(not sequencer.validate(oversized))
assert(not pcall(sequencer.new_pattern,16,"extended"))
assert(not pcall(sequencer.new_pitch,0,0,1,false))
assert(not sequencer.validate({length = 17, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 33, pitch_events = {}, time_events = {}}))
assert(not sequencer.validate({length = 16, pitch_events = {}}))

pattern.pitch_events[1] = sequencer.new_pitch(0,0,false,true)
pattern.pitch_events[2] = sequencer.new_pitch(0,1,true,false)
pattern.time_events[1],pattern.time_events[2],pattern.time_events[3]="N","T","R"
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
pattern.time_events[4] = nil -- a hole in TIME memory must not pass validation
assert(not sequencer.validate(pattern))
pattern.time_events[4] = "N"
assert(sequencer.validate(pattern))

local extended=sequencer.new_pattern(32)
assert(extended.pitch_length==16 and sequencer.validate(extended))
assert(sequencer.set_pitch_length(extended,3))
local source=sequencer.new_pattern(16)
for step=1,sequencer.MAX_STEPS do
  assert(sequencer.is_leading_tie(step,"T")==(step==1))
  for _,command in ipairs({"N","T","R"}) do
    assert(sequencer.normalize_time_entry(step,command)==
      (step==1 and command=="T" and "N" or command))
  end
end
assert(not sequencer.normalize_time_entry(0,"N"))
assert(not sequencer.normalize_time_entry(1.5,"N"))
assert(not sequencer.normalize_time_entry(0/0,"N"))
source.time_events[1]="T"
local leading_ok,leading_error=sequencer.validate(source)
assert(not leading_ok and leading_error=="leading TIE must be entered as NOTE")
assert(sequencer.set_time(source,1,"T")=="N")
assert(source.time_events[1]=="N")
assert(not sequencer.set_time(source,17,"N"))
source.time_events[17]="R"
source.length=17
assert(source.time_events[17]=="R" and sequencer.validate(source))
source.length=16
assert(source.time_events[17]=="R" and sequencer.validate(source))

print("ACID pitch/time memory checks passed")
