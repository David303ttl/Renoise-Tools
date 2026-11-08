dofile("tests/bootstrap.lua")("acid")
local seq=require("model.sequencer")
local own=require("renoise.phrase_ownership")
local store=require("renoise.pattern_store")

local current
renoise={song=function() return current end}
local phrase_limits={max_lines=1,max_note_columns=1,max_effect_columns=0,number_of_lines=1}
local make_phrase_fixture=dofile("tests/acid/complete_phrase_fixture.lua")
local function set_identity(p,id)
  local snapshot=assert(own.snapshot(p,phrase_limits))
  local seal_columns={}
  for column=1,12 do seal_columns[column]=p:column_is_muted(column) end
  p.name=assert(own.make_name_from_verified_snapshot(snapshot,id,seal_columns))
end

local function phrase(id)
  local p=make_phrase_fixture(phrase_limits)
  local cell=p.lines[1].note_columns[1]
  cell.note_value=48
  cell.is_empty=false
  set_identity(p,id)
  return p
end

local function fresh()
  local first,second=phrase(1),phrase(2)
  local instrument={name="Lead",phrases={first,second}}
  local song={instruments={instrument}}
  current=song
  assert(store.save(song,1,seq.new_pattern(4),"play_once",0))
  assert(store.save(song,2,seq.new_pattern(6),"repeat",12))
  return song,instrument,first,second
end

local function descriptor(instrument,first)
  return {kind="existing",instrument=instrument,phrase=first,token={},revision=1}
end

local function guard() return true end

local song,instrument,first=fresh()
local original_name=first.name
local old_source=assert(store.read_entry(song,1))
local draft=seq.new_pattern(7)
assert(store.write_draft(song,instrument,first,draft,"repeat",24))
local candidate_id=assert(store.allocate(song))
local candidate=assert(store.prepare_revision(song,candidate_id,seq.new_pattern(9),
  "play_once",2,guard,descriptor(instrument,first)))
assert(first.name==original_name,"preparation must not mutate the phrase")
local snapshot=assert(own.snapshot(first,phrase_limits))
local seal_columns={}
for column=1,12 do seal_columns[column]=first:column_is_muted(column) end
local new_name=assert(own.make_name_from_verified_snapshot(snapshot,candidate_id,seal_columns))
first.name=new_name
assert(store.commit(song,candidate),"revision commit should remove its unchanged captured draft")
assert(store.has_drafts(song)==false,"matching captured draft should be cleared")
assert(store.read_entry(song,1).length==old_source.length,
  "committing a revision must retain the historical source")
assert(store.load(song,instrument,first).length==9,
  "the new native phrase ID must resolve to the new source")

first.name=original_name
assert(store.load(song,instrument,first).length==4,
  "restoring the old native phrase name must resolve to the old source")
first.name=new_name
assert(store.load(song,instrument,first).length==9,
  "restoring the new native phrase name must resolve to the new source")

song,instrument,first=fresh()
draft=seq.new_pattern(7)
assert(store.write_draft(song,instrument,first,draft,"repeat",24))
candidate_id=assert(store.allocate(song))
candidate=assert(store.prepare_revision(song,candidate_id,seq.new_pattern(9),
  "play_once",2,guard,descriptor(instrument,first)))
local changed_draft=seq.new_pattern(8)
assert(store.write_draft(song,instrument,first,changed_draft,"repeat",24))
local newer_raw=song.tool_data
set_identity(first,candidate_id)
assert(not store.commit(song,candidate) and song.tool_data==newer_raw,
  "a raw-store change after candidate capture must reject source commit")
assert(store.has_drafts(song),"the concurrently changed draft must survive the rejected commit")
set_identity(first,1)
assert(store.read_draft(song,instrument,first).length==8,
  "undoing to the old source ID must recover the newer preserved draft")

song,instrument,first=fresh()
local before=song.tool_data
assert(not store.prepare_revision(song,1,seq.new_pattern(9),"play_once",2,guard),
  "a revision must never replace an existing committed row")
assert(song.tool_data==before)
first.name="foreign phrase"
assert(not store.prepare_revision(song,3,seq.new_pattern(9),"play_once",2,guard,
  descriptor(instrument,first)),"captured old identity must be validated before mutation")
set_identity(first,1)
candidate=assert(store.prepare_revision(song,3,seq.new_pattern(9),"play_once",2,
  guard,descriptor(instrument,first)))
local unchanged=song.tool_data
set_identity(first,4)
assert(not store.commit(song,candidate) and song.tool_data==unchanged,
  "a changed post-mutation phrase identity must block the source commit")
set_identity(first,3)
assert(not store.prepare_revision(song,3,seq.new_pattern(9),"play_once",2,guard),
  "a revision ID already used by a live phrase must not be reused")

print("ACID immutable source revision checks passed")
