-- Exercise the production runtime request seam with the real phrase writer,
-- pattern store and draft cache against one API-shaped host. No playback claims.
dofile("tests/bootstrap.lua")("acid")
local columns=dofile("tests/acid/phrase_columns.lua")
local pitch=dofile("tests/acid/pitch_fixture.lua")

local instrument
local MAX_LINES,MAX_NOTE_COLUMNS,MAX_EFFECT_COLUMNS=16,2,1

local function make_phrase()
  local phrase={name="",number_of_lines=16,lpb=16,shuffle=0,looping=false,
    loop_start=1,loop_end=16,playback_mode=1,key_tracking=1,base_note=48,
    autoseek=false,visible_note_columns=1,visible_effect_columns=0,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,mapping=nil,cells={},
    script={paragraphs={},parameters={},pending_changes=0,editor_visible=true},
    column_names={},column_mutes={}}
  for column=1,12 do
    phrase.column_names[column]="column "..column
    phrase.column_mutes[column]=false
  end
  for line=1,MAX_LINES do
    phrase.cells[line]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function phrase:line(index) return columns.line(self,index) end
  function phrase:column_name(column) return self.column_names[column] end
  function phrase:column_is_muted(column) return self.column_mutes[column] end
  function phrase:copy_from(other)
    for _,key in ipairs({"name","number_of_lines","lpb","shuffle","looping",
      "loop_start","loop_end","playback_mode","key_tracking","base_note",
      "autoseek","visible_note_columns","visible_effect_columns",
      "instrument_column_visible","volume_column_visible",
      "panning_column_visible","delay_column_visible",
      "sample_effects_column_visible"}) do
      self[key]=other[key]
    end
    self.cells={}
    for line=1,MAX_LINES do
      local copy={}
      for key,value in pairs(other.cells[line] or {}) do copy[key]=value end
      self.cells[line]=copy
    end
    for column=1,MAX_NOTE_COLUMNS do
      self.column_names[column]=other.column_names[column]
      self.column_mutes[column]=other.column_mutes[column]
    end
  end
  return phrase
end

instrument={name="Runtime writer integration",phrases={},
  phrase_mappings={},
  samples={{sample_buffer={has_sample_data=true}}},
  plugin_properties={plugin_loaded=false,alias_instrument_index=0,
    alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},
  midi_output_properties={device_name="",instrument_type=0,channel=1},
  phrase_playback_mode=2,phrase_program=7,phrase_editor_visible=false}
function instrument:insert_phrase_at(index)
  assert(index==#self.phrases+1,"phrase insertion must append")
  local phrase=make_phrase()
  self.phrases[index]=phrase
  return phrase
end
function instrument:delete_phrase_at(index) table.remove(self.phrases,index) end

local song={instruments={instrument},transport={timing_model=2,lpb=16,tpl=12,
  groove_enabled=false}}
function song:is_undo_redoing() return false end
_G.renoise={
  Transport={TIMING_MODEL_LPB=2,TIMING_MODEL_SPEED=1},
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1,
    MAX_NUMBER_OF_LINES=MAX_LINES,MAX_NUMBER_OF_NOTE_COLUMNS=MAX_NOTE_COLUMNS,
    MAX_NUMBER_OF_EFFECT_COLUMNS=MAX_EFFECT_COLUMNS},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function() return song end,
}
-- Renoise exposes API classes as indexed userdata proxies, not Lua tables.
local function class_proxy(values)
  local proxy=newproxy(true)
  getmetatable(proxy).__index=values
  return proxy
end
renoise.InstrumentPhrase=class_proxy(renoise.InstrumentPhrase)
renoise.Instrument=class_proxy(renoise.Instrument)

local context=require("runtime.context")
local drafts=require("runtime.draft_cache")
local writer=require("writers.phrase_writer")
local store=require("renoise.pattern_store")
local ownership=require("renoise.phrase_ownership")
local sequencer=require("model.sequencer")
local materializer=require("writers.phrase_materializer")
local materializer_calls=0
local during_mutation
local after_materializer_apply
local base_materializer_apply=materializer.apply
materializer.apply=function(...)
  materializer_calls=materializer_calls+1
  if during_mutation then during_mutation() end
  local result,count={},0
  local function capture(...) count=select("#",...);for index=1,count do result[index]=select(index,...) end end
  capture(base_materializer_apply(...))
  if after_materializer_apply and result[1]==true then
    local mutate=after_materializer_apply
    after_materializer_apply=nil
    mutate()
  end
  return unpack(result,1,count)
end

