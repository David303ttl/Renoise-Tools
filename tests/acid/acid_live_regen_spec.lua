dofile("tests/bootstrap.lua")("acid")
local live=require("model.live_regen")

local function timer_fixture()
  local timers={active={},calls=0,removed=0}
  function timers:add_timer(fn,ms)
    assert(ms==350)
    self.active[fn]=true
    self.calls=self.calls+1
  end
  function timers:remove_timer(fn)
    if self.active[fn] then self.removed=self.removed+1 end
    self.active[fn]=nil
  end
  function timers:fire()
    local fn=next(self.active)
    assert(fn,"no scheduled callback")
    fn()
  end
  return timers
end

local timers=timer_fixture()
local starts,tokens=0,{}
local finish
local results={}
local c=live.new(timers,function(done,token)
  starts=starts+1
  finish=done
  tokens[#tokens+1]=token
  return true
end,function(ok,msg) results[#results+1]={ok,msg} end)
c:changed()
assert(starts==0)
c:set_enabled(true)
assert(next(timers.active)==nil)
c:changed();c:changed();c:changed()
assert(timers.calls==3)
timers:fire()
assert(starts==1 and c.busy and tokens[1]:is_current())
assert(next(timers.active)==nil)
c:changed();c:changed()
assert(starts==1 and next(timers.active)==nil and c.pending)
finish(true,"generated")
assert(not c.busy and #results==1 and results[1][1])
timers:fire()
assert(starts==2 and tokens[2]:is_current())
finish(true,"generated again")
assert(#results==2)

-- Disabling invalidates the active job before its asynchronous callback arrives.
c:changed();timers:fire()
local stale_finish=finish
local stale_token=tokens[3]
assert(stale_token:is_current())
c:stop()
assert(not stale_token:is_current() and not c.enabled and not c.pending)
stale_finish(true,"late commit callback")
assert(#results==2 and not c.busy)

-- Re-enabling never regenerates by itself, and cancelled timer callbacks are inert.
c:set_enabled(true)
assert(next(timers.active)==nil)
c:changed()
local old_timer=next(timers.active)
c:changed()
assert(timers.removed>=1)
old_timer()
assert(starts==3)
timers:fire()
assert(starts==4)
finish(true,"generated after debounce")
assert(#results==3)

-- A synchronous renderer refusal settles cleanly and reports one result.
local refused=live.new(timers,function()
  return nil,"not owned"
end,function(ok,msg) results[#results+1]={ok,msg} end)
refused:set_enabled(true)
refused:changed();timers:fire()
assert(results[#results][1]==false and results[#results][2]=="not owned")
assert(not refused.busy)

-- Explicit context invalidation cancels exactly the active token when the
-- injected renderer guarantees synchronous cleanup.
local cancelled_token
local cancelled=live.new(timers,function(_,token)
  cancelled_token=token
  return true
end,function(ok,msg) results[#results+1]={ok,msg} end,nil,
function(token,reason)
  assert(token==cancelled_token and reason=="target changed")
  return true
end)
cancelled:set_enabled(true)
cancelled:changed();timers:fire()
assert(cancelled_token:is_current())
cancelled:invalidate("target changed")
assert(not cancelled_token:is_current() and not cancelled.busy)
assert(#results==4) -- cancelled job does not report stale completion

-- A late callback cannot settle a newer job or release its single-flight lock.
local completions={}
local serial=live.new(timers,function(done)
  completions[#completions+1]=done
  return true
end)
serial:set_enabled(true)
serial:changed();timers:fire()
serial:changed()
serial:invalidate("song changed")
completions[1](true,"stale")
assert(not serial.busy and not serial.pending)
print("ACID live regeneration invalidation checks passed")
