-- SPDX-License-Identifier: GPL-3.0-only
-- Pure pattern/scale/poly helpers. Uses the firmware's two-stream data layout.
local C = require("constants")
local protocol = require("protocol")
local M = {}
local floor = math.floor

local NOTES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B", "C+"}
local DIRECTIONS = {"Forward", "Reverse", "Ping-pong", "Random", "Half random", "Brownian"}
M.notes, M.directions = NOTES, DIRECTIONS

local function is_int(v, lo, hi)
  return type(v) == "number" and v == floor(v) and v >= lo and v <= hi
end

local function copy(raw)
  local result = {}
  for i = 1, #raw do result[i] = raw[i] end
  return result
end

local function cell(raw, offset, step)
  return floor(raw[offset + floor(step / 4)] / (4 ^ (step % 4))) % 4
end

local function put_cell(raw, offset, step, value)
  local index = offset + floor(step / 4)
  local shift = 4 ^ (step % 4)
  local old = cell(raw, offset, step)
  raw[index] = raw[index] + (value - old) * shift
end

local function bit(value, bit_index)
  return floor(value / (2 ^ bit_index)) % 2 == 1
end

function M.poly_step(pattern, step)
  assert(pattern.type == "poly", "expected poly pattern")
  assert(is_int(step, 0, C.STEPS - 1), "invalid step index")
  local raw = pattern.raw
  local t = cell(raw, 97, step) -- notes[96], then time[8]
  local result = {time = t, ratchet = 0, voices = {}, accent = false, slide = false}
  if t ~= C.TIME_NOTE then return result end
  local chord_index = 0
  for s = 0, step - 1 do
    if cell(raw, 97, s) == C.TIME_NOTE then chord_index = chord_index + 1 end
  end
  if chord_index >= raw[113] then return result end -- empty/legacy chord stream
  local offset = chord_index * 3
  local a, b, c = raw[offset + 1], raw[offset + 2], raw[offset + 3]
  result.voices = {
    a % 64,
    floor(a / 64) + (b % 16) * 4,
    floor(b / 16) + (c % 4) * 16,
    floor(c / 4)
  }
  result.accent = bit(raw[105 + floor(chord_index / 8)], chord_index % 8)
  result.slide = bit(raw[109 + floor(chord_index / 8)], chord_index % 8)
  return result
end

function M.step(pattern, step)
  if pattern.type == "poly" then return M.poly_step(pattern, step) end
  return protocol.step(pattern, step)
end

function M.pitch_label(packed)
  if packed == nil or packed == 63 then return "--" end
  local semi, oct = packed % 16, floor(packed / 16) % 4
  if semi > 12 then return "?" end
  return NOTES[semi + 1] .. (oct - 1 < 0 and "-1" or tostring(oct - 1))
end

function M.step_label(pattern, step)
  if step >= pattern.length then return string.format("%02d  --", step + 1) end
  local s = M.step(pattern, step)
  local label = "--"
  if s.time == C.TIME_TIE then label = "TIE"
  elseif s.time == C.TIME_NOTE then
    if pattern.type == "poly" then
      local count = 0
      for _, voice in ipairs(s.voices) do if voice ~= 63 then count = count + 1 end end
      label = tostring(count) .. "V"
    else
      label = NOTES[(s.semitone or 0) + 1] .. tostring((s.octave or 1) - 1)
    end
  end
  local flags = (s.accent and "A" or "") .. (s.slide and "S" or "")
  if s.ratchet == 2 or s.ratchet == 3 then flags = flags .. tostring(s.ratchet) end
  return string.format("%02d %-4s%s", step + 1, label, flags)
end

function M.metadata(pattern)
  if pattern.type == "poly" then
    return {direction = pattern.raw[114], length = pattern.raw[115],
      triplet = false, transpose = 0}
  end
  local raw = pattern.raw
  local transpose = raw[50]
  if transpose >= 128 then transpose = transpose - 256 end
  return {direction = raw[C.FLAGS_OFFSET] % 8,
    triplet = floor(raw[C.FLAGS_OFFSET] / 8) % 2 == 1,
    transpose = transpose, length = pattern.length}
end

