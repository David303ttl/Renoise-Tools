dofile("tests/bootstrap.lua")("acid")

local function observable()
  local handlers={}
  return {
    add_notifier=function(_,handler) handlers[handler]=true end,
    remove_notifier=function(_,handler) handlers[handler]=nil end,
    listener_count=function()
      local count=0
      for _ in pairs(handlers) do count=count+1 end
      return count
    end,
    fire=function()
      local pending={}
      for handler in pairs(handlers) do pending[#pending+1]=handler end
      for _,handler in ipairs(pending) do
        if handlers[handler] then handler() end
      end
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

local tool={app_new_document_observable=observable(),app_idle_observable=observable()}
local instrument={name="Target",phrases={{id=21,name="ACID phrase 1"},
  {id=22,name="ACID phrase 2"}},samples={},sample_modulation_sets={},
  sample_device_chains={},phrase_program_observable=observable()}
local instrument_two={name="Other target",phrases={{id=31,name="Other phrase"}},
  samples={},sample_modulation_sets={},sample_device_chains={},
  phrase_program_observable=observable()}
local song={selected_instrument_index=1,selected_instrument=instrument,
  selected_phrase=instrument.phrases[1],selected_phrase_observable=observable(),
  instruments={instrument,instrument_two}}
rawset(song,"_selected_phrase_index",1)
setmetatable(song,{
  __index=function(t,key)
    if key=="selected_phrase_index" then return rawget(t,"_selected_phrase_index") end
  end,
  __newindex=function(t,key,value)
    if key=="selected_phrase_index" then
      rawset(t,"_selected_phrase_index",value)
      song.selected_phrase=instrument.phrases[value]
      song.selected_phrase_observable:fire()
    else rawset(t,key,value) end
  end
})
instrument.phrase_program=1
instrument_two.phrase_program=1
local function select_native_phrase(index)
  song.selected_phrase_index=index
  assert(song.selected_phrase==instrument.phrases[index])
end
local builder=view_builder()
local dialog
local app={}
function app:show_custom_dialog(_,content)
  dialog={visible=true,content=content,show=function()end,close=function(self)self.visible=false end}
  return dialog
end
function app:show_warning(message) error(message) end

local render_calls,edit_notifications=0,0
local generation_request,generation_callback
package.loaded["model.live_regen"]={new=function(render,on_result)
  local self={enabled=false,busy=false,pending=false,status="CLEAN",last_result=nil,last_commit=nil}
  local function dispatch()
    if not self.enabled or self.busy or not self.pending then return end
    self.pending=false
    self.busy=true
    self.status="RENDERING"
    render(function(result)
      self.busy=false
      self.last_result=result
      if result.status=="committed" or result.status=="approximate" then self.last_commit=result end
      self.status=string.upper(result.status)
      if on_result then on_result(result) end
      if self.pending then dispatch() end
    end,{is_current=function()return true end})
  end
  function self:changed()
    if not self.enabled then return end
    edit_notifications=edit_notifications+1
    self.pending=true
    dispatch()
  end
  function self:set_enabled(value) self.enabled=value==true end
  function self:rebind() end
  function self:stop() self.enabled=false;self.pending=false end
  function self:retry() self.pending=true;dispatch();return true end
  function self:state()
    return {enabled=self.enabled,busy=self.busy,pending=self.pending,status=self.status,
      last_result=self.last_result,last_commit=self.last_commit}
  end
  return self
end}
package.loaded["writers.phrase_writer"]={
  generate=function(instrument_index,callback,pattern,target_index,options)
    render_calls=render_calls+1
    generation_request={instrument_index=instrument_index,target_index=target_index,
      pattern=pattern,options=options}
    local target_instrument=song.instruments[instrument_index]
    if instrument_index==1 and target_index<=#target_instrument.phrases then
      -- Staging changes the editor selection without touching the playback program.
      song.selected_phrase_index=#target_instrument.phrases+1
      assert(song.selected_phrase==nil)
    end
    generation_callback=callback
    return true
  end,
  cancel=function() return true end
}
package.loaded["writers.phrase_ownership"]={
  status=function() return "owned" end,
  id=function(phrase) return phrase.id end
}
local persisted_drafts={}
package.loaded["model.pattern_store"]={load=function(_,phrase)
  local source=require("model.sequencer").new_pattern(16)
  for i=1,source.length do source.time_events[i]="N" end
  return source,"repeat",phrase.id==22 and 24 or 0
end,
  write_draft=function(_,index,phrase_id,name,pattern,policy,pb_range)
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
    local key=index..":"..phrase_id
    local existed=persisted_drafts[key]~=nil
    persisted_drafts[key]=nil
    return existed
  end,
  has_drafts=function()return next(persisted_drafts)~=nil end}
package.loaded["renoise.selection_context"]={inspect_selection=function()return "selection" end}
package.loaded["renoise.sampler_audit"]={describe=function()return "sampler" end}
renoise={
  song=function()return song end,
  tool=function()return tool end,
  ViewBuilder=function()return builder end,
  app=function()return app end
}

require("gui").show()
assert(dialog and dialog.visible)
local program=builder.views.acid_program_panel
local grid=builder.views.acid_grid_panel
local view=builder.views.acid_editor_view
assert(program.visible and not grid.visible)
local function display_snapshot()
  return table.concat({builder.views.acid_source_summary.text,
    builder.views.acid_preview_summary.text,builder.views.acid_source_diagnostic.text,
    builder.views.acid_program_pitch_summary.text,
    builder.views.acid_program_time_summary.text},"|")
end
local initial=display_snapshot()
view:fire(2)
assert(not program.visible and grid.visible)
assert(display_snapshot()==initial)
assert(edit_notifications==0 and render_calls==0)
view:fire(1)
assert(program.visible and not grid.visible)
assert(display_snapshot()==initial)
assert(edit_notifications==0 and render_calls==0)

builder.views.acid_program_time_command:fire(3)
assert(builder.views.acid_grid_time_01.value==3)
assert(builder.views.acid_preview_summary.text:find("REST",1,true))
assert(edit_notifications==0 and render_calls==0)
builder.views.acid_editor_view:fire(2)
assert(builder.views.acid_grid_time_01.value==3)
assert(edit_notifications==0 and render_calls==0)
builder.views.acid_editor_view:fire(1)
builder.views.acid_program_key_popup:fire(2)
assert(builder.views.acid_grid_pitch_01.text:find("C#",1,true))
assert(edit_notifications==0 and render_calls==0)
builder.views.acid_editor_view:fire(2)
assert(builder.views.acid_grid_pitch_01.text:find("C#",1,true))
assert(edit_notifications==0 and render_calls==0)

local last_step
local output_popup
local pb_range_popup
local phrase_popup
for _,node in ipairs(builder.nodes) do
  if node.kind=="valuebox" then last_step=node end
  if node.kind=="popup" and node.items and node.items[1]=="Play Once" then
    output_popup=node
  end
  if node.id=="acid_pb_range" then pb_range_popup=node end
  if node.kind=="popup" and node.width==360 then phrase_popup=node end
end
assert(last_step and last_step.min==1 and last_step.max==64)
assert(pb_range_popup and pb_range_popup.items[1]=="Off" and
  pb_range_popup.items[2]=="±2" and pb_range_popup.items[3]=="±12" and
  pb_range_popup.items[4]=="±24" and pb_range_popup.items[5]=="±48" and
  pb_range_popup.value==1,"PB Range defaults to Off and offers the documented assumptions")
last_step:fire("32")
assert(builder.views.acid_source_summary.text:find("STEPS 32/64",1,true))
output_popup:fire(1)
pb_range_popup:fire(3)
assert(pb_range_popup.value==3 and builder.views.acid_source_summary.text:find("STEPS 32/64",1,true),
  "PB Range changes do not mutate canonical PITCH/TIME source")

local function button(text)
  for _,node in ipairs(builder.nodes) do
    if node.kind=="button" and node.text==text then return node end
  end
  error("missing button: "..text)
end
button("Reset Source"):fire()
assert(builder.views.acid_source_summary.text:find("STEPS 32/64",1,true))
assert(builder.views.acid_preview_summary.text:find("Start: NOTE",1,true))
assert(output_popup.value==2,"Reset Source restores Repeat output")
assert(pb_range_popup.value==1,"Reset Source restores PB Range Off")
assert(button("Undo").active)
button("Undo"):fire()
assert(builder.views.acid_source_summary.text:find("STEPS 32/64",1,true))
assert(builder.views.acid_preview_summary.text:find("Start: REST",1,true))
assert(builder.views.acid_program_key_popup.value==2)
assert(output_popup.value==1,"Undo restores the previous output policy")
assert(pb_range_popup.value==3,"Undo restores the prior PB Range")
assert(button("Redo").active)
button("Redo"):fire()
assert(output_popup.value==2 and builder.views.acid_preview_summary.text:find("Start: NOTE",1,true))
assert(pb_range_popup.value==1,"Redo restores the reset PB Range Off")
button("Undo"):fire()
builder.views.acid_program_time_command:fire(1)
assert(not button("Redo").active,"new edits discard the redo branch")

phrase_popup:fire(1)
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request.target_index==1,"the first owned phrase can be generated in place")
generation_callback({kind="complete",status="committed",message="Phrase 01 generated.",
  diagnostics={},target={phrase_index=1}})
assert(song.selected_phrase==instrument.phrases[1] and instrument.phrase_program==1,
  "manual regeneration restores Renoise's selected phrase after staging cleanup")

phrase_popup:fire(2)
assert(pb_range_popup.value==4,"phrase selection restores its stored PB Range")
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request and generation_request.instrument_index==1)
assert(generation_request.target_index==2,
  "generation must pass the selected phrase index")
