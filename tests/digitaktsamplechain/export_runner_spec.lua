dofile('tests/bootstrap.lua')('digitaktsamplechain')
local runner = require("export_runner")
local settings = require("chain_options")
local host = require("host_stub")
local wav = require("wav_writer")
local SLOW_JOB_FRAMES, PROGRESS_JOB_FRAMES = 4000, 128
local LEGACY_TICK_LIMIT, WAV_HEADER_BYTES, WAV_FRAME_BYTES = 100, 44, 2
local SIMULATED_CLOCK_STEP_SECONDS = 1
local REAL_CLOCK_READ_SECONDS, REAL_CLOCK_SOURCE_FRAMES = 0.001, 256

-- A stalled or prematurely detached timer must not make the driver loop forever.
for _, failure in ipairs({ "stalled", "detached", "terminal", "regressed", "overflow", "unexpected" }) do
  local source = host.instrument({ host.buffer(1) })
  local tool = host.host(source)
  local job = { plan = { total_frames = 1 }, written_frames = 0, verified_frames = 0,
    finished = failure == "terminal" }
  if failure == "regressed" then job.written_frames = 1 end
  job.timer = function()
    if failure == "detached" then
      job.written_frames = 1
      tool:remove_timer(job.timer)
    elseif failure == "regressed" then
      job.written_frames, job.verified_frames = 0, 1
    elseif failure == "overflow" then
      job.written_frames = 2
    end
  end
  local timer = failure == "unexpected" and function() end or job.timer
  tool:add_timer(timer, 1)
  local ok, err = pcall(host.drive, tool, job)
  local expected = failure == "stalled" and "made no progress"
    or failure == "detached" and "stopped before completion"
    or failure == "regressed" and "progress counters regressed"
    or failure == "overflow" and "progress exceeds planned frames"
    or failure == "unexpected" and "unexpected export timer" or "did not detach"
  assert(not ok and tostring(err):find(expected, 1, true), tostring(err))
  if tool:has_timer(timer) then tool:remove_timer(timer) end
end

-- A progressing job can legitimately take more ticks than the old fixed cap.
do
  local tool = host.host(host.instrument({ host.buffer(1) }))
  local job = { plan = { total_frames = PROGRESS_JOB_FRAMES }, written_frames = 0,
    verified_frames = 0, finished = false }
  job.timer = function()
    if job.written_frames < job.plan.total_frames then
      job.written_frames = job.written_frames + 1
    else
      job.verified_frames = job.verified_frames + 1
      if job.verified_frames == job.plan.total_frames then
        job.finished = true
        tool:remove_timer(job.timer)
      end
    end
  end
  tool:add_timer(job.timer, 1)
  assert(host.drive(tool, job) > LEGACY_TICK_LIMIT and job.finished)
end

