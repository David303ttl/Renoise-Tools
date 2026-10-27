dofile('tests/bootstrap.lua')('acid')
local signals=require("model.control_signals")
local seq=require("model.sequencer")
local p=seq.new_pattern(8,"extended")
p.pitch_length=4
p.pitch_events[1]={note=36,slide=true};p.pitch_events[2]={note=39,accent=true}
p.pitch_events[3]={note=43};p.pitch_events[4]={note=41}
p.time_events={"N","T","N","R","N","N","T","R"}
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
local gate_writer=require("writers.gate_writer")
local cells={}
for i=1,16 do cells[i]={note_value=121} end
local phrase={}
function phrase:line(i)return {note_columns={cells[i]}}end
local result=assert(gate_writer.apply(phrase,tl))
assert(result.early_releases==1 and cells[10].note_value==120)
assert(not gate_writer.apply(phrase,tl))
print("ACID control-signal and gate tests passed")

-- Compare every short valid source to a run-based oracle. A run ends at a
-- REST boundary, or at the final held-step midpoint before a fresh NOTE/end.
local cycles=require("model.cycle_interpreter")
local checked=0
local function verify(commands,slide_mask,playback)
  local source=seq.new_pattern(#commands,"extended")
  source.playback=playback
  source.pitch_length=2
  source.time_events=commands
  for i=1,2 do
    source.pitch_events[i].note=36 -- same-note connection must stay connected
    source.pitch_events[i].slide=math.floor(slide_mask/2^(i-1))%2==1
  end
  local count=playback=="loop" and 3 or 1
  local plans=assert(cycles.compile_cycles(source,count+1))
  local actual={}
  for c=1,count do
    local timeline=assert(signals.compile(source,{plan=plans[c],
      successor=playback=="loop" and plans[c+1] or nil,playback=playback}))
    for _,edge in ipairs(timeline.events) do
      assert(edge.at>=0 and edge.at<#commands*256)
      if edge.kind=="gate_off" then actual[#actual+1]=(c-1)*#commands*256+edge.at end
      if edge.kind=="pitch_target" then assert(edge.note==edge.from_note) end
    end
    if playback=="one_shot" then assert(not timeline.open_at_end) end
  end
  local expected={}
  local run_start,last_held,outgoing=nil,nil,false
  local cursor=1
  local limit=count*#commands
  -- Inspect one extra successor to resolve the final repeating midpoint.
  for absolute=1,limit+(playback=="loop" and 1 or 0) do
    local index=(absolute-1)%#commands+1
    if index==1 then cursor=1 end
    local command=commands[index]
    if command=="N" then
      if run_start and not outgoing then
        expected[#expected+1]=(last_held-1)*256+128
      end
      run_start=absolute
      outgoing=source.pitch_events[cursor].slide==true
      cursor=cursor%source.pitch_length+1
      last_held=absolute
    elseif command=="T" then
      if run_start then last_held=absolute end
    elseif run_start then
      local at=(absolute-1)*256
      if at<limit*256 then expected[#expected+1]=at end
      run_start,last_held,outgoing=nil,nil,false
    end
  end
  if playback=="one_shot" and run_start then
    expected[#expected+1]=(last_held-1)*256+128
  end
  assert(#actual==#expected,"release count: "..table.concat(commands).." "..playback)
  for i,at in ipairs(expected) do assert(actual[i]==at,"release position mismatch") end
  checked=checked+1
end
local function enumerate(commands,length)
  if #commands==length then
    if commands[1]~="T" then
      for mask=0,3 do
        verify(commands,mask,"loop")
        verify(commands,mask,"one_shot")
      end
    end
    return
  end
  for _,command in ipairs({"N","T","R"}) do
    local next_commands={}
    for i,value in ipairs(commands) do next_commands[i]=value end
    next_commands[#next_commands+1]=command
    enumerate(next_commands,length)
  end
end
for length=1,5 do enumerate({},length) end
assert(checked==1936)
local terminal=seq.new_pattern(1,"extended")
terminal.playback="one_shot"
terminal.time_events={"N"}
terminal.pitch_events[1].slide=true
local tail=assert(signals.compile(terminal))
assert(#tail.events==2 and tail.events[2].at==128 and tail.events[2].reason=="tail")
assert(assert(signals.release_lines(tail,2))[1]==2)

print("ACID successor gate oracle passed "..checked.." cases")

local terminal_plan=assert(cycles.compile_cycle(terminal))
assert(not signals.compile(terminal,{plan=terminal_plan,playback="loop"}))
assert(not signals.compile(terminal,{playback="invalid"}))
assert(not signals.release_lines(assert(signals.compile(terminal,{gate_fraction=0.25})),2))
for _,length in ipairs({16,17,32,33,48,49,64}) do
  local long=seq.new_pattern(length,"extended")
  long.playback="one_shot"
  for step=1,length do long.time_events[step]=step==1 and "N" or "T" end
  long.pitch_events[1].slide=true
  local timeline=assert(signals.compile(long))
  local releases=assert(signals.release_lines(timeline,2))
  assert(#releases==1 and releases[1]==length*2)
  assert(timeline.events[#timeline.events].at==(length-1)*256+128)
  assert(not timeline.open_at_end)
end
