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
  local default_size={width=0,height=0}
  local sizes=setmetatable({},{__mode="k"})
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
    setmetatable(node,{__index=function(view,key)
      if key=="size" then return sizes[view] or default_size end
    end,__newindex=function(view,key,value)
      if key=="size" then sizes[view]=value~=default_size and value or nil
      else rawset(view,key,value) end
    end})
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
    function node:update()
      assert(self.kind=="canvas")
      self.render({size=self.size,stroke_rect=function() end})
    end
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
local phrase_two={id=12,name="ACID 0.1 #12 [v3:00000000]",invalid_seal=true}
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
function app:show_prompt(title,_,buttons)
  assert(title=="Reset Pattern" and buttons[2]=="Reset")
  return "Reset"
end

local persisted_drafts={}
local fail_draft_persistence=false
local committed_entries={}
local next_revision_id=100
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
local valid_label=require("renoise.pattern_store").valid_label
package.loaded["renoise.pattern_store"]={valid_label=valid_label,load=function(_,instrument,phrase)
  local entry=committed_entries[phrase.id]
  if not entry then
    local source=sequencer.new_pattern(16)
    store_entry(phrase.id,source,"repeat",phrase.id==11 and 2 or phrase.id==12 and 48 or 0)
    entry=committed_entries[phrase.id]
  end
  return assert(sequencer.copy_source(entry.source)),entry.policy,entry.pb_range
end,
  read_entry=read_entry,
  write_draft_metadata=function(song,instrument,phrase,pattern,policy,pb_range)
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
  status=function(phrase)
    if phrase.foreign then return "foreign" end
    return phrase.invalid_seal and "modified" or "owned"
  end,
  id=function(phrase)if phrase.foreign then return nil end;return phrase.id end,
  snapshot_index=function()return nil end,
  capture_recovery=function()return {} end,
}
local active_request
local sync_next_result
local sync_next_message
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
  call.completed=false
  local status=sync_next_result or "committed"
  sync_next_result=nil
  local message=sync_next_message
  sync_next_message=nil
  local result=terminal_result(call,status,message)
  active_request=nil
  call.completed=true
  done(result)
  tool.app_idle_observable:fire()
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
local function saved_pitch(phrase_id,index)
  local entry=assert(persisted_drafts["1:"..phrase_id],"missing persisted phrase draft")
  return entry.pattern.pitch_events[index]
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
assert(phrase_choice.items[2]:find("%(tagged%)$") and
  not phrase_choice.items[2]:find("%(ACID%)"),
  "a recognized ID with an invalid seal is labeled tagged, not verified ownership: "..
    tostring(phrase_choice.items[2]))
phrase_two.name="Owned two"
phrase_two.invalid_seal=nil
assert(pb_range_popup(builder).value==2,"the selected phrase restores its stored PB Range")
pitch_key(builder,2):fire()
phrase_choice:fire(2)
assert(pb_range_popup(builder).value==5,"switching phrases restores that phrase's PB Range")
pitch_key(builder,3):fire()
phrase_choice:fire(1)
assert(saved_pitch(11,1).key==1,
  "switching phrases restores the unsaved draft for phrase one")
assert(pb_range_popup(builder).value==2,
  "switching phrases restores the unsaved PB Range draft for phrase one")
phrase_choice:fire(2)
assert(saved_pitch(12,1).key==2,
  "switching back restores the separate phrase two draft")

dialog.visible=false
tool.app_idle_observable:fire()
builder,dialog=open_gui()
phrase_choice=popup(builder,360)
assert(saved_pitch(11,1).key==1,
  "closing and reopening the editor recovers the phrase one draft")
local recovered_status=builder.views.acid_status
assert(recovered_status.text=="",
  "successful draft restoration leaves shared feedback empty: "..tostring(recovered_status.text))
builder.views.acid_program_select_pitch_01:fire()
assert(builder.views.acid_program_select_pitch_01.tooltip:find("key C#",1,true),
  "reopened Program control reflects the restored pitch")
pitch_key(builder,3):fire()
assert(saved_pitch(11,1).key==2 and
  builder.views.acid_program_select_pitch_01.tooltip:find("key D",1,true),
  "a post-reopen pitch edit updates the saved draft and Program control")
