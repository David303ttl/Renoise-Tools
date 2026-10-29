-- SPDX-License-Identifier: GPL-3.0-only
-- Shared pure musical input and native velocity policies.
local M = {}
M.PB_CHOICES = {0, 2, 12, 24, 48}
M.DEFAULT_PB_RANGE = 0
M.DEFAULT_OUTPUT_POLICY = "repeat"
M.NORMAL_VOLUME = 0.7
M.ACCENT_VOLUME = 1
local pb_ranges = {}
for _, value in ipairs(M.PB_CHOICES) do pb_ranges[value] = true end

function M.is_integer(value)
  return type(value) == "number" and value % 1 == 0
end

function M.in_integer_range(value, minimum, maximum)
  return M.is_integer(value) and value >= minimum and value <= maximum
end

function M.valid_pb_range(value)
  return type(value) == "number" and pb_ranges[value] == true
end

function M.valid_output_policy(value)
  return value == "repeat" or value == "play_once"
end

function M.valid_volume(value)
  return type(value) == "number" and value >= 0 and value <= 1
end

function M.format_volume(value)
  return string.format("%.6f", value)
end

function M.quantize_volume(value)
  local emitted = tonumber(M.format_volume(value))
  return emitted == 1 and 255 or math.floor(emitted * 128)
end

function M.note_volume(accent, normal, accented)
  return accent and (accented or M.ACCENT_VOLUME) or (normal or M.NORMAL_VOLUME)
end

function M.note_velocity(accent)
  return M.quantize_volume(M.note_volume(accent))
end

return M
