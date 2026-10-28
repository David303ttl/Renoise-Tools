package.path = "com.david303ttl.ACID.xrnx/?.lua;" .. package.path

local sequencer = require("model.sequencer")
package.loaded["writers.phrase_ownership"]={
  id=function(phrase) return phrase and phrase.id end,
  status=function(phrase)return phrase and phrase.id and "owned" or "foreign" end
}
local cache = require("model.draft_cache")

local instrument_a, instrument_b = {name="A",phrases={}}, {name="B",phrases={}}
local song_a, song_b = {instruments={instrument_a,instrument_b}}, {instruments={}}
local phrase_a, phrase_b = {id=41}, {id=42}
local host_object = {__eq=function()
  error("Renoise host objects do not provide __eq")
end}
setmetatable(instrument_a,host_object)
setmetatable(instrument_b,host_object)
setmetatable(phrase_a,host_object)
setmetatable(phrase_b,host_object)
instrument_a.phrases={phrase_a,phrase_b}
local source = sequencer.new_pattern(17)
source.pitch_length = 4
source.pitch_events[3] = sequencer.new_pitch(5, 1, true, true)
source.time_events[17] = "R"

assert(cache.put(song_a, instrument_a, phrase_a, source, "play_once",24))
source.pitch_events[3].note = 36
local restored, policy, pb_range = cache.get(song_a, instrument_a, phrase_a)
assert(restored and restored.pitch_events[3].note == 53)
assert(restored.pitch_length == 4 and restored.length == 17)
assert(restored.time_events[17] == "R" and policy == "play_once" and pb_range==24)
assert(restored.pb_range==nil,"PB range remains outside canonical PITCH/TIME source")

-- Lookup must pass other host objects without invoking their equality operator.
assert(cache.put(song_a,instrument_b,nil,sequencer.new_pattern(3),"repeat"))
assert(cache.get(song_a,instrument_b,nil).length==3)
assert(cache.clear(song_a,instrument_b,nil))

-- Returned values are detached from cached canonical data.
restored.time_events[17] = "N"
restored.pitch_events[3].accent = false
local pristine,_,pristine_pb = cache.get(song_a, instrument_a, phrase_a)
assert(pristine.time_events[17] == "R" and pristine.pitch_events[3].accent)
assert(pristine_pb==24)

-- All three host object identities scope a draft independently.
assert(cache.put(song_a, instrument_a, phrase_b, sequencer.new_pattern(8), "repeat"))
assert(cache.get(song_a, instrument_a, phrase_b).length == 8)
assert(cache.get(song_a, instrument_b, phrase_a) == nil)
assert(cache.get(song_b, instrument_a, phrase_a) == nil)

