dofile("tests/bootstrap.lua")("acid")
local live=require("model.live_regen")
local function result(status,message)
  return {kind="complete",status=status,message=message,diagnostics={}}
end

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
end,function(value) results[#results+1]=value end)
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
finish(result("committed","generated"))
assert(not c.busy and #results==1 and results[1].status=="committed")
timers:fire()
assert(starts==2 and tokens[2]:is_current())
finish(result("committed","generated again"))
assert(#results==2)

-- Disabling invalidates the active job before its asynchronous callback arrives.
c:changed();timers:fire()
local stale_finish=finish
local stale_token=tokens[3]
assert(stale_token:is_current())
c:stop()
assert(not stale_token:is_current() and not c.enabled and not c.pending)
stale_finish(result("committed","late commit callback"))
assert(#results==2 and not c.busy)
assert(c:state().status=="CLEAN")

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
finish(result("committed","generated after debounce"))
assert(#results==3)

-- A synchronous renderer refusal settles cleanly and reports one result.
local refused=live.new(timers,function()
  return nil,"not owned"
end,function(value) results[#results+1]=value end)
refused:set_enabled(true)
refused:changed();timers:fire()
assert(results[#results].status=="error" and results[#results].message=="not owned")
assert(not refused.busy)

-- Synchronous typed destination loss remains a suspension, not a generic error.
local typed_suspension={kind="complete",status="suspended",
  message="selected phrase was deleted",reason="destination deleted",diagnostics={}}
local typed=live.new(timers,function() return nil,typed_suspension end)
typed:set_enabled(true)
typed:changed();timers:fire()
assert(typed.enabled and typed.armed and typed:state().suspended)
assert(typed:state().status=="SUSPENDED")
assert(typed:state().last_result==typed_suspension)

-- Explicit context invalidation cancels exactly the active token when the
-- injected renderer guarantees synchronous cleanup.
local cancelled_token
local cancelled=live.new(timers,function(_,token)
  cancelled_token=token
  return true
end,function(value) results[#results+1]=value end,nil,
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
completions[1](result("committed","stale"))
assert(not serial.busy and not serial.pending)

-- A failed render leaves Live Edit armed. A later relevant edit retries it.
local retry_timers=timer_fixture()
local retry_completions={}
local retry_results={}
local retry=live.new(retry_timers,function(done)
  retry_completions[#retry_completions+1]=done
  return true
end,function(value)
  retry_results[#retry_results+1]=value
end)
retry:set_enabled(true)
retry:changed();retry_timers:fire()
retry_completions[1](result("error","temporary render failure"))
assert(retry.enabled and not retry.busy and not retry.pending)
assert(retry.armed and retry:state().status=="ERROR")
assert(#retry_results==1 and retry_results[1].status=="error")
assert(retry:retry())
retry_timers:fire()
assert(#retry_completions==2 and retry.busy and retry.enabled)
retry_completions[2](result("approximate","recovered with approximation"))
assert(retry.enabled and retry.armed and not retry.busy)
assert(retry:state().status=="APPROXIMATE" and retry_results[2].status=="approximate")
local last_commit=retry:state().last_commit
assert(last_commit==retry_results[2])
retry:changed();retry_timers:fire()
retry:changed()
retry_completions[3](result("error","next render failed"))
assert(retry.enabled and retry.pending and retry:state().status=="QUEUED")
assert(retry:state().last_error==retry_results[3])
assert(retry:state().last_commit==last_commit,
  "a failed render preserves the last successful commit while latest edits stay pending")

-- Edits received during one render coalesce into one follow-up render.
local batch_timers=timer_fixture()
local batch_completions={}
local batch=live.new(batch_timers,function(done)
  batch_completions[#batch_completions+1]=done
  return true
end)
batch:set_enabled(true)
batch:changed();batch_timers:fire()
batch:changed();batch:changed();batch:changed()
assert(#batch_completions==1 and batch.busy and batch.pending)
batch_completions[1](result("error","recoverable"))
assert(batch.enabled and not batch.busy and batch.pending)
batch_timers:fire()
assert(#batch_completions==2 and batch.busy and not batch.pending)
batch_completions[2](result("committed","latest source committed"))
assert(batch.enabled and not batch.busy)

-- Failed asynchronous cancellation invalidates commit authority but preserves
-- the single-flight lock until the renderer confirms completion.
local async_timers=timer_fixture()
local async_done,async_token
local async_results=0
local async=live.new(async_timers,function(done,token)
  async_done,async_token=done,token
  return true
end,function() async_results=async_results+1 end,nil,function()
  return false
end)
async:set_enabled(true)
async:changed();async_timers:fire()
async:changed()
async:invalidate("destination ownership lost")
assert(async.busy and not async.pending and not async_token:is_current())
assert(async:state().suspended and async:state().status=="SUSPENDED")
async:changed()
assert(async.pending and async:state().suspended and next(async_timers.active)==nil)
assert(not async:retry())
async_done(result("committed","late result"))
assert(not async.busy and async.enabled and async_results==0)
assert(next(async_timers.active)==nil)
assert(async:resume() and not async:state().suspended)
async_timers:fire()
assert(async.busy and async_token:is_current())
async_done(result("committed","rebound target"))
assert(not async.busy and async_results==1 and async:state().status=="COMMITTED")

-- Synchronous cancellation cleanup failures release the lock and remain visible.
local cleanup_timers=timer_fixture()
local cleanup_result=result("error","staging phrase cleanup failed")
local cleanup_reports={}
local cleanup=live.new(cleanup_timers,function() return true end,
  function(value) cleanup_reports[#cleanup_reports+1]=value end,nil,
  function() return true,cleanup_result end)
cleanup:set_enabled(true)
cleanup:changed();cleanup_timers:fire()
cleanup:suspend("destination ownership lost")
local cleanup_state=cleanup:state()
assert(not cleanup.busy and cleanup_state.suspended and cleanup.armed)
assert(cleanup_state.status=="SUSPENDED" and cleanup_state.last_error==cleanup_result)
assert(#cleanup_reports==1 and cleanup_reports[1]==cleanup_result)
print("ACID live regeneration invalidation checks passed")
