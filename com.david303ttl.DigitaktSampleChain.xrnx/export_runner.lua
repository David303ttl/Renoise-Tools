-- SPDX-License-Identifier: GPL-3.0-only
-- Bounded-memory export jobs. All source access remains on Renoise's GUI thread.
local options_model = require("chain_options")
local extractor = require("sample_extractor")
local layout = require("slot_layout")
local wav = require("wav_writer")
local M = {}
local FRAMES_PER_STEP, TIMER_INTERVAL_MS = 32768, 10
local RESAMPLED_FRAMES_PER_STEP = 2048
local FRAMES_PER_BATCH, STEP_BUDGET_SECONDS = 32, 0.008
local PERCENT_SCALE = 100
local Job = {}
Job.__index = Job

local function notify_terminal(job, name, value)
  local callback = job.callbacks[name]
  job.callbacks = {}
  if not callback then return end
  local ok, err = pcall(callback, value)
  if not ok then
    job.callback_error = "Export " .. name .. " callback failed: " .. tostring(err)
    print("[DigitaktSampleChain] " .. job.callback_error)
  end
end

local function cleanup(job, discard)
  local errors = {}
  local function attempt(action)
    local ok, err = pcall(action)
    if not ok then errors[#errors + 1] = tostring(err) end
  end
  attempt(function()
    if job.tool:has_timer(job.timer) then job.tool:remove_timer(job.timer) end
  end)
  for index = #job.guards, 1, -1 do
    local guard = job.guards[index]
    attempt(function()
      if guard.observable:has_notifier(guard.callback) then
        guard.observable:remove_notifier(guard.callback)
      end
    end)
  end
  if discard and job.output then
    local ok, err = job.output:abort()
    if not ok then errors[#errors + 1] = err end
  end
  job.guards, job.snapshot, job.chunk, job.reader, job.output = {}, nil, nil, nil, nil
  if #errors > 0 then return table.concat(errors, "\n") end
end

function Job:fail(message)
  if self.finished then return end
  self.finished = true
  local cleanup_err = cleanup(self, true)
  if cleanup_err then message = tostring(message) .. "\n" .. cleanup_err end
  notify_terminal(self, "on_error", tostring(message))
end

function Job:cancel(message)
  if self.finished then return end
  self.finished, self.canceled = true, true
  local cleanup_err = cleanup(self, true)
  message = message or "Export canceled."
  if cleanup_err then message = message .. "\n" .. cleanup_err end
  notify_terminal(self, "on_cancel", message)
end

function Job:step()
  if self.finished then return end
  local deadline = os.clock() + STEP_BUDGET_SECONDS
  if self.invalid_reason then self:fail(self.invalid_reason); return end
  if self.callbacks.on_progress then
    local frames = self.verifying and self.verified_frames or self.written_frames
    self.callbacks.on_progress(string.format("%s %d%%", self.verifying and "Verifying" or "Exporting",
      math.floor(PERCENT_SCALE * frames / self.plan.total_frames)))
  end
  if self.finished then return end
  if self.invalid_reason then self:fail(self.invalid_reason); return end

  -- Buffer notifications can arrive after dimensions change.
  for _, entry in ipairs(self.snapshot.buffers) do
    local buffer = entry.buffer
    if not buffer.has_sample_data or buffer.number_of_frames ~= entry.frames
        or buffer.number_of_channels ~= entry.channels or buffer.sample_rate ~= entry.source_rate then
      self:fail("Source audio changed. Restart the export.")
      return
    end
  end

  local count, payloads = 0, {}
  while count < self.frames_per_step and self.slot <= self.plan.slot_count do
    local entry = self.snapshot.buffers[self.slot]
    local source_length = entry and entry.output_frames or 0
    local slot_length = self.plan.slot_frames or source_length
    if not self.reader then
      self.reader = layout.make_slot_reader(self.plan,
        entry and extractor.reader(entry, self.options.mono) or nil, source_length)
    end
    local frames = math.min(FRAMES_PER_BATCH, self.frames_per_step - count, slot_length - self.offset)
    for index = 1, frames do
      self.chunk[index] = self.reader(self.offset + index)
    end
    payloads[#payloads + 1] = wav.encode(self.chunk, 1, frames, self.dither)
    count, self.offset = count + frames, self.offset + frames
    if self.offset == slot_length then
      self.slot, self.offset, self.reader = self.slot + 1, 0, nil
    end
    -- Yield after a complete PCM batch; file I/O and callbacks can still block.
    if count > 0 and os.clock() >= deadline then break end
  end
  local payload = table.concat(payloads)
  local accepted, output_err
  if self.verifying then
    accepted, output_err = self.output:verify(payload)
    self.verified_frames = self.verified_frames + count
  else
    accepted, output_err = self.output:write(payload)
    self.written_frames = self.written_frames + count
  end
  if not accepted then self:fail(output_err); return end
  if self.slot <= self.plan.slot_count then return end
  if not self.verifying then
    self.verifying, self.slot, self.offset, self.reader = true, 1, 0, nil
    self.dither = self.options.dither and wav.new_dither() or nil
    return
  end

  local committed, warning = self.output:commit()
  if not committed then self:fail(warning); return end
  self.finished = true
  local cleanup_err = cleanup(self, false)
  if cleanup_err then warning = (warning and warning .. "\n" or "") .. cleanup_err end
  notify_terminal(self, "on_finish", {
    path = self.path, mode = self.plan.mode, sample_rate = options_model.SAMPLE_RATE,
    frames = self.plan.total_frames, slot_count = self.plan.slot_count,
    slot_sec = self.plan.slot_sec, total_sec = self.plan.total_sec, warning = warning,
  })
end

function M.start(instrument, options, path, callbacks)
  if type(path) ~= "string" or path == "" then return nil, "Missing export destination." end
  local normalized, options_err = options_model.validate(options)
  if not normalized then return nil, options_err end
  local read_ok, snapshot, read_err = pcall(extractor.snapshot, instrument)
  if not read_ok then return nil, "Could not read instrument: " .. tostring(snapshot) end
  if not snapshot then return nil, read_err end
  local lengths = {}
  local frames_per_step = FRAMES_PER_STEP
  for index, entry in ipairs(snapshot.buffers) do
    lengths[index] = entry.output_frames
    if entry.source_rate ~= snapshot.rate then frames_per_step = RESAMPLED_FRAMES_PER_STEP end
  end
  local plan, plan_err = layout.plan(lengths, normalized, snapshot.rate)
  if not plan then return nil, plan_err end
  local size_ok, size_err = wav.assert_size(plan.total_frames)
  if not size_ok then return nil, size_err end

  local job = setmetatable({
    options = normalized, path = path, callbacks = callbacks or {}, snapshot = snapshot,
    plan = plan, tool = renoise.tool(), guards = {}, chunk = {},
    frames_per_step = frames_per_step,
    dither = normalized.dither and wav.new_dither() or nil,
    slot = 1, offset = 0, written_frames = 0, verified_frames = 0, finished = false,
  }, Job)
  job.timer = function()
    local ok, err = pcall(Job.step, job)
    if not ok then job:fail(err) end
  end
  local function watch(observable, callback)
    -- Retain before attachment to unwind partial setup.
    job.guards[#job.guards + 1] = { observable = observable, callback = callback }
    if not observable:has_notifier(callback) then observable:add_notifier(callback) end
  end
  local setup_ok, setup_err = pcall(function()
    local song = assert(renoise.song(), "Open a Renoise song first.")
    local function invalidate()
      job.invalid_reason = "Source samples changed. Restart the export."
    end
    local function cancel_document() job:cancel("Export canceled because the song or tool closed.") end
    watch(job.tool.app_release_document_observable, cancel_document)
    watch(job.tool.tool_will_unload_observable, cancel_document)
    watch(song.instruments_observable, invalidate)
    watch(instrument.samples_observable, invalidate)
    for _, sample in ipairs(instrument.samples) do
      watch(sample.sample_buffer_observable, invalidate)
      watch(sample.slice_markers_observable, invalidate)
    end
    local output, open_err = wav.open(path, plan.total_frames, snapshot.rate)
    if not output then error(open_err, 0) end
    job.output = output
    job.tool:add_timer(job.timer, TIMER_INTERVAL_MS)
  end)
  if not setup_ok then
    job.finished = true
    local cleanup_err = cleanup(job, true)
    return nil, tostring(setup_err) .. (cleanup_err and "\n" .. cleanup_err or "")
  end
  return job
end

return M
