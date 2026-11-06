local M = {}
local SAMPLE_RATE, MONO_CHANNELS = 48000, 1
local EXPORT_PASSES, MAX_TERMINAL_TICKS = 2, 10

-- Standalone Lua lacks Renoise's directory API. Keep directory ownership in
-- memory while delegating file bytes and failures to real filesystem handles.
local directories, backing_paths, stat_types = {}, {}, {}
local raw_open, raw_remove, raw_rename = io.open, os.remove, os.rename
local function backing_path(path)
  local parent, name = path:match("^(.*)/([^/]+)$")
  if directories[parent] then backing_paths[path] = parent .. "_" .. name end
  return backing_paths[path] or path
end
io.open = function(path, mode) return raw_open(backing_path(path), mode) end
io.exists = function(path)
  if directories[path] or stat_types[path] then return true end
  local file = io.open(path, "rb")
  if not file then return false end
  assert(file:close())
  return true
end
io.stat = function(path)
  if stat_types[path] then return { type = stat_types[path] } end
  if directories[path] then return { type = "directory" } end
  local file, err, code = io.open(path, "rb")
  if not file then return nil, err, code end
  assert(file:close())
  return { type = "file" }
end

os.mkdir = function(path)
  if io.exists(path) then return nil, "Path already exists" end
  directories[path] = true
  return true
end
os.remove = function(path)
  if directories[path] then
    for virtual, physical in pairs(backing_paths) do
      if virtual:sub(1, #path + 1) == path .. "/" then
        local file = raw_open(physical, "rb")
        if file then file:close(); return nil, "Directory is not empty" end
      end
    end
    directories[path] = nil
    return true
  end
  return raw_remove(backing_path(path))
end
os.rename = function(from, to) return raw_rename(backing_path(from), backing_path(to)) end

function M.assert_no_staging_directories()
  assert(next(directories) == nil, "staging directory leaked")
end

function M.set_stat_type(path, file_type)
  stat_types[path] = file_type
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

function M.drive(tool, job, until_ready)
  local ticks, terminal_ticks = 0, 0
  local max_ticks = EXPORT_PASSES * job.plan.total_frames + MAX_TERMINAL_TICKS
  while not (until_ready and until_ready()) do
    local timer = next(tool.timers)
    if not timer then
      assert(not until_ready and job.finished, "export stopped before completion")
      return ticks
    end
    assert(timer == job.timer and not next(tool.timers, timer), "unexpected export timer")
    ticks = ticks + 1
    assert(ticks <= max_ticks, "export exceeded its progress bound")
    local written, verified, finished = job.written_frames, job.verified_frames, job.finished
    timer()
    if finished then
      terminal_ticks = terminal_ticks + 1
      assert(terminal_ticks <= MAX_TERMINAL_TICKS, "export timer did not detach")
    else
      assert(job.written_frames >= written and job.verified_frames >= verified,
        "export progress counters regressed")
      assert(job.written_frames <= job.plan.total_frames and job.verified_frames <= job.written_frames,
        "export progress exceeds planned frames")
      assert(job.finished or job.written_frames > written or job.verified_frames > verified,
        "export timer made no progress")
    end
  end
  return ticks
end

function M.temp_path()
  local name = os.tmpname()
  os.remove(name)
  -- Some Windows Lua builds return a drive-root name regardless of TEMP.
  local token = assert(name:match("[^/\\]+$"))
  return "tests/digitaktsamplechain/" .. token .. "_digitakt.wav.tmp"
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
