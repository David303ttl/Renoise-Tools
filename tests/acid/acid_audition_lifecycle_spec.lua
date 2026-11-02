dofile("tests/bootstrap.lua")("acid")

local SEQUENCER, MASTER, SEND, GROUP = 1, 2, 3, 4
local NOTE, VOLUME, INTERVAL = 43, 0.8, 120
renoise = {Track={TRACK_TYPE_SEQUENCER=SEQUENCER,
  TRACK_TYPE_MASTER=MASTER, TRACK_TYPE_SEND=SEND, TRACK_TYPE_GROUP=GROUP}}
local audition = require("runtime.audition")

local function observable()
  local handlers = {}
  local result = {fail_add=false,fail_remove=false}
  function result:add_notifier(fn)
    assert(not handlers[fn], "duplicate observer")
    if self.fail_add then error("observer attach failed") end
    if self.skip_add then return end
    if self.before_add then self.before_add() end
    handlers[fn] = true
    if self.on_add then self.on_add() end
  end
  function result:has_notifier(fn) return handlers[fn] == true end
  function result:remove_notifier(fn)
    assert(handlers[fn], "removed missing observer")
    if self.fail_remove then error("observer detach failed")end
    handlers[fn] = nil
  end
  function result:fire()
    local pending = {}
    for fn in pairs(handlers) do pending[#pending+1] = fn end
    for _,fn in ipairs(pending) do if handlers[fn] then fn() end end
  end
  function result:count()
    local count=0; for _ in pairs(handlers) do count=count+1 end; return count
  end
  return result
end

local function fixture()
  local f = {calls={},timers={},timer_removals=0,outcomes={},modal=false}
  local instrument,track = {},{type=SEQUENCER,name="Lead"}
  local song = {instruments={instrument},tracks={track},
    selected_instrument=instrument,selected_track=track,
    instruments_observable=observable(),tracks_observable=observable(),
    selected_instrument_observable=observable(),selected_track_observable=observable()}
  f.song,f.instrument,f.track,f.current = song,instrument,track,song
  local tool = {app_release_document_observable=observable(),
    app_new_document_observable=observable(),tool_will_unload_observable=observable()}
  f.tool=tool
  function song:trigger_instrument_note_on(i,t,n,v)
    f.calls[#f.calls+1]={kind="on",i=i,t=t,n=n,v=v}
    if f.on_hook then f.on_hook() end
    if f.fail_on then error("onset failed") end
  end
  function song:trigger_instrument_note_off(i,t,n)
    f.calls[#f.calls+1]={kind="off",i=i,t=t,n=n}
    if f.fail_off then error("release failed") end
  end
  function tool:has_timer(fn) return f.timers[fn]~=nil end
  function tool:add_timer(fn,interval)
    assert(interval==INTERVAL,"nominal interval")
    assert(not f.timers[fn],"duplicate timer")
    if f.fail_timer then error("timer attach failed") end
    if f.skip_timer then return end
    if f.before_timer then f.before_timer() end
    f.timers[fn]=interval
  end
  function tool:remove_timer(fn)
    assert(f.timers[fn],"removed missing timer")
    if f.fail_timer_remove then error("timer detach failed")end
    f.timer_removals=f.timer_removals+1
    f.timers[fn]=nil
  end
  function f:tick()
    if self.modal then return end
    local pending={};for fn in pairs(self.timers)do pending[#pending+1]=fn end
    for _,fn in ipairs(pending)do if self.timers[fn]then fn()end end
  end
  f.owner=audition.new({song=function()return f.current end,tool=tool,
    on_outcome=function(outcome)f.outcomes[#f.outcomes+1]=outcome end})
  function f:clean()
    assert(not self.owner:active(),"audition remains active")
    assert(next(self.timers)==nil,"timer retained")
    for _,ob in ipairs({song.instruments_observable,song.tracks_observable,
      song.selected_instrument_observable,song.selected_track_observable,
      tool.app_release_document_observable,tool.app_new_document_observable,
      tool.tool_will_unload_observable})do assert(ob:count()==0,"observer retained")end
  end
  return f
end

local function call(f,index,kind,i,t)
  local value=assert(f.calls[index],"missing note call")
  assert(value.kind==kind and value.i==i and value.t==t and value.n==NOTE,
    "wrong captured note tuple")
  if kind=="on"then assert(value.v==VOLUME,"preview volume")end
end

do
  local f=fixture()
  table.insert(f.song.instruments,1,{})
  table.insert(f.song.tracks,1,{type=SEQUENCER})
  assert(f.owner:start(NOTE));call(f,1,"on",2,2)
  table.insert(f.song.instruments,1,{})
  table.insert(f.song.tracks,1,{type=SEQUENCER})
  f.track.name="Renamed"
  f.song.instruments_observable:fire();f.song.tracks_observable:fire()
  assert(f.owner:active(),"membership-preserving changes released audition")
  f:tick();call(f,2,"off",3,3)
  f:clean();assert(f.timer_removals==1)
  assert(f.owner:release("again"));assert(#f.calls==2)
  local outcome=f.owner:last_outcome()
  assert(outcome.onset_attempted and outcome.onset_ok and outcome.release_attempted and outcome.release_ok)
end

do
  local f=fixture()
  f.tool.app_new_document_observable.on_add=function()
    table.insert(f.song.instruments,1,{})
    table.insert(f.song.tracks,1,{type=MASTER})
  end
  assert(f.owner:start(NOTE));call(f,1,"on",2,2)
  f:tick();f:clean();call(f,2,"off",2,2)
end

for _,track_type in ipairs({SEQUENCER,MASTER,GROUP})do
  local f=fixture();f.track.type=track_type
  assert(f.owner:start(NOTE));assert(f.owner:close());f:clean()
  call(f,2,"off",1,1)
end

for _,invalid in ipairs({"send","foreign instrument","foreign track","no song","bad note"})do
  local f=fixture();local note=NOTE
  if invalid=="send"then f.track.type=SEND
  elseif invalid=="foreign instrument"then f.song.selected_instrument={}
  elseif invalid=="foreign track"then f.song.selected_track={type=SEQUENCER}
  elseif invalid=="no song"then f.current=nil
  else note=61 end
  assert(not f.owner:start(note),invalid.." admitted")
  assert(#f.calls==0,invalid.." invoked host");f:clean()
end

for _,removed in ipairs({"instrument","track","song","send conversion"})do
  local f=fixture();assert(f.owner:start(NOTE))
  if removed=="instrument"then
    f.song.instruments[1]={};f.song.instruments_observable:fire()
  elseif removed=="track"then
    f.song.tracks[1]={type=SEQUENCER};f.song.tracks_observable:fire()
  elseif removed=="song"then
    f.current={};f.tool.app_new_document_observable:fire()
  else f.track.type=SEND;f.song.tracks_observable:fire()end
  f:tick();f:clean()
  assert(#f.calls==1,"note-off sent to absent or ineligible identity")
  assert(f.owner:last_outcome().release_error,"missing best-effort release failure")
end

for _,event in ipairs({"modal","navigation","close","document release","new document","unload"})do
  local f=fixture();assert(f.owner:start(NOTE))
  if event=="document release"then f.tool.app_release_document_observable:fire()
  elseif event=="new document"then f.tool.app_new_document_observable:fire()
  elseif event=="unload"then f.owner:close()
  elseif event=="close"then f.owner:close()
  else assert(f.owner:release(event))end
  f.modal=true;f:tick();f:clean();call(f,2,"off",1,1)
  assert(f.timer_removals==1);assert(#f.calls==2)
end

do
  local f=fixture();assert(f.owner:start(NOTE));f.modal=true;f:tick()
  assert(f.owner:active()and #f.calls==1,"mock modal callback suppression")
  assert(f.owner:release("modal"));f:clean();call(f,2,"off",1,1)
end

do
  local f=fixture();assert(f.owner:start(NOTE));assert(f.owner:start(NOTE))
  call(f,1,"on",1,1);call(f,2,"off",1,1);call(f,3,"on",1,1)
  f:tick();f:clean();call(f,4,"off",1,1);assert(f.timer_removals==2)
end

for _,fault in ipairs({"onset","onset and release","timer","observer","release"})do
  local f=fixture()
  f.fail_on=fault=="onset"or fault=="onset and release"
  f.fail_off=fault=="release"or fault=="onset and release"
  f.fail_timer=fault=="timer"
  if fault=="observer"then f.song.tracks_observable.fail_add=true end
  local ok=f.owner:start(NOTE)
  if fault=="release"then assert(ok);f:tick()else assert(not ok,fault.." accepted")end
  f:clean()
  local outcome=assert(f.owner:last_outcome())
  if f.fail_on then
    assert(outcome.onset_attempted and not outcome.onset_ok and outcome.onset_error)
    assert(outcome.release_attempted,"onset failure skipped release")
  end
  if f.fail_off then assert(not outcome.release_ok and outcome.release_error)end
  local count=#f.calls;f:tick();f.owner:release("again");assert(#f.calls==count)
end

do
  local f=fixture();f.fail_on=true
  f.on_hook=function()f.song.instruments[1]={}end
  assert(not f.owner:start(NOTE));f:clean()
  assert(#f.calls==1,"onset exception released replacement")
  local outcome=f.owner:last_outcome()
  assert(outcome.onset_error and outcome.release_error,"lost onset or cleanup failure")
end

for _,fault in ipairs({"timer detach","observer detach"})do
  local f=fixture();assert(f.owner:start(NOTE))
  local stale_timer=next(f.timers)
  if fault=="timer detach"then f.fail_timer_remove=true
  else f.song.tracks_observable.fail_remove=true end
  assert(not f.owner:release(fault),"cleanup failure hidden")
  assert(not f.owner:active())
  local outcome=f.owner:last_outcome()
  assert(outcome.onset_ok and outcome.release_ok and #outcome.cleanup_errors==1)
  call(f,2,"off",1,1)
  stale_timer();f.song.tracks_observable:fire()
  assert(#f.calls==2,"detached lifecycle callback repeated release")
  if fault=="timer detach"then
    f.fail_timer_remove=false;f.tool:remove_timer(stale_timer)
  else
    assert(next(f.timers)==nil)
    assert(f.song.instruments_observable:count()==0)
    assert(f.tool.app_release_document_observable:count()==0)
    assert(f.tool.app_new_document_observable:count()==0)
  end
end

do
  local f=fixture();assert(f.owner:close())
  assert(not f.owner:start(NOTE),"closed owner restarted")
  assert(#f.calls==0);f:clean()
end

for _,registration in ipairs({"observer", "timer"})do
  local f=fixture()
  if registration=="observer"then f.song.tracks_observable.skip_add=true
  else f.skip_timer=true end
  assert(not f.owner:start(NOTE),"missing registration accepted")
  f:clean()
  local outcome=assert(f.owner:last_outcome())
  assert(outcome.onset_error)
  assert(#f.calls==(registration=="observer"and 0 or 2))
end

for _,registration in ipairs({"observer", "timer"})do
  local f=fixture()
  local release=function()assert(f.owner:release("registration callback"))end
  if registration=="observer"then f.song.tracks_observable.before_add=release
  else f.before_timer=release end
  assert(not f.owner:start(NOTE),"released registration accepted")
  f:clean()
  assert(#f.calls==(registration=="observer"and 0 or 2))
end

do
  local f=fixture()
  f.on_hook=function()
    assert(not f.owner:start(NOTE),"reentrant onset accepted")
    assert(f.owner:release("onset callback"))
  end
  assert(not f.owner:start(NOTE));f:clean()
  assert(#f.calls==2)
  assert(f.owner:last_outcome().onset_error)
end

do
  local f=fixture()
  f.owner=audition.new({song=function()return f.current end,tool=f.tool,
    on_outcome=function()assert(not f.owner:start(NOTE),"reentrant release accepted")end})
  assert(f.owner:start(NOTE));assert(f.owner:release("outcome callback"));f:clean()
  assert(#f.calls==2)
end

for _,selection in ipairs({"selected_instrument_observable", "selected_track_observable"})do
  local f=fixture();assert(f.owner:start(NOTE))
  f.song[selection]:fire();f:clean()
  call(f,2,"off",1,1)
  assert(f.owner:last_outcome().reason=="selection change")
end

for _,fault in ipairs({"timer", "observer"})do
  local f=fixture();assert(f.owner:start(NOTE))
  if fault=="timer"then f.fail_timer_remove=true
  else f.song.tracks_observable.fail_remove=true end
  local weak=setmetatable({f.song},{__mode="v"})
  assert(not f.owner:release("detach failure"))
  f.song=nil;f.current=nil;f.clean=nil
  collectgarbage("collect");collectgarbage("collect")
  assert(weak[1]==nil,"orphan callback retained captured song")
end

print("acid audition lifecycle specs passed")
