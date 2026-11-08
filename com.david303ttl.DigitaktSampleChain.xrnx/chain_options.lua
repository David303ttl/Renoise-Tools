-- SPDX-License-Identifier: GPL-3.0-only
local M = {}

M.SAMPLE_RATE = 48000
M.FADE_OUT_MS = 20
M.EDGE_SILENCE_FRAMES = 64
M.DEFAULT_CHOICE = 1

local EXPORT_MODES = {
  { id = "spaced", label = "Grid (Digitakt Slices)" },
  { id = "chain", label = "Concatenated" },
}

local MONO_MODES = {
  { id = "average", label = "Average Channels" },
  { id = "left", label = "Left Channel" },
  { id = "right", label = "Right Channel" },
}

local SLOT_COUNT_CHOICES = { 4, 8, 16, 32, 64 }

local function labels(list)
  local items = {}
  for i, entry in ipairs(list) do items[i] = entry.label end
  return items
end

function M.export_mode_labels()
  return labels(EXPORT_MODES)
end

function M.mono_mode_labels()
  return labels(MONO_MODES)
end

function M.slot_count_labels()
  local items = {}
  for i, count in ipairs(SLOT_COUNT_CHOICES) do
    items[i] = tostring(count)
  end
  return items
end

function M.export_mode(index)
  local entry = EXPORT_MODES[index]
  return entry and entry.id
end

function M.mono_mode(index)
  local entry = MONO_MODES[index]
  return entry and entry.id
end

function M.slot_count(index)
  return SLOT_COUNT_CHOICES[index]
end

function M.defaults()
  return {
    mode = EXPORT_MODES[M.DEFAULT_CHOICE].id,
    mono = MONO_MODES[M.DEFAULT_CHOICE].id,
    slot_count = SLOT_COUNT_CHOICES[M.DEFAULT_CHOICE],
    fade = false,
    dither = false,
    zero_pad = false,
  }
end

function M.is_grid_division(value)
  for _, count in ipairs(SLOT_COUNT_CHOICES) do
    if value == count then return true end
  end
  return false
end

local function contains_id(list, id)
  for _, entry in ipairs(list) do
    if entry.id == id then return true end
  end
  return false
end

function M.validate(options)
  if type(options) ~= "table" then
    return nil, "Invalid export options."
  end
  if not contains_id(EXPORT_MODES, options.mode) then
    return nil, "Unknown export mode."
  end
  if not contains_id(MONO_MODES, options.mono) then
    return nil, "Unknown mono conversion mode."
  end
  local slot_count = nil
  if options.mode == "spaced" then
    if not M.is_grid_division(options.slot_count) then
      return nil, "Choose a grid division of 4, 8, 16, 32 or 64."
    end
    slot_count = options.slot_count
  end
  for _, flag in ipairs({ "fade", "dither", "zero_pad" }) do
    if type(options[flag]) ~= "boolean" then
      return nil, "Option '" .. flag .. "' must be enabled or disabled."
    end
  end
  return {
    mode = options.mode,
    mono = options.mono,
    slot_count = slot_count,
    fade = options.fade,
    dither = options.dither,
    zero_pad = options.zero_pad,
  }
end

return M
