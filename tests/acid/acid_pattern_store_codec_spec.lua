dofile("tests/bootstrap.lua")("acid")
local store=require("renoise.pattern_store")
local seq=require("model.sequencer")
local interpreter=require("model.cycle_interpreter")
local compile_cycle=interpreter.compile_cycle
interpreter.compile_cycle=function() error("Storage validation must not build playback plans") end
local file=assert(io.open("tests/acid/fixtures/pattern_store.txt","rb"))
local raw=file:read("*a")
file:close()
local header,snapshot,label_record,draft=raw:match("([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)\n$")
assert(header and snapshot and label_record and draft)
local instrument={name="Kit|\n",phrases={}}
local song={tool_data=raw,instruments={instrument}}
local entries=assert(store.read(song))
local source=entries[2].pattern
assert(source.length==17 and source.pitch_length==3 and source.timing_mode=="triplet")
assert(source.pitch_events[2].note==25 and source.pitch_events[2].octave==-1)
assert(source.pitch_events[32].note==60 and source.pitch_events[32].octave==1)
assert(source.time_events[16]=="T" and source.time_events[17]=="R" and source.time_events[32]=="T")
entries[2].pattern.pitch_events[1].note=99
assert(store.read(song)[2].pattern.pitch_events[1].note==36,
  "public store reads must not expose cached decoded sources")
source=assert(store.read_entry(song,2))
local entry_source=assert(store.read_entry(song,2))
entry_source.pitch_events[1].note=98
assert(store.read_entry(song,2).pitch_events[1].note==36,
  "narrow entry reads must remain detached from the decoded cache")
local restored,policy,pb,label,label_custom=store.read_draft(song,instrument,nil)
assert(restored and policy=="repeat" and pb==24)
assert(label=="Untitled" and not label_custom)
assert(store.write_draft(song,instrument,nil,restored,policy,pb))
assert(song.tool_data==raw,"snapshot and draft encoding must match the saved fixture")
assert(store.update_label(song,instrument,nil,"Untitled",true,raw,restored,policy,pb))
local _,_,_,pending_label,pending_custom=store.read_draft(song,instrument,nil)
assert(pending_label=="Untitled" and pending_custom==true,
  "literal Untitled must roundtrip as an explicitly custom pending label")
song.tool_data=raw
assert(store.read(song)[2].label=="Pattern 2" and store.read(song)[2].label_custom==false)
assert(store.valid_label("A") and store.valid_label(string.rep("A",32)))
assert(store.valid_label("A _.-Z"))
for _,label_value in ipairs({"",string.rep("A",33)," bad","A/","A\n","é"}) do
  assert(not store.valid_label(label_value),"invalid label accepted: "..label_value)
end
local rollback_instrument={name="Rollback label",phrases={}}
local rollback_raw=""
local setter_mode=nil
local rollback_song=setmetatable({instruments={rollback_instrument}}, {
  __index=function(_,key)if key=="tool_data" then return rollback_raw end end,
  __newindex=function(target,key,value)
    if key=="tool_data" then
      if setter_mode=="before" then error("injected pre-mutation setter error") end
      rollback_raw=value
      if setter_mode=="after" then error("injected setter error") end
      if setter_mode=="third" then rollback_raw="third-party bytes" end
    else rawset(target,key,value) end
  end})
assert(store.write_draft(rollback_song,rollback_instrument,nil,seq.new_pattern(3),"repeat",0))
local rollback_before=rollback_raw
assert(not store.update_label(rollback_song,rollback_instrument,nil,"Changed",true,"stale raw",
  seq.new_pattern(3),"repeat",0) and rollback_raw==rollback_before)
setter_mode="before"
local before_write=store.update_label(rollback_song,rollback_instrument,nil,"Changed",true,
  rollback_before,seq.new_pattern(3),"repeat",0)
assert(not before_write and rollback_raw==rollback_before,
  "pre-mutation setter failure must preserve the exact old bytes")
setter_mode="after"
local label_saved=store.update_label(rollback_song,rollback_instrument,nil,"Changed",true,
  rollback_before,seq.new_pattern(3),"repeat",0)
assert(not label_saved and rollback_raw==rollback_before,
  "mutate-then-throw label setter must restore only its exact candidate")
setter_mode="third"
local third=store.update_label(rollback_song,rollback_instrument,nil,"Changed",true,
  rollback_before,seq.new_pattern(3),"repeat",0)
assert(not third and rollback_raw=="third-party bytes",
  "uncertain third-value label storage must never be overwritten")
setter_mode=nil
assert(store.save(song,2,source,"repeat",24))
assert(song.tool_data==raw,"snapshot encoding must preserve draft bytes")

local cache_instrument={name="Cache kit",phrases={}}
local cache_song={tool_data="",instruments={cache_instrument}}
local caller_source=seq.copy_source(source)
local caller_pitch=caller_source.pitch_events[1].note
local custom_candidate=assert(store.prepare(cache_song,1,caller_source,"repeat",0,
  function()return true end,nil,"Explicit",true))
assert(store.commit(cache_song,custom_candidate))
local _,_,_,stored_label,stored_custom=store.read_entry(cache_song,1)
assert(stored_label=="Explicit" and stored_custom==true)
cache_song.tool_data=""
assert(store.write_draft(cache_song,cache_instrument,nil,caller_source,"repeat",0))
caller_source.pitch_events[1].note=(caller_pitch+1)%120
local cached_draft=assert(store.read_draft(cache_song,cache_instrument,nil))
assert(cached_draft.pitch_events[1].note==caller_pitch,
  "draft cache publication must not retain the mutable caller source")
