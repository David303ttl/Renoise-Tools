dofile("tests/bootstrap.lua")("acid")
local store=require("renoise.pattern_store")
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
local restored,policy,pb=store.read_draft(song,instrument,nil)
assert(restored and policy=="repeat" and pb==24)
assert(store.write_draft(song,instrument,nil,restored,policy,pb))
assert(song.tool_data==raw,"snapshot and draft encoding must match the saved fixture")
assert(store.save(song,2,source,"repeat",24))
assert(song.tool_data==raw,"snapshot encoding must preserve draft bytes")

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
print("ACID shared store codec grammar and byte fixtures passed")
