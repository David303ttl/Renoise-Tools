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

local persisted_drafts={}
local fail_draft_persistence=false
package.loaded["renoise.pattern_store"]={load=function(_,instrument,phrase)
  local source=require("model.sequencer").new_pattern(16)
  if phrase.id==12 then source.timing_mode="triplet" end
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
    result.baseline=call.request.baseline or {
      id=phrase and phrase.id,source=call.request.source,
      settings={output_policy=call.request.output_policy,pb_range=call.request.pb_range},
      snapshot={},planning_inputs=call.request.planning_inputs}
  end
  return result
end
local function start(kind,request,done)
  local call={kind=kind,request=request,token=request.token,source=request.source,
    pb_range=request.pb_range}
  call.pattern=request.source
  call.options={token=request.token,pb_range=request.pb_range,
    phrase_mutation=function(action) return request:mutate(request.token,action) end}
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
  end
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
local timing=builder.views.acid_timing
local generate=button(builder,"Generate / Regenerate ACID Phrase")
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED",builder.views.acid_source_state.text)
generate:fire()
local manual=tool.writer_calls[#tool.writer_calls]
assert(manual.pattern.timing_mode=="straight" and manual.options.token:is_current(),
  "manual generation starts with a current straight snapshot")
timing:fire(2)
assert(builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true))
assert(builder.views.acid_source_diagnostic.text:find("cycle 16/3 beats",1,true))
builder.views.acid_editor_view:fire(2)
assert(builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true))
button(builder,"Undo"):fire()
assert(timing.value==1 and builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true))
button(builder,"Redo"):fire()
assert(timing.value==2 and builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true))
assert(not manual.options.token:is_current(),
  "changing timing invalidates the pending manual render")
render_callbacks[#render_callbacks](terminal_result(manual,"suspended","invalidated"))
assert(builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true))
generate:fire()
local manual_call=tool.writer_calls[#tool.writer_calls]
render_callbacks[#render_callbacks](terminal_result(manual_call,"committed","saved"))
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED",
  "a successful current generation clears the dirty indication")
timing:fire(2)


local live_checkbox
for _,node in ipairs(builder.nodes) do
  if node.kind=="checkbox" and node.value==false then live_checkbox=node end
end
assert(live_checkbox)
live_checkbox:fire(true)
local before_live_edit=#tool.writer_calls
assert(before_live_edit==2,"arming Live Edit does not write")
builder.views.acid_program_key_popup:fire(2)
local first=tool.writer_calls[#tool.writer_calls]
assert(first.pattern.timing_mode=="triplet" and first.options.token:is_current(),
  "Live Edit starts with the current triplet snapshot")
timing:fire(1)
assert(not first.options.token:is_current(),
  "changing timing invalidates the pending Live Edit render")
render_callbacks[#render_callbacks](terminal_result(first,"suspended","invalidated"))
local second=tool.writer_calls[#tool.writer_calls]
assert(second~=first and second.pattern.timing_mode=="straight" and second.options.token:is_current(),
  "Live Edit queues the newest timing after the stale render settles")
local live_result=terminal_result(second,"committed","saved")
render_callbacks[#render_callbacks](live_result)
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED")
live_checkbox:fire(false)


local phrase_choice=popup(builder,360)
timing:fire(2)
assert(pb_range_popup(builder).value==2, "timing edits retain phrase one PB Range")
phrase_choice:fire(2)
assert(timing.value==2 and pb_range_popup(builder).value==5,
  "phrase two restores its committed timing and separate PB Range")
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED",builder.views.acid_source_state.text)
timing:fire(1)
phrase_choice:fire(1)
assert(timing.value==2 and pb_range_popup(builder).value==2,
  "switching back restores phrase one's timing draft and PB Range")
assert(builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true))
phrase_choice:fire(2)
assert(timing.value==1 and pb_range_popup(builder).value==5,
  "phrase two retains its independent timing draft")

dialog.visible=false
tool.app_idle_observable:fire()
builder,dialog=open_gui()
timing=builder.views.acid_timing
phrase_choice=popup(builder,360)
assert(timing.value==2 and pb_range_popup(builder).value==2,
  "reopening restores phrase one's saved timing draft and PB Range")
phrase_choice:fire(2)
assert(timing.value==1 and pb_range_popup(builder).value==5,
  "reopening preserves phrase two's separate timing draft")
local target_popup=popup(builder,290)
target_popup:fire(2)
assert(timing.value==1 and pb_range_popup(builder).value==1,
  "a new instrument draft starts with its own default timing and PB Range")
timing:fire(2)
target_popup:fire(1)
assert(timing.value==2 and pb_range_popup(builder).value==2,
  "returning to the first instrument restores its selected phrase draft")
target_popup:fire(2)
assert(timing.value==2 and pb_range_popup(builder).value==1,
  "the second instrument retains its own uncommitted timing")
local reopened_live
for _,node in ipairs(builder.nodes) do
  if node.kind=="checkbox" and node.value==false then reopened_live=node end
end
assert(reopened_live)
reopened_live:fire(true)
local before_append=#tool.writer_calls
builder.views.acid_program_key_popup:fire(2)
assert(#tool.writer_calls==before_append+1,"an edit requests the armed append")
local append=tool.writer_calls[#tool.writer_calls]
local append_callback=render_callbacks[#render_callbacks]
assert(append.instrument_index==2 and append.target==3 and append.pattern.timing_mode=="triplet",
  "Live Edit snapshots the new instrument's triplet draft for append")
phrase_choice:fire(2)
assert(not append.options.token:is_current(),
  "selecting a foreign phrase invalidates the pending append")
assert(other_instrument.phrases[2]==other_foreign,
  "foreign phrase remains untouched during Live Edit recovery")
append_callback(terminal_result(append,"suspended","invalidated"))
assert(#tool.writer_calls==before_append+1,"navigation does not queue an append")
builder.views.acid_program_key_popup:fire(3)
assert(#tool.writer_calls==before_append+1,
  "foreign selection never redirects its source to append")
phrase_choice:fire(3)
builder.views.acid_program_key_popup:fire(3)
local explicit_new=tool.writer_calls[#tool.writer_calls]
assert(explicit_new~=append and explicit_new.instrument_index==2 and explicit_new.target==3 and
  explicit_new.pattern.timing_mode=="triplet" and explicit_new.options.token:is_current(),
  "an explicit New selection recovers its independent triplet draft before a fresh edit")
print("GUI timing render invalidation passed")
