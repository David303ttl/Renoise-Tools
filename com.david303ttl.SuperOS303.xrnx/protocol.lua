-- SPDX-License-Identifier: GPL-3.0-only
-- SuperOS-303 application SysEx protocol. No bootloader or firmware opcodes.
local C = require("constants")
local CMD = C.COMMAND
local M = {}

M.STEPS = C.STEPS
M.PATTERN_SIZE = C.PATTERN_SIZE
M.POLY_SIZE = C.POLY_SIZE
M.PACKED_PATTERN_SIZE = C.PACKED_PATTERN_SIZE
M.PACKED_POLY_SIZE = C.PACKED_POLY_SIZE
M.PITCH_EMPTY = C.PITCH_EMPTY

local floor = math.floor

local function integer(n, low, high, name)
  assert(type(n) == "number" and n == floor(n) and n >= low and n <= high,
    (name or "value") .. " out of range")
  return n
end

function M.has_flag(value, flag)
  return floor(value / flag) % C.BIT_BASE == 1
end

local function xor8(a, b)
  local result, bit = 0, 1
  for _ = 1, C.BYTE_BITS do
    if a % C.BIT_BASE ~= b % C.BIT_BASE then result = result + bit end
    a, b, bit = floor(a / C.BIT_BASE), floor(b / C.BIT_BASE), bit * C.BIT_BASE
  end
  return result
end

function M.checksum(raw)
  local sum = 0
  for i = 1, #raw do sum = xor8(sum, integer(raw[i], 0, C.BYTE_MAX, "raw byte")) end
  return sum
end

