-- Exercise the production runtime request seam with the real phrase writer,
-- pattern store and draft cache against one API-shaped host. No playback claims.
dofile("tests/bootstrap.lua")("acid")
local columns=dofile("tests/acid/phrase_columns.lua")
local pitch=dofile("tests/acid/pitch_fixture.lua")

local EMPTY_SCRIPT_DIAGNOSTIC="compile error: no script content present."

local function observable()
  local handlers={}
  return {
    add_notifier=function(_,callback) handlers[callback]=true end,
    remove_notifier=function(_,callback) handlers[callback]=nil end,
    fire=function()
      local pending={}
      for callback in pairs(handlers) do pending[#pending+1]=callback end
      for _,callback in ipairs(pending) do callback() end
    end,
  }
end
local idle,committed=observable(),observable()

local instrument
local render_queue={}
local render_mode="sync"
local defer_commit=false

local function make_script()
  local script={paragraphs={},parameters={},pending_changes=0,editor_visible=true,
    compile_error="",runtime_error="",committed_observable=committed}
  function script:commit()
    self.compile_error=#self.paragraphs==0 and EMPTY_SCRIPT_DIAGNOSTIC or ""
    self.runtime_error=""
    if defer_commit then
      local notify
      notify=function()
        idle:remove_notifier(notify)
        committed:fire()
      end
      idle:add_notifier(notify)
    else
      committed:fire()
    end
  end
  function script:render_to_pattern(options,callback)
    local source=assert(self.paragraphs[1])
    local values=assert(source:match("local values = { (.-) }\nreturn pattern"))
    local target=instrument.phrases[#instrument.phrases]
    local step,count=0,0
    for token in (values..","):gmatch("(.-),") do
      local volume=tonumber(token:match("volume = ([%d%.]+)"))
      local note=tonumber(token:match("key = (%d+)"))
      local off=token:find('"off"',1,true)~=nil
      local empty=token:match("^%s*false%s*$")~=nil
      if volume then
        local line=(math.max(step,1)-1)*4+1
        target.cells[line].volume_value=volume==1 and 255 or 89
      end
      if note or off or empty then
        step=step+1
        local line=(step-1)*4+1
        if note then
          target.cells[line].note_value=note
          count=count+1
        elseif off then
          target.cells[line].note_value=120
          count=count+1
        end
      end
    end
    assert(options.lpb==16,"straight source rendered at an unexpected LPB")
    if render_mode=="defer" then
      render_queue[#render_queue+1]={callback=callback,count=count,steps=step}
      return true
    end
    callback(nil,count,0)
    return true
  end
  return script
end

local MAX_LINES,MAX_NOTE_COLUMNS,MAX_EFFECT_COLUMNS=16,2,1

local function make_phrase()
  local phrase={name="",number_of_lines=16,lpb=16,shuffle=0,looping=false,
    loop_start=1,loop_end=16,playback_mode=1,key_tracking=1,base_note=48,
    autoseek=false,visible_note_columns=1,visible_effect_columns=0,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,mapping=nil,cells={},
    script=make_script(),column_names={},column_mutes={}}
  for column=1,MAX_NOTE_COLUMNS do
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
  tool=function() return {app_idle_observable=idle} end,
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

local sink_calls=0
local fail_next_adoption=false
local sink=function(request,done)
  sink_calls=sink_calls+1
  local function complete(result)
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
  for _=1,400 do
    idle:fire()
    local status=writer.state()
    if #results>=expected and status=="idle" then return end
  end
  local diagnostic=writer.diagnostic()
  error(label..": terminal delivery did not arrive (writer="..tostring(writer.state())..
    ", sink calls="..tostring(sink_calls)..", diagnostic="..tostring(diagnostic and diagnostic.message)..")")
end
local function settle_writer(label)
  for _=1,400 do
    idle:fire()
    if writer.state()=="idle" then return end
  end
  error(label..": writer did not settle")
end
local function next_render(label)
  for _=1,20 do
    if #render_queue>0 then return table.remove(render_queue,1) end
    idle:fire()
  end
  error(label..": native render did not start")
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

edit(ctx,source(52))
dispatch(ctx)
drain(results,2,"first regenerate")
assert_success(results[2],phrase,"first regenerate")
assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],phrase))
assert(phrase.cells[1].note_value==52)
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
  and reopened.baseline and reopened.baseline.id==created_id,
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
cold_ctx:transition("arm")
edit(cold_ctx,source(54))
assert(cold_ctx:generation_state().pending,"post-commit Live Edit was not queued")
cold_ctx:refresh_inventory()
assert(cold_ctx:generation_state().pending,
  "refresh treated the runtime's own adopted baseline as an external target change")
