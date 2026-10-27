-- Debounced, serialized live phrase regeneration with invalidatable jobs.
local M = {}
M.DELAY_MS = 350

function M.new(timers, render, on_result, delay_ms, cancel_render)
  assert(timers and type(timers.add_timer) == "function" and
    type(timers.remove_timer) == "function")
  assert(type(render) == "function")
  local delay = delay_ms or M.DELAY_MS
  assert(type(delay) == "number" and delay > 0)
  assert(cancel_render == nil or type(cancel_render) == "function")

  local self = {enabled=false, busy=false, pending=false}
  local timer, generation, active = nil, 0, nil

  local function clear_timer()
    if timer then
      pcall(timers.remove_timer, timers, timer)
      timer = nil
    end
  end

  local schedule
  local function settle(job, success, message)
    if active ~= job or job.settled then return false end
    job.settled = true
    active = nil
    self.busy = false
    local current = job.valid and self.enabled and job.generation == generation
    if current and on_result then on_result(success, message) end
    if self.enabled and self.pending then schedule() end
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
      local ok, cancelled = pcall(cancel_render, job.token, job.invalid_reason)
      -- A true result promises that cancellation and temporary cleanup are
      -- synchronous. Otherwise retain the single-flight lock until done().
      if ok and cancelled == true then settle(job, false, job.invalid_reason) end
    end
  end

  local function dispatch()
    timer = nil
    if not self.enabled or not self.pending or self.busy then return end
    self.pending = false
    self.busy = true
    local job = {generation=generation, valid=true, settled=false}
    job.token = {
      generation=job.generation,
      is_current=function()
        return job.valid and not job.settled and active == job and
          self.enabled and job.generation == generation
      end
    }
    active = job
    local function done(success, message)
      settle(job, success, message)
    end
    local safe, started, err = pcall(render, done, job.token)
    if not safe then
      done(false, tostring(started))
    elseif not started then
      done(false, err or "ACID live regeneration was refused")
    end
  end

  schedule = function()
    clear_timer()
    if not self.enabled or self.busy or not self.pending then return end
    local callback
    callback = function()
      if timer ~= callback then return end
      clear_timer()
      dispatch()
    end
    timer = callback
    timers:add_timer(callback, delay)
  end

  function self:set_enabled(value)
    value = value == true
    if not value then
      self.enabled = false
      invalidate("Live Edit was disabled")
    elseif not self.enabled then
      self.enabled = true
      generation = generation + 1
      self.pending = false
    end
  end

  function self:changed()
    if not self.enabled then return end
    self.pending = true
    schedule()
  end

  function self:invalidate(reason)
    invalidate(reason)
  end

  function self:stop()
    self:set_enabled(false)
  end

  function self:state()
    return {enabled=self.enabled, busy=self.busy, pending=self.pending,
      generation=generation, job_generation=active and active.generation or nil,
      job_current=active and active.token.is_current() or false}
  end

  return self
end

return M
