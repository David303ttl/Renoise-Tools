-- Pure Lua ACID state-model scaffold.
-- Separate pitch and timing domains are intentional. This does not yet
-- implement original acid-style timing, rests, ties, slide or accent semantics.
local M = {}

function M.new_pattern(length)
  length = length or 16
  assert(type(length) == "number" and length % 1 == 0
    and length >= 1 and length <= 16, "length must be 1..16")
  return {
    length = length,
    pitch_events = {},
    time_events = {}
  }
end

function M.validate(pattern)
  if type(pattern) ~= "table" then
    return false, "pattern must be a table"
  end
  local n = pattern.length
  if type(n) ~= "number" or n % 1 ~= 0 or n < 1 or n > 16 then
    return false, "pattern length must be 1..16"
  end
  if type(pattern.pitch_events) ~= "table"
    or type(pattern.time_events) ~= "table" then
    return false, "pitch_events and time_events must be tables"
  end
  return true
end

function M.describe(pattern)
  local ok, err = M.validate(pattern)
  if not ok then
    return nil, err
  end
  return string.format(
    "Draft state: %d time slots, %d pitch entries, %d time events",
    pattern.length, #pattern.pitch_events, #pattern.time_events
  )
end

return M
