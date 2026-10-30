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

local tool={app_new_document_observable=observable(),app_idle_observable=observable(),
  app_release_document_observable=observable(),tool_will_unload_observable=observable()}
local instrument={name="Target",phrases={{id=21,name="ACID phrase 1"},
  {id=22,name="ACID phrase 2"}},samples={},sample_modulation_sets={},
  sample_device_chains={},phrase_program_observable=observable()}
local instrument_two={name="Other target",phrases={{id=31,name="Other phrase"}},
  samples={},sample_modulation_sets={},sample_device_chains={},
  phrase_program_observable=observable()}
local selection_assignment_attempts=0
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
      selection_assignment_attempts=selection_assignment_attempts+1
      error("selected_phrase_index is read-only")
    else rawset(t,key,value) end
  end
})
instrument.phrase_program=1
instrument_two.phrase_program=1
local function select_native_phrase(index)
  rawset(song,"_selected_phrase_index",index)
  song.selected_phrase=instrument.phrases[index]
  song.selected_phrase_observable:fire()
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

local render_calls=0
local writer_releases=0
local generation_request,generation_callback
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
  render_calls=render_calls+1
  local call={kind=kind,request=request,token=request.token,source=request.source,
    pb_range=request.pb_range}
  call.pattern=request.source
  for index,instrument in ipairs(request.song.instruments) do
    if rawequal(instrument,request.instrument) then call.instrument_index=index;break end
  end
  if kind=="create" then
    call.target_index=#request.instrument.phrases+1
  else
    for index,phrase in ipairs(request.instrument.phrases) do
      if rawequal(phrase,request.phrase) then call.target_index=index;break end
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
  generation_request=call
  local target_instrument=request.instrument
  if rawequal(request.instrument,song.instruments[1]) and call.target_index<=#target_instrument.phrases then
    -- Staging changes the editor selection without touching the playback program.
    call.options.phrase_mutation(function()
      select_native_phrase(#target_instrument.phrases+1)
    end)
    assert(song.selected_phrase==nil)
  end
  active_request=request
  generation_callback=function(result)
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
  release=function() writer_releases=writer_releases+1 end
}

package.loaded["renoise.phrase_ownership"]={
  status=function() return "owned" end,
  id=function(phrase) return phrase.id end
}
local persisted_drafts={}
package.loaded["renoise.pattern_store"]={load=function(_,instrument,phrase)
  local source=require("model.sequencer").new_pattern(16)
  for i=1,source.length do source.time_events[i]="N" end
  return source,"repeat",phrase.id==22 and 24 or 0
end,
  write_draft=function(song,instrument,phrase,pattern,policy,pb_range)
    local index;for i,candidate in ipairs(song.instruments) do if rawequal(candidate,instrument) then index=i;break end end
    local phrase_id,name=phrase and phrase.id or 0,instrument.name
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

dofile("tests/acid/gui_host_stub.lua")
local editor=require("model.editor_state")
local project=editor.project
local projection_calls=0
editor.project=function(...)
  projection_calls=projection_calls+1
  return project(...)
end
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
local initial_projections=projection_calls
view:fire(2)
assert(not program.visible and grid.visible)
assert(display_snapshot()==initial)
assert(render_calls==0)
view:fire(1)
assert(program.visible and not grid.visible)
assert(display_snapshot()==initial)
assert(render_calls==0)
assert(projection_calls==initial_projections,"view navigation reuses the validated projection")

builder.views.acid_program_time_command:fire(3)
assert(projection_calls==initial_projections+1,"a TIME edit projects once")
assert(builder.views.acid_grid_time_01.value==3)
assert(builder.views.acid_preview_summary.text:find("REST",1,true))
assert(render_calls==0)
builder.views.acid_editor_view:fire(2)
assert(builder.views.acid_grid_time_01.value==3)
assert(render_calls==0)
builder.views.acid_editor_view:fire(1)
builder.views.acid_program_key_popup:fire(2)
assert(projection_calls==initial_projections+2,"a PITCH edit projects once")
assert(builder.views.acid_grid_pitch_01.text:find("C#",1,true))
assert(render_calls==0)
builder.views.acid_editor_view:fire(2)
assert(builder.views.acid_grid_pitch_01.text:find("C#",1,true))
assert(render_calls==0)

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
assert(last_step and last_step.min==1 and last_step.max==32)
assert(pb_range_popup and pb_range_popup.items[1]=="Off" and
  pb_range_popup.items[2]=="±2" and pb_range_popup.items[3]=="±12" and
  pb_range_popup.items[4]=="±24" and pb_range_popup.items[5]=="±48" and
  pb_range_popup.value==1,"PB Range defaults to Off and offers the documented assumptions")
last_step:fire("32")
assert(builder.views.acid_source_summary.text:find("STEPS 32/32",1,true))
local before_settings=projection_calls
output_popup:fire(1)
assert(projection_calls==before_settings+1,"output-policy edits invalidate projection once")
pb_range_popup:fire(3)
assert(projection_calls==before_settings+2,"PB-range edits invalidate projection once")
pb_range_popup:fire(3)
assert(projection_calls==before_settings+2,"unchanged settings reuse projection")
song.selected_phrase_observable:fire()
builder.views.acid_editor_view:fire(2)
assert(projection_calls==before_settings+3,"host invalidation refreshes the projection")
builder.views.acid_editor_view:fire(1)
assert(projection_calls==before_settings+3,"the refreshed host projection is reused")
assert(pb_range_popup.value==3 and builder.views.acid_source_summary.text:find("STEPS 32/32",1,true),
  "PB Range changes do not mutate canonical PITCH/TIME source")

local function button(text)
  for _,node in ipairs(builder.nodes) do
    if node.kind=="button" and node.text==text then return node end
  end
  error("missing button: "..text)
end
local timing_popup=builder.views.acid_timing
timing_popup:fire(2)
assert(timing_popup.value==2)
button("Reset Source"):fire()
assert(timing_popup.value==1,"Reset Source restores straight timing")
assert(builder.views.acid_source_summary.text:find("STEPS 32/32",1,true))
assert(builder.views.acid_preview_summary.text:find("Start: NOTE",1,true))
assert(output_popup.value==2,"Reset Source restores Repeat output")
assert(pb_range_popup.value==1,"Reset Source restores PB Range Off")
assert(button("Undo").active)
button("Undo"):fire()
assert(timing_popup.value==2,"Undo restores the previous timing")
assert(builder.views.acid_source_summary.text:find("STEPS 32/32",1,true))
assert(builder.views.acid_preview_summary.text:find("Start: REST",1,true))
assert(builder.views.acid_program_key_popup.value==2)
assert(output_popup.value==1,"Undo restores the previous output policy")
assert(pb_range_popup.value==3,"Undo restores the prior PB Range")
assert(button("Redo").active)
button("Redo"):fire()
assert(output_popup.value==2 and builder.views.acid_preview_summary.text:find("Start: NOTE",1,true))
assert(pb_range_popup.value==1,"Redo restores the reset PB Range Off")
assert(timing_popup.value==1,"Redo restores straight timing")
button("Undo"):fire()
builder.views.acid_program_time_command:fire(1)
assert(not button("Redo").active,"new edits discard the redo branch")

phrase_popup:fire(1)
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request.target_index==1,"the first owned phrase can be generated in place")
generation_callback(terminal_result(generation_request,"committed","Phrase 01 generated."))
assert(song.selected_phrase==nil and instrument.phrase_program==1,
  "manual regeneration accepts structural selection changes without altering playback")

