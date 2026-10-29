dofile('tests/bootstrap.lua')('acid')
local compiler=require("model.cycle_interpreter")
local articulation=require("model.articulation")
local seq=require("model.sequencer")
local pitch=dofile("tests/acid/pitch_fixture.lua")
local pattern=seq.new_pattern(8)
pattern.pitch_length=3
pattern.pitch_events[1]=pitch(36,false,true);pattern.pitch_events[2]=pitch(43);pattern.pitch_events[3]=pitch(39)
for i,command in ipairs({"N","T","N","R","N","R","R","R"}) do pattern.time_events[i]=command end
local plan=assert(compiler.compile_cycle(pattern))
local commands=assert(articulation.plan(plan,4,0x40))
assert(#commands==2)
assert(commands[1].line==9 and commands[1].amount==0x40)
assert(commands[2].line==10 and commands[2].amount==0)
local cells={}
for i=1,32 do cells[i]={
  note_value=121,effect_number_value=0,effect_amount_value=0
} end
cells[1].note_value=36
cells[9].note_value=43
cells[13].note_value=120
cells[17].note_value=39
cells[21].note_value=120
local phrase={}
function phrase:line(i) return {note_columns={cells[i]}} end
local result=assert(articulation.apply(phrase,plan,4,0x40,{output_policy="play_once"}))
assert(result.slide_count==1 and result.commands==2)
assert(cells[9].effect_number_string=="0G")
assert(cells[9].effect_amount_value==0x40)
assert(cells[10].effect_number_string=="0G")
assert(cells[10].effect_amount_value==0)
assert(cells[13].note_value==120 and cells[21].note_value==120)
-- Validate preflight: if destination already contains foreign content,
-- do not partially change an otherwise valid target.
cells[9].effect_number_value=0
cells[9].effect_number_string=nil
cells[10].effect_number_value=7
assert(not articulation.apply(phrase,plan,4,0x40,{output_policy="play_once"}))
assert(cells[9].effect_number_value==0)
assert(not articulation.plan(plan,4,0))
-- The configured rate needs more command lines than the step can provide.
local short,why=articulation.plan(plan,4,16)
assert(not short and why:find("requires 7 command lines, only 4",1,true),why)
assert(why:find("TIME step 03, cycle 1, phrase line 0x08",1,true),why)
local tied=seq.new_pattern(8)
tied.pitch_length=2
tied.pitch_events[1]=pitch(48,false,true)
tied.pitch_events[2]=pitch(60)
for i,command in ipairs({"N","N","T","T","R","N","R","R"}) do tied.time_events[i]=command end
local tied_plan=assert(compiler.compile_cycle(tied))
local long=assert(articulation.plan(tied_plan,4))
assert(#long==6 and long[1].amount==0x20 and long[1].line==5)
for index=2,6 do
  assert(long[index].line==index+4 and long[index].amount==0)
  assert(long[index].kind=="continuation" and long[index].note==nil)
end
-- Signed interval changes direction without changing the fixed rate or span.
tied.pitch_events[1]=pitch(60,false,true);tied.pitch_events[2]=pitch(48)
local down=assert(articulation.plan(assert(compiler.compile_cycle(tied)),4))
assert(#down==6 and down[1].note==48 and down[1].amount==0x20)
tied.pitch_events[2]=pitch(60)
local same=assert(articulation.plan(assert(compiler.compile_cycle(tied)),4))
assert(#same==1 and same[1].kind=="glide" and same[1].note==60)
-- REST cancels the outgoing slide; a later NOTE is a fresh attack.
for i,command in ipairs({"N","R","N","T","T","T","R","R"}) do tied.time_events[i]=command end
assert(#assert(articulation.plan(assert(compiler.compile_cycle(tied)),4))==0)
-- A fresh NOTE bounds coverage even if following steps could hold it.
tied.pitch_events[2]=pitch(48)
for i,command in ipairs({"N","N","N","T","T","T","R","R"}) do tied.time_events[i]=command end
local blocked,reason=articulation.plan(assert(compiler.compile_cycle(tied)),4)
assert(not blocked and reason:find("requires 6 command lines, only 4",1,true),reason)
print("ACID articulation placement checks passed")
