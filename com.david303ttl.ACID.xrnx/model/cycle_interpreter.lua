-- SPDX-License-Identifier: GPL-3.0-only
-- Resolve complete TIME traversals without relying on Renoise playback.
local sequencer = require("model.sequencer")
local policies = require("model.policies")
local M = { MAX_CYCLES = 128 }

local integer = policies.in_integer_range

local function copy_voice(voice)
  if not voice then return nil end
  return { note=voice.note, pitch_index=voice.pitch_index,
    accent=voice.accent, slide=voice.slide, key=voice.key, octave=voice.octave,
    origin_cycle=voice.origin_cycle, origin_step=voice.origin_step }
end

local function validate(pattern)
  local ok, err = sequencer.validate(pattern)
  if not ok then return nil, err end
  if not integer(pattern.pitch_length, 1, sequencer.MAX_STEPS) then
    return nil, "pitch length must be 1..32"
  end
  if #pattern.time_events < pattern.length then
    return nil, "time memory must have one N/T/R value per active step"
  end
  if sequencer.is_leading_tie(1, pattern.time_events[1]) then
    return nil, "leading TIE must be entered as NOTE"
  end
  for _, command in ipairs(pattern.time_events) do
    if command == "N" and #pattern.pitch_events < pattern.pitch_length then
      return nil, "NOTE requires a complete active pitch span"
    end
  end
  return true
end

local function validate_state(state)
  if state == nil then return true end
  if type(state) ~= "table" or not integer(state.cycle, 1, 1000000) then
    return nil, "invalid cycle state"
  end
  local voice = state.voice
  if state.cycle == 1 and voice ~= nil then
    return nil, "initial cycle must start silent"
  end
  if voice ~= nil then
    if type(voice) ~= "table" or not integer(voice.note, 0, 119) or
        not integer(voice.pitch_index, 1, sequencer.MAX_STEPS) or
        type(voice.accent) ~= "boolean" or type(voice.slide) ~= "boolean" then
      return nil, "invalid cycle voice"
    end
    local key, octave_or_error=sequencer.pitch_controls(voice)
    if key==nil then return nil,"invalid cycle voice: "..octave_or_error end
  end
  return true
end

local function run_cycle(pattern, state)
  local cycle = state and state.cycle or 1
  local voice = state and copy_voice(state.voice) or nil
  local cursor = 1
  local plan = {cycle=cycle, entry_kind=cycle == 1 and "cold" or "repeat",
    length=pattern.length, steps={}, note_count=0, pitch_length=pattern.pitch_length}
  for step=1,pattern.length do
    local command = pattern.time_events[step]
    local event = {cycle=cycle, step=step, absolute_step=(cycle-1)*pattern.length+step}
    if command == "N" then
      local pitch = pattern.pitch_events[cursor]
      event.kind, event.pitch_index = "note", cursor
      event.note, event.accent, event.slide = pitch.note, pitch.accent == true, pitch.slide == true
      event.key, event.octave = pitch.key, pitch.octave
      event.from_note = voice and voice.note or nil
      event.transition = not voice and "attack" or (voice.slide and "slide" or "retrigger")
      event.connected = event.transition == "slide"
      voice = {note=pitch.note, pitch_index=cursor, accent=event.accent,
        slide=event.slide, key=pitch.key, octave=pitch.octave,
        origin_cycle=cycle, origin_step=step}
      cursor = cursor % pattern.pitch_length + 1
      plan.note_count = plan.note_count + 1
    elseif command == "T" then
      event.kind, event.holds = "tie", voice ~= nil
      event.note = voice and voice.note or nil
      event.pitch_index = voice and voice.pitch_index or nil
    else
      event.kind, event.releases = "rest", voice ~= nil
      event.released_note = voice and voice.note or nil
      voice = nil
    end
    local next_command = step<pattern.length and pattern.time_events[step + 1]
      or pattern.time_events[1]
    event.hold_intent = voice ~= nil and
      (next_command == "T" or (next_command == "N" and voice.slide)) or false
    event.voice = copy_voice(voice)
    plan.steps[step] = event
  end
  local exit = {cycle=cycle+1, next_pitch=cursor, voice=copy_voice(voice),
    hold_intent=plan.steps[pattern.length].hold_intent}
  return plan, exit
end

function M.compile_cycle(pattern, state)
  local ok, err = validate(pattern)
  if not ok then return nil, err end
  ok, err = validate_state(state)
  if not ok then return nil, err end
  return run_cycle(pattern, state)
end

function M.compile_cycles(pattern, count, state)
  if not integer(count, 1, M.MAX_CYCLES) then return nil, "invalid cycle count" end
  local ok, err = validate(pattern)
  if not ok then return nil, err end
  ok, err = validate_state(state)
  if not ok then return nil, err end
  if state and state.cycle + count > 1000001 then return nil, "invalid cycle count" end
  local plans = {}
  for i=1,count do plans[i], state = run_cycle(pattern, state) end
  return plans, state
end

local function same_voice(a, b)
  if a == nil or b == nil then return a == b end
  for _, key in ipairs({"note", "pitch_index", "accent", "slide", "key", "octave"}) do
    if a[key] ~= b[key] then return false end
  end
  return true
end

function M.plan_loop(pattern)
  if type(pattern) ~= "table" then return nil, "invalid pattern" end
  local plans, state_or_error = M.compile_cycles(pattern, 3)
  if not plans then return nil, state_or_error end
  local steady, verification = plans[2], plans[3]
  for step=1,pattern.length do
    local a, b = steady.steps[step], verification.steps[step]
    for _, key in ipairs({"kind", "pitch_index", "note", "accent", "slide",
        "key", "octave", "transition", "from_note", "connected", "holds",
        "releases", "released_note", "hold_intent"}) do
      if a[key] ~= b[key] then
        return nil, "repeating cycle is not periodic at TIME step " .. step
      end
    end
    if not same_voice(a.voice, b.voice) then
      return nil, "repeating voice is not periodic at TIME step " .. step
    end
  end
  return {cold=plans[1], steady=steady, verification=verification,
    exit_state=state_or_error}
end

return M
