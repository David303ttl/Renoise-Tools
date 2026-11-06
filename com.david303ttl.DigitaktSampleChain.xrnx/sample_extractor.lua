-- SPDX-License-Identifier: GPL-3.0-only
local settings = require("chain_options")
local resampler = require("resampler")
local M = {}
local MONO_CHANNELS, STEREO_CHANNELS = 1, 2
local LEFT_CHANNEL, RIGHT_CHANNEL = 1, 2
local MIN_SAMPLE_FRAMES = 1

function M.snapshot(instrument)
  if not instrument then return nil, "No instrument is selected." end
  if #instrument.samples == 0 then
    return nil, "Selected instrument has no samples."
  end
  local entries = {}
  for index, sample in ipairs(instrument.samples) do
    local buffer = sample.sample_buffer
    if buffer.has_sample_data then
      local rate = buffer.sample_rate
      if type(rate) ~= "number" or rate <= 0 or rate >= math.huge or rate ~= math.floor(rate) then
        return nil, string.format("Sample %d has an invalid sample rate.", index)
      end
      local frames, channels = buffer.number_of_frames, buffer.number_of_channels
      if frames < MIN_SAMPLE_FRAMES or (channels ~= MONO_CHANNELS and channels ~= STEREO_CHANNELS) then
        return nil, string.format("Sample %d has an invalid audio buffer.", index)
      end
      entries[#entries + 1] = {
        buffer = buffer, frames = frames, channels = channels,
        source_rate = rate,
        output_frames = resampler.frame_count(frames, rate, settings.SAMPLE_RATE),
      }
    end
  end
  if #entries == 0 then return nil, "Selected instrument has no sample data to export." end
  return { rate = settings.SAMPLE_RATE, buffers = entries }
end

local function mono_reader(entry, mode)
  local buffer = entry.buffer
  if entry.channels == MONO_CHANNELS or mode == "left" then
    return function(frame) return buffer:sample_data(LEFT_CHANNEL, frame) end
  elseif mode == "right" then
    return function(frame) return buffer:sample_data(RIGHT_CHANNEL, frame) end
  end
  return function(frame)
    return (buffer:sample_data(LEFT_CHANNEL, frame) + buffer:sample_data(RIGHT_CHANNEL, frame)) / STEREO_CHANNELS
  end
end

function M.reader(entry, mode)
  return resampler.reader(mono_reader(entry, mode), entry.frames,
    entry.source_rate, settings.SAMPLE_RATE)
end

return M
