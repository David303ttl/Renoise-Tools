dofile("tests/bootstrap.lua")("acid")
local sequencer=require("model.sequencer")
local compiler=require("model.cycle_interpreter")
local output=require("model.output_planner")
local control=require("model.control_signals")
local legato=require("model.legato")

local function copy(value)
  if type(value)~="table" then return value end
  local result={}
  for key,item in pairs(value) do result[key]=copy(item) end
  return result
end

local source=sequencer.new_pattern(2)
source.pitch_length=2
source.pitch_events[1]=sequencer.new_pitch(0,0,false,true)
source.pitch_events[2]=sequencer.new_pitch(7,0,false,true)
source.time_events[1],source.time_events[2]="N","N"
local plan,layout=assert(output.plan_output(source,"repeat",512))
local successor=copy(plan.loop.steady)
assert(not rawequal(successor,plan.loop.steady))
local timeline=assert(control.compile(source,{plan=plan,successor=successor,output_policy="repeat"}))
assert(legato.plan(copy(plan),copy(timeline),layout))

successor.steps[1].note=48
assert(not control.compile(source,{plan=plan,successor=successor,output_policy="repeat"}))
assert(legato.plan(plan,timeline,layout))
local changed=copy(timeline)
changed.successor.steps[1].note=48
assert(not legato.plan(plan,changed,layout))
changed=copy(timeline)
changed.events[1].note=48
assert(not legato.plan(plan,changed,layout))
assert(not legato.plan(plan,changed,layout,{pb_range=12,instrument_value=255}))
changed=copy(plan)
changed.steps[1].note=48
assert(not legato.plan(changed,timeline,layout))
changed=copy(plan)
changed.entry_kind="repeat"
assert(not legato.plan(changed,timeline,layout))

local cold,exit=assert(compiler.compile_cycle(source))
local next_cycle=assert(compiler.compile_cycle(source,exit))
local cycle_timeline=assert(control.compile(source,{plan=cold,successor=copy(next_cycle),output_policy="repeat"}))
assert(legato.plan(copy(cold),cycle_timeline,layout))
next_cycle.steps[1].note=48
assert(not control.compile(source,{plan=cold,successor=next_cycle,output_policy="repeat"}))
cycle_timeline.successor.steps[1].note=48
assert(not legato.plan(cold,cycle_timeline,layout))

for _,mutate in ipairs({
  function(value) value.loop=true end,
  function(value) value.steps[1].note="bad" end,
  function(value) value.steps[1].cycle="bad" end,
  function(value) value.steps[1].step=2 end,
  function(value) value.steps[1].voice=value end,
  function(value) value.loop.steady.steps={} end,
}) do
  local malformed=copy(plan)
  mutate(malformed)
  local ok,result=pcall(control.compile,source,{plan=malformed,successor=plan.loop.steady,output_policy="repeat"})
  assert(ok and not result)
  ok,result=pcall(legato.plan,malformed,timeline,layout)
  assert(ok and not result)
end
assert(not legato.plan(plan,{steps=plan.length,events={}},layout))
print("ACID semantic successor and timeline association checks passed")
