-- SPDX-License-Identifier: GPL-3.0-only
-- SuperOS-303 application SysEx protocol. No bootloader or firmware opcodes.
local M = {}

M.STEPS = 32
M.PATTERN_SIZE = 60
M.POLY_SIZE = 115
M.PACKED_PATTERN_SIZE = 69
M.PACKED_POLY_SIZE = 132
M.PITCH_EMPTY = 0xFF

local floor = math.floor

local function integer(n, low, high, name)
  assert(type(n) == "number" and n == floor(n) and n >= low and n <= high,
    (name or "value") .. " out of range")
  return n
end

local function xor8(a, b)
  local result, bit = 0, 1
  for _ = 1, 8 do
    if a % 2 ~= b % 2 then result = result + bit end
    a, b, bit = floor(a / 2), floor(b / 2), bit * 2
  end
  return result
end

function M.checksum(raw)
  local sum = 0
  for i = 1, #raw do sum = xor8(sum, integer(raw[i], 0, 255, "raw byte")) end
  return sum
end

function M.pack7(raw)
  local packed = {}
  for i = 1, #raw, 7 do
    local msb, block = 0, {}
    for j = i, math.min(i + 6, #raw) do
      local value = integer(raw[j], 0, 255, "raw byte")
      if value >= 128 then msb = msb + 2 ^ (j - i) end
      block[#block + 1] = value % 128
    end
    packed[#packed + 1] = msb
    for _, value in ipairs(block) do packed[#packed + 1] = value end
  end
  return packed
end

function M.unpack7(packed, count)
  if #packed ~= count + math.ceil(count / 7) then return nil, "packed size mismatch" end
  local raw, pos = {}, 1
  for i = 1, count, 7 do
    local msb = packed[pos]
    if not msb or msb > 127 then return nil, "invalid MSB byte" end
    pos = pos + 1
    for bit = 0, math.min(6, count - i) do
      local value = packed[pos]
      if not value or value > 127 then return nil, "invalid packed data" end
      raw[#raw + 1] = value + (floor(msb / (2 ^ bit)) % 2) * 128
      pos = pos + 1
    end
  end
  return raw
end

function M.frame(body)
  assert(type(body) == "table" and body[1] == 0x7D, "not a SuperOS message")
  local framed = { 0xF0 }
  for i = 1, #body do framed[#framed + 1] = integer(body[i], 0, 127, "SysEx byte") end
  framed[#framed + 1] = 0xF7
  return framed
end

local function body_of(message)
  if type(message) ~= "table" then return nil, "not a byte array" end
  local first = (message[1] == 0xF0) and 2 or 1
  local last = (first == 2) and (#message - 1) or #message
  if first == 2 and message[#message] ~= 0xF7 then return nil, "unterminated SysEx" end
  if last - first < 1 or message[first] ~= 0x7D then return nil, "not SuperOS SysEx" end
  local body = {}
  for i = first, last do
    local v = message[i]
    if type(v) ~= "number" or v ~= floor(v) or v < 0 or v > 127 then
      return nil, "invalid SysEx data byte"
    end
    body[#body + 1] = v
  end
  return body
end

local function decode_blob(body, size, packed_size)
  if #body ~= 5 + packed_size and #body ~= 6 + packed_size then
    return nil, "unsupported blob length"
  end
  local packed = {}
  for i = 6, 5 + packed_size do packed[#packed + 1] = body[i] end
  local raw, err = M.unpack7(packed, size)
  if not raw then return nil, err end
  if M.checksum(raw) ~= body[4] + 128 * body[5] then return nil, "checksum mismatch" end
  return raw
end

function M.decode(message)
  local body, err = body_of(message)
  if not body then return nil, err end
  local cmd = body[2]
  if cmd == 0x21 then
    if #body < 8 then return nil, "short config reply" end
    local version = {}
    for i = 9, #body do version[#version + 1] = string.char(body[i]) end
    return {type = "config", channel = body[3], flags = body[4],
      direction = body[5], brightness = body[6], var2_channel = body[7],
      var3_channel = body[8], version = table.concat(version)}
  elseif cmd == 0x11 then
    local raw, issue = decode_blob(body, M.PATTERN_SIZE, M.PACKED_PATTERN_SIZE)
    if not raw then return nil, issue end
    local variation = (#body > 5 + M.PACKED_PATTERN_SIZE) and body[#body] or 0
    if body[3] > 15 or variation > 2 then return nil, "invalid pattern address" end
    if raw[52] < 1 or raw[52] > M.STEPS or
       ((floor(raw[41] / 8) % 2 == 1) and raw[52] > 24) then
      return nil, "invalid pattern length"
    end
    return {type = "pattern", pattern = body[3], variation = variation,
      raw = raw, length = raw[52], triplet = (floor(raw[41] / 8) % 2 == 1)}
  elseif cmd == 0x25 then
    if #body ~= 5 + M.PACKED_POLY_SIZE then return nil, "unsupported poly length" end
    local raw, issue = decode_blob(body, M.POLY_SIZE, M.PACKED_POLY_SIZE)
    if not raw then return nil, issue end
    if body[3] > 15 then return nil, "invalid poly address" end
    return {type = "poly", pattern = body[3], variation = 2, raw = raw}
  elseif cmd == 0x14 then
    if #body < 3 then return nil, "short acknowledgement" end
    return {type = "ack", status = body[3]}
  elseif cmd == 0x1C then
    if #body < 3 or body[3] > 3 then return nil, "invalid group" end
    return {type = "group", group = body[3]}
  elseif cmd == 0x1E or cmd == 0x15 then
    if #body < 4 or body[3] > 15 then return nil, "invalid pattern selection" end
    return {type = (cmd == 0x1E) and "active" or "position",
      pattern = body[3], step = (cmd == 0x15) and body[4] or nil,
      group = body[5] or body[4]}
  elseif cmd == 0x1F then
    if #body < 4 then return nil, "short variation reply" end
    return {type = "variation", pattern = body[3], variation = body[4]}
  elseif cmd == 0x16 or cmd == 0x18 or cmd == 0x27 or
         cmd == 0x28 or cmd == 0x29 or cmd == 0x2A or cmd == 0x2B then
    return {type = "changed", command = cmd, pattern = body[3]}
  end
  return {type = "other", command = cmd}
end

function M.step(pattern, zero_step)
  local raw = pattern.raw
  local step = integer(zero_step, 0, M.STEPS - 1, "step")
  local timebyte = raw[33 + floor(step / 4)]
  local time = floor(timebyte / (4 ^ (step % 4))) % 4
  local ratchet = floor(raw[53 + floor(step / 4)] / (4 ^ (step % 4))) % 4
  local result = {time = time, ratchet = ratchet}
  if time == 1 then
    local note_index = 1
    for i = 0, step - 1 do
      local b = raw[33 + floor(i / 4)]
      if floor(b / (4 ^ (i % 4))) % 4 == 1 then note_index = note_index + 1 end
    end
    local pitch = raw[note_index]
    if pitch == M.PITCH_EMPTY then pitch = 0x10 end
    result.semitone = pitch % 16
    result.octave = floor(pitch / 16) % 4
    result.accent = floor(pitch / 64) % 2 == 1
    result.slide = floor(pitch / 128) % 2 == 1
  end
  return result
end

function M.pitch(semitone, octave, accent, slide)
  integer(semitone, 0, 12, "semitone")
  integer(octave, 0, 3, "octave")
  return semitone + octave * 16 + (accent and 64 or 0) + (slide and 128 or 0)
end

function M.request_config() return {0x7D, 0x20} end
function M.request_pattern(pat, var)
  integer(pat, 0, 15, "pattern")
  integer(var, 0, 2, "variation")
  return {0x7D, 0x10, pat, var}
end
function M.queue_pattern(pat)
  integer(pat, 0, 15, "pattern")
  return {0x7D, 0x1D, pat}
end
function M.select_variation(pat, var)
  integer(pat, 0, 15, "pattern")
  integer(var, 0, 2, "variation")
  return {0x7D, 0x1F, pat, var}
end

function M.write_step(pat, step, time, pitch)
  integer(pat, 0, 15, "pattern")
  integer(step, 0, M.STEPS - 1, "step")
  integer(time, 0, 2, "time")
  pitch = (time == 1) and integer(pitch, 0, 255, "pitch") or M.PITCH_EMPTY
  return {0x7D, 0x16, pat, step, pitch % 128, floor(pitch / 128), time}
end

function M.write_length(pat, length, triplet)
  integer(pat, 0, 15, "pattern")
  integer(length, 1, triplet and 24 or M.STEPS, "length")
  return {0x7D, 0x18, pat, length}
end

function M.write_ratchet(pat, step, count)
  integer(pat, 0, 15, "pattern")
  integer(step, 0, M.STEPS - 1, "step")
  assert(count == 0 or count == 2 or count == 3, "ratchet must be 0, 2 or 3")
  return {0x7D, 0x28, pat, step, count}
end

function M.write_config(original, changes)
  assert(original and type(original.flags) == "number", "read configuration first")
  local channel = integer(changes.channel, 0, 16, "MIDI channel")
  local brightness = integer(changes.brightness, 1, 8, "brightness")
  local v2 = integer(changes.var2_channel, 1, 16, "variation 2 channel")
  local v3 = integer(changes.var3_channel, 1, 16, "variation 3 channel")
  local preserved = floor(original.flags / 4) * 4 -- preserve SysEx RX/TX disable bits
  local flags = preserved + (changes.clock and 1 or 0) + (changes.thru and 2 or 0)
  return {0x7D, 0x22, channel, flags, original.direction, brightness, v2, v3}
end

return M
