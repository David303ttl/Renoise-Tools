dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local store=require("renoise.pattern_store")
local SOURCE_ID=1
local RETAINED_DRAFT_ID=7
local NEXT_ID=8
local FOLLOWING_ID=NEXT_ID+1
local LIVE_PHRASE_ID=12
local NEXT_LIVE_ID=LIVE_PHRASE_ID+1
local song={instruments={{name="Instrument",phrases={}}}}
local current=song
renoise={song=function()return current end}
local source=seq.new_pattern(4)
assert(store.save(song,SOURCE_ID,source,"repeat",12))
assert(store.write_draft(song,song.instruments[1],nil,source,"repeat",12))
local raw=song.tool_data
local draft=assert(raw:match("(DRAFT|1|0|[^\n]+)\n"))
song.tool_data=raw..draft:gsub("^DRAFT|1|0|","DRAFT|1|"..RETAINED_DRAFT_ID.."|").."\n"
local retained=song.tool_data
assert(store.allocate(song)==NEXT_ID,"retained orphan draft IDs must not be reused")
assert(song.tool_data==retained,"allocation must not rewrite retained persistence")
song.instruments[1].phrases={setmetatable({}, {__index=function()error("unreadable phrase")end})}
local ok,id,reason=pcall(store.allocate,song)
assert(ok and id==nil and type(reason)=="string","unreadable names must reject safely")
assert(song.tool_data==retained)
current={instruments={}}
assert(not store.allocate(song),"released songs cannot allocate IDs")
assert(song.tool_data==retained)
current=song
song.instruments[1].phrases={}
local candidate=assert(store.prepare(song,NEXT_ID,source,"repeat",12,function()return true end))
assert(store.candidate_status(candidate))
assert(song.tool_data==retained,"candidate preparation must preserve committed sources and drafts")
store.release_candidate(candidate)
assert(not store.candidate_status(candidate),"released candidates must lose their host registry state immediately")
assert(not store.commit(song,candidate),"released candidates cannot commit")
store.release_candidate(candidate)

local before_failed_prepare=song.tool_data
local invalid_source={}
local rejected,prepare_error=store.prepare(song,FOLLOWING_ID,invalid_source,"repeat",12,function()return true end)
assert(not rejected and type(prepare_error)=="string","invalid source must reject candidate preparation")
assert(song.tool_data==before_failed_prepare,"failed preparation must preserve source and draft bytes")
assert(store.allocate(song)==NEXT_ID,"failed preparation must not reserve or consume an ID")

song.instruments[1].phrases={{name=string.format("ACID 0.1 #%d [v3:00000000]",LIVE_PHRASE_ID)}}
assert(store.allocate(song)==NEXT_LIVE_ID,"live phrase IDs without source records must not be reused")
assert(song.tool_data==before_failed_prepare,"live-name allocation must not rewrite source and draft bytes")
song.instruments[1].phrases={}

local corrupt_data="unreadable ACID data"
song.tool_data=corrupt_data
local allocated,allocation_error=store.allocate(song)
assert(not allocated and type(allocation_error)=="string","corrupt storage must block ID allocation")
local corrupt_candidate,corrupt_error=store.prepare(song,NEXT_ID,source,"repeat",12,function()return true end)
assert(not corrupt_candidate and type(corrupt_error)=="string","corrupt storage must block candidate preparation")
assert(song.tool_data==corrupt_data,"failed allocation and preparation must preserve corrupt storage exactly")
print("ACID guarded ID allocation checks passed")
