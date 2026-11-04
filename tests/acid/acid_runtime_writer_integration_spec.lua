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
local before_terminal_delivery
local last_writer_terminal
local sink=function(request,done)
  sink_calls=sink_calls+1
  if before_prepare_mutation then
    local mutate=before_prepare_mutation
    before_prepare_mutation=nil
    mutate(request)
  end
  local function complete(result)
    last_writer_terminal=result
    if before_terminal_delivery then
      local action=before_terminal_delivery
      before_terminal_delivery=nil
      action(result)
    end
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
local _,_,_,created_label,created_custom=store.read_entry(song,created_id)
assert(created_label=="Pattern "..created_id and created_custom==false,
  "New phrase did not derive its default label from the allocated stable ID")
assert(ctx:editor_state().label==created_label and ctx:editor_state().label_custom==false,
  "committed New default label was not adopted into editor/history state")
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
assert(ctx:rename_label("Explicit",true))

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
local _,_,_,first_label,first_custom=store.read_entry(song,first_revision_id)
assert(first_label=="Explicit" and first_custom==true,
  "regeneration did not preserve accepted custom label metadata")
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
  for index=1,12 do dirty.scale_mask[index]=index==1 end
  dirty.scale_mask_enabled=true
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
  assert(target_phrase.cells[1].note_value==48 and
      target_ctx:editor_state().prepared_resolution.resolved_records[1].note==48,
    "masked raw pitch was not shared with the committed render output")
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

