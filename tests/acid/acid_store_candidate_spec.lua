dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local own=require("renoise.phrase_ownership")
local store=require("renoise.pattern_store")
local current
renoise={song=function()return current end}
local function yes()return true end
local function phrase(id)
  local p={name="",number_of_lines=1,visible_note_columns=1,visible_effect_columns=0}
  function p:line()return {note_columns={{note_value=48,instrument_value=255,
    volume_value=255,panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}}}end
  function p:column_is_muted()return false end
  p.name=assert(own.make_name(p,id));return p
end
local function fresh()
  local a,b=phrase(1),phrase(2)
  local ins={name="First",phrases={a,b}}
  local other={name="Second",phrases={}}
  local song={instruments={ins,other}}
  current=song
  assert(store.save(song,1,seq.new_pattern(4),"repeat",0))
  assert(store.save(song,2,seq.new_pattern(4),"repeat",0))
  return song,ins,a,b,other
end
local default_pitches=string.rep("36:0:0:00,",31).."36:0:0:00"
local default_time=string.rep("N",32)
local default_mask="0|111111111111"
local function source_row(id,policy,pb_range,length)
  return table.concat({tostring(id),policy or "repeat",tostring(pb_range or 0),"straight","16",
    tostring(length or 4),default_mask,
    default_pitches,default_time},"|")
end
local function label_row(id)
  local text="Pattern "..id
  local hex=text:gsub(".",function(byte)return string.format("%02X",string.byte(byte))end)
  return table.concat({"LABEL",tostring(id),"0",hex},"|")
end
local function removal(ins,p,token,revision)
  return {kind=p and "existing" or "new",instrument=ins,phrase=p,
    token=token or {},revision=revision or 1}
end
local function prepare(song,id,guard,capture)
  return assert(store.prepare(song,id,seq.new_pattern(5),"play_once",12,guard or yes,capture))
end
for _,operation in ipairs({"label","draft"}) do
  for _,has_draft in ipairs({false,true}) do
    local song,ins,owned=fresh()
    if has_draft then assert(store.write_draft(song,ins,owned,seq.new_pattern(6),"repeat",0)) end
    local previous=song.tool_data
    local stored=previous
    local write_attempts=0
    song.tool_data=nil
    setmetatable(song,{
      __index=function(_,key)if key=="tool_data" then return stored end end,
      __newindex=function(target,key,value)
        if key=="tool_data" then
          write_attempts=write_attempts+1
          error("injected rejected metadata write")
        end
        rawset(target,key,value)
      end})
    if operation=="label" then
      assert(not store.update_label(song,ins,owned,"Rejected",true,previous))
    else
      assert(not store.write_draft_metadata(song,ins,owned,seq.new_pattern(7),"repeat",0,"Rejected",true))
    end
    assert(write_attempts==1,"metadata regression must reach the failing persistence setter")
    assert(stored==previous)
    local _,_,_,label,custom=store.read_entry(song,1)
    assert(label=="Pattern 1" and custom==false,
      "failed owned metadata writes must preserve cached committed metadata")
    local draft,_,_,draft_label,draft_custom=store.read_draft(song,ins,owned)
    assert((not has_draft and not draft) or
      (draft and draft.length==6 and draft_label=="Pattern 1" and draft_custom==false),
      "failed owned metadata writes must preserve cached pending metadata")
    getmetatable(song).__newindex=function(target,key,value)
      if key=="tool_data" then stored=value else rawset(target,key,value) end
    end
    assert(store.save(song,3,seq.new_pattern(5),"repeat",0))
    assert(not stored:find("52656A6563746564",1,true),
      "an unrelated source write must not persist rejected label metadata")
    local _,_,_,persisted_label,persisted_custom=store.read_entry(song,1)
    assert(persisted_label=="Pattern 1" and persisted_custom==false)
  end
end
for _,restore_fails in ipairs({false,true}) do
  local song,ins,owned=fresh()
  local previous=song.tool_data
  local stored,attempts=previous,0
  song.tool_data=nil
  setmetatable(song,{
    __index=function(_,key)if key=="tool_data" then return stored end end,
    __newindex=function(target,key,value)
      if key~="tool_data" then rawset(target,key,value);return end
      attempts=attempts+1
      if attempts==1 then stored=value;error("draft setter failed after assignment") end
      if restore_fails then error("draft restore failed") end
      stored=value
    end})
  local saved,reason=store.write_draft_metadata(song,ins,owned,seq.new_pattern(7),"repeat",0,"Rejected",true)
  assert(not saved and type(reason)=="string","throwing draft setter was accepted")
  assert(attempts==2,"throwing draft setter did not attempt exact rollback")
  if restore_fails then
    assert(stored~=previous and reason:find("uncertain",1,true),"failed restore concealed changed storage")
  else
    assert(stored==previous and store.read_draft(song,ins,owned)==nil,
      "failed draft publication did not restore exact store/cache preimage")
  end
