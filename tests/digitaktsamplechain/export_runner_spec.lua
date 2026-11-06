dofile('tests/bootstrap.lua')('digitaktsamplechain')
local runner = require("export_runner")
local settings = require("chain_options")
local host = require("host_stub")
local MAX_TIMER_STEPS = 100

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

local function drive(tool)
  local iterations = 0
  while next(tool.timers) do
    local timer = next(tool.timers)
    timer()
    iterations = iterations + 1
    assert(iterations < MAX_TIMER_STEPS, "job did not terminate")
  end
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
drive(tool)
assert(job.finished and result and not failure)
assert(result.mode == "spaced" and result.frames == 20 and result.slot_count == 4)
assert(result.slot_sec == 5 / 48000 and result.total_sec == 20 / 48000)
assert(host.read_file(path):sub(45) == string.char(
  0, 64, 0, 224, 0, 16, 0, 0, 0, 0,
  154, 25, 154, 25, 154, 25, 154, 25, 154, 25) .. string.rep("\0", 20))
clean(tool, song, instrument)
job.timer() -- Delayed callbacks after completion are inert.
assert(os.remove(path))

-- End-to-end fixed padded geometry, including trailing silent slots.
local opts = settings.defaults()
opts.zero_pad, opts.slot_count, opts.dither = true, 4, true
result = nil
job = assert(runner.start(instrument, opts, path, callbacks))
drive(tool)
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
  drive(tool)
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
  drive(tool)
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
drive(tool)
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
drive(tool)
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
drive(tool)
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
  drive(tool)
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
  drive(tool)
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
    drive(tool)
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
    while not job.verifying do job.timer() end
    job.timer()
    assert(job.verified_frames > 0 and job.verified_frames < job.plan.total_frames)
    drive(tool)
  end)
  os.clock = clock
  assert(ok, err)
  assert(result and not failure)
  local budgeted = host.read_file(path)
  clean(tool, song, source)
  job = assert(runner.start(source, opts, path, callbacks))
  drive(tool)
  assert(host.read_file(path) == budgeted, "tick budget changed PCM or dither")
  clean(tool, song, source)
  assert(os.remove(path))
end
print("DigitaktSampleChain streaming, source lifetime and cancellation specs passed")
