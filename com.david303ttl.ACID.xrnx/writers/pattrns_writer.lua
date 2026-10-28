-- SPDX-License-Identifier: GPL-3.0-only
-- Emit finite pattrns scripts from semantic note and timing events.
-- Glide and release-gate effects are applied separately to the rendered phrase.
local interpreter = require('model.cycle_interpreter')
local M = {}

local function valid_unit(value)
  return value == '1/16'
end

local function valid_volume(value)
  return type(value) == 'number' and value >= 0 and value <= 1
    and value == value -- reject NaN
end

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
    or plan.length < 1 or plan.length > 128 then
    return nil, 'invalid compiled ACID plan'
  end
  local unit = options.unit or '1/16'
  if not valid_unit(unit) then
    return nil, 'only straight 1/16 timing is supported'
  end
  local normal_volume = options.normal_volume or 0.7
  local accent_volume = options.accent_volume or 1.0
  if not valid_volume(normal_volume) or not valid_volume(accent_volume) then
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
      local velocity = event.accent and accent_volume or normal_volume
      items[index] = string.format('{ key = %d, volume = %.6f }', event.note, velocity)
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
    '  unit = "1/16",',
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

-- Derive native volume expectations from source events, never rendered cells.
-- Renoise's pattrns renderer truncates sub-unity volume * 128, and emits
-- the empty/full-volume sentinel 255 for unity volume.
function M.expected_volumes(plan, lines_per_step, number_of_lines, columns, options)
  options = options or {}
  local normal = options.normal_volume or 0.7
  local accent = options.accent_volume or 1.0
  if not valid_volume(normal) or not valid_volume(accent) then
    return nil, 'volumes must be numbers between 0 and 1'
  end
  if type(plan) ~= 'table' or type(plan.steps) ~= 'table'
    or type(plan.length) ~= 'number' or plan.length < 1 or plan.length % 1 ~= 0
    or type(lines_per_step) ~= 'number' or lines_per_step < 1 or lines_per_step % 1 ~= 0
    or type(number_of_lines) ~= 'number' or number_of_lines < plan.length * lines_per_step
    or number_of_lines % 1 ~= 0 or type(columns) ~= 'number'
    or columns < 1 or columns % 1 ~= 0 then
    return nil, 'invalid volume expectation layout'
  end
  local volumes = {}
  for line = 1, number_of_lines do
    volumes[line] = {}
    for column = 1, columns do volumes[line][column] = 255 end
  end
  for step = 1, plan.length do
    local event = plan.steps[step]
    if type(event) ~= 'table' or event.step ~= step then
      return nil, 'missing or out-of-order semantic step ' .. step
    end
    if event.kind == 'note' then
      -- Match the six-decimal source emitted above before native quantization.
      local volume = tonumber(string.format('%.6f', event.accent and accent or normal))
      volumes[(step - 1) * lines_per_step + 1][1] = volume == 1 and 255 or math.floor(volume * 128)
    elseif event.kind ~= 'rest' and event.kind ~= 'tie' then
      return nil, 'invalid semantic kind at step ' .. step
    end
  end
  return volumes
end

function M.generate(pattern, options)
  local plan, error_message = interpreter.compile_cycle(pattern)
  if not plan then return nil, error_message end
  return M.emit(plan, options)
end

return M