phrase_popup:fire(2)
local rebound_projections=projection_calls
assert(rebound_projections>before_settings+3,"phrase rebinding invalidates the prior projection")
builder.views.acid_editor_view:fire(1)
assert(projection_calls==rebound_projections,"rebound projection is reused during navigation")
assert(pb_range_popup.value==4,"phrase selection restores its stored PB Range")
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request and generation_request.instrument_index==1)
assert(generation_request.target_index==2,
  "generation must pass the selected phrase index")
assert(generation_request.options.pb_range==24,
  "manual generation receives the selected phrase's PB Range")
assert(phrase_popup.value==2,
  "successful generation must keep the selected destination phrase")
generation_callback(terminal_result(generation_request,"committed","Phrase generated."))
assert(song.selected_phrase==nil and instrument.phrase_program==1,
  "manual generation leaves host selection unchanged after staging")
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
generation_callback(terminal_result(generation_request,"committed","Phrase generated."))
local draft_cache=require("runtime.draft_cache")
local recovered,recovered_policy,recovered_pb_range=draft_cache.get(song,instrument,nil)
assert(recovered and recovered.pitch_events[1].key==3 and recovered_policy=="repeat" and
  recovered_pb_range==48,
  "stale create completion preserves the newest New Phrase draft at its original target")
assert(not draft_cache.get(song,instrument,created_phrase),
  "stale create completion cannot associate newer edits with an unverified destination")
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
assert(render_calls==3,"arming Live Edit does not request a render")
local armed_projections=projection_calls
builder.views.acid_editor_view:fire(2)
assert(render_calls==3 and projection_calls==armed_projections,
  "armed view navigation reuses projection without rendering")
button("Reset Source"):fire()
assert(render_calls==3,"resetting an armed source does not request a render")
builder.views.acid_program_key_popup:fire(2)
assert(render_calls==4 and generation_request.target_index==4,
  "an edit after arming appends the selected new phrase")
local appended={id=24,name="Live appended phrase"}
generation_request.options.phrase_mutation(function()
  instrument.phrases[4]=appended
  return appended
end)
generation_callback(terminal_result(generation_request,"committed","Live append committed."))
assert(phrase_popup.value==4,"Live Edit binds the newly appended owned phrase")
builder.views.acid_program_key_popup:fire(5)
assert(render_calls==5 and generation_request.target_index==4,
  "the next edit regenerates the same appended phrase in place")
generation_callback(terminal_result(generation_request,"committed","Live regeneration committed."))
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
assert(render_calls==5 and song.selected_phrase==instrument.phrases[2],
  "switching to a saved phrase does not regenerate or disturb its selection")
