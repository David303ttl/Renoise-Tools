-- chain_exporter.lua
-- This script handles the core logic for exporting selected instrument samples from Renoise.
-- It processes them into a single, monophonic .wav file, formatted as a sample chain
-- suitable for Elektron Digitakt I, with options for fixed slot lengths.

local sample_rate = 48000 -- Audio sample rate for export, matching Digitakt specifications.
local bit_depth = 16    -- Audio bit depth for export.

-- Configuration variables for the export process
local export_mode = "spaced" 
local fixed_slot_count = nil 
local apply_fadeout = false  
local apply_dither = false  
local pad_with_zero = false  
local current_mono_mode = "average" 

--- Flattens a multi-channel sample buffer into a mono sample buffer.
-- @param sample The Renoise sample object to process.
-- @return A table containing the mono sample data (floating-point numbers), or nil if no sample data.
local function flatten_sample(sample)
  local buffer = sample.sample_buffer
  if not buffer.has_sample_data then return nil end

  local frames = buffer.number_of_frames
  local channels = buffer.number_of_channels
  local data = {}

  for i = 1, frames do
    local value
    if current_mono_mode == "left" and channels >= 1 then
      value = buffer:sample_data(1, i) 
    elseif current_mono_mode == "right" and channels >= 2 then
      value = buffer:sample_data(2, i) 
    else 
      local sum = 0
      for c = 1, channels do
        sum = sum + buffer:sample_data(c, i)
      end
      value = sum / channels 
    end
    data[i] = value
  end

  return data
end

