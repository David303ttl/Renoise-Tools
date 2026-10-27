dofile("tests/bootstrap.lua")("acid")
local memory=require("model.memory_status")
local ownership=require("writers.phrase_ownership")
local seq=require("model.sequencer")
local state=seq.new_pattern(8,"extended")
state.pitch_length=2
state.pitch_events[1]={note=36,accent=false,slide=true}
state.pitch_events[2]={note=39,accent=true,slide=false}
state.time_events={"N","T","N","R","N","N","T","R"}
local m=memory.inspect(state)
assert(m.length==8 and m.notes==4 and m.ties==2 and m.rests==2)
assert(m.missing_time==0 and m.pitch_count==64 and m.pitch_length==2 and m.next_pitch==1)
assert(m.time_text=="N T N R N N T R")
local p={name="",number_of_lines=2,visible_note_columns=1,visible_effect_columns=0,lpb=8,looping=false,loop_start=1,loop_end=2,playback_mode=1,key_tracking=1,lines={}}
function p:column_is_muted()return false end
p.lines[1]={note_columns={{note_value=36,instrument_value=255,volume_value=255,panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}}}
p.lines[2]={note_columns={{note_value=121,instrument_value=255,volume_value=255,panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}}}
function p:line(i)return self.lines[i] end
assert(ownership.status(p)=="foreign")
p.name=assert(ownership.make_name(p,1))
assert(ownership.status(p)=="owned")
p.lines[1].note_columns[1].note_value=39
assert(ownership.status(p)=="modified")
p.name="ACID 0.1 TEST"
assert(ownership.status(p)=="foreign")
print("ACID ownership and memory status checks passed")
