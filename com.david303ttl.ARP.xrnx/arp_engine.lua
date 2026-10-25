-- Pure Lua ARP v0.3 note ordering and scheduler.
local M = {}
function M.order_notes(input, mode)
  assert(type(input) == "table", "input must be an array")
  mode = mode or "up"
  assert(mode == "up" or mode == "down" or mode == "up_down", "invalid mode")
  local notes = {}
  for _, v in ipairs(input) do
    assert(type(v) == "number" and v % 1 == 0 and v >= 0 and v <= 119, "invalid note")
    notes[#notes+1] = v
  end
  table.sort(notes)
  if mode == "down" then
    local reverse = {}
    for i=#notes,1,-1 do reverse[#reverse+1] = notes[i] end
    return reverse
  end
  if mode == "up_down" then
    local count = #notes
    for i=count-1,2,-1 do notes[#notes+1] = notes[i] end
  end
  return notes
end

-- Convert named note length into Renoise pattern lines at current LPB.
-- Fractional lines cannot be represented by this v0.3 writer.
function M.rate_lines(lpb, division)
  assert(type(lpb) == "number" and lpb >= 1 and lpb % 1 == 0, "invalid LPB")
  local denominators = { ["1/4"] = 4, ["1/8"] = 8, ["1/16"] = 16, ["1/32"] = 32 }
  local denominator = assert(denominators[division], "unsupported division")
  local lines = lpb * 4 / denominator
  if lines < 1 or lines % 1 ~= 0 then
    return nil, "Selected rate needs sub-line timing; increase LPB or choose a slower rate"
  end
  return lines
end

-- Expand by octaves, then apply direction; duplicate source pitches are
-- retained intentionally to permit repeated-note patterns.
function M.expand_notes(notes, octaves, mode)
  assert(type(octaves) == "number" and octaves % 1 == 0
    and octaves >= 1 and octaves <= 4, "octave count must be 1..4")
  local expanded = {}
  for octave = 0, octaves - 1 do
    for _, note in ipairs(notes) do
      local shifted = note + 12 * octave
      if shifted <= 119 then expanded[#expanded+1] = shifted end
    end
  end
  return M.order_notes(expanded, mode)
end

-- Chords: ordered {line, notes, instrument}; each chord phase restarts
-- at its onset. Emits note-ons only, as in v0.2.
function M.generate(chords, length, rate, mode, octaves)
  assert(type(chords) == "table" and type(length) == "number"
    and type(rate) == "number" and rate >= 1 and rate % 1 == 0,
    "invalid generator arguments")
  octaves = octaves or 1
  local events = {}
  for i, chord in ipairs(chords) do
    local next_chord = chords[i+1]
    local stop = next_chord and (next_chord.line - 1) or length
    local ordered = M.expand_notes(chord.notes, octaves, mode)
    if #ordered > 0 then
      local cycle = 1
      for line = chord.line, stop, rate do
        events[#events+1] = {
          line = line, note = ordered[cycle], instrument = chord.instrument
        }
        cycle = cycle % #ordered + 1
      end
    end
  end
  return events
end
return M
