dofile('tests/bootstrap.lua')('acid')
local engine=require("model.cycle_interpreter")
local art=require("model.articulation")
local seq=require("model.sequencer")
local p=seq.new_pattern(8,"extended")
p.pitch_length=4
p.pitch_events[1]={note=36,slide=true};p.pitch_events[2]={note=43}
p.pitch_events[3]={note=39};p.pitch_events[4]={note=41}
p.time_events={"N","T","N","R","N","N","T","R"}
local plan=assert(engine.compile_cycle(p))
local commands=assert(art.plan(plan,2,0x20))
assert(#commands==2 and commands[1].line==5 and commands[2].line==6)
local cells={}
for i=1,16 do cells[i]={note_value=121,effect_number_value=0,effect_amount_value=0} end
for i,v in pairs({[1]=36,[5]=43,[7]=120,[9]=39,[11]=41,[15]=120}) do
 cells[i].note_value=v
end
local phrase={number_of_lines=16}
function phrase:line(i)return {note_columns={cells[i]}}end
local result,err=art.apply(phrase,plan,2,0x20,true)
assert(result,err)
assert(result.slide_count==1)
assert(result.early_releases==1)
assert(cells[5].effect_number_string=="0G")
assert(cells[6].effect_amount_value==0)
assert(cells[10].note_value==120)
local old=cells[1].note_value
assert(not art.apply(phrase,plan,2,0x20,true))
assert(cells[1].note_value==old)
-- Standalone application uses the same terminal gate policy as the writer.
local isolated=seq.new_pattern(1,"extended")
isolated.playback="one_shot"
isolated.time_events={"N"}
local tail_plan=assert(engine.compile_cycle(isolated))
cells[1]={note_value=tail_plan.steps[1].note,effect_number_value=0,effect_amount_value=0}
cells[2]={note_value=121,effect_number_value=0,effect_amount_value=0}
local tail=assert(art.apply(phrase,tail_plan,2,nil,true))
assert(tail.early_releases==1 and tail.slide_count==0 and tail.commands==1)
assert(tail.rate==0x20 and cells[2].note_value==120)
print("ACID gate/slide operation checks passed")
