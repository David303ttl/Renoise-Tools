dofile("tests/bootstrap.lua")("acid")
local live=require("model.live_regen")

local function result(status,message)
  return {kind="complete",status=status,message=message,diagnostics={}}
end

-- Edits dispatch immediately, while multiple changes during one render coalesce.
local starts,completions,tokens=0,{},{}
local reports={}
local c=live.new(function(done,token)
  starts=starts+1
  completions[#completions+1]=done
  tokens[#tokens+1]=token
  return true
end,function(value) reports[#reports+1]=value end)
assert(c:changed()==false and starts==0)
c:set_enabled(true)
assert(c:changed() and starts==1 and c.busy and tokens[1]:is_current())
c:changed();c:changed();c:changed()
assert(starts==1 and c.pending and c:state().status=="RENDERING")
completions[1](result("committed","first commit"))
assert(starts==2 and c.busy and not c.pending)
assert(c:state().last_commit==reports[1])
completions[2](result("approximate","latest commit"))
assert(not c.busy and #reports==2 and c:state().last_commit==reports[2])

-- Disable invalidates the token, cancels once, and ignores late completion.
local cancelled=0
local stopped_done,stopped_token
local stopping=live.new(function(done,token)
  stopped_done,stopped_token=done,token
  return true
end,nil,function(token,reason)
  assert(token==stopped_token and reason=="Live Edit was disabled")
  cancelled=cancelled+1
  return true
end)
stopping:set_enabled(true)
stopping:changed()
assert(stopping.busy and stopped_token:is_current())
stopping:stop()
assert(cancelled==1 and not stopping.enabled and not stopping.busy)
assert(not stopped_token:is_current() and stopping:state().status=="CLEAN")
stopped_done(result("committed","late commit"))
assert(stopping:state().last_commit==nil)

-- Rebinding invalidates the old destination without unarming Live Edit or
-- dispatching until the newly bound source reports a relevant change.
local rebound_done,rebound_token
local rebound_starts=0
local rebound=live.new(function(done,token)
  rebound_starts=rebound_starts+1
  rebound_done,rebound_token=done,token
  return true
end,nil,function(token,reason)
  assert(token==rebound_token and reason=="phrase changed")
  return true
end)
rebound:set_enabled(true)
rebound:changed()
assert(rebound_starts==1 and rebound.busy)
rebound:rebind("phrase changed")
assert(rebound.enabled and rebound.armed and not rebound.busy and not rebound.pending)
assert(not rebound_token:is_current() and rebound_starts==1)
assert(rebound:changed() and rebound_starts==2 and rebound.busy)
rebound_done(result("committed","new phrase committed"))
assert(rebound:state().last_commit.message=="new phrase committed")

-- Failed cancellation cleanup is surfaced with its recovery record and does
-- not schedule the rebound target until a new source change arrives.
local retained_done,retained_starts,cleanup_report= nil,0,nil
local retained=live.new(function(done)
  retained_starts=retained_starts+1
  retained_done=done
  return true
end,function(value) cleanup_report=value end,function()
  return true,{kind="complete",status="error",message="staging cleanup failed",
    diagnostics={"staging phrase retained"},recovery={staging=true}}
end)
retained:set_enabled(true)
retained:changed()
retained:rebind("new target")
local retained_state=retained:state()
assert(retained.enabled and retained.armed and not retained.busy and not retained.pending)
assert(retained_starts==1 and retained_state.status=="ERROR")
assert(retained_state.last_error.recovery.staging and cleanup_report==retained_state.last_error,
  "retained staging cleanup details remain available to the caller")
assert(retained:changed() and retained_starts==2 and retained.busy)
retained_done(result("committed","rebound target committed"))

-- A failed render leaves Live Edit armed and reports ERROR. A later edit retries.
local retry_completions,retry_results={},{}
local retry=live.new(function(done)
  retry_completions[#retry_completions+1]=done
  return true
end,function(value) retry_results[#retry_results+1]=value end)
retry:set_enabled(true)
retry:changed()
assert(#retry_completions==1 and retry.busy)
retry_completions[1](result("error","temporary render failure"))
assert(retry.enabled and retry.armed and not retry.busy and not retry.pending)
assert(retry:state().status=="ERROR" and retry:state().last_error==retry_results[1])
assert(retry:changed() and #retry_completions==2 and retry.busy)
retry_completions[2](result("approximate","recovered"))
local last_commit=retry:state().last_commit
assert(last_commit==retry_results[2] and retry:state().status=="APPROXIMATE")
retry:changed()
retry:changed()
assert(#retry_completions==3 and retry.busy and retry.pending)
retry_completions[3](result("error","later render failed"))
assert(retry:state().last_error==retry_results[3])
assert(retry:state().last_commit==last_commit)
assert(#retry_completions==4 and retry.busy and not retry.pending,
  "the coalesced edit dispatches immediately after the failed render settles")
retry_completions[4](result("committed","pending source committed"))
assert(retry:state().last_commit==retry_results[4])

-- Typed stale-target outcomes become recoverable ERROR results, without a
-- latched suspension state or automatic retry.
local typed_result
local typed=live.new(function() return nil,{kind="complete",status="suspended",
  message="selected phrase was deleted",reason="destination deleted",diagnostics={}} end,
  function(value) typed_result=value end)
typed:set_enabled(true)
typed:changed()
assert(typed.enabled and typed.armed and not typed.busy and not typed.pending)
assert(typed:state().status=="ERROR" and typed_result.status=="error")
assert(typed_result.message=="selected phrase was deleted")

-- Synchronous failures settle without recursion or spinning. Changes raised
-- from a result callback are coalesced and bounded to two same-stack attempts.
local sync_starts,sync_results=0,0
local synchronous
synchronous=live.new(function()
  sync_starts=sync_starts+1
  return nil,"sync failure"
end,function()
  sync_results=sync_results+1
  synchronous:changed()
end)
synchronous:set_enabled(true)
synchronous:changed()
assert(sync_starts==2 and sync_results==2 and synchronous.pending)
assert(synchronous:state().status=="ERROR" and synchronous.enabled)
print("ACID immediate Live Edit serialization, retry and rebind checks passed")