end
local byte_song,byte_ins=fresh()
assert(store.write_draft(byte_song,byte_ins,nil,seq.new_pattern(6),"repeat",0))
local byte_candidate=prepare(byte_song,3)
local expected_candidate_draft=table.concat({"DRAFT","1","0","4669727374","556E7469746C6564","0",
  "repeat","0","straight","16","6",default_mask,default_pitches,default_time},"|")
local expected_candidate_raw=table.concat({"ACID-PITCH-TIME-2",source_row(1),source_row(2),
  source_row(3,"play_once",12,5),label_row(1),label_row(2),label_row(3),expected_candidate_draft},"\n").."\n"
assert(byte_candidate.raw==expected_candidate_raw,
  "prepared source/draft composition changed the exact persisted bytes\n"..
  tostring(byte_candidate.raw).."\nEXPECTED\n"..expected_candidate_raw)
store.release_candidate(byte_candidate)
local song,ins,a,b,other=fresh()
assert(store.write_draft(song,ins,nil,seq.new_pattern(6),"repeat",0))
other.name=ins.name
local session_only=removal(ins,nil)
session_only.instrument_name_unique=false
session_only.instrument_index=1
session_only.instrument_name=ins.name
local session_candidate=prepare(song,3,function(token,revision)
  return token==session_only.token and revision==session_only.revision
end,session_only)
assert(store.commit(song,session_candidate),"session-only New drafts must not block source creation")
assert(store.read_entry(song,3))
assert(store.has_drafts(song),"ambiguous older durable scratch must be preserved")
other.name="Second"
assert(store.read_draft(song,ins,nil).length==6,
  "a session-only commit cannot delete an older durable scratch")
local detached=removal({name=ins.name,phrases={}},nil)
detached.instrument_name_unique=false
assert(not store.prepare(song,4,seq.new_pattern(5),"repeat",0,yes,detached),
  "session-only capture still requires a live instrument")
song,ins,a,b,other=fresh()
-- Candidate work must not mutate the decoded cache for its previous raw bytes.
local cached_history=assert(store.read(song))
local cached_candidate=prepare(song,3)
assert(store.commit(song,cached_candidate) and store.restore(song,cached_candidate))
local restored_history=assert(store.read(song))
assert(restored_history[1] and restored_history[2] and not restored_history[3] and
  cached_history[1] and cached_history[2] and not cached_history[3],
  "candidate preparation or rollback mutated the cached decoded source history")
song,ins,a,b,other=fresh()
local raw_candidate=prepare(song,3)
assert(store.commit(song,raw_candidate))
song,ins,a,b,other=fresh()
local source=seq.new_pattern(7)
assert(store.write_draft(song,ins,a,source,"repeat",24))
local expected_draft=table.concat({"DRAFT","1","1","4669727374","5061747465726E2031","0",
  "repeat","24","straight","16","7",default_mask,default_pitches,default_time},"|")
local expected_store=table.concat({"ACID-PITCH-TIME-2",source_row(1),source_row(2),
  label_row(1),label_row(2),expected_draft},"\n").."\n"
assert(song.tool_data==expected_store,"source and draft wire format changed")
assert(store.write_draft(song,ins,b,source,"repeat",2))
assert(store.write_draft(song,other,nil,source,"repeat",0))
local descriptor=removal(ins,a)
local token,revision=descriptor.token,descriptor.revision
local calls=0
local candidate=prepare(song,1,function(t,r)
  calls=calls+1;return rawequal(t,token) and r==revision
end,descriptor)
descriptor.instrument=other;descriptor.phrase=b;descriptor.token={};descriptor.revision=99
candidate.raw="forged";candidate.previous_raw="forged";candidate.id=2
assert(store.commit(song,candidate) and calls==1)
assert(store.read_entry(song,1).length==5)
assert(store.read_draft(song,ins,a)==nil)
assert(store.read_draft(song,ins,b).length==7 and store.read_draft(song,other,nil).length==7)
local status=assert(store.candidate_status(candidate))
assert(status.write_attempted and status.written_verified and not status.integrity_uncertain)
status.written_raw="forged";status.write_attempted=false
assert(store.candidate_status(candidate).write_attempted)
assert(not store.commit(song,candidate),"a candidate cannot be reused")
assert(store.restore(song,candidate) and store.restore(song,candidate))
assert(store.read_entry(song,1).length==4 and store.read_draft(song,ins,a).length==7)

