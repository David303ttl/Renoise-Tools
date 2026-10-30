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
    if fail_draft_clear then return nil,"test cleanup failure" end
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
    phrase=success and phrase or nil,reason=success and nil or (message or "fixture complete"),
    message=message or "fixture complete"}
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
  tool.writer_calls[#tool.writer_calls+1]=call
  if kind=="create" then
    call.target=#request.instrument.phrases+1
  else
    for index,phrase in ipairs(request.instrument.phrases) do
      if rawequal(phrase,request.phrase) then call.target=index;break end
    end
  end
  if kind=="regenerate" then
    request:mutate(request.token,function() song.selected_phrase_observable:fire() end)
    assert(request.token:is_current(),"internal selection notification preserves authorization")
  end
  active_request=request
  render_callbacks[#render_callbacks+1]=function(result)
    active_request=nil
    done(result)
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
local context_module=require("runtime.context")
local original_new=context_module.new
local contexts,admissions={},{}
context_module.new=function(options)
  local context=original_new(options)
  contexts[#contexts+1]=context
  local request=context.request_generation
  function context:request_generation(trigger)
    local accepted,reason=request(self,trigger)
    admissions[#admissions+1]={trigger=trigger,accepted=accepted,reason=reason,context=self}
    return accepted,reason
  end
  return context
end
local function live_control(builder)
  local selected
  for _,node in ipairs(builder.nodes) do
    if node.kind=="checkbox" then selected=node end
  end
  return assert(selected,"missing Live Edit checkbox")
end
local function complete(index,status)
  local call=tool.writer_calls[index]
  render_callbacks[index](terminal_result(call,status))
end

local builder,dialog=open_gui()
assert(#contexts==1,"GUI must install one runtime context")
assert(#admissions==0 and #tool.writer_calls==0,"opening must not request generation")
local phrase_popup=popup(builder,360)
local live=live_control(builder)
live:fire(true)
phrase_popup:fire(2)
phrase_popup:fire(1)
builder.views.acid_editor_view:fire(2)
builder.views.acid_editor_view:fire(1)
button(builder,"Reset Source"):fire()
builder.views.acid_timing:fire(builder.views.acid_timing.value)
builder.views.acid_pb_range:fire(builder.views.acid_pb_range.value)
assert(#admissions==0 and #tool.writer_calls==0,
  "arming, target/source restoration, view navigation, reset and no-op edits must make zero requests")

button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==1 and #admissions==1 and admissions[1].trigger=="manual",
  "manual Generate must enter runtime admission: "..tostring(admissions[#admissions] and admissions[#admissions].reason))
local manual=tool.writer_calls[1]
assert(manual.options.token:is_current() and manual.target==1)
builder.views.acid_timing:fire(builder.views.acid_timing.value)
assert(#admissions==1 and manual.options.token:is_current(),
  "an in-flight no-op edit neither enqueues nor revokes the admitted request")
complete(1)
builder.views.acid_program_key_popup:fire(2)
assert(#tool.writer_calls==2 and #admissions==2 and admissions[2].trigger=="live",
  "armed real edits must enter the same runtime admission")
assert(rawequal(admissions[1].context,admissions[2].context),"manual and live share one runtime authority")
local stale=tool.writer_calls[2]
assert(stale.options.token:is_current() and not rawequal(manual.options.token,stale.options.token),
  "runtime issues a distinct operation token for each admitted request")

dialog.visible=false
tool.app_idle_observable:fire()
assert(not stale.options.token:is_current(),"closing revokes the old runtime request")
local admission_count=#admissions
builder,dialog=open_gui()
assert(#contexts==1,"reopening retains the same runtime authority")
assert(#admissions==admission_count,"reopen and draft restoration request nothing")
local state_before=builder.views.acid_source_state.text
local target_before=popup(builder,360).value
complete(2)
assert(builder.views.acid_source_state.text==state_before and popup(builder,360).value==target_before,
  "old-session completion must not update reopened widgets or destination")

local context=contexts[#contexts]
local original=instrument.phrases[1]
instrument.phrases[1]={id=91,name="replacement",foreign=true}
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==2,"removed same-index target must reject without append")
instrument.phrases[1]=original
popup(builder,290):fire(2)
popup(builder,360):fire(2)
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==2,"foreign manual destination must reject without append")
live_control(builder):fire(true)
builder.views.acid_program_key_popup:fire(3)
assert(#tool.writer_calls==2,"foreign Live Edit must reject without append")

popup(builder,360):fire(3)
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==3 and tool.writer_calls[3].target==3,
  "only explicitly selected New authorizes append")
assert(tool.writer_calls[3].options.token:is_current(),"New uses runtime-issued authorization")
complete(3,"error")
live_control(builder):fire(false)
popup(builder,290):fire(1)
popup(builder,360):fire(1)
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==4)
builder.views.acid_program_key_popup:fire(5)
local dirty_state=builder.views.acid_source_state.text
assert(not tool.writer_calls[4].options.token:is_current(),"real edits revoke a prior manual request")
complete(4)
assert(builder.views.acid_source_state.text==dirty_state and
  require("runtime.draft_cache").get(song,instrument,original),
  "same-session stale completion preserves current widgets and newer draft")
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==5)
assert(context:record_blocker(tool.writer_calls[5].options.token,{reason="fixture recovery evidence"}))
complete(5,"error")
assert(context:integrity_state().blocked)
dialog.visible=false
tool.app_idle_observable:fire()
builder,dialog=open_gui()
assert(#contexts==1 and context:integrity_state().blocked,
  "closing and reopening cannot clear a song integrity blocker")
local blocked_count=#tool.writer_calls
button(builder,"Generate / Regenerate ACID Phrase"):fire()
assert(#tool.writer_calls==blocked_count,"a reopened integrity blocker still rejects generation")
print("acid GUI runtime admission specs passed")