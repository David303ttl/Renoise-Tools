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
local fail_draft_clear=false
package.loaded["model.pattern_store"]={load=function(_,phrase)
  local source=require("model.sequencer").new_pattern(16)
  if phrase.id==12 then source.timing_mode="triplet" end
  return source,"repeat",phrase.id==11 and 2 or phrase.id==12 and 48 or 0
end,
  write_draft=function(_,index,phrase_id,name,pattern,policy,pb_range)
    if fail_draft_persistence then return nil,"test persistence failure" end
    persisted_drafts[index..":"..phrase_id]={pattern=pattern,policy=policy,
      pb_range=pb_range,name=name}
    return true
  end,
  read_draft=function(_,index,phrase_id,name)
    local item=persisted_drafts[index..":"..phrase_id]
    if not item then return nil end
    assert(item.name==name)
    return item.pattern,item.policy,item.pb_range
  end,
  clear_draft=function(_,index,phrase_id)
    if fail_draft_clear then return nil,"test cleanup failure" end
    persisted_drafts[index..":"..phrase_id]=nil
    return true
  end,
  has_drafts=function()return next(persisted_drafts)~=nil end}
package.loaded["writers.phrase_ownership"]={
  status=function(phrase)return phrase.foreign and "foreign" or "owned" end,
  id=function(phrase)return phrase.id end
}
package.loaded["renoise.selection_context"]={inspect_selection=function()return "selection" end}
package.loaded["renoise.sampler_audit"]={describe=function()return "sampler" end}
local render_callbacks={}
package.loaded["writers.phrase_writer"]={
  generate=function(instrument_index,callback,pattern,target,options)
    tool.writer_calls[#tool.writer_calls+1]={instrument_index=instrument_index,
      target=target,options=options,pattern=pattern}
    render_callbacks[#render_callbacks+1]=callback
    return true
  end,
  cancel=function()return true end
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
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED")
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
render_callbacks[#render_callbacks]({kind="complete",status="suspended",message="invalidated"})
assert(builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true))
fail_draft_clear=true
generate:fire()
local manual_result={kind="complete",status="committed",message="saved",target={phrase_index=1}}
render_callbacks[#render_callbacks](manual_result)
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED; DRAFT RECOVERY PENDING",
  "manual commit reports retained draft when cleanup fails")
assert(persisted_drafts["1:11"], "failed cleanup must retain the draft")
assert(manual_result.draft_warning:find("test cleanup failure",1,true))
local recovery_choice=popup(builder,360)
recovery_choice:fire(2)
recovery_choice:fire(1)
assert(builder.views.acid_source_state.text:find("SOURCE DIRTY",1,true) and timing.value==2,
  "reselecting the phrase recovers the retained draft")
fail_draft_clear=false
generate:fire()
render_callbacks[#render_callbacks]({kind="complete",status="committed",message="saved",
  target={phrase_index=1}})
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED",
  "only a successful current generation clears the dirty indication")
timing:fire(2)

local live_checkbox
for _,node in ipairs(builder.nodes) do
  if node.kind=="checkbox" and node.value==false then live_checkbox=node end
end
assert(live_checkbox)
live_checkbox:fire(true)
local first=tool.writer_calls[#tool.writer_calls]
assert(first.pattern.timing_mode=="triplet" and first.options.token:is_current(),
  "Live Edit starts with the current triplet snapshot")
timing:fire(1)
assert(not first.options.token:is_current(),
  "changing timing invalidates the pending Live Edit render")
render_callbacks[#render_callbacks]({kind="complete",status="suspended",message="invalidated"})
local second=tool.writer_calls[#tool.writer_calls]
assert(second~=first and second.pattern.timing_mode=="straight" and second.options.token:is_current(),
  "Live Edit queues the newest timing after the stale render settles")
fail_draft_clear=true
local live_result={kind="complete",status="committed",message="saved",target={phrase_index=1}}
render_callbacks[#render_callbacks](live_result)
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED; DRAFT RECOVERY PENDING",
  "Live Edit commit reports retained draft when cleanup fails")
assert(persisted_drafts["1:11"], "Live Edit cleanup failure must retain the draft")
assert(live_result.draft_warning:find("test cleanup failure",1,true))
fail_draft_clear=false
live_checkbox:fire(false)

local phrase_choice=popup(builder,360)
timing:fire(2)
assert(pb_range_popup(builder).value==2, "timing edits retain phrase one PB Range")
phrase_choice:fire(2)
assert(timing.value==2 and pb_range_popup(builder).value==5,
  "phrase two restores its committed timing and separate PB Range")
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED")
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
local append=tool.writer_calls[#tool.writer_calls]
local append_callback=render_callbacks[#render_callbacks]
assert(append.instrument_index==2 and append.target==3 and append.pattern.timing_mode=="triplet",
  "Live Edit snapshots the new instrument's triplet draft for append")
phrase_choice:fire(2)
assert(not append.options.token:is_current(),
  "selecting a foreign phrase invalidates the pending append")
assert(other_instrument.phrases[2]==other_foreign,
  "foreign phrase remains untouched during Live Edit recovery")
append_callback({kind="complete",status="suspended",message="invalidated"})
local redirected=tool.writer_calls[#tool.writer_calls]
assert(redirected~=append and redirected.instrument_index==2 and redirected.target==3 and
  redirected.pattern.timing_mode=="triplet" and redirected.options.token:is_current(),
  "foreign selection redirects the separate new-phrase draft with its timing intact: "..
  tostring(redirected==append).." / "..tostring(redirected.instrument_index).." / "..
  tostring(redirected.target).." / "..tostring(redirected.pattern.timing_mode).." / "..
  tostring(redirected.options.token:is_current()))
print("GUI timing render invalidation passed")