assert(generation_request.options.pb_range==24,
  "manual generation receives the selected phrase's PB Range")
assert(phrase_popup.value==2,
  "successful generation must keep the selected destination phrase")
generation_callback({kind="complete",status="committed",message="Phrase generated.",
  diagnostics={},target={phrase_index=2}})
assert(song.selected_phrase==instrument.phrases[1] and instrument.phrase_program==1,
  "manual generation preserves a different native phrase selection")
local draft_warning
for _,node in ipairs(builder.nodes) do
  if type(node.text)=="string" and node.text:find("DRAFT WARNING",1,true) then
    draft_warning=node.text
  end
end
assert(not draft_warning,
  "clearing a nonexistent draft does not report a cleanup failure: "..tostring(draft_warning))

phrase_popup:fire(3)
assert(pb_range_popup.value==1,"a new phrase starts with PB Range Off")
pb_range_popup:fire(4)
builder.views.acid_program_key_popup:fire(3)
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request.target_index==3,"new phrase generation targets append slot")
assert(generation_request.options.pb_range==24,"new phrase render captures its selected PB Range")
pb_range_popup:fire(5)
builder.views.acid_program_key_popup:fire(4)
local target_popup
for _,node in ipairs(builder.nodes) do
  if node.kind=="popup" and node.width==290 then target_popup=node end
