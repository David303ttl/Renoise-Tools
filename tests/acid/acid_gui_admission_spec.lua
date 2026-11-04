dofile("tests/bootstrap.lua")("acid")

local function observable()
  local handlers={}
  return {
    add_notifier=function(_,handler) handlers[handler]=true end,
    has_notifier=function(_,handler) return handlers[handler]==true end,
    remove_notifier=function(_,handler) handlers[handler]=nil end,
    fire=function(self)
      local pending={}
      for handler in pairs(handlers) do pending[#pending+1]=handler end
      for _,handler in ipairs(pending) do if handlers[handler] then handler() end end
    end
  }
end

local function view_builder()
  local builder={views={},nodes={}}
  local parent_by_child={}
  local function add_view(parent,child)
    if parent_by_child[child] then error("view already has a parent") end
    parent.views[#parent.views+1]=child;parent_by_child[child]=parent
  end
  local function remove_view(parent,child)
    for index,current in ipairs(parent.views) do
      if rawequal(current,child) then table.remove(parent.views,index);parent_by_child[child]=nil;return end
    end
    error("view is not a child")
  end
  local function construct(kind,properties)
    local node={kind=kind,views={},notifiers={}}
    for key,value in pairs(properties or {}) do
      if type(key)=="number" then add_view(node,value)
      else node[key]=value end
    end
    if node.id then builder.views[node.id]=node end
    builder.nodes[#builder.nodes+1]=node
    function node:add_view(child) add_view(self,child) end
    function node:remove_view(child) remove_view(self,child) end
    node.add_child=node.add_view;node.remove_child=node.remove_view
    function node:add_notifier(handler) self.notifiers[#self.notifiers+1]=handler end
    function node:fire(value)
      self.value=value
      if self.notifier then self.notifier(value) end
      for _,handler in ipairs(self.notifiers) do handler(value) end
    end
    return node
  end
  setmetatable(builder,{__index=function(_,kind)
    return function(_,properties) return construct(kind,properties) end
  end})
  return builder
end

local tool={app_new_document_observable=observable(),app_release_document_observable=observable(),
  app_idle_observable=observable(),tool_will_unload_observable=observable(),writer_calls={},
  preferences={custom_scales={value=""}}}

local phrase_one={id=11,name="Owned one"}
local phrase_two={id=12,name="Owned two"}
local instrument={name="Target",phrases={phrase_one,phrase_two},phrase_program=1,
  samples={},sample_modulation_sets={},sample_device_chains={}}
local other_owned={id=21,name="Other owned"}
local other_foreign={id=22,name="Other foreign",foreign=true}
local other_instrument={name="Other target",phrases={other_owned,other_foreign},
  phrase_program=1,samples={},sample_modulation_sets={},sample_device_chains={}}
local song={selected_instrument_index=1,selected_instrument=instrument,
  selected_phrase=phrase_one,selected_phrase_observable=observable(),
  instruments={instrument,other_instrument}}
local current_builder
local dialogs={}
local warnings={}
local app={}
function app:show_custom_dialog(_,content)
  local dialog={visible=true,content=content,show=function()end,
    close=function(self)self.visible=false end}
  dialogs[#dialogs+1]=dialog
  return dialog
end
function app:show_warning(message) warnings[#warnings+1]=message end
function app:show_prompt(title)
  error("Unexpected confirmation: "..tostring(title))
end

local persisted_drafts={}
local persisted_entries={}
local fail_draft_persistence=false
local fail_draft_clear=false
local draft_save_attempts=0
local valid_label=require("renoise.pattern_store").valid_label
package.loaded["renoise.pattern_store"]={valid_label=valid_label,load=function(_,instrument,phrase)
  local committed=persisted_entries[phrase.id]
  if committed then
    return assert(require("model.sequencer").copy_source(committed.source)),
      committed.output_policy,committed.pb_range
  end
  local source=require("model.sequencer").new_pattern(16)
  if phrase.id==12 then source.timing_mode="triplet" end
  return source,"repeat",phrase.id==11 and 2 or phrase.id==12 and 48 or 0
end,
  write_draft_metadata=function(song,instrument,phrase,pattern,policy,pb_range)
    draft_save_attempts=draft_save_attempts+1
    local index;for i,candidate in ipairs(song.instruments) do if rawequal(candidate,instrument) then index=i;break end end
    local phrase_id,name=phrase and phrase.id or 0,instrument.name
    if fail_draft_persistence then return nil,"test persistence failure" end
    persisted_drafts[index..":"..phrase_id]={pattern=pattern,policy=policy,
      pb_range=pb_range,name=name}
    return true
  end,
  read_draft=function(song,instrument,phrase)
    local index;for i,candidate in ipairs(song.instruments) do if rawequal(candidate,instrument) then index=i;break end end
    local phrase_id,name=phrase and phrase.id or 0,instrument.name
    local item=persisted_drafts[index..":"..phrase_id]
    if not item then return nil end
    assert(item.name==name)
    return item.pattern,item.policy,item.pb_range
  end,
  read_entry=function(_,id)
    local item=persisted_entries[id]
    if not item then return nil end
    return item.source,item.output_policy,item.pb_range
  end,
  clear_draft=function(song,instrument,phrase)
    local index;for i,candidate in ipairs(song.instruments) do if rawequal(candidate,instrument) then index=i;break end end
    local phrase_id=phrase and phrase.id or 0
    if fail_draft_clear then return nil,"test cleanup failure" end
    persisted_drafts[index..":"..phrase_id]=nil
    return true
  end,
  has_drafts=function()return next(persisted_drafts)~=nil end}
package.loaded["renoise.phrase_ownership"]={
  status=function(phrase)return phrase.foreign and "foreign" or "owned" end,
  id=function(phrase)if phrase.foreign then return nil end;return phrase.id end,
  snapshot_index=function()return nil end,
  capture_recovery=function()return {} end,
}
local render_callbacks={}
local active_request
local sync_next_result
local preserve_target_on_sync_success=false
local function terminal_result(call,status,message)
  local success=status=="committed" or status=="approximate"
  local phrase=call.phrase or call.request.phrase
  local result={kind=success and "success" or "failure",status=status or (success and "committed" or "failed"),
    verified=success,token=call.request.token,epoch=call.request.epoch,request=call.request,
    phrase=success and phrase or nil,reason=success and nil or (message or "fixture complete"),
    message=message or "fixture complete"}
  if success then
    if phrase and phrase.id and call.request.token:is_current() then
      persisted_entries[phrase.id]={source=call.request.source,
        output_policy=call.request.output_policy,pb_range=call.request.pb_range}
    end
    local candidate
    if call.request.kind=="create" and phrase then
      local ok,value=pcall(function()
        return require("writers.phrase_validator").classify(call.request.song,
          call.request.instrument,phrase,{},{},{})
      end)
      if ok then candidate=value end
    end
    result.baseline=candidate and {id=phrase.id,source=candidate.source,settings=candidate.settings,
      snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs} or
      {id=phrase and phrase.id,source=call.request.source,
        settings={output_policy=call.request.output_policy,pb_range=call.request.pb_range},
        snapshot=call.request.baseline and call.request.baseline.snapshot or {},
        planning_inputs=call.request.planning_inputs or {capabilities={},capacities={},options={}}}
  end
  return result
end
local function start(kind,request,done)
  local call={kind=kind,request=request,token=request.token,source=request.source,
    pb_range=request.pb_range,token_current_at_start=request.token:is_current()}
  call.pattern=request.source
  call.options={token=request.token,pb_range=request.pb_range,
    phrase_mutation=function(action) return request:mutate(request.token,action) end}
  for index,instrument in ipairs(request.song.instruments) do
    if rawequal(instrument,request.instrument) then call.instrument_index=index;break end
  end
  tool.writer_calls[#tool.writer_calls+1]=call
  if kind=="create" then
    call.target=#request.instrument.phrases+1
  else
    for index,phrase in ipairs(request.instrument.phrases) do
      if rawequal(phrase,request.phrase) then call.target=index;break end
    end
  end
  if kind=="regenerate" then
    request:mutate(request.token,function() song.selected_phrase_observable:fire() end)
    assert(request.token:is_current(),"internal selection notification preserves authorization")
  end
  active_request=request
  local callback_index=#render_callbacks+1
  call.completed=false
  render_callbacks[callback_index]=function(result)
    active_request=nil
    call.completed=true
    done(result)
  end
  if sync_next_result then
    local status=sync_next_result
    sync_next_result=nil
    if status=="committed" and kind=="regenerate" and not preserve_target_on_sync_success then
      request:mutate(request.token,function() request.phrase.id=request.phrase.id+100 end)
    end
    render_callbacks[callback_index](terminal_result(call,status))
  end
  return true
end
package.loaded["writers.phrase_writer"]={
  create=function(request,done) return start("create",request,done) end,
  regenerate=function(request,done) return start("regenerate",request,done) end,
  state=function()
    return active_request and "busy" or "idle",active_request and active_request.token or nil
  end,
  is_temporary=function()return false end,
  cancel=function(token)
    return active_request~=nil and rawequal(active_request.token,token)
  end,
  release=function()end
}

renoise={
  song=function()return song end,
  tool=function()return tool end,
  ViewBuilder=function()
    current_builder=view_builder()
    return current_builder
  end,
  app=function()return app end
}

dofile("tests/acid/gui_host_stub.lua")
local function open_gui()
  require("gui").show()
  return current_builder,dialogs[#dialogs]
end
local function button(builder,label)
  for _,node in ipairs(builder.nodes) do
    if node.kind=="button" and node.text==label then return node end
  end
  error("missing button: "..label)
end
local function pitch_key(builder,index)
  return assert(builder.views[string.format("acid_program_key_%02d",index)],
    "missing PITCH key button "..index)
end
local function popup(builder,width)
  for _,node in ipairs(builder.nodes) do
    if node.kind=="popup" and node.width==width then return node end
  end
  error("missing popup width "..width)
end
local context_module=require("runtime.context")
local original_new=context_module.new
local contexts,admissions={},{}
local fail_next_edit_transition=false
context_module.new=function(options)
  local context=original_new(options)
  contexts[#contexts+1]=context
  local transition=context.transition
  function context:transition(kind,values)
    if fail_next_edit_transition and (kind=="edit" or kind=="reset") then
      fail_next_edit_transition=false
      return nil,"Injected editor transition failure"
    end
    return transition(self,kind,values)
  end
  local request=context.request_generation
  function context:request_generation(trigger)
    local accepted,reason=request(self,trigger)
    admissions[#admissions+1]={trigger=trigger,accepted=accepted,reason=reason,context=self}
    return accepted,reason
  end
  return context
end
local function live_control(builder)
  return assert(builder.views.acid_live_edit,"missing Live Edit checkbox")
end
local function complete(index,status,phrase)
  local call=tool.writer_calls[index]
  call.phrase=phrase
  render_callbacks[index](terminal_result(call,status))
end

local builder,dialog=open_gui()
assert(#contexts==1,"GUI must install one runtime context")
assert(#admissions==0 and #tool.writer_calls==0,"opening must not request generation")
local phrase_popup=popup(builder,360)
local live=live_control(builder)
live:fire(true)
phrase_popup:fire(2)
phrase_popup:fire(1)
builder.views.acid_editor_view:fire(2)
builder.views.acid_editor_view:fire(1)
builder.views.acid_timing:fire(builder.views.acid_timing.value)
builder.views.acid_pb_range:fire(builder.views.acid_pb_range.value)
assert(#admissions==0 and #tool.writer_calls==0,
  "arming, target/source restoration, view navigation and no-op edits must make zero requests")

sync_next_result="error"
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==1 and #admissions==1 and admissions[1].trigger=="manual",
  "manual Generate must enter runtime admission: "..tostring(admissions[#admissions] and admissions[#admissions].reason))
local manual=tool.writer_calls[1]
assert(manual.token_current_at_start and manual.target==1)
assert(manual.completed,"manual write and completion finish inside the Generate callback")
builder.views.acid_timing:fire(builder.views.acid_timing.value)
assert(#admissions==1 and manual.completed,
  "a no-op edit neither enqueues a duplicate nor changes completed state")
pitch_key(builder,2):fire()
assert(#tool.writer_calls==2 and #admissions==2 and admissions[2].trigger=="live",
  "armed edit must enter runtime admission inside the user edit callback")
tool.app_idle_observable:fire()
assert(#tool.writer_calls==2 and #admissions==2,
  "idle must not start a duplicate admission after the synchronous edit callback")
assert(rawequal(admissions[1].context,admissions[2].context),"manual and live share one runtime authority")
local stale=tool.writer_calls[2]
assert(stale.options.token:is_current() and not rawequal(manual.options.token,stale.options.token),
  "runtime issues a distinct operation token for each admitted request")

dialog.visible=false
tool.app_idle_observable:fire()
assert(not stale.options.token:is_current(),"closing revokes the old runtime request")
local admission_count=#admissions
builder,dialog=open_gui()
assert(#contexts==1,"reopening retains the same runtime authority")
assert(#admissions==admission_count,"reopen and draft restoration request nothing")
local target_before=popup(builder,360).value
complete(2)
assert(popup(builder,360).value==target_before,
  "old-session completion must not update the reopened destination")
phrase_popup=popup(builder,360)

local context=contexts[#contexts]
do
  local phrase_popup=popup(builder,360)
  local status=builder.views.acid_status
  local failed_a=#tool.writer_calls+1
  button(builder,"Generate / Regenerate ACID Phrase"):fire()
  assert(#tool.writer_calls==failed_a,"target A Generate was not admitted: "..tostring(admissions[#admissions].reason))
  complete(failed_a,"error","target A failure detail")
  assert(status.text:find("Couldn't update the phrase. Try again.",1,true),
    "a current target A generation failure gets actionable feedback")
  local restore=context.restore_editor_target
  function context:restore_editor_target(...)
    local restored=restore(self,...)
    restored.draft_error="injected unreadable draft"
    return restored
  end
  phrase_popup:fire(2)
  context.restore_editor_target=restore
  assert(not status.text:find("Couldn't update the phrase. Try again.",1,true),
    "switching to B clears A-specific generation feedback")
  local duplicate=context.request_duplicate
  context.request_duplicate=function()return false,"injected duplicate admission detail"end
  local writer_count=#tool.writer_calls
  builder.views.acid_pattern_duplicate:fire()
  context.request_duplicate=duplicate
  local duplicate_failure="Couldn't duplicate the phrase. Try again."
  local load_failure="Saved edits could not be loaded. Check the sequence before generating."
  assert(status.text==load_failure.."\n"..duplicate_failure and #tool.writer_calls==writer_count,
    "a rejected duplicate publishes its own failure without writing or raw details")
  local succeeded_b=#tool.writer_calls+1
  button(builder,"Generate / Regenerate ACID Phrase"):fire()
  assert(#tool.writer_calls==succeeded_b,"target B Generate was not admitted")
  complete(succeeded_b,"approximate")
  assert(not status.text:find("Couldn't update the phrase. Try again.",1,true) and
    require("model.sequencer").same_source(context:editor_state().source,
      tool.writer_calls[succeeded_b].request.source),
    "verified target B success adopts B's source and clears A's generation failure")
  assert(status.text==load_failure.."\n"..duplicate_failure..
    "\nPhrase updated with a musical approximation.",
    "approximation warning coexists with unresolved draft-load and Duplicate failures")
  phrase_popup:fire(1)
end
do
  local phrase_popup=popup(builder,360)
  local status=builder.views.acid_status
  local writer_count=#tool.writer_calls
  button(builder,"Generate / Regenerate ACID Phrase"):fire()
  local stale_success=#tool.writer_calls
  assert(stale_success==writer_count+1 and
    tool.writer_calls[stale_success].request.phrase==phrase_one)
  phrase_popup:fire(2)
  builder.views.acid_clipboard_paste:fire()
  assert(status.text:find("Copy a scope before pasting.",1,true),
    "fixture creates B-scoped feedback before stale success: "..status.text)
  local b_source=assert(require("model.sequencer").copy_source(context:editor_state().source))
  local b_revision=context:revision_state().edit_revision
  local b_feedback=status.text
  complete(stale_success,"committed")
  assert(context:target_projection().phrase==phrase_two and
    context:revision_state().edit_revision==b_revision and
    require("model.sequencer").same_source(b_source,context:editor_state().source) and
    status.text==b_feedback and not status.text:find("Phrase updated.",1,true),
    "stale success for A cannot change B source, history or feedback")
  phrase_popup:fire(1)
  button(builder,"Generate / Regenerate ACID Phrase"):fire()
  local stale_failure=#tool.writer_calls
  assert(stale_failure==stale_success+1 and
    tool.writer_calls[stale_failure].request.phrase==phrase_one)
  phrase_popup:fire(2)
  builder.views.acid_clipboard_paste:fire()
  b_feedback=status.text
  complete(stale_failure,"error","stale A failure detail")
  assert(status.text==b_feedback and not status.text:find("stale A failure detail",1,true) and
    context:target_projection().phrase==phrase_two,
    "stale failure for A cannot replace feedback for B")
  phrase_popup:fire(1)
end

fail_next_edit_transition=true
pitch_key(builder,3):fire()
local status_view=builder.views.acid_status
assert(not fail_next_edit_transition and status_view and
  status_view.text=="Your latest edits could not be saved with the song.",
  "a failed editor transition must not report a saved draft: "..tostring(status_view and status_view.text))
fail_next_edit_transition=true
button(builder,"Undo"):fire()
local timing=builder.views.acid_timing
timing:fire(timing.value==1 and 2 or 1)
assert(not builder.views.acid_status.text:find(
  "Edits to the previous phrase could not be saved with the song.",1,true),
  "a successful save to the matching target clears its prior save warning")

fail_next_edit_transition=true
pitch_key(builder,4):fire()
assert(rawequal(context:target_projection().phrase,phrase_one),"save-warning fixture starts on A")
assert(builder.views.acid_status.text:find(
  "Your latest edits could not be saved with the song.",1,true),
  "the failed save fixture sets A's save issue")
do
  local status=builder.views.acid_status
  local one_issue_height=status.height
  local save_count,writer_count=draft_save_attempts,#tool.writer_calls
  builder.views.acid_clipboard_paste:fire()
  assert(status.text:find("Your latest edits could not be saved with the song.\nCopy a scope before pasting.",1,true) and
    status.height>one_issue_height and status.visible and draft_save_attempts==save_count and
    #tool.writer_calls==writer_count,
    "save precedes input feedback and both issues receive space without saving or writing")
  builder.views.acid_clipboard_copy:fire()
  assert(status.text=="Your latest edits could not be saved with the song." and status.height==one_issue_height,
    "successful Copy clears its input error and restores feedback height without hiding the save failure")
end
phrase_popup:fire(2)
assert(rawequal(context:target_projection().phrase,phrase_two),"save-warning fixture switched from A to B")
assert(builder.views.acid_status.text:find(
  "Edits to the previous phrase could not be saved with the song.",1,true),
  "switching away preserves A's failed save as a previous-target warning: "..builder.views.acid_status.text)
timing:fire(timing.value==1 and 2 or 1)
assert(builder.views.acid_status.text:find(
  "Edits to the previous phrase could not be saved with the song.",1,true),
  "saving target B cannot clear A's save warning")
phrase_popup:fire(1)
assert(builder.views.acid_status.text:find(
  "Edits to the previous phrase could not be saved with the song.",1,true),
  "returning to A does not clear its warning before a verified save")
timing:fire(timing.value==1 and 2 or 1)
assert(not builder.views.acid_status.text:find(
  "Edits to the previous phrase could not be saved with the song.",1,true),
  "a verified save to matching target A clears its previous-target warning")

do
  local restore=context.restore_editor_target
  local injected_load_error=false
  function context:restore_editor_target(...)
    local restored=restore(self,...)
    if not injected_load_error then
      injected_load_error=true
      restored.draft_error="injected unreadable draft"
    end
    return restored
  end
  local save_count,writer_count=draft_save_attempts,#tool.writer_calls
  phrase_popup:fire(2)
  assert(builder.views.acid_status.text=="Saved edits could not be loaded. Check the sequence before generating.",
    "unreadable draft produces a target-specific load error without raw details")
  phrase_popup:fire(1)
  context.restore_editor_target=restore
  assert(builder.views.acid_status.text=="" and draft_save_attempts==save_count and
    #tool.writer_calls==writer_count,
    "leaving an unreadable draft clears its load issue without inventing a failed save or writing")
end

local original=instrument.phrases[1]
local writer_count=#tool.writer_calls
instrument.phrases[1]={id=91,name="replacement",foreign=true}
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==writer_count,"removed same-index target must reject without append")
instrument.phrases[1]=original
popup(builder,290):fire(2)
popup(builder,360):fire(2)
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==writer_count,"foreign manual destination must reject without append")
live_control(builder):fire(true)
pitch_key(builder,3):fire()
assert(#tool.writer_calls==writer_count,"foreign Live Edit must reject without append")

local new_request_base=#tool.writer_calls
popup(builder,360):fire(3)
button(builder,"Generate / Regenerate ACID Phrase"):fire()
local create_request=#tool.writer_calls
assert(create_request==new_request_base+1 and tool.writer_calls[create_request].target==3,
  "only explicitly selected New authorizes append")
assert(tool.writer_calls[create_request].options.token:is_current(),"New uses runtime-issued authorization")
complete(create_request,"error","new target failure")
assert(builder.views.acid_status.text:find("Couldn't update the phrase. Try again.",1,true),
  "a failed New Phrase generation is scoped to the New target")
local create_retry=#tool.writer_calls+1
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(create_retry==#tool.writer_calls and tool.writer_calls[create_retry].target==3,
  "retry retains the selected New destination")
local created_phrase={id=31,name="ACID created phrase"}
tool.writer_calls[create_retry].options.phrase_mutation(function()
  other_instrument.phrases[#other_instrument.phrases+1]=created_phrase
  return created_phrase
end)
complete(create_retry,"committed",created_phrase)
assert(context:target_projection().phrase==created_phrase and popup(builder,360).value==3 and
  require("model.sequencer").same_source(context:editor_state().source,
    tool.writer_calls[create_retry].request.source) and
  not builder.views.acid_status.text:find("Couldn't update the phrase. Try again.",1,true) and
  builder.views.acid_status.text:find(
    "Edits to the previous phrase could not be saved with the song.",1,true) and
  not builder.views.acid_status.text:find("Phrase updated.",1,true),
  "verified New Phrase success adopts the target and clears its old feedback: "..
    builder.views.acid_status.text.." / "..tostring(context:target_projection().phrase==created_phrase))
live_control(builder):fire(false)
popup(builder,290):fire(1)
popup(builder,360):fire(1)
local stale_request=#tool.writer_calls+1
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==stale_request)
pitch_key(builder,5):fire()
local dirty_source=assert(require("model.sequencer").copy_source(context:editor_state().source))
assert(not tool.writer_calls[stale_request].options.token:is_current(),"real edits revoke a prior manual request")
complete(stale_request)
assert(require("model.sequencer").same_source(dirty_source,context:editor_state().source) and
  require("runtime.draft_cache").get(song,instrument,original),
  "same-session stale completion preserves current widgets and newer draft")

do
  live_control(builder):fire(true)
  fail_draft_persistence=true
  sync_next_result="committed"
  preserve_target_on_sync_success=true
  local writer_count,admission_count=#tool.writer_calls,#admissions
  local save_count=draft_save_attempts
  local edit_revision=context:revision_state().edit_revision
  local source_before_edit=assert(require("model.sequencer").copy_source(context:editor_state().source))
  pitch_key(builder,6):fire()
  preserve_target_on_sync_success=false
  fail_draft_persistence=false
  local completed=tool.writer_calls[#tool.writer_calls]
  local feedback=builder.views.acid_status.text
  assert(#tool.writer_calls==writer_count+1 and #admissions==admission_count+1 and
    draft_save_attempts==save_count+1 and completed.completed and active_request==nil,
    "failed draft persistence is followed by exactly one synchronous Live Edit write")
  assert(context:revision_state().edit_revision>edit_revision and
    require("model.sequencer").same_source(completed.request.source,context:editor_state().source),
    "accepted source and history remain aligned after the output write")
  assert(feedback:find("Your latest edits could not be saved with the song.",1,true) and
    not feedback:find("Phrase updated.",1,true) and not feedback:find("Draft saved.",1,true),
    "generation success cannot erase or contradict the matching save failure: "..feedback)
  live_control(builder):fire(false)
  button(builder,"Undo"):fire()
  assert(require("model.sequencer").same_source(context:editor_state().source,source_before_edit),
    "the synchronously written edit remains in GUI history and Undo restores its prior source")
end

popup(builder,360):fire(#popup(builder,360).items)
local blocker_request=#tool.writer_calls+1
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==blocker_request,"New destination admits blocker fixture request")
assert(context:record_blocker(tool.writer_calls[blocker_request].options.token,{reason="fixture recovery evidence"}))
complete(blocker_request,"error")
assert(context:integrity_state().blocked)
dialog.visible=false
tool.app_idle_observable:fire()
local restore_blocked=context.restore_editor_target
function context:restore_editor_target(...)
  local restored=restore_blocked(self,...)
  restored.draft_error="injected blocked draft load detail"
  return restored
end
builder,dialog=open_gui()
context.restore_editor_target=restore_blocked
assert(#contexts==1 and context:integrity_state().blocked,
  "closing and reopening cannot clear a song integrity blocker")
assert(builder.views.acid_status.text:find("ACID cannot safely update this song.",1,true) and
  not builder.views.acid_status.text:find("Check the sequence before generating.",1,true),
  "a draft-load failure cannot conceal the current song blocker or offer generation as a remedy")
local blocked_count=#tool.writer_calls
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==blocked_count,"a reopened integrity blocker still rejects generation")

-- A new document warns about volatile drafts from the tracked old song, and a
-- closed dialog's checkbox is not touched by the released runtime.
fail_draft_persistence=true
pitch_key(builder,7):fire()
assert(require("runtime.draft_cache").has_volatile(song),
  "volatile draft fixture was not created")
local warnings_before=#warnings
local closed_checkbox=live_control(builder)
dialog.visible=false
tool.app_idle_observable:fire()
local writes=0
setmetatable(closed_checkbox,{__newindex=function(node,key,value)
  if key=="value" then writes=writes+1 end
  rawset(node,key,value)
end})
tool.app_new_document_observable:fire()
assert(warnings_before+1==#warnings and warnings[#warnings]:find("could not be saved",1,true),
  "new document did not warn about volatile old-song drafts")
assert(writes==0,"released runtime wrote a stale dialog checkbox")
print("acid GUI runtime admission specs passed")
