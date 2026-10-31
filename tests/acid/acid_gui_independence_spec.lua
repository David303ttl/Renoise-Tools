local fixture=dofile("tests/acid/runtime_phrase_fixture.lua")
local ownership=require("renoise.phrase_ownership")
local store=require("renoise.pattern_store")
local seq=require("model.sequencer")
local EDITED_PITCH_KEY=5
local song,instrument,original,_,source=fixture.fixture()
source.pitch_events[1]=seq.new_pitch(4,0,true,false)
original=fixture.phrase(source,101)
instrument.phrases={original,fixture.phrase(source,102)}
assert(store.save(song,101,source,"play_once",0))
assert(store.save(song,102,source,"play_once",0))
local duplicate=fixture.phrase(source,101)
local note_equal={__eq=function() return true end}
setmetatable(original,note_equal)
setmetatable(duplicate,note_equal)
instrument.phrases[#instrument.phrases+1]=duplicate
song.selected_instrument_index=1
song.selected_instrument=instrument
song.selected_phrase=duplicate
local selected_phrase=song.selected_phrase
local selection_assignments=0
song.selected_phrase=nil
setmetatable(song,{__index=function(_,key)
  if key=="selected_phrase" then return selected_phrase end
end,__newindex=function(target,key,value)
  if key=="selected_phrase" then
    selection_assignments=selection_assignments+1
    selected_phrase=value
  elseif key=="selected_phrase_index" then
    selection_assignments=selection_assignments+1
  else rawset(target,key,value) end
end})

local function observable()
  local handlers,history={},{}
  return {add_notifier=function(_,fn)handlers[fn]=true;history[#history+1]=fn end,
    remove_notifier=function(_,fn)handlers[fn]=nil end,
    fire_stale=function()
      local pending={};for _,fn in ipairs(history)do pending[#pending+1]=fn end
      for _,fn in ipairs(pending)do fn()end
    end,
    fire=function()
      local pending={};for fn in pairs(handlers)do pending[#pending+1]=fn end
      for _,fn in ipairs(pending)do if handlers[fn]then fn()end end
    end}
end
song.selected_phrase_observable=observable()
song.instruments_observable=observable()
instrument.name_observable=observable()
instrument.phrases_observable=observable()
local tool={app_new_document_observable=observable(),app_release_document_observable=observable(),
  app_idle_observable=observable()}
local builder={views={},nodes={}}
setmetatable(builder,{__index=function(_,kind)return function(_,properties)
  local node={kind=kind,children={},notifiers={}}
  for key,value in pairs(properties or {})do node[key]=value end
  function node:add_child(child)self.children[#self.children+1]=child end
  function node:add_notifier(fn)self.notifiers[#self.notifiers+1]=fn end
  function node:fire(value)
    if value~=nil then self.value=value end
    if self.notifier then self.notifier(value)end
    for _,fn in ipairs(self.notifiers)do fn(value)end
  end
  if node.id then builder.views[node.id]=node end
  builder.nodes[#builder.nodes+1]=node
  return node
end end})
local dialog
local app={show_warning=function()end,show_custom_dialog=function()
  dialog={visible=true,show=function()end,close=function(self)self.visible=false end}
  return dialog
end}
renoise.song=function()return song end
renoise.tool=function()return tool end
renoise.app=function()return app end
renoise.ViewBuilder=function()return builder end
local writes=0
local last_writer_request
local writer_status="idle"
package.loaded["writers.phrase_writer"]={state=function()return writer_status,nil end,
  is_temporary=function()return false end,release=function()end,
  create=function(request)
    writes=writes+1;last_writer_request=request;return false,"unexpected render"
  end,
  regenerate=function(request)
    writes=writes+1;last_writer_request=request;return false,"unexpected render"
  end}
local before=assert(ownership.snapshot(duplicate))
local original_before=assert(ownership.snapshot(original))
local context_module=require("runtime.context")
local original_context_new=context_module.new
local close_calls=0
context_module.new=function(options)
  local runtime=original_context_new(options)
  local make_independent=runtime.make_independent
  local close_dialog=runtime.close_dialog
  runtime.close_dialog=function(self,...)
    close_calls=close_calls+1
    return close_dialog(self,...)
  end
  local resolved=0
  runtime.make_independent=function(self,...)
    if resolved==0 then
      local changed,result=make_independent(self,...)
      if changed then resolved=resolved+1 end
      return changed,result
    end
    local transition=self.transition
    self.transition=function(context,kind,...)
      if kind=="refresh" then return nil,"injected post-commit reconciliation failure" end
      return transition(context,kind,...)
    end
    local changed,result=make_independent(self,...)
    self.transition=transition
    return changed,result
  end
  return runtime
end
require("gui").show()
context_module.new=original_context_new
local independent=assert(builder.views.acid_make_independent)
assert(independent.active,"a matching selected collision offers Make Independent")
assert(writes==0,"opening a collision does not generate")
local live
for _,node in ipairs(builder.nodes)do
  if node.kind=="checkbox" and not node.id then live=node end
end
assert(live)
live:fire(true)
local duplicate_name,source_bytes=duplicate.name,song.tool_data
writer_status="busy"
independent:fire()
assert(duplicate.name==duplicate_name and song.tool_data==source_bytes,
  "cached GUI eligibility authorized Make Independent while the writer was occupied")
assert(writes==0,"occupied Make Independent entered the musical writer")
writer_status="idle"
independent:fire()
local fresh=ownership.id(duplicate)
assert(fresh and fresh~=101 and ownership.id(original)==101)
assert(ownership.compare(before,assert(ownership.snapshot(duplicate)),"name"))
assert(ownership.compare(original_before,assert(ownership.snapshot(original))))
assert(seq.same_source(assert(store.read_entry(song,fresh)),source))
assert(independent.active==false,"a resolved unique target cannot be rekeyed again")
assert(builder.views.acid_source_state.text=="SOURCE COMMITTED",
  "resolution replaces the unavailable placeholder with committed source status: "..
    tostring(builder.views.acid_source_state.text))
assert(builder.views.acid_program_key_popup.value==source.pitch_events[1].key+1,
  "the independent phrase projects its cloned source")
assert(live.value and writes==0,"armed Make Independent never enters the musical writer")
local phrase_choice
for _,node in ipairs(builder.nodes)do
  if node.kind=="popup" and node.width==360 then phrase_choice=node end
end
assert(phrase_choice.value==3,"resolution keeps the selected object bound")
builder.views.acid_program_key_popup:fire(EDITED_PITCH_KEY+1)
tool.app_idle_observable:fire()
assert(writes==1 and last_writer_request.kind=="regenerate" and
    rawequal(last_writer_request.phrase,duplicate),
  "a new armed source edit regenerates only the exact independent phrase")
local blocked_duplicate=fixture.phrase(source,fresh)
instrument.phrases[#instrument.phrases+1]=blocked_duplicate
instrument.phrases_observable:fire()
tool.app_idle_observable:fire()
assert(independent.active,"a new copied-ID collision offers resolution")
independent:fire()
local status
for _,node in ipairs(builder.nodes)do
  if node.kind=="multiline_textfield" then status=node end
end
assert(status and status.text:find("Selected phrase is independent.",1,true) and
    status.text:find("injected post-commit reconciliation failure",1,true),
  "GUI distinguishes a committed identity from its visible recovery warning")
assert(not independent.active,"a blocked committed identity cannot authorize another resolution")
local generate
for _,node in ipairs(builder.nodes)do
  if node.kind=="button" and node.text=="Generate / Regenerate ACID Phrase" then generate=node end
end
assert(generate)
generate:fire()
assert(writes==1,"blocked committed outcome cannot enter the musical writer")
instrument.phrases[3]=nil
instrument.phrases_observable:fire()
tool.app_idle_observable:fire()
assert(phrase_choice.items[phrase_choice.value]=="Unavailable bound phrase",
  "native removal leaves the exact missing target unavailable")
assert(writes==1 and not independent.active)
song.instruments={}
song.instruments_observable:fire()
tool.app_idle_observable:fire()
local instrument_choice
for _,node in ipairs(builder.nodes)do
  if node.kind=="popup" and node.width==290 then instrument_choice=node end
end
assert(instrument_choice.items[instrument_choice.value]=="Unavailable bound instrument",
  "removing the bound instrument preserves its unavailable identity")
assert(writes==1 and not independent.active)
local live_value=live.value
live.value=nil
setmetatable(live,{__index=function(_,key)
  if key=="value" then return live_value end
end,__newindex=function(node,key,value)
  if key=="value" then
    live_value=value
    tool.app_idle_observable:fire()
  else rawset(node,key,value) end
end})
dialog.visible=false
tool.app_idle_observable:fire()
assert(close_calls==1,"closing the dialog closes its runtime session once")
assert(live_value==false,"close disarms Live Edit even when checkbox updates reenter idle")
tool.app_idle_observable:fire()
assert(close_calls==1,"a removed idle callback cannot close a session again")
local closed_dialog=dialog
song.instruments={instrument}
song.selected_instrument_index=1
song.selected_instrument=instrument
require("gui").show()
assert(dialog~=closed_dialog and dialog.visible,"the GUI opens a fresh dialog session")
local fresh_dialog=dialog
tool.app_idle_observable:fire_stale()
assert(dialog==fresh_dialog and dialog.visible and close_calls==1,
  "a stale idle callback cannot close or update a reopened dialog session")
dialog.visible=false
tool.app_idle_observable:fire()
assert(close_calls==2,"the reopened dialog closes its own runtime session")
assert(selection_assignments==0,"GUI identity resolution never assigns native selection")
print("ACID GUI explicit collision resolution passed (mocked Renoise)")
