dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local own=require("renoise.phrase_ownership")
local store=require("renoise.pattern_store")
local host={__eq=function() error("host equality is not identity") end}
local phrase_limits={max_lines=1,max_note_columns=1,max_effect_columns=0,number_of_lines=1}
local make_phrase_fixture=dofile("tests/acid/complete_phrase_fixture.lua")
local function phrase(id)
  local p=setmetatable(make_phrase_fixture(phrase_limits),host)
  local cell=p.lines[1].note_columns[1]
  cell.note_value=48
  cell.is_empty=false
  local snapshot=assert(own.snapshot(p,phrase_limits))
  local seal_columns={}
  for column=1,12 do seal_columns[column]=p:column_is_muted(column) end
  p.name=assert(own.make_name_from_verified_snapshot(snapshot,id,seal_columns))
  return p
end
local a,b=phrase(1),phrase(2)
local first=setmetatable({name="First",phrases={a}},host)
local second=setmetatable({name="Second",phrases={b}},host)
local song=setmetatable({instruments={first,second}},host)
local current=song
renoise={song=function()return current end}
local source=seq.new_pattern(4)
assert(store.save(song,1,source,"repeat",12))
assert(store.save(song,2,source,"play_once",0))
assert(own.membership(song,first,a)==1)
local id,index,position=own.validate_live(song,first,a)
assert(id==1 and index==1 and position==1)
local equal_phrase=phrase(1)
first.phrases[1]=equal_phrase
assert(not own.validate_identity(song,first,a),
  "a content-equal phrase object cannot stand in for the selected live phrase")
first.phrases[1]=a
assert(store.load(song,first,a).length==4)
assert(not store.load(song,a),"source loading requires an explicit instrument and phrase")
local copied,policy,pb=store.read_entry(song,1)
assert(policy=="repeat" and pb==12)
copied.pitch_events[1].accent=true
assert(not store.read_entry(song,1).pitch_events[1].accent)
assert(not store.read_entry(song,99) and not store.read_entry(song,0))

local function rejected(instrument,target)
  local before=song.tool_data
  assert(not store.load(song,instrument,target))
  assert(not store.read_draft(song,instrument,target))
  assert(not store.write_draft(song,instrument,target,source,"repeat",0))
  assert(not store.clear_draft(song,instrument,target))
  assert(song.tool_data==before,"rejected access changed persistence")
end
assert(store.write_draft(song,first,a,source,"play_once",24))
assert(store.read_draft(song,first,a).length==4)
local single_draft=song.tool_data
local duplicate=assert(single_draft:match("(DRAFT|1|1|[^\n]+)\n")):gsub("^DRAFT|1|1|","DRAFT|2|1|")
song.tool_data=single_draft..duplicate.."\n"
local ambiguous_raw=song.tool_data
assert(not store.read_draft(song,first,a))
assert(not store.write_draft(song,first,a,source,"repeat",0))
assert(not store.clear_draft(song,first,a))
assert(song.tool_data==ambiguous_raw,"ambiguous persisted draft group must be preserved")
song.tool_data=single_draft
local replacement=phrase(1)
first.phrases[1]=replacement
assert(not own.validate_identity(song,first,a),"a missing target remained identity-valid")
rejected(first,a)
first.phrases[1]=a
song.instruments[1]=setmetatable({name="First",phrases={a}},host)
rejected(first,a)
song.instruments[1]=first

