dofile('tests/bootstrap.lua')('acid')
local compiler=require("model.cycle_interpreter")
local articulation=require("model.articulation")
local seq=require("model.sequencer")
local pattern=seq.new_pattern(8,"extended")
pattern.pitch_length=3
pattern.pitch_events[1]={note=36,slide=true};pattern.pitch_events[2]={note=43};pattern.pitch_events[3]={note=39}
pattern.time_events={"N","T","N","R","N","R","R","R"}
local plan=assert(compiler.compile_cycle(pattern))
local commands=assert(articulation.plan(plan,2,0x40))
assert(#commands==2)
assert(commands[1].line==5 and commands[1].amount==0x40)
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
local result=assert(articulation.apply(phrase,plan,2,0x40))
assert(result.slide_count==1 and result.commands==2)
assert(cells[5].effect_number_string=="0G")
assert(cells[5].effect_amount_value==0x40)
assert(cells[6].effect_number_string=="0G")
assert(cells[6].effect_amount_value==0)
-- Validate preflight: if destination already contains foreign content,
-- do not partially change an otherwise valid target.
cells[5].effect_number_value=0
cells[5].effect_number_string=nil
cells[6].effect_number_value=7
assert(not articulation.apply(phrase,plan,2,0x40))
assert(cells[5].effect_number_value==0)
assert(not articulation.plan(plan,2,0))
-- At rate 20, seven semitones require four command lines; two truncate.
local short,why=articulation.plan(plan,2)
assert(not short and why:find("requires 4 command lines, only 2",1,true),why)
assert(why:find("TIME step 03, cycle 1, phrase line 0x04",1,true),why)
local tied=seq.new_pattern(8,"extended")
tied.pitch_length=2
tied.pitch_events[1]={note=48,slide=true}
tied.pitch_events[2]={note=60}
tied.time_events={"N","N","T","T","R","N","R","R"}
local tied_plan=assert(compiler.compile_cycle(tied))
local long=assert(articulation.plan(tied_plan,2))
assert(#long==6 and long[1].amount==0x20 and long[1].line==3)
for index=2,6 do
  assert(long[index].line==index+2 and long[index].amount==0)
  assert(long[index].kind=="continuation" and long[index].note==nil)
end
-- Signed interval changes direction without changing the fixed rate or span.
tied.pitch_events[1].note=60;tied.pitch_events[2].note=48
local down=assert(articulation.plan(assert(compiler.compile_cycle(tied)),2))
assert(#down==6 and down[1].note==48 and down[1].amount==0x20)
tied.pitch_events[2].note=60
local same=assert(articulation.plan(assert(compiler.compile_cycle(tied)),2))
assert(#same==1 and same[1].kind=="glide" and same[1].note==60)
-- REST cancels the outgoing slide; a later NOTE is a fresh attack.
tied.time_events={"N","R","N","T","T","T","R","R"}
assert(#assert(articulation.plan(assert(compiler.compile_cycle(tied)),2))==0)
-- A fresh NOTE bounds coverage even if following steps could hold it.
tied.pitch_events[2].note=72
tied.time_events={"N","N","N","T","T","T","R","R"}
local blocked,reason=articulation.plan(assert(compiler.compile_cycle(tied)),2)
assert(not blocked and reason:find("requires 6 command lines, only 2",1,true),reason)
print("ACID articulation placement checks passed")
