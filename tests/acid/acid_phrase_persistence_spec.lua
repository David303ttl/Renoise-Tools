dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local ownership=require("writers.phrase_ownership")
local store=require("model.pattern_store")
local function phrase(note)
  local p={name="",number_of_lines=1,lpb=8,looping=false,playback_mode=1,
    key_tracking=1,visible_note_columns=1,visible_effect_columns=0}
  function p:line()
    return {note_columns={{note_value=note or 36,instrument_value=255,
      volume_value=255,panning_value=255,delay_value=0,
      effect_number_value=0,effect_amount_value=0}}}
  end
  return p
end
local s={tool_data=nil,instruments={{phrases={}}}}
local a=phrase()
a.name=assert(ownership.make_name(a,1))
s.instruments[1].phrases[1]=a
assert(ownership.status(a)=="owned" and ownership.id(a)==1)
local p=seq.new_pattern(17)
for i=1,17 do p.time_events[i]="N" end
p.pitch_events[2]=seq.new_pitch(3,1,true,true)
p.time_events[16]="T"
p.time_events[17]="R"
assert(store.allocate(s)==2)
assert(store.save(s,1,p,"slide"))
local restored,mode=store.load(s,a)
assert(restored and mode=="slide")
assert(restored.length==17 and #restored.pitch_events==64)
assert(restored.pitch_events[2].note==51)
assert(restored.pitch_events[2].octave==1)
assert(restored.pitch_events[2].accent and restored.pitch_events[2].slide)
assert(restored.time_events[16]=="T" and restored.time_events[17]=="R")
restored.pitch_events[2].note=36
local again=assert(store.load(s,a))
assert(again.pitch_events[2].note==51)
local b=phrase(40)
b.name=assert(ownership.make_name(b,2))
s.instruments[1].phrases[2]=b
assert(store.allocate(s)==3)
local p2=seq.new_pattern(64)
for i=1,64 do p2.time_events[i]="R" end
assert(store.save(s,2,p2,"baseline"))
assert(store.load(s,b).length==64)
assert(store.load(s,a).length==17)
b:line().note_columns[1].note_value=41 -- this mock produces a new cell every call
-- Instead modify sealed name to verify ownership refusal.
b.name="ACID 0.1 #2 [00000000]"
assert(not store.load(s,b))
b.name=assert(ownership.make_name(b,2))
s.tool_data="unexpected external data"
assert(not store.save(s,3,p,"baseline"))
assert(s.tool_data=="unexpected external data")
print("ACID source persistence and phrase ID checks passed")