local sink_calls=0
local fail_next_adoption=false
local probe_terminal_reentry=false
local before_prepare_mutation
local sink=function(request,done)
  sink_calls=sink_calls+1
  if before_prepare_mutation then
    local mutate=before_prepare_mutation
    before_prepare_mutation=nil
    mutate(request)
  end
  local function complete(result)
    if probe_terminal_reentry then
      probe_terminal_reentry=false
      local nested_calls=0
      local accepted=writer.regenerate(request,function() nested_calls=nested_calls+1 end)
      assert(not accepted and nested_calls==0,
        "terminal callback reentry was admitted before delivery ended")
    end
    if fail_next_adoption and result.kind=="success" then
      fail_next_adoption=false
      local membership=ownership.membership
      ownership.membership=function() return nil,"Injected adoption failure" end
      local ok,err=pcall(done,result)
      ownership.membership=membership
      if not ok then error(err) end
      return
    end
    return done(result)
  end
  if request.kind=="create" then return writer.create(request,complete) end
  if request.kind=="regenerate" then return writer.regenerate(request,complete) end
  error("unexpected runtime request kind "..tostring(request.kind))
end
local function new_context()
  return context.new{
    writer=writer,
    capture=function() return nil,"capture requires an installed editor" end,
    sink=sink,
    drafts=drafts,
    cancel=writer.cancel,
  }
end
local function delivered()
  local results={}
  local function delivery(result) results[#results+1]=result end
  return results,delivery
end
local function source(note)
  local pattern=sequencer.new_pattern(2)
  pattern.pitch_length=2
  pattern.pitch_events[1]=pitch(note)
  pattern.pitch_events[2]=pitch(note+3)
  pattern.time_events[1]="N"
  pattern.time_events[2]="N"
  return pattern
end
local function edit(ctx,pattern)
  local editor,effects=ctx:transition("edit",{source=pattern,
    output_policy="play_once",pb_range=0})
  assert(editor and effects,"editor transition was rejected")
  return effects
end
local function dispatch(ctx)
  local accepted,reason=ctx:request_generation("manual")
  assert(accepted,reason)
end
local function drain(results,expected,label)
  assert(#results>=expected,label..": terminal delivery did not arrive")
  assert(writer.state()=="idle",label..": synchronous writer did not settle before return")
end
local function assert_success(result,phrase,label)
  assert(type(result)=="table",label..": missing terminal result")
  assert(result.kind=="success" and result.verified==true,label..": "..tostring(result.reason))
  assert(result.status=="committed" or result.status=="approximate",label..": "..tostring(result.status))
  assert(rawequal(result.phrase,phrase),label..": wrong destination phrase")
  assert(type(result.baseline)=="table" and type(result.baseline.source)=="table",
    label..": success did not include a committed baseline")
end
local function first_note(pattern)
  return pattern.pitch_events[1].note
end

-- Create, then regenerate the same destination object twice. Each later
-- request captures the baseline the runtime adopted from the prior terminal.
local ctx=new_context()
local results,delivery=delivered()
ctx:attach_document(song)
ctx:open_dialog(delivery)
ctx:bind_new(instrument)
edit(ctx,source(48))
dispatch(ctx)
drain(results,1,"initial create")
local phrase=assert(results[1].phrase)
assert_success(results[1],phrase,"initial create")
assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],phrase))
assert(materializer_calls==1,"create did not apply exactly one phrase image")
local created_id=assert(ownership.id(phrase))
local target=ctx:target_state()
assert(target.kind=="owned" and rawequal(target.phrase,phrase)
  and target.baseline and target.baseline.id==created_id,
  "create terminal did not bind and adopt its destination")
local created_store=song.tool_data
assert(created_store and created_store~= "", "create did not persist source")
assert(drafts.get(song,instrument,phrase)==nil,
  "create retained the session draft")
assert(store.read_draft(song,instrument,phrase)==nil,
  "create retained the durable draft")
assert(drafts.has(song)==false,"create left a draft behind")

-- Capture may use the cached light target, but the writer must still reject
-- a native phrase edit that lands before its fresh prepare classification.
do
  edit(ctx,source(51))
  local phrase_line=phrase.cells[16]
  local prior_delay=phrase_line.delay_value
  local store_before=song.tool_data
  local materializer_before=materializer_calls
  before_prepare_mutation=function(request)
    assert(rawequal(request.phrase,phrase),"mutation probe targeted another phrase")
    phrase_line.delay_value=prior_delay==0 and 1 or 0
  end
  local accepted,rejection=ctx:request_generation("manual")
  assert(not accepted and rejection,"writer accepted a native edit made after request capture")
  assert(before_prepare_mutation==nil,"pre-prepare mutation hook did not run")
  assert(materializer_calls==materializer_before,"stale native phrase reached materialization")
  assert(song.tool_data==store_before,"stale native phrase changed persisted source")
  assert(phrase_line.delay_value~=prior_delay,"pre-prepare native mutation was not injected")
  phrase_line.delay_value=prior_delay
  assert(writer.state()=="idle","rejected stale request left writer occupied")
