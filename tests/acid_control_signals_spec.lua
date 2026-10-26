package.path="com.david303ttl.ACID.xrnx/?.lua;"..package.path
local signals=require("control_signals")
local p={length=8,pitch_events={{note=36,slide=true},{note=39,accent=true},{note=43},{note=41}},time_events={"N","T","N","R","N","N","T","R"}}
local tl=assert(signals.compile(p,{gate_fraction=0.5}))
local events=tl.events
local by={}
for _,e in ipairs(events) do
  local key=e.kind..":"..e.at
  by[key]=e
end
assert(by["gate_on:0"].note==36)
assert(by["tie:256"].note==36)
assert(by["pitch_target:512"].note==39)
assert(by["gate_off:768"].reason=="rest")
assert(by["gate_on:1024"].note==43)
assert(by["gate_off:1152"].reason=="retrigger")
assert(by["gate_on:1280"].note==41)
assert(by["tie:1536"].note==41)
assert(by["gate_off:1792"].reason=="rest")
local lines=assert(signals.release_lines(tl,2))
assert(#lines==1 and lines[1]==10)
assert(not signals.compile(p,{gate_fraction=0}))
assert(not signals.release_lines(tl,1))
local gate_writer=require("gate_writer")
local cells={}
for i=1,16 do cells[i]={note_value=121} end
local phrase={}
function phrase:line(i)return {note_columns={cells[i]}}end
local result=assert(gate_writer.apply(phrase,tl))
assert(result.early_releases==1 and cells[10].note_value==120)
assert(not gate_writer.apply(phrase,tl))
print("ACID control-signal and gate tests passed")
