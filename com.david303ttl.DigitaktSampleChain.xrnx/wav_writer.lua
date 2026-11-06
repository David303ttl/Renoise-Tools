-- SPDX-License-Identifier: GPL-3.0-only
local M = {}
local BITS_PER_BYTE, BITS_PER_SAMPLE = 8, 16
local BYTE_BASE = 2 ^ BITS_PER_BYTE
local WORD_BASE = BYTE_BASE * BYTE_BASE
local FULL_SCALE = WORD_BASE / 2
local INT16_MIN, INT16_MAX = -FULL_SCALE, FULL_SCALE - 1
local PCM_FORMAT, CHANNELS, FORMAT_CHUNK_BYTES = 1, 1, 16
local BYTES_PER_FRAME = CHANNELS * BITS_PER_SAMPLE / BITS_PER_BYTE
local HEADER_BYTES = 44
local RIFF_OVERHEAD = 36
local MAX_RIFF_SIZE = 4294967295
local RNG_MODULUS, RNG_MULTIPLIER, DEFAULT_SEED = 2147483647, 48271, 1
local MAX_TEMP_ATTEMPTS = 16
local ROUNDING_OFFSET, TPDF_CENTERING_OFFSET = 0.5, 1
local MIN_FRAME_COUNT, MIN_SAMPLE_RATE = 1, 1

local function le16(value)
  return string.char(value % BYTE_BASE, math.floor(value / BYTE_BASE) % BYTE_BASE)
end

local function le32(value)
  return le16(value % WORD_BASE) .. le16(math.floor(value / WORD_BASE))
end

function M.assert_size(frames)
  if type(frames) ~= "number" or frames < MIN_FRAME_COUNT or frames ~= math.floor(frames)
      or RIFF_OVERHEAD + frames * BYTES_PER_FRAME > MAX_RIFF_SIZE then
    return nil, "Invalid frame count or chain exceeds the 4 GB WAV size limit."
  end
  return true
end

function M.header(frames, rate)
  local valid, err = M.assert_size(frames)
  if not valid then return nil, err end
  if type(rate) ~= "number" or rate < MIN_SAMPLE_RATE or rate ~= math.floor(rate)
      or rate * BYTES_PER_FRAME > MAX_RIFF_SIZE then
    return nil, "Invalid WAV sample rate."
  end
  local bytes = frames * BYTES_PER_FRAME
  return table.concat({
    "RIFF", le32(RIFF_OVERHEAD + bytes), "WAVEfmt ", le32(FORMAT_CHUNK_BYTES),
    le16(PCM_FORMAT), le16(CHANNELS), le32(rate), le32(rate * BYTES_PER_FRAME),
    le16(BYTES_PER_FRAME), le16(BITS_PER_SAMPLE), "data", le32(bytes),
  })
end

-- Park-Miller products stay within double-precision integer range.
function M.new_dither()
  local state = DEFAULT_SEED
  return function()
    state = (state * RNG_MULTIPLIER) % RNG_MODULUS
    return (state - 1) / (RNG_MODULUS - 1)
  end
end

function M.quantize(value, rng)
  assert(type(value) == "number" and value == value
    and value > -math.huge and value < math.huge, "Invalid audio frame")
  -- Keep padded regions digitally silent.
  if rng and value ~= 0 then
    value = value + (rng() + rng() - TPDF_CENTERING_OFFSET) / FULL_SCALE
  end
  local integer = math.floor(value * FULL_SCALE + ROUNDING_OFFSET)
  return math.max(INT16_MIN, math.min(INT16_MAX, integer))
end

function M.encode(values, first, last, rng)
  local parts = {}
  for index = first, last do
    parts[index - first + 1] = le16(M.quantize(values[index], rng))
  end
  return table.concat(parts)
end

local function file_call(file, method, ...)
  local ok, result, err = pcall(file[method], file, ...)
  if not ok then return nil, tostring(result) end
  if not result then return nil, tostring(err) end
  return true
