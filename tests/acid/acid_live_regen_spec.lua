dofile("tests/bootstrap.lua")("acid")
local live=require("model.live_regen")
local timers={active={},calls=0}
function timers:add_timer(fn,ms)
  assert(ms==350)
  self.active[fn]=true
  self.calls=self.calls+1
end
function timers:remove_timer(fn) self.active[fn]=nil end
function timers:fire()
  local fn=next(self.active)
  assert(fn,"no scheduled callback")
  fn()
end
local starts=0
local finish
local results={}
local c=live.new(timers,function(done)
  starts=starts+1
  finish=done
  return true
end,function(ok,msg) results[#results+1]={ok,msg} end)
c:changed()
assert(starts==0)
c:set_enabled(true)
assert(next(timers.active)==nil)
c:changed()
c:changed()
c:changed()
assert(timers.calls==3)
timers:fire()
assert(starts==1 and c.busy)
assert(next(timers.active)==nil)
c:changed()
c:changed()
assert(starts==1 and next(timers.active)==nil)
finish(true,"generated")
assert(not c.busy and #results==1)
timers:fire()
assert(starts==2)
finish(true,"generated again")
assert(#results==2)
c:changed()
c:stop()
assert(next(timers.active)==nil)
c:set_enabled(true)
assert(next(timers.active)==nil)
c:changed()
timers:fire()
assert(starts==3)
c:stop()
finish(true,"completed while disabled")
assert(#results==2 and next(timers.active)==nil)
local errors={}
local refuse=live.new(timers,function(done)
  return nil,"not owned"
end,function(ok,msg)
  errors[#errors+1]=msg
end)
refuse:set_enabled(true)
refuse:changed()
timers:fire()
assert(errors[1]=="not owned" and refuse.busy==false)
refuse:stop()
print("ACID live editing debounce and single-flight checks passed")
