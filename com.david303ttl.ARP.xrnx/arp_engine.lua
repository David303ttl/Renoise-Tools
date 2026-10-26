-- Pure-Lua note ordering and timing planner.
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
-- Gate 100% emits note onsets without OFF events.
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
-- Short gates are rejected when ON and OFF need the same line and column.
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

-- Fractional-line gates that cannot be expressed as same-column Note-Offs
-- may be represented as explicit Renoise Cx tick-cuts. This is NOT a
-- Note-Off: it stops the voice without running a release envelope.
-- Conservative rule: each cut must be EXACTLY on a tick and before its
-- note's pattern-line boundary; no TPL or LPB adjustments are made.
function M.attach_tick_cuts(events, units, gate, tpl)
  if type(tpl)~="number" or tpl%1~=0 or tpl<1 or tpl>16 then
    return nil,"Invalid TPL (expected 1..16)"
  end
  if gate~=25 and gate~=50 and gate~=75 then
    return nil,"Tick Cut requires a 25%, 50% or 75% gate"
  end
  local duration_units=units*gate/100
  local ticks=duration_units*tpl/256
  if ticks%1~=0 or ticks<1 or ticks>15 then
    return nil,string.format(
      "Cut duration is %.3f ticks at TPL %d; "
      .."Cx requires an exact integer from 1 to 15",ticks,tpl)
  end
  local planned={}
  for i,event in ipairs(events) do
    local end_delay=event.delay+duration_units
    if end_delay>=256 then
      return nil,string.format(
        "Cut on pattern line %02d would cross the line boundary; "
        .."cannot guarantee gate timing",event.line-1)
    end
    local cloned={}
    for k,v in pairs(event) do cloned[k]=v end
    cloned.cut_ticks=ticks
    planned[i]=cloned
  end
  return planned,nil,ticks
end

-- Renoise NoteColumn panning_value command representation: 0x0000xxyy,
-- where xy is the ASCII two-character effect command (e.g. C3 -> 0x4333).
-- Separate helper makes the encoding unit-testable.
function M.cut_command_value(ticks)
  if type(ticks)~="number" or ticks%1~=0 or ticks<1 or ticks>15 then
    error("Invalid Cx tick-cut value")
  end
  local command=string.format("C%X",ticks)
  return string.byte(command,1)*256+string.byte(command,2)
end

-- Fractional-line *release* planner. Renoise only permits one event in
-- each note-column/line cell. Allocate ON/OFF pairs to a stable column
-- (voice lane), rejecting same-line releases and any overlapping cells.
-- Does not implement tick cuts: those do not trigger release envelopes.
function M.plan_fractional_release(chords, length, units, mode, octaves, gate)
  if gate~=25 and gate~=50 and gate~=75 then
    return nil,"Fractional release gate must be 25%, 50%, or 75%"
  end
  if units%256==0 then
    return nil,"Use the whole-line release planner for this rate"
  end
  local duration=units*gate/100
  if duration<1 or duration%1~=0 then
    return nil,"Gate falls between Renoise's 1/256-line delay positions"
  end
  local ons,err,note_count= M.plan_subline(
    chords,length,units,mode,octaves,100)
  if not ons then return nil,err end

  local events,occupied,available={}, {}, {}
  local max_columns=0
  for i, note in ipairs(ons) do
    local start=(note.line-1)*256+note.delay
    local finish=start+duration
    local off_line=math.floor(finish/256)+1
    if off_line>length then
      return nil,string.format(
        "Gate from %02X+%02X needs OFF at %02X+%02X outside %d-line pattern; "
        .."increase pattern length or use Gate 100%%",
        note.line-1,note.delay,off_line-1,finish%256,length)
    end
    if off_line==note.line then
      return nil,"Note-Off shares a pattern line with its Note-On. "
        .."Choose a longer rate, larger LPB, or Gate 100%."
    end
    if ons[i+1] then
      local next_start=(ons[i+1].line-1)*256+ons[i+1].delay
      if finish>=next_start then
        return nil,"Gate overlaps the next note"
      end
    end
    local lane
    for col=1,12 do
      local slots=occupied[col] or {}
      if not slots[note.line] and not slots[off_line]
        and (available[col] or -1)<start then
        lane=col
        break
      end
    end
    if not lane then
      return nil,"Release timing requires more than 12 independent note columns"
    end
    occupied[lane]=occupied[lane] or {}
    occupied[lane][note.line]=true
    occupied[lane][off_line]=true
    available[lane]=finish
    if lane>max_columns then max_columns=lane end
    events[#events+1]={
      line=note.line,column=lane,delay=note.delay,
      kind="on",note=note.note,instrument=note.instrument
    }
    events[#events+1]={
      line=off_line,column=lane,delay=finish%256,
      kind="off",note=120,instrument=255
    }
  end
  table.sort(events,function(a,b)
    if a.line~=b.line then return a.line<b.line end
    if a.delay~=b.delay then return a.delay<b.delay end
    return a.column<b.column
  end)
  return events,nil,note_count,note_count,max_columns
end

return M