phrase_popup:fire(1)
assert(phrase_popup.value==1 and render_calls==5 and song.selected_phrase==instrument.phrases[2],
  "choosing an ACID destination leaves native selection unchanged without regenerating")
phrase_popup:fire(2)
assert(phrase_popup.value==2 and render_calls==5 and song.selected_phrase==instrument.phrases[2],
  "choosing phrase 02 in Destination stays selected without regenerating")
builder.views.acid_program_key_popup:fire(5)
assert(render_calls==6 and generation_request.target_index==2,
  "an edit after a native phrase switch targets the selected phrase")
instrument.phrase_program=2
instrument.phrase_program_observable:fire()
generation_callback(terminal_result(generation_request,"committed","Native phrase selection regenerated."))
assert(song.selected_phrase==nil and instrument.phrase_program==2,
  "Live Edit preserves a playback program change made during rendering")
builder.views.acid_program_key_popup:fire(6)
assert(render_calls==7 and generation_request.target_index==2,
  "subsequent PITCH edits keep regenerating the phrase selected in Renoise")
instrument.phrase_program=1
instrument.phrase_program_observable:fire()
generation_callback(terminal_result(generation_request,"committed","Selected phrase regenerated again."))
assert(instrument.phrase_program==1,
  "Live Edit also preserves a playback program change back to phrase 01")
assert(#instrument.phrases==4,"native phrase selection must not create another destination")

live_checkbox:fire(false)
instrument.phrase_program_observable:fire()
select_native_phrase(2)
phrase_popup:fire(1)
tool.app_idle_observable:fire()
assert(phrase_popup.value==1,"an explicit ACID destination beats a queued native selection")
live_checkbox:fire(true)
assert(render_calls==7,"rearming Live Edit does not request a render")
builder.views.acid_program_key_popup:fire(3)
assert(render_calls==8 and generation_request.target_index==1,
  "an edit after rearming targets the selected phrase 01")

generation_request.options.phrase_mutation(function()
  select_native_phrase(2)
end)
generation_callback(terminal_result(generation_request,"committed","Live phrase 01 regenerated."))
tool.app_idle_observable:fire()
assert(phrase_popup.value==1 and generation_request.target_index==1,
  "ACID generation cannot redirect its selected phrase through native phrase notifications")
assert(song.selected_phrase==instrument.phrases[2] and song.selected_phrase_index==2 and instrument.phrase_program==1,
  "regenerating ACID phrase 01 leaves native structural selection unchanged")

-- Cancelling a live render must not block subsequent native selections.
builder.views.acid_program_key_popup:fire(7)
assert(render_calls==9,"a fresh Live Edit render is running before cancellation")
live_checkbox:fire(false)
select_native_phrase(2)
tool.app_idle_observable:fire()
assert(phrase_popup.value==2,"cancelled renders must not suppress native phrase selection")
local after_cancel=render_calls

-- Passive selection of a foreign phrase must never start a new render.
instrument.phrases[3].foreign=true
package.loaded["renoise.phrase_ownership"].status=function(phrase)
  return phrase.foreign and "foreign" or "owned"
end
select_native_phrase(3)
tool.app_idle_observable:fire()
assert(render_calls==after_cancel and phrase_popup.value==3,
  "foreign native selection is reflected without appending or redirecting to New")
instrument.phrases[3].foreign=nil
select_native_phrase(1)
tool.app_idle_observable:fire()
assert(phrase_popup.value==1,"owned phrase selection still synchronizes after cancellation")

generation_callback(terminal_result(generation_request,"suspended","cancelled render cleaned"))

local before_queued_generate=render_calls
live_checkbox:fire(true)
select_native_phrase(2)
assert(render_calls==before_queued_generate and phrase_popup.value==1,
  "arming and queued native selection remain read-only")
button("Generate / Regenerate ACID Phrase"):fire()
assert(render_calls==before_queued_generate+1 and generation_request.target_index==2,
  "explicit Generate applies queued native selection and renders while Live Edit is armed")
generation_callback(terminal_result(generation_request,"committed","Queued destination generated."))
live_checkbox:fire(false)

assert(song.selected_phrase_observable:listener_count()==1,
  "ACID watches the Renoise selected phrase")
dialog.visible=false
tool.app_idle_observable:fire()
assert(song.selected_phrase_observable:listener_count()==0,
  "closing ACID removes its selected-phrase observer")

local lifecycle_events={}
draft_cache.has_volatile=function() return true end
app.show_warning=function() lifecycle_events[#lifecycle_events+1]="warning" end
package.loaded["writers.phrase_writer"].release=function()
  writer_releases=writer_releases+1
  lifecycle_events[#lifecycle_events+1]="release"
end
tool.app_release_document_observable:fire()
assert(writer_releases==1 and lifecycle_events[1]=="warning" and lifecycle_events[2]=="release",
  "document release warns about volatile drafts before releasing writer host references")
tool.tool_will_unload_observable:fire()
assert(writer_releases==2,"tool unload releases writer host references")
assert(selection_assignment_attempts==0,"ACID never attempts to assign read-only native selection")
print("ACID Program/Grid views, native phrase selection and Live Edit destination checks passed")
