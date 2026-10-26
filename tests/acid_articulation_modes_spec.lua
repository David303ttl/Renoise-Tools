-- Run locally from repository root: texlua tests/acid_articulation_modes_spec.lua
package.path="com.david303ttl.ACID.xrnx/?.lua;"..package.path
local engine=require("compiler")
local art=require("articulation")
local p={length=8,
 pitch_events={{note=36,slide=true},{note=43},{note=39},{note=41}},
 time_events={"N","T","N","R","N","N","T","R"}}
local plan=assert(engine.compile(p))
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
print("ACID gate/slide operation checks passed")