end

edit(ctx,source(52))
dispatch(ctx)
drain(results,2,"first regenerate")
assert_success(results[2],phrase,"first regenerate")
assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],phrase))
assert(phrase.cells[1].note_value==52)
local first_revision_id=assert(ownership.id(phrase))
assert(first_revision_id~=created_id,"first regeneration reused the immutable phrase ID")
assert(store.read_entry(song,created_id),"first regeneration removed the old source row")
local saved=assert(store.load(song,instrument,phrase))
assert(first_note(saved)==52,"first regenerate did not persist its source")
local adopted=ctx:target_state()
assert(adopted.baseline and first_note(adopted.baseline.source)==52,
  "first regenerate baseline was not adopted")

edit(ctx,source(55))
dispatch(ctx)
drain(results,3,"second regenerate")
assert_success(results[3],phrase,"second regenerate")
assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],phrase))
assert(phrase.cells[1].note_value==55)
local second_revision_id=assert(ownership.id(phrase))
assert(second_revision_id~=first_revision_id,"second regeneration reused the prior phrase ID")
assert(store.read_entry(song,created_id) and store.read_entry(song,first_revision_id),
  "successive regeneration removed historical source rows")
local saved_second=assert(store.load(song,instrument,phrase))
assert(first_note(saved_second)==55,"second regenerate did not persist its source")
local adopted_second=ctx:target_state()
assert(adopted_second.baseline and first_note(adopted_second.baseline.source)==55,
  "second regenerate baseline was not adopted")
assert(drafts.get(song,instrument,phrase)==nil,
  "regenerate retained the session draft")
assert(store.read_draft(song,instrument,phrase)==nil,
  "regenerate retained the durable draft")
assert(drafts.has(song)==false,"regenerate left a draft behind")

-- A cold context reopens the same saved song read-only, then regenerates the
-- existing phrase from its durable source association.
local cold_store=song.tool_data
ctx:release_document()
assert(writer.state()=="idle","release left the writer occupied")
local cold, cold_delivery=delivered()
local cold_ctx=new_context()
cold_ctx:attach_document(song)
cold_ctx:open_dialog(cold_delivery)
cold_ctx:bind_phrase(instrument,phrase)
local reopened=cold_ctx:target_state()
assert(reopened.kind=="owned" and rawequal(reopened.phrase,phrase)
  and reopened.baseline and reopened.baseline.id==second_revision_id,
  "cold context did not classify the saved phrase")
assert(song.tool_data==cold_store,"cold target inspection changed saved data")
assert(drafts.get(song,instrument,phrase)==nil,
  "cold context restored a draft instead of reading saved data")
