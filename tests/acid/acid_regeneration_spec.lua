dofile("tests/bootstrap.lua")("acid")
local interpreter=require("model.cycle_interpreter")
local ownership=require("renoise.phrase_ownership")
local seq=require("model.sequencer")
local pitch=dofile("tests/acid/pitch_fixture.lua")
local state=seq.new_pattern(8)
state.pitch_length=2
state.pitch_events[1]=pitch(36,false,true)
state.pitch_events[2]=pitch(39,true,false)
for i,command in ipairs({"N","T","N","R","N","N","T","R"}) do state.time_events[i]=command end
local plan,exit=assert(interpreter.compile_cycle(state))
assert(plan.length==8 and plan.note_count==4 and plan.pitch_length==2)
local kinds={"note","tie","note","rest","note","note","tie","rest"}
local pitches={1,1,2,false,1,2,2,false}
for step,event in ipairs(plan.steps) do
  assert(event.kind==kinds[step] and event.pitch_index==(pitches[step] or nil))
end
assert(exit.next_pitch==1 and exit.voice==nil)
state.time_events[4]=nil
assert(not interpreter.compile_cycle(state),"incomplete time memory must reject compilation")
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
print("ACID ownership and cycle state checks passed")
