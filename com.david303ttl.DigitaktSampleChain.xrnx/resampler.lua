-- SPDX-License-Identifier: GPL-3.0-only
local M = {}
local LOBES, ROUNDING = 16, 0.5
local MIN_OUTPUT_FRAMES, MAX_NORMALIZED_CUTOFF = 1, 1
local CACHE_PADDING_FRAMES = 3
local SINC_ZERO_TOLERANCE = 1e-12
local WINDOW_BASELINE, WINDOW_AMPLITUDE = 0.5, 0.5
local PI = math.pi

function M.frame_count(frames, source_rate, target_rate)
  return math.max(MIN_OUTPUT_FRAMES,
    math.floor(frames * target_rate / source_rate + ROUNDING))
end

-- Windowed sinc with a rate-dependent low-pass cutoff. Extend endpoints so
-- short buffers and DC retain their level; never read outside the source.
function M.reader(read, frames, source_rate, target_rate)
  if source_rate == target_rate then return read end
  local ratio = source_rate / target_rate
  local cutoff = math.min(MAX_NORMALIZED_CUTOFF, 1 / ratio)
  local radius = LOBES / cutoff
  local capacity = math.ceil(2 * radius) + CACHE_PADDING_FRAMES
  local keys, values = {}, {}
  local function cached(frame)
    frame = math.max(1, math.min(frames, frame))
    local slot = frame % capacity + 1
    if keys[slot] ~= frame then
      keys[slot], values[slot] = frame, read(frame)
    end
    return values[slot]
  end
  return function(frame)
    local position = (frame - 1) * ratio + 1
    local sum, weight_sum = 0, 0
    for index = math.ceil(position - radius), math.floor(position + radius) do
      local distance = (position - index) * cutoff
      local sinc = math.abs(distance) < SINC_ZERO_TOLERANCE
        and 1 or math.sin(PI * distance) / (PI * distance)
      local window = WINDOW_BASELINE
        + WINDOW_AMPLITUDE * math.cos(PI * distance / LOBES)
      local weight = sinc * window
      sum, weight_sum = sum + cached(index) * weight, weight_sum + weight
    end
    return sum / weight_sum
  end
end

return M
