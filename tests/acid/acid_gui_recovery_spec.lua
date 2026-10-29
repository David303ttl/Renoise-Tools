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
  cancel=function()return true end,
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
assert(builder.views.acid_live_edit_state.text:find("RENDERING",1,true),
  "arming Live Edit immediately renders the current source")
assert(#render_callbacks==1 and tool.writer_calls[1].options.token,
  "Live Edit passes a cancellation token to the writer")
assert(tool.writer_calls[1].options.pb_range==12,
  "Live Edit passes the selected PB Range to the renderer")
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
builder.views.acid_program_key_popup:fire(6)
assert(#render_callbacks==2 and tool.writer_calls[2].pattern.pitch_events[2].key==5,
  "a source edit immediately retries the armed Live Edit: callbacks="..
    #render_callbacks.." calls="..#tool.writer_calls.." key="..
    tostring(tool.writer_calls[2] and tool.writer_calls[2].pattern.pitch_events[2].key))
builder.views.acid_program_key_popup:fire(7)
assert(#render_callbacks==2 and #tool.writer_calls==2,
  "rapid edits coalesce while one render is active")
local long_diagnostic=string.rep("TIME step 05: SLIDE approximated: bend range exceeded; ",40)
render_callbacks[2]({kind="complete",status="error",message=long_diagnostic,
  diagnostics={long_diagnostic}})
assert(#render_callbacks==3 and tool.writer_calls[3].pattern.pitch_events[2].key==6,
  "the in-flight follow-up renders the newest source immediately: P1="..
    tostring(tool.writer_calls[3].pattern.pitch_events[1].key).." P2="..
    tostring(tool.writer_calls[3].pattern.pitch_events[2].key))
assert(status.text:find(long_diagnostic,1,true),
  "the bounded details field retains the complete diagnostic")
assert(not builder.views.acid_live_edit_state.text:find(long_diagnostic,1,true),
  "the live status does not duplicate long diagnostics into an auto-sizing text view")
fail_draft_clear=true
render_callbacks[3]({kind="complete",status="approximate",message="recovered with approximation",
  diagnostics={"slide approximated"}})
assert(live_checkbox.value,"a recoverable writer error leaves Live Edit armed")
assert(status.text=="LIVE EDIT APPROXIMATE: recovered with approximation\nslide approximated\n"..
  "DRAFT WARNING: Phrase committed, but its saved draft could not be cleared: test cleanup failure",
  status.text)
assert(builder.views.acid_live_edit_state.text:find("APPROXIMATE",1,true),
  "draft cleanup failure does not change a successful render status")
fail_draft_clear=false

phrase_choice:fire(2)
assert(live_checkbox.value and #render_callbacks==4,
  "selecting a destination with a recovered draft resumes Live Edit")
assert(tool.writer_calls[4].options.pb_range==48,
  "Live Edit restores and passes the newly selected phrase's PB Range")
render_callbacks[4]({kind="complete",status="committed",message="owned phrase rebound"})
local target_popup=popup(builder,290)
target_popup:fire(2)
assert(live_checkbox.value and #render_callbacks==5,
  "explicit instrument selection rebinds Live Edit to its selected owned phrase")
render_callbacks[5]({kind="complete",status="committed",message="instrument rebound"})
phrase_choice:fire(3)
assert(live_checkbox.value and #render_callbacks==6 and tool.writer_calls[6].target==3,
  "selecting NEW PHRASE immediately starts an append render")
builder.views.acid_program_key_popup:fire(9)
local explicit_append={id=23,name="ACID explicit append"}
other_instrument.phrases[3]=explicit_append
render_callbacks[6]({kind="complete",status="committed",message="initial append",
  target={instrument_index=2,phrase_index=3}})
assert(phrase_choice.value==3 and #render_callbacks==7 and tool.writer_calls[7].target==3,
  "an edit during first append moves to its committed phrase and renders the newest source")
assert(tool.writer_calls[7].pattern.pitch_events[1].key==8,
  "the follow-up append render uses the edit made while the first render was active")
render_callbacks[7]({kind="complete",status="committed",message="explicit phrase updated",
  target={instrument_index=2,phrase_index=3}})
phrase_choice:fire(2)
assert(live_checkbox.value and #render_callbacks==8 and tool.writer_calls[8].target==4,
  "foreign phrase selection redirects to a new append slot")
assert(other_instrument.phrases[2]==other_foreign,
  "foreign phrase remains untouched while Live Edit appends a separate phrase")
local separate_owned={id=24,name="ACID foreign replacement"}
other_instrument.phrases[4]=separate_owned
render_callbacks[8]({kind="complete",status="committed",message="foreign redirected",
  target={instrument_index=2,phrase_index=4}})
assert(phrase_choice.value==4,"successful redirect binds the new owned phrase")
builder.views.acid_program_key_popup:fire(8)
assert(#render_callbacks==9 and tool.writer_calls[9].target==4,
  "the edit after foreign redirection regenerates its new owned phrase")
render_callbacks[9]({kind="complete",status="committed",message="separate phrase updated",
  target={instrument_index=2,phrase_index=4}})
assert(#other_instrument.phrases==4 and other_instrument.phrases[2]==other_foreign,
  "foreign phrase stays in place and repeated edits do not append duplicates")
assert(live_checkbox.value and status.text=="LIVE EDIT COMMITTED: separate phrase updated",status.text)
builder.views.acid_program_key_popup:fire(8)
other_instrument.phrases[4].foreign=true
render_callbacks[10]({kind="complete",status="suspended",code="safety.target_changed",
  category="safety",message="target phrase changed during generation"})
assert(#render_callbacks==11 and tool.writer_calls[11].target==5,
  "a target ownership change during rendering immediately redirects to append")
assert(other_instrument.phrases[4]==separate_owned,
  "the changed target object is retained without overwrite")
local safety_append={id=25,name="ACID safety append"}
other_instrument.phrases[5]=safety_append
render_callbacks[11]({kind="complete",status="committed",message="safety append committed",
  target={instrument_index=2,phrase_index=5}})
assert(phrase_choice.value==5,"safety redirect binds the separately appended owned phrase")
builder.views.acid_program_key_popup:fire(9)
assert(#render_callbacks==12 and tool.writer_calls[12].target==5,
  "edits after safety redirect regenerate the appended phrase")
render_callbacks[12]({kind="complete",status="committed",message="safety phrase updated",
  target={instrument_index=2,phrase_index=5}})
builder.views.acid_program_key_popup:fire(8)
render_callbacks[13]({kind="complete",status="error",message="later render failed"})
local live_state=builder.views.acid_live_edit_state.text
local live_state_view=builder.views.acid_live_edit_state
assert(live_state_view.kind=="multiline_text" and live_state_view.width==820 and
  live_state_view.height==48,
  "live status uses a fixed-size wrapping view so long diagnostics cannot widen the dialog")
assert(live_state:find("LIVE EDIT ERROR",1,true) and
  live_state:find("LAST COMMIT: COMMITTED | Other target / 05 ACID safety append",1,true) and
  not live_state:find("safety phrase updated",1,true),
  "a later render error preserves a concise summary of the prior successful commit")

print("ACID GUI draft recovery and typed Live Edit outcome checks passed")
