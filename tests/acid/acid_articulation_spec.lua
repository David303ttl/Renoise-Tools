dofile('tests/bootstrap.lua')('acid')
local compiler=require("model.cycle_interpreter")
local articulation=require("model.articulation")
assert(articulation.rate_for_interval(12,4)==48)
assert(articulation.rate_for_interval(-12,4)==48)
assert(articulation.rate_for_interval(1,3)==6)
assert(articulation.command_span(12,48)==4)
assert(articulation.command_span(-12,48)==4)
assert(articulation.command_span(0,articulation.MIN_RATE)==1)
assert(articulation.command_span(119,articulation.MAX_FINITE_RATE)==8)
assert(articulation.command_span(119,articulation.MAX_RATE)==1)
local control=require("model.control_signals")
local planner=require("model.output_planner")
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
local timeline=assert(control.compile({}, {plan=plan,output_policy="play_once"}))
local operations=assert(planner.plan_gates(timeline,plan,commands,4))
assert(commands[1].kind=="glide" and #operations.operations==2)
assert(operations.effects[9]==0x40 and operations.effects[10]==0)
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
