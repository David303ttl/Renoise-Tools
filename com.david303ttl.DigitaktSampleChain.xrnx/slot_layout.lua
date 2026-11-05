-- SPDX-License-Identifier: GPL-3.0-only
local settings = require("chain_options")
local M = {}
local MILLISECONDS_PER_SECOND, SLOT_EDGES = 1000, 2

function M.plan(lengths, options, sample_rate)
  if #lengths == 0 then return nil, "No samples to lay out." end
  local max_length, total = 0, 0
  for _, length in ipairs(lengths) do
    if type(length) ~= "number" or length < 1 or length >= math.huge
        or length ~= math.floor(length) then
      return nil, "Invalid sample length."
    end
    max_length = math.max(max_length, length)
    total = total + length
  end
  local chain = options.mode == "chain"
  local count = chain and #lengths or (options.slot_count or #lengths)
  if count < #lengths then
    return nil, string.format("%d samples do not fit into %d slots.", #lengths, count)
  end
  local edge = not chain and options.zero_pad and settings.EDGE_SILENCE_FRAMES or 0
  local slot_frames = not chain and (max_length + SLOT_EDGES * edge) or nil
  local total_frames = chain and total or slot_frames * count
  return {
    mode = options.mode, slot_count = count, slot_frames = slot_frames,
    total_frames = total_frames, edge_silence = edge,
    fade_frames = options.fade and math.floor(sample_rate * settings.FADE_OUT_MS / MILLISECONDS_PER_SECOND) or 0,
    slot_sec = (chain and total / count or slot_frames) / sample_rate,
    total_sec = total_frames / sample_rate,
  }
end

function M.make_slot_reader(plan, read, source_length)
  if not read then return function() return 0 end end
  local edge = plan.edge_silence
  local fade = math.min(plan.fade_frames, source_length)
  local fade_start = source_length - fade + 1
  return function(frame)
    local source_frame = frame - edge
    if source_frame < 1 or source_frame > source_length then return 0 end
    local value = read(source_frame)
    if fade > 0 and source_frame >= fade_start then
      local gain = fade == 1 and 0 or (source_length - source_frame) / (fade - 1)
      value = value * gain
    end
    return value
  end
end

return M
