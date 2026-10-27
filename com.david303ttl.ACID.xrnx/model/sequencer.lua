-- ACID pitch/time memory. Drafts can be partially entered.
-- Pitch and time memories have independent contents and 64-slot capacity.
local M = {}
M.MAX_STEPS = 64
M.PAGE_SIZE = 16
M.BASE_NOTE = 36 -- C-3 in Renoise
local SOURCE_FIELDS={length=true,pitch_length=true,pitch_events=true,time_events=true}

local function integer_between(v, a, b)
  return type(v) == "number" and v % 1 == 0 and v >= a and v <= b
end

local function array_size(a)
  if type(a) ~= "table" then return nil end
  local n, max = 0, 0
  for key in pairs(a) do
    if not integer_between(key, 1, M.MAX_STEPS) then return nil end
    n = n + 1
    if key > max then max = key end
  end
  if n ~= max then return nil end
  return n
end

function M.new_pattern(length,...)
  assert(select("#",...)==0,"new_pattern accepts only LAST STEP")
  length = length or 16
  assert(integer_between(length, 1, M.MAX_STEPS), "length must be 1..64")
  -- PITCH and TIME memories are fixed-capacity; LAST STEP selects the active
  -- TIME prefix. Untouched PITCH positions play C with no ACCENT or SLIDE.
  local pitches = {}
  for i=1,M.MAX_STEPS do
    pitches[i] = M.new_pitch(0,0,false,false)
  end
  local time_events = {}
  for i=1,M.MAX_STEPS do time_events[i] = "N" end
  return {length=length, pitch_length=16, pitch_events=pitches,
    time_events=time_events}
end

function M.set_pitch_length(pattern, pitch_length)
  if type(pattern) ~= "table" or
      not integer_between(pitch_length, 1, M.MAX_STEPS) then
    return false, "pitch length must be 1..64"
  end
  pattern.pitch_length = pitch_length
  return true
end

function M.set_time(pattern, step, command)
  if type(pattern) ~= "table" or not integer_between(pattern.length, 1, M.MAX_STEPS)
    or type(pattern.time_events)~="table" then
    return nil, "invalid pattern"
  end
  if not integer_between(step, 1, pattern.length) then
    return nil, "invalid time step"
  end
  if command ~= "N" and command ~= "T" and command ~= "R" then
    return nil, "invalid timing command"
  end
  if step == 1 and command == "T" then command = "N" end
  pattern.time_events[step] = command
  return command
end

-- Original 13-key pitch keyboard, combined with octave DOWN/NORMAL/UP.
function M.new_pitch(key, octave, accent, slide)
  assert(integer_between(key, 0, 12), "keyboard key must be 0..12")
  assert(integer_between(octave, -1, 1), "octave must be -1, 0 or +1")
  assert(accent==nil or type(accent)=="boolean", "accent must be boolean")
  assert(slide==nil or type(slide)=="boolean", "slide must be boolean")
  return {note=M.BASE_NOTE+key+octave*12, key=key, octave=octave,
    accent=accent==true, slide=slide==true}
end

function M.pitch_controls(p)
  if type(p) ~= "table" or not integer_between(p.note, 0, 119) then
    return nil, "invalid pitch"
  end
  if not integer_between(p.key, 0, 12) or
    not integer_between(p.octave, -1, 1) or
    p.note ~= M.BASE_NOTE+p.key+p.octave*12 then
    return nil, "pitch keyboard/octave does not match MIDI note"
  end
  return p.key, p.octave
end

function M.validate(pattern)
  if type(pattern) ~= "table" then return false, "pattern must be a table" end
  for key in pairs(pattern) do
    if not SOURCE_FIELDS[key] then return false,"unknown source field: "..tostring(key) end
  end
  if not integer_between(pattern.length, 1, M.MAX_STEPS) then
    return false, "pattern length must be 1..64"
  end
  if not integer_between(pattern.pitch_length, 1, M.MAX_STEPS) then
    return false, "pitch length must be 1..64"
  end
  if array_size(pattern.pitch_events) ~= M.MAX_STEPS then
    return false, "PITCH memory must contain exactly 64 entries"
  end
  local np, nt = array_size(pattern.pitch_events), array_size(pattern.time_events)
  if np == nil or nt == nil then
    return false, "pitch_events and time_events must be dense arrays (maximum 64 entries)"
  end
  if nt ~= M.MAX_STEPS then
    return false, "TIME memory must contain exactly 64 entries"
  end
  for i, p in ipairs(pattern.pitch_events) do
    if type(p) ~= "table" or not integer_between(p.note, 0, 119) then
      return false, "invalid pitch at entry " .. i
    end
    for key in pairs(p) do
      if key~="note" and key~="key" and key~="octave" and
          key~="accent" and key~="slide" then
        return false,"unknown pitch field at entry "..i..": "..tostring(key)
      end
    end
    local key, octave_or_error = M.pitch_controls(p)
    if key == nil then
      return false, octave_or_error .. " at pitch entry " .. i
    end
    if type(p.accent) ~= "boolean" then
      return false, "accent must be boolean at entry " .. i
    end
    if type(p.slide) ~= "boolean" then
      return false, "slide must be boolean at entry " .. i
    end
  end
  for i, t in ipairs(pattern.time_events) do
    if t ~= "N" and t ~= "T" and t ~= "R" then
      return false, "invalid timing command at step " .. i
    end
  end
  if pattern.time_events[1] == "T" then
    return false, "leading TIE must be entered as NOTE"
  end
  return true
end

function M.describe(pattern)
  local ok, err = M.validate(pattern)
  if not ok then return nil, err end
  return string.format("Draft state: %d time slots, %d active pitch entries, %d stored pitch entries, %d time events",
    pattern.length,
    pattern.pitch_length or #pattern.pitch_events, #pattern.pitch_events,
    #pattern.time_events)
end
return M
