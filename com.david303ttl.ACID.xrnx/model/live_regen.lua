-- Debounced, serialized live phrase regeneration. Pure Lua except the
-- injected Renoise ScriptingTool timer interface.
local M={}
M.DELAY_MS=350

function M.new(timers,render,on_result,delay_ms)
  assert(timers and type(timers.add_timer)=="function"
    and type(timers.remove_timer)=="function")
  assert(type(render)=="function")
  local delay=delay_ms or M.DELAY_MS
  assert(type(delay)=="number" and delay>0)
  local self={enabled=false,busy=false,pending=false}
  local timer

  local function clear_timer()
    if timer then
      timers:remove_timer(timer)
      timer=nil
    end
  end

  local schedule
  local function dispatch()
    timer=nil
    if not self.enabled or not self.pending or self.busy then return end
    self.pending=false
    self.busy=true
    local settled=false
    local function done(success,message)
      if settled then return end
      settled=true
      self.busy=false
      if self.enabled and on_result then on_result(success,message) end
      if self.enabled and self.pending then schedule() end
    end
    local safe,started,err=pcall(render,done)
    if not safe then
      done(false,tostring(started))
    elseif not started then
      done(false,err or "ACID live regeneration was refused")
    end
  end

  schedule=function()
    clear_timer()
    if not self.enabled or self.busy or not self.pending then return end
    local callback=function()
      -- Renoise timers repeat unless explicitly removed.
      local current=timer
      if current then timers:remove_timer(current) end
      dispatch()
    end
    timer=callback
    timers:add_timer(callback,delay)
  end

  function self:set_enabled(value)
    value=value==true
    if not value then
      clear_timer()
      self.enabled=false
      self.pending=false
    else
      self.enabled=true
      -- Enabling live mode does not regenerate or overwrite anything.
    end
  end

  function self:changed()
    if not self.enabled then return end
    self.pending=true
    schedule()
  end

  function self:stop()
    self:set_enabled(false)
  end

  return self
end

return M
