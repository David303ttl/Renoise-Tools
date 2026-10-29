-- SPDX-License-Identifier: GPL-3.0-only
-- Emit finite pattrns scripts from semantic note and timing events.
-- Glide and release-gate effects are applied separately to the rendered phrase.
local interpreter = require('model.cycle_interpreter')
local timing = require('model.timing')
local sequencer = require('model.sequencer')
local policies = require("model.policies")
local M = {}
local MAX_PHYSICAL_STEPS=sequencer.MAX_STEPS*timing.REPEAT_CYCLES

local function count_pulses(n)
  local items = {}
  for i = 1, n do items[i] = '1' end
  return table.concat(items, ', ')
end

-- Input must be compiler.compile()'s resolved event plan.
-- Returns a source string and non-playback metadata. No Renoise API required.
function M.emit(plan, options)
  options = options or {}
  if type(options) ~= 'table' then return nil, 'options must be a table' end
  if type(plan) ~= 'table' or type(plan.steps) ~= 'table'
    or type(plan.length) ~= 'number' or plan.length % 1 ~= 0
    or plan.length < 1 or plan.length > MAX_PHYSICAL_STEPS then
    return nil, 'invalid compiled ACID plan'
  end
  local unit = options.unit or timing.STRAIGHT_PULSE_UNIT
  local resolution = options.resolution or timing.STRAIGHT_PULSE_RESOLUTION
  if not ((unit == timing.STRAIGHT_PULSE_UNIT and
      resolution == timing.STRAIGHT_PULSE_RESOLUTION) or
      (unit == timing.TRIPLET_PULSE_UNIT and
      resolution == timing.TRIPLET_PULSE_RESOLUTION)) then
    return nil, 'invalid timing pulse'
  end
  local normal_volume = options.normal_volume or policies.NORMAL_VOLUME
  local accent_volume = options.accent_volume or policies.ACCENT_VOLUME
  if not policies.valid_volume(normal_volume) or not policies.valid_volume(accent_volume) then
    return nil, 'volumes must be numbers between 0 and 1'
  end

  local items, note_count, off_count, slide_count = {}, 0, 0, 0
  for index = 1, plan.length do
    local event = plan.steps[index]
    if type(event) ~= 'table' or event.step ~= index then
      return nil, 'missing or out-of-order semantic step ' .. index
    end
    if event.kind == 'note' then
      if type(event.note) ~= 'number' or event.note % 1 ~= 0
        or event.note < 0 or event.note > 119 then
        return nil, 'invalid note at step ' .. index
      end
      local velocity = policies.note_volume(event.accent, normal_volume, accent_volume)
      items[index] = string.format('{ key = %d, volume = %s }', event.note, policies.format_volume(velocity))
      note_count = note_count + 1
      if event.transition == 'slide' then
        slide_count = slide_count + 1
      end
    elseif event.kind == 'rest' then
      if type(event.releases) ~= 'boolean' then
        return nil, 'rest release flag missing at step ' .. index
      end
      -- A rest releases only if it follows an active voice.
      items[index] = event.releases and '"off"' or 'false'
      if event.releases then off_count = off_count + 1 end
    elseif event.kind == 'tie' then
      items[index] = 'false' -- nil from event emitter, never advances pitch
    else
      return nil, 'invalid semantic kind at step ' .. index
    end
  end
  -- Emit one traversal without native looping or articulation effects.
  local lines = {
    '-- Note and timing events; glide and gate effects are applied separately.',
    'local values = { ' .. table.concat(items, ', ') .. ' }',
    'return pattern {',
    '  unit = "' .. unit .. '",',
    '  resolution = ' .. (resolution == timing.STRAIGHT_PULSE_RESOLUTION
      and timing.STRAIGHT_PULSE_RESOLUTION_SOURCE
      or timing.TRIPLET_PULSE_RESOLUTION_SOURCE) .. ',',
    '  repeats = false,',
    '  pulse = { ' .. count_pulses(plan.length) .. ' },',
    '  event = function(context)',
    '    local index = context.pulse_step',
    '    local value = values[index]',
    '    if value == false then return nil end',
    '    return value',
    '  end',
    '}',
  }
  return table.concat(lines, '\n') .. '\n', {
    steps = plan.length,
    note_count = note_count,
    off_count = off_count,
    slide_intentions = slide_count,
    requires_articulation = true
  }
end

M.expected_volumes=require("model.output_planner").expected_volumes

function M.generate(pattern, options)
  local plan, error_message = interpreter.compile_cycle(pattern)
  if not plan then return nil, error_message end
  if options ~= nil and type(options) ~= 'table' then return nil, 'options must be a table' end
  options = options or {}
  local layout, layout_error = timing.new(pattern.timing_mode, pattern.length, 'play_once')
  if not layout then return nil, layout_error end
  if (options.unit ~= nil and options.unit ~= layout.unit) or
      (options.resolution ~= nil and options.resolution ~= layout.resolution) then
    return nil, 'timing options do not match source timing mode'
  end
  local emit_options = {}
  for key, value in pairs(options) do emit_options[key] = value end
  emit_options.unit, emit_options.resolution = layout.unit, layout.resolution
  return M.emit(plan, emit_options)
end

return M