end
assert(target_popup,"target instrument selector was not created")
target_popup:fire(2)
local created_phrase={id=23,name="Generated phrase"}
instrument.phrases[3]=created_phrase
generation_callback({kind="complete",status="committed",message="Phrase generated.",
  diagnostics={},target={phrase_index=3}})
local draft_cache=require("model.draft_cache")
local recovered,recovered_policy,recovered_pb_range=draft_cache.get(song,instrument,created_phrase)
assert(recovered and recovered.pitch_events[1].key==3 and recovered_policy=="repeat" and
  recovered_pb_range==48,
  "the newest NEW PHRASE edit moves onto the phrase committed by its render")
assert(not draft_cache.get(song,instrument,nil),
  "the committed NEW PHRASE draft key is cleared after it moves")
assert(not draft_cache.get(song,instrument_two,instrument_two.phrases[1]),
  "completion never attaches an in-flight source draft to the current foreign target")

target_popup:fire(1)
phrase_popup:fire(4)
local live_checkbox
for _,node in ipairs(builder.nodes) do
  if node.kind=="checkbox" and node.value==false then live_checkbox=node end
end
assert(live_checkbox,"Live Edit checkbox was not created")
live_checkbox:fire(true)
assert(render_calls==4 and generation_request.target_index==4,
  "arming Live Edit immediately appends the selected new phrase")
