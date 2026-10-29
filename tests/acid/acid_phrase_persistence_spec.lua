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
assert(a.name:find("[v3:",1,true))
s.instruments[1].phrases[1]=a
assert(ownership.status(a)=="owned" and ownership.id(a)==1)
local p=seq.new_pattern(17)
p.timing_mode="triplet"
p.pitch_length=3
for i=1,17 do p.time_events[i]="N" end
p.pitch_events[2]=seq.new_pitch(3,1,true,true)
p.pitch_events[32]=seq.new_pitch(4,0,true,false)
p.time_events[16]="T"
p.time_events[17]="R"
p.time_events[32]="T"
local initial=assert(store.prepare(s,2,p,"repeat"))
assert(initial.previous_raw==nil)
assert(store.commit(s,initial) and s.tool_data==initial.raw)
assert(store.restore(s,initial) and s.tool_data==nil)
assert(store.allocate(s)==2)
assert(store.save(s,1,p,"play_once",12))
assert(s.tool_data:match("^ACID%-PITCH%-TIME%-1\n"))
local restored,output_policy,pb_range=store.load(s,a)
assert(restored and output_policy=="play_once" and pb_range==12)
assert(restored.length==17 and #restored.pitch_events==32)
assert(restored.timing_mode=="triplet")
assert(restored.pitch_length==3 and #restored.time_events==32)
assert(restored.pitch_events[2].note==51)
assert(restored.pitch_events[2].octave==1)
assert(restored.pitch_events[2].accent and restored.pitch_events[2].slide)
assert(restored.pitch_events[32].note==40 and restored.pitch_events[32].accent)
assert(restored.time_events[16]=="T" and restored.time_events[17]=="R")
assert(restored.time_events[32]=="T")
restored.length=16
assert(store.save(s,1,restored,"repeat"))
local shortened,_,shortened_pb=store.load(s,a)
assert(shortened.length==16 and shortened.time_events[17]=="R" and shortened.time_events[32]=="T")
assert(shortened_pb==0,"omitted PB range defaults to Off")
shortened.length=17
assert(store.save(s,1,shortened,"repeat",24))
local expanded=assert(store.load(s,a))
local _,_,expanded_pb=store.load(s,a)
assert(expanded.length==17 and expanded.time_events[17]=="R" and expanded.time_events[32]=="T")
assert(expanded_pb==24)
restored.pitch_events[2].note=36
local again=assert(store.load(s,a))
assert(again.pitch_events[2].note==51)
again.time_events[17]="N"
local candidate=assert(store.prepare(s,1,again,"play_once"))
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
local p2=seq.new_pattern(32)
for i=1,32 do p2.time_events[i]="R" end
assert(store.save(s,2,p2,"repeat"))
assert(store.load(s,b).length==32)
assert(store.load(s,a).length==17)
local c=phrase(43)
c.name=assert(ownership.make_name(c,3))
s.instruments[1].phrases[3]=c
local original=seq.new_pattern()
for i=1,16 do original.time_events[i]="R" end
assert(store.save(s,3,original,"repeat",48))
local original_copy,original_policy,original_pb_range=store.load(s,c)
assert(original_policy=="repeat")
assert(original_pb_range==48)
assert(original_copy.length==16 and original_copy.pitch_length==original.pitch_length)
assert(#original_copy.pitch_events==32 and original_copy.pitch_events[32].note==36)
assert(store.save(s,3,original,"play_once",2))
local play_once_copy,play_once_policy,play_once_pb_range=store.load(s,c)
assert(play_once_policy=="play_once")
assert(play_once_pb_range==2)
assert(play_once_copy.length==original.length and play_once_copy.pitch_length==original.pitch_length)
local valid_data=s.tool_data
s.tool_data=valid_data:gsub("|triplet|", "|unknown|", 1)
assert(not store.read(s))
s.tool_data=valid_data:gsub("|triplet|", "|", 1)
assert(not store.read(s))
s.tool_data=valid_data:gsub("|play_once|2|", "|play_once|4|", 1)
assert(not store.read(s)) -- unsupported PB ranges are rejected
s.tool_data=valid_data:gsub("|play_once|", "|unsupported|", 1)
assert(not store.read(s)) -- unsupported output policies are rejected
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
old.name="ACID 0.1 #3 [v2:DEADBEEF]"
assert(ownership.id(old)==nil and ownership.status(old)=="foreign")
s.tool_data=nil
local invalid_range,range_error=store.prepare(s,4,p,"repeat",4)
assert(not invalid_range and range_error=="invalid PB range")
assert(s.tool_data==nil)
local note_only=seq.new_pattern(1)
note_only.pitch_events[1]={note=36,accent=false,slide=false}
assert(not store.save(s,4,note_only,"repeat"))
assert(s.tool_data==nil)
s.tool_data="unexpected external data"
assert(not store.save(s,3,p,"repeat"))
assert(s.tool_data=="unexpected external data")
print("ACID source persistence and phrase ID checks passed")
