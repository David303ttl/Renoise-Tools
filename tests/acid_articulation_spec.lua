-- From repo root: lua tests/acid_articulation_spec.lua
package.path = "com.david303ttl.ACID.xrnx/?.lua;" .. package.path
local compiler=require("compiler")
local articulation=require("articulation")
local pattern={
  length=8,
  pitch_events={{note=36,slide=true},{note=43},{note=39}},
  time_events={"N","T","N","R","N","R","R","R"}
}
local plan=assert(compiler.compile(pattern))
local commands=assert(articulation.plan(plan,2,2))
assert(#commands==2)
assert(commands[1].line==5 and commands[1].amount==2)
assert(commands[2].line==6 and commands[2].amount==0)
local cells={}
for i=1,16 do cells[i]={
  note_value=121,effect_number_value=0,effect_amount_value=0
} end
cells[1].note_value=36
cells[5].note_value=43
cells[7].note_value=120
cells[9].note_value=39
cells[11].note_value=120
local phrase={}
function phrase:line(i) return {note_columns={cells[i]}} end
local result=assert(articulation.apply(phrase,plan,2,2))
assert(result.slide_count==1 and result.commands==2)
assert(cells[5].effect_number_string=="0G")
assert(cells[5].effect_amount_value==2)
assert(cells[6].effect_number_string=="0G")
assert(cells[6].effect_amount_value==0)
-- Validate preflight: if destination already contains foreign content,
-- do not partially change an otherwise valid target.
cells[5].effect_number_value=0
cells[5].effect_number_string=nil
cells[6].effect_number_value=7
assert(not articulation.apply(phrase,plan,2,2))
assert(cells[5].effect_number_value==0)
assert(not articulation.plan(plan,2,0))
print("ACID articulation placement checks passed")
