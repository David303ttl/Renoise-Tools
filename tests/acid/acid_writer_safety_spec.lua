dofile("tests/bootstrap.lua")("acid")
local columns=dofile("tests/acid/phrase_columns.lua")
local seq=require("model.sequencer")
local pitch=dofile("tests/acid/pitch_fixture.lua")
local CAP_LINES=32
local CAP_NOTES=4
local CAP_EFFECTS=2

local instrument={name="Writer safety",phrases={},
  samples={{sample_buffer={has_sample_data=true}}},
  plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,
    alias_fx_device_index=0,midi_output_routing_index=0},
  midi_output_properties={device_name="",instrument_type=1,channel=1},
  phrase_playback_mode=2,phrase_program=1}
local function make_phrase()
  local phrase={name="",number_of_lines=16,lpb=16,shuffle=0,looping=false,
    loop_start=1,loop_end=16,playback_mode=1,key_tracking=1,base_note=48,
    autoseek=false,visible_note_columns=1,visible_effect_columns=0,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,
    mapping={key_tracking=1,base_note=48,loop_start=1,loop_end=16,
      looping=false,note_range={0,119}},
    script={paragraphs={},parameters={},pending_changes=0,editor_visible=true},cells={},
    column_names={},column_mutes={}}
  for column=1,12 do
    phrase.column_names[column]="user column "..column
    phrase.column_mutes[column]=column==2
  end
  for line=1,CAP_LINES do
    phrase.cells[line]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function phrase:line(index)return columns.line(self,index)end
  function phrase:column_name(index)return self.column_names[index]end
  function phrase:column_is_muted(index)return self.column_mutes[index]end
  function phrase:set_column_name(index,value)self.column_names[index]=value end
  function phrase:set_column_is_muted(index,value)self.column_mutes[index]=value end
  return phrase
end
function instrument:insert_phrase_at(index)
  assert(index==#self.phrases+1,"create must append one destination")
  local phrase=make_phrase()
  self.phrases[index]=phrase
  return phrase
end
function instrument:delete_phrase_at(index)table.remove(self.phrases,index)end

local song={instruments={instrument},tool_data="",transport={timing_model=2,lpb=16,
  tpl=12,groove_enabled=false}}
function song:is_undo_redoing()return false end
_G.renoise={Transport={TIMING_MODEL_LPB=2,TIMING_MODEL_SPEED=1},
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1,
    MAX_NUMBER_OF_LINES=CAP_LINES,MAX_NUMBER_OF_NOTE_COLUMNS=CAP_NOTES,
    MAX_NUMBER_OF_EFFECT_COLUMNS=CAP_EFFECTS},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function()return song end}

local writer=require("writers.phrase_writer")
local request_factory=dofile("tests/acid/writer_request.lua")
local ownership=require("renoise.phrase_ownership")
local store=require("renoise.pattern_store")
local materializer=require("writers.phrase_materializer")

local function source(first)
  local pattern=seq.new_pattern(3)
  pattern.pitch_length=2
  pattern.pitch_events[1]=pitch(first)
  pattern.pitch_events[2]=pitch(first+2,true)
  pattern.time_events[1],pattern.time_events[2],pattern.time_events[3]="N","T","R"
  return pattern
end
local function request(pattern,target,options)
  local result,reason=request_factory.build(song,1,pattern,target,options)
  assert(result,type(reason)=="table" and reason.message or tostring(reason))
  return result
end
local function run(candidate)
  local calls=0
  local operation=candidate.kind=="create" and writer.create or writer.regenerate
  local accepted,rejection=operation(candidate,function(result)
    calls=calls+1
    assert(type(result)=="table" and (result.kind=="success" or result.kind=="failure"))
    candidate.result=result
  end)
  return accepted,rejection,calls,candidate.result
end
local function snapshot(phrase)
  return assert(ownership.snapshot(phrase,{max_lines=CAP_LINES,
    max_note_columns=CAP_NOTES,max_effect_columns=CAP_EFFECTS}))
end

-- Create and regeneration settle synchronously, with one authorized mutation.
local first=request(source(48),1)
local first_mutations=0
local authorize=first.mutate
function first:mutate(token,action)
  first_mutations=first_mutations+1
  return authorize(self,token,action)
end
local accepted,rejection,calls,result=run(first)
assert(accepted,rejection and rejection.message)
assert(calls==1 and first_mutations==1 and result.status=="committed",
  "create did not complete through one mutation and one synchronous terminal callback: "..
  tostring(result and result.status).." / "..tostring(result and result.message)..
  " / calls="..tostring(calls).." mutations="..tostring(first_mutations))
