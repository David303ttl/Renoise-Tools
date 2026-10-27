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
  app_idle_observable=observable(),
  timers={},writer_calls={}}
function tool:add_timer(handler,delay)
  assert(delay==350)
  self.timers[handler]=true
end
function tool:remove_timer(handler) self.timers[handler]=nil end
function tool:fire_timer()
  local handler=next(self.timers)
  assert(handler,"no scheduled Live Edit action")
  self.timers[handler]=nil
  handler()
end

local phrase_one={id=11,name="Owned one"}
local phrase_two={id=12,name="Owned two"}
local instrument={name="Target",phrases={phrase_one,phrase_two},phrase_program=1,
  samples={},sample_modulation_sets={},sample_device_chains={}}
local other_owned={id=21,name="Other owned"}
local other_foreign={id=22,name="Other foreign",foreign=true}
local other_instrument={name="Other target",phrases={other_owned,other_foreign},
  phrase_program=1,samples={},sample_modulation_sets={},sample_device_chains={}}
local song={selected_instrument_index=1,instruments={instrument,other_instrument}}
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
package.loaded["model.pattern_store"]={load=function()
  local source=require("model.sequencer").new_pattern(16)
  return source,"repeat"
end,
  write_draft=function(_,index,phrase_id,name,pattern,policy)
    if fail_draft_persistence then return nil,"test persistence failure" end
    persisted_drafts[index..":"..phrase_id]={pattern=pattern,policy=policy,name=name}
    return true
  end,
  read_draft=function(_,index,phrase_id,name)
    local item=persisted_drafts[index..":"..phrase_id]
    if not item then return nil end
    assert(item.name==name)
    return item.pattern,item.policy
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
  generate=function(_,callback,_,target,options)
    tool.writer_calls[#tool.writer_calls+1]={target=target,options=options}
    render_callbacks[#render_callbacks+1]=callback
    return true
  end,
  cancel=function()return true end
}
local editor_module=require("model.editor_state")
local force_diagnostic=false
package.loaded["model.editor_state"]={
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

local builder,dialog=open_gui()
local phrase_choice=popup(builder,360)
builder.views.acid_program_key_popup:fire(2)
phrase_choice:fire(2)
builder.views.acid_program_key_popup:fire(3)
phrase_choice:fire(1)
assert(builder.views.acid_program_key_popup.value==2,
  "switching phrases restores the unsaved draft for phrase one")
phrase_choice:fire(2)
assert(builder.views.acid_program_key_popup.value==3,
  "switching back restores the separate phrase two draft")

dialog.visible=false
tool.app_idle_observable:fire()
builder,dialog=open_gui()
phrase_choice=popup(builder,360)
assert(builder.views.acid_program_key_popup.value==2,
  "closing and reopening the editor recovers the phrase one draft")
local recovered_status
for _,node in ipairs(builder.nodes) do
  if node.kind=="multiline_textfield" then recovered_status=node end
end
assert(recovered_status.text:find("Recovered saved draft",1,true),
  "draft recovery reports song persistence")
tool.app_release_document_observable:fire()
assert(#warnings==0,"song-persistent drafts do not show a loss warning")
force_diagnostic=true
builder.views.acid_editor_view:fire(2)
local go_to_error=button(builder,"Go to source error")
assert(go_to_error.active,"invalid source exposes diagnostic navigation: "..builder.views.acid_source_diagnostic.text)
go_to_error:fire()
assert(builder.views.acid_program_time_position.value==3 and
  builder.views.acid_program_pitch_position.value==2,
  "diagnostic navigation selects the failing TIME and PITCH positions")
force_diagnostic=false
builder.views.acid_editor_view:fire(1)
fail_draft_persistence=true
builder.views.acid_program_key_popup:fire(6)
assert(recovered_status.text=="DRAFT SAVE ERROR: session recovery only: test persistence failure",
  recovered_status.text)
tool.app_release_document_observable:fire()
assert(#warnings==1 and warnings[1]:find("could not be saved",1,true),
  "volatile draft persistence failure warns before song close")
fail_draft_persistence=false

local live_checkbox
for _,node in ipairs(builder.nodes) do
  if node.kind=="checkbox" and node.value==false then live_checkbox=node end
end
assert(live_checkbox,"Live Edit checkbox was not created")
live_checkbox:fire(true)
builder.views.acid_program_key_popup:fire(4)
assert(builder.views.acid_live_edit_state.text:find("QUEUED",1,true),
  "pending Live Edit is visible before rendering")
tool:fire_timer()
assert(builder.views.acid_live_edit_state.text:find("RENDERING",1,true),
  "active Live Edit rendering is visible")
assert(#render_callbacks==1 and tool.writer_calls[1].options.token,
  "Live Edit passes a cancellation token to the writer")
render_callbacks[1]({kind="complete",status="error",message="temporary render failure",
  diagnostics={"temporary render failure"}})
assert(live_checkbox.value,"a recoverable writer error leaves Live Edit armed")
assert(builder.views.acid_live_edit_state.text:find("ERROR",1,true),
  "last Live Edit failure remains visible")
local status
for _,node in ipairs(builder.nodes) do
  if node.kind=="multiline_textfield" then status=node end
end
assert(status.text=="LIVE EDIT ERROR: temporary render failure",status.text)
button(builder,"Retry Live Edit"):fire()
tool:fire_timer()
assert(#render_callbacks==2)
fail_draft_clear=true
render_callbacks[2]({kind="complete",status="approximate",message="recovered with approximation",
  diagnostics={"slide approximated"}})
assert(live_checkbox.value,"a recoverable writer error leaves Live Edit armed")
assert(status.text=="LIVE EDIT APPROXIMATE: recovered with approximation\nslide approximated\n"..
  "DRAFT WARNING: Phrase committed, but its saved draft could not be cleared: test cleanup failure",
  status.text)
assert(builder.views.acid_live_edit_state.text:find("APPROXIMATE",1,true),
  "draft cleanup failure does not change a successful render status")
fail_draft_clear=false

phrase_choice:fire(2)
tool:fire_timer()
assert(live_checkbox.value and #render_callbacks==3,
  "owned-to-owned destination selection keeps Live Edit armed and resumes")
render_callbacks[3]({kind="complete",status="committed",message="owned phrase rebound"})
local target_popup=popup(builder,290)
target_popup:fire(2)
tool:fire_timer()
assert(live_checkbox.value and #render_callbacks==4,
  "explicit instrument selection rebinds Live Edit to its selected owned phrase")
render_callbacks[4]({kind="complete",status="committed",message="instrument rebound"})
phrase_choice:fire(2)
assert(live_checkbox.value and builder.views.acid_live_edit_state.text:find("SUSPENDED",1,true),
  "foreign phrase selection suspends without disarming Live Edit")
assert(next(tool.timers)==nil,"foreign selection schedules no phrase write")
phrase_choice:fire(3)
assert(live_checkbox.value and builder.views.acid_live_edit_state.text:find("SUSPENDED",1,true),
  "new phrase selection remains suspended until a safe owned target is selected")
assert(next(tool.timers)==nil,"new phrase selection schedules no phrase write")
phrase_choice:fire(1)
tool:fire_timer()
assert(live_checkbox.value and #render_callbacks==5,
  "selecting a safe owned target explicitly resumes the armed editor")
render_callbacks[5]({kind="complete",status="committed",message="safe target rebound"})
assert(live_checkbox.value and status.text=="LIVE EDIT COMMITTED: safe target rebound",status.text)
builder.views.acid_program_key_popup:fire(8)
tool:fire_timer()
render_callbacks[6]({kind="complete",status="error",message="later render failed"})
local live_state=builder.views.acid_live_edit_state.text
assert(live_state:find("LIVE EDIT ERROR",1,true) and
  live_state:find("LAST COMMIT: COMMITTED | Other target / 01 Other owned | safe target rebound",1,true),
  "a later render error preserves the prior successful target and result")

print("ACID GUI draft recovery and typed Live Edit outcome checks passed")