--- Applies a short fade-out to the end of a sample data array.
-- @param data A table of sample data (floating-point numbers).
-- @param ms The duration of the fade-out in milliseconds.
-- @return The sample data table with fade-out applied.
local function apply_fade(data, ms)
  local fade_samples = math.floor(sample_rate * (ms / 1000))
  for i = #data - fade_samples + 1, #data do
    local scale = (i - (#data - fade_samples)) / fade_samples
    data[i] = data[i] * (1.0 - scale)
  end
  return data
end

--- Pads a sample data array to a specific length with zeros.
-- Optionally adds extra zero padding at the beginning and end if `pad_with_zero` is true.
-- @param data A table of sample data (floating-point numbers).
-- @param length The target length for the padded sample.
-- @return The padded sample data table.
local function pad_sample_to_length(data, length)
  local padded = {}
  for i = 1, length do
    padded[i] = data[i] or 0.0 -- Pad with zeros if original data is shorter.
  end

  if pad_with_zero then
    local zeros = {}
    for i = 1, 64 do zeros[i] = 0.0 end -- 64 samples of silence.
    local extended = {}
    for _, z in ipairs(zeros) do table.insert(extended, z) end
    for _, v in ipairs(padded) do table.insert(extended, v) end
    for _, z in ipairs(zeros) do table.insert(extended, z) end
    return extended
  end

  return padded
end

local last_export_info = { slot_sec = 0, total_sec = 0 } -- Stores information about the last export for display.

--- Joins an array of processed samples into a single continuous chain.
-- The joining method depends on `export_mode` and `fixed_slot_count`.
-- @param samples A table of pre-processed sample data tables.
-- @return A single table containing the complete sample chain.
local function join_slots(samples)
  local output = {}

  -- Handle "chain" mode (direct concatenation)
  if export_mode == "chain" then
    for _, s in ipairs(samples) do
      if apply_fadeout then s = apply_fade(s, 20) end -- Apply fade if enabled.
      for _, v in ipairs(s) do
        table.insert(output, v) -- Concatenate samples directly.
      end
    end
    -- Calculate and store info for "chain" mode.
    local slot_length = math.floor(#output / #samples)
    last_export_info.slot_sec = slot_length / sample_rate
    last_export_info.total_sec = (#samples * slot_length) / sample_rate
    return output
  end

  -- Handle "spaced" mode (fixed-length slots)
  local max_sample_length = 0
  local total_samples_length = 0
  for _, s in ipairs(samples) do
    if #s > max_sample_length then max_sample_length = #s end -- Find the longest sample.
    total_samples_length = total_samples_length + #s -- Calculate total length of all samples.
  end

  -- Default slot length is the longest sample.
  local slot_length = max_sample_length

  if fixed_slot_count then
    -- Calculate ideal slot length to fit all samples into the specified number of slots.
    local ideal_slot_length = math.ceil(total_samples_length / fixed_slot_count)
    
    -- Ensure slot_length is at least the longest sample's length and the ideal slot length.
    slot_length = math.max(max_sample_length, ideal_slot_length)
    
    -- If zero padding is enabled, account for it in the slot length.
    if pad_with_zero then
        slot_length = slot_length + (64 * 2) 
    end
  end

  -- Update export info based on calculated slot length and count.
  last_export_info.slot_sec = slot_length / sample_rate
  last_export_info.total_sec = (fixed_slot_count or #samples) * slot_length / sample_rate

  -- Pad and append each sample to the output chain.
  for _, s in ipairs(samples) do
    if apply_fadeout then s = apply_fade(s, 20) end
    local padded = pad_sample_to_length(s, slot_length)
    for _, v in ipairs(padded) do
      table.insert(output, v)
    end
  end

  -- Ensure the final output length matches the target total length for fixed_slot_count.
  local target_total_length = slot_length * (fixed_slot_count or #samples)
  while #output < target_total_length do
      table.insert(output, 0.0) -- Pad remaining length with zeros.
  end

  return output
end

--- Writes the given sample data to a WAV file with RIFF header.
-- @param filename The full path for the output WAV file.
-- @param data A table of sample data (floating-point numbers).
local function write_wav(filename, data)
  local frames = #data
  local f = io.open(filename, "wb")
  if not f then
    renoise.app():show_error("Could not open file for writing: " .. filename)
    return
  end

  -- Helper function to write a 16-bit little-endian integer.
  local function write_le_16(x)
    f:write(string.char(x % 256, math.floor(x / 256) % 256))
  end

  -- Helper function to write a 32-bit little-endian integer.
  local function write_le_32(x)
    write_le_16(x % 65536)
    write_le_16(math.floor(x / 65536))
  end

  -- Write WAV file header (RIFF, WAVE, fmt chunk, data chunk).
  f:write("RIFF")
  write_le_32(36 + frames * 2) -- File size.
  f:write("WAVE")
  f:write("fmt ")
  write_le_32(16) -- fmt chunk size.
  write_le_16(1)  -- Audio format (1 for PCM).
  write_le_16(1)  -- Number of channels (1 for mono).
  write_le_32(sample_rate) -- Sample rate.
  write_le_32(sample_rate * 2) -- Byte rate (SampleRate * NumChannels * BitsPerSample/8).
  write_le_16(2)  -- Block align (NumChannels * BitsPerSample/8).
  write_le_16(bit_depth) -- Bits per sample.

  f:write("data")
  write_le_32(frames * 2) -- Data chunk size.

  math.randomseed(os.time()) -- Initialize random seed for dithering.

  -- Write sample data, applying dither and clipping if enabled.
  for _, v in ipairs(data) do
    if apply_dither then
      local r1 = math.random() - 0.5
      local r2 = math.random() - 0.5
      v = v + (r1 + r2) / 65536 -- TPDF dither.
    end
    local clipped = math.max(-1, math.min(1, v)) -- Clip to -1.0 to 1.0.
    local int16 = math.floor(clipped * 32767)   -- Convert to 16-bit integer.
    if int16 < 0 then int16 = int16 + 65536 end -- Handle negative values for unsigned 16-bit write.
    write_le_16(int16) -- Write the sample.
  end

  f:close()
  renoise.app():show_status("Chain exported to " .. filename) -- Display success message.
end

-- Module table to expose public functions.
local M = {}

function M.export(filename, mode, slot_count, fade, dither, pad, mono_selection_from_gui)
  export_mode = mode or "spaced"
  fixed_slot_count = slot_count
  apply_fadeout = fade
  apply_dither = dither
  pad_with_zero = pad
  current_mono_mode = mono_selection_from_gui or "average" -- Set the chosen mono mode.

  local instr = renoise.song().selected_instrument
  if #instr.samples == 0 then
    renoise.app():show_error("Selected instrument has no samples.")
    return
  end

  local all_samples = {}
  for i = 1, #instr.samples do
    local data = flatten_sample(instr.samples[i]) -- Process each sample to mono.
    if data then
      table.insert(all_samples, data)
    end
  end

  if #all_samples == 0 then
    renoise.app():show_error("No valid slice data to export.")
    return
  end

  local chain = join_slots(all_samples) -- Join all processed samples into a chain.
  local full_path = renoise.app():prompt_for_filename_to_write("WAV", filename) -- Prompt user for save location.
  if full_path then
    write_wav(full_path, chain) -- Write the WAV file.
  end
end

--- Returns information about the last export.
-- @return A table with slot_sec (single slot duration) and total_sec (total chain duration).
function M.get_last_export_info()
  return last_export_info
end

return M