cached_draft.pitch_events[1].note=(caller_pitch+2)%120
assert(store.read_draft(cache_song,cache_instrument,nil).pitch_events[1].note==caller_pitch,
  "public draft reads must not expose cached decoded sources")

local replacement_instrument={name="Cache kit",phrases={}}
local replacement_song={tool_data="",instruments={replacement_instrument}}
assert(store.write_draft(replacement_song,replacement_instrument,nil,seq.new_pattern(9),"repeat",0))
cache_song.tool_data=replacement_song.tool_data
assert(store.read_draft(cache_song,cache_instrument,nil).length==9,
  "a raw store replacement must invalidate the decoded cache")

local function find_upvalue(fn,wanted)
  for index=1,100 do
    local name,value=debug.getupvalue(fn,index)
    if name==nil then break end
    if name==wanted then return index,value end
  end
end
local allocation_instrument={name="Allocation cache",phrases={}}
local allocation_song={tool_data=raw,instruments={allocation_instrument}}
renoise={song=function()return allocation_song end}
assert(store.read(allocation_song))
local _,read_decoded=find_upvalue(store.allocate,"read_decoded")
assert(read_decoded)
local decode_index,original_decode=find_upvalue(read_decoded,"decode")
assert(decode_index and original_decode)
local decode_calls=0
debug.setupvalue(read_decoded,decode_index,function(value)
  decode_calls=decode_calls+1
  return original_decode(value)
end)
local allocated_id,allocation_error=store.allocate(allocation_song)
assert(allocated_id==3 and decode_calls==0,
  "allocation repeated decoding for an unchanged raw cache key: id="..tostring(allocated_id).." error="..tostring(allocation_error).." calls="..decode_calls)
local changed_snapshot=snapshot:gsub("^2|","10|",1)
allocation_song.tool_data=header.."\n"..changed_snapshot.."\n"..
  label_record:gsub("^LABEL|2|","LABEL|10|",1).."\n"..draft.."\n"
assert(store.allocate(allocation_song)==11 and decode_calls==1,
  "allocation did not decode a changed raw cache key and observe its source ID")
debug.setupvalue(read_decoded,decode_index,original_decode)
renoise=nil

local failed_instrument={name="Failed cache",phrases={}}
local failed_song=setmetatable({instruments={failed_instrument}},{
  __index=function(_,key) if key=="tool_data" then return nil end end,
  __newindex=function(target,key,value)
    if key=="tool_data" then error("injected write failure") end
    rawset(target,key,value)
  end})
local failed,failed_error=store.write_draft(failed_song,failed_instrument,nil,
  seq.new_pattern(5),"repeat",0)
assert(not failed and failed_error and store.read_draft(failed_song,failed_instrument,nil)==nil,
  "a failed write must not publish its unpersisted draft into the decoded cache")

local function reject(record,category)
  song.tool_data=header.."\n"..record.."\n"..label_record.."\n"
  local before=song.tool_data
  local result,err=store.read(song)
  assert(not result and type(err)=="string",tostring(category)..": "..tostring(err))
  assert(not store.write_draft(song,instrument,nil,source,"repeat",24))
  assert(song.tool_data==before,"malformed data must remain untouched")
end

song.tool_data="ACID-PITCH-TIME-1\n"..snapshot.."\n"..label_record.."\n"
local schema1_raw=song.tool_data
assert(not store.read(song) and song.tool_data==schema1_raw,"schema 1 must remain read-only unsupported data")
song.tool_data=raw

for _,item in ipairs({{snapshot,"snapshot"},{draft,"draft"}}) do
  local record,kind=item[1],item[2]
  reject(record:gsub("|repeat|","|unsupported|",1),"Invalid ACID "..kind.." header")
  reject(record:gsub("|24|","|4|",1),"Invalid ACID "..kind.." header")
  reject(record:gsub("|3|17|","|33|17|",1),"Invalid ACID "..kind.." header")
  reject(record:gsub("|3|17|","|3|0|",1),"Invalid ACID "..kind.." header")
  reject(record:gsub("|triplet|","|unknown|",1),"Invalid ACID "..(kind=="draft" and "draft source:" or "source:"))
  reject(record:gsub("36:0:0:00,","36:0:0:02,",1),"Corrupt pitch")
  reject(record:gsub("36:0:0:00,","36:0:0:00,,",1),kind=="draft" and "Invalid ACID draft pitch data" or "Invalid pitch separators")
  reject(record:gsub("36:0:0:00,","",1),kind=="draft" and "Invalid ACID draft pitch data" or "ACID source must store exactly 32 pitches")
  reject(record.."|extra","Invalid ACID snapshot header")
  reject(record.."\n"..record,"Invalid ACID "..kind.." header at line 3")
end
reject(draft:gsub("4B69747C0A","4B69747C0",1),"Invalid ACID draft instrument identity")
reject(snapshot:gsub("^2|","2147483648|"),"Invalid ACID snapshot header")
reject(draft:gsub("^DRAFT|1|","DRAFT|0|"),"Invalid ACID draft header")
song.tool_data=header.."\n"..snapshot.."\n"..label_record.."\n"
assert(store.read(song)[2] and not store.has_drafts(song))
song.tool_data=header.."\n"..draft.."\n"
assert(next(assert(store.read(song)))==nil and store.has_drafts(song))
assert(store.read_draft(song,instrument,nil))
interpreter.compile_cycle=compile_cycle
print("ACID shared store codec grammar and byte fixtures passed")