-- A not-yet-created phrase has a distinct destination key for its instrument.
local new_destination = sequencer.new_pattern(23)
assert(cache.put(song_a, instrument_a, nil, new_destination, "repeat"))
assert(cache.get(song_a, instrument_a, nil).length == 23)
assert(cache.get(song_a, instrument_a, phrase_a).length == 17)
local foreign_phrase={}
instrument_a.phrases[#instrument_a.phrases+1]=foreign_phrase
assert(cache.get(song_a,instrument_a,foreign_phrase)==nil)
assert(cache.clear(song_a,instrument_a,foreign_phrase)==false)
assert(cache.get(song_a,instrument_a,nil).length==23,
  "clearing a foreign phrase cannot remove the new-phrase draft")
instrument_a.phrases[#instrument_a.phrases]=nil

-- Drafts survive a new editor session and committed source rewrites preserve them.
package.loaded["model.draft_cache"]=nil
cache=require("model.draft_cache")
local durable,_,durable_pb=cache.get(song_a,instrument_a,phrase_a)
assert(durable.length==17 and durable.pitch_events[3].note==53)
assert(durable_pb==24)
local pattern_store=require("model.pattern_store")
assert(pattern_store.save(song_a,77,sequencer.new_pattern(4),"repeat",12))
package.loaded["model.draft_cache"]=nil
cache=require("model.draft_cache")
durable,_,durable_pb=cache.get(song_a,instrument_a,phrase_a)
assert(durable.length==17 and durable.time_events[17]=="R")
assert(durable_pb==24)

-- Existing phrase drafts resolve by sealed ID after instrument reordering.
song_a.instruments={instrument_b,instrument_a}
assert(cache.get(song_a,instrument_a,phrase_a).length==17)
package.loaded["model.draft_cache"]=nil
cache=require("model.draft_cache")
assert(cache.get(song_a,instrument_b,nil)==nil,
  "a reordered new-phrase destination is never rebound by index alone")
local named_instrument={name="Unique",phrases={}}
local named_song={instruments={named_instrument}}
assert(cache.put(named_song,named_instrument,nil,sequencer.new_pattern(6),"repeat"))
package.loaded["model.draft_cache"]=nil
cache=require("model.draft_cache")
named_song.instruments={named_instrument,{name="Unique",phrases={}}}
assert(cache.get(named_song,named_instrument,nil)==nil,
  "ambiguous instrument names block new-phrase draft recovery")
local ambiguous,ambiguous_error=cache.put(named_song,named_instrument,nil,
  sequencer.new_pattern(7),"repeat")
assert(not ambiguous and ambiguous_error:find("ambiguous",1,true),
  "duplicate names report that durable destination identity is unavailable")
instrument_a.phrases={phrase_b}
assert(cache.get(song_a,instrument_a,phrase_a)==nil)
instrument_a.phrases={phrase_a,phrase_b}

-- A draft-only write rebases an in-flight source candidate and survives its commit.
local candidate=assert(pattern_store.prepare(song_a,88,sequencer.new_pattern(5),"repeat",48))
local changed=sequencer.new_pattern(19)
changed.pitch_events[2]=sequencer.new_pitch(7,0,true,false)
assert(cache.put(song_a,instrument_a,phrase_a,changed,"repeat",12))
local committed,commit_error=pattern_store.commit(song_a,candidate)
assert(committed,commit_error)
local merged=assert(pattern_store.read(song_a))
assert(merged[88].pattern.length==5 and merged[88].pb_range==48)
package.loaded["model.draft_cache"]=nil
cache=require("model.draft_cache")
local recovered,_,recovered_pb=cache.get(song_a,instrument_a,phrase_a)
assert(recovered.length==19 and recovered.pitch_events[2].note==43,
  "commit preserves the newest dirty draft while storing the rendered source")
assert(recovered_pb==12)
assert(pattern_store.restore(song_a,candidate))
local rolled_back=assert(pattern_store.read(song_a))
assert(rolled_back[88]==nil,
  "rollback removes only the source snapshot from the in-flight render")
local persisted_draft,_,persisted_pb=pattern_store.read_draft(song_a,1,41,"A")
assert(persisted_draft.length==19 and persisted_draft.pitch_events[2].note==43,
  "rollback restores the rebased raw data and preserves the newest draft")
assert(persisted_pb==12)

-- A concurrent source-record change still rejects the prepared candidate.
local stale_candidate=assert(pattern_store.prepare(song_a,89,sequencer.new_pattern(6),"repeat"))
assert(pattern_store.save(song_a,90,sequencer.new_pattern(7),"repeat"))
local stale,stale_error=pattern_store.commit(song_a,stale_candidate)
assert(not stale and stale_error=="ACID song data changed during generation")
assert(pattern_store.read(song_a)[90]~=nil and pattern_store.read(song_a)[89]==nil)

-- Corrupt persistence leaves a recoverable volatile draft and reports the fault.
local volatile_instrument={name="Volatile",phrases={}}
local volatile_song={tool_data="corrupt",instruments={volatile_instrument}}
local volatile=sequencer.new_pattern(3)
local persisted,persist_error=cache.put(volatile_song,volatile_instrument,nil,volatile,"repeat",24)
assert(not persisted and type(persist_error)=="string")
local volatile_copy,_,volatile_pb=cache.get(volatile_song,volatile_instrument,nil)
assert(volatile_copy.length==3 and volatile_pb==24)
assert(cache.has_volatile(volatile_song) and not cache.has_volatile(song_a))

-- Successful commit calls clear; repeated clear and unrelated targets are safe.
assert(cache.clear(song_a, instrument_a, phrase_a))
assert(cache.get(song_a, instrument_a, phrase_a) == nil)
assert(not cache.clear(song_a, instrument_a, phrase_a))
assert(cache.get(song_a, instrument_a, phrase_b) ~= nil)
assert(cache.get(song_a, instrument_a, nil) == nil,
  "reordered unbound new-phrase drafts remain unavailable for automatic recovery")

assert(not cache.put(song_a, instrument_a, phrase_a, {}, "repeat"))
assert(not cache.put(song_a, instrument_a, phrase_a, sequencer.new_pattern(), "invalid_policy"))
assert(not cache.put(song_a,instrument_a,phrase_a,sequencer.new_pattern(),"repeat",4))
print("acid_draft_cache_spec: ok")
