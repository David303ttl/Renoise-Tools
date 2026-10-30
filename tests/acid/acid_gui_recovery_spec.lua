dofile("tests/bootstrap.lua")("acid")

local function observable()
  local handlers={}
  return {
    add_notifier=function(_,handler) handlers[handler]=true end,
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
  local function construct(kind,properties)
    local node={kind=kind,views={},notifiers={}}
    for key,value in pairs(properties or {}) do
      if type(key)=="number" then node.views[#node.views+1]=value
      else node[key]=value end
    end
    if node.id then builder.views[node.id]=node end
    builder.nodes[#builder.nodes+1]=node
    function node:add_child(child) self.views[#self.views+1]=child end
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
  app_idle_observable=observable(),writer_calls={}}

local phrase_one={id=11,name="Owned one"}
local phrase_two={id=12,name="Owned two"}
local instrument={name="Target",phrases={phrase_one,phrase_two},phrase_program=1,
  name_observable=observable(),phrases_observable=observable(),
  samples={},sample_modulation_sets={},sample_device_chains={}}
local other_owned={id=21,name="Other owned"}
local other_foreign={id=22,name="Other foreign",foreign=true}
local other_instrument={name="Other target",phrases={other_owned,other_foreign},
  phrase_program=1,samples={},sample_modulation_sets={},sample_device_chains={}}
local song={selected_instrument_index=1,selected_instrument=instrument,
  instruments_observable=observable(),selected_instrument_observable=observable(),
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

local persisted_drafts={}
local fail_draft_persistence=false
package.loaded["renoise.pattern_store"]={load=function(_,instrument,phrase)
  local source=require("model.sequencer").new_pattern(16)
  return source,"repeat",phrase.id==11 and 2 or phrase.id==12 and 48 or 0
end,
  write_draft=function(song,instrument,phrase,pattern,policy,pb_range)
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
  clear_draft=function(song,instrument,phrase)
    local index;for i,candidate in ipairs(song.instruments) do if rawequal(candidate,instrument) then index=i;break end end
    local phrase_id=phrase and phrase.id or 0
    persisted_drafts[index..":"..phrase_id]=nil
    return true
  end,
  has_drafts=function()return next(persisted_drafts)~=nil end}
package.loaded["renoise.phrase_ownership"]={
  status=function(phrase)return phrase.foreign and "foreign" or "owned" end,
  id=function(phrase)return phrase.id end
}
package.loaded["renoise.selection_context"]={inspect_selection=function()return "selection" end}
package.loaded["renoise.sampler_audit"]={describe=function()return "sampler" end}
local render_callbacks={}
local active_request
local function terminal_result(call,status,message)
  local success=status=="committed" or status=="approximate"
  local phrase=call.phrase or call.request.phrase
  local result={kind=success and "success" or "failure",status=status or (success and "committed" or "failed"),
    verified=success,token=call.request.token,epoch=call.request.epoch,request=call.request,
    phrase=success and phrase or nil,reason=success and nil or (message or "invalidated"),
    message=message or "invalidated"}
  if success then
    if call.request.kind=="regenerate" then
      result.baseline=call.request.baseline
    else
      local ok,candidate=pcall(function()
        return require("writers.phrase_validator").classify(call.request.song,
          call.request.instrument,phrase,{},{},{})
      end)
      if ok and candidate then
        result.baseline={id=phrase.id,source=candidate.source,settings=candidate.settings,
          snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs}
      else
        result.baseline={id=phrase and phrase.id,source=call.request.source,
          settings={output_policy=call.request.output_policy,pb_range=call.request.pb_range},
          snapshot={content=0},planning_inputs={}}
      end
    end
  end
  return result
end
local function start(kind,request,done)
  local call={kind=kind,request=request,token=request.token,source=request.source,
    pb_range=request.pb_range}
  call.pattern=request.source
  for index,instrument in ipairs(request.song.instruments) do
    if rawequal(instrument,request.instrument) then call.instrument_index=index;break end
  end
  if kind=="create" then
    call.target=#request.instrument.phrases+1
  else
    for index,phrase in ipairs(request.instrument.phrases) do
      if rawequal(phrase,request.phrase) then call.target=index;break end
    end
  end
  call.options={token=request.token,pb_range=request.pb_range,
    phrase_mutation=function(action)
      local values={n=0}
      local function packed(...) return {n=select("#",...),...} end
      local ok,out=pcall(function() return packed(request:mutate(request.token,action)) end)
      if not ok then error(out,0) end
      if kind=="create" and out.n>0 and type(out[1])=="table" then call.phrase=out[1] end
      return (unpack or table.unpack)(out,1,out.n)
    end}
  tool.writer_calls[#tool.writer_calls+1]=call
  active_request=request
  render_callbacks[#render_callbacks+1]=function(result)
    active_request=nil
    done(result)
    tool.app_idle_observable:fire()
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

local editor_module=require("model.editor_state")
local force_diagnostic=false
package.loaded["model.editor_state"]={
  MAX_PAGES=editor_module.MAX_PAGES,
  project=function(pattern)
    if force_diagnostic then
      return {error={step=3,pitch_index=2,message="TIME step 03: test diagnostic."},
        used={},mapping={},repeat_mapping={},note_count=0}
    end
    return editor_module.project(pattern)
  end,
  new_history=editor_module.new_history,
  index_on_page=editor_module.index_on_page,
  page_for=editor_module.page_for,
  step_text=editor_module.step_text
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
local function popup(builder,width)
  for _,node in ipairs(builder.nodes) do
    if node.kind=="popup" and node.width==width then return node end
  end
  error("missing popup width "..width)
end
local function pb_range_popup(builder)
  assert(builder.views.acid_pb_range,"PB Range popup was not created")
  return builder.views.acid_pb_range
end

local builder,dialog=open_gui()
local phrase_choice=popup(builder,360)
assert(pb_range_popup(builder).value==2,"the selected phrase restores its stored PB Range")
builder.views.acid_program_key_popup:fire(2)
phrase_choice:fire(2)
assert(pb_range_popup(builder).value==5,"switching phrases restores that phrase's PB Range")
builder.views.acid_program_key_popup:fire(3)
phrase_choice:fire(1)
assert(builder.views.acid_program_key_popup.value==2,
  "switching phrases restores the unsaved draft for phrase one")
assert(pb_range_popup(builder).value==2,
  "switching phrases restores the unsaved PB Range draft for phrase one")
phrase_choice:fire(2)
assert(builder.views.acid_program_key_popup.value==3,
  "switching back restores the separate phrase two draft")

dialog.visible=false
tool.app_idle_observable:fire()
builder,dialog=open_gui()
phrase_choice=popup(builder,360)
assert(builder.views.acid_program_key_popup.value==2,
  "closing and reopening the editor recovers the phrase one draft")
assert(pb_range_popup(builder).value==2,
  "closing and reopening the editor recovers the phrase one's PB Range")
local recovered_status
for _,node in ipairs(builder.nodes) do
  if node.kind=="multiline_textfield" then recovered_status=node end
end
assert(recovered_status.text:find("Recovered saved draft",1,true),
  "draft recovery reports song persistence")
tool.app_release_document_observable:fire()
assert(#warnings==0,"song-persistent drafts do not show a loss warning")
dialog.visible=false
builder,dialog=open_gui()
phrase_choice=popup(builder,360)
for _,node in ipairs(builder.nodes) do
  if node.kind=="multiline_textfield" then recovered_status=node end
end
pb_range_popup(builder):fire(1)
button(builder,"Undo"):fire()
assert(pb_range_popup(builder).value==2,"Undo restores the previous PB Range")
button(builder,"Redo"):fire()
assert(pb_range_popup(builder).value==1,"Redo restores the changed PB Range")
pb_range_popup(builder):fire(3)
force_diagnostic=true
song.selected_phrase_observable:fire()
builder.views.acid_editor_view:fire(2)
local go_to_error=button(builder,"Go to source error")
assert(go_to_error.active,"invalid source exposes diagnostic navigation: "..builder.views.acid_source_diagnostic.text)
go_to_error:fire()
assert(builder.views.acid_program_time_position.value==3 and
  builder.views.acid_program_pitch_position.value==2,
  "diagnostic navigation selects the failing TIME and PITCH positions")
force_diagnostic=false
song.selected_phrase_observable:fire()
builder.views.acid_editor_view:fire(1)
fail_draft_persistence=true
builder.views.acid_program_key_popup:fire(6)
assert(recovered_status.text=="DRAFT SAVE ERROR: session recovery only: test persistence failure",
  recovered_status.text)
tool.app_release_document_observable:fire()
assert(#warnings==1 and warnings[1]:find("could not be saved",1,true),
  "volatile draft persistence failure warns before song close")
fail_draft_persistence=false
dialog.visible=false
builder,dialog=open_gui()
phrase_choice=popup(builder,360)
builder.views.acid_program_pitch_position:fire(2)

local live_checkbox
for _,node in ipairs(builder.nodes) do
  if node.kind=="checkbox" and node.value==false then live_checkbox=node end
end
assert(live_checkbox,"Live Edit checkbox was not created")
live_checkbox:fire(true)
assert(#render_callbacks==0,"arming Live Edit does not write")
builder.views.acid_program_key_popup:fire(5)
assert(builder.views.acid_live_edit_state.text:find("RENDERING",1,true),
  "editing the armed source starts a render")
assert(#render_callbacks==1 and tool.writer_calls[1].options.token,
  "Live Edit passes a cancellation token to the writer")
assert(tool.writer_calls[1].options.pb_range==12,
  "Live Edit passes the selected PB Range to the renderer")
local first_failure=terminal_result(tool.writer_calls[1],"error","temporary render failure")
first_failure.diagnostics={"temporary render failure"}
render_callbacks[1](first_failure)
assert(live_checkbox.value,"a recoverable writer error leaves Live Edit armed")
assert(builder.views.acid_live_edit_state.text:find("ERROR",1,true),
  "last Live Edit failure remains visible")
local status
for _,node in ipairs(builder.nodes) do
  if node.kind=="multiline_textfield" then status=node end
end
assert(status.text=="LIVE EDIT ERROR: temporary render failure",status.text)
builder.views.acid_program_key_popup:fire(6)
assert(#render_callbacks==2 and tool.writer_calls[2].pattern.pitch_events[2].key==5,
  "a source edit immediately retries the armed Live Edit: callbacks="..
    #render_callbacks.." calls="..#tool.writer_calls.." key="..
    tostring(tool.writer_calls[2] and tool.writer_calls[2].pattern.pitch_events[2].key))
builder.views.acid_program_key_popup:fire(7)
assert(#render_callbacks==2 and #tool.writer_calls==2,
  "rapid edits coalesce while one render is active")
local long_diagnostic=string.rep("TIME step 05: SLIDE approximated: bend range exceeded; ",40)
local stale_failure=terminal_result(tool.writer_calls[2],"error",long_diagnostic)
stale_failure.diagnostics={long_diagnostic}
render_callbacks[2](stale_failure)
assert(#render_callbacks==3 and tool.writer_calls[3].pattern.pitch_events[2].key==6,
  "the in-flight follow-up renders the newest source immediately: P1="..
    tostring(tool.writer_calls[3].pattern.pitch_events[1].key).." P2="..
    tostring(tool.writer_calls[3].pattern.pitch_events[2].key))
assert(not status.text:find(long_diagnostic,1,true), "a superseded request cannot replace current details with a stale error")
assert(not builder.views.acid_live_edit_state.text:find(long_diagnostic,1,true),
  "the live status does not duplicate long diagnostics into an auto-sizing text view")
local approximate_result=terminal_result(tool.writer_calls[3],"approximate","recovered with approximation")
approximate_result.diagnostics={"slide approximated"}
render_callbacks[3](approximate_result)
assert(live_checkbox.value,"a recoverable writer error leaves Live Edit armed")
assert(status.text:find("LIVE EDIT APPROXIMATE: recovered with approximation",1,true),status.text)
assert(builder.views.acid_live_edit_state.text:find("APPROXIMATE",1,true),
  "draft cleanup failure does not change a successful render status")


phrase_choice:fire(2)
assert(#render_callbacks==3,"destination navigation does not write")
builder.views.acid_program_key_popup:fire(2)
assert(live_checkbox.value and #render_callbacks==4,
  "editing a destination with a recovered draft resumes Live Edit")
assert(tool.writer_calls[4].options.pb_range==48,
  "Live Edit restores and passes the newly selected phrase's PB Range")
render_callbacks[4](terminal_result(tool.writer_calls[4],"committed","owned phrase rebound"))
local target_popup=popup(builder,290)
target_popup:fire(2)
phrase_choice:fire(1)
assert(#render_callbacks==4,"instrument navigation does not write")
builder.views.acid_program_key_popup:fire(2)
assert(live_checkbox.value and #render_callbacks==5,
  "explicit instrument selection rebinds Live Edit to its selected owned phrase")
render_callbacks[5](terminal_result(tool.writer_calls[5],"committed","instrument rebound"))
phrase_choice:fire(3)
assert(#render_callbacks==5,"new phrase navigation does not write")
builder.views.acid_program_key_popup:fire(2)
assert(live_checkbox.value and #render_callbacks==6 and tool.writer_calls[6].target==3,
  "editing NEW PHRASE starts an append render: "..#render_callbacks.." / "..tostring(tool.writer_calls[#tool.writer_calls].target).." / "..status.text)
local explicit_append={id=23,name="ACID explicit append"}
tool.writer_calls[6].options.phrase_mutation(function()
  other_instrument.phrases[3]=explicit_append
  return explicit_append
end)
builder.views.acid_program_key_popup:fire(9)
render_callbacks[6](terminal_result(tool.writer_calls[6],"committed","initial append"))
builder.views.acid_program_key_popup:fire(9)

assert(phrase_choice.value==3 and #render_callbacks==7 and tool.writer_calls[7].target==3,
  "an edit after accepted create regenerates the returned destination")
assert(tool.writer_calls[7].pattern.pitch_events[1].key==8,
  "the follow-up regeneration uses the newest source")
render_callbacks[7](terminal_result(tool.writer_calls[7],"committed","explicit phrase updated"))
phrase_choice:fire(2)
assert(#render_callbacks==7,"foreign phrase navigation does not write")
builder.views.acid_program_key_popup:fire(2)
assert(live_checkbox.value and #render_callbacks==7,
  "foreign phrase edits reject without overwriting or appending")
assert(other_instrument.phrases[2]==other_foreign)
phrase_choice:fire(4)
builder.views.acid_program_key_popup:fire(2)
assert(#render_callbacks==8 and tool.writer_calls[8].target==4,
  "only explicit New selection allows creating a separate phrase")
local separate_owned={id=24,name="ACID explicit New phrase"}
tool.writer_calls[8].options.phrase_mutation(function()
  other_instrument.phrases[4]=separate_owned
  return separate_owned
end)
render_callbacks[8](terminal_result(tool.writer_calls[8],"committed","foreign redirected"))
assert(phrase_choice.value==4,"successful explicit create binds the returned phrase")
builder.views.acid_program_key_popup:fire(8)
assert(#render_callbacks==9 and tool.writer_calls[9].target==4,
  "the next edit regenerates the explicit created phrase")
render_callbacks[9](terminal_result(tool.writer_calls[9],"committed","separate phrase updated"))
assert(#other_instrument.phrases==4 and other_instrument.phrases[2]==other_foreign,
  "foreign phrase stays in place and repeated edits do not append duplicates")
assert(live_checkbox.value and status.text=="LIVE EDIT COMMITTED: separate phrase updated",status.text)
builder.views.acid_program_key_popup:fire(8)
assert(#render_callbacks==9,"an unchanged PITCH value does not render")
builder.views.acid_program_key_popup:fire(9)
other_instrument.phrases[4].foreign=true
render_callbacks[10](terminal_result(tool.writer_calls[10],"suspended",
  "target phrase changed during generation"))
assert(#render_callbacks==10,
  "a target ownership change during rendering cannot redirect to append")
assert(other_instrument.phrases[4]==separate_owned)
phrase_choice:fire(5)
builder.views.acid_program_key_popup:fire(3)
assert(#render_callbacks==11 and tool.writer_calls[11].target==5,
  "a fresh edit on explicitly selected New can create after blocked target rejection")
local safety_append={id=25,name="ACID explicit recovery"}
tool.writer_calls[11].options.phrase_mutation(function()
  other_instrument.phrases[5]=safety_append
  return safety_append
end)
render_callbacks[11](terminal_result(tool.writer_calls[11],"committed","safety append committed"))
assert(phrase_choice.value==5,"explicit recovery create binds the returned phrase")
builder.views.acid_program_key_popup:fire(10)
assert(#render_callbacks==12 and tool.writer_calls[12].target==5,
  "edits after explicit recovery regenerate the created phrase")
render_callbacks[12](terminal_result(tool.writer_calls[12],"committed","safety phrase updated"))
builder.views.acid_program_key_popup:fire(8)
render_callbacks[13](terminal_result(tool.writer_calls[13],"error",long_diagnostic))
assert(status.text:find(long_diagnostic,1,true),
  "the bounded details field retains a current request complete diagnostic")
local live_state=builder.views.acid_live_edit_state.text
local live_state_view=builder.views.acid_live_edit_state
assert(live_state_view.kind=="multiline_text" and live_state_view.width==820 and
  live_state_view.height==48,
  "live status uses a fixed-size wrapping view so long diagnostics cannot widen the dialog")
assert(live_state:find("LIVE EDIT ERROR",1,true) and
  live_state:find("LAST COMMIT: COMMITTED | Other target / 05 ACID explicit recovery",1,true) and
  not live_state:find("safety phrase updated",1,true),
  "a later render error preserves a concise summary of the prior successful commit")

local before_reset=#render_callbacks
builder.views.acid_program_key_popup:fire(3)
assert(#render_callbacks==before_reset+1,"a source edit starts the held render")
local held=render_callbacks[#render_callbacks]
local held_request=tool.writer_calls[#tool.writer_calls]
builder.views.acid_program_key_popup:fire(4)
button(builder,"Reset Source"):fire()
assert(not held_request.options.token:is_current(),"reset invalidates the held render")
held(terminal_result(held_request,"suspended","source reset"))
assert(#render_callbacks==before_reset+1 and live_checkbox.value,
  "reset discards pending edits without rendering and keeps Live Edit armed")
builder.views.acid_program_key_popup:fire(2)
assert(#render_callbacks==before_reset+2,"the next real edit renders the reset source")
assert(tool.writer_calls[#tool.writer_calls].pattern.pitch_events[1].key==1)

render_callbacks[#render_callbacks](terminal_result(tool.writer_calls[#tool.writer_calls],"committed","last edit settled"))
live_checkbox:fire(false)
local draft_cache=require("runtime.draft_cache")
local recovered_source=require("model.sequencer").new_pattern(8)
recovered_source.pitch_events[1]=require("model.sequencer").new_pitch(10,0,true,false)
assert(draft_cache.put(song,instrument,phrase_one,recovered_source,"play_once",24))
local recovery_token=assert(draft_cache.detach(song,instrument,phrase_one,"Native phrase changed"))
target_popup:fire(1)
phrase_choice:fire(#phrase_choice.items)
builder.views.acid_program_key_popup:fire(4)
local count_before_copy=#render_callbacks
live_checkbox:fire(true)
local recovery_popup=builder.views.acid_recovery_choice
local recovery_rows=draft_cache.list(song)
local recovery_index
for index,entry in ipairs(recovery_rows) do
  if entry.token==recovery_token then recovery_index=index end
end
assert(recovery_index,"detached draft is listed")
recovery_popup:fire(recovery_index)
assert(builder.views.acid_recovery_detail.text:find("Native phrase changed",1,true))
builder.views.acid_recovery_copy:fire()
assert(#render_callbacks==count_before_copy,"armed recovery never invokes the writer")
assert(phrase_choice.value==#phrase_choice.items,"recovery binds explicit New")
assert(builder.views.acid_program_key_popup.value==11 and pb_range_popup(builder).value==4,
  "recovery projects source and bend range")
local source,policy,pb=draft_cache.get(song,instrument,nil)
assert(source.pitch_events[1].key==10 and policy=="play_once" and pb==24)
local found_original,found_scratch=false,false
for _,entry in ipairs(draft_cache.list(song)) do
  found_original=found_original or entry.token==recovery_token
  found_scratch=found_scratch or entry.pattern.pitch_events[1].key==3
end
assert(found_original and found_scratch,"copy retains original and occupied outgoing scratch")
builder.views.acid_recovery_discard:fire()
for _,entry in ipairs(draft_cache.list(song)) do assert(entry.token~=recovery_token) end
assert(#render_callbacks==count_before_copy,"discard never invokes the writer")
source=draft_cache.get(song,instrument,nil)
assert(source.pitch_events[1].key==10,"discarding recovery keeps the copied editor draft")
assert(builder.views.acid_make_independent.active==false,"unique targets cannot be rekeyed")
assert(builder.views.acid_revalidate.active==false,"unblocked songs need no revalidation")
instrument.name="Renamed target"
instrument.name_observable:fire()
tool.app_idle_observable:fire()
assert(target_popup.items[target_popup.value]:find("Renamed target",1,true),
  "native rename refreshes instrument choices")
assert(phrase_choice.value==#phrase_choice.items,"native rename preserves explicit New")
song.instruments={other_instrument,instrument}
song.selected_instrument_index=2
song.instruments_observable:fire()
tool.app_idle_observable:fire()
assert(target_popup.value==2 and target_popup.items[2]:find("Renamed target",1,true),
  "native reorder keeps the exact bound instrument")
song.instruments={instrument}
song.selected_instrument_index=1
song.instruments_observable:fire()
tool.app_idle_observable:fire()
assert(#target_popup.items==1 and target_popup.value==1,"native removal refreshes instrument choices")
assert(phrase_choice.value==#phrase_choice.items and #render_callbacks==count_before_copy,
  "native inventory notifications neither redirect New nor generate")

-- A failed explicit create must keep the selected recovery origin available;
-- only the exact copied revision consumed by a later verified create clears it.
local retry_source=require("model.sequencer").new_pattern(8)
retry_source.pitch_events[1]=require("model.sequencer").new_pitch(7,0,true,false)
assert(draft_cache.put(song,instrument,phrase_two,retry_source,"repeat",12))
local retry_origin=assert(draft_cache.detach(song,instrument,phrase_two,"Retry recovered create"))
live_checkbox:fire(true)
recovery_rows=draft_cache.list(song)
local retry_index
for index,entry in ipairs(recovery_rows) do
  if entry.token==retry_origin then retry_index=index end
end
assert(retry_index,"newly detached origin appears in the recovery chooser")
recovery_popup:fire(retry_index)
builder.views.acid_recovery_copy:fire()
assert(phrase_choice.value==#phrase_choice.items and live_checkbox.value,
  "recovery copy keeps the explicit New destination and armed state")
local before_retry=#render_callbacks
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#render_callbacks==before_retry+1 and tool.writer_calls[#tool.writer_calls].kind=="create",
  "manual Generate starts an explicit recovered create")
render_callbacks[#render_callbacks](terminal_result(tool.writer_calls[#tool.writer_calls],"error",
  "temporary recovered create failure"))
assert(phrase_choice.value==#phrase_choice.items,"failed create retains the selected New destination")
assert(recovery_popup.value==retry_index,
  "failed create keeps the exact recovery row selected")
local origin_present=false
for _,entry in ipairs(draft_cache.list(song)) do
  origin_present=origin_present or entry.token==retry_origin
end
assert(origin_present,"failed create preserves its exact selected recovery origin")
local retained_tokens={}
for _,entry in ipairs(draft_cache.list(song)) do retained_tokens[entry.token]=true end
before_retry=#render_callbacks
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#render_callbacks==before_retry+1 and tool.writer_calls[#tool.writer_calls].kind=="create",
  "the unchanged recovered draft can retry its explicit create")
local recovered_created={id=31,name="Recovered create"}
tool.writer_calls[#tool.writer_calls].options.phrase_mutation(function()
  instrument.phrases[#instrument.phrases+1]=recovered_created
  return recovered_created
end)
render_callbacks[#render_callbacks](terminal_result(tool.writer_calls[#tool.writer_calls],"committed",
  "recovered create committed"))
assert(phrase_choice.value==#phrase_choice.items-1 and
  phrase_choice.items[phrase_choice.value]:find("Recovered create",1,true),
  "successful create binds its exact returned phrase")
local remaining_tokens={}
for _,entry in ipairs(draft_cache.list(song)) do remaining_tokens[entry.token]=true end
assert(not remaining_tokens[retry_origin],"verified create clears only its exact recovery origin")
for token in pairs(retained_tokens) do
  if token~=retry_origin then
    assert(remaining_tokens[token],"successful create preserves unrelated recovery entries")
  end
end

print("ACID GUI draft recovery and typed Live Edit outcome checks passed")
