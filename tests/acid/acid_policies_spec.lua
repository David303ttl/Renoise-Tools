dofile("tests/bootstrap.lua")("acid")
local policies=require("model.policies")
local planner=require("model.output_planner")
local emitter=require("writers.pattrns_writer")
assert(policies.DEFAULT_PB_RANGE==0 and policies.DEFAULT_OUTPUT_POLICY=="repeat")
for _,value in ipairs({0,2,12,24,48}) do assert(policies.valid_pb_range(value)) end
for _,value in ipairs({-1,1,2.5,49,"2",false,math.huge,0/0}) do
  assert(not policies.valid_pb_range(value))
end
assert(not policies.valid_pb_range(nil))
assert(policies.valid_output_policy("repeat") and policies.valid_output_policy("play_once"))
assert(not policies.valid_output_policy("once"))
assert(policies.in_integer_range(2,1,3))
for _,value in ipairs({0,4,2.5,"2",math.huge,0/0}) do
  assert(not policies.in_integer_range(value,1,3))
end
local plan={length=1,steps={{step=1,kind="note",note=36,accent=false}}}
for _,value in ipairs({0,0.7,1/128,0.9999994,0.9999996,1}) do
  assert(policies.valid_volume(value))
  local emitted=tonumber(policies.format_volume(value))
  local expected=emitted==1 and 255 or math.floor(emitted*128)
  assert(policies.quantize_volume(value)==expected)
  local options={normal_volume=value,accent_volume=value}
  local script=assert(emitter.emit(plan,options))
  assert(script:find("volume = "..policies.format_volume(value),1,true))
  local volumes=assert(planner.expected_volumes(plan,1,1,1,options))
  assert(volumes[1][1]==expected)
  plan.steps[1].accent=true
  volumes=assert(planner.expected_volumes(plan,1,1,1,options))
  assert(volumes[1][1]==expected)
  plan.steps[1].accent=false
end
for _,value in ipairs({-0.000001,1.000001,"0.7",math.huge,-math.huge,0/0}) do
  assert(not policies.valid_volume(value))
  assert(not emitter.emit(plan,{normal_volume=value}))
  assert(not planner.expected_volumes(plan,1,1,1,{accent_volume=value}))
end
assert(not policies.valid_volume(nil))
assert(policies.quantize_volume(0.9999994)==127)
assert(policies.quantize_volume(0.9999996)==255)
assert(assert(emitter.emit(plan)):find("volume = 0.700000",1,true))
assert(policies.note_velocity(false)==89 and policies.note_velocity(true)==255)
assert(policies.quantize_volume(0.7)==89 and policies.quantize_volume(1)==255)
print("acid policies specs passed")
