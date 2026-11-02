dofile("tests/bootstrap.lua")("acid")

local function observable()
  local handlers,notifier_history={},{}
  return {
    add_notifier=function(self,handler)
      if self.ignore_add then return end
      if self.fail_add then error("injected notifier registration failure") end
      handlers[handler]=true
      notifier_history[#notifier_history+1]=handler
      if self.fail_add_after_register then error("injected partial notifier registration failure") end
    end,
    has_notifier=function(_,handler) return handlers[handler]==true end,
    remove_notifier=function(self,handler)
      if self.fail_remove then error("injected notifier removal failure") end
      if not handlers[handler] then error("injected removal of unattached notifier") end
      handlers[handler]=nil
      if self.fail_remove_after_unregister then error("injected removal failure after unregister") end
    end,
    fail_remove=false,
    fail_remove_after_unregister=false,
    fail_add=false,
    fail_add_after_register=false,
    listener_count=function()
      local count=0
      for _ in pairs(handlers) do count=count+1 end
      return count
    end,
    notifier_history=notifier_history,
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
  local native_view_metatable={__eq=function()
    error("native ViewBuilder controls do not support equality")
  end}
  local function construct(kind,properties)
    local node={kind=kind,views={},notifiers={}}
    setmetatable(node,native_view_metatable)
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
  assert(not content.dialog_attached,"dialog content cannot be attached twice")
  content.dialog_attached=true
  dialog={visible=true,content=content,show=function()end,close=function(self)self.visible=false end}
  return dialog
end
function app:show_warning(message) error(message) end
function app:show_prompt() return "Cancel" end
function app:prompt_for_filename_to_read(extensions,title)
  self.last_file_extensions=extensions
  self.last_file_title=title
  return self.scale_import_filename or ""
end

local render_calls=0
local writer_releases=0
local synchronous_writes=false
local next_revision_id=100
local generation_request,generation_callback
local active_request
local committed_entries={}
local sequencer=require("model.sequencer")
local function store_entry(id,source,policy,pb_range)
  local copied=assert(sequencer.copy_source(source))
  committed_entries[id]={source=copied,policy=policy,pb_range=pb_range}
end
local function read_entry(_,id)
  local entry=committed_entries[id]
  if not entry then return nil,"test source revision is missing" end
  return assert(sequencer.copy_source(entry.source)),entry.policy,entry.pb_range
end
local function terminal_result(call,status,message)
  local success=status=="committed" or status=="approximate"
  local phrase=call.phrase or call.request.phrase
  if success and call.request.kind=="regenerate" then
    next_revision_id=next_revision_id+1
    local revision_id=next_revision_id
    call.request:mutate(call.request.token,function()
      local accepted,revision_error=call.request:expect_revision(call.request.token,revision_id)
      assert(accepted,revision_error)
      phrase.id=revision_id
      phrase.baseline_revision=(phrase.baseline_revision or 0)+1
    end)
  end
  local result={kind=success and "success" or "failure",status=status or (success and "committed" or "failed"),
    verified=success,token=call.request.token,epoch=call.request.epoch,request=call.request,
    phrase=success and phrase or nil,reason=success and nil or (message or "invalidated"),
    message=message or "invalidated"}
  if success then
    if phrase and phrase.id then
      store_entry(phrase.id,call.request.source,call.request.output_policy,call.request.pb_range)
    end
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
        snapshot={content=phrase and phrase.baseline_revision or 0},planning_inputs={}}
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
  if synchronous_writes then
    synchronous_writes=false
    generation_callback(terminal_result(call,"committed","Synchronous Live Edit committed."))
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
  id=function(phrase) if phrase.foreign then return nil end;return phrase.id end,
  snapshot_index=function()return nil end,
  capture_recovery=function()return {} end,
  matches_recovery=function(_,token)return type(token)=="table" end,
  recovery_matches_snapshot=function(token)return type(token)=="table" end
}
local persisted_drafts={}
local draft_writes=0
package.loaded["renoise.pattern_store"]={load=function(_,instrument,phrase)
  local entry=committed_entries[phrase.id]
  if not entry then
    local source=sequencer.new_pattern(16)
    for i=1,source.length do source.time_events[i]="N" end
    source.pitch_events[1]=sequencer.new_pitch(0,0,false,false)
    source.pitch_events[2]={note=36,key=12,octave=-1,accent=true,slide=true}
    source.pitch_events[3]={note=48,key=12,octave=0,accent=false,slide=false}
    source.pitch_events[4]={note=60,key=12,octave=1,accent=false,slide=false}
    for i=2,source.length do source.time_events[i]="R" end
    store_entry(phrase.id,source,"repeat",phrase.id==22 and 24 or 0)
    entry=committed_entries[phrase.id]
  end
  return assert(sequencer.copy_source(entry.source)),entry.policy,entry.pb_range
end,
  read_entry=read_entry,
  write_draft_metadata=function(song,instrument,phrase,pattern,policy,pb_range)
    draft_writes=draft_writes+1
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
renoise={Document={create=function()
  return function(properties)
    local document={}
    for name,value in pairs(properties or {}) do document[name]={value=value} end
    function document:add_property(name,value) self[name]={value=value} end
    return document
  end
end},
  song=function()return song end,
  tool=function()return tool end,
  ViewBuilder=function()return builder end,
  app=function()return app end
}

dofile("tests/acid/gui_host_stub.lua")
local validator=require("writers.phrase_validator")
local classify=validator.classify
local classification_calls=0
validator.classify=function(...)
  classification_calls=classification_calls+1
  return classify(...)
end
local editor=require("model.editor_state")
local draft_cache=require("runtime.draft_cache")
local project=editor.project
local projection_calls=0
editor.project=function(...)
  projection_calls=projection_calls+1
  return project(...)
end
local runtime_context=require("runtime.context")
local new_context=runtime_context.new
local recovery_action_reads=0
local recovery_reason_fixture
local label_context
runtime_context.new=function(options)
  local context=new_context(options)
  label_context=context
  local recovery_entries=context.recovery_entries
  context.recovery_entries=function(self,...)
    recovery_action_reads=recovery_action_reads+1
    local entries=recovery_entries(self,...)
    if recovery_reason_fixture then
      entries=entries or {}
      entries[#entries+1]={token={},revision=1,
        labels={instrument="Recovery fixture",phrase="Long diagnostic"},
        reason=recovery_reason_fixture}
    end
    return entries
  end
  return context
end
tool.app_new_document_observable.fail_add=true
local lifecycle_loaded,lifecycle_error=pcall(require,"gui")
assert(not lifecycle_loaded and tostring(lifecycle_error):find("New document notifier registration failed",1,true),
  "required lifecycle registration failure is visible")
assert(tool.app_release_document_observable:listener_count()==0,
  "partial lifecycle registration unwinds earlier listeners")
package.loaded.gui=nil
tool.app_new_document_observable.fail_add=false
tool.app_new_document_observable.fail_add_after_register=true
lifecycle_loaded,lifecycle_error=pcall(require,"gui")
assert(not lifecycle_loaded and tostring(lifecycle_error):find("New document notifier registration failed",1,true),
  "partially installed lifecycle notifier registration is visible")
assert(tool.app_release_document_observable:listener_count()==0 and
  tool.app_new_document_observable:listener_count()==0,
  "partial notifier installation is removed after registration throws")
package.loaded.gui=nil
tool.app_new_document_observable.fail_add_after_register=false
tool.app_new_document_observable.ignore_add=true
lifecycle_loaded,lifecycle_error=pcall(require,"gui")
assert(not lifecycle_loaded and tostring(lifecycle_error):find("New document notifier registration failed",1,true),
  "silently ineffective lifecycle registration must reject initialization")
assert(tool.app_release_document_observable:listener_count()==0 and
  tool.app_new_document_observable:listener_count()==0,
  "ineffective lifecycle registration must unwind installed listeners")
package.loaded.gui=nil
tool.app_new_document_observable.ignore_add=false
local unload_observable=tool.tool_will_unload_observable
tool.tool_will_unload_observable=nil
lifecycle_loaded,lifecycle_error=pcall(require,"gui")
assert(not lifecycle_loaded and tostring(lifecycle_error):find("Tool unload notifier registration failed",1,true),
  "missing required lifecycle observable is visible")
assert(tool.app_release_document_observable:listener_count()==0 and
  tool.app_new_document_observable:listener_count()==0,
  "missing required lifecycle observable unwinds earlier subscriptions")
tool.tool_will_unload_observable=unload_observable
package.loaded.gui=nil
require("gui").show()
runtime_context.new=new_context
assert(dialog and dialog.visible)
local program=builder.views.acid_program_panel
local grid=builder.views.acid_grid_panel
local view=builder.views.acid_editor_view
assert(program.visible and not grid.visible)
for _,id in ipairs({"acid_program_pitch_position","acid_program_time_position",
    "acid_program_key_popup","acid_program_octave_popup"}) do
  assert(builder.views[id]==nil,"removed memory dropdown remains: "..id)
end
for id in pairs(builder.views) do
  assert(not id:match("^acid_grid_time_"),"removed TIME cell popup remains: "..id)
end
local function assert_direct_memory_controls(node)
  assert(node.kind~="popup","memory editing must use direct controls")
  assert(node.kind~="multiline_text","decoded preview belongs in its workspace tab")
  for _,child in ipairs(node.views) do assert_direct_memory_controls(child) end
end
assert_direct_memory_controls(program)
assert_direct_memory_controls(grid)
local function display_snapshot()
  return table.concat({builder.views.acid_source_summary.text,
    builder.views.acid_preview_summary.text,builder.views.acid_source_diagnostic.text,
    builder.views.acid_program_pitch_summary.tooltip,
    builder.views.acid_program_time_summary.text},"|")
end
local initial=display_snapshot()
local initial_recovery_action_reads=recovery_action_reads
local initial_projections=projection_calls
local initial_classifications=classification_calls
local function button(text)
  for _,node in ipairs(builder.nodes) do
    if node.kind=="button" and node.text==text then return node end
  end
  error("missing button: "..text)
end
local recovery_item_reads
local function control(id)
  assert(builder.views[id],"missing behavioral GUI control: "..id)
  return builder.views[id]
end
local function program_key(index)
  return control(string.format("acid_program_key_%02d",index))
end
local function saved_draft()
  return assert(persisted_drafts["1:21"],"expected durable editor draft").pattern
end
local function text_control(text)
  for _,node in ipairs(builder.nodes) do
    if node.text==text then return node end
  end
  error("missing text control: "..text)
end
local function assert_navigation_neutral(before,label)
  assert(render_calls==before.writes,label.." must not request generation")
  assert(projection_calls==before.projections,label.." must not re-resolve source")
  assert(classification_calls==before.classifications,label.." must not reclassify phrase content")
  assert(button("Undo").active==before.undo and button("Redo").active==before.redo,
    label.." must not create a history transition")
  assert(draft_writes==before.drafts,label.." must not persist a draft")
  assert(recovery_item_reads==before.recovery_reads,label.." must not rescan recovery entries")
end
local function navigation_snapshot()
  return {writes=render_calls,projections=projection_calls,
    classifications=classification_calls,undo=button("Undo").active,
    redo=button("Redo").active,drafts=draft_writes,recovery_reads=recovery_item_reads}
end
local recovery_choice=builder.views.acid_recovery_choice
local recovery_items=recovery_choice.items
local recovery_item_writes=0
recovery_item_reads=0
recovery_choice.items=nil
setmetatable(recovery_choice,{__index=function(_,key)
  if key=="items" then recovery_item_reads=recovery_item_reads+1;return recovery_items end
end,__newindex=function(self,key,value)
  if key=="items" then recovery_item_writes=recovery_item_writes+1;recovery_items=value
  else rawset(self,key,value) end
end})
local summary_view=builder.views.acid_source_summary
local summary_text=summary_view.text
local summary_writes,summary_reads=0,0
summary_view.text=nil
setmetatable(summary_view,{__index=function(_,key)
  if key=="text" then summary_reads=summary_reads+1;return summary_text end
end,__newindex=function(self,key,value)
  if key=="text" then summary_writes=summary_writes+1;summary_text=value
  else rawset(self,key,value) end
end})
local navigation=navigation_snapshot()
assert(not control("acid_details_panel").visible,"routine diagnostics start collapsed")
control("acid_details_toggle"):fire()
assert(control("acid_details_panel").visible,"Details exposes diagnostic reports")
control("acid_details_toggle"):fire()
assert(not control("acid_details_panel").visible,"Details can be collapsed again")
assert_navigation_neutral(navigation,"diagnostic visibility")
assert(not control("acid_program_stage_status").visible,
  "idle entry does not show staging diagnostics")
assert(not control("acid_source_diagnostic").visible,
  "valid source does not show a routine validation report")
control("acid_program_select_time_02"):fire()
local initial_time_label=control("acid_program_select_time_02").text
for _,assignment in ipairs({{"TIE","Tie"},{"REST","Rest"}}) do
  button(assignment[1]):fire()
  assert(control("acid_program_select_time_02").text=="02 "..assignment[2] and
    control("acid_program_time_summary").text=="TIME 02: "..assignment[2],
    "Program TIME displays the assigned command in plain language")
  view:fire(2)
  assert(control("acid_grid_select_time_02").text=="02 "..assignment[2],
    "Grid TIME uses the same command label")
  view:fire(1)
  button("Undo"):fire()
end
assert(control("acid_program_select_time_02").text==initial_time_label,
  "Undo restores the visible TIME assignment")
control("acid_program_select_time_01"):fire()
navigation=navigation_snapshot()
view:fire(2)
assert(display_snapshot()==initial)
assert_navigation_neutral(navigation,"workspace view navigation")
view:fire(1)
assert(display_snapshot()==initial)
assert_navigation_neutral(navigation,"return workspace navigation")
local workspace_tabs={"Decoded","Pattern / Copy","Extended / Clear","Output","Recovery"}
local workspace_panels={"acid_decoded_panel","acid_pattern_copy_panel","acid_extended_panel",
  "acid_output_panel","acid_recovery_panel"}
for index,tab in ipairs(workspace_tabs) do
  text_control(tab):fire()
  for panel_index,id in ipairs(workspace_panels) do
    assert(control(id).visible==(panel_index==index),
      tab.." selects its workspace panel without leaving other panels visible")
  end
end
assert(control("acid_clipboard_copy").active~=false and not control("acid_clipboard_paste").active and
  control("acid_clipboard_status").text=="Clipboard empty",
  "Pattern / Copy exposes Copy and disables empty Paste")
assert(control("acid_operation_open") and control("acid_mask_enabled"),
  "Extended / Clear exposes scoped operations and mask controls")
assert(control("acid_output_policy").active and control("acid_pb_range").active,
  "Output provides active phrase policy and PB Range controls")
assert_navigation_neutral(navigation,"workspace tab navigation")
assert(control("acid_recovery_choice").items[1]=="No detached drafts" and
  control("acid_recovery_detail"),
  "Recovery remains available and reports the empty-recovery state instead of an unavailable placeholder")
assert(summary_writes==0,"unchanged summary text is not assigned again")
assert(recovery_item_reads<=1,
  "recovery items are read only to seed the rendered-value cache")
local initial_recovery_item_reads=recovery_item_reads
for _=1,20 do tool.app_idle_observable:fire() end
assert(classification_calls==initial_classifications,"unchanged idle ticks must not rescan native phrase content")

local nav_before=navigation_snapshot()
for page=1,2 do
  assert(control("acid_pitch_page_"..page),"PITCH page control missing")
  assert(control("acid_time_page_"..page),"TIME page control missing")
end
view:fire(2)
control("acid_pitch_page_2"):fire()
control("acid_grid_pitch_01"):fire()
view:fire(1)
assert(control("acid_program_pitch_summary").tooltip:find("P17",1,true),
  "PITCH page two selects P17")
assert(control("acid_program_time_summary").text:find("TIME 01",1,true),
  "PITCH selection leaves the independent TIME cursor unchanged")
control("acid_time_page_2"):fire()
control("acid_grid_select_time_01"):fire()
assert(control("acid_program_time_summary").text:find("TIME 17",1,true),
  "TIME page two selects TIME17")
assert(control("acid_program_pitch_summary").tooltip:find("P17",1,true),
  "TIME selection leaves the independent PITCH cursor unchanged")
assert_navigation_neutral(nav_before,"independent cursor and page navigation")
view:fire(2)
control("acid_pitch_page_1"):fire()
assert(control("acid_grid_pitch_header_02").text=="P02" and
  control("acid_grid_pitch_02").tooltip:find("36/12%-1") and
  control("acid_grid_pitch_02").tooltip:find("36/12%-1"),
  "the visible cell header and button preserve raw (36,12,-1) and active flags")
control("acid_pitch_page_1"):fire()
assert(control("acid_grid_pitch_header_03").text=="P03" and
  control("acid_grid_pitch_03").tooltip:find("48/12+0",1,true),
  "the visible cell preserves raw (48,12,0) and inactive flags")
assert(control("acid_grid_pitch_header_04").text=="P04" and
  control("acid_grid_pitch_04").tooltip:find("60/12+1",1,true),
  "the visible cell preserves the MIDI-60 encoding and inactive flags")
control("acid_grid_pitch_03"):fire()
view:fire(1)
program_key(2):fire()
local raw48_edit=saved_draft().pitch_events[3]
assert(raw48_edit.note==37 and raw48_edit.key==1 and raw48_edit.octave==0,
  "a genuine edit canonicalizes raw (48,12,0) through keyboard mapping")
view:fire(2)
control("acid_pitch_page_1"):fire()
assert(control("acid_grid_pitch_03").tooltip:find("37/1+0",1,true),
  "the visible cell preserves the canonicalized raw-48 pitch and flags")
control("acid_grid_pitch_04"):fire()
view:fire(1)
program_key(1):fire()
local raw60_edit=saved_draft().pitch_events[4]
assert(raw60_edit.note==48 and raw60_edit.key==0 and raw60_edit.octave==1,
  "a genuine edit canonicalizes loaded raw (60,12,1) through keyboard mapping")
view:fire(2)
control("acid_pitch_page_1"):fire()
assert(control("acid_grid_pitch_04").tooltip:find("48/0+1",1,true),
  "the visible cell preserves the canonicalized loaded endpoint and flags")
view:fire(1)
view:fire(2)
control("acid_pitch_page_1"):fire()
control("acid_grid_pitch_01"):fire()
view:fire(1)
assert(control("acid_program_pitch_summary").tooltip:find("STORED | REFERENCED | UNMODIFIED",1,true),
  "default C is stored, referenced by canonical TIME, and clean against load baseline")
view:fire(2)
control("acid_grid_pitch_02"):fire()
view:fire(1)
assert(control("acid_program_pitch_summary").tooltip:find("STORED | NOT REFERENCED | UNMODIFIED",1,true),
  "a nondefault but unconsumed PITCH slot remains stored and clean")
local all_page_navigation=navigation_snapshot()
for page=1,2 do
  control("acid_pitch_page_"..page):fire()
  for cell=1,16 do
    local slot=(page-1)*16+cell
    assert(control(string.format("acid_grid_pitch_%02d",cell)).active,
      "all 32 PITCH slots remain editable, including P"..slot)
  end
end
assert_navigation_neutral(all_page_navigation,"PITCH and TIME page selection")
local pitch_rows=0
local function inspect_pitch_rows(node)
  if node.kind=="row" then
    local cells=0
    for _,child in ipairs(node.views or {}) do
      for _,candidate in ipairs(child.views or {child}) do
        if type(candidate.id)=="string" and candidate.id:match("^acid_grid_pitch_%d%d$") then
          cells=cells+1
        end
      end
    end
    if cells>0 then assert(cells==8,"each PITCH memory row contains exactly eight cells");pitch_rows=pitch_rows+1 end
  end
  for _,child in ipairs(node.views or {}) do inspect_pitch_rows(child) end
end
inspect_pitch_rows(builder.views.acid_grid_panel)
assert(pitch_rows==2,"PITCH memory uses exactly two rows of eight cells per page")
local time_rows=0
local function inspect_time_rows(node)
  if node.kind=="row" then
    local cells=0
    for _,child in ipairs(node.views or {}) do
      local candidates=child.views or {child}
      for _,candidate in ipairs(candidates) do
        if type(candidate.id)=="string" and candidate.id:match("^acid_grid_select_time_%d%d$") then
          cells=cells+1
        end
      end
    end
    if cells>0 then assert(cells==8,"each TIME memory row contains exactly eight cells");time_rows=time_rows+1 end
  end
  for _,child in ipairs(node.views or {}) do inspect_time_rows(child) end
end
inspect_time_rows(builder.views.acid_grid_panel)
assert(time_rows==2,"TIME memory uses exactly two rows of eight cells per page")
control("acid_pitch_page_1"):fire()
control("acid_grid_pitch_01"):fire()
local edit_neutral=navigation_snapshot()
view:fire(2)
local bounded_views={
  {control("acid_grid_pitch_01"),98},
  {control("acid_grid_pitch_header_01"),98},
  {control("acid_grid_pitch_column_01"),98},
  {control("acid_source_summary"),820},
  {control("acid_preview_summary"),820},
  {control("acid_source_diagnostic"),820},
  {control("acid_status"),820},
  {control("acid_decoded_rows"),820}
}
local widths={}
for index,entry in ipairs(bounded_views) do
  local view,width=entry[1],entry[2]
  assert(view.size and view.size.width==width,
    "Grid pitch and readout views have explicit bounded widths")
  widths[index]=view.size.width
end
local pitch_cell=control("acid_grid_pitch_01")
local pitch_header=control("acid_grid_pitch_header_01")
local old_grid_label=pitch_cell.text
control("acid_grid_key_03"):fire()
assert(pitch_cell.text~=old_grid_label and
  pitch_cell.text:match("^D%d") and pitch_header.text=="P01" and
  pitch_cell.tooltip:find("SRM",1,true),
  "Grid pitch edits show note names and retain source diagnostics in tooltips")
assert(control("acid_grid_pitch_column_01").size.height==38 and
  control("acid_grid_pitch_header_01").size.height==18 and pitch_cell.size.height==20,
  "the position header and raw-pitch button fit the original 38-pixel cell height")
for index,entry in ipairs(bounded_views) do
  assert(entry[1].size.width==widths[index],
    "Grid pitch edits preserve explicit width constraint "..index)
end
view:fire(1)
assert(control("acid_program_pitch_summary").tooltip:find("MODIFIED",1,true),
  "a genuine PITCH edit differs from the accepted baseline")
button("Undo"):fire()
assert(control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "undo recomputes the baseline-relative indicator")
button("Redo"):fire()
assert(control("acid_program_pitch_summary").tooltip:find("MODIFIED",1,true) and
  not control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "redo recomputes the baseline-relative indicator")
program_key(1):fire()
assert(control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "editing back to the loaded baseline clears modified")
assert(render_calls==edit_neutral.writes,"PITCH edits with Live Edit disabled make no request")
local c_plus=control("acid_program_c_plus")
assert(not c_plus.active,"C+ is unavailable unless the selected PITCH octave is UP")
local c_plus_before=navigation_snapshot()
local pitch_before_c_plus=saved_draft().pitch_events[1]
c_plus:fire()
local pitch_after_c_plus=saved_draft().pitch_events[1]
assert(pitch_after_c_plus.note==pitch_before_c_plus.note and
  pitch_after_c_plus.key==pitch_before_c_plus.key and
  pitch_after_c_plus.octave==pitch_before_c_plus.octave and
  draft_writes==c_plus_before.drafts and button("Undo").active==c_plus_before.undo,
  "programmatically firing disabled C+ at NORMAL is a no-op")
assert_navigation_neutral(c_plus_before,"disabled C+ control")
control("acid_program_octave_down"):fire()
assert(not c_plus.active,"C+ is unavailable at DOWN")
local down_c_plus_before=navigation_snapshot()
local pitch_before_down_c_plus=saved_draft().pitch_events[1]
c_plus:fire()
local pitch_after_down_c_plus=saved_draft().pitch_events[1]
assert(pitch_after_down_c_plus.note==pitch_before_down_c_plus.note and
  pitch_after_down_c_plus.key==pitch_before_down_c_plus.key and
  pitch_after_down_c_plus.octave==pitch_before_down_c_plus.octave and
  draft_writes==down_c_plus_before.drafts and button("Undo").active==down_c_plus_before.undo,
  "programmatically firing disabled C+ at DOWN is a no-op")
assert_navigation_neutral(down_c_plus_before,"disabled C+ control at DOWN")
control("acid_program_octave_up"):fire()
assert(c_plus.active,"C+ becomes available at UP")
c_plus:fire()
local endpoint_draft=saved_draft()
assert(endpoint_draft.pitch_events[1].note==60 and
  endpoint_draft.pitch_events[1].key==12 and endpoint_draft.pitch_events[1].octave==1,
  "C+ at the UP octave maps to the inclusive MIDI-60 endpoint: "..
    tostring(endpoint_draft.pitch_events[1].note).."/"..
    tostring(endpoint_draft.pitch_events[1].key).."/"..
    tostring(endpoint_draft.pitch_events[1].octave))
view:fire(2)
control("acid_pitch_page_1"):fire()
assert(control("acid_grid_pitch_header_01").text=="P01" and
  control("acid_grid_pitch_01").tooltip:find("60/12+1",1,true),
  "navigating away and back retains the visible MIDI-60 encoding and flags")
view:fire(1)
program_key(1):fire()
control("acid_program_octave_normal"):fire()
control("acid_grid_pitch_02"):fire()
local raw_before=assert(committed_entries[21].source.pitch_events[2])
assert(raw_before.note==36 and raw_before.key==12 and raw_before.octave==-1,
  "fixture retains the alternate raw encoding (36,12,-1)")
program_key(2):fire()
local alternate_draft=saved_draft()
assert(alternate_draft.pitch_events[2].note==25 and
  alternate_draft.pitch_events[2].key==1 and alternate_draft.pitch_events[2].octave==-1 and
  alternate_draft.pitch_events[2].accent and alternate_draft.pitch_events[2].slide,
  "editing alternate raw (36,12,-1) uses keyboard mapping and preserves ACCENT/SLIDE")
local decoded_rows
local decoded_page_label
for _,node in ipairs(builder.nodes) do
  if node.kind=="multiline_text" and node.size.height==76 then decoded_rows=node end
  if node.kind=="text" and node.text=="TIME 01-04 / 32" then decoded_page_label=node end
end
assert(decoded_rows and decoded_page_label,"decoded paging controls were not built")
local decoded_line_count=decoded_rows.text=="" and 0 or 1
for _ in decoded_rows.text:gmatch("\n") do decoded_line_count=decoded_line_count+1 end
assert(decoded_line_count==4,"decoded workspace is bounded to four visible rows")
assert(text_control("Previous 4") and text_control("Next 4"),
  "decoded sequence uses bounded four-row paging controls")
local decoded_navigation=navigation_snapshot()
for _=1,7 do text_control("Next 4"):fire() end
assert(decoded_page_label.text=="TIME 29-32 / 32",
  "decoded paging reaches exactly the final four of 32 TIME positions")
text_control("Next 4"):fire()
assert(decoded_page_label.text=="TIME 29-32 / 32",
  "decoded paging cannot advance past the source")
for _=1,7 do text_control("Previous 4"):fire() end
assert(decoded_page_label.text=="TIME 01-04 / 32",
  "decoded paging returns to the first four TIME positions")
assert_navigation_neutral(decoded_navigation,"decoded paging")
local recovery_items=control("acid_recovery_choice").items
assert(#recovery_items<=16,"recovery selector is bounded to sixteen entries")
recovery_reason_fixture=string.rep("Injected recovery evidence remains available across bounded pages. ",32)
control("acid_recovery_choice"):fire(1)
assert(#control("acid_recovery_choice").items<=16,
  "recovery selection remains bounded while displaying long evidence")
local recovery_page_label=control("acid_recovery_page_label")
local recovery_detail=control("acid_recovery_detail")
local function visible_lines(text)
  local count=text=="" and 0 or 1
  for _ in text:gmatch("\n") do count=count+1 end
  return count
end
assert(visible_lines(recovery_detail.text)<=4,
  "long recovery evidence renders no more than four lines at once")
local recovery_navigation=navigation_snapshot()
local recovery_first_page=recovery_page_label.text
local _,recovery_page_count_text=recovery_first_page:match("^(%d+) / (%d+)$")
local recovery_page_count=tonumber(recovery_page_count_text)
assert(recovery_page_count and recovery_page_count>1,
  "long recovery evidence exposes multiple bounded pages")
for page=1,recovery_page_count do
  assert(visible_lines(recovery_detail.text)<=4 and recovery_detail.text~="",
    "recovery page "..page.." contains at most four nonempty lines")
  if page<recovery_page_count then
    control("acid_recovery_next"):fire()
    assert(recovery_page_label.text==string.format("%d / %d",page+1,recovery_page_count),
      "recovery Next advances exactly one page")
  end
end
local recovery_last_page=recovery_page_label.text
assert(visible_lines(recovery_detail.text)<=4 and
  recovery_detail.text:find("OWNERSHIP:",1,true),
  "the final recovery page retains ownership context within the line bound")
control("acid_recovery_next"):fire()
assert(recovery_page_label.text==recovery_last_page,
  "recovery paging cannot advance past its final page")
while control("acid_recovery_previous").active do control("acid_recovery_previous"):fire() end
assert(recovery_page_label.text==recovery_first_page and visible_lines(recovery_detail.text)<=4,
  "recovery paging returns to its first bounded page")
assert(recovery_detail.text:find("Injected recovery evidence",1,true),
  "the first recovery page displays injected long-reason content")
assert_navigation_neutral(recovery_navigation,"recovery detail paging")
recovery_reason_fixture=nil
control("acid_recovery_choice"):fire(1)
local recovery_writes_before_source_edit=recovery_item_writes

control("acid_time_page_1"):fire()
control("acid_grid_select_time_01"):fire()
local recovery_reads_before_time_edit=recovery_action_reads
button("REST"):fire()
assert(projection_calls>initial_projections,"a TIME edit refreshes the canonical projection")
assert(recovery_action_reads==recovery_reads_before_time_edit,
  "a successful source edit does not rescan recovery actions")
assert(render_calls==0)
assert(recovery_item_writes==recovery_writes_before_source_edit,
  "unchanged recovery choices are not reassigned during source edits")
local shared_view_snapshot=display_snapshot()
view:fire(2)
assert(display_snapshot()==shared_view_snapshot,"Program and Grid project the same canonical source")
assert(render_calls==0)
view:fire(1)

local last_step=control("acid_last_step")
assert(last_step and last_step.min==1 and last_step.max==32)
last_step:fire("20")
control("acid_time_page_2"):fire()
control("acid_grid_select_time_01"):fire()
assert(control("acid_program_time_summary").text:find("TIME 17",1,true))
button("TIE"):fire()
local inactive_time=saved_draft().time_events[17]
assert(inactive_time=="T","TIME17 accepts an edit while within LAST STEP")
last_step:fire("8")
assert(control("acid_program_time_summary").text:find("TIME 17",1,true),
  "shrinking LAST STEP retains the TIME17 cursor")
assert(not button("TIE").active and not button("REST").active and not button("NOTE").active,
  "shared TIME assignment controls disable while the cursor is inactive")
local inactive_history={undo=button("Undo").active,redo=button("Redo").active,
  drafts=draft_writes}
button("REST"):fire()
assert(saved_draft().time_events[17]==inactive_time and
  button("Undo").active==inactive_history.undo and button("Redo").active==inactive_history.redo and
  draft_writes==inactive_history.drafts,
  "inactive TIME17 cannot be edited or persisted after shrink")

local output_popup
local pb_range_popup
local phrase_popup
for _,node in ipairs(builder.nodes) do
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

local timing_popup=builder.views.acid_timing
timing_popup:fire(2)
assert(timing_popup.value==2)
local reset_preview=builder.views.acid_preview_summary.text
local reset_pitch=builder.views.acid_program_pitch_summary.tooltip
app.show_prompt=function() error("Reset must not prompt") end
button("Reset Pattern"):fire()
app.show_prompt=function() return "Cancel" end
assert(timing_popup.value==1,"Reset Source restores straight timing")
assert(builder.views.acid_source_summary.text:find("STEPS 32/32",1,true))
assert(builder.views.acid_preview_summary.text:find("Start: NOTE",1,true))
assert(output_popup.value==2,"Reset Source restores Repeat output")
assert(pb_range_popup.value==1,"Reset Source restores PB Range Off")
assert(button("Undo").active)
button("Undo"):fire()
assert(timing_popup.value==2,"Undo restores the previous timing")
assert(builder.views.acid_source_summary.text:find("STEPS 32/32",1,true))
assert(builder.views.acid_preview_summary.text==reset_preview)
builder.views.acid_editor_view:fire(1)
assert(builder.views.acid_program_pitch_summary.tooltip==reset_pitch,
  "undo restores selected PITCH without changing selection")
assert(output_popup.value==1,"Undo restores the previous output policy")
assert(pb_range_popup.value==3,"Undo restores the prior PB Range")
assert(button("Redo").active)
button("Redo"):fire()
assert(output_popup.value==2 and builder.views.acid_preview_summary.text:find("Start: NOTE",1,true))
assert(pb_range_popup.value==1,"Redo restores the reset PB Range Off")
assert(timing_popup.value==1,"Redo restores straight timing")
button("Undo"):fire()
button("NOTE"):fire()
assert(not button("Redo").active,"new edits discard the redo branch")

phrase_popup:fire(1)
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request.target_index==1,"the first owned phrase can be generated in place")
generation_callback(terminal_result(generation_request,"committed","Phrase 01 generated."))
assert(song.selected_phrase==nil and instrument.phrase_program==1,
  "manual regeneration accepts structural selection changes without altering playback")
assert(control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "verified generation establishes the accepted PITCH baseline")

local classifications_before_rebind=classification_calls
phrase_popup:fire(2)
assert(classification_calls<=classifications_before_rebind+1,
  "target restoration uses at most one full phrase classification")
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
program_key(3):fire()
button("Generate / Regenerate ACID Phrase"):fire()
assert(generation_request.target_index==3,"new phrase generation targets append slot")
assert(generation_request.options.pb_range==24,"new phrase render captures its selected PB Range")
pb_range_popup:fire(5)
program_key(4):fire()
local target_popup
for _,node in ipairs(builder.nodes) do
  if node.kind=="popup" and node.width==290 then target_popup=node end
end
assert(target_popup,"target instrument selector was not created")
target_popup:fire(2)
local created_phrase={id=23,name="Generated phrase"}
instrument.phrases[3]=created_phrase
generation_callback(terminal_result(generation_request,"committed","Phrase generated."))
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
local live_render_base=render_calls
local live_checkbox=builder.views.acid_live_edit
assert(live_checkbox,"Live Edit checkbox was not created")
live_checkbox:fire(true)
assert(render_calls==live_render_base,"arming Live Edit does not request a render")
local armed_projections=projection_calls
builder.views.acid_editor_view:fire(2)
assert(render_calls==live_render_base and projection_calls==armed_projections,
  "armed view navigation reuses projection without rendering")
program_key(2):fire()
tool.app_idle_observable:fire()
assert(render_calls==live_render_base+1 and generation_request.target_index==4,
  "an edit after arming appends the selected new phrase")
local appended={id=24,name="Live appended phrase"}
generation_request.options.phrase_mutation(function()
  instrument.phrases[4]=appended
  return appended
end)
generation_callback(terminal_result(generation_request,"committed","Live append committed."))
assert(phrase_popup.value==4,"Live Edit binds the newly appended owned phrase")
synchronous_writes=true
program_key(5):fire()
assert(render_calls==live_render_base+2 and active_request==nil,
  "a synchronous writer completes inside the native source-edit callback")
tool.app_idle_observable:fire()
assert(render_calls==live_render_base+2 and generation_request.target_index==4,
  "the idle callback does not duplicate the same in-place Live Edit write")
assert(#instrument.phrases==4,"subsequent Live Edit does not append a duplicate phrase")

do
  local before_policy=output_popup.value
  local changed_policy=before_policy==1 and 2 or 1
  local policies={"play_once","repeat"}
  local writes=render_calls
  live_checkbox:fire(true)
  synchronous_writes=true
  output_popup:fire(changed_policy)
  assert(render_calls==writes+1 and active_request==nil and
    generation_request.request.output_policy==policies[changed_policy],
    "armed output edit commits synchronously: "..control("acid_status").text.." writes "..render_calls.."/"..writes)
  local edited_source=assert(sequencer.copy_source(generation_request.source))
  synchronous_writes=true
  button("Undo"):fire()
  assert(render_calls==writes+2 and active_request==nil and
    generation_request.request.output_policy==policies[before_policy] and
    sequencer.same_source(edited_source,generation_request.source),
    "armed Undo synchronously restores output policy with exact musical source")
  synchronous_writes=true
  button("Redo"):fire()
  assert(render_calls==writes+3 and active_request==nil and
    generation_request.request.output_policy==policies[changed_policy] and
    sequencer.same_source(edited_source,generation_request.source),
    "armed Redo synchronously restores output policy with exact musical source")
  synchronous_writes=true
  button("Undo"):fire()
  live_render_base=live_render_base+4
end

instrument.phrase_program=2
instrument.phrase_program_observable:fire()
instrument.phrase_program=1
assert(phrase_popup.value==4 and render_calls==live_render_base+2,
  "playback-program notifications alone do not redirect the ACID edit destination")
select_native_phrase(2)
assert(phrase_popup.value==4 and render_calls==live_render_base+2,
  "native phrase selection defers ACID view changes until the idle callback")
tool.app_idle_observable:fire()
assert(phrase_popup.value==2 and pb_range_popup.value==4,
  "native Phrase Editor selection rebinds ACID to that phrase on idle")
assert(render_calls==live_render_base+2 and song.selected_phrase==instrument.phrases[2],
  "switching to a saved phrase does not regenerate or disturb its selection")
phrase_popup:fire(1)
assert(phrase_popup.value==1 and render_calls==live_render_base+2 and song.selected_phrase==instrument.phrases[2],
  "choosing an ACID destination leaves native selection unchanged without regenerating")
phrase_popup:fire(2)
assert(phrase_popup.value==2 and render_calls==live_render_base+2 and song.selected_phrase==instrument.phrases[2],
  "choosing phrase 02 in Destination stays selected without regenerating")
program_key(5):fire()
tool.app_idle_observable:fire()
assert(render_calls==live_render_base+3 and generation_request.target_index==2,
  "an edit after a native phrase switch targets the selected phrase")
assert(generation_request.options.token:is_current(),
  "the request is current before the playback-program change")
local pending_revision_id=generation_request.request.phrase.id
instrument.phrase_program=2
instrument.phrase_program_observable:fire()
assert(not generation_request.options.token:is_current(),
  "a playback-program change revokes an in-flight phrase mutation")
generation_callback(terminal_result(generation_request,"suspended","playback program changed"))
assert(generation_request.request.phrase.id==pending_revision_id and instrument.phrase_program==2,
  "a revoked request leaves the phrase revision untouched and keeps the playback program")
program_key(6):fire()
tool.app_idle_observable:fire()
assert(render_calls==live_render_base+4 and generation_request.target_index==2,
  "a fresh edit still targets the ACID-selected phrase after playback changes")
generation_callback(terminal_result(generation_request,"committed","Phrase regenerated with program 02 selected."))
assert(song.selected_phrase==nil and instrument.phrase_program==2,
  "the fresh synchronous regeneration preserves the changed playback program")
view:fire(1)
assert(control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "verified generation establishes the accepted PITCH baseline")
instrument.phrase_program=1
instrument.phrase_program_observable:fire()
assert(instrument.phrase_program==1 and phrase_popup.value==2 and render_calls==live_render_base+4,
  "a playback-program notification alone preserves the ACID destination without writing")
assert(#instrument.phrases==4,"native phrase selection must not create another destination")

live_checkbox:fire(false)
instrument.phrase_program_observable:fire()
select_native_phrase(2)
phrase_popup:fire(1)
tool.app_idle_observable:fire()
assert(phrase_popup.value==1,"an explicit ACID destination beats a queued native selection")
view:fire(2)
control("acid_pitch_page_1"):fire()
control("acid_grid_pitch_01"):fire()
view:fire(1)
live_checkbox:fire(true)
assert(render_calls==live_render_base+4,"rearming Live Edit does not request a render")
control("acid_program_octave_up"):fire()
assert(control("acid_program_pitch_summary").tooltip:find("MODIFIED",1,true) and
  not control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "in-flight request source differs from accepted P1 baseline")
tool.app_idle_observable:fire()
assert(render_calls==live_render_base+5 and generation_request.target_index==1,
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

-- Cancelling an active Live Edit render must not block native selection.
control("acid_program_octave_down"):fire()
tool.app_idle_observable:fire()
assert(render_calls==live_render_base+6 and generation_request.target_index==1,
  "a fresh PITCH edit starts the render used by the cancellation check")
local cancelled_request=generation_request
live_checkbox:fire(false)
assert(not cancelled_request.options.token:is_current(),
  "disarming Live Edit revokes the in-flight request")
select_native_phrase(1)
tool.app_idle_observable:fire()
assert(phrase_popup.value==1,"native phrase selection advances while the cancelled render settles")
select_native_phrase(2)
tool.app_idle_observable:fire()
assert(phrase_popup.value==2 and render_calls==live_render_base+6,
  "cancelled render does not queue a replacement on native selection")
generation_callback(terminal_result(cancelled_request,"suspended","cancelled render cleaned"))
local before_native_selection=render_calls

-- Passive selection of a foreign phrase must never start a new render.
instrument.phrases[3].foreign=true
package.loaded["renoise.phrase_ownership"].status=function(phrase)
  return phrase.foreign and "foreign" or "owned"
end
select_native_phrase(3)
tool.app_idle_observable:fire()
assert(render_calls==before_native_selection and phrase_popup.value==3,
  "foreign native selection is reflected without appending or redirecting to New")
instrument.phrases[3].foreign=nil
select_native_phrase(1)
tool.app_idle_observable:fire()
assert(phrase_popup.value==1,"owned phrase selection still synchronizes after cancellation")

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

-- Instrument inventory notifications refresh the native destination popup on
-- idle while preserving its bound object and without requesting a render.
local function popup_with_item(item)
  for _,node in ipairs(builder.nodes) do
    if node.kind=="popup" and node.items then
      for _,candidate in ipairs(node.items) do
        if candidate==item then return node end
      end
    end
  end
  error("missing popup item: "..item)
end
local target_label="00: "..instrument.name
local instrument_popup=popup_with_item(target_label)
local phrase_popup_for_inventory=popup_with_item("NEW PHRASE (append)")
local before_inventory_render_calls=render_calls
local function inventory_idle()
  tool.app_idle_observable:fire()
  local expected_index
  for index,target in ipairs(song.instruments) do
    if rawequal(target,instrument) then expected_index=index end
  end
  local labels_match=#instrument_popup.items==#song.instruments
  for index,target in ipairs(song.instruments) do
    labels_match=labels_match and instrument_popup.items[index]==
      string.format("%02X: %s",index-1,target.name)
  end
  assert(labels_match and expected_index and instrument_popup.value==expected_index and
    instrument_popup.items[expected_index]==string.format("%02X: %s",expected_index-1,instrument.name),
    "instrument popup refreshes labels and selected index while retaining the bound object")
  assert(phrase_popup_for_inventory.items[#phrase_popup_for_inventory.items]=="NEW PHRASE (append)" and
    phrase_popup_for_inventory.value>=1,
    "instrument inventory refresh keeps the bound phrase choices available")
  assert(render_calls==before_inventory_render_calls,
    string.format("instrument inventory notifications never request a writer operation (before=%d after=%d)",before_inventory_render_calls,render_calls))
end
local inventory_host=dofile("tests/acid/observer_host_fixture.lua")
local added_phrase={name="Imported observer sentinel",foreign=true}
table.insert(instrument_two.phrases,added_phrase)
inventory_host.attach(song,observable)
instrument_two.phrases_observable:fire()
assert(added_phrase.name_observable:listener_count()==0,
  "phrase inventory callbacks defer observer attachment")
builder.views.acid_live_edit:fire(true)
tool.app_idle_observable:fire()
builder.views.acid_live_edit:fire(false)
assert(added_phrase.name_observable:listener_count()==1,
  "a GUI callback before idle must not discard pending phrase observer attachment")
table.remove(instrument_two.phrases)
instrument_two.phrases_observable:fire()
inventory_idle()
local added_instrument={name="Inventory add",phrases={},samples={},sample_modulation_sets={},
  sample_device_chains={},phrase_program=1}
table.insert(song.instruments,added_instrument)
inventory_host.attach(song,observable)
song.instruments_observable:fire()
inventory_idle()
added_instrument.name="Inventory renamed"
added_instrument.name_observable:fire()
inventory_idle()
song.instruments={instrument_two,instrument,added_instrument}
song.instruments_observable:fire()
inventory_idle()
song.instruments={instrument_two,instrument}
song.instruments_observable:fire()
inventory_idle()
song.instruments={instrument,instrument_two}
song.instruments_observable:fire()
inventory_idle()

phrase_popup:fire(1)
view:fire(2)
control("acid_pitch_page_1"):fire()
control("acid_grid_pitch_01"):fire()
view:fire(1)
local committed_key=tonumber(control("acid_program_pitch_summary").tooltip:match("/(%d+)"))
assert(committed_key,"selected pitch summary does not expose its canonical key")
program_key(committed_key==0 and 2 or 1):fire()
assert(control("acid_program_pitch_summary").tooltip:find("MODIFIED",1,true) and
  not control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "precondition: source is modified against the verified commit baseline")
button("Generate / Regenerate ACID Phrase"):fire()
local missing_phrase_result=terminal_result(generation_request,"committed",
  "verified completion without destination identity")
assert(missing_phrase_result.kind=="success" and missing_phrase_result.verified,
  "fixture supplies a verified successful completion before removing phrase identity")
missing_phrase_result.phrase=nil
generation_callback(missing_phrase_result)
assert(control("acid_program_pitch_summary").tooltip:find("MODIFIED",1,true) and
  not control("acid_program_pitch_summary").tooltip:find("UNMODIFIED",1,true),
  "verified completion without the bound phrase does not reset the modified baseline")

assert(song.selected_phrase_observable:listener_count()==1,
  "ACID watches the Renoise selected phrase")
do
  local main_dialog=dialog
  local rename=label_context.rename_label
  local failing=false
  local writes=0
  label_context.rename_label=function(_,label,custom,guard)
    assert(custom==true and guard(),"label write requires current accepted history")
    writes=writes+1
    if failing then return false,"injected label persistence failure" end
    return true
  end
  local function save_label(value)
    control("acid_label_rename"):fire()
    control("acid_label_field"):fire(value)
    control("acid_label_save"):fire()
    dialog=main_dialog
  end
  local renders,draft_count=render_calls,draft_writes
  save_label("Accepted A")
  assert(control("acid_label_accepted").text=="Accepted A")
  control("acid_label_rename"):fire()
  local closed_label_dialog=dialog
  closed_label_dialog:close()
  control("acid_label_rename"):fire()
  assert(not rawequal(dialog.content,closed_label_dialog.content),
    "reopening a natively closed label dialog builds fresh content")
  control("acid_label_discard"):fire()
  dialog=main_dialog
  save_label("Accepted B")
  assert(control("acid_label_accepted").text=="Accepted B")
  assert(render_calls==renders and draft_writes==draft_count,
    "label-only rename does not use musical edit or generation paths")
  failing=true
  button("Undo"):fire()
  dialog=main_dialog
  assert(control("acid_label_field").value=="Accepted A" and not control("acid_label_field").active)
  assert(control("acid_label_accepted").text=="Accepted B" and
    control("acid_label_error").text:find("injected",1,true),
    "failed metadata Undo retains accepted label and proposed history transition")
  local pending_writes=writes
  button("Undo"):fire()
  button("Redo"):fire()
  control("acid_clipboard_paste"):fire()
  program_key(3):fire()
  phrase_popup:fire(2)
  assert(writes==pending_writes and control("acid_label_accepted").text=="Accepted B" and
    render_calls==renders and draft_writes==draft_count,
    "unresolved metadata attempt blocks ambiguous actions and direct source edits")
  failing=false
  control("acid_label_retry"):fire()
  assert(control("acid_label_accepted").text=="Accepted A")
  button("Redo"):fire()
  assert(control("acid_label_accepted").text=="Accepted B",
    "Retry commits original Undo proposal instead of appending a rename")
  failing=true
  save_label("Attempted C")
  assert(control("acid_label_field").value=="Attempted C" and
    control("acid_label_accepted").text=="Accepted B")
  control("acid_label_discard"):fire()
  assert(control("acid_label_field").value=="Accepted B" and
    control("acid_label_accepted").text=="Accepted B",
    "Discard Attempt restores accepted field without accepting failed text")
  failing=false
  button("Undo"):fire()
  assert(control("acid_label_accepted").text=="Accepted A",
    "Undo after discard uses accepted history")
  assert(render_calls==renders and draft_writes==draft_count)
  label_context.rename_label=rename
  dialog=main_dialog
end
do
  phrase_popup:fire(#phrase_popup.items)
  local mask=control("acid_mask_enabled")
  assert(not mask.value)
  control("acid_mask_class_02"):fire(false)
  assert(not mask.value and not control("acid_mask_class_02").value,
    "editing disabled mask preserves disabled state: "..control("acid_status").text)
  control("acid_mask_class_02"):fire(true)
  assert(not mask.value and control("acid_mask_class_02").value)
  button("Undo"):fire();button("Undo"):fire()
  assert(control("acid_mask_class_02").value and not mask.value)
  local CLEAR_PITCH,RANDOM_PITCH,RANDOM_TIME=1,9,10
  local confirmations=0
  app.show_prompt=function() confirmations=confirmations+1;return "Cancel" end
  local function valid_random_parameters()
    control("acid_operation_pitch_seed").value=17
    control("acid_operation_min_note").value=24
    control("acid_operation_max_note").value=60
  end
  control("acid_live_edit"):fire(false)
  program_key(5):fire()
  local before_clear=assert(sequencer.copy_source(label_context:editor_state().source))
  local clear_writes=draft_writes
  control("acid_operation").value=CLEAR_PITCH
  control("acid_operation_open"):fire()
  assert(draft_writes==clear_writes+1,"Clear immediately creates one edit")
  button("Undo"):fire()
  assert(sequencer.same_source(before_clear,label_context:editor_state().source),
    "one Undo restores Clear")
  for _,mode in ipairs({1,2}) do
    view:fire(mode)
    for _,live in ipairs({false,true}) do
      control("acid_live_edit"):fire(live)
      control("acid_operation").value=CLEAR_PITCH
      control("acid_operation_open"):fire()
      local writes=draft_writes
      control("acid_operation_open"):fire()
      assert(draft_writes==writes,"identical Clear is inert")
      button("Reset Pattern"):fire()
      writes=draft_writes
      button("Reset Pattern"):fire()
      assert(draft_writes==writes,"identical Reset is inert")
      for operation=CLEAR_PITCH,RANDOM_PITCH-1 do
        control("acid_operation").value=operation
        control("acid_operation_open"):fire()
      end
      assert(confirmations==0,"routine Clear and Reset never prompt")
      control("acid_live_edit"):fire(false)
    end
  end
  app.show_custom_prompt=function()error("randomization must not open a dialog")end
  control("acid_operation"):fire(RANDOM_PITCH)
  local before=navigation_snapshot()
  valid_random_parameters()
  control("acid_operation_min_note").value=36
  control("acid_operation_max_note").value=48
  control("acid_operation_pitch_seed").value=1
  for _,choice in ipairs({RANDOM_TIME,CLEAR_PITCH,RANDOM_PITCH}) do
    control("acid_operation"):fire(choice)
    assert(control("acid_random_parameters").visible==(choice~=CLEAR_PITCH) and
      control("acid_random_pitch_parameters").visible==(choice==RANDOM_PITCH) and
      control("acid_random_time_parameters").visible==(choice==RANDOM_TIME),
      "operation selection exposes only its inline parameters")
    assert(control("acid_operation_min_note").value==36 and
      control("acid_operation_max_note").value==48 and control("acid_operation_pitch_seed").value==1,
      "operation navigation preserves typed parameters")
  end
  assert_navigation_neutral(before,"inline random parameter editing")
  local previous=assert(sequencer.copy_source(label_context:editor_state().source))
  local writes=draft_writes
  control("acid_operation_open"):fire()
  assert(confirmations==0 and draft_writes==writes+1,"random Apply immediately creates one edit")
  local randomized=assert(sequencer.copy_source(label_context:editor_state().source))
  assert(control("acid_operation_pitch_seed").value==2,"successful random Apply advances seed")
  writes=draft_writes
  control("acid_operation_open"):fire()
  assert(draft_writes==writes+1,"repeated Apply creates a fresh random edit")
  assert(not sequencer.same_source(randomized,label_context:editor_state().source),"next seed changes pitches")
  button("Undo"):fire()
  control("acid_operation_pitch_seed").value=1
  writes=draft_writes
  control("acid_operation_open"):fire()
  assert(draft_writes==writes,"same random seed and parameters produce a no-op")
  assert(control("acid_operation_pitch_seed").value==2,"valid no-op randomization also advances seed")
  button("Undo"):fire()
  assert(sequencer.same_source(previous,label_context:editor_state().source),"one Undo restores random edit")
  button("Redo"):fire()
  assert(sequencer.same_source(randomized,label_context:editor_state().source),"Redo restores random edit")
  do
    local pitch_seed=control("acid_operation_pitch_seed")
    local time_seed=control("acid_operation_time_seed")
    local repeat_last=control("acid_random_repeat")
    local last_used=control("acid_random_last_seed")
    assert(last_used.text=="Last used: 1" and repeat_last.active)
    pitch_seed.value=25
    writes=draft_writes
    repeat_last:fire()
    assert(draft_writes==writes and pitch_seed.value==25,
      "Repeat last reuses the previous seed without consuming the next seed")
    control("acid_operation"):fire(RANDOM_TIME)
    assert(time_seed.value==1 and not repeat_last.active and last_used.text=="Last used: —",
      "TIME starts with its own seed and no previous result")
    time_seed.value=7
    control("acid_operation_open"):fire()
    assert(time_seed.value==8 and pitch_seed.value==25 and last_used.text=="Last used: 7",
      "TIME Apply advances only TIME and records its used seed")
    local time_result=assert(sequencer.copy_source(label_context:editor_state().source))
    button("Undo"):fire()
    repeat_last:fire()
    assert(sequencer.same_source(time_result,label_context:editor_state().source) and time_seed.value==8,
      "Repeat last reproduces TIME after Undo without advancing its seed")
    button("Undo"):fire()
    control("acid_operation"):fire(RANDOM_PITCH)
    assert(last_used.text=="Last used: 1" and pitch_seed.value==25,
      "operation navigation restores the operation's next and last seed")
    pitch_seed.value=pitch_seed.max
    control("acid_operation_open"):fire()
    assert(pitch_seed.value==pitch_seed.min and time_seed.value==8,
      "maximum PITCH seed wraps without changing TIME seed")
    assert(last_used.text=="Last used: "..tostring(pitch_seed.max))
    button("Undo"):fire()
  end
  for _,invalid in ipairs({
      function()control("acid_operation_min_note").value=60;control("acid_operation_max_note").value=24 end,
      function()control("acid_operation_pitch_seed").value=1.5 end}) do
    valid_random_parameters()
    invalid()
    writes=draft_writes
    local last_used=control("acid_random_last_seed").text
    local next_seed=control("acid_operation_pitch_seed").value
    control("acid_operation_open"):fire()
    assert(draft_writes==writes and confirmations==0,"invalid random parameters never edit")
    assert(control("acid_random_last_seed").text==last_used and
      control("acid_operation_pitch_seed").value==next_seed,
      "invalid random parameters preserve next and last seeds")
  end
  control("acid_operation"):fire(RANDOM_TIME)
  before=navigation_snapshot()
  control("acid_operation_note_weight").value=0
  control("acid_operation_tie_weight").value=0
  control("acid_operation_rest_weight").value=0
  assert_navigation_neutral(before,"inline TIME weight editing")
  writes=draft_writes
  control("acid_operation_open"):fire()
  assert(draft_writes==writes and confirmations==0,"zero random weights never edit")
  control("acid_operation"):fire(RANDOM_PITCH)
  valid_random_parameters()
  app.show_prompt=function(_,title)
    if title=="Re-enter PITCH" then return "Proceed" end
    return "Stay"
  end
  control("acid_program_reenter_pitch"):fire()
  for _,name in ipairs({"pitch_seed","time_seed","min_note","max_note","note_weight","tie_weight","rest_weight"}) do
    assert(not control("acid_operation_"..name).active,"staging disables inline parameter: "..name)
  end
  assert(not control("acid_random_repeat").active,"staging disables Repeat last")
  before=navigation_snapshot()
  control("acid_operation_open"):fire()
  assert(draft_writes==before.drafts and render_calls==before.writes and
    control("acid_program_discard").active,"random Apply respects pending stage guard")
  app.show_prompt=function()return "Discard"end
  control("acid_program_discard"):fire()
  local main_dialog=dialog
  control("acid_label_rename"):fire()
  writes=draft_writes
  control("acid_operation_open"):fire()
  assert(draft_writes==writes,"random Apply cannot overwrite open label editor")
  control("acid_label_discard"):fire()
  dialog=main_dialog
  app.show_prompt=function()return "Cancel"end
end

do
  local scales=require("model.scales")
  local function current_source() return label_context:editor_state().source end
  local root=control("acid_scale_root")
  local category=control("acid_scale_category")
  local choice=control("acid_scale_choice")
  local search=control("acid_scale_search")
  local follow=control("acid_scale_follow")
  local importer=control("acid_scale_import")
  local source_before=assert(sequencer.copy_source(label_context:editor_state().source))
  local writes_before=draft_writes
  local history_before=button("Undo").active
  local function find_scale(name)
    for index,item in ipairs(choice.items) do
      if item==name then return index end
    end
  end
  assert(root.value==1 and not follow.value and category.items[1]=="All" and
    choice.items[1]=="Custom / current mask",
    "scale controls start at C, Custom/current mask and Follow off")
  search:fire("Major Pentatonic")
  local pentatonic_index=find_scale("Major Pentatonic")
  assert(pentatonic_index and choice.items[pentatonic_index]=="Major Pentatonic",
    "scale search finds a bundled scale by name")
  local neutral=navigation_snapshot()
  category:fire(1)
  search:fire("")
  assert_navigation_neutral(neutral,"scale browser category and search")

  source_before=assert(sequencer.copy_source(label_context:editor_state().source))
  writes_before=draft_writes
  search:fire("Major Pentatonic")
  pentatonic_index=assert(find_scale("Major Pentatonic"),"Major Pentatonic is searchable")
  choice:fire(pentatonic_index)
  local major_mask=scales.mask({intervals={0,2,4,7,9}},0)
  local selected=assert(sequencer.copy_source(label_context:editor_state().source))
  assert(selected.scale_mask_enabled and draft_writes==writes_before+1,
    "choosing a scale enables MASK as one immediate editor change")
  for index,allowed in ipairs(major_mask) do
    assert(selected.scale_mask[index]==allowed and control(string.format("acid_mask_class_%02d",index)).value==allowed,
      "the selected scale writes each pitch class into MASK")
  end
  button("Undo"):fire()
  assert(sequencer.same_source(source_before,label_context:editor_state().source),
    "one Undo restores the source before scale selection")
  button("Redo"):fire()
  assert(sequencer.same_source(selected,label_context:editor_state().source),
    "one Redo restores the selected scale mask")

  writes_before=draft_writes
  root:fire(3)
  local transposed=assert(sequencer.copy_source(label_context:editor_state().source))
  local d_mask=scales.mask({intervals={0,2,4,7,9}},2)
  assert(draft_writes==writes_before+1 and root.value==3,
    "changing root rotates the current mask as one editor change")
  for index,allowed in ipairs(d_mask) do
    assert(transposed.scale_mask[index]==allowed,"root change transposes mask class "..index)
  end
  button("Undo"):fire()
  assert(sequencer.same_source(selected,label_context:editor_state().source) and root.value==3,
    "Undo restores the mask while the session root remains selected")
  assert(choice.value==1,"mask mismatch against the current root is shown as Custom/current mask")

  root:fire(1)
  button("Undo"):fire()
  assert(sequencer.same_source(selected,label_context:editor_state().source),
    "returning the root to C and undoing its rotation restores the prior mask")
  control("acid_mask_class_03"):fire(false)
  assert(choice.value==1 or choice.items[choice.value]~="Major Pentatonic",
    "manual mask edits re-detect a matching preset or select Custom/current mask")
  button("Undo"):fire()
  assert(sequencer.same_source(selected,label_context:editor_state().source),
    "one Undo restores a manual scale mask edit")

  view:fire(1)
  control("acid_program_select_pitch_01"):fire()
  assert(control("acid_program_key_02").color~=control("acid_program_key_03").color,
    "Program keyboard highlights allowed notes with a distinct color")
  follow:fire(true)
  control("acid_program_select_pitch_05"):fire()
  control("acid_program_octave_normal"):fire()
  program_key(5):fire()
  local before_program=assert(sequencer.copy_source(label_context:editor_state().source))
  program_key(2):fire()
  local program_pitch=current_source().pitch_events[5]
  assert(program_pitch.key==0 and program_pitch.octave==0,
    "Follow snaps an equidistant chromatic Program entry down to the lower allowed pitch")
  button("Undo"):fire()
  assert(sequencer.same_source(before_program,label_context:editor_state().source),
    "Undo restores Program input constrained by Follow")
  button("Undo"):fire()

  view:fire(2)
  control("acid_grid_pitch_06"):fire()
  control("acid_grid_key_05"):fire()
  local before_grid=assert(sequencer.copy_source(label_context:editor_state().source))
  control("acid_grid_key_02"):fire()
  local grid_pitch=current_source().pitch_events[6]
  assert(grid_pitch.key==0 and grid_pitch.octave==0,
    "Follow constrains Grid pitch entry using the same nearest-note rule")
  assert(control("acid_grid_key_02").color~=control("acid_grid_key_03").color,
    "Grid keyboard highlights allowed notes with a distinct color")
  button("Undo"):fire()
  assert(sequencer.same_source(before_grid,label_context:editor_state().source),
    "Undo restores the Grid pitch before Follow-constrained entry")
  button("Undo"):fire()
  follow:fire(false)
  assert(not follow.value and control("acid_scale_detail").text:find("Follow scale off",1,true),
    "Follow toggle updates session state before chromatic entry")
  view:fire(1)
  control("acid_program_select_pitch_05"):fire()
  assert(control("acid_program_pitch_summary").text:find("P05",1,true),
    "Program selects P05 before editing: "..control("acid_program_pitch_summary").text)
  assert(program_key(5).active,
    "Program key is active before Follow-off entry: "..control("acid_status").text)
  program_key(5):fire()
  assert(current_source().pitch_events[5].key==4,
    "Program can set E before chromatic input: "..tostring(current_source().pitch_events[5].key).." / "..control("acid_status").text)
  program_key(2):fire()
  assert(current_source().pitch_events[5].key==1,
    "Program accepts chromatic input when Follow is off")
  button("Undo"):fire()
  button("Undo"):fire()
  follow:fire(true)
  control("acid_mask_enabled"):fire(false)
  program_key(5):fire()
  program_key(2):fire()
  assert(current_source().pitch_events[5].key==1,
    "Follow leaves chromatic input unconstrained while MASK is disabled")
  button("Undo"):fire()
  button("Undo"):fire()
  button("Undo"):fire()
  follow:fire(false)

  local source_before_import=assert(sequencer.copy_source(label_context:editor_state().source))
  writes_before=draft_writes
  local undo_before_import=button("Undo").active
  app.scale_import_filename="mock-scales.txt"
  local old_open=io.open
  local file_text
  io.open=function(path,mode)
    assert(path=="mock-scales.txt" and mode=="rb")
    local read=false
    return {read=function(_,limit)
      assert(limit==scales.MAX_TEXT_BYTES+1)
      if read then return nil end
      read=true
      return file_text
    end,close=function()end}
  end
  file_text="[Custom]\nIntegration Unique = 0 1 3 6 8 10\nIntegration Alias = 0, 1, 3, 6, 8, 10\n"
  importer:fire()
  assert(app.last_file_extensions[1]=="txt" and app.last_file_title=="Import custom scales",
    "custom scale import uses Renoise's TXT file picker")
  assert(tool.preferences and tool.preferences.custom_scales and
    tool.preferences.custom_scales.value:find("Integration Unique",1,true) and
    tool.preferences.custom_scales.value:find("Integration Alias",1,true),
    "valid custom scales persist in the tool preferences with aliases")
  assert(sequencer.same_source(source_before_import,label_context:editor_state().source) and
    draft_writes==writes_before and button("Undo").active==undo_before_import,
    "import changes neither the pattern, draft nor Undo history")
  search:fire("Integration Alias")
  assert(#choice.items==2 and choice.items[2]=="Integration Unique",
    "duplicate pitch-class definitions are deduplicated and searchable as aliases")
  local preferences_before_bad=tool.preferences.custom_scales.value
  app.scale_import_filename="mock-scales.txt"
  file_text="Invalid = 0 12\n"
  importer:fire()
  assert(tool.preferences.custom_scales.value==preferences_before_bad and
    sequencer.same_source(source_before_import,label_context:editor_state().source),
    "malformed import is atomic and does not alter the saved library or pattern")
  app.scale_import_filename=""
  importer:fire()
  assert(tool.preferences.custom_scales.value==preferences_before_bad and
    sequencer.same_source(source_before_import,label_context:editor_state().source),
    "canceling the Renoise file picker leaves the library and pattern unchanged")
  io.open=old_open
  app.scale_import_filename=nil

  assert(history_before==button("Undo").active,
    "scale browser and import actions do not alter the existing Undo history")
  assert(control("acid_status").text:find("Cannot import scales",1,true),
    "invalid text import reports a parser error: "..control("acid_status").text)
  assert(control("acid_scale_follow").value==false)
  assert(sequencer.same_source(source_before_import,label_context:editor_state().source),
    "scale browser and import checks leave the final pattern source unchanged")
end

dialog.visible=false
tool.app_idle_observable:fire()
assert(song.selected_phrase_observable:listener_count()==0,
  "closing ACID removes its selected-phrase observer")
assert(tool.app_idle_observable:listener_count()==0,
  "closing ACID removes its dialog idle listener")
local gui_module=require("gui")
tool.app_idle_observable.ignore_add=true
local idle_loaded,idle_error=pcall(gui_module.show)
assert(not idle_loaded and tostring(idle_error):find("idle notifier registration failed",1,true),
  "silently ineffective idle registration rejects dialog initialization")
assert(tool.app_idle_observable:listener_count()==0 and
  song.selected_phrase_observable:listener_count()==0 and
  not gui_module.get_ui_state().dialog_visible and
  not gui_module.get_ui_state().idle_listener_attached,
  "ineffective idle registration unwinds the dialog, native subscriptions and active flag")
tool.app_idle_observable.ignore_add=false
gui_module.show()
assert(gui_module.get_ui_state().dialog_visible and tool.app_idle_observable:listener_count()==1,
  "dialog reopens with one idle watcher after ineffective registration cleanup")
dialog.visible=false
tool.app_idle_observable:fire()
tool.app_idle_observable.fail_add=true
idle_loaded,idle_error=pcall(gui_module.show)
assert(not idle_loaded and tostring(idle_error):find("idle notifier registration failed",1,true),
  "idle notifier registration failure before attachment is visible")
assert(tool.app_idle_observable:listener_count()==0 and
  song.selected_phrase_observable:listener_count()==0 and
  not gui_module.get_ui_state().dialog_visible,
  "pre-attachment idle registration failure leaves no phantom notifier")
tool.app_idle_observable.fail_add=false
gui_module.show()
assert(gui_module.get_ui_state().dialog_visible and tool.app_idle_observable:listener_count()==1,
  "dialog reopens after pre-attachment idle registration failure")
dialog.visible=false
tool.app_idle_observable:fire()
tool.app_idle_observable.fail_add_after_register=true
idle_loaded,idle_error=pcall(gui_module.show)
assert(not idle_loaded and tostring(idle_error):find("idle notifier registration failed",1,true),
  "idle notifier registration failure is visible")
assert(tool.app_idle_observable:listener_count()==0 and
  song.selected_phrase_observable:listener_count()==0 and
  not gui_module.get_ui_state().dialog_visible,
  "failed idle registration unwinds dialog and native subscriptions")
tool.app_idle_observable.fail_add_after_register=false
gui_module.show()
assert(gui_module.get_ui_state().dialog_visible and tool.app_idle_observable:listener_count()==1,
  "dialog can reopen after failed idle registration cleanup")
dialog.visible=false
tool.app_idle_observable.fail_remove_after_unregister=true
tool.app_idle_observable:fire()
assert(tool.app_idle_observable:listener_count()==0 and
  not gui_module.get_ui_state().idle_listener_attached,
  "removal that unregisters before throwing retires the exact idle handler")
tool.app_idle_observable.fail_remove_after_unregister=false
gui_module.show()

local lifecycle_events={}
draft_cache.has_volatile=function() return true end
app.show_warning=function() lifecycle_events[#lifecycle_events+1]="warning" end
package.loaded["writers.phrase_writer"].release=function()
  writer_releases=writer_releases+1
  lifecycle_events[#lifecycle_events+1]="release"
end
local queued_idle_notifier=tool.app_idle_observable.notifier_history[
  #tool.app_idle_observable.notifier_history]
tool.app_release_document_observable:fire()
assert(writer_releases==1 and lifecycle_events[1]=="warning" and lifecycle_events[2]=="release",
  "document release warns about volatile drafts before releasing writer host references")
dofile("tests/acid/observer_host_fixture.lua").attach(song,observable)
require("gui").show()
assert(tool.app_idle_observable:listener_count()==1,
  "reopened ACID attaches one dialog idle listener")
local replacement_state_before_stale=gui_module.get_ui_state()
assert(replacement_state_before_stale.native_observers_attached and
  replacement_state_before_stale.native_listener_count>0,
  string.format("reopened ACID lacked native observers before stale callback (attached=%s listeners=%d error=%s)",
    tostring(replacement_state_before_stale.native_observers_attached),
    replacement_state_before_stale.native_listener_count,
    tostring(replacement_state_before_stale.native_observer_error)))
queued_idle_notifier()
local stale_callback_state=gui_module.get_ui_state()
assert(tool.app_idle_observable:listener_count()==1 and stale_callback_state.idle_listener_attached and
  stale_callback_state.native_observers_attached and stale_callback_state.native_listener_count>0,
  string.format("queued idle callback removed replacement observers (idle=%d active=%s native=%s listeners=%d)",
    tool.app_idle_observable:listener_count(),tostring(stale_callback_state.idle_listener_attached),
    tostring(stale_callback_state.native_observers_attached),stale_callback_state.native_listener_count))
gui_module.show()
assert(dialog.visible and tool.app_idle_observable:listener_count()==1,
  "replacement dialog remains functional after a stale idle callback")
tool.app_idle_observable.fail_remove=true
tool.app_release_document_observable:fire()
assert(tool.app_idle_observable:listener_count()==1,
  "failed idle listener removal retains cleanup evidence")
tool.app_idle_observable:fire()
assert(tool.app_idle_observable:listener_count()==1,
  "retained idle callback is inert after release")
tool.app_idle_observable.fail_remove=false
tool.app_new_document_observable:fire()
assert(tool.app_idle_observable:listener_count()==0,
  "new document retries and completes idle listener removal")
gui_module.show()
tool.app_idle_observable.fail_remove=true
tool.app_release_document_observable.fail_remove=true
tool.tool_will_unload_observable:fire()
assert(writer_releases==4,"tool unload releases writer host references")
assert(tool.app_idle_observable:listener_count()==1 and
  tool.app_release_document_observable:listener_count()==1 and
  tool.app_new_document_observable:listener_count()==0 and
  tool.tool_will_unload_observable:listener_count()==1,
  "tool unload retains cleanup callback after listener removal fails")
tool.app_release_document_observable.fail_remove=false
tool.tool_will_unload_observable:fire()
assert(tool.app_idle_observable:listener_count()==1 and
  tool.app_release_document_observable:listener_count()==0 and
  tool.tool_will_unload_observable:listener_count()==1,
  "unload retries root listener removal while retaining the idle cleanup retry")
tool.app_idle_observable.fail_remove=false
tool.tool_will_unload_observable:fire()
assert(tool.app_idle_observable:listener_count()==0 and
  tool.app_release_document_observable:listener_count()==0 and
  tool.app_new_document_observable:listener_count()==0 and
  tool.tool_will_unload_observable:listener_count()==0,
  "inert unload callback retries failed listener cleanup")
tool.app_release_document_observable:fire()
tool.app_new_document_observable:fire()
assert(writer_releases==4,"removed lifecycle callbacks remain inert")
assert(selection_assignment_attempts==0,"ACID never attempts to assign read-only native selection")
print("ACID Program/Grid views, native phrase selection and Live Edit destination checks passed")
