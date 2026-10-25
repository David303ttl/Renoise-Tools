-- ARP v0.4: pure-Lua note ordering and timing planner.
local M = {}

function M.order_notes(input, mode)
  assert(type(input) == "table", "input must be an array")
  mode = mode or "up"
  assert(mode == "up" or mode == "down" or mode == "up_down", "invalid mode")
  local notes = {}
  for _, note in ipairs(input) do
    assert(type(note) == "number" and note % 1 == 0
      and note >= 0 and note <= 119, "invalid note")
    notes[#notes + 1] = note
  end
  table.sort(notes)
  if mode == "down" then
    local reverse = {}
    for i = #notes, 1, -1 do reverse[#reverse + 1] = notes[i] end
    return reverse
  end
  if mode == "up_down" then
    local n = #notes
    for i = n - 1, 2, -1 do notes[#notes + 1] = notes[i] end
  end
  return notes
end

function M.rate_lines(lpb, division)
  assert(type(lpb) == "number" and lpb >= 1 and lpb % 1 == 0, "invalid LPB")
  local denom = assert(({["1/4"]=4, ["1/8"]=8,
    ["1/16"]=16, ["1/32"]=32})[division], "invalid rate")
  local lines = 4 * lpb / denom
  if lines < 1 or lines % 1 ~= 0 then
    return nil, "Rate requires sub-line note-ons: increase LPB or select a slower rate"
  end
  return lines
end

function M.expand_notes(notes, octaves, mode)
  assert(type(octaves) == "number" and octaves % 1 == 0
    and octaves >= 1 and octaves <= 4, "octaves must be 1..4")
  local expanded = {}
  for oct = 0, octaves - 1 do
    for _, note in ipairs(notes) do
      local shifted = note + 12 * oct
      if shifted <= 119 then expanded[#expanded + 1] = shifted end
    end
  end
  return M.order_notes(expanded, mode)
end

-- An onset belongs to a chord until the next chord onset or pattern end.
function M.generate(chords, length, rate, mode, octaves)
  assert(type(chords) == "table" and type(length) == "number"
    and type(rate) == "number" and rate % 1 == 0 and rate >= 1,
    "invalid generator arguments")
  local result = {}
  for i, chord in ipairs(chords) do
    local next_chord = chords[i+1]
    local stop = next_chord and next_chord.line - 1 or length
    local ordered = M.expand_notes(chord.notes, octaves or 1, mode)
    if #ordered > 0 then
      local cursor = 1
      for line = chord.line, stop, rate do
        result[#result + 1] = {
          line = line, note = ordered[cursor], instrument = chord.instrument
        }
        cursor = cursor % #ordered + 1
      end
    end
  end
  return result
end

-- Gate <100%: explicit OFF in the same note column, with sub-line delay
-- when required. Renoise has one event per note column per line: if ON
-- and OFF need the same line, reject instead of approximating silently.
-- Gate 100% maintains v0.3 legato/retrigger semantics (no OFF events).
-- All events use 1-based lines and 0..255 delay units.
function M.plan(chords, length, rate, mode, octaves, gate)
  gate = gate or 100
  if gate ~= 25 and gate ~= 50 and gate ~= 75 and gate ~= 100 then
    return nil, "Gate must be 25, 50, 75 or 100 percent"
  end
  local ons = M.generate(chords, length, rate, mode, octaves)
  local events, occupied = {}, {}
  local off_count = 0
  for i, note in ipairs(ons) do
    if note.line < 1 or note.line > length or occupied[note.line] then
      return nil, "Overlapping note-on positions"
    end
    events[#events + 1] = {
      line=note.line, delay=0, kind="on",
      note=note.note, instrument=note.instrument
    }
    occupied[note.line] = true
    if gate < 100 then
      local start = (note.line - 1) * 256
      local stop = start + math.floor(rate * 256 * gate / 100 + 0.5)
      if ons[i+1] and stop >= (ons[i+1].line - 1) * 256 then
        return nil, "Gate overlaps next note; use shorter gate or slower rate"
      end
      if stop >= length * 256 then
        return nil, "Gate extends past pattern end; use 100% or adjust notes"
      end
      local off_line = math.floor(stop / 256) + 1
      if off_line == note.line then
        return nil, "Gate needs ON and OFF on the same line; increase LPB or rate"
      end
      if occupied[off_line] then
        return nil, "Gate OFF shares a line with another note"
      end
      occupied[off_line] = true
      events[#events + 1] = {
        line=off_line, delay=stop % 256, kind="off",
        note=120, instrument=255
      }
      off_count = off_count + 1
    end
  end
  table.sort(events, function(a,b)
    if a.line ~= b.line then return a.line < b.line end
    return a.delay < b.delay
  end)
  return events, nil, #ons, off_count
end

-- Precise musical rate in 1/256-line units, independent of global LPB.
function M.rate_subunits(lpb, division)
  assert(type(lpb)=="number" and lpb>=1 and lpb%1==0,"invalid LPB")
  local denominator=({["1/4"]=4,["1/8"]=8,
    ["1/16"]=16,["1/32"]=32})[division]
  if not denominator then return nil,"Unsupported musical division" end
  local units=4*lpb*256/denominator
  if units<1 or units%1~=0 then
    return nil,"Rate is below Renoise delay resolution"
  end
  return units
end

-- Schedule non-integer-line note-ons. Every event on a shared line gets
-- its own note column, ordered from left to right by delay.
-- At 100% gate no OFFs are emitted, matching the legacy note-on mode.
-- Short gates with fractional rates are intentionally not implemented:
-- a voice cannot receive ON and OFF on the same line/column.
function M.plan_subline(chords, length, units, mode, octaves, gate)
  if gate~=100 then
    return nil,"Sub-line rate currently supports Gate 100% only"
  end
  local events,per_line,max_columns={}, {}, 0
  for i,chord in ipairs(chords) do
    local start=(chord.line-1)*256
    local next_chord=chords[i+1]
    local finish=next_chord and (next_chord.line-1)*256 or length*256
    local ordered=M.expand_notes(chord.notes,octaves,mode)
    local cursor=1
    if #ordered>0 then
      for tick=start,finish-1,units do
        local line=math.floor(tick/256)+1
        local delay=tick%256
        local column=(per_line[line] or 0)+1
        per_line[line]=column
        if column>max_columns then max_columns=column end
        if max_columns>12 then
          return nil,"Musical rate needs more than Renoise's 12 note columns"
        end
        events[#events+1]={
          line=line,column=column,delay=delay,kind="on",
          note=ordered[cursor],instrument=chord.instrument
        }
        cursor=cursor%#ordered+1
      end
    end
  end
  return events,nil,#events,0,max_columns
end

return M