local cold_source=assert(store.load(song,instrument,phrase))
assert(first_note(cold_source)==55,"cold context read the wrong saved source")
edit(cold_ctx,source(57))
dispatch(cold_ctx)
drain(cold,1,"cold regenerate")
assert_success(cold[1],phrase,"cold regenerate")
assert(rawequal(instrument.phrases[1],phrase) and #instrument.phrases==1)
assert(phrase.cells[1].note_value==57)
local cold_saved=assert(store.load(song,instrument,phrase))
assert(first_note(cold_saved)==57,"cold regenerate did not persist its source")
local cold_target=cold_ctx:target_state()
assert(cold_target.baseline and first_note(cold_target.baseline.source)==57,
  "cold regenerate baseline was not adopted")
assert(drafts.get(song,instrument,phrase)==nil,
  "cold regenerate retained the session draft")
assert(store.read_draft(song,instrument,phrase)==nil,
  "cold regenerate retained the durable draft")
assert(drafts.has(song)==false,"cold regenerate left a draft behind")

-- If the native phrase changes after prepare but before materializer.apply,
-- the preimage rejection must not roll that unrelated edit back over itself.
do
  local phrase_line=phrase.cells[16]
  local prior_delay=phrase_line.delay_value
  local terminal_before=#cold
  edit(cold_ctx,source(56))
  local persisted_before=song.tool_data
  during_mutation=function()
    during_mutation=nil
    phrase_line.delay_value=prior_delay==0 and 1 or 0
  end
  dispatch(cold_ctx)
  drain(cold,terminal_before+1,"preimage drift rejection")
  assert(cold[#cold].kind=="failure","preimage drift was reported as success")
  assert(phrase_line.delay_value~=prior_delay,
    "rollback overwrote a native edit rejected before any phrase write")
  assert(song.tool_data==persisted_before,"preimage drift changed persisted source")
  phrase_line.delay_value=prior_delay
end

cold_ctx:transition("arm")
edit(cold_ctx,source(54))
assert(cold_ctx:generation_state().pending,"post-commit Live Edit was not queued")
cold_ctx:refresh_inventory()
assert(cold_ctx:generation_state().pending,
  "refresh treated the runtime's own adopted baseline as an external target change")
cold_ctx:transition("disarm")
cold_ctx:transition("programmatic",{source=cold_source,output_policy="play_once",pb_range=0,restore=true})
assert(drafts.clear(song,instrument,phrase))

-- Synchronous runtime regeneration preserves destination identity, selection,
-- and inventory while adopting each committed source revision.
cold_ctx:bind_phrase(instrument,phrase)
song.selected_phrase_index=1
song.selected_phrase=phrase
local phrase_count_before_sync=#instrument.phrases
local insert_count,delete_count=0,0
local original_insert,original_delete=instrument.insert_phrase_at,instrument.delete_phrase_at
function instrument:insert_phrase_at(index)
  insert_count=insert_count+1
  return original_insert(self,index)
end
function instrument:delete_phrase_at(index)
  delete_count=delete_count+1
  return original_delete(self,index)
end
local sync_before=#cold
local materializer_before=materializer_calls
local original_ownership_status=ownership.status
local ownership_status_calls=0
ownership.status=function(...)
  ownership_status_calls=ownership_status_calls+1
  return original_ownership_status(...)
end
edit(cold_ctx,source(56))
local accepted_sync, sync_reason=cold_ctx:request_generation("manual")
ownership.status=original_ownership_status
assert(accepted_sync,sync_reason)
assert(#cold==sync_before+1,"terminal result was not delivered before request returned")
assert(materializer_calls==materializer_before+1,"regeneration did not apply exactly one phrase image")
assert(ownership_status_calls==0,"regeneration repeated ownership classification before the full materializer baseline match")
assert_success(cold[#cold],phrase,"synchronous runtime regenerate")
assert(rawequal(instrument.phrases[1],phrase) and #instrument.phrases==phrase_count_before_sync,
  "regeneration replaced or inserted a phrase")
assert(insert_count==0 and delete_count==0,"regeneration changed phrase inventory")
assert(song.selected_phrase_index==1 and rawequal(song.selected_phrase,phrase),
  "regeneration changed native phrase selection")
local sync_id=assert(ownership.id(phrase))
assert(sync_id~=second_revision_id and store.read_entry(song,second_revision_id),
  "regeneration did not retain the prior immutable source row")
assert(first_note(assert(store.load(song,instrument,phrase)))==56)
assert(writer.state()=="idle" and cold_ctx:state().status=="idle",
  "synchronous runtime operation did not settle before returning")
local target_after_adoption=cold_ctx:target_state()
assert(target_after_adoption.kind=="owned" and target_after_adoption.baseline.id==sync_id,
  "fresh full target read rejected the adopted postimage proof")
local original_note=phrase.cells[1].note_value
phrase.cells[1].note_value=original_note==60 and 59 or 60
local target_after_external_edit=cold_ctx:target_state()
assert(target_after_external_edit.kind=="unavailable",
  "a later full target read accepted a native edit after postimage adoption")
phrase.cells[1].note_value=original_note

-- A direct materializer failure restores the exact phrase and source state.
local before_failure=assert(ownership.snapshot(phrase))
local original_apply=materializer.apply
materializer.apply=function(...)
  materializer_calls=materializer_calls+1
  local result,err,attempted=original_apply(...)
  if result then
    phrase:line(1).note_columns[1].note_value=60
    return nil,"injected post-apply mismatch",true
  end
  return result,err,attempted
end
local failure_before=#cold
edit(cold_ctx,source(57))
local store_before_failure=song.tool_data
dispatch(cold_ctx)
materializer.apply=original_apply
assert(#cold==failure_before+1 and cold[#cold].kind=="failure",
  "materialization failure was not delivered synchronously")
local failure_snapshot=assert(ownership.snapshot(phrase))
local failure_same,failure_difference=ownership.compare(before_failure,failure_snapshot)
assert(failure_same and song.tool_data==store_before_failure,
  "materialization failure did not restore phrase and source state exactly")
assert(writer.state()=="idle" and cold_ctx:state().status=="idle",
  "failed synchronous operation did not release runtime state")

-- Reentry from terminal delivery is rejected until the callback returns.
probe_terminal_reentry=true
local reentry_before=#cold
edit(cold_ctx,source(55))
dispatch(cold_ctx)
assert(not probe_terminal_reentry and #cold==reentry_before+1,
  "terminal reentry probe did not complete exactly once")
assert(writer.state()=="idle" and #instrument.phrases==phrase_count_before_sync,
  "terminal reentry changed writer or phrase inventory state")

instrument.insert_phrase_at=original_insert
instrument.delete_phrase_at=original_delete
-- Resolve one explicitly selected member of a three-way same-instrument ID
-- collision, then save and reopen its unique ID while the other two remain
-- blocked together. The selected owner remains regenerable throughout.
do
  local selected=instrument.phrases[#instrument.phrases]
  local old_id=assert(ownership.id(selected))
  local old_source=assert(store.read_entry(song,old_id))
  local selected_before=assert(ownership.snapshot(selected))
  local function duplicate_phrase()
    local duplicate=instrument:insert_phrase_at(#instrument.phrases+1)
    duplicate:copy_from(selected)
    duplicate.script.paragraphs={}
    for index,value in ipairs(selected.script.paragraphs) do
      duplicate.script.paragraphs[index]=value
    end
    duplicate.script.parameters={}
    for index,value in ipairs(selected.script.parameters) do
      duplicate.script.parameters[index]={name=value.name,value=value.value}
    end
    duplicate.script.pending_changes=selected.script.pending_changes
    duplicate.script.editor_visible=selected.script.editor_visible
    return duplicate
  end
  local second,third=duplicate_phrase(),duplicate_phrase()
  assert(ownership.compare(assert(ownership.snapshot(selected)),assert(ownership.snapshot(second))))
  assert(ownership.compare(assert(ownership.snapshot(selected)),assert(ownership.snapshot(third))))

  -- Identity work is excluded for the full synchronous mutation scope.
  local identity_ctx=new_context()
  identity_ctx:attach_document(song)
  identity_ctx:open_dialog()
  identity_ctx:bind_phrase(instrument,selected)
  local holder_names={selected.name,second.name,third.name}
  local dispatch_before_mutation=sink_calls
  cold_ctx:bind_new(instrument)
  edit(cold_ctx,source(52))
  during_mutation=function()
    assert(writer.state()=="busy","writer did not reserve the operation during mutation")
    local eligible,reason=identity_ctx:independence_eligibility()
    assert(not eligible and tostring(reason):find("writer",1,true),
      "active writer did not reject identity eligibility: "..tostring(reason))
    local changed,occupied_reason=identity_ctx:make_independent()
    assert(not changed and tostring(occupied_reason):find("writer",1,true),
      "active writer admitted identity work: "..tostring(occupied_reason))
  end
  local store_bytes=song.tool_data
  dispatch(cold_ctx)
  during_mutation=nil
  assert(#cold>=1 and cold[#cold].kind=="success",
    "identity probe request did not reach a successful terminal result")
  assert(sink_calls==dispatch_before_mutation+1 and writer.state()=="idle")
  local created=instrument.phrases[#instrument.phrases]
  local created_id=ownership.id(created)
  assert(song.tool_data~=store_bytes and created_id and store.read_entry(song,created_id) and
    store.read_entry(song,old_id) and selected.name==holder_names[1] and
    second.name==holder_names[2] and third.name==holder_names[3],
    "identity admission probe changed the collision or lost its immutable source revision")
  identity_ctx:release_document()
  cold_ctx:bind_phrase(instrument,selected)
  assert(cold_ctx:independence_eligibility(),"fresh identity authorization failed after settlement")
  cold_ctx:transition("arm")
  assert(cold_ctx:generation_state().armed,
    "Live Edit did not arm before Make Independent")
  song.selected_instrument=instrument
  song.selected_phrase=selected
  local dispatch_count=sink_calls
  local independent,identity= cold_ctx:make_independent()
  assert(independent,identity)
  assert(cold_ctx:generation_state().armed,
    "Make Independent changed the Live Edit arming state")
  assert(rawequal(cold_ctx:target_state().phrase,selected),
    "Make Independent replaced the explicitly selected phrase object")
  assert(rawequal(song.selected_instrument,instrument) and rawequal(song.selected_phrase,selected),
    "Make Independent changed native selection")
  assert(identity.old_id==old_id and ownership.id(selected)==identity.id)
  assert(ownership.id(second)==old_id and ownership.id(third)==old_id)
  local groups=assert(ownership.inventory(song))
  assert(#groups[old_id]==2 and #groups[identity.id]==1)
  assert(ownership.compare(selected_before,assert(ownership.snapshot(selected)),'name'),
    'Make Independent changed musical content')
  local retained=assert(store.read_entry(song,old_id))
  local cloned=assert(store.read_entry(song,identity.id))
  assert(sequencer.same_source(retained,old_source) and sequencer.same_source(cloned,old_source))
  assert(sequencer.same_source(cold_ctx:editor_state().source,old_source),
    'Make Independent replaced the committed editor source with a placeholder')
  assert(sink_calls==dispatch_count,'Make Independent entered the writer')
  local independent_target=cold_ctx:target_state()
  assert(independent_target.kind=='owned' and rawequal(independent_target.phrase,selected),
    tostring(independent_target.kind)..': '..tostring(independent_target.reason))

  cold_ctx:transition("disarm")
  edit(cold_ctx,source(49))
  assert(first_note(cold_ctx:editor_state().source)==49,
    'selected holder editor did not retain its new draft source')
  assert(ownership.id(selected)==identity.id and #instrument.phrases==4 and
    #assert(ownership.inventory(song))[old_id]==2,
    'selected holder draft changed an unrelated same-ID collision')

  cold_ctx:release_document()
  cold_ctx:attach_document(song)
  cold_ctx:open_dialog(cold_delivery)
  cold_ctx:bind_phrase(instrument,selected)
  local reopened_target=cold_ctx:target_state()
  assert(reopened_target.kind=='owned' and reopened_target.baseline.id==identity.id)
  assert(first_note(assert(store.load(song,instrument,selected)))==55)
  assert(first_note(reopened_target.baseline.source)==55,
    'reopened independent holder did not recover its committed source')
  assert(#assert(ownership.inventory(song))[old_id]==2)

  -- A reentrant dialog close after the identity commit retains the selected
  -- object and blocks writes until committed state is explicitly revalidated.
  local reentrant_duplicate=duplicate_phrase()
  local phrase_count_before_reentrant=#instrument.phrases
  local reentrant_id=assert(ownership.id(selected))
  local selected_snapshot=assert(ownership.snapshot(selected))
  local duplicate_snapshot=assert(ownership.snapshot(reentrant_duplicate))
  local other_snapshot=assert(ownership.snapshot(second))
  local third_snapshot=assert(ownership.snapshot(third))
  local retained_source,retained_policy,retained_pb_range=store.read_entry(song,old_id)
  assert(retained_source)
  local duplicate_source,duplicate_policy,duplicate_pb_range=store.read_entry(song,reentrant_id)
  assert(duplicate_source)
  local function unrelated_state_unchanged()
    local current_source,current_policy,current_pb_range=store.read_entry(song,old_id)
    local current_duplicate_source,current_duplicate_policy,current_duplicate_pb_range=
      store.read_entry(song,reentrant_id)
    return current_source and sequencer.same_source(retained_source,current_source) and
      current_policy==retained_policy and current_pb_range==retained_pb_range and
      current_duplicate_source and sequencer.same_source(duplicate_source,current_duplicate_source) and
      current_duplicate_policy==duplicate_policy and current_duplicate_pb_range==duplicate_pb_range and
      ownership.compare(duplicate_snapshot,assert(ownership.snapshot(reentrant_duplicate))) and
      ownership.compare(other_snapshot,assert(ownership.snapshot(second))) and
      ownership.compare(third_snapshot,assert(ownership.snapshot(third)))
  end
  assert(ownership.id(reentrant_duplicate)==reentrant_id)
  local reentrant_ctx=new_context()
  local reentrant_results,reentrant_delivery=delivered()
  reentrant_ctx:attach_document(song)
  reentrant_ctx:open_dialog(reentrant_delivery)
  reentrant_ctx:bind_phrase(instrument,selected)
  local original_transition=reentrant_ctx.transition
  local close_on_refresh=true
  reentrant_ctx.transition=function(self,kind,values)
    if kind=="refresh" and close_on_refresh then
      close_on_refresh=false
      self:close_dialog()
    end
    return original_transition(self,kind,values)
  end
  local dispatch_before_close=sink_calls
  local committed,close_result=reentrant_ctx:make_independent()
  reentrant_ctx.transition=original_transition
  assert(sink_calls==dispatch_before_close,"reentrant identity close dispatched the writer")
  assert(committed and close_result.committed and close_result.warning,
    "post-commit dialog close was not reported as a committed blocked result")
  assert(not reentrant_ctx:lifetime_state().open,
    "post-commit reentrant close left the dialog open")
  assert(ownership.id(selected)~=reentrant_id and ownership.id(reentrant_duplicate)==reentrant_id,
    "reentrant close changed the selected phrase identity or its duplicate")
  assert(ownership.compare(selected_snapshot,assert(ownership.snapshot(selected)),"name"),
    "reentrant identity close changed the selected phrase content")
  assert(#instrument.phrases==phrase_count_before_reentrant and
    unrelated_state_unchanged() and
    ownership.id(second)==old_id and ownership.id(third)==old_id,
    "reentrant close changed unrelated phrase content, identities, or inventory")
  assert(rawequal(reentrant_ctx:target_projection().phrase,selected),
    "reentrant close replaced the explicitly selected phrase object")
  assert(reentrant_ctx:integrity_state().blocked and
    not reentrant_ctx:request_generation("manual"),
    "post-commit reentrant close allowed a write before revalidation")
  reentrant_ctx:open_dialog(reentrant_delivery)
  song.selected_instrument=instrument
  song.selected_phrase=selected
  local revalidation,revalidation_proof=reentrant_ctx:revalidation_status()
  assert(revalidation.verified,revalidation.reason)
  assert(reentrant_ctx:revalidate(revalidation_proof),
    "post-commit reentrant close evidence could not be revalidated")
  reentrant_ctx:bind_phrase(instrument,selected)
  reentrant_ctx:transition("disarm")
  local regenerated_pitch=56
  edit(reentrant_ctx,source(regenerated_pitch))
  dispatch(reentrant_ctx)
  drain(reentrant_results,1,"regenerate after reentrant identity close")
  assert_success(reentrant_results[1],selected,"regenerate after reentrant identity close")
  assert(rawequal(reentrant_results[1].phrase,selected) and
    #instrument.phrases==phrase_count_before_reentrant,
    "explicit regeneration after identity close changed the destination or phrase count")
  assert(first_note(assert(store.load(song,instrument,selected)))==regenerated_pitch)
  assert(unrelated_state_unchanged(),
    "regeneration after identity close changed unrelated phrase or source state")
  reentrant_ctx:release_document()
end

-- Once apply has produced a verified receipt, a later native edit must be
-- preserved and reported as blocked instead of rolling back over that edit.
do
  local guarded_ctx=new_context()
  local guarded_results,guarded_delivery=delivered()
  guarded_ctx:attach_document(song)
  guarded_ctx:open_dialog(guarded_delivery)
  guarded_ctx:bind_phrase(instrument,phrase)
  edit(guarded_ctx,source(54))
  local phrase_line=phrase.cells[16]
  local prior_delay=phrase_line.delay_value
  after_materializer_apply=function()
    phrase_line.delay_value=prior_delay==0 and 1 or 0
  end
  dispatch(guarded_ctx)
  assert(#guarded_results==1 and guarded_results[1].kind=="failure" and
    guarded_results[1].status=="integrity_blocked",
    "post-receipt native drift was not reported as an integrity blocker")
  assert(guarded_results[1].committed==true and guarded_results[1].baseline==nil,
    "blocked postimage rollback misreported commit state or invented a baseline")
  assert(phrase_line.delay_value~=prior_delay,
    "post-receipt rollback overwrote the native edit")
  assert(guarded_ctx:integrity_state().blocked,
    "post-receipt drift did not block further writes pending revalidation")
  local phrase_id=assert(ownership.id(phrase))
  local committed=assert(store.read_entry(song,phrase_id))
  assert(first_note(committed)==54,
    "blocked postimage rollback rewrote the already committed source")
  guarded_ctx:release_document()
end

-- A dirty sample-render draft remains editable after switching to a plugin;
-- the next real writer request uses the new MIDI/PB-capable output plan.
do
  local previous_song_accessor=renoise.song
  local previous_note_capacity,previous_effect_capacity=MAX_NOTE_COLUMNS,MAX_EFFECT_COLUMNS
  local phrase_api_values=getmetatable(renoise.InstrumentPhrase).__index
  MAX_NOTE_COLUMNS,MAX_EFFECT_COLUMNS=12,8
  phrase_api_values.MAX_NUMBER_OF_NOTE_COLUMNS=MAX_NOTE_COLUMNS
  phrase_api_values.MAX_NUMBER_OF_EFFECT_COLUMNS=MAX_EFFECT_COLUMNS
  local target={name="Receiver change integration",phrases={},phrase_mappings={},
    samples={{sample_buffer={has_sample_data=true}}},
    plugin_properties={plugin_loaded=false,alias_instrument_index=0,
      alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},
    midi_output_properties={device_name="",instrument_type=0,channel=1},
    phrase_playback_mode=2,phrase_program=7,phrase_editor_visible=false}
  function target:insert_phrase_at(index)
    assert(index==#self.phrases+1)
    local created=make_phrase();self.phrases[index]=created;return created
  end
  function target:delete_phrase_at(index) table.remove(self.phrases,index) end
  local target_song={instruments={target},tool_data="",transport={timing_model=2,lpb=16,tpl=12,
    groove_enabled=false}}
  function target_song:is_undo_redoing() return false end
  renoise.song=function() return target_song end
  local target_ctx=new_context()
  local target_results,target_delivery=delivered()
  target_ctx:attach_document(target_song)
  target_ctx:open_dialog(target_delivery)
  target_ctx:bind_new(target)
  local sample_source=source(48)
  sample_source.length=3
  sample_source.pitch_events[1].slide=true
  sample_source.time_events[3]="R"
  assert(target_ctx:transition("edit",{source=sample_source,
    output_policy="play_once",pb_range=12}))
  assert(target_ctx:request_generation("manual"))
  drain(target_results,1,"initial sample receiver create")
  local target_phrase=assert(target_results[1].phrase)
  assert_success(target_results[1],target_phrase,"initial sample receiver create")
  local sample_native=assert(ownership.snapshot(target_phrase))
  assert(target_results[1].baseline.planning_inputs.capabilities.sample==true and
      target_results[1].baseline.planning_inputs.capabilities.plugin==false,
    "initial phrase did not retain its sample receiver association")

  local dirty=source(49)
  dirty.length=3
  dirty.pitch_events[1].slide=true
  dirty.time_events[3]="R"
  assert(target_ctx:transition("edit",{source=dirty,output_policy="play_once",pb_range=12}))
  local draft_before=assert(drafts.capture(target_song,target,target_phrase,target_ctx:draft_options()))
  target.samples[1].sample_buffer.has_sample_data=false
  target.plugin_properties.plugin_loaded=true
  local refreshed=target_ctx:target_state()
  assert(refreshed.kind=="owned" and refreshed.baseline.planning_inputs.capabilities.sample==true and
      refreshed.baseline.planning_inputs.capabilities.plugin==false,
    "receiver change discarded or rewrote the committed sample proof: "..tostring(refreshed.reason))
  local restored=assert(target_ctx:restore_editor_target(target,target_phrase))
  assert(sequencer.same_source(restored.source,dirty),
    "receiver change detached or replaced the dirty source")
  local draft_after=assert(drafts.capture(target_song,target,target_phrase,target_ctx:draft_options()))
  assert(draft_after.token==draft_before.token and draft_after.revision==draft_before.revision,
    "receiver change replaced the dirty draft revision")

  local target_capabilities=require("renoise.target_capabilities")
  local planner=require("model.output_planner")
  local limits={max_lines=MAX_LINES,max_note_columns=MAX_NOTE_COLUMNS,
    max_effect_columns=MAX_EFFECT_COLUMNS,play_pattern=renoise.InstrumentPhrase.PLAY_PATTERN,
    key_tracking_none=renoise.InstrumentPhrase.KEY_TRACKING_NONE}
  local plugin_profile=assert(target_capabilities.inspect(target))
  local plugin_plan=assert(planner.plan(dirty,"play_once",12,limits,plugin_profile,
    {pitch_bend_delivery=true}))
  local sample_profile={sample=true,plugin=false,midi=false,alias=false}
  local sample_plan=assert(planner.plan(dirty,"play_once",12,limits,sample_profile,
    {pitch_bend_delivery=true}))
  assert(not ownership.compare(sample_plan.expected,plugin_plan.expected),
    "receiver-change fixture does not alter generated native output")
  local before_store=target_song.tool_data
  assert(target_ctx:request_generation("manual"),"compatible receiver-change regeneration was rejected")
  drain(target_results,2,"plugin receiver regenerate")
  assert_success(target_results[2],target_phrase,"plugin receiver regenerate")
  assert(ownership.id(target_phrase)~=target_results[1].baseline.id,
    "receiver-change regenerate reused the committed phrase revision")
  assert(target_results[2].baseline.planning_inputs.capabilities.sample==false and
      target_results[2].baseline.planning_inputs.capabilities.plugin==true,
    "new phrase revision did not capture the current receiver")
  assert(sequencer.same_source(assert(store.load(target_song,target,target_phrase)),dirty),
    "receiver-change regenerate did not commit the dirty source")
  assert(not ownership.compare(sample_native,assert(ownership.snapshot(target_phrase)),"name"),
    "receiver-change regenerate did not materialize the new receiver output")
  assert(target_song.tool_data~=before_store and drafts.get(target_song,target,target_phrase)==nil and
      store.read_draft(target_song,target,target_phrase)==nil,
    "successful receiver-change regenerate did not commit and clear its exact draft")
  target_ctx:release_document()
  renoise.song=previous_song_accessor
  MAX_NOTE_COLUMNS,MAX_EFFECT_COLUMNS=previous_note_capacity,previous_effect_capacity
  phrase_api_values.MAX_NUMBER_OF_NOTE_COLUMNS=previous_note_capacity
  phrase_api_values.MAX_NUMBER_OF_EFFECT_COLUMNS=previous_effect_capacity
end

print("ACID runtime writer integration checks passed (native playback unverified)")
