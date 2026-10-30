dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local store=require("renoise.pattern_store")
local song={instruments={{name="Instrument",phrases={}}}}
local current=song
renoise={song=function()return current end}
local source=seq.new_pattern(4)
assert(store.save(song,1,source,"repeat",12))
assert(store.write_draft(song,song.instruments[1],nil,source,"repeat",12))
local raw=song.tool_data
local draft=assert(raw:match("(DRAFT|1|0|[^\n]+)\n"))
song.tool_data=raw..draft:gsub("^DRAFT|1|0|","DRAFT|1|7|").."\n"
local retained=song.tool_data
assert(store.allocate(song)==8,"retained orphan draft IDs must not be reused")
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
local candidate=assert(store.prepare(song,8,source,"repeat",12,function()return true end))
assert(store.candidate_status(candidate))
store.release_candidate(candidate)
assert(not store.candidate_status(candidate),"released candidates must lose their host registry state immediately")
assert(not store.commit(song,candidate),"released candidates cannot commit")
store.release_candidate(candidate)
print("ACID guarded ID allocation checks passed")
