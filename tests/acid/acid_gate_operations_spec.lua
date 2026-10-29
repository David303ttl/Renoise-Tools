dofile("tests/bootstrap.lua")("acid")
local gates=require("writers.gate_writer")
local planner=require("model.output_planner")
local signals=require("model.control_signals")
local seq=require("model.sequencer")
local compiler=require("model.cycle_interpreter")
local p=seq.new_pattern(2)
for i,command in ipairs({"N","N"}) do p.time_events[i]=command end
local semantic=assert(compiler.compile_cycle(p))
local timeline=assert(signals.compile(p,{plan=semantic,output_policy="play_once"}))
local operations=assert(planner.plan_gates(timeline,semantic,nil,4))
assert(operations.release_lines[3] and operations.release_lines[7])
local cells={}
local phrase={}
local function reset()
  for i=1,8 do cells[i]={note_value=(i==1 or i==5) and 48 or 121,
    delay_value=0,instrument_value=255,volume_value=255,panning_value=255,
    effect_number_value=0,effect_amount_value=0} end
end
function phrase:line(i) return {note_columns={cells[i]}} end
reset()
assert(gates.apply_plan(phrase,operations))
assert(cells[3].note_value==120 and cells[7].note_value==120)
for _,field in ipairs({"delay_value","instrument_value","volume_value","panning_value","effect_number_value","effect_amount_value","note_value"}) do
  reset()
  cells[7][field]=field=="note_value" and 60 or 7
  local result,err=gates.apply_plan(phrase,operations)
  assert(not result and err:find("TIME step 02, cycle 1, phrase line 0x06",1,true),err)
  assert(cells[3].note_value==121,"Preflight partially changed the phrase")
end
reset()
cells[7]=nil
assert(not gates.apply_plan(phrase,operations))
assert(cells[3].note_value==121)
local merged,err=planner.plan_gates(timeline,semantic,{{line=7,kind="continuation",command="0G",amount=0}},4)
assert(not merged and err:find("contradictory gate/glide operations",1,true),err)
merged,err=planner.plan_gates(timeline,semantic)
assert(not merged and err:find("positive integer lines-per-step",1,true),err)
-- An exception after an earlier write restores that earlier cell.
reset()
local stored={note_value=121,effect_number_value=0,effect_amount_value=0}
local fail_once=true
cells[7]=setmetatable({}, {
  __index=stored,
  __newindex=function(_,key,value)
    if key=="note_value" and value==120 and fail_once then fail_once=false;error("injected setter failure") end
    stored[key]=value
  end})
local result,why=gates.apply_plan(phrase,operations)
assert(not result and why:find("rolled back",1,true),why)
assert(cells[3].note_value==121 and cells[7].note_value==121)
-- A later malformed merged release must never target the loop sentinel.
local bad={steps=2,gate_fraction=.5,events={{kind="gate_off",reason="tail",at=512}}}
assert(not planner.plan_gates(bad,semantic,nil,4))
print("ACID merged articulation collision and rollback checks passed")
