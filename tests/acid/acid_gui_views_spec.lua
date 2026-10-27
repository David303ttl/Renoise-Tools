dofile("tests/bootstrap.lua")("acid")

local function observable()
  local handlers={}
  return {
    add_notifier=function(_,handler) handlers[handler]=true end,
    remove_notifier=function(_,handler) handlers[handler]=nil end
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
function tool:add_timer() end
function tool:remove_timer() end
local instrument={name="Target",phrases={{id=21,name="ACID phrase 1"},
  {id=22,name="ACID phrase 2"}},samples={},sample_modulation_sets={},
  sample_device_chains={},phrase_program=1}
local instrument_two={name="Other target",phrases={{id=31,name="Other phrase"}},
  samples={},sample_modulation_sets={},sample_device_chains={},phrase_program=1}
local song={selected_instrument_index=1,instruments={instrument,instrument_two}}
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
package.loaded["model.live_regen"]={new=function()
  return {
    changed=function() edit_notifications=edit_notifications+1 end,
    stop=function() end,
    set_enabled=function() end
  }
end}
package.loaded["writers.phrase_writer"]={
  generate=function(instrument_index,callback,pattern,target_index,options)
    render_calls=render_calls+1
    generation_request={instrument_index=instrument_index,target_index=target_index,
      pattern=pattern,options=options}
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
package.loaded["model.pattern_store"]={load=function()
  local source=require("model.sequencer").new_pattern(16)
  for i=1,source.length do source.time_events[i]="N" end
  return source,"repeat"
end,
  write_draft=function(_,index,phrase_id,name,pattern,policy)
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
    persisted_drafts[index..":"..phrase_id]=nil
    return true
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
assert(edit_notifications==1 and render_calls==0)
builder.views.acid_editor_view:fire(2)
assert(builder.views.acid_grid_time_01.value==3)
assert(edit_notifications==1 and render_calls==0)
builder.views.acid_editor_view:fire(1)
builder.views.acid_program_key_popup:fire(2)
assert(builder.views.acid_grid_pitch_01.text:find("C#",1,true))
assert(edit_notifications==2 and render_calls==0)
builder.views.acid_editor_view:fire(2)
assert(builder.views.acid_grid_pitch_01.text:find("C#",1,true))
assert(edit_notifications==2 and render_calls==0)

local last_step
local output_popup
local phrase_popup
for _,node in ipairs(builder.nodes) do
  if node.kind=="valuebox" then last_step=node end
  if node.kind=="popup" and node.items and node.items[1]=="Play Once" then
    output_popup=node
  end
  if node.kind=="popup" and node.width==360 then phrase_popup=node end
end
assert(last_step and last_step.min==1 and last_step.max==64)
last_step:fire("32")
assert(builder.views.acid_source_summary.text:find("STEPS 32/64",1,true))
output_popup:fire(1)

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
assert(button("Undo").active)
button("Undo"):fire()
assert(builder.views.acid_source_summary.text:find("STEPS 32/64",1,true))
assert(builder.views.acid_preview_summary.text:find("Start: REST",1,true))
assert(builder.views.acid_program_key_popup.value==2)
assert(output_popup.value==1,"Undo restores the previous output policy")
assert(button("Redo").active)
button("Redo"):fire()
assert(output_popup.value==2 and builder.views.acid_preview_summary.text:find("Start: NOTE",1,true))
button("Undo"):fire()
builder.views.acid_program_time_command:fire(1)
assert(not button("Redo").active,"new edits discard the redo branch")

phrase_popup:fire(2)
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request and generation_request.instrument_index==1)
assert(generation_request.target_index==2,
  "generation must pass the selected phrase index")
assert(phrase_popup.value==2,
  "successful generation must keep the selected destination phrase")
generation_callback({kind="complete",status="committed",message="Phrase generated.",
  diagnostics={},target={phrase_index=2}})

phrase_popup:fire(3)
builder.views.acid_program_key_popup:fire(3)
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request.target_index==3,"new phrase generation targets append slot")
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
local recovered,recovered_policy=draft_cache.get(song,instrument,created_phrase)
assert(recovered and recovered.pitch_events[1].key==3 and recovered_policy=="repeat",
  "the newest NEW PHRASE edit moves onto the phrase committed by its render")
assert(not draft_cache.get(song,instrument,nil),
  "the committed NEW PHRASE draft key is cleared after it moves")
assert(not draft_cache.get(song,instrument_two,instrument_two.phrases[1]),
  "completion never attaches an in-flight source draft to the current foreign target")

print("ACID Program/Grid views share one source and switch presentation without regeneration")
