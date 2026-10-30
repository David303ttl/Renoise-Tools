local fixture=dofile("tests/acid/runtime_phrase_fixture.lua")
local ownership=require("renoise.phrase_ownership")
local store=require("renoise.pattern_store")
local seq=require("model.sequencer")
local song,instrument,original,_,source=fixture.fixture()
source.pitch_events[1]=seq.new_pitch(4,0,true,false)
original=fixture.phrase(source,101)
instrument.phrases={original,fixture.phrase(source,102)}
assert(store.save(song,101,source,"play_once",0))
assert(store.save(song,102,source,"play_once",0))
local duplicate=fixture.phrase(source,101)
instrument.phrases[#instrument.phrases+1]=duplicate
song.selected_instrument_index=1
song.selected_instrument=instrument
song.selected_phrase=duplicate

local function observable()
  local handlers={}
  return {add_notifier=function(_,fn)handlers[fn]=true end,
    remove_notifier=function(_,fn)handlers[fn]=nil end,
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
package.loaded["writers.phrase_writer"]={state=function()return "idle",nil end,
  is_temporary=function()return false end,release=function()end,
  create=function()writes=writes+1;return false,"unexpected render" end,
  regenerate=function()writes=writes+1;return false,"unexpected render" end}
local before=assert(ownership.snapshot(duplicate))
local original_before=assert(ownership.snapshot(original))
require("gui").show()
local independent=assert(builder.views.acid_make_independent)
assert(independent.active,"a matching selected collision offers Make Independent")
assert(writes==0,"opening a collision does not generate")
local live
for _,node in ipairs(builder.nodes)do
  if node.kind=="checkbox" and not node.id then live=node end
end
assert(live)
live:fire(true)
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
instrument.phrases[3]=nil
instrument.phrases_observable:fire()
tool.app_idle_observable:fire()
assert(phrase_choice.items[phrase_choice.value]=="Unavailable bound phrase",
  "native removal leaves the exact missing target unavailable")
assert(writes==0 and not independent.active)
song.instruments={}
song.instruments_observable:fire()
tool.app_idle_observable:fire()
local instrument_choice
for _,node in ipairs(builder.nodes)do
  if node.kind=="popup" and node.width==290 then instrument_choice=node end
end
assert(instrument_choice.items[instrument_choice.value]=="Unavailable bound instrument",
  "removing the bound instrument preserves its unavailable identity")
assert(writes==0 and not independent.active)
dialog.visible=false
tool.app_idle_observable:fire()
print("ACID GUI explicit collision resolution passed (mocked Renoise)")