function M.with_metadata(pattern, direction, triplet, transpose)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(direction, 0, 5), "invalid direction")
  assert(is_int(transpose, -24, 24), "invalid transpose")
  assert(type(triplet) == "boolean", "invalid triplet flag")
  if triplet and pattern.length > C.TRIPLET_STEPS then
    return nil, "triplet length must be at most 24"
  end
  local raw = copy(pattern.raw)
  local flags = raw[C.FLAGS_OFFSET]
  raw[C.FLAGS_OFFSET] = flags - flags % 16 + direction + (triplet and 8 or 0)
  raw[50] = transpose % 256
  return raw
end

function M.with_length(pattern, length)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(length, 1, pattern.triplet and C.TRIPLET_STEPS or C.STEPS), "invalid length")
  local raw = copy(pattern.raw)
  raw[C.LENGTH_OFFSET] = length
  return raw
end

function M.with_step(pattern, step, time, pitch)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(step, 0, pattern.length - 1), "invalid step")
  assert(is_int(time, 0, 2), "invalid time")
  if time == C.TIME_NOTE then
    assert(is_int(pitch, 0, 255) and pitch ~= C.PITCH_EMPTY, "invalid pitch")
  end
  local raw = copy(pattern.raw)
  put_cell(raw, C.TIME_OFFSET, step, time)
  if time == C.TIME_NOTE then
    local index = 1
    for s = 0, step - 1 do
      if cell(raw, C.TIME_OFFSET, s) == C.TIME_NOTE then index = index + 1 end
    end
    raw[index] = pitch
  end
  return raw
end

function M.with_ratchet(pattern, step, count)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(step, 0, pattern.length - 1), "invalid step")
  assert(count == 0 or count == 2 or count == 3, "invalid ratchet")
  local raw = copy(pattern.raw)
  put_cell(raw, C.RATCHET_OFFSET, step, count)
  return raw
end

function M.scale(pattern)
  assert(pattern.type == "pattern", "mono pattern only")
  local raw = pattern.raw
  local mask = raw[42] + (raw[43] % 16) * 256
  if mask == 0 then mask = 4095 end
  return {mask = mask, enabled = raw[43] >= 128}
end

function M.with_scale(pattern, mask, enabled)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(mask, 1, 4095), "select at least one scale note")
  local raw = copy(pattern.raw)
  raw[42] = mask % 256
  -- Firmware rewrites reserved[2] to mask high nibble plus the enable flag.
  raw[43] = floor(mask / 256) + (enabled and 128 or 0)
  return raw
end

M.scale_presets = {"Chromatic", "Major", "Natural minor", "Minor pentatonic", "Major pentatonic"}
M.scale_roots = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local PRESET_INTERVALS = {
  {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
  {0, 2, 4, 5, 7, 9, 11},
  {0, 2, 3, 5, 7, 8, 10},
  {0, 3, 5, 7, 10},
  {0, 2, 4, 7, 9}
}

function M.preset_mask(root, preset)
  assert(is_int(root, 0, 11) and is_int(preset, 1, #PRESET_INTERVALS),
    "invalid scale preset")
  local mask = 0
  for _, interval in ipairs(PRESET_INTERVALS[preset]) do
    mask = mask + 2 ^ ((root + interval) % 12)
  end
  return mask
end

function M.poly_length(pattern)
  return pattern.raw[115]
end

function M.with_poly_step(pattern, step, time, voices, accent, slide)
  assert(pattern.type == "poly", "poly pattern only")
  assert(is_int(step, 0, pattern.length - 1), "invalid step")
  assert(is_int(time, 0, 2), "invalid time")
  assert(#voices == 4, "four voices are required")
  for i = 1, 4 do
    assert(is_int(voices[i], 0, 63), "invalid packed voice")
    assert(voices[i] == 63 or voices[i] % 16 <= 12, "invalid voice note")
  end
  return {C.MANUFACTURER_ID, C.COMMAND.POLY_STEP, pattern.pattern, step,
    voices[1], voices[2], voices[3], voices[4], time,
    (accent and 1 or 0) + (slide and 2 or 0)}
end

function M.probability(raw, step)
  assert(#raw == 3 * C.STEPS and is_int(step, 0, C.STEPS - 1),
    "invalid probability table or step")
  local offset = step * 3
  local a, b, c = raw[offset + 1], raw[offset + 2], raw[offset + 3]
  return {accent = a % 16, slide = floor(a / 16),
    down = b % 16, up = floor(b / 16), double = c % 2 == 1}
end

return M
