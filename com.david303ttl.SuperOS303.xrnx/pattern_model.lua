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
  return floor(raw[offset + floor(step / C.CELLS_PER_BYTE)] /
    (C.CELL_BASE ^ (step % C.CELLS_PER_BYTE))) % C.CELL_BASE
end

local function put_cell(raw, offset, step, value)
  local index = offset + floor(step / C.CELLS_PER_BYTE)
  local shift = C.CELL_BASE ^ (step % C.CELLS_PER_BYTE)
  local old = cell(raw, offset, step)
  raw[index] = raw[index] + (value - old) * shift
end

local function bit(value, bit_index)
  return floor(value / (C.BIT_BASE ^ bit_index)) % C.BIT_BASE == 1
end

function M.poly_step(pattern, step)
  assert(pattern.type == "poly", "expected poly pattern")
  assert(is_int(step, 0, C.STEPS - 1), "invalid step index")
  local raw = pattern.raw
  local t = cell(raw, C.POLY_TIME_OFFSET, step)
  local result = {time = t, ratchet = C.RATCHET_OFF, voices = {}, accent = false, slide = false}
  if t ~= C.TIME_NOTE then return result end
  local chord_index = 0
  for s = 0, step - 1 do
    if cell(raw, C.POLY_TIME_OFFSET, s) == C.TIME_NOTE then chord_index = chord_index + 1 end
  end
  if chord_index >= raw[C.POLY_CHORD_COUNT_OFFSET] then return result end -- empty/legacy chord stream
  local offset = chord_index * C.POLY_CHORD_BYTES
  local a, b, c = raw[offset + 1], raw[offset + 2], raw[offset + 3]
  result.voices = {
    a % C.POLY_VOICE_BASE,
    floor(a / C.POLY_VOICE_BASE) + (b % C.NIBBLE_BASE) * C.POLY_VOICE_TAIL_BASE,
    floor(b / C.NIBBLE_BASE) + (c % C.POLY_VOICE_TAIL_BASE) * C.NIBBLE_BASE,
    floor(c / C.POLY_VOICE_TAIL_BASE)
  }
  result.accent = bit(raw[C.POLY_ACCENT_OFFSET + floor(chord_index / C.BYTE_BITS)],
    chord_index % C.BYTE_BITS)
  result.slide = bit(raw[C.POLY_SLIDE_OFFSET + floor(chord_index / C.BYTE_BITS)],
    chord_index % C.BYTE_BITS)
  return result
end

function M.step(pattern, step)
  if pattern.type == "poly" then return M.poly_step(pattern, step) end
  return protocol.step(pattern, step)
end

function M.pitch_label(packed)
  if packed == nil or packed == C.POLY_EMPTY then return "--" end
  local semi = packed % C.PITCH_OCTAVE_BASE
  local oct = floor(packed / C.PITCH_OCTAVE_BASE) % C.PITCH_OCTAVES
  if semi > C.MAX_SEMITONE then return "?" end
  return NOTES[semi + 1] .. tostring(oct - C.OCTAVE_LABEL_OFFSET)
end

function M.step_label(pattern, step)
  if step >= pattern.length then return string.format("%02d  --", step + 1) end
  local s = M.step(pattern, step)
  local label = "--"
  if s.time == C.TIME_TIE then label = "TIE"
  elseif s.time == C.TIME_NOTE then
    if pattern.type == "poly" then
      local count = 0
      for _, voice in ipairs(s.voices) do if voice ~= C.POLY_EMPTY then count = count + 1 end end
      label = tostring(count) .. "V"
    else
      label = NOTES[(s.semitone or C.DEFAULT_SEMITONE) + 1] ..
        tostring((s.octave or C.DEFAULT_OCTAVE) - C.OCTAVE_LABEL_OFFSET)
    end
  end
  local flags = (s.accent and "A" or "") .. (s.slide and "S" or "")
  if s.ratchet == C.RATCHET_DOUBLE or s.ratchet == C.RATCHET_TRIPLE then
    flags = flags .. tostring(s.ratchet)
  end
  return string.format("%02d %-4s%s", step + 1, label, flags)
end

function M.metadata(pattern)
  if pattern.type == "poly" then
    return {direction = pattern.raw[C.POLY_DIRECTION_OFFSET], length = pattern.raw[C.POLY_LENGTH_OFFSET],
      triplet = false, transpose = 0}
  end
  local raw = pattern.raw
  local transpose = raw[C.TRANSPOSE_OFFSET]
  if transpose >= C.SIGNED_BYTE_THRESHOLD then transpose = transpose - C.BYTE_BASE end
  return {direction = raw[C.FLAGS_OFFSET] % C.DIRECTION_BASE,
    triplet = protocol.has_flag(raw[C.FLAGS_OFFSET], C.TRIPLET_FLAG),
    transpose = transpose, length = pattern.length}
end