do
  local previous_song_accessor=renoise.song
  local function duplicate_fixture()
    local target={}
    for key,value in pairs(instrument)do target[key]=value end
    target.name,target.phrases="Duplicate transaction",{}
    local target_song={instruments={target},tool_data="",transport={timing_model=2,groove_enabled=false}}
    function target_song:is_undo_redoing()return false end
    renoise.song=function()return target_song end
    local owner=new_context()
    local completions,delivery=delivered()
    owner:attach_document(target_song);owner:open_dialog(delivery);owner:bind_new(target)
    edit(owner,source(48));dispatch(owner)
    local original=assert(completions[1].phrase)
    assert_success(completions[1],original,"duplicate origin create")
    assert(owner:rename_label("Acid Pattern",true))
    edit(owner,source(51))
    local descriptor=assert(drafts.capture(target_song,target,original,owner:draft_options()))
    return owner,target_song,target,original,completions,descriptor
  end
  local owner,target_song,target,original,completions,descriptor=duplicate_fixture()
  local baseline=assert(ownership.snapshot(original))
  local committed=assert(store.load(target_song,target,original))
  assert(owner:request_duplicate())
  local result=assert(completions[2],"duplicate completion missing: "..tostring(owner:generation_state().last_result and owner:generation_state().last_result.reason))
  assert_success(result,result.phrase,"committed-source duplicate")
  assert(not rawequal(result.phrase,original) and #target.phrases==2)
  assert(ownership.id(result.phrase)~=ownership.id(original))
  assert(ownership.compare(baseline,assert(ownership.snapshot(original))))
  assert(sequencer.same_source(committed,assert(store.load(target_song,target,result.phrase))))
  local _,_,_,label,custom=store.read_entry(target_song,ownership.id(result.phrase))
  assert(label=="Acid Pattern copy" and custom==true)
  assert(sequencer.same_source(owner:editor_state().source,committed) and
    rawequal(owner:target_state().phrase,result.phrase),"duplicate completion accepted dirty origin source")
  assert(drafts.is_current(target_song,descriptor) and
    sequencer.same_source(source(51),assert(drafts.get(target_song,target,original))) and
    sequencer.same_source(source(51),assert(store.read_draft(target_song,target,original))),
    "duplicate success consumed or changed original draft")
  owner:release_document()

  for _,change in ipairs({"target","source","label"}) do
    local owner,target_song,target,original,completions,descriptor=duplicate_fixture()
    local changed_editor,changed_revision,changed_draft
    before_terminal_delivery=function(result)
      assert(result.kind=="success" and result.verified,"stale duplicate fixture did not commit")
      if change=="target" then assert(owner:restore_editor_target(target,nil))
      elseif change=="source" then edit(owner,source(54))
      else assert(owner:rename_label("Later label",true))end
      changed_editor=assert(owner:editor_state())
      changed_revision=owner:revision_state()
      changed_draft=assert(drafts.capture(target_song,target,original,owner:draft_options()))
    end
    assert(owner:request_duplicate())
    assert(#target.phrases==2 and ownership.id(target.phrases[2])~=ownership.id(original),
      "late binding change removed verified duplicate")
    local selected=owner:target_projection()
    assert((change=="target" and selected.kind=="new" or
      change~="target" and rawequal(selected.phrase,original)) and
      sequencer.same_source(changed_editor.source,owner:editor_state().source) and
      owner:editor_state().label==changed_editor.label and
      owner:revision_state().target_revision==changed_revision.target_revision and
      owner:revision_state().edit_revision==changed_revision.edit_revision and
      owner:revision_state().metadata_revision==changed_revision.metadata_revision,
      "stale duplicate completion replaced current editor or selection")
    assert((not completions[2] or completions[2].stale==true and completions[2].destination_current==false) and
      drafts.is_current(target_song,changed_draft),
      "stale duplicate completion delivered to replaced editor or consumed origin draft")
    if change=="target" then assert(drafts.is_current(target_song,descriptor))end
    owner:release_document()
  end

  for _,phase in ipairs({"allocation","insertion","materialization","store","verification",
      "origin-materialized","origin-committed","rollback"}) do
    local owner,target_song,target,original,completions,descriptor=duplicate_fixture()
    local raw=target_song.tool_data
    local baseline=assert(ownership.snapshot(original))
    local allocate,insert,apply,commit,restore,classify=store.allocate,target.insert_phrase_at,
      materializer.apply,store.commit,store.restore,require("writers.phrase_validator").classify_verified_postimage
    local validator=require("writers.phrase_validator")
    if phase=="allocation" then store.allocate=function()return nil,"injected allocation"end
    elseif phase=="insertion" then target.insert_phrase_at=function()error("injected insertion")end
    elseif phase=="materialization" then materializer.apply=function()return nil,"injected materialization",false end
    elseif phase=="store" then store.commit=function()return nil,"injected store"end
    elseif phase=="verification" then validator.classify_verified_postimage=function()return nil,"injected verification"end
    elseif phase=="origin-materialized" then
      after_materializer_apply=function()original.cells[1].note_value=47 end
    elseif phase=="origin-committed" then
      store.commit=function(...)
        local saved,reason=commit(...)
        if saved then original.cells[1].note_value=47 end
        return saved,reason
      end
    else
      store.commit=function(...)assert(commit(...));error("injected committed store")end
      store.restore=function()return nil,"injected rollback failure"end
    end
    local called,accepted,reason=pcall(owner.request_duplicate,owner)
    store.allocate,target.insert_phrase_at,materializer.apply,store.commit,store.restore,
      validator.classify_verified_postimage=allocate,insert,apply,commit,restore,classify
    after_materializer_apply=nil
    assert(called,phase..": duplicate escaped transaction: "..tostring(accepted))
    local result=completions[2] or last_writer_terminal
    assert(not accepted or result and result.kind=="failure",phase..": failure was reported as success")
    assert(drafts.is_current(target_song,descriptor),phase..": original draft revision changed")
    assert(drafts.matches_values(target_song,target,original,source(51),"play_once",0),
      phase..": original session draft changed")
    assert(sequencer.same_source(source(51),assert(store.read_draft(target_song,target,original))))
    if phase=="rollback" then
      assert(result and result.status=="integrity_blocked" and owner:integrity_state().blocked,
        "uncertain duplicate rollback did not retain recovery blocker")
      assert(sequencer.same_source(source(51),owner:editor_state().source),
        "uncertain duplicate rollback replaced original editor source")
    else
      assert(rawequal(owner:target_projection().phrase,original),phase..": failed duplicate changed target")
      assert(target_song.tool_data==raw and #target.phrases==1 and rawequal(target.phrases[1],original),
        phase..": duplicate did not restore exact store and phrase inventory")
      if phase=="origin-materialized" or phase=="origin-committed" then
        assert(original.cells[1].note_value==47,phase..": rollback overwrote external origin edit")
      else assert(ownership.compare(baseline,assert(ownership.snapshot(original))),phase..": origin phrase changed")end
    end
    owner:release_document()
  end

  -- A failed runtime adoption after a verified writer commit stays blocked
  -- until same-song reattachment proves the committed target again.
  local seed_ctx,adoption_song,adoption_target,adoption_phrase=duplicate_fixture()
  seed_ctx:release_document()
  local integrity_module=require("runtime.integrity")
  local original_integrity_new=integrity_module.new
  integrity_module.new=function(...)
    local owner=original_integrity_new(...)
    owner.record=function()return false,"injected integrity evidence failure"end
    return owner
  end
  local adoption_ctx=new_context()
  local adoption_results,adoption_delivery=delivered()
  adoption_ctx:attach_document(adoption_song)
  adoption_ctx:open_dialog(adoption_delivery)
  assert(adoption_ctx:bind_phrase(adoption_target,adoption_phrase).kind=="owned")
  integrity_module.new=original_integrity_new

  local function fail_adoption(note)
    fail_next_adoption=true
    edit(adoption_ctx,source(note))
    local expected=#adoption_results+1
    dispatch(adoption_ctx)
    drain(adoption_results,expected,"adoption failure")
    assert(adoption_results[#adoption_results].status=="integrity_blocked" and
      adoption_ctx:integrity_state().blocked,
      "failed adoption recording did not block the current session")
    local calls=sink_calls
    adoption_ctx:close_dialog();adoption_ctx:open_dialog(adoption_delivery)
    assert(not adoption_ctx:request_generation("manual") and sink_calls==calls,
      "dialog reopen cleared an unrecorded adoption blocker")
  end

  fail_adoption(54)
  assert(adoption_ctx:release_document())
  local classify=require("writers.phrase_validator").classify
  local classifications=0
  require("writers.phrase_validator").classify=function(...)
    classifications=classifications+1
    return classify(...)
  end
  adoption_ctx:attach_document(adoption_song);adoption_ctx:open_dialog(adoption_delivery)
  local rebound=adoption_ctx:bind_phrase(adoption_target,adoption_phrase)
  require("writers.phrase_validator").classify=classify
  assert(classifications>0 and rebound.kind=="owned" and rebound.baseline and
    rebound.baseline.id==ownership.id(adoption_phrase),
    "same-song attachment did not establish a fresh committed target proof")
  edit(adoption_ctx,source(55))
  local regenerate_expected=#adoption_results+1
  dispatch(adoption_ctx)
  drain(adoption_results,regenerate_expected,"regenerate after fresh target proof")
  assert_success(adoption_results[#adoption_results],adoption_phrase,"regenerate after fresh target proof")

  fail_adoption(56)
  assert(adoption_ctx:release_document())
  adoption_phrase.cells[MAX_LINES].delay_value=1
  adoption_ctx:attach_document(adoption_song);adoption_ctx:open_dialog(adoption_delivery)
  assert(adoption_ctx:bind_phrase(adoption_target,adoption_phrase).kind=="unavailable",
    "same-song attachment adopted a corrupt native phrase after failed evidence recording")
  local calls=sink_calls
  assert(not adoption_ctx:request_generation("manual") and sink_calls==calls,
    "corrupt post-commit phrase passed full generation admission")
  adoption_phrase.cells[MAX_LINES].delay_value=0
  adoption_ctx:release_document()
  integrity_module.new=original_integrity_new
  renoise.song=previous_song_accessor
end

print("ACID runtime writer integration checks passed (native playback unverified)")