cold_ctx:transition("disarm")
cold_ctx:transition("programmatic",{source=cold_source,output_policy="play_once",pb_range=0,restore=true})
assert(drafts.clear(song,instrument,phrase))

-- While the writer is rendering asynchronously, a newer edit supersedes the
-- active request and leaves one latest pending intent. The writer remains
-- occupied until its native callback; flush_pending dispatches the latest
-- intent only after that terminal retirement.
render_mode="defer"
cold_ctx:bind_new(instrument)
edit(cold_ctx,source(36))
local queued_create=cold_ctx:request_generation("manual")
assert(queued_create,"queued create was rejected")
local pending=cold_ctx:state()
assert(pending.status=="pending" and pending.pending==false)
local active_token=pending.token
local first_render=next_render("deferred create")
assert(writer.state()=="busy")
local sink_before_queue=sink_calls
edit(cold_ctx,source(40))
local queued,queued_reason=cold_ctx:request_generation("manual")
assert(queued,queued_reason)
assert(not active_token:is_current(),"newer edit did not supersede the active request")
assert(cold_ctx:state().pending==true,"latest edit was not queued")
local blocked, blocked_reason=cold_ctx:request_generation("manual")
assert(blocked,blocked_reason)
assert(cold_ctx:state().pending==true,"second queue replaced the pending intent")
edit(cold_ctx,source(43))
queued,queued_reason=cold_ctx:request_generation("manual")
assert(queued,queued_reason)
assert(cold_ctx:state().pending==true)
assert(sink_calls==sink_before_queue,"queued edits dispatched into a busy writer")
first_render.callback(nil,first_render.count,0)
settle_writer("superseded create")
assert(#cold==1,"superseded create unexpectedly delivered a commit")
assert(cold_ctx:state().pending==true,"pending intent was lost at terminal")
local flushed, flush_reason=cold_ctx:flush_pending()
assert(flushed,flush_reason)
local second_render=next_render("flushed latest edit")
second_render.callback(nil,second_render.count,0)
drain(cold,2,"flushed latest edit")
local created_second=instrument.phrases[#instrument.phrases]
assert_success(cold[2],created_second,"flushed latest edit")
assert(#instrument.phrases==2 and rawequal(instrument.phrases[2],created_second))
assert(created_second.cells[1].note_value==43,
  "flush_pending did not dispatch the latest queued edit")
assert(phrase.cells[1].note_value==57,"queued work changed the first destination")
assert(drafts.get(song,instrument,created_second)==nil,
  "flushed create retained the session draft")
assert(store.read_draft(song,instrument,created_second)==nil,
  "flushed create retained the durable draft")
assert(drafts.has(song)==false,"flushed create left a draft behind")
assert(cold_ctx:state().pending==false)
render_mode="sync"

-- Cancellation before the deferred native render settles and leaves the
-- scheduler dispatchable for a later create.
defer_commit=true
cold_ctx:bind_new(instrument)
edit(cold_ctx,source(45))
local cancelled_before=sink_calls
assert(cold_ctx:request_generation("manual"))
local token=cold_ctx:state().token
assert(token and writer.cancel(token,"cancelled before render")==true)
drain(cold,3,"cancelled before render")
assert(cold[3].kind=="failure" and cold[3].status=="cancelled",
  "pre-render cancellation was not terminal")
assert(writer.state()=="idle","cancellation wedged the writer")
assert(cold_ctx:state().status=="idle","cancellation wedged the scheduler")
defer_commit=false
cold_ctx:bind_new(instrument)
edit(cold_ctx,source(47))
dispatch(cold_ctx)
drain(cold,4,"recovery create")
local recovered=instrument.phrases[#instrument.phrases]
assert_success(cold[4],recovered,"recovery create")
assert(recovered.cells[1].note_value==47)
assert(sink_calls==cancelled_before+2,"unexpected dispatch count after cancellation")

-- Committed output with a leaked backup blocks every later request, including
-- after dialog reopen, until explicit read-only revalidation proves consistency.
local native_delete=instrument.delete_phrase_at
instrument.delete_phrase_at=function(self,index)
  if self.phrases[index].name==writer.TRANSACTION_BACKUP_NAME then error("injected backup cleanup failure") end
  return native_delete(self,index)
end
cold_ctx:bind_phrase(instrument,recovered)
edit(cold_ctx,source(49))
dispatch(cold_ctx)
drain(cold,5,"committed cleanup failure")
instrument.delete_phrase_at=native_delete
assert(cold[5].integrity_blocked and cold[5].committed==true,
  tostring(cold[5].kind).."/"..tostring(cold[5].status).." committed="..tostring(cold[5].committed))
assert(recovered.cells[1].note_value==49,"musical commit was not reported accurately")
assert(cold_ctx:integrity_state().blocked,"committed cleanup failed to persist its blocker")
assert(not cold_ctx:request_generation("manual"),"recovery material did not block generation")
local recovery_phrase=instrument.phrases[#instrument.phrases]
assert(recovery_phrase.name==writer.RECOVERY_BACKUP_NAME)
assert(writer.is_temporary(song,instrument,recovery_phrase),
  "retained recovery phrase lost its writer-temporary registration")
assert(not cold_ctx:revalidation_status().verified)
cold_ctx:close_dialog()
cold_ctx:open_dialog(cold_delivery)
assert(cold_ctx:integrity_state().blocked and not cold_ctx:request_generation("manual"))
native_delete(instrument,#instrument.phrases)
local revalidation,proof=cold_ctx:revalidation_status()
assert(revalidation.verified,revalidation.reason)
assert(cold_ctx:revalidate(proof),"verified committed recovery could not be revalidated")
assert(not cold_ctx:integrity_state().blocked)

-- A verified musical commit whose runtime baseline adoption fails must block
-- later generation until the committed destination passes explicit revalidation.
cold_ctx:bind_new(instrument)
edit(cold_ctx,source(50))
fail_next_adoption=true
dispatch(cold_ctx)
drain(cold,6,"post-commit adoption failure")
local adoption_phrase=instrument.phrases[#instrument.phrases]
assert(cold[6].status=="integrity_blocked" and cold[6].committed==true,
  "post-commit adoption failure was not reported as blocked")
assert(adoption_phrase.cells[1].note_value==50,"writer commit did not complete before adoption failed")
assert(cold_ctx:integrity_state().blocked,"adoption failure did not persist an integrity blocker")
local sink_before_blocked_request=sink_calls
local accepted= cold_ctx:request_generation("manual")
assert(not accepted and sink_calls==sink_before_blocked_request,
  "generation was dispatched while committed state awaited revalidation")
cold_ctx:bind_new(instrument)
assert(cold_ctx:integrity_state().blocked and not cold_ctx:request_generation("manual"),
  "changing the selected destination cleared the adoption blocker")
cold_ctx:close_dialog()
cold_ctx:open_dialog(cold_delivery)
assert(cold_ctx:integrity_state().blocked and not cold_ctx:request_generation("manual"),
  "reopening the dialog cleared the adoption blocker")
local committed_note=adoption_phrase.cells[1].note_value
adoption_phrase.cells[1].note_value=committed_note-1
local adoption_status,adoption_proof=cold_ctx:revalidation_status()
assert(not adoption_status.verified and not adoption_proof,
  "inconsistent committed output passed explicit revalidation")
adoption_phrase.cells[1].note_value=committed_note
adoption_status,adoption_proof=cold_ctx:revalidation_status()
assert(adoption_status.verified,adoption_status.reason)
assert(cold_ctx:revalidate(adoption_proof),"consistent committed destination could not be revalidated")
assert(not cold_ctx:integrity_state().blocked)
assert(sink_calls==sink_before_blocked_request,"revalidation retried a prior generation request")
cold_ctx:bind_new(instrument)
edit(cold_ctx,source(51))
dispatch(cold_ctx)
drain(cold,7,"generation after explicit adoption revalidation")
assert(cold[7].kind=="success" and sink_calls==sink_before_blocked_request+1,
  "fresh generation did not dispatch after explicit revalidation")

-- A rejected or throwing writer blocker hook still installs runtime evidence.
local blocker_target=cold[7].phrase
local function test_blocker_hook_failure(mode,note)
  local hook_ctx=new_context()
  local hook_results,hook_delivery=delivered()
  hook_ctx:attach_document(song)
  hook_ctx:open_dialog(hook_delivery)
  hook_ctx:bind_phrase(instrument,blocker_target)
  edit(hook_ctx,source(note))
  local record_blocker=hook_ctx.record_blocker
  hook_ctx.record_blocker=function()
    if mode=="throw" then error("injected blocker hook failure") end
    return false,"injected blocker rejection"
  end
  local delete_phrase=instrument.delete_phrase_at
  instrument.delete_phrase_at=function(self,index)
    if self.phrases[index].name==writer.TRANSACTION_BACKUP_NAME then
      error("injected committed backup cleanup failure")
    end
    return delete_phrase(self,index)
  end
  local expected=#hook_results+1
  dispatch(hook_ctx)
  drain(hook_results,expected,"blocker hook "..mode)
  hook_ctx.record_blocker=record_blocker
  instrument.delete_phrase_at=delete_phrase
  assert(hook_results[expected].kind=="failure" and hook_results[expected].status=="integrity_blocked",
    "blocker hook "..mode.." did not produce a blocked terminal result")
  assert(hook_ctx:integrity_state().blocked,
    "blocker hook "..mode.." failed to install runtime integrity evidence")
  assert(not hook_ctx:request_generation("manual"),
    "blocker hook "..mode.." allowed a subsequent generation")
  local recovery=instrument.phrases[#instrument.phrases]
  assert(recovery.name==writer.RECOVERY_BACKUP_NAME,
    "blocker hook "..mode.." did not retain its backup")
  instrument.delete_phrase_at(instrument,#instrument.phrases)
  local status,proof=hook_ctx:revalidation_status()
  assert(status.verified, status.reason)
  assert(hook_ctx:revalidate(proof),"blocker hook "..mode.." evidence could not be revalidated")
  hook_ctx:release_document()
end
test_blocker_hook_failure("reject",53)
test_blocker_hook_failure("throw",54)
local verified_ctx=new_context()
local verified_results,verified_delivery=delivered()
verified_ctx:attach_document(song)
verified_ctx:open_dialog(verified_delivery)
verified_ctx:bind_phrase(instrument,blocker_target)
edit(verified_ctx,source(55))
dispatch(verified_ctx)
drain(verified_results,1,"generation after blocker-hook revalidation")
assert(verified_results[1].kind=="success",
  "verified blocker-hook recovery did not release the writer integrity latch")
verified_ctx:release_document()

-- The module-level runtime is reused across documents. Its released delivery
-- cannot remain active after the real writer detaches its completion callback.
render_mode="defer"
cold_ctx:bind_new(instrument)
edit(cold_ctx,source(42))
dispatch(cold_ctx)
local released_render=next_render("released render")
local released_song=song
local released_store=song.tool_data
local released_stage=instrument.phrases[#instrument.phrases]
local delivered_before_release=#cold
cold_ctx:release_document()
local warning=writer.release()
assert(type(warning)=="string" and warning:find(writer.PHRASE_NAME,1,true))
local next_instrument={}
for key,value in pairs(instrument) do if key~="phrases" then next_instrument[key]=value end end
next_instrument.phrases={}
instrument=next_instrument
song={instruments={instrument},transport={timing_model=2,lpb=16,tpl=12,groove_enabled=false}}
function song:is_undo_redoing() return false end
cold_ctx:attach_document(song)
cold_ctx:open_dialog(cold_delivery)
cold_ctx:bind_new(instrument)
edit(cold_ctx,source(46))
assert(not cold_ctx:request_generation("manual"),"released native render lost occupancy")
released_render.callback(nil,released_render.count,0)
assert(writer.state()=="idle" and #cold==delivered_before_release)
assert(cold_ctx:state().status=="idle","released delivery permanently wedged the reused runtime")
assert(cold_ctx:state().pending==false and not cold_ctx:flush_pending())
assert(released_song.tool_data==released_store and released_stage.name==writer.PHRASE_NAME)
render_mode="sync"
dispatch(cold_ctx)
drain(cold,delivered_before_release+1,"new document after released callback")
assert_success(cold[#cold],instrument.phrases[#instrument.phrases],"new document create")

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

  -- Real native-render occupancy excludes identity work before and after
  -- cancellation. Its matching callback retires the slot without retrying it.
  local identity_ctx=new_context()
  identity_ctx:attach_document(song)
  identity_ctx:open_dialog()
  identity_ctx:bind_phrase(instrument,selected)
  local holder_names={selected.name,second.name,third.name}
  local dispatch_before_render=sink_calls
  render_mode="defer"
  cold_ctx:bind_new(instrument)
  edit(cold_ctx,source(52))
  local store_bytes=song.tool_data
  dispatch(cold_ctx)
  local render=next_render("identity exclusion create")
  local request_token=assert(cold_ctx:state().token)
  assert(writer.state()=="busy")
  local eligible,reason=identity_ctx:independence_eligibility()
  assert(not eligible and tostring(reason):find("writer",1,true),
    "active real writer did not reject identity eligibility: "..tostring(reason))
  local changed,occupied_reason=identity_ctx:make_independent()
  assert(not changed and tostring(occupied_reason):find("writer",1,true),
    "active real writer admitted identity work: "..tostring(occupied_reason))
  assert(sink_calls==dispatch_before_render+1,"identity rejection dispatched another writer job")

  assert(cold_ctx:revoke(request_token,"identity exclusion cancellation"))
  assert(not request_token:is_current() and writer.state()=="busy",
    "revocation released active native render occupancy")
  changed,occupied_reason=identity_ctx:make_independent()
  assert(not changed and tostring(occupied_reason):find("writer",1,true),
    "canceled in-flight writer admitted identity work: "..tostring(occupied_reason))
  assert(sink_calls==dispatch_before_render+1,"occupied identity rejection queued work")
  assert(song.tool_data==store_bytes and selected.name==holder_names[1] and
    second.name==holder_names[2] and third.name==holder_names[3],
    "occupied identity rejection mutated the collision")

  render.callback(nil,render.count,0)
  settle_writer("identity exclusion cancellation")
  assert(song.tool_data==store_bytes and selected.name==holder_names[1] and
    second.name==holder_names[2] and third.name==holder_names[3],
    "late render settlement retried identity work or changed the collision")
  assert(sink_calls==dispatch_before_render+1,
    "late settlement dispatched a rejected identity action")
  assert(writer.state()=="idle")
  identity_ctx:release_document()
  cold_ctx:bind_phrase(instrument,selected)
  assert(cold_ctx:independence_eligibility(),"fresh identity authorization failed after settlement")
  render_mode="sync"

  local dispatch_count=sink_calls
  local independent,identity= cold_ctx:make_independent()
  assert(independent,identity)
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

  edit(cold_ctx,source(49))
  dispatch(cold_ctx)
  drain(cold,#cold+1,'regenerate unique holder beside unrelated collision')
  assert_success(cold[#cold],selected,'regenerate unique holder beside unrelated collision')
  assert(#instrument.phrases==3 and ownership.id(selected)==identity.id)
  assert(#assert(ownership.inventory(song))[old_id]==2,
    'unrelated two-holder collision was altered by regeneration')
  assert(first_note(assert(store.load(song,instrument,selected)))==49)

  cold_ctx:release_document()
  cold_ctx:attach_document(song)
  cold_ctx:open_dialog(cold_delivery)
  cold_ctx:bind_phrase(instrument,selected)
  local reopened_target=cold_ctx:target_state()
  assert(reopened_target.kind=='owned' and reopened_target.baseline.id==identity.id)
  assert(first_note(assert(store.load(song,instrument,selected)))==49)
  edit(cold_ctx,source(51))
  dispatch(cold_ctx)
  drain(cold,#cold+1,'reopen and regenerate independent holder')
  assert_success(cold[#cold],selected,'reopen and regenerate independent holder')
  assert(first_note(assert(store.load(song,instrument,selected)))==51)
  assert(#assert(ownership.inventory(song))[old_id]==2)
end

print("ACID runtime writer integration checks passed (native playback unverified)")
