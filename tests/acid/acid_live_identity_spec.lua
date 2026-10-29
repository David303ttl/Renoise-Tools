dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local own=require("writers.phrase_ownership")
local store=require("model.pattern_store")
local host={__eq=function() error("host equality is not identity") end}
local function phrase(id)
  local cell={note_value=48,instrument_value=255,volume_value=255,panning_value=255,
    delay_value=0,effect_number_value=0,effect_amount_value=0}
  local p=setmetatable({name="",number_of_lines=1,visible_note_columns=1,
    visible_effect_columns=0},host)
  function p:line()return {note_columns={cell}}end
  function p:column_is_muted()return false end
  p.name=assert(own.make_name(p,id))
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
rejected(first,a)
first.phrases[1]=a
song.instruments[1]=setmetatable({name="First",phrases={a}},host)
rejected(first,a)
song.instruments[1]=first

local collision=phrase(1)
second.phrases[2]=collision
local groups=assert(own.inventory(song))
assert(#groups[1]==2)
rejected(first,a)
assert(store.read_entry(song,1).length==4,"narrow collision read is source-only")
assert(own.validate_live(song,first,a,{[collision]=true})==1)
assert(store.load(song,first,a,{[collision]=true}).length==4)
assert(not own.validate_live(song,first,a,{[a]=true}),"excluded target is not an owner")
second.phrases[2]=nil

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
assert(persisted,partial_error or "a setter error with exact requested readback is verified success")
assert(type(partial_data())=="string" and partial_data():find("DRAFT|",1,true))
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