song,ins,a,b,other=fresh()
descriptor=removal(ins,a)
candidate=prepare(song,1,yes,descriptor)
assert(store.write_draft(song,ins,a,source,"repeat",0))
local added_draft_raw=song.tool_data
assert(not store.commit(song,candidate) and song.tool_data==added_draft_raw,
  "any raw-store change after candidate capture must reject without merging")
assert(store.read_draft(song,ins,a).length==7,"conflict must preserve the added draft")

song,ins,a,b,other=fresh()
assert(store.write_draft(song,ins,a,source,"repeat",0))
candidate=prepare(song,1,yes,removal(ins,a))
assert(store.write_draft(song,ins,a,seq.new_pattern(8),"repeat",0))
assert(store.write_draft(song,other,nil,seq.new_pattern(9),"repeat",0))
local changed_drafts_raw=song.tool_data
assert(not store.commit(song,candidate) and song.tool_data==changed_drafts_raw)
assert(store.read_draft(song,ins,a).length==8 and store.read_draft(song,other,nil).length==9)

song,ins,a=fresh()
assert(store.write_draft(song,ins,a,source,"repeat",0))
candidate=prepare(song,1,yes,removal(ins,a))
assert(store.write_draft(song,ins,a,source,"play_once",24))
local changed_settings_raw=song.tool_data
assert(not store.commit(song,candidate) and song.tool_data==changed_settings_raw)
local _,policy,pb=store.read_draft(song,ins,a)
assert(policy=="play_once" and pb==24,"changed draft settings are preserved")

song,ins,a=fresh()
assert(store.write_draft(song,ins,a,source,"repeat",0))
local edit_revision=1
candidate=prepare(song,1,function(_,r)return r==edit_revision end,removal(ins,a,{},edit_revision))
assert(store.write_draft(song,ins,a,seq.new_pattern(8),"repeat",0))
assert(store.write_draft(song,ins,a,source,"repeat",0))
edit_revision=3
local before=song.tool_data
assert(not store.commit(song,candidate) and song.tool_data==before,
  "equal-valued newer edits invalidate the request through its captured revision")

song,ins,a=fresh()
assert(store.write_draft(song,ins,a,source,"repeat",0))
candidate=prepare(song,3)
assert(store.commit(song,candidate) and store.read_draft(song,ins,a).length==7,
  "metadata-only source cloning has no draft removal")
assert(not store.prepare(song,4,source,"repeat",0,yes,removal(ins,a)),
  "a fresh identity cannot remove the old identity's draft")

for _,change in ipairs({"none","rename","reorder","collision","added"})do
  song,ins,a,b,other=fresh()
  if change~="added" then assert(store.write_draft(song,ins,nil,source,"repeat",0))end
  candidate=prepare(song,3,yes,removal(ins,nil))
  if change=="rename"then ins.name="Renamed"
  elseif change=="reorder"then song.instruments={other,ins}
  elseif change=="collision"then other.name=ins.name
  elseif change=="added"then assert(store.write_draft(song,ins,nil,source,"repeat",0))end
  local before=song.tool_data
  if change=="added" then
    assert(not store.commit(song,candidate) and song.tool_data==before)
    assert(store.has_drafts(song),"a concurrently added draft must be preserved")
  else
    assert(store.commit(song,candidate))
    assert(store.has_drafts(song)==(change~="none"),"New scratch removal policy: "..change)
  end
end

song,ins,a=fresh()
for _,invalid in ipairs({{kind="existing",instrument=ins,token={},revision=1},
    {kind="new",instrument=ins,phrase=a,token={},revision=1},
    {instrument=ins,phrase=a,token={},revision=1},
    {kind="existing",instrument=ins,phrase=a,revision=1},
    {kind="existing",instrument=ins,phrase=a,token={},revision=1.5}})do
  assert(not store.prepare(song,1,source,"repeat",0,yes,invalid))
