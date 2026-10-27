-- Immediate, serialized Live Edit regeneration with invalidatable jobs.
local M = {}

local TERMINAL={committed=true,approximate=true,error=true,suspended=true}

local function result_value(value)
  if type(value)=="table" and value.kind=="complete" and TERMINAL[value.status] then
    if value.status=="suspended" then
      local normalized={}
      for key,item in pairs(value) do normalized[key]=item end
      normalized.status="error"
      normalized.message=normalized.message or normalized.reason or "Live Edit target requires rebinding"
      return normalized
    end
    return value
  end
  local message=type(value)=="table" and value.message or value
  message=tostring(message or "ACID live regeneration failed")
  return {kind="complete",status="error",message=message,diagnostics={message}}
end

function M.new(render,on_result,cancel_render)
  assert(type(render)=="function")
  assert(on_result==nil or type(on_result)=="function")
  assert(cancel_render==nil or type(cancel_render)=="function")

  local self={enabled=false,armed=false,busy=false,pending=false,status="CLEAN",
    last_result=nil,last_error=nil,last_commit=nil}
  local generation,active,draining=0,nil,false

  local drain
  local function settle(job,value,report)
    if active~=job or job.settled then return false end
    job.settled=true
    active=nil
    self.busy=false
    local current=job.valid and self.enabled and job.generation==generation
    if current and report~=false then
      local result=result_value(value)
      job.result_status=result.status
      self.last_result=result
      self.last_error=result.status=="error" and result or nil
      if result.status=="committed" or result.status=="approximate" then
        self.last_commit=result
      end
      if result.status=="error" then self.status="ERROR"
      elseif result.status=="approximate" then self.status="APPROXIMATE"
      else self.status="COMMITTED" end
      if on_result then
        local ok,err=pcall(on_result,result)
        if not ok then self.callback_error=tostring(err) end
      end
    elseif not self.enabled or not self.pending then
      self.status="CLEAN"
    end
    if self.enabled and self.pending then drain() end
    return current
  end

  local function invalidate(reason)
    generation=generation+1
    self.pending=false
    if not active then
      self.status="CLEAN"
      return
    end
    local job=active
    job.valid=false
    job.invalid_reason=reason or "Live Edit context changed"
    local cancellation_result
    if cancel_render then
      local ok,cancelled,result=pcall(cancel_render,job.token,job.invalid_reason)
      if ok and cancelled==true then
        cancellation_result=result
        settle(job,nil,false)
      end
    end
    if cancellation_result~=nil then
      local result=result_value(cancellation_result)
      if result.status=="error" then
        self.last_result=result
        self.last_error=result
        self.status="ERROR"
        if on_result then
          local ok,err=pcall(on_result,result)
          if not ok then self.callback_error=tostring(err) end
        end
      end
    elseif not active then
      self.status="CLEAN"
    end
  end

  local function run_one()
    self.pending=false
    self.busy=true
    self.status="RENDERING"
    local job={generation=generation,valid=true,settled=false}
    job.token={generation=job.generation,is_current=function()
      return job.valid and not job.settled and active==job and self.enabled and
        job.generation==generation
    end}
    active=job
    local function done(value) settle(job,value) end
    local ok,started,reason=pcall(render,done,job.token)
    if not ok then
      done({kind="complete",status="error",message=tostring(started),diagnostics={tostring(started)}})
    elseif not started then
      done(reason)
    end
    return job.settled and job.result_status=="error"
  end

  drain=function()
    if draining then return end
    draining=true
    local synchronous_failures=0
    while self.enabled and self.pending and not self.busy do
      if run_one() then
        synchronous_failures=synchronous_failures+1
        if synchronous_failures>=2 then
          self.status="ERROR"
          break
        end
      else
        synchronous_failures=0
      end
      if self.busy then break end
    end
    draining=false
  end

  function self:set_enabled(value)
    value=value==true
    if value==self.enabled then return end
    if not value then
      self.enabled=false
      self.armed=false
      invalidate("Live Edit was disabled")
      self.status="CLEAN"
    else
      self.enabled=true
      self.armed=true
      self.pending=false
      generation=generation+1
      self.status="CLEAN"
    end
  end

  function self:changed()
    if not self.enabled then return false end
    self.pending=true
    if self.busy then
      self.status="RENDERING"
    else
      self.status="DIRTY"
      drain()
    end
    return true
  end

  function self:retry()
    if not self.enabled then return false end
    return self:changed()
  end

  function self:rebind(reason)
    if not self.enabled then return false end
    invalidate(reason or "Live Edit target rebound")
    return true
  end

  function self:stop()
    self:set_enabled(false)
  end

  function self:state()
    return {enabled=self.enabled,armed=self.armed,busy=self.busy,pending=self.pending,
      status=self.status,last_result=self.last_result,last_error=self.last_error,
      last_commit=self.last_commit,callback_error=self.callback_error,
      generation=generation,job_generation=active and active.generation or nil,
      job_current=active and active.token.is_current() or false}
  end

  return self
end

return M
