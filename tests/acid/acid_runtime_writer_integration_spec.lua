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

local function make_phrase()
  local phrase={name="",number_of_lines=16,lpb=16,shuffle=0,looping=false,
    loop_start=1,loop_end=16,playback_mode=1,key_tracking=1,base_note=48,
    autoseek=false,visible_note_columns=1,visible_effect_columns=0,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,mapping=nil,cells={},
    script=make_script(),column_names={},column_mutes={}}
  for column=1,12 do
    phrase.column_names[column]="column "..column
    phrase.column_mutes[column]=false
  end
  for line=1,512 do
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
    for line=1,512 do
      local copy={}
      for key,value in pairs(other.cells[line] or {}) do copy[key]=value end
      self.cells[line]=copy
    end
    for column=1,12 do
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
    MAX_NUMBER_OF_LINES=512,MAX_NUMBER_OF_NOTE_COLUMNS=12,
    MAX_NUMBER_OF_EFFECT_COLUMNS=8},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function() return song end,
  tool=function() return {app_idle_observable=idle} end,
}

local context=require("runtime.context")
local drafts=require("runtime.draft_cache")
local writer=require("writers.phrase_writer")
local store=require("renoise.pattern_store")
local ownership=require("renoise.phrase_ownership")
local sequencer=require("model.sequencer")

local sink_calls=0
local sink=function(request,done)
  sink_calls=sink_calls+1
  if request.kind=="create" then return writer.create(request,done) end
  if request.kind=="regenerate" then return writer.regenerate(request,done) end
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
  error(label..": terminal delivery did not arrive")
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

print("ACID runtime writer integration checks passed (native playback unverified)")
