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
local function source_row(id)
  return table.concat({tostring(id),"repeat","0","straight","16","4",
    default_pitches,default_time},"|")
end
local function removal(ins,p,token,revision)
  return {kind=p and "existing" or "new",instrument=ins,phrase=p,
    token=token or {},revision=revision or 1}
end
local function prepare(song,id,guard,capture)
  return assert(store.prepare(song,id,seq.new_pattern(5),"play_once",12,guard or yes,capture))
end
local song,ins,a,b,other=fresh()
local source=seq.new_pattern(7)
assert(store.write_draft(song,ins,a,source,"repeat",24))
local expected_draft=table.concat({"DRAFT","1","1","4669727374","repeat","24",
  "straight","16","7",default_pitches,default_time},"|")
local expected_store=table.concat({"ACID-PITCH-TIME-1",source_row(1),source_row(2),
  expected_draft},"\n").."\n"
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
assert(store.commit(song,candidate))
assert(store.read_draft(song,ins,a).length==7,"captured absence cannot delete an added draft")

song,ins,a,b,other=fresh()
assert(store.write_draft(song,ins,a,source,"repeat",0))
candidate=prepare(song,1,yes,removal(ins,a))
assert(store.write_draft(song,ins,a,seq.new_pattern(8),"repeat",0))
assert(store.write_draft(song,other,nil,seq.new_pattern(9),"repeat",0))
assert(store.commit(song,candidate))
assert(store.read_draft(song,ins,a).length==8 and store.read_draft(song,other,nil).length==9)
assert(store.restore(song,candidate))
assert(store.read_draft(song,ins,a).length==8,"rollback must retain rebased current drafts")

song,ins,a=fresh()
assert(store.write_draft(song,ins,a,source,"repeat",0))
candidate=prepare(song,1,yes,removal(ins,a))
assert(store.write_draft(song,ins,a,source,"play_once",24))
assert(store.commit(song,candidate))
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
  assert(store.commit(song,candidate))
  assert(store.has_drafts(song)==(change~="none"),"New scratch removal policy: "..change)
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
candidate=prepare(song,1,function()
  assert(store.write_draft(song,ins,a,source,"repeat",0));return true
end,removal(ins,a))
assert(store.commit(song,candidate) and store.read_draft(song,ins,a).length==7,
  "a guard's draft changes must be included in current-draft rebasing")
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