local target=assert(result.phrase)
local first_id=assert(ownership.id(target))
local first_snapshot=snapshot(target)
local first_raw=song.tool_data
assert(target.mapping.key_tracking==1 and target.column_names[1]=="user column 1"
  and target.column_mutes[2],"create changed user column or mapping metadata")
assert(target.cells[CAP_LINES].panning_value==255,
  "create did not materialize the planner's empty hidden tail")

-- Regeneration keeps the phrase object, columns, and hidden data while adding
-- a new immutable source identity and retaining its previous source row.
target.cells[CAP_LINES].panning_value=73
local hidden_tail_raw=song.tool_data
local hidden_tail_request=request(source(52),1)
local hidden_tail_calls=0
local rejected,rejection=writer.regenerate(hidden_tail_request,function() hidden_tail_calls=hidden_tail_calls+1 end)
assert(not rejected and hidden_tail_calls==0 and rejection.category=="safety",
  "regeneration admitted a manually changed hidden tail: "..
  tostring(rejection and rejection.code).." / "..tostring(rejection and rejection.message))
assert(song.tool_data==hidden_tail_raw and target.cells[CAP_LINES].panning_value==73,
  "hidden-tail preflight rejection mutated the phrase or source")
target.cells[CAP_LINES].panning_value=255
local before=snapshot(target)
local old_source=assert(store.load(song,instrument,target))
local regen=request(source(52),1)
local regen_mutations=0
local original_mutate=regen.mutate
function regen:mutate(token,action)
  regen_mutations=regen_mutations+1
  return original_mutate(self,token,action)
end
local regen_ok,regen_error,regen_calls,regen_result=run(regen)
assert(regen_ok,regen_error and regen_error.message)
assert(regen_calls==1 and regen_mutations==1 and regen_result.status=="committed",
  "regeneration did not use one mutation and one terminal callback")
