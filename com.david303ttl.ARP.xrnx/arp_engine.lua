-- Pure Lua arpeggiator logic. MIDI-like note values (0..119).
local M = {}

function M.order_notes(input, mode)
  assert(type(input) == "table", "input must be an array")
  mode = mode or "up"
  assert(mode == "up" or mode == "down" or mode == "up_down", "invalid mode")
  local notes = {}
  for _, v in ipairs(input) do
    assert(type(v) == "number" and v % 1 == 0 and v >= 0 and v <= 119,
      "invalid note")
    notes[#notes+1] = v
  end
  table.sort(notes)
  if mode == "down" then
    local reverse = {}
    for i=#notes,1,-1 do reverse[#reverse+1] = notes[i] end
    return reverse
  end
  if mode == "up_down" then
    for i=#notes-1,2,-1 do notes[#notes+1] = notes[i] end
  end
  return notes
end

-- Chords: ordered {line, notes, instrument}. A chord lasts until the
-- next chord onset. No implicit chord is assumed before the first onset.
-- Each onset starts its own phase. This function does not mutate input.
function M.generate(chords, length, rate, mode)
  assert(type(chords) == "table" and type(length) == "number"
    and type(rate) == "number" and rate >= 1 and rate % 1 == 0,
    "invalid generator arguments")
  local events = {}
  for i, chord in ipairs(chords) do
    local next_chord = chords[i+1]
    local stop = next_chord and (next_chord.line - 1) or length
    local ordered = M.order_notes(chord.notes, mode)
    if #ordered > 0 then
      local cycle = 1
      for line = chord.line, stop, rate do
        events[#events+1] = {
          line = line,
          note = ordered[cycle],
          instrument = chord.instrument
        }
        cycle = cycle % #ordered + 1
      end
    end
  end
  return events
end

return M
