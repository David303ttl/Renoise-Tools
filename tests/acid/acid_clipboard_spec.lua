dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local source=seq.new_pattern(7)
source.pitch_length=9
for i=1,seq.MAX_STEPS do
  source.pitch_events[i]=seq.new_pitch(i%13,(i%3)-1,i%2==0,i%3==0)
  source.time_events[i]=i==1 and "N" or ({"N","T","R"})[i%3+1]
end
local target=seq.new_pattern(12)
target.pitch_length=13
target.timing_mode="triplet"
target.scale_mask_enabled=true
target.scale_mask[2]=false
local expected_fields={pitch={pitch_events=true,pitch_length=true},
  time={time_events=true,length=true},
  both={pitch_events=true,pitch_length=true,time_events=true,length=true}}
for _,scope in ipairs({"pitch","time","both"}) do
  local payload=assert(seq.make_clipboard(source,scope))
  for key in pairs(payload) do assert(expected_fields[scope][key],"unexpected payload key") end
  for key in pairs(expected_fields[scope]) do assert(payload[key]~=nil,"missing payload key") end
  local candidate=assert(seq.paste_candidate(target,payload,scope))
  assert(candidate~=target and candidate.scale_mask~=target.scale_mask)
  assert(candidate.timing_mode==target.timing_mode and candidate.scale_mask_enabled==target.scale_mask_enabled)
  for i=1,12 do assert(candidate.scale_mask[i]==target.scale_mask[i]) end
  assert(candidate.length==(scope=="pitch" and target.length or source.length))
  assert(candidate.pitch_length==(scope=="time" and target.pitch_length or source.pitch_length))
  for i=1,seq.MAX_STEPS do
    local expected=scope=="time" and target.pitch_events[i] or source.pitch_events[i]
    for key,value in pairs(expected) do assert(candidate.pitch_events[i][key]==value) end
    assert(candidate.time_events[i]==(scope=="pitch" and target.time_events[i] or source.time_events[i]))
  end
  if payload.pitch_events then
    local note=payload.pitch_events[32].note
    candidate.pitch_events[32].note=-1
    assert(payload.pitch_events[32].note==note and source.pitch_events[32].note==note)
    payload.pitch_events[32].accent=not payload.pitch_events[32].accent
    assert(payload.pitch_events[32].accent~=source.pitch_events[32].accent)
  end
  if payload.time_events then
    candidate.time_events[32]="bad"
    assert(payload.time_events[32]==source.time_events[32])
    payload.time_events[32]="bad"
    assert(source.time_events[32]~="bad")
  end
end
local corruptions={
  function(p)p.length=nil end,function(p)p.extra=true end,
  function(p)p.pitch_events[2]=nil end,function(p)p.time_events[32]=nil end,
  function(p)p.time_events[33]="N" end,function(p)p.pitch_events[1].extra=true end,
  function(p)p.pitch_events[1].note=61 end,function(p)p.pitch_events[1].key=0 end,
  function(p)p.pitch_events[1].accent=1 end,function(p)p.pitch_events[1].slide=nil end,
  function(p)p.time_events[2]="bad" end,function(p)p.time_events[1]="T" end,
  function(p)p.length=0 end,function(p)p.pitch_length=33 end,
  function(p)p.pitch_events="bad" end,function(p)p.time_events=false end,
  function(p)setmetatable(p,{}) end,
  function(p)setmetatable(p.pitch_events,{}) end,
  function(p)setmetatable(p.time_events,{}) end,
  function(p)setmetatable(p.pitch_events[1],{}) end}
for _,corrupt in ipairs(corruptions) do
  local payload=assert(seq.make_clipboard(source,"both"))
  local before=assert(seq.copy_source(target))
  corrupt(payload)
  local candidate,err=seq.paste_candidate(target,payload,"both")
  assert(candidate==nil and type(err)=="string","corrupt payload accepted")
  assert(seq.same_source(target,before),"rejected paste changed target")
end
assert(not seq.make_clipboard(source,"invalid"))
assert(not seq.paste_candidate(target,{},"invalid"))
assert(not seq.paste_candidate(target,false,"both"))
assert(not seq.paste_candidate(target,seq.make_clipboard(source,"pitch"),"time"))
assert(seq.same_source(source,assert(seq.paste_candidate(source,seq.make_clipboard(source,"both"),"both"))))
print("acid_clipboard_spec: OK")
