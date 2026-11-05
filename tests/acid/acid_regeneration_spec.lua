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
local MAX_LINES=2
renoise={InstrumentPhrase={MAX_NUMBER_OF_LINES=MAX_LINES,
  MAX_NUMBER_OF_NOTE_COLUMNS=12,MAX_NUMBER_OF_EFFECT_COLUMNS=8}}
local p=dofile('tests/acid/complete_phrase_fixture.lua')({max_lines=MAX_LINES,number_of_lines=MAX_LINES})
p.name=''
p.lines[1].note_columns[1].note_value=36
assert(ownership.status(p)=="foreign")
p.name=assert(ownership.make_name_from_verified_snapshot(assert(ownership.snapshot(p)),1))
assert(ownership.status(p)=="owned")
p.lines[1].note_columns[1].note_value=39
assert(ownership.status(p)=="modified")
p.name="ACID 0.1 TEST"
assert(ownership.status(p)=="foreign")
print("ACID ownership and cycle state checks passed")