local appended={id=24,name="Live appended phrase"}
instrument.phrases[4]=appended
generation_callback({kind="complete",status="committed",message="Live append committed.",
  diagnostics={},target={instrument_index=1,phrase_index=4}})
assert(phrase_popup.value==4,"Live Edit binds the newly appended owned phrase")
builder.views.acid_program_key_popup:fire(5)
assert(render_calls==5 and generation_request.target_index==4,
  "the next edit regenerates the same appended phrase in place")
generation_callback({kind="complete",status="committed",message="Live regeneration committed.",
  diagnostics={},target={instrument_index=1,phrase_index=4}})
assert(#instrument.phrases==4,"subsequent Live Edit does not append a duplicate phrase")

instrument.phrase_program=2
instrument.phrase_program_observable:fire()
instrument.phrase_program=1
assert(phrase_popup.value==4 and render_calls==5,
  "playback-program notifications alone do not redirect the ACID edit destination")
select_native_phrase(2)
assert(phrase_popup.value==4 and render_calls==5,
  "native phrase selection defers ACID view changes until the idle callback")
tool.app_idle_observable:fire()
assert(phrase_popup.value==2 and pb_range_popup.value==4,
  "native Phrase Editor selection rebinds ACID to that phrase on idle")
assert(render_calls==6 and generation_request.target_index==2,
  "Live Edit after a native phrase switch targets the selected phrase")
generation_callback({kind="complete",status="committed",message="Native phrase selection regenerated.",
  diagnostics={},target={instrument_index=1,phrase_index=2}})
assert(song.selected_phrase==instrument.phrases[2] and song.selected_phrase_index==2 and instrument.phrase_program==1,
  "Live Edit restores the native phrase selected before rendering")
builder.views.acid_program_key_popup:fire(6)
assert(render_calls==7 and generation_request.target_index==2,
  "subsequent PITCH edits keep regenerating the phrase selected in Renoise")
generation_callback({kind="complete",status="committed",message="Selected phrase regenerated again.",
  diagnostics={},target={instrument_index=1,phrase_index=2}})
assert(#instrument.phrases==4,"native phrase selection must not create another destination")

live_checkbox:fire(false)
instrument.phrase_program_observable:fire()
select_native_phrase(2)
phrase_popup:fire(1)
tool.app_idle_observable:fire()
assert(phrase_popup.value==1,"an explicit ACID destination beats a queued native selection")
live_checkbox:fire(true)
assert(render_calls==8 and generation_request.target_index==1,
  "arming Live Edit after selecting phrase 01 targets phrase 01 after phrase 02 was generated")
generation_callback({kind="complete",status="committed",message="Live phrase 01 regenerated.",
  diagnostics={},target={instrument_index=1,phrase_index=1}})
tool.app_idle_observable:fire()
assert(phrase_popup.value==1 and generation_request.target_index==1,
  "ACID generation cannot redirect its selected phrase through native phrase notifications")
assert(song.selected_phrase==instrument.phrases[2] and song.selected_phrase_index==2 and instrument.phrase_program==1,
  "regenerating ACID phrase 01 keeps Renoise's independently selected phrase 02")

assert(song.selected_phrase_observable:listener_count()==1,
  "ACID watches the Renoise selected phrase")
dialog.visible=false
tool.app_idle_observable:fire()
assert(song.selected_phrase_observable:listener_count()==0,
  "closing ACID removes its selected-phrase observer")

print("ACID Program/Grid views, native phrase selection and Live Edit destination checks passed")