pitch_key(builder,2):fire()
assert(saved_pitch(11,1).key==1 and
  builder.views.acid_program_select_pitch_01.tooltip:find("key C#",1,true),
  "editing back to the restored pitch updates the saved draft and Program control")
assert(pb_range_popup(builder).value==2,
  "closing and reopening the editor recovers the phrase one's PB Range")
tool.app_release_document_observable:fire()
assert(#warnings==0,"song-persistent drafts do not show a loss warning")
dialog.visible=false
builder,dialog=open_gui()
phrase_choice=popup(builder,360)
recovered_status=builder.views.acid_status
pb_range_popup(builder):fire(1)
button(builder,"Undo"):fire()
assert(pb_range_popup(builder).value==2,"Undo restores the previous PB Range")
button(builder,"Redo"):fire()
assert(pb_range_popup(builder).value==1,"Redo restores the changed PB Range")
fail_draft_persistence=true
local timing=builder.views.acid_timing
timing:fire(timing.value==1 and 2 or 1)
assert(recovered_status.text:find("Your latest edits could not be saved with the song.",1,true),
  recovered_status.text)
tool.app_release_document_observable:fire()
assert(#warnings==1 and warnings[1]:find("could not be saved",1,true),
  "volatile draft persistence failure warns before song close")
fail_draft_persistence=false
dialog.visible=false
builder,dialog=open_gui()
phrase_choice=popup(builder,360)
pb_range_popup(builder):fire(3)
builder.views.acid_editor_view:fire(2)
builder.views.acid_grid_pitch_02:fire()
builder.views.acid_editor_view:fire(1)

local live_checkbox=builder.views.acid_live_edit
assert(live_checkbox,"Live Edit checkbox was not created")
local status=builder.views.acid_status
local writer_count=#tool.writer_calls
live_checkbox:fire(true)
assert(#tool.writer_calls==writer_count,"arming Live Edit does not write")

local long_diagnostic=string.rep("TIME step 05: SLIDE approximated; ",40)
sync_next_result="error"
sync_next_message=long_diagnostic
pitch_key(builder,5):fire()
local first=tool.writer_calls[#tool.writer_calls]
assert(#tool.writer_calls==writer_count+1 and first.completed and active_request==nil,
  "Live Edit admission and completion finish inside the source-edit callback")
assert(first.options.pb_range==12,"Live Edit uses the selected target PB Range")
assert(live_checkbox.value and status.text=="Couldn't update the phrase. Try again." and
  not status.text:find(long_diagnostic,1,true),
  "a synchronous writer error keeps Live Edit armed and hides raw diagnostics")
tool.app_idle_observable:fire()
assert(#tool.writer_calls==writer_count+1,
  "idle does not retry a completed Live Edit failure")

sync_next_result="error"
pitch_key(builder,6):fire()
local second=tool.writer_calls[#tool.writer_calls]
assert(#tool.writer_calls==writer_count+2 and second.completed and active_request==nil and
  not require("model.sequencer").same_source(first.request.source,second.request.source),
  "a later edit admits one synchronous request with the newer source")

local calls_before_navigation=#tool.writer_calls
phrase_choice:fire(2)
assert(#tool.writer_calls==calls_before_navigation and pb_range_popup(builder).value==5,
  "destination navigation restores its PB Range without generating")
sync_next_result="error"
pitch_key(builder,2):fire()
local third=tool.writer_calls[#tool.writer_calls]
assert(#tool.writer_calls==calls_before_navigation+1 and third.completed and
  third.options.pb_range==48 and live_checkbox.value,
  "Live Edit uses the selected owned phrase and remains armed after failure")

live_checkbox:fire(false)
local calls_before_disarm_edit=#tool.writer_calls
pitch_key(builder,3):fire()
assert(#tool.writer_calls==calls_before_disarm_edit,
  "disarming Live Edit prevents automatic writes")
live_checkbox:fire(true)
assert(#tool.writer_calls==calls_before_disarm_edit,
  "rearming Live Edit waits for a new source edit")
sync_next_result="error"
pitch_key(builder,4):fire()
assert(#tool.writer_calls==calls_before_disarm_edit+1 and
  tool.writer_calls[#tool.writer_calls].request.trigger=="live" and
  tool.writer_calls[#tool.writer_calls].completed,
  "a new edit starts one current synchronous Live Edit request")
live_checkbox:fire(false)
print("ACID GUI synchronous Live Edit lifecycle checks passed")
