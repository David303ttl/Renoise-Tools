-- SPDX-License-Identifier: GPL-3.0-only
assert(dofile("tests/bootstrap.lua")("superos303"))
local json = dofile("tests/renoise/driver/json.lua")
local protocol = require("protocol")
local C = require("constants")
local action, path = arg[1], arg[2]
local function read(path)
  local file = assert(io.open(path, "rb"))
  local result = json.decode(file:read("*a")); file:close(); return result
end
local function inspect(events)
  local result = {notes = json.array(), errors = json.array()}
  for _, event in ipairs(events) do
    if event.kind == "error" then
      result.errors[#result.errors + 1] = event
    elseif event.kind == "sysex" then
      local decoded, issue = protocol.decode(event.bytes)
      if decoded then
        if decoded.type == "pattern" then result.pattern = decoded
        elseif decoded.type == "config" then result.config = decoded
        elseif decoded.type == "position" or decoded.type == "active" then result.active = decoded
        elseif decoded.type == "group" then result.group = decoded.group end
      elseif event.bytes[C.FRAME_BODY_START] == C.MANUFACTURER_ID then
        result.errors[#result.errors + 1] = issue
      end
    elseif event.kind == "short" then
      local message = event.bytes
      local status = message[1]
      if math.floor(status / 16) == 9 and message[3] > 0 then
        result.notes[#result.notes + 1] = {channel = status % 16 + 1, note = message[2]}
      end
    end
  end
  return result
end
local result
if action == "settings" then
  result = {config = protocol.frame(protocol.request_config())}
elseif action == "inspect" then
  result = inspect(read(path))
elseif action == "request" then
  result = protocol.frame(protocol.request_pattern(tonumber(path), C.VARIATION_CV))
elseif action == "plan" then
  local capture = inspect(read(path))
  local p = assert(capture.pattern, "No verified pattern received")
  local step_index, s
  for i = 0, p.length - 1 do
    local value = protocol.step(p, i)
    if value.time == C.TIME_NOTE then step_index, s = i, value; break end
  end
  assert(s, "Pattern has no NOTE step to test without changing its time stream")
  local TEST_SEMITONE_SHIFT = 5
  local pitch = protocol.pitch((s.semitone + TEST_SEMITONE_SHIFT) % C.MAX_SEMITONE,
    s.octave, s.accent, s.slide)
  result = {original = p, notes = capture.notes, step = step_index, pitch = pitch,
    write = protocol.frame(protocol.write_step(p.pattern, step_index, s.time, pitch)),
    restore = protocol.frame(protocol.write_step(p.pattern, step_index, s.time,
      protocol.pitch(s.semitone, s.octave, s.accent, s.slide)))}
elseif action == "verify" then
  local input = read(path)
  local capture = inspect(input.events)
  local p = assert(capture.pattern, "No hardware readback")
  local step = protocol.step(p, input.plan.step)
  local pitch = protocol.pitch(step.semitone, step.octave, step.accent, step.slide)
  local changed = {}
  for i, value in ipairs(p.raw) do
    if value ~= input.plan.original.raw[i] then changed[#changed + 1] = i end
  end
  local before, added = {}, {}
  for _, note in ipairs(input.plan.notes) do before[note.channel .. ":" .. note.note] = true end
  for _, note in ipairs(capture.notes) do
    local key = note.channel .. ":" .. note.note
    if not before[key] then added[key] = true end
  end
  local new_notes = json.array()
  for note in pairs(added) do new_notes[#new_notes + 1] = note end
  table.sort(new_notes)
  result = {pitch = pitch, changed_bytes = json.array(changed), notes = capture.notes,
    errors = capture.errors, active = capture.active, new_notes = new_notes,
    matches = input.restore and #changed == 0 or (not input.restore and pitch == input.plan.pitch)}
else error("Unknown probe action") end
local function arrays(value)
  if type(value) ~= "table" then return value end
  for key, child in pairs(value) do value[key] = arrays(child) end
  if #value > 0 then return json.array(value) end
  return value
end
print(json.encode(arrays(result)))