function M.pack7(raw)
  local packed = {}
  for i = 1, #raw, C.PACK_GROUP_SIZE do
    local msb, block = 0, {}
    for j = i, math.min(i + C.PACK_GROUP_SIZE - 1, #raw) do
      local value = integer(raw[j], 0, C.BYTE_MAX, "raw byte")
      if value >= C.MIDI_DATA_BASE then msb = msb + C.BIT_BASE ^ (j - i) end
      block[#block + 1] = value % C.MIDI_DATA_BASE
    end
    packed[#packed + 1] = msb
    for _, value in ipairs(block) do packed[#packed + 1] = value end
  end
  return packed
end

function M.unpack7(packed, count)
  if #packed ~= count + math.ceil(count / C.PACK_GROUP_SIZE) then return nil, "packed size mismatch" end
  local raw, pos = {}, 1
  for i = 1, count, C.PACK_GROUP_SIZE do
    local msb = packed[pos]
    if not msb or msb > C.MIDI_DATA_MAX then return nil, "invalid MSB byte" end
    pos = pos + 1
    for bit = 0, math.min(C.PACK_GROUP_SIZE - 1, count - i) do
      local value = packed[pos]
      if not value or value > C.MIDI_DATA_MAX then return nil, "invalid packed data" end
      raw[#raw + 1] = value + (floor(msb / (C.BIT_BASE ^ bit)) % C.BIT_BASE) * C.MIDI_DATA_BASE
      pos = pos + 1
    end
  end
  return raw
end

function M.frame(body)
  assert(type(body) == "table" and body[C.BODY_MANUFACTURER] == C.MANUFACTURER_ID, "not a SuperOS message")
  local framed = {C.SYSEX_START}
  for i = 1, #body do framed[#framed + 1] = integer(body[i], 0, C.MIDI_DATA_MAX, "SysEx byte") end
  framed[#framed + 1] = C.SYSEX_END
  return framed
end

local function body_of(message)
  if type(message) ~= "table" then return nil, "not a byte array" end
  local framed = message[1] == C.SYSEX_START
  local first = framed and C.FRAME_BODY_START or C.BODY_MANUFACTURER
  local last = framed and (#message - 1) or #message
  if framed and message[#message] ~= C.SYSEX_END then return nil, "unterminated SysEx" end
  if last - first < 1 or message[first] ~= C.MANUFACTURER_ID then return nil, "not SuperOS SysEx" end
  local body = {}
  for i = first, last do
    local v = message[i]
    if type(v) ~= "number" or v ~= floor(v) or v < 0 or v > C.MIDI_DATA_MAX then
      return nil, "invalid SysEx data byte"
    end
    body[#body + 1] = v
  end
  return body
end

local function decode_blob(body, size, packed_size)
  if #body ~= C.BLOB_HEADER_SIZE + packed_size and #body ~= C.BLOB_HEADER_SIZE + packed_size + 1 then
    return nil, "unsupported blob length"
  end
  local packed = {}
  for i = C.BLOB_DATA_START, C.BLOB_HEADER_SIZE + packed_size do packed[#packed + 1] = body[i] end
  local raw, err = M.unpack7(packed, size)
  if not raw then return nil, err end
  if M.checksum(raw) ~= body[C.CHECKSUM_LOW] + C.MIDI_DATA_BASE * body[C.CHECKSUM_HIGH] then
    return nil, "checksum mismatch"
  end
  return raw
end

function M.decode(message)
  local body, err = body_of(message)
  if not body then return nil, err end
  local cmd = body[C.BODY_COMMAND]
  if cmd == CMD.CONFIG_REPLY then
    if #body < C.CONFIG.REPLY_SIZE then return nil, "short config reply" end
    local version = {}
    for i = C.CONFIG.VERSION_START, #body do version[#version + 1] = string.char(body[i]) end
    return {type = "config", channel = body[C.CONFIG.CHANNEL], flags = body[C.CONFIG.FLAGS],
      direction = body[C.CONFIG.DIRECTION], brightness = body[C.CONFIG.BRIGHTNESS],
      var2_channel = body[C.CONFIG.VAR2_CHANNEL], var3_channel = body[C.CONFIG.VAR3_CHANNEL],
      version = table.concat(version)}
  elseif cmd == CMD.PATTERN_REPLY then
    local raw, issue = decode_blob(body, C.PATTERN_SIZE, C.PACKED_PATTERN_SIZE)
    if not raw then return nil, issue end
    local variation = (#body > C.BLOB_HEADER_SIZE + C.PACKED_PATTERN_SIZE) and body[#body] or C.VARIATION_CV
    if body[C.BODY_ADDRESS] >= C.PATTERNS or variation >= C.VARIATIONS then return nil, "invalid pattern address" end
    local length = raw[C.LENGTH_OFFSET]
    local triplet = M.has_flag(raw[C.FLAGS_OFFSET], C.TRIPLET_FLAG)
    if length < C.MIN_LENGTH or length > C.STEPS or (triplet and length > C.TRIPLET_STEPS) then
      return nil, "invalid pattern length"
    end
    return {type = "pattern", pattern = body[C.BODY_ADDRESS], variation = variation,
      raw = raw, length = length, triplet = triplet}
  elseif cmd == CMD.POLY_REPLY then
    if #body ~= C.BLOB_HEADER_SIZE + C.PACKED_POLY_SIZE then return nil, "unsupported poly length" end
    local raw, issue = decode_blob(body, C.POLY_SIZE, C.PACKED_POLY_SIZE)
    if not raw then return nil, issue end
    if body[C.BODY_ADDRESS] >= C.PATTERNS then return nil, "invalid poly address" end
    return {type = "poly", pattern = body[C.BODY_ADDRESS], variation = C.VARIATION_POLY, raw = raw}
  elseif cmd == CMD.ACK then
    if #body < C.BODY_ADDRESS then return nil, "short acknowledgement" end
    return {type = "ack", status = body[C.BODY_ADDRESS]}
  elseif cmd == CMD.GROUP then
    if #body < C.BODY_ADDRESS or body[C.BODY_ADDRESS] >= C.GROUPS then return nil, "invalid group" end
    return {type = "group", group = body[C.BODY_ADDRESS]}
  elseif cmd == CMD.ACTIVE_PATTERN or cmd == CMD.POSITION then
    local group_index = (cmd == CMD.POSITION) and C.POSITION_GROUP or C.BODY_VALUE
    if #body < group_index or body[C.BODY_ADDRESS] >= C.PATTERNS or body[group_index] >= C.GROUPS or
       (cmd == CMD.POSITION and body[C.BODY_VALUE] >= C.STEPS) then
      return nil, "invalid pattern selection"
    end
    return {type = (cmd == CMD.ACTIVE_PATTERN) and "active" or "position",
      pattern = body[C.BODY_ADDRESS], step = (cmd == CMD.POSITION) and body[C.BODY_VALUE] or nil,
      group = body[group_index]}
  elseif cmd == CMD.EDIT_VARIATION then
    if #body < C.BODY_VALUE then return nil, "short variation reply" end
    return {type = "variation", pattern = body[C.BODY_ADDRESS], variation = body[C.BODY_VALUE]}
  elseif C.EDIT_LAYOUT[cmd] then
    local layout = C.EDIT_LAYOUT[cmd]
    local variation = layout.default_variation or C.VARIATION_CV
    if layout.variation and body[layout.variation] then variation = body[layout.variation] end
    if #body < layout.size or body[C.BODY_ADDRESS] >= C.PATTERNS or variation >= C.VARIATIONS then
      return nil, "invalid hardware edit"
    end
    return {type = "changed", command = cmd, pattern = body[C.BODY_ADDRESS], variation = variation}
  end
  return {type = "other", command = cmd}
end

local function cell(raw, offset, step)
  return floor(raw[offset + floor(step / C.CELLS_PER_BYTE)] /
    (C.CELL_BASE ^ (step % C.CELLS_PER_BYTE))) % C.CELL_BASE
end

function M.step(pattern, zero_step)
  local raw = pattern.raw
  local step = integer(zero_step, 0, C.STEPS - 1, "step")
  local time = cell(raw, C.TIME_OFFSET, step)
  local result = {time = time, ratchet = cell(raw, C.RATCHET_OFFSET, step)}
  if time == C.TIME_NOTE then
    local note_index = 1
    for i = 0, step - 1 do
      if cell(raw, C.TIME_OFFSET, i) == C.TIME_NOTE then note_index = note_index + 1 end
    end
    local pitch = raw[note_index]
    if pitch == C.PITCH_EMPTY then pitch = C.PITCH_DEFAULT end
    result.semitone = pitch % C.PITCH_OCTAVE_BASE
    result.octave = floor(pitch / C.PITCH_OCTAVE_BASE) % C.PITCH_OCTAVES
    result.accent = M.has_flag(pitch, C.ACCENT_FLAG)
    result.slide = M.has_flag(pitch, C.SLIDE_FLAG)
  end
  return result
end

function M.pitch(semitone, octave, accent, slide)
  integer(semitone, 0, C.MAX_SEMITONE, "semitone")
  integer(octave, 0, C.PITCH_OCTAVES - 1, "octave")
  return semitone + octave * C.PITCH_OCTAVE_BASE +
    (accent and C.ACCENT_FLAG or 0) + (slide and C.SLIDE_FLAG or 0)
end

function M.request_config() return {C.MANUFACTURER_ID, CMD.REQUEST_CONFIG} end
function M.request_pattern(pat, var)
  integer(pat, 0, C.PATTERNS - 1, "pattern")
  integer(var, 0, C.VARIATIONS - 1, "variation")
  return {C.MANUFACTURER_ID, CMD.REQUEST_PATTERN, pat, var}
end
function M.queue_pattern(pat)
  integer(pat, 0, C.PATTERNS - 1, "pattern")
  return {C.MANUFACTURER_ID, CMD.QUEUE_PATTERN, pat}
end
function M.select_variation(pat, var)
  integer(pat, 0, C.PATTERNS - 1, "pattern")
  integer(var, 0, C.VARIATIONS - 1, "variation")
  return {C.MANUFACTURER_ID, CMD.EDIT_VARIATION, pat, var}
end

function M.write_step(pat, step, time, pitch)
  integer(pat, 0, C.PATTERNS - 1, "pattern")
  integer(step, 0, C.STEPS - 1, "step")
  integer(time, C.TIME_REST, C.TIME_TIE, "time")
  pitch = (time == C.TIME_NOTE) and integer(pitch, 0, C.BYTE_MAX, "pitch") or C.PITCH_EMPTY
  return {C.MANUFACTURER_ID, CMD.WRITE_STEP, pat, step,
    pitch % C.MIDI_DATA_BASE, floor(pitch / C.MIDI_DATA_BASE), time}
end

function M.write_length(pat, length, triplet)
  integer(pat, 0, C.PATTERNS - 1, "pattern")
  integer(length, C.MIN_LENGTH, triplet and C.TRIPLET_STEPS or C.STEPS, "length")
  return {C.MANUFACTURER_ID, CMD.WRITE_LENGTH, pat, length}
end

function M.write_ratchet(pat, step, count)
  integer(pat, 0, C.PATTERNS - 1, "pattern")
  integer(step, 0, C.STEPS - 1, "step")
  assert(count == C.RATCHET_OFF or count == C.RATCHET_DOUBLE or count == C.RATCHET_TRIPLE,
    "ratchet must be 0, 2 or 3")
  return {C.MANUFACTURER_ID, CMD.WRITE_RATCHET, pat, step, count}
end

function M.write_config(original, changes)
  assert(original and type(original.flags) == "number", "read configuration first")
  local channel = integer(changes.channel, 0, C.MIDI_CHANNELS, "MIDI channel")
  local brightness = integer(changes.brightness, C.MIN_BRIGHTNESS, C.MAX_BRIGHTNESS, "brightness")
  local v2 = integer(changes.var2_channel, 1, C.MIDI_CHANNELS, "variation 2 channel")
  local v3 = integer(changes.var3_channel, 1, C.MIDI_CHANNELS, "variation 3 channel")
  local preserved = floor(original.flags / C.CONFIG_FLAG.RX_DISABLED) * C.CONFIG_FLAG.RX_DISABLED
  local flags = preserved + (changes.clock and C.CONFIG_FLAG.CLOCK or 0) +
    (changes.thru and C.CONFIG_FLAG.THRU or 0)
  return {C.MANUFACTURER_ID, CMD.WRITE_CONFIG, channel, flags, original.direction, brightness, v2, v3}
end

return M
