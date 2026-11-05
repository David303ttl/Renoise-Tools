local M = {}
local SAMPLE_RATE, MONO_CHANNELS = 48000, 1

io.exists = function(path)
  local file = io.open(path, "rb")
  if not file then return false end
  assert(file:close())
  return true
end

function M.observable()
  local callbacks = {}
  local observable = { callbacks = callbacks }
  function observable:has_notifier(callback) return callbacks[callback] == true end
  function observable:add_notifier(callback)
    assert(not callbacks[callback], "duplicate notifier")
    callbacks[callback] = true
  end
  function observable:remove_notifier(callback)
    assert(callbacks[callback], "unknown notifier")
    callbacks[callback] = nil
  end
  function observable:notify()
    local pending = {}
    for callback in pairs(callbacks) do pending[#pending + 1] = callback end
    for _, callback in ipairs(pending) do callback() end
  end
  return observable
end

function M.buffer(frames, rate, channels, value)
  return {
    has_sample_data = frames > 0, number_of_frames = frames,
    number_of_channels = channels or MONO_CHANNELS, sample_rate = rate or SAMPLE_RATE, reads = 0,
    sample_data = function(self, channel, frame)
      assert(channel >= 1 and channel <= self.number_of_channels, "channel out of range")
      assert(frame >= 1 and frame <= self.number_of_frames, "frame out of range")
      self.reads = self.reads + 1
      return value and value(channel, frame) or 0.25
    end,
  }
end

function M.instrument(buffers)
  local samples = {}
  for index, buffer in ipairs(buffers) do
    samples[index] = {
      sample_buffer = buffer, sample_buffer_observable = M.observable(),
      slice_markers_observable = M.observable(),
    }
  end
  return { samples = samples, samples_observable = M.observable() }
end

function M.host(instrument)
  local tool = {
    timers = {}, app_release_document_observable = M.observable(),
    tool_will_unload_observable = M.observable(),
  }
  function tool:has_timer(timer) return self.timers[timer] ~= nil end
  function tool:add_timer(timer, interval)
    assert(interval > 0 and not self:has_timer(timer))
    self.timers[timer] = interval
  end
  function tool:remove_timer(timer)
    assert(self:has_timer(timer))
    self.timers[timer] = nil
  end
  local song = { instruments_observable = M.observable(), selected_instrument = instrument }
  renoise = { tool = function() return tool end, song = function() return song end }
  return tool, song
end

function M.temp_path()
  local name = os.tmpname()
  os.remove(name)
  return name .. "_digitakt.wav"
end

function M.read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = assert(file:read("*a"))
  assert(file:close())
  return content
end

function M.write_file(path, content)
  local file = assert(io.open(path, "wb"))
  assert(file:write(content))
  assert(file:close())
end

return M