local function clean(tool, song, instrument)
  host.assert_no_staging_directories()
  assert(next(tool.timers) == nil, "timer leaked")
  local observables = { tool.app_release_document_observable, tool.tool_will_unload_observable,
    song.instruments_observable, instrument.samples_observable }
  for _, sample in ipairs(instrument.samples) do
    observables[#observables + 1] = sample.sample_buffer_observable
    observables[#observables + 1] = sample.slice_markers_observable
  end
  for _, observable in ipairs(observables) do assert(next(observable.callbacks) == nil, "notifier leaked") end
end

local path = host.temp_path()
local first_values = { 0.5, -0.25, 0.125 }
local instrument = host.instrument({
  host.buffer(3, 48000, 1, function(_, frame) return first_values[frame] end),
  host.buffer(5, 48000, 1, function() return 0.2 end),
})
local tool, song = host.host(instrument)
local result, failure
local callbacks = {
  on_finish = function(info) result = info end,
  on_error = function(err) failure = err end,
}
local job = assert(runner.start(instrument, settings.defaults(), path, callbacks))
assert(instrument.samples[1].sample_buffer.reads == 0, "start should not read full audio")
host.drive(tool, job)
assert(job.finished and result and not failure)
assert(result.mode == "spaced" and result.frames == 20 and result.slot_count == 4)
assert(result.slot_sec == 5 / 48000 and result.total_sec == 20 / 48000)
assert(host.read_file(path):sub(45) == string.char(
  0, 64, 0, 224, 0, 16, 0, 0, 0, 0,
  154, 25, 154, 25, 154, 25, 154, 25, 154, 25) .. string.rep("\0", 20))
clean(tool, song, instrument)
job.timer() -- Delayed callbacks after completion are inert.
assert(os.remove(path))

-- Budget-limited rendering completes and preserves the staged audio.
do
  local source = host.instrument({ host.buffer(SLOW_JOB_FRAMES) })
  local slow_tool, slow_song = host.host(source)
  local options = settings.defaults()
  options.mode = "chain"
  local completed, failed
  local slow_job = assert(runner.start(source, options, path, {
    on_finish = function(info) completed = info end,
    on_error = function(message) failed = message end,
  }))
  local original_clock, elapsed = os.clock, 0
  os.clock = function()
    elapsed = elapsed + SIMULATED_CLOCK_STEP_SECONDS
    return elapsed
  end
  local ok, ticks = pcall(host.drive, slow_tool, slow_job)
  os.clock = original_clock
  if not ok then slow_job:cancel(); error(ticks) end
  assert(ticks > 1 and completed and not failed)
  assert(completed.frames == SLOW_JOB_FRAMES)
  assert(slow_job.written_frames == SLOW_JOB_FRAMES and slow_job.verified_frames == SLOW_JOB_FRAMES)
  local bytes = host.read_file(path)
  assert(#bytes == WAV_HEADER_BYTES + SLOW_JOB_FRAMES * WAV_FRAME_BYTES)
  assert(bytes:sub(WAV_HEADER_BYTES + 1) == string.rep(string.char(0, 32), SLOW_JOB_FRAMES))
  clean(slow_tool, slow_song, source)
  assert(os.remove(path))
  tool, song = host.host(instrument)
end

-- A slow source also yields against the real clock, not just the fake clock.
do
  local source = host.instrument({ host.buffer(REAL_CLOCK_SOURCE_FRAMES, nil, nil, function()
    local started = os.clock()
    while os.clock() - started < REAL_CLOCK_READ_SECONDS do end
    return 0.25
  end) })
  local slow_tool, slow_song = host.host(source)
  local options = settings.defaults()
  options.mode = "chain"
  local completed, failed
  local slow_job = assert(runner.start(source, options, path, {
    on_finish = function(info) completed = info end,
    on_error = function(message) failed = message end,
  }))
  slow_job.timer()
  assert(slow_job.written_frames > 0 and slow_job.written_frames < slow_job.plan.total_frames,
    "real-clock budget did not yield")
  host.drive(slow_tool, slow_job)
  assert(completed and not failed and completed.frames == REAL_CLOCK_SOURCE_FRAMES)
  clean(slow_tool, slow_song, source)
  assert(os.remove(path))
  tool, song = host.host(instrument)
end

-- End-to-end fixed padded geometry, including trailing silent slots.
local opts = settings.defaults()
opts.zero_pad, opts.slot_count, opts.dither = true, 4, true
result = nil
job = assert(runner.start(instrument, opts, path, callbacks))
host.drive(tool, job)
assert(result.frames == 4 * (5 + 128) and result.total_sec == result.frames / 48000)
local content = host.read_file(path)
assert(#content == 44 + result.frames * 2)
assert(content:sub(45, 44 + 128) == string.rep("\0", 128))
assert(content:sub(45 + 2 * 133 * 2) == string.rep("\0", 2 * 133 * 2))
clean(tool, song, instrument)
assert(os.remove(path))

-- Per-export dither is deterministic and must not consume or reseed global RNG.
local random, randomseed = math.random, math.randomseed
math.random = function() error("global RNG used") end
math.randomseed = function() error("global RNG reseeded") end
opts = settings.defaults()
opts.dither = true
local function dither_export()
  local started = assert(runner.start(instrument, opts, path, callbacks))
  host.drive(tool, started)
  assert(started.finished and not failure)
  return host.read_file(path)
end
local ok, first, second = pcall(function() return dither_export(), dither_export() end)
math.random, math.randomseed = random, randomseed
assert(ok and first == second, tostring(first))
assert(os.remove(path))

-- A long source is streamed, not copied into a chain-sized Lua table.
local long = host.instrument({ host.buffer(200000) })
tool, song = host.host(long)
host.write_file(path, "original")
local canceled = 0
job = assert(runner.start(long, settings.defaults(), path, {
  on_cancel = function() canceled = canceled + 1 end,
  on_error = function(err) error(err) end,
}))
local temporary = job.output.temporary
assert(long.samples[1].sample_buffer.reads == 0)
job.timer()
assert(long.samples[1].sample_buffer.reads > 0 and long.samples[1].sample_buffer.reads < 200000)
assert(job.written_frames < 200000 and not job.finished)
assert(host.read_file(path) == "original")
job:cancel()
job:cancel()
job.timer()
assert(job.finished and job.canceled and canceled == 1)
assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
assert(job.chunk == nil and job.snapshot == nil)
clean(tool, song, long)

-- Cancel before the first tick also preserves an existing destination.
job = assert(runner.start(long, settings.defaults(), path, {}))
temporary = job.output.temporary
job:cancel()
assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
clean(tool, song, long)

-- Failed teardown retains its handles and retries them on a later timer tick.
do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  host.write_file(path, "original")
  local timer_removals, notifier_removals, aborts = 0, 0, 0
  local original_remove_timer = tool.remove_timer
  tool.remove_timer = function(self, timer)
    timer_removals = timer_removals + 1
    if timer_removals == 1 then return end
    if timer_removals == 2 then error("simulated timer cleanup failure") end
    return original_remove_timer(self, timer)
  end
  local observable = source.samples_observable
  local original_remove_notifier = observable.remove_notifier
  observable.remove_notifier = function(self, callback)
    notifier_removals = notifier_removals + 1
    if notifier_removals <= 2 then error("simulated notifier cleanup failure") end
    return original_remove_notifier(self, callback)
  end
  local canceled, cancel_message = 0, nil
  job = assert(runner.start(source, settings.defaults(), path, {
    on_cancel = function(message) canceled, cancel_message = canceled + 1, message end,
  }))
  local output = job.output
  local original_abort = output.abort
  output.abort = function(self)
    aborts = aborts + 1
    if aborts <= 2 then return nil, "simulated output cleanup failure" end
    return original_abort(self)
  end
  temporary = output.temporary

  job:cancel()
  assert(canceled == 1 and cancel_message:find("simulated", 1, true))
  assert(job.output == output and #job.guards > 0 and tool:has_timer(job.timer))
  assert(aborts == 2 and notifier_removals == 2 and timer_removals == 0)

  job.timer()
  assert(job.output == nil and #job.guards == 0 and tool:has_timer(job.timer))
  assert(aborts == 3 and notifier_removals == 3 and timer_removals == 2)

  job.timer()
  assert(job.output == nil and #job.guards == 0 and not tool:has_timer(job.timer))
  assert(timer_removals == 3)
  assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
  clean(tool, song, source)
end

-- Buffer/list notifications and dimensions invalidate an in-flight export.
for _, change in ipairs({ "buffer", "samples", "instruments", "slices", "frames", "rate", "channels", "empty" }) do
  local source = host.instrument({ host.buffer(100000) })
  tool, song = host.host(source)
  failure, result = nil, nil
  job = assert(runner.start(source, settings.defaults(), path, callbacks))
  temporary = job.output.temporary
  if change == "buffer" then source.samples[1].sample_buffer_observable:notify()
  elseif change == "samples" then source.samples_observable:notify()
  elseif change == "instruments" then song.instruments_observable:notify()
  elseif change == "slices" then source.samples[1].slice_markers_observable:notify()
  elseif change == "frames" then source.samples[1].sample_buffer.number_of_frames = 1
  elseif change == "rate" then source.samples[1].sample_buffer.sample_rate = 44100
  elseif change == "channels" then source.samples[1].sample_buffer.number_of_channels = 2
  else source.samples[1].sample_buffer.has_sample_data = false end
  host.drive(tool, job)
  assert(job.finished and failure and failure:find("changed") and not result)
  assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
  clean(tool, song, source)
end

for _, lifetime in ipairs({ "app_release_document_observable", "tool_will_unload_observable" }) do
  tool, song = host.host(long)
  canceled = 0
  job = assert(runner.start(long, settings.defaults(), path, {
    on_cancel = function() canceled = canceled + 1 end,
  }))
  temporary = job.output.temporary
  tool[lifetime]:notify()
  assert(job.finished and job.canceled and canceled == 1)
  assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
  clean(tool, song, long)
end

-- Readback catches same-size edits to frames emitted before verification.
local changed_value = false
local changing = host.instrument({ host.buffer(100, 48000, 1, function(_, frame)
  if frame == 1 and changed_value then return 0.75 end
  return 0.25
end) })
tool, song = host.host(changing)
host.write_file(path, "original")
result, failure = nil, nil
job = assert(runner.start(changing, settings.defaults(), path, {
  on_error = function(err) failure = err end,
  on_progress = function(message)
    if message:find("Verifying", 1, true) then changed_value = true end
  end,
}))
temporary = job.output.temporary
host.drive(tool, job)
assert(failure and failure:find("changed", 1, true) and not result)
assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
clean(tool, song, changing)

-- A source edit in the last writing progress callback is rechecked immediately.
local final_write = host.instrument({ host.buffer(40000) })
tool, song = host.host(final_write)
failure, result = nil, nil
local final_options = settings.defaults()
final_options.mode = "chain"
job = assert(runner.start(final_write, final_options, path, {
  on_error = function(err) failure = err end,
  on_progress = function()
    if job and job.written_frames > 0 and not job.verifying then
      final_write.samples_observable:notify()
    end
  end,
}))
temporary = job.output.temporary
host.drive(tool, job)
assert(failure and failure:find("changed", 1, true) and not result)
assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
clean(tool, song, final_write)

-- Cancellation during verification closes and removes the staging file.
local verifying = host.instrument({ host.buffer(100) })
tool, song = host.host(verifying)
canceled = 0
job = assert(runner.start(verifying, settings.defaults(), path, {
  on_cancel = function() canceled = canceled + 1 end,
  on_progress = function(message)
    if message:find("Verifying", 1, true) then job:cancel() end
  end,
}))
temporary = job.output.temporary
host.drive(tool, job)
assert(job.finished and job.canceled and canceled == 1)
assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
clean(tool, song, verifying)

-- Read/encoding/write/commit failures remove staging files without success callbacks.
for _, kind in ipairs({ "read", "nan", "write", "verify", "commit" }) do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  result, failure = nil, nil
  job = assert(runner.start(source, settings.defaults(), path, callbacks))
  temporary = job.output.temporary
  if kind == "read" then source.samples[1].sample_buffer.sample_data = function() error("source unavailable") end
  elseif kind == "nan" then source.samples[1].sample_buffer.sample_data = function() return 0/0 end
  else job.output[kind] = function() return nil, "simulated " .. kind .. " failure" end end
  host.drive(tool, job)
  assert(failure and not result and job.finished)
  assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
  clean(tool, song, source)
end

-- Failed notifier/timer setup rolls back partially attached host resources.
for _, kind in ipairs({ "notifier", "timer" }) do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  if kind == "notifier" then
    local original = source.samples_observable.add_notifier
    source.samples_observable.add_notifier = function(self, callback)
      original(self, callback)
      error("simulated notifier setup failure")
    end
  else
    local original = tool.add_timer
    tool.add_timer = function(self, timer, interval)
      original(self, timer, interval)
      error("simulated timer setup failure")
    end
  end
  local rejected, err = runner.start(source, settings.defaults(), path, {})
  assert(not rejected and err:find("simulated"))
  clean(tool, song, source)
  assert(host.read_file(path) == "original")
end

-- Setup rollback retries a notifier left attached before export timer setup.
do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  local observable = source.samples_observable
  local original_add = observable.add_notifier
  local original_remove = observable.remove_notifier
  local removals = 0
  observable.add_notifier = function(self, callback)
    original_add(self, callback)
    error("simulated pre-timer notifier setup failure")
  end
  observable.remove_notifier = function(self, callback)
    removals = removals + 1
    if removals <= 2 then error("simulated pre-timer notifier cleanup failure") end
    return original_remove(self, callback)
  end

  local rejected, err = runner.start(source, settings.defaults(), path, {})
  assert(not rejected and err:find("pre%-timer notifier setup failure"))
  assert(err:find("Cleanup retry scheduled", 1, true) and removals == 2)
  local retry_timer = next(tool.timers)
  assert(retry_timer, "rollback did not schedule a retry timer")
  retry_timer()
  assert(removals == 3 and not tool:has_timer(retry_timer))
  clean(tool, song, source)
end

-- A failed initial timer registration still permits bounded output-abort retry.
do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  host.write_file(path, "original")
  local original_add_timer = tool.add_timer
  local timer_additions, aborts, output, temporary = 0, 0, nil, nil
  tool.add_timer = function(self, timer, interval)
    timer_additions = timer_additions + 1
    if timer_additions == 1 then error("simulated timer setup failure before registration") end
    return original_add_timer(self, timer, interval)
  end
  local original_open = wav.open
  wav.open = function(...)
    local opened, open_err = original_open(...)
    if opened then
      output = opened
      temporary = opened.temporary
      local original_abort = opened.abort
      opened.abort = function(self)
        aborts = aborts + 1
        if aborts <= 2 then return nil, "simulated pre-timer output cleanup failure" end
        return original_abort(self)
      end
    end
    return opened, open_err
  end

  local rejected, err = runner.start(source, settings.defaults(), path, {})
  wav.open = original_open
  assert(not rejected and err:find("timer setup failure before registration", 1, true))
  assert(err:find("Cleanup retry scheduled", 1, true) and aborts == 2)
  assert(timer_additions == 2 and output and next(tool.timers))
  local retry_timer = next(tool.timers)
  retry_timer()
  assert(aborts == 3 and not tool:has_timer(retry_timer))
  assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
  clean(tool, song, source)
end

-- Failed retry scheduling is reported rather than claiming rollback recovery.
do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  local observable = source.samples_observable
  local original_add = observable.add_notifier
  local original_remove = observable.remove_notifier
  local removals = 0
  observable.add_notifier = function(self, callback)
    original_add(self, callback)
    error("simulated setup failure")
  end
  observable.remove_notifier = function(self, callback)
    removals = removals + 1
    if removals <= 2 then error("simulated persistent cleanup failure") end
    return original_remove(self, callback)
  end
  tool.add_timer = function() error("simulated retry scheduler failure") end

  local rejected, err = runner.start(source, settings.defaults(), path, {})
  assert(not rejected and err:find("Could not schedule cleanup retry", 1, true))
  assert(err:find("simulated retry scheduler failure", 1, true) and not next(tool.timers))
  observable:notify()
  assert(removals == 3)
  clean(tool, song, source)
end

-- Persistent rollback failure exhausts the finite retry budget and reports it.
do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  host.write_file(path, "original")
  local original_add_timer = tool.add_timer
  local timer_additions, aborts, output, temporary, finish_abort = 0, 0, nil, nil, nil
  tool.add_timer = function(self, timer, interval)
    timer_additions = timer_additions + 1
    if timer_additions == 1 then error("simulated initial timer registration failure") end
    return original_add_timer(self, timer, interval)
  end
  local original_open = wav.open
  wav.open = function(...)
    local opened, open_err = original_open(...)
    if opened then
      output = opened
      temporary = opened.temporary
      finish_abort = opened.abort
      output.abort = function(self)
        aborts = aborts + 1
        return nil, "simulated persistent output abort failure"
      end
    end
    return opened, open_err
  end
  local original_print, messages = print, {}
  print = function(message) messages[#messages + 1] = message end

  local rejected, err = runner.start(source, settings.defaults(), path, {})
  wav.open = original_open
  assert(not rejected and err:find("Cleanup retry scheduled", 1, true))
  local retry_timer = next(tool.timers)
  assert(retry_timer and aborts == 2)
  retry_timer()
  assert(tool:has_timer(retry_timer) and aborts == 4)
  retry_timer()
  print = original_print

  assert(not tool:has_timer(retry_timer) and aborts == 6)
  assert(#messages == 1 and messages[1]:find("retries exhausted", 1, true))
  assert(finish_abort(output))
  assert(host.read_file(path) == "original" and not io.open(temporary, "rb"))
  clean(tool, song, source)
end

-- Preflight validation runs before filesystem output or timer attachment.
tool, song = host.host(long)
assert(not runner.start(long, {}, path, {}))
assert(not runner.start(long, settings.defaults(), "", {}))
local huge = host.instrument({ host.buffer(2200000000) })
assert(not runner.start(huge, settings.defaults(), path, {}))
assert(huge.samples[1].sample_buffer.reads == 0)
local non_native = host.instrument({ host.buffer(2, 0) })
local rejected, err = runner.start(non_native, settings.defaults(), path, {})
assert(not rejected and err:find("invalid sample rate"))
opts = settings.defaults()
opts.slot_count = 4
local too_many = host.instrument({ host.buffer(1), host.buffer(1), host.buffer(1), host.buffer(1), host.buffer(1) })
rejected, err = runner.start(too_many, opts, path, {})
assert(not rejected and err:find("do not fit"))
assert(host.read_file(path) == "original")
clean(tool, song, long)
assert(os.remove(path))

-- Mixed source rates use converted lengths for both layouts and cross chunks.
for _, mode in ipairs({ "chain", "spaced" }) do
  local source = host.instrument({ host.buffer(4410, 44100), host.buffer(19200, 96000) })
  tool, song = host.host(source)
  opts = settings.defaults()
  opts.mode = mode
  result, failure = nil, nil
  job = assert(runner.start(source, opts, path, callbacks))
  host.drive(tool, job)
  assert(result and not failure)
  local expected = mode == "chain" and 14400 or 38400
  assert(result.frames == expected and result.sample_rate == 48000)
  local bytes = host.read_file(path)
  assert(#bytes == 44 + expected * 2)
  assert(bytes:sub(25, 28) == string.char(128, 187, 0, 0))
  assert(source.samples[1].sample_buffer.sample_rate == 44100)
  assert(source.samples[2].sample_buffer.number_of_frames == 19200)
  clean(tool, song, source)
  assert(os.remove(path))
end

-- Terminal callback failures are reported once after resources are released.
for _, terminal in ipairs({ "on_finish", "on_error", "on_cancel" }) do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  local calls, messages = 0, {}
  local original_print = print
  print = function(message) messages[#messages + 1] = message end
  local ok, err = pcall(function()
    job = assert(runner.start(source, settings.defaults(), path, {
      [terminal] = function()
        calls = calls + 1
        clean(tool, song, source)
        error("simulated terminal failure")
      end,
    }))
    if terminal == "on_error" then source.samples_observable:notify()
    elseif terminal == "on_cancel" then job:cancel() end
    host.drive(tool, job)
    job.timer()
    job:cancel()
    job:fail("late failure")
  end)
  print = original_print
  assert(ok, err)
  assert(calls == 1 and #messages == 1)
  assert(job.callback_error:find(terminal, 1, true))
  assert(messages[1]:find("simulated terminal failure", 1, true))
  assert(next(job.callbacks) == nil)
  clean(tool, song, source)
  if terminal == "on_finish" then assert(os.remove(path)) end
end

-- Slow reads yield during both passes without changing dither or slot offsets.
do
  local elapsed, clock = 0, os.clock
  local source = host.instrument({ host.buffer(200, 192000, 1, function()
    elapsed = elapsed + 0.001
    return 0.25
  end) })
  tool, song = host.host(source)
  opts = settings.defaults()
  opts.mode, opts.dither = "chain", true
  result, failure = nil, nil
  job = assert(runner.start(source, opts, path, callbacks))
  os.clock = function() return elapsed end
  local ok, err = pcall(function()
    job.timer()
    assert(job.written_frames > 0 and job.written_frames < job.plan.total_frames)
    host.drive(tool, job, function() return job.verifying end)
    job.timer()
    assert(job.verified_frames > 0 and job.verified_frames < job.plan.total_frames)
    host.drive(tool, job)
  end)
  os.clock = clock
  assert(ok, err)
  assert(result and not failure)
  local budgeted = host.read_file(path)
  clean(tool, song, source)
  job = assert(runner.start(source, opts, path, callbacks))
  host.drive(tool, job)
  assert(host.read_file(path) == budgeted, "tick budget changed PCM or dither")
  clean(tool, song, source)
  assert(os.remove(path))
end
print("DigitaktSampleChain streaming, source lifetime and cancellation specs passed")