local collision=phrase(1)
second.phrases[2]=collision
local groups=assert(own.inventory(song))
assert(#groups[1]==2)
assert(not own.validate_identity(song,first,a),
  "a duplicate ID in another instrument remained identity-valid")
rejected(first,a)
assert(store.read_entry(song,1).length==4,"narrow collision read is source-only")
local validator=require('writers.phrase_validator')
local exclusion_calls={
 function(value)return own.inventory(song,value)end,
 function(value)return own.validate_identity(song,first,a,value)end,
 function(value)return own.validate_live(song,first,a,value)end,
 function(value)return store.load(song,first,a,value)end,
 function(value)return store.read_draft(song,first,a,value)end,
 function(value)return store.write_draft(song,first,a,source,'repeat',0,value)end,
 function(value)return store.clear_draft(song,first,a,value)end,
 function(value)return validator.classify(song,first,a,{}, {}, {},value)end,
 function(value)return validator.classify(song,first,a,{}, {}, {excluded=value})end,
}
local before_exclusions=song.tool_data
for _,value in ipairs({{[collision]=true},{[a]=true},{},{token={}},false})do
 for index,call in ipairs(exclusion_calls)do
  local result,reason=call(value)
  assert(not result and reason=='Ownership exclusions are not supported',index..': '..tostring(reason))
  assert(song.tool_data==before_exclusions,'exclusion attempt wrote persistence')
 end
end
-- Explicit nil surplus arguments must also reject under Lua 5.1.
for index=1,8 do
 local result,reason=exclusion_calls[index](nil)
 assert(not result and reason=='Ownership exclusions are not supported')
end
assert(#assert(own.inventory(song))[1]==2,'all holders remain in ownership inventory')
second.phrases[2]=nil

local original_name=a.name
local drift_name=phrase(2).name
local name_reads=0
rawset(a,"name",nil)
setmetatable(a,{__index=function(_,key)
  if key=="name" then
    name_reads=name_reads+1
    return name_reads<=2 and original_name or drift_name
  end
end,__eq=host.__eq})
local drift_id,drift_error=own.validate_identity(song,first,a)
assert(not drift_id and drift_error:find("identity changed",1,true),
  "identity validation accepted a target ID that drifted during the inventory scan")
rawset(a,"name",original_name)
setmetatable(a,host)

local raw=song.tool_data
assert(store.write_draft(song,first,nil,source,"repeat",0))
local with_scratch=song.tool_data
local foreign={name="Foreign"}
first.phrases[2]=foreign
rejected(first,foreign)
assert(store.read_draft(song,first,nil).length==4,"foreign target must not become New")
first.phrases[2]=nil
first.name="Renamed"
assert(not store.read_draft(song,first,nil))
assert(not store.clear_draft(song,first,nil))
assert(not store.write_draft(song,first,nil,source,"repeat",0))
assert(song.tool_data==with_scratch)
first.name="First"
second.name="First"
rejected(first,nil)
second.name="Second"
song.tool_data=raw

local missing=phrase(3)
first.phrases[2]=missing
rejected(first,missing)
song.tool_data="corrupt"
rejected(first,a)
assert(not store.read_entry(song,1))
song.tool_data=raw
current={instruments={first,second}}
rejected(first,a)
assert(not own.inventory(song),"released song inventory is unavailable")
current=song
renoise.song=function()error("released host")end
rejected(first,a)
renoise.song=function()return song end

local unreadable=setmetatable({},{__index=function()error("removed object")end})
second.phrases[2]=unreadable
assert(not own.inventory(song))
assert(not store.load(song,first,a))
second.phrases[2]=nil
local status=own.status
own.status=function()error("unreadable content")end
assert(not store.load(song,first,a))
own.status=status
local line=a.line
a.line=function()error("removed lines")end
assert(own.inventory(song)[1][1].phrase==a,"name inventory must not hash phrase cells")
assert(not store.load(song,first,a))
local dirty_cell_draft=assert(store.read_draft(song,first,a))
assert(dirty_cell_draft.length==4,
  "draft reads must use unique identity without hashing edited phrase cells")
assert(store.write_draft(song,first,a,dirty_cell_draft,"repeat",0),
  "draft writes must remain available when native phrase cells are edited")
assert(store.read_draft(song,first,a).length==4,
  "draft persistence lost source while native phrase cells were edited")
a.line=line

assert(store.clear_draft(song,first,a))
assert(store.read_draft(song,first,a)==nil)
assert(store.clear_draft(song,first,a)==false)

local prior_current=current
local prior_song_accessor=renoise.song
renoise.song=function()return current end
local function draft_write_fixture(mode)
  local backing,fail_readback
  local destination={name="Draft write",phrases={}}
  local draft_song=setmetatable({instruments={destination}},{
    __index=function(_,key)
      if key=="tool_data" then
        if fail_readback then error("readback unavailable") end
        return backing
      end
    end,
    __newindex=function(target,key,value)
      if key~="tool_data" then rawset(target,key,value);return end
      if mode=="unchanged" then error("setter rejected write") end
      if mode=="partial_then_throw" then backing="partial ACID record";error("setter failed after partial mutation") end
      backing=value
      if mode=="mutate_then_throw" then error("setter failed after mutation") end
      if mode=="failed_readback" then fail_readback=true end
    end})
  return draft_song,destination,function()return backing end
end
local write_source=seq.new_pattern(2)
local partial_song,partial_instrument,partial_data=draft_write_fixture("mutate_then_throw")
current=partial_song
assert(rawequal(renoise.song(),partial_song))
local persisted,partial_error=store.write_draft(partial_song,partial_instrument,nil,write_source,"repeat",0)
assert(not persisted and partial_error:find("restored",1,true),
  "a throwing draft setter must abort after exact rollback")
assert(partial_data()==nil,"failed draft publication did not restore absent storage")
local unchanged_song,unchanged_instrument,unchanged_data=draft_write_fixture("unchanged")
current=unchanged_song
local unchanged,unchanged_error=store.write_draft(unchanged_song,unchanged_instrument,nil,write_source,"repeat",0)
assert(not unchanged and unchanged_error:find("unchanged",1,true) and unchanged_data()==nil,
  "a failed setter with verified previous storage is classified as unchanged")
local partial_song,partial_instrument,partial_value=draft_write_fixture("partial_then_throw")
current=partial_song
local partial,partial_error=store.write_draft(partial_song,partial_instrument,nil,write_source,"repeat",0)
assert(not partial and partial_error:find("uncertain",1,true) and partial_value()=="partial ACID record",
  "a visible partial mutation is reported as uncertain")
local unreadable_song,unreadable_instrument,unreadable_data=draft_write_fixture("failed_readback")
current=unreadable_song
local unreadable,unreadable_error=store.write_draft(unreadable_song,unreadable_instrument,nil,write_source,"repeat",0)
assert(not unreadable and unreadable_error:find("uncertain",1,true) and type(unreadable_data())=="string",
  "a failed readback after mutation is classified as uncertain")
current=prior_current
renoise.song=prior_song_accessor
print("ACID live identity and guarded durable draft checks passed")