end

local function verify_staged_structure(writer)
  local ok, size, seek_err = pcall(writer.file.seek, writer.file, "end")
  if not ok then return nil, "WAV size check failed: " .. tostring(size) end
  if not size then return nil, "WAV size check failed: " .. tostring(seek_err) end
  if type(size) ~= "number" then return nil, "WAV size check failed: invalid file position." end

  local expected_size = HEADER_BYTES + writer.expected
  if size > expected_size then return nil, "WAV staged artifact contains unexpected trailing data." end
  if size < expected_size then return nil, "WAV staged artifact is shorter than planned." end

  local positioned, position_err = file_call(writer.file, "seek", "set", 0)
  if not positioned then return nil, "WAV seek failed: " .. position_err end
  local read_ok, header, read_err = pcall(writer.file.read, writer.file, HEADER_BYTES)
  if not read_ok then return nil, "WAV header readback failed: " .. tostring(header) end
  if not header then return nil, "WAV header readback failed: " .. tostring(read_err or "unexpected end of file") end
  if type(header) ~= "string" or #header ~= HEADER_BYTES then
    return nil, "WAV header readback failed: incomplete header."
  end
  if header ~= writer.expected_header then return nil, "WAV header changed during staging." end
  return true
end

local function reserve_staging_directory(destination)
  for _ = 1, MAX_TEMP_ATTEMPTS do
    local temporary = os.tmpname()
    if io.exists(temporary) then
      local removed, remove_err = os.remove(temporary)
      if not removed then return nil, remove_err end
    end
    local token = temporary:match("[^/\\]+$")
    local candidate = destination .. "." .. token .. ".tmp"
    -- mkdir reserves the namespace atomically; file creation happens inside it.
    local created, create_err = os.mkdir(candidate)
    if created then return candidate end
    if not io.exists(candidate) then return nil, create_err end
  end
  return nil, "Could not reserve a temporary WAV directory."
end

local Writer = {}
Writer.__index = Writer

local function remove_staging_directory(writer)
  if not writer.staging_directory then return true end
  local removed, err = os.remove(writer.staging_directory)
  if not removed then
    return nil, "Could not remove staging directory '" .. writer.staging_directory .. "': " .. tostring(err)
  end
  writer.staging_directory = nil
  return true
end

