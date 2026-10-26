-- ACID 0.1: first native Renoise phrase integration proof.
-- No changes to pattern tracks, no slides, no automatic regeneration.
local sequencer = require("model.sequencer")
local pattrns = require("writers.pattrns_writer")
local compiler = require("model.compiler")
local validator = require("writers.phrase_validator")
local articulation = require("model.articulation")
local control = require("model.control_signals")
local gates = require("writers.gate_writer")
local ownership = require("writers.phrase_ownership")
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
    pcall(function()
      if job.temporary and job.instrument.phrases[#job.instrument.phrases]==job.phrase then
        job.instrument:delete_phrase_at(#job.instrument.phrases)
      end
    end)
    notify(job, "ACID generation failed: " .. tostring(error_message))
    return
  end
  notify(job, string.format(
    "Phrase %02d generated (%d notes, %d OFF; %d raw events). Instrument %02X.",
    job.target_index, rendered_events.notes, rendered_events.offs,
    rendered_events.raw_events, job.instrument_index - 1) ..
    (job.mode=="baseline" and "" or
     " | "..job.mode.." articulation test applied"))
end

local function finalize(job, event_count, skipped)
  if current ~= job then return end
  if skipped ~= 0 then
    complete(job, "Renoise skipped " .. tostring(skipped) .. " event(s)")
    return
  end
  -- Pattrns may count no-output pulses among its raw rendered events.
  -- Inspect the *actual phrase cells* to validate musical note/off events.
  if type(event_count) ~= "number" or event_count < job.expected_events then
    complete(job, string.format(
      "Too few raw events: expected at least %d, received %s",
      job.expected_events, tostring(event_count)))
    return
  end
  local result, validation_error = validator.verify(job.phrase, job.plan, 2)
  if not result then
    complete(job, validation_error)
    return
  end
  if job.mode ~= "baseline" then
    local timeline, timeline_err=control.compile(job.pattern,{gate_fraction=0.5})
    if not timeline then complete(job,timeline_err);return end
    local gate_result,gate_err=gates.apply(job.phrase,timeline)
    if not gate_result then complete(job,gate_err);return end
    if job.mode=="slide" or job.mode=="mono" then
      -- Pure native Gxx comparison; mono instrument configuration remains
      -- user-owned until we can validate envelope behavior and restore safely.
      local glide_result,glide_err=articulation.apply(
        job.phrase,job.plan,2,job.glide_rate,false)
      if not glide_result then complete(job,glide_err);return end
    end
  end
  local ok, error_message = pcall(function()
    -- Rendered lines are normal native phrase data (not a running script).
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    job.phrase.lpb = M.LPB
    job.phrase.number_of_lines = job.plan.length * 2
    job.phrase.name = M.PHRASE_NAME
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
  local safe, swap_err=pcall(function()
    if job.replace then
      local dest=job.instrument.phrases[job.target_index]
      local status=ownership.status(dest)
      if status~="owned" and not (status=="legacy" and job.adopt_legacy) then
        error("Target phrase changed during rendering; not overwritten")
      end
      dest:copy_from(job.phrase)
      local newname,sealerr=ownership.make_name(dest)
      if not newname then error(sealerr) end
      dest.name=newname
      job.instrument:delete_phrase_at(#job.instrument.phrases)
      job.temporary=false
    else
      local newname,sealerr=ownership.make_name(job.phrase)
      if not newname then error(sealerr) end
      job.phrase.name=newname
      job.temporary=false
    end
  end)
  if not safe then complete(job,swap_err);return end
  result.raw_events = event_count
  complete(job, nil, result)
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
      max_events = job.plan.length + 8
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

function M.generate(instrument_index, callback, mode, custom_pattern, adopt_legacy)
  if busy then return nil, "ACID is already generating a phrase" end
  mode=mode or "baseline"
  if mode~="baseline" and mode~="retrigger" and mode~="slide" and mode~="mono" then
    return nil,"Invalid playback test mode"
  end
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
  local replace=false
  local target_index=1
  if #instrument.phrases>0 then
    if #instrument.phrases~=1 then
      return nil,"Multiple phrases found; ACID 0.1 will not overwrite any of them"
    end
    local status=ownership.status(instrument.phrases[1])
    if status=="owned" or (status=="legacy" and adopt_legacy==true) then
      replace=true
    elseif status=="legacy" then
      return nil,"Legacy ACID test phrase: enable Adopt legacy once, then regenerate"
    else
      return nil,"Phrase is not safely owned by ACID (or was manually edited)"
    end
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
  local fixture=custom_pattern or M.fixture()
  if not custom_pattern and (mode=="slide" or mode=="mono") then fixture.pitch_events[1].slide=true end
  local plan, compile_error = compiler.compile(fixture)
  if not plan then return nil, compile_error end
  local source, meta = pattrns.emit(plan)
  if not source then return nil, meta end
  if meta.slide_intentions ~= 0 and mode ~= "slide" and mode ~= "mono" and custom_pattern==nil then
    return nil, "Prototype must not render selective slides"
  end
  local job = {
    instrument = instrument, instrument_index = instrument_index,
    expected_events = meta.note_count + meta.off_count,
    plan = plan, pattern=fixture, mode=mode, glide_rate=0x20,
    replace=replace,adopt_legacy=adopt_legacy==true,target_index=target_index,temporary=true,
    callback = callback, committed = false, commit_tick = 0,
    cancelled = false
  }

  local ok, error_message = pcall(function()
    -- First and only phrase in the target instrument. Never overwrite
    -- existing phrase content or any song pattern notes.
    job.phrase = instrument:insert_phrase_at(#instrument.phrases+1)
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
        if job.phrase and instrument.phrases[#instrument.phrases] == job.phrase then
          instrument:delete_phrase_at(#instrument.phrases)
        end
      end)
    end
    return nil, tostring(error_message)
  end
  notify(job, "ACID: compiling test phrase...")
  return true
end

return M
