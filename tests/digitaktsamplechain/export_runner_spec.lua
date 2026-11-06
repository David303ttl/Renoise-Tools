dofile('tests/bootstrap.lua')('digitaktsamplechain')
local runner = require("export_runner")
local settings = require("chain_options")
local host = require("host_stub")
local wav = require("wav_writer")
local SLOW_JOB_FRAMES, PROGRESS_JOB_FRAMES = 4000, 128
local MIN_PROGRESS_TICKS, WAV_HEADER_BYTES, WAV_FRAME_BYTES = 100, 44, 2
local SIMULATED_CLOCK_STEP_SECONDS = 1
local REAL_CLOCK_READ_SECONDS, REAL_CLOCK_SOURCE_FRAMES = 0.001, 256

-- A stalled or prematurely detached timer must not make the driver loop forever.
for _, failure in ipairs({ "stalled", "detached", "terminal", "regressed", "overflow", "unexpected" }) do
  local source = host.instrument({ host.buffer(1) })
  local tool = host.host(source)
  local job = { plan = { total_frames = 1 }, written_frames = 0,
    finished = failure == "terminal" }
  if failure == "regressed" then job.written_frames = 1 end
  job.timer = function()
    if failure == "detached" then
      job.written_frames = 1
      tool:remove_timer(job.timer)
    elseif failure == "regressed" then
      job.written_frames = 0
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

-- The driver bounds ticks by planned work, including small incremental writes.
do
  local tool = host.host(host.instrument({ host.buffer(1) }))
  local job = { plan = { total_frames = PROGRESS_JOB_FRAMES }, written_frames = 0, finished = false }
  job.timer = function()
    job.written_frames = job.written_frames + 1
    if job.written_frames == job.plan.total_frames then
      job.finished = true
      tool:remove_timer(job.timer)
    end
  end
  tool:add_timer(job.timer, 1)
  assert(host.drive(tool, job) > MIN_PROGRESS_TICKS and job.finished)
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
assert(instrument.samples[1].sample_buffer.reads == 3 and instrument.samples[2].sample_buffer.reads == 5, "source should be read once")
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
  assert(slow_job.written_frames == SLOW_JOB_FRAMES)
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

-- A file cleanup failure is reported after callbacks are detached, without retries.
do
  local source = host.instrument({ host.buffer(100) })
  tool, song = host.host(source)
  host.write_file(path, "original")
  local message
  job = assert(runner.start(source, settings.defaults(), path, {
    on_cancel = function(value) message = value end,
  }))
  local output = job.output
  temporary = output.temporary
  local remove, attempts = os.remove, 0
  os.remove = function(name)
    if name == temporary then
      attempts = attempts + 1
      return nil, "simulated cleanup failure"
    end
    return remove(name)
  end
  job:cancel()
  job:cancel()
  job.timer()
  os.remove = remove
  assert(attempts == 1 and message:find(temporary, 1, true))
  assert(message:find("simulated cleanup failure", 1, true))
  assert(next(tool.timers) == nil and #job.guards == 0 and job.snapshot == nil)
  assert(host.read_file(path) == "original")
  assert(output:abort())
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

-- Read/encoding/write/commit failures remove staging files without success callbacks.
for _, kind in ipairs({ "read", "nan", "write", "commit" }) do
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
    local original = tool.app_release_document_observable.add_notifier
    tool.app_release_document_observable.add_notifier = function(self, callback)
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
    if terminal == "on_error" then source.samples[1].sample_buffer.sample_data = function() error("source unavailable") end
    elseif terminal == "on_cancel" then job:cancel() end
    host.drive(tool, job)
    job.timer()
    job:cancel()
    job:fail("late failure")
  end)
  print = original_print
  assert(ok, err)
  assert(calls == 1 and #messages == 1)
  assert(messages[1]:find(terminal, 1, true))
  assert(messages[1]:find("simulated terminal failure", 1, true))
  assert(next(job.callbacks) == nil)
  clean(tool, song, source)
  if terminal == "on_finish" then assert(os.remove(path)) end
end

-- Slow reads yield without changing dither or slot offsets.
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