end
assert(not store.prepare(song,1,source,"repeat",0),"request guard is mandatory")
local hostile=setmetatable({}, {__index=function()error("unreadable descriptor")end})
before=song.tool_data
assert(not store.prepare(song,1,source,"repeat",0,yes,hostile) and song.tool_data==before,
  "non-value draft descriptors reject before their fields are accessed")
candidate=prepare(song,1,function()error("guard failure")end)
before=song.tool_data
assert(not store.commit(song,candidate) and song.tool_data==before)
candidate=prepare(song,1,function()current={instruments={}};return true end)
assert(not store.commit(song,candidate) and song.tool_data==before)
current=song
candidate=prepare(song,1)
local other_song={tool_data=song.tool_data,instruments=song.instruments}
current=other_song
assert(not store.commit(other_song,candidate) and not store.restore(other_song,candidate))
current=song
assert(store.commit(song,candidate))
song.tool_data="newer external data"
assert(not store.restore(song,candidate) and song.tool_data=="newer external data")
assert(store.candidate_status(candidate).integrity_uncertain)
assert(not store.commit(song,{raw=candidate.raw,previous_raw=candidate.previous_raw}),
  "public fields cannot forge a candidate")

song,ins,a=fresh()
local guarded_change
candidate=prepare(song,1,function()
  assert(store.write_draft(song,ins,a,seq.new_pattern(8),"repeat",0))
  guarded_change=song.tool_data
  return true
end,removal(ins,a))
local guarded_ok,guarded_error=store.commit(song,candidate)
assert(not guarded_ok and song.tool_data==guarded_change and
  store.read_draft(song,ins,a).length==8,"guard-time draft change must fail closed: "..tostring(guarded_error))
candidate=prepare(song,1,function()
  assert(store.save(song,2,seq.new_pattern(12),"repeat",0));return true
end)
assert(not store.commit(song,candidate) and store.read_entry(song,2).length==12)

local backing,unreadable,fail_write,race,reads,observed_candidate
local writes
local function proxy()
  backing="";unreadable=false;fail_write=nil;race=false;reads=0;writes=0;observed_candidate=nil
  local target=setmetatable({instruments={}}, {
    __index=function(_,key)
      if key=="tool_data"then
        if unreadable then error("unreadable store")end
        reads=reads+1
        if race and reads==2 then backing="concurrent external data"end
        return backing
      end
    end,
    __newindex=function(_,key,value)
      assert(key=="tool_data");writes=writes+1
      local evidence=assert(store.candidate_status(observed_candidate))
      assert(evidence.write_attempted and evidence.written_raw~=nil,
        "write evidence must precede even a throwing setter")
      backing=value
      if fail_write=="throw"then fail_write=nil;error("mutated then threw")end
      if fail_write=="read"then unreadable=true end
      if fail_write=="different"then backing="unexpected host data"end
    end})
  current=target;return target
end
song=proxy();candidate=prepare(song,1);observed_candidate=candidate;fail_write="throw"
assert(not store.commit(song,candidate))
status=assert(store.candidate_status(candidate))
assert(status.write_attempted and status.written_verified and not status.integrity_uncertain)
assert(store.restore(song,candidate) and backing=="")

song=proxy();candidate=prepare(song,1);observed_candidate=candidate;fail_write="read"
assert(not store.commit(song,candidate))
assert(store.candidate_status(candidate).integrity_uncertain)
assert(not store.restore(song,candidate))
unreadable=false;fail_write=nil
assert(store.restore(song,candidate) and backing=="")
assert(not store.candidate_status(candidate).integrity_uncertain)

song=proxy();candidate=prepare(song,1);observed_candidate=candidate;fail_write="different"
assert(not store.commit(song,candidate))
assert(not store.restore(song,candidate) and backing=="unexpected host data")

song=proxy();candidate=prepare(song,1);observed_candidate=candidate;reads=0;race=true
assert(not store.commit(song,candidate) and writes==0 and backing=="concurrent external data",
  "final raw comparison must reject a store change before its setter")

song=proxy();candidate=prepare(song,1);observed_candidate=candidate
backing=candidate.raw
assert(not store.restore(song,candidate) and backing==candidate.raw,
  "an unattempted candidate cannot roll back someone else's matching write")
print("ACID guarded source candidates and atomic draft removal checks passed")
