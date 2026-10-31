-- SPDX-License-Identifier: GPL-3.0-only
local M = {}

-- Commit notification orders rendering after the new source is committed.
-- Compilation remains asynchronous; render results and output validation decide
-- success, rather than an idle count or a snapshot of compile_error.
function M.new(script, options, callbacks)
  local runner = {phase="queued"}
  local observer, on_commit
  local render_started=false
  local detaching=false
  local commit_called=false
  local function detach()
    if detaching then return false end
    if observer and on_commit then
      detaching=true
      pcall(function() observer:remove_notifier(on_commit) end)
      local probed,attached=pcall(function()
        if type(observer.has_notifier)=="function" then return observer:has_notifier(on_commit) end
        return nil
      end)
      detaching=false
      if not probed or attached ~= false then return false end
      observer, on_commit = nil, nil
    end
    return true
  end
  local function finish(err, rendered, skipped)
    if runner.phase == "done" or runner.phase == "cancelled" then return end
    runner.phase = "done"
    detach()
    script = nil
    callbacks.done(err, rendered, skipped)
  end
  function runner:detach()
    if self.phase == "queued" or self.phase == "committing" then
      self.phase = "cancelled"
      script = nil
    elseif not render_started then
      script = nil
    end
    return detach()
  end
  function runner:cancel()
    if self.phase ~= "queued" and self.phase ~= "committing" then return false end
    self:detach()
    return true
  end
  function runner:start()
    if self.phase ~= "queued" then return nil, "Script runner already started" end
    self.phase = "committing"
    on_commit = function()
      if self.phase ~= "committing" then detach();return end
      if not commit_called then return end
      self.phase = "rendering"
      detach()
      local native_invoked = false
      local ok, err = pcall(function()
        if callbacks.rendering then callbacks.rendering() end
        if self.phase ~= "rendering" then return end
        if not script then
          finish("Script runner detached before rendering")
          return
        end
        native_invoked = true
        render_started=true
        local started, start_error = script:render_to_pattern(options, finish)
        if started == false then
          finish("Phrase rendering could not start: " .. tostring(start_error or "unknown error"))
        end
      end)
      if not ok then
        if native_invoked and self.phase == "rendering" then
          -- A thrown native call does not establish that rendering stopped.
          self.error = "Phrase rendering raised an exception: " .. tostring(err)
        elseif not native_invoked then
          finish("Phrase rendering failed: " .. tostring(err))
        end
      end
    end
    local ok, err = pcall(function()
      observer = script.committed_observable
      observer:add_notifier(on_commit)
      if type(observer.has_notifier) ~= "function" then
        error("Commit notifier registration cannot be verified")
      end
      local probed, attached = pcall(function() return observer:has_notifier(on_commit) end)
      if not probed or attached ~= true then
        error("Commit notifier registration was not verified")
      end
      commit_called=true
      script:commit()
    end)
    if not ok then
      if self.phase == "committing" then
        self.phase = "done"
        detach()
        return nil, tostring(err)
      end
      -- Commit may notify, start a native render, then throw. Only the native
      -- callback can release that render's occupancy.
    end
    return true
  end
  return runner
end

return M
