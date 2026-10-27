dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local ownership=require("writers.phrase_ownership")
local store=require("model.pattern_store")
local function phrase(note)
  local p={name="",number_of_lines=4,lpb=8,looping=false,loop_start=1,loop_end=4,playback_mode=1,
    key_tracking=1,visible_note_columns=1,visible_effect_columns=0,
    instrument_column_visible=false,volume_column_visible=false,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false}
  local cell={note_value=note or 36,instrument_value=255,
    volume_value=255,panning_value=255,delay_value=0,
    effect_number_value=0,effect_amount_value=0}
  local muted={}
  function p:line()
    return {note_columns={cell}}
  end
  function p:column_is_muted(column) return muted[column]==true end
  function p:set_column_is_muted(column,value) muted[column]=value end
  return p
end
local s={tool_data=nil,instruments={{phrases={}}}}
local a=phrase()
a.name=assert(ownership.make_name(a,1))
assert(a.name:find("[v2:",1,true))
s.instruments[1].phrases[1]=a
assert(ownership.status(a)=="owned" and ownership.id(a)==1)
local p=seq.new_pattern(17,"extended")
p.pitch_length,p.playback=3,"loop"
for i=1,17 do p.time_events[i]="N" end
p.pitch_events[2]=seq.new_pitch(3,1,true,true)
p.pitch_events[40]=seq.new_pitch(4,0,true,false)
p.time_events[16]="T"
p.time_events[17]="R"
local initial=assert(store.prepare(s,2,p,"slide"))
assert(initial.previous_raw==nil)
assert(store.commit(s,initial) and s.tool_data==initial.raw)
assert(store.restore(s,initial) and s.tool_data==nil)
assert(store.allocate(s)==2)
assert(store.save(s,1,p,"slide"))
local restored,mode=store.load(s,a)
assert(restored and mode=="slide")
assert(restored.length==17 and #restored.pitch_events==64)
assert(restored.entry_mode=="extended" and restored.pitch_length==3 and restored.playback=="loop")
assert(restored.pitch_events[2].note==51)
assert(restored.pitch_events[2].octave==1)
assert(restored.pitch_events[2].accent and restored.pitch_events[2].slide)
assert(restored.pitch_events[40].note==40 and restored.pitch_events[40].accent)
assert(restored.time_events[16]=="T" and restored.time_events[17]=="R")
restored.pitch_events[2].note=36
local again=assert(store.load(s,a))
assert(again.pitch_events[2].note==51)
again.time_events[17]="N"
local candidate=assert(store.prepare(s,1,again,"slide"))
assert(candidate.previous_raw==s.tool_data and candidate.raw~=candidate.previous_raw)
s.tool_data=candidate.raw.."external mutation"
assert(not store.commit(s,candidate))
s.tool_data=candidate.previous_raw
assert(store.commit(s,candidate))
assert(store.restore(s,candidate) and s.tool_data==candidate.previous_raw)
s.tool_data="newer independent source"
assert(not store.restore(s,candidate) and s.tool_data=="newer independent source")
s.tool_data=candidate.previous_raw
local b=phrase(40)
b.name=assert(ownership.make_name(b,2))
s.instruments[1].phrases[2]=b
assert(store.allocate(s)==3)
local p2=seq.new_pattern(64,"extended")
for i=1,64 do p2.time_events[i]="R" end
assert(store.save(s,2,p2,"baseline"))
assert(store.load(s,b).length==64)
assert(store.load(s,a).length==17)
local c=phrase(43)
c.name=assert(ownership.make_name(c,3))
s.instruments[1].phrases[3]=c
local original=seq.new_pattern()
for i=1,16 do original.time_events[i]="R" end
assert(store.save(s,3,original,"baseline"))
local original_copy,original_audio=store.load(s,c)
assert(original_audio=="baseline" and original_copy.entry_mode=="original")
assert(original_copy.length==16 and original_copy.pitch_length==16 and original_copy.playback=="loop")
assert(#original_copy.pitch_events==64 and original_copy.pitch_events[64].note==36)
original.playback="one_shot"
assert(store.save(s,3,original,"baseline"))
local one_shot_copy=assert(store.load(s,c))
assert(one_shot_copy.playback=="one_shot")
local valid_data=s.tool_data
s.tool_data=valid_data:gsub("|extended|3|loop|17|","|original|16|loop|17|",1)
assert(not store.read(s)) -- invalid Original length is rejected without throwing
s.tool_data=valid_data:gsub("36:0:0:00,","36:0:0:00,,",1)
assert(not store.read(s)) -- empty pitch token is malformed
s.tool_data=valid_data.."\n"
assert(not store.read(s)) -- blank rows are outside the serialized grammar
s.tool_data=valid_data:sub(1,-2)
assert(not store.read(s)) -- the terminating LF is required
s.tool_data=valid_data
b:line().note_columns[1].note_value=41
assert(ownership.status(b)=="modified" and not store.load(s,b))
b:line().note_columns[1].note_value=40
assert(ownership.status(b)=="owned")
b:set_column_is_muted(2,true)
assert(ownership.status(b)=="modified")
b:set_column_is_muted(2,false)
b.volume_column_visible=true
assert(ownership.status(b)=="modified")
b.volume_column_visible=false
assert(ownership.status(b)=="owned")
b.sample_effects_column_visible=true
assert(ownership.status(b)=="modified")
b.sample_effects_column_visible=false
assert(ownership.status(b)=="owned")
-- A syntactically old seal is foreign and grants no ID or adoption path.
b.name="ACID 0.1 #2 [00000000]"
assert(not store.load(s,b))
b.name=assert(ownership.make_name(b,2))
b.loop_end=3
assert(ownership.status(b)=="modified" and not store.load(s,b))
b.loop_end=4
assert(ownership.status(b)=="owned")
local old=phrase(42)
old.name="ACID 0.1 #3 [DEADBEEF]"
assert(ownership.id(old)==nil and ownership.status(old)=="foreign")
old.name="ACID 0.1 #3 [v1:DEADBEEF]"
assert(ownership.id(old)==nil and ownership.status(old)=="foreign")
s.tool_data="ACID-PITCH-TIME-1\n"
assert(not store.read(s) and not store.save(s,3,p,"baseline"))
assert(s.tool_data=="ACID-PITCH-TIME-1\n")
s.tool_data="unexpected external data"
assert(not store.save(s,3,p,"baseline"))
assert(s.tool_data=="unexpected external data")
print("ACID source persistence and phrase ID checks passed")
