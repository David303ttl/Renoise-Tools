-- SPDX-License-Identifier: GPL-3.0-only
local M = {}

M.SAMPLE_RATE = 48000
M.FADE_OUT_MS = 20
M.EDGE_SILENCE_FRAMES = 64
M.DEFAULT_CHOICE = 1

local EXPORT_MODES = {
  { id = "spaced", label = "Spaced (Digitakt Grid)" },
  { id = "chain", label = "Chain (Direct Concatenation)" },
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
  local items = { "Auto" }
  for i, count in ipairs(SLOT_COUNT_CHOICES) do
    items[i + 1] = tostring(count)
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
  return SLOT_COUNT_CHOICES[index - M.DEFAULT_CHOICE]
end

function M.defaults()
  return {
    mode = EXPORT_MODES[M.DEFAULT_CHOICE].id,
    mono = MONO_MODES[M.DEFAULT_CHOICE].id,
    fade = false,
    dither = false,
    zero_pad = false,
  }
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
  local slot_count = options.slot_count
  if slot_count ~= nil then
    local supported = false
    for _, count in ipairs(SLOT_COUNT_CHOICES) do
      if slot_count == count then supported = true end
    end
    if not supported then
      return nil, "Choose a supported slot count or Auto."
    end
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
