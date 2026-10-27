-- Debounced, serialized live phrase regeneration with invalidatable jobs.
local M = {}
M.DELAY_MS = 350

local function failure(message)
  if type(message)=="table" and message.kind=="complete" and
      (message.status=="committed" or message.status=="approximate" or
        message.status=="error" or message.status=="suspended") then return message end
  return {kind="complete",status="error",message=tostring(message or "ACID live regeneration failed"),
    diagnostics={tostring(message or "ACID live regeneration failed")}}
end

function M.new(timers, render, on_result, delay_ms, cancel_render)
  assert(timers and type(timers.add_timer) == "function" and
    type(timers.remove_timer) == "function")
  assert(type(render) == "function")
  local delay = delay_ms or M.DELAY_MS
  assert(type(delay) == "number" and delay > 0)
  assert(cancel_render == nil or type(cancel_render) == "function")

  local self = {enabled=false, armed=false, busy=false, pending=false, suspended=false,
    status="CLEAN", last_result=nil, last_error=nil, last_commit=nil}
  local timer, generation, active = nil, 0, nil

  local function clear_timer()
    if timer then
      pcall(timers.remove_timer, timers, timer)
      timer = nil
    end
  end

  local schedule
  local function settle(job, result, report_stale)
    if active ~= job or job.settled then return false end
    job.settled = true
    active = nil
    self.busy = false
    local current = job.valid and self.enabled and job.generation == generation
    if current or report_stale then
      local valid=type(result)=="table" and result.kind=="complete" and
        (result.status=="committed" or result.status=="approximate" or
          result.status=="error" or result.status=="suspended")
      result=valid and result or failure(type(result)=="table" and result.message or result)
      self.last_result=result
      self.last_error=(result.status=="error" or result.status=="suspended") and result or nil
      if current and (result.status=="committed" or result.status=="approximate") then
        self.last_commit=result
      end
      if result.status=="suspended" then
        self.suspended=true
        self.suspension_reason=result.reason or result.message
        self.status="SUSPENDED"
      elseif self.suspended then self.status="SUSPENDED"
      elseif result.status=="error" then self.status="ERROR"
      elseif result.status=="approximate" then self.status="APPROXIMATE"
      else self.status="COMMITTED" end
      if on_result and (current or report_stale) then
        local ok,err=pcall(on_result,result)
        if not ok then self.callback_error=tostring(err) end
      end
    elseif not self.enabled then
      self.status="CLEAN"
    end
    if self.enabled and self.pending and not self.suspended then schedule() end
    return current
  end

  local function invalidate(reason)
    generation = generation + 1
    self.pending = false
    clear_timer()
    if not active then return end
    local job = active
    job.valid = false
    job.invalid_reason = reason or "ACID live regeneration context changed"
    if cancel_render then
      local ok, cancelled, cancellation_result = pcall(cancel_render, job.token, job.invalid_reason)
      if ok and cancelled == true then
        settle(job, cancellation_result or failure(job.invalid_reason),
          cancellation_result~=nil)
      end
    end
  end

  local function dispatch()
    timer = nil
    if not self.enabled or not self.pending or self.busy then return end
    self.pending = false
    self.busy = true
    self.status="RENDERING"
    local job = {generation=generation, valid=true, settled=false}
    job.token = {
      generation=job.generation,
      is_current=function()
        return job.valid and not job.settled and active == job and
          self.enabled and job.generation == generation
      end
    }
    active = job
    local function done(result)
      settle(job, result)
    end
    local safe, started, err = pcall(render, done, job.token)
    if not safe then
      done(failure(started))
    elseif not started then
      done(failure(err or started or "ACID live regeneration was refused"))
    end
  end

  schedule = function()
    clear_timer()
    if not self.enabled or self.suspended or self.busy or not self.pending then return end
    local callback
    callback = function()
      if timer ~= callback then return end
      clear_timer()
      dispatch()
    end
    timer = callback
    self.status="QUEUED"
    timers:add_timer(callback, delay)
  end

  function self:set_enabled(value)
    value = value == true
    if not value then
      self.enabled = false
      self.armed = false
      self.suspended = false
      self.suspension_reason = nil
      invalidate("Live Edit was disabled")
      self.status=self.busy and "SUSPENDED" or "CLEAN"
    elseif not self.enabled then
      self.enabled = true
      self.armed = true
      self.suspended = false
      self.suspension_reason = nil
      generation = generation + 1
      self.pending = false
      self.status="CLEAN"
    end
  end

  function self:changed()
    if not self.enabled then return end
    self.pending = true
    if not self.suspended then self.status="DIRTY" end
    schedule()
  end

  function self:retry()
    if not self.enabled or self.suspended then return false end
    self.pending=true
    self.status="DIRTY"
    schedule()
    return true
  end

  function self:suspend(reason)
    self.suspended=true
    self.suspension_reason=reason or "Live Edit target is unavailable"
    self.status="SUSPENDED"
    invalidate(self.suspension_reason)
  end

  function self:resume()
    if not self.enabled or not self.suspended then return false end
    self.suspended=false
    self.suspension_reason=nil
    self.pending=true
    self.status="DIRTY"
    schedule()
    return true
  end

  function self:invalidate(reason)
    self:suspend(reason)
  end

  function self:stop()
    self:set_enabled(false)
  end

  function self:state()
    return {enabled=self.enabled, armed=self.armed, busy=self.busy, pending=self.pending,
      suspended=self.suspended,
      status=self.status, last_result=self.last_result, last_error=self.last_error,
      last_commit=self.last_commit,
      suspension_reason=self.suspension_reason, callback_error=self.callback_error,
      generation=generation,
      job_generation=active and active.generation or nil,
      job_current=active and active.token.is_current() or false}
  end

  return self
end

return M
