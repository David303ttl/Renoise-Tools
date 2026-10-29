dofile("tests/bootstrap.lua")("acid")
local compiler=require("model.cycle_interpreter")
local articulation=require("model.articulation")
local seq=require("model.sequencer")
local pitch=dofile("tests/acid/pitch_fixture.lua")
local pattern=seq.new_pattern(4)
pattern.pitch_length=2
pattern.pitch_events[1]=pitch(36,false,true);pattern.pitch_events[2]=pitch(39)
for i,command in ipairs({"N","N","N","R"}) do pattern.time_events[i]=command end
local plan=assert(compiler.compile_cycle(pattern))
local cells={}
for i=1,16 do cells[i]={note_value=121,effect_number_value=0,effect_amount_value=0} end
cells[1].note_value=36
cells[5].note_value=39
cells[9].note_value=36
cells[13].note_value=120
-- Simulate a gate-off placed by the gate renderer at the glide's
-- required continuation position.
cells[7].note_value=120
local phrase={}
function phrase:line(i)return {note_columns={cells[i]}}end
local result,err=articulation.apply(phrase,plan,4,12,{output_policy="play_once"})
assert(not result and err:find("contradictory gate/glide operations",1,true),err)
assert(cells[7].note_value==120 and cells[7].effect_amount_value==0)
assert(cells[5].effect_number_string==nil)
-- A shorter glide leaves the midpoint free; foreign content on its continuation
-- is then reported at the continuation line without mutating the phrase.
cells[6].note_value=40
cells[7].note_value=121
cells[5].effect_number_value=0
cells[5].effect_number_string=nil
cells[5].effect_amount_value=0
local blocked,diagnostic=articulation.apply(phrase,plan,4,0x20,{output_policy="play_once"})
assert(not blocked)
assert(diagnostic:find("TIME step 02",1,true),diagnostic)
assert(diagnostic:find("cycle 1, phrase line 0x05",1,true),diagnostic)
assert(cells[5].effect_number_value==0)
assert(cells[5].effect_number_string==nil)
assert(cells[5].effect_amount_value==0)
print("ACID slide/gate overlap diagnostic checks passed")