function M.with_metadata(pattern, direction, triplet, transpose)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(direction, 0, C.DIRECTION_MAX), "invalid direction")
  assert(is_int(transpose, -C.TRANSPOSE_LIMIT, C.TRANSPOSE_LIMIT), "invalid transpose")
  assert(type(triplet) == "boolean", "invalid triplet flag")
  if triplet and pattern.length > C.TRIPLET_STEPS then
    return nil, string.format("triplet length must be at most %d", C.TRIPLET_STEPS)
  end
  local raw = copy(pattern.raw)
  local flags = raw[C.FLAGS_OFFSET]
  raw[C.FLAGS_OFFSET] = flags - flags % C.NIBBLE_BASE + direction + (triplet and C.TRIPLET_FLAG or 0)
  raw[C.TRANSPOSE_OFFSET] = transpose % C.BYTE_BASE
  return raw
end

function M.with_length(pattern, length)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(length, C.MIN_LENGTH, pattern.triplet and C.TRIPLET_STEPS or C.STEPS), "invalid length")
  local raw = copy(pattern.raw)
  raw[C.LENGTH_OFFSET] = length
  return raw
end

function M.with_step(pattern, step, time, pitch)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(step, 0, pattern.length - 1), "invalid step")
  assert(is_int(time, C.TIME_REST, C.TIME_TIE), "invalid time")
  if time == C.TIME_NOTE then
    assert(is_int(pitch, 0, C.BYTE_MAX) and pitch ~= C.PITCH_EMPTY, "invalid pitch")
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
  assert(count == C.RATCHET_OFF or count == C.RATCHET_DOUBLE or count == C.RATCHET_TRIPLE,
    "invalid ratchet")
  local raw = copy(pattern.raw)
  put_cell(raw, C.RATCHET_OFFSET, step, count)
  return raw
end

function M.scale(pattern)
  assert(pattern.type == "pattern", "mono pattern only")
  local raw = pattern.raw
  local mask = raw[C.SCALE_LOW_OFFSET] + (raw[C.SCALE_HIGH_OFFSET] % C.NIBBLE_BASE) * C.BYTE_BASE
  if mask == 0 then mask = C.SCALE_MASK_MAX end
  return {mask = mask, enabled = raw[C.SCALE_HIGH_OFFSET] >= C.SCALE_ENABLED_FLAG}
end

function M.with_scale(pattern, mask, enabled)
  assert(pattern.type == "pattern", "mono pattern only")
  assert(is_int(mask, 1, C.SCALE_MASK_MAX), "select at least one scale note")
  local raw = copy(pattern.raw)
  raw[C.SCALE_LOW_OFFSET] = mask % C.BYTE_BASE
  -- Firmware rewrites reserved[2] to mask high nibble plus the enable flag.
  raw[C.SCALE_HIGH_OFFSET] = floor(mask / C.BYTE_BASE) + (enabled and C.SCALE_ENABLED_FLAG or 0)
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
  assert(is_int(root, 0, C.SEMITONES_PER_OCTAVE - 1) and is_int(preset, 1, #PRESET_INTERVALS),
    "invalid scale preset")
  local mask = 0
  for _, interval in ipairs(PRESET_INTERVALS[preset]) do
    mask = mask + C.BIT_BASE ^ ((root + interval) % C.SEMITONES_PER_OCTAVE)
  end
  return mask
end

function M.poly_length(pattern)
  return pattern.raw[C.POLY_LENGTH_OFFSET]
end

function M.with_poly_step(pattern, step, time, voices, accent, slide)
  assert(pattern.type == "poly", "poly pattern only")
  assert(is_int(step, 0, pattern.length - 1), "invalid step")
  assert(is_int(time, C.TIME_REST, C.TIME_TIE), "invalid time")
  assert(#voices == C.POLY_VOICES, "four voices are required")
  for i = 1, C.POLY_VOICES do
    assert(is_int(voices[i], 0, C.POLY_VOICE_BASE - 1), "invalid packed voice")
    assert(voices[i] == C.POLY_EMPTY or voices[i] % C.PITCH_OCTAVE_BASE <= C.MAX_SEMITONE,
      "invalid voice note")
  end
  return {C.MANUFACTURER_ID, C.COMMAND.POLY_STEP, pattern.pattern, step,
    voices[1], voices[2], voices[3], voices[4], time,
    (accent and C.POLY_STEP_FLAG.ACCENT or 0) + (slide and C.POLY_STEP_FLAG.SLIDE or 0)}
end

function M.probability(raw, step)
  assert(#raw == C.PROBABILITY_SIZE and is_int(step, 0, C.STEPS - 1),
    "invalid probability table or step")
  local offset = step * C.PROBABILITY_BYTES_PER_STEP
  local a, b, c = raw[offset + 1], raw[offset + 2], raw[offset + 3]
  return {accent = a % C.NIBBLE_BASE, slide = floor(a / C.NIBBLE_BASE),
    down = b % C.NIBBLE_BASE, up = floor(b / C.NIBBLE_BASE),
    double = protocol.has_flag(c, C.PROBABILITY_DOUBLE_FLAG)}
end

return M
