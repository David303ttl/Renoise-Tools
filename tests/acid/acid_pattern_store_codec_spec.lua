dofile("tests/bootstrap.lua")("acid")
local store=require("renoise.pattern_store")
local interpreter=require("model.cycle_interpreter")
local compile_cycle=interpreter.compile_cycle
interpreter.compile_cycle=function() error("Storage validation must not build playback plans") end
local file=assert(io.open("tests/acid/fixtures/pattern_store.txt","rb"))
local raw=file:read("*a")
file:close()
local header,snapshot,draft=raw:match("([^\n]+)\n([^\n]+)\n([^\n]+)\n$")
assert(header and snapshot and draft)
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
local restored,policy,pb=store.read_draft(song,instrument,nil)
assert(restored and policy=="repeat" and pb==24)
assert(store.write_draft(song,instrument,nil,restored,policy,pb))
assert(song.tool_data==raw,"snapshot and draft encoding must match the saved fixture")
assert(store.save(song,2,source,"repeat",24))
assert(song.tool_data==raw,"snapshot encoding must preserve draft bytes")

local sequencer=require("model.sequencer")
local cache_instrument={name="Cache kit",phrases={}}
local cache_song={tool_data="",instruments={cache_instrument}}
local caller_source=sequencer.copy_source(source)
local caller_pitch=caller_source.pitch_events[1].note
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
assert(store.write_draft(replacement_song,replacement_instrument,nil,sequencer.new_pattern(9),"repeat",0))
cache_song.tool_data=replacement_song.tool_data
assert(store.read_draft(cache_song,cache_instrument,nil).length==9,
  "a raw store replacement must invalidate the decoded cache")

local failed_instrument={name="Failed cache",phrases={}}
local failed_song=setmetatable({instruments={failed_instrument}},{
  __index=function(_,key) if key=="tool_data" then return nil end end,
  __newindex=function(target,key,value)
    if key=="tool_data" then error("injected write failure") end
    rawset(target,key,value)
  end})
local failed,failed_error=store.write_draft(failed_song,failed_instrument,nil,
  sequencer.new_pattern(5),"repeat",0)
assert(not failed and failed_error and store.read_draft(failed_song,failed_instrument,nil)==nil,
  "a failed write must not publish its unpersisted draft into the decoded cache")

local function reject(record,category)
  song.tool_data=header.."\n"..record.."\n"
  local before=song.tool_data
  local result,err=store.read(song)
  assert(not result and err:find(category,1,true),tostring(err))
  assert(not store.write_draft(song,instrument,nil,source,"repeat",24))
  assert(song.tool_data==before,"malformed data must remain untouched")
end

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
song.tool_data=header.."\n"..snapshot.."\n"
assert(store.read(song)[2] and not store.has_drafts(song))
song.tool_data=header.."\n"..draft.."\n"
assert(next(assert(store.read(song)))==nil and store.has_drafts(song))
assert(store.read_draft(song,instrument,nil))
interpreter.compile_cycle=compile_cycle
print("ACID shared store codec grammar and byte fixtures passed")