assert(rawequal(regen_result.phrase,target) and rawequal(instrument.phrases[1],target)
  and #instrument.phrases==1,"regeneration replaced its destination or changed inventory")
assert(target.cells[CAP_LINES].panning_value==255,
  "regeneration did not retain the planner's empty hidden tail")
assert(target.mapping.key_tracking==1 and target.column_names[1]=="user column 1"
  and target.column_mutes[2],"regeneration lost user column or mapping metadata")
local second_id=assert(ownership.id(target))
assert(second_id~=first_id,"regeneration reused a committed phrase ID")
local history=assert(store.read(song))
assert(history[first_id] and history[second_id]
  and seq.same_source(history[first_id].pattern,old_source)
  and history[second_id].pattern.pitch_events[1].note==52,
  "regeneration did not retain both exact source revisions")

-- A failed materialization restores the exact target and source state.
local good_snapshot=snapshot(target)
local good_raw=song.tool_data
local apply=materializer.apply
materializer.apply=function(phrase,...)
  local ok,actual,attempted=apply(phrase,...)
  if not ok then return ok,actual,attempted end
  phrase.cells[1].note_value=0
  return nil,"injected post-write verification failure",true
end
local failed_request=request(source(57),1)
local failed_ok,failed_rejection,failed_calls,failed_result=run(failed_request)
materializer.apply=apply
assert(failed_ok,failed_rejection and failed_rejection.message)
assert(failed_calls==1 and failed_result.kind=="failure",
  "materializer failure did not report one terminal failure")
assert(rawequal(instrument.phrases[1],target) and #instrument.phrases==1
  and song.tool_data==good_raw and ownership.compare(good_snapshot,snapshot(target)),
  "materialization failure did not restore phrase and source exactly")
assert(writer.is_temporary(song,instrument,target)==false,
  "failed regeneration classified the existing destination as temporary")

-- Reentrant phrase drift after source preparation must be caught at the exact
-- materializer boundary, without restoring over the intervening edit.
do
  local before=snapshot(target)
  local before_raw=song.tool_data
  local prepare_revision=store.prepare_revision
  store.prepare_revision=function(...)
    local candidate,prepare_error=prepare_revision(...)
    if candidate then target.cells[1].note_value=0 end
    return candidate,prepare_error
  end
  local boundary_request=request(source(58),1)
  local boundary_ok,_,boundary_calls,boundary_result=run(boundary_request)
  store.prepare_revision=prepare_revision
  assert(boundary_ok and boundary_calls==1 and boundary_result.kind=="failure" and
    boundary_result.status~="integrity_blocked",
    "mutation-boundary preimage check did not reject reentrant phrase drift")
  assert(song.tool_data==before_raw and target.cells[1].note_value==0,
    "mutation-boundary rejection changed source bytes or overwrote phrase drift")
  target.cells[1].note_value=before.lines[1].notes[1].note_value
end

-- A throwing authorization wrapper has no separate cleanup authority while
-- the captured request remains current, so the committed write is blocked.
local throw_request=request(source(57),1)
local mutate=throw_request.mutate
local cleanup=throw_request.cleanup_mutate
local cleanup_calls=0
function throw_request:mutate(token,action)
  mutate(self,token,action)
  error("injected mutation wrapper failure after action",0)
end
function throw_request:cleanup_mutate(token,action)
  cleanup_calls=cleanup_calls+1
  return cleanup(self,token,action)
end
local throw_ok,throw_rejection,throw_calls,throw_result=run(throw_request)
assert(throw_ok,throw_rejection and throw_rejection.message)
assert(throw_calls==1 and cleanup_calls==0 and throw_result.kind=="failure" and
  throw_result.status=="integrity_blocked" and throw_result.committed==true,
  "mutation wrapper exception did not report the committed write without unauthorized cleanup")
assert(throw_request.blocker and throw_request.blocker.committed==true and
  writer.is_temporary(song,instrument,target)==false,
  "mutation wrapper exception did not retain accurate blocker evidence")
good_snapshot=snapshot(target)
good_raw=song.tool_data
second_id=assert(ownership.id(target))

-- A failed restore blocks later work without marking the owned destination as
-- a temporary phrase or authorizing its removal.
local restore=materializer.restore
materializer.apply=function(phrase,...)
  local ok,actual,attempted=apply(phrase,...)
  if not ok then return ok,actual,attempted end
  phrase.cells[1].note_value=0
  return nil,"injected write failure before restore",true
end
materializer.restore=function()return nil,"injected restore failure"end
local blocked_request=request(source(58),1)
local blocked_ok,blocked_rejection,blocked_calls,blocked_result=run(blocked_request)
materializer.apply,materializer.restore=apply,restore
assert(blocked_ok,blocked_rejection and blocked_rejection.message)
assert(blocked_calls==1 and blocked_result.status=="integrity_blocked")
assert(writer.is_temporary(song,instrument,target)==false,
  "rollback failure registered the existing destination as temporary")
assert(restore(target,good_snapshot,{max_lines=CAP_LINES,
  max_note_columns=CAP_NOTES,max_effect_columns=CAP_EFFECTS}))
writer.clear_integrity_blocker(song)
assert(song.tool_data==good_raw and ownership.compare(good_snapshot,snapshot(target)))

-- A source rollback setter can reenter and edit the phrase after the initial
-- rollback guard. The later phrase restore must not overwrite that edit.
do
  local rollback_snapshot=snapshot(target)
  local rollback_raw=song.tool_data
  local original_song_meta=getmetatable(song)
  local stored_data=rollback_raw
  local inject_on_restore=false
  rawset(song,"tool_data",nil)
  setmetatable(song,{__index=function(object,key)
      if key=="tool_data" then return stored_data end
      return original_song_meta and original_song_meta.__index and
        original_song_meta.__index(object,key) or nil
    end,
    __newindex=function(object,key,value)
      if key=="tool_data" then
        stored_data=value
        if inject_on_restore and value==rollback_raw then
          inject_on_restore=false
          target.cells[1].note_value=0
        end
      elseif original_song_meta and original_song_meta.__newindex then
        original_song_meta.__newindex(object,key,value)
      else
        rawset(object,key,value)
      end
    end})
  local commit=store.commit
  store.commit=function(...)
    local committed,commit_error=commit(...)
    if committed then
      inject_on_restore=true
      return nil,"injected failure after source commit"
    end
    return committed,commit_error
  end
  local reentrant_request=request(source(58),1)
  local reentrant_ok,_,reentrant_calls,reentrant_result=run(reentrant_request)
  store.commit=commit
  setmetatable(song,original_song_meta)
  rawset(song,"tool_data",stored_data)
  assert(reentrant_ok and reentrant_calls==1 and reentrant_result.status=="integrity_blocked",
    "reentrant tool_data setter during rollback was not blocked")
  assert(target.cells[1].note_value==0,
    "phrase restore overwrote the native edit made during source rollback")
  assert(song.tool_data==rollback_raw and reentrant_request.blocker,
    "reentrant rollback did not restore source bytes or retain blocker evidence")
  writer.clear_integrity_blocker(song)
  assert(restore(target,rollback_snapshot,{max_lines=CAP_LINES,
    max_note_columns=CAP_NOTES,max_effect_columns=CAP_EFFECTS}))
  assert(song.tool_data==rollback_raw)
end

-- A malformed result or throw leaves apply ownership unknown, so rollback must
-- preserve the native phrase and source rather than restore a stale preimage.
for _,outcome in ipairs({"missing flag","throw"}) do
  local before=snapshot(target)
  local before_raw=song.tool_data
  local prior_delay=target.cells[CAP_LINES].delay_value
  materializer.apply=function(phrase,...)
    local ok,receipt,attempted=apply(phrase,...)
    if ok then
      phrase.cells[CAP_LINES].delay_value=prior_delay==0 and 1 or 0
      if outcome=="throw" then error("injected apply exception after native edit",0) end
      return nil,"injected missing apply outcome flag"
    end
    return ok,receipt,attempted
  end
  local unknown_request=request(source(58),1)
  local unknown_ok,unknown_rejection,unknown_calls,unknown_result=run(unknown_request)
  materializer.apply=apply
  assert(unknown_ok,unknown_rejection and unknown_rejection.message)
  assert(unknown_calls==1 and unknown_result.status=="integrity_blocked" and
    unknown_result.committed==false,
    "unknown apply outcome was not blocked without claiming a commit: "..outcome)
  assert(target.cells[CAP_LINES].delay_value~=prior_delay and song.tool_data==before_raw,
    "unknown apply outcome rollback overwrote native drift or changed persisted source: "..outcome)
  assert(unknown_request.blocker and writer.is_temporary(song,instrument,target)==false,
    "unknown apply outcome did not retain blocker evidence: "..outcome)
  assert(restore(target,before,{max_lines=CAP_LINES,
    max_note_columns=CAP_NOTES,max_effect_columns=CAP_EFFECTS}))
  writer.clear_integrity_blocker(song)
  good_snapshot=snapshot(target)
  good_raw=song.tool_data
end

-- A store wrapper that throws after a successful write must still roll both
-- phrase and source back; the terminal result describes the surviving state.
local commit=store.commit
store.commit=function(target_song,candidate)
  assert(commit(target_song,candidate))
  error("injected post-write source failure",0)
end
local failed_commit=request(source(58),1)
local commit_ok,commit_rejection,commit_calls,commit_result=run(failed_commit)
store.commit=commit
assert(commit_ok,commit_rejection and commit_rejection.message)
assert(commit_calls==1 and commit_result.kind=="failure"
  and commit_result.message:find("injected post-write source failure",1,true),
  "source write failure was not reported")
assert(commit_result.committed==false,
  "rolled-back source write was incorrectly reported as committed")
assert(rawequal(instrument.phrases[1],target) and #instrument.phrases==1
  and song.tool_data==good_raw and ownership.compare(good_snapshot,snapshot(target)),
  "source write failure did not restore phrase and source exactly")
assert(assert(ownership.id(target))==second_id,
  "failed regeneration changed the last-good phrase identity")

-- Stale or revoked requests fail before mutation and never call done twice.
local stale_source=song.tool_data
local stale=request(source(58),1,{token={current=false,is_current=function()return false end}})
local stale_ok,stale_rejection,stale_calls=run(stale)
assert(not stale_ok and stale_rejection and stale_calls==0,
  "revoked request reached the synchronous writer")
assert(song.tool_data==stale_source and ownership.compare(good_snapshot,snapshot(target)))

-- Requests without the required authorization checkpoint fail before admission.
local legacy_checkpoint=request(source(58),1)
legacy_checkpoint.validate_authorization_checkpoint=nil
local legacy_store=song.tool_data
local legacy_snapshot=snapshot(target)
local legacy_ok,legacy_rejection,legacy_calls,legacy_result=run(legacy_checkpoint)
assert(not legacy_ok and legacy_rejection and
  tostring(legacy_rejection.message):find("authorization checkpoint is unavailable",1,true) and
  legacy_calls==0 and legacy_result==nil,
  "writer admitted a request without the required authorization checkpoint")
assert(song.tool_data==legacy_store and ownership.compare(legacy_snapshot,snapshot(target)),
  "missing request authorization mutated the destination or persisted source")

assert(writer.state()=="idle")
print("ACID synchronous writer safety checks passed (mocked Renoise)")
