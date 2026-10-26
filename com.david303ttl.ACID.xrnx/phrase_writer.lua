-- ACID 0.1: first native Renoise phrase integration proof.
-- No changes to pattern tracks, no slides, no automatic regeneration.
local sequencer = require("sequencer")
local pattrns = require("pattrns_writer")
local M = {}

M.LPB = 8
M.STEPS = 8
M.PHRASE_NAME = "ACID 0.1 TEST"
local busy = false
local current = nil

function M.fixture()
  local pattern = sequencer.new_pattern(M.STEPS)
  pattern.pitch_events = {
    {note=36, accent=false, slide=false},
    {note=39, accent=true, slide=false},
    {note=43, accent=false, slide=false},
    {note=41, accent=false, slide=false}
  }
  pattern.time_events = {"N","T","N","R","N","N","T","R"}
  return pattern
end

local function notify(job, message)
  if not job.cancelled and job.callback then
    local ok, err = pcall(job.callback, message)
    if not ok then print("[ACID] Status callback error: " .. tostring(err)) end
  end
end

local function unlink(job)
  if job.commit_observer and job.on_commit then
    pcall(function() job.commit_observer:remove_notifier(job.on_commit) end)
  end
  if job.idle_observer and job.on_idle then
    pcall(function() job.idle_observer:remove_notifier(job.on_idle) end)
  end
  job.on_commit, job.on_idle = nil, nil
end

local function complete(job, error_message, rendered_events)
  if current ~= job then return end
  unlink(job)
  busy = false
  current = nil
  if error_message then
    -- This prototype only creates a phrase in instruments with NO existing
    -- phrases. Remove that newly created test phrase on failure.
    pcall(function()
      if #job.instrument.phrases == 1
        and job.instrument.phrases[1].name == M.PHRASE_NAME then
        job.instrument:delete_phrase_at(1)
      end
    end)
    notify(job, "ACID generation failed: " .. tostring(error_message))
    return
  end
  notify(job, string.format(
    "Phrase 01 generated (%d events). Trigger a note with instrument %02X.",
    rendered_events, job.instrument_index - 1))
end

local function finalize(job, event_count, skipped)
  if current ~= job then return end
  if skipped ~= 0 then
    complete(job, "Renoise skipped " .. tostring(skipped) .. " event(s)")
    return
  end
  if event_count ~= job.expected_events then
    complete(job, string.format(
      "Expected %d rendered events, received %s",
      job.expected_events, tostring(event_count)))
    return
  end
  local ok, error_message = pcall(function()
    -- Rendered lines are normal native phrase data (not a running script).
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    job.phrase.lpb = M.LPB
    job.phrase.number_of_lines = M.STEPS * 2
    job.phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
    job.phrase.looping = false
    job.instrument.phrase_playback_mode =
      renoise.Instrument.PHRASES_PLAY_SELECTIVE
    job.instrument.phrase_program = 1
    job.instrument.phrase_editor_visible = true
  end)
  if not ok then
    complete(job, error_message)
    return
  end
  complete(job, nil, event_count)
end

local function render(job)
  if current ~= job then return end
  local script = job.phrase.script
  if script.compile_error and script.compile_error ~= "" then
    complete(job, "Script compilation: " .. script.compile_error)
    return
  end
  if script.runtime_error and script.runtime_error ~= "" then
    complete(job, "Script runtime: " .. script.runtime_error)
    return
  end
  notify(job, "ACID: rendering pattrns to native phrase...")
  local ok, error_message = pcall(function()
    script:render_to_pattern({
      lpb = M.LPB,
      max_events = M.STEPS + 8
    }, function(render_error, rendered_events, skipped_events)
      if current ~= job then return end
      if render_error and render_error ~= "" then
        complete(job, "Phrase rendering: " .. tostring(render_error))
      else
        finalize(job, rendered_events, skipped_events)
      end
    end)
  end)
  if not ok then complete(job, error_message) end
end

local function begin_wait(job)
  local ticks = 0
  -- committed_observable may fire before the compile error is updated.
  -- Wait for idle after commit before reading compile/runtime errors.
  job.on_idle = function()
    if current ~= job then return end
    ticks = ticks + 1
    if ticks > 500 then
      complete(job, "Timed out waiting for script compilation")
      return
    end
    if not job.committed or ticks < job.commit_tick + 2 then return end
    local ok, err = pcall(render, job)
    if not ok then complete(job, err) end
  end
  job.idle_observer = renoise.tool().app_idle_observable
  job.idle_observer:add_notifier(job.on_idle)
end

function M.cancel()
  if current then
    local job = current
    job.cancelled = true
    unlink(job)
    current = nil
    busy = false
  end
end

function M.generate(instrument_index, callback)
  if busy then return nil, "ACID is already generating a phrase" end
  if type(callback) ~= "function" then
    return nil, "Status callback required"
  end
  local song = renoise.song()
  if not song then return nil, "Open a song first" end
  if type(instrument_index) ~= "number" or instrument_index % 1 ~= 0
    or instrument_index < 1 or instrument_index > #song.instruments then
    return nil, "Choose a valid native sample instrument"
  end
  local instrument = song.instruments[instrument_index]
  if #instrument.phrases ~= 0 then
    return nil, "Use a sample instrument with no existing phrases for this test"
  end
  local has_sample_data = false
  for _, sample in ipairs(instrument.samples) do
    if sample.sample_buffer and sample.sample_buffer.has_sample_data then
      has_sample_data = true
      break
    end
  end
  if not has_sample_data then
    return nil, "Load a playable sample into the selected instrument first"
  end
  local source, meta = pattrns.generate(M.fixture())
  if not source then return nil, meta end
  if meta.slide_intentions ~= 0 then
    return nil, "Prototype must not render selective slides"
  end
  local job = {
    instrument = instrument, instrument_index = instrument_index,
    expected_events = meta.note_count + meta.off_count,
    callback = callback, committed = false, commit_tick = 0,
    cancelled = false
  }

  local ok, error_message = pcall(function()
    -- First and only phrase in the target instrument. Never overwrite
    -- existing phrase content or any song pattern notes.
    job.phrase = instrument:insert_phrase_at(1)
    job.phrase.name = M.PHRASE_NAME
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_SCRIPT
    local script = job.phrase.script
    script.paragraphs = {source}
    job.commit_observer = script.committed_observable
    job.on_commit = function()
      job.committed = true
      -- Recorded from idle tick counter below; next idle is sufficient
      -- to check result after the asynchronous commit notification.
      job.commit_tick = job.tick or 0
    end
    job.commit_observer:add_notifier(job.on_commit)
    current = job
    busy = true
    local old_begin_wait = begin_wait
    old_begin_wait(job)
    -- Track idle ticks for post-commit settle.
    local idle = job.on_idle
    job.on_idle = function()
      job.tick = (job.tick or 0) + 1
      idle()
    end
    -- Existing notifier must be changed to point at the wrapper.
    job.idle_observer:remove_notifier(idle)
    job.idle_observer:add_notifier(job.on_idle)
    script:commit()
  end)
  if not ok then
    if current == job then
      complete(job, error_message)
    else
      pcall(function()
        if job.phrase and #instrument.phrases == 1
          and instrument.phrases[1].name == M.PHRASE_NAME then
          instrument:delete_phrase_at(1)
        end
      end)
    end
    return nil, tostring(error_message)
  end
  notify(job, "ACID: compiling test phrase...")
  return true
end

return M