function Writer:abort()
  local errors = {}
  if self.file then
    local ok, err = file_call(self.file, "close")
    self.file = nil
    if not ok then errors[#errors + 1] = err end
  end
  if self.temporary then
    local removed, err = true, nil
    if io.exists(self.temporary) then removed, err = os.remove(self.temporary) end
    if removed then
      self.temporary = nil
    else
      errors[#errors + 1] = "Could not remove temporary file '" .. self.temporary .. "': " .. tostring(err)
    end
  end
  local removed, remove_err = remove_staging_directory(self)
  if not removed then errors[#errors + 1] = remove_err end
  if #errors > 0 then return nil, table.concat(errors, "\n") end
  return true
end

function Writer:write(payload)
  if not self.file then return nil, "WAV output is closed." end
  if self.verified then return nil, "WAV output is being verified." end
  if #payload % BYTES_PER_FRAME ~= 0 or self.written + #payload > self.expected then
    return nil, "PCM data exceeds the planned WAV length."
  end
  local ok, err = file_call(self.file, "write", payload)
  if not ok then return nil, "WAV write failed: " .. err end
  self.written = self.written + #payload
  return true
end

function Writer:verify(payload)
  if not self.file then return nil, "WAV output is closed." end
  if self.written ~= self.expected then return nil, "WAV data is incomplete." end
  if not self.verified then
    local flushed, flush_err = file_call(self.file, "flush")
    if not flushed then return nil, "WAV flush failed: " .. flush_err end
    local structure_ok, structure_err = verify_staged_structure(self)
    if not structure_ok then return nil, structure_err end
    self.verified = 0
  end
  if self.verified + #payload > self.expected then return nil, "WAV verification exceeds planned length." end
  local read_ok, content, read_err = pcall(self.file.read, self.file, #payload)
  if not read_ok then return nil, "WAV readback failed: " .. tostring(content) end
  if not content then return nil, "WAV readback failed: " .. tostring(read_err or "unexpected end of file") end
  if content ~= payload then return nil, "Source audio changed. Restart the export." end
  self.verified = self.verified + #payload
  return true
end

function Writer:commit()
  if not self.file then return nil, "WAV output is closed." end
  if self.written ~= self.expected then return nil, "WAV data is incomplete." end
  if self.verified ~= self.expected then return nil, "WAV verification is incomplete." end
  local flushed, flush_err = file_call(self.file, "flush")
  if not flushed then return nil, "WAV flush failed: " .. flush_err end
  local structure_ok, structure_err = verify_staged_structure(self)
  if not structure_ok then return nil, structure_err end
  local closed, close_err = file_call(self.file, "close")
  self.file = nil
  if not closed then return nil, "WAV close failed: " .. close_err end

  local backup
  if io.exists(self.destination) then
    -- Stat and rename are separate operations, so this guard is not race-free.
    local stat_ok, attributes, stat_err = pcall(io.stat, self.destination)
    if not stat_ok then
      return nil, "Could not inspect existing destination '" .. self.destination .. "': " .. tostring(attributes)
    end
    if not attributes then
      return nil, "Could not inspect existing destination '" .. self.destination .. "': "
        .. tostring(stat_err or "unknown stat error")
    end
    if type(attributes) ~= "table" or attributes.type ~= "file" then
      return nil, "Existing destination is not a regular file: '" .. self.destination .. "'."
    end
    backup = self.temporary .. ".bak"
    if io.exists(backup) then return nil, "Backup filename is already in use: " .. backup end
    local moved, move_err = os.rename(self.destination, backup)
    if not moved then return nil, "Could not back up destination: " .. tostring(move_err) end
  end
  local installed, install_err = os.rename(self.temporary, self.destination)
  if not installed then
    if backup then
      local restored, restore_err = os.rename(backup, self.destination)
      if not restored then
        return nil, "Could not install WAV: " .. tostring(install_err)
          .. ". Original retained at '" .. backup .. "': " .. tostring(restore_err)
      end
    end
    return nil, "Could not install WAV: " .. tostring(install_err)
  end
  self.temporary = nil
  if backup then
    local removed, err = os.remove(backup)
    if not removed then
      return true, "WAV exported; could not remove backup '" .. backup .. "': " .. tostring(err)
    end
  end
  local removed, remove_err = remove_staging_directory(self)
  if not removed then return true, "WAV exported; " .. remove_err end
  return true
end

function M.open(path, frames, rate)
  local header, err = M.header(frames, rate)
  if not header then return nil, err end
  local directory, temp_err = reserve_staging_directory(path)
  if not directory then return nil, "Could not create export staging directory: " .. tostring(temp_err) end
  local temporary = directory .. "/audio.wav"
  local file, open_err = io.open(temporary, "w+b")
  local writer = setmetatable({
    file = file, destination = path, temporary = file and temporary or nil, staging_directory = directory,
    expected = frames * BYTES_PER_FRAME, expected_header = header, written = 0,
  }, Writer)
  if not file then
    local cleaned, cleanup_err = writer:abort()
    return nil, "Could not open WAV output: " .. tostring(open_err)
      .. (cleaned and "" or "\n" .. cleanup_err)
  end
  local written, write_err = file_call(file, "write", header)
  if not written then
    local cleaned, cleanup_err = writer:abort()
    return nil, "WAV header write failed: " .. write_err
      .. (cleaned and "" or "\n" .. cleanup_err)
  end
  return writer
end

return M
