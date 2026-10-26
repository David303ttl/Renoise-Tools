-- Pure Lua ACID pitch/time memory model. No Renoise API dependency.
local M = {}

local function integer_between(value, low, high)
  return type(value) == "number" and value % 1 == 0
    and value >= low and value <= high
end

local function array_size(value)
  if type(value) ~= "table" then return nil end
  local count, max_index = 0, 0
  for key in pairs(value) do
    if not integer_between(key, 1, 16) then return nil end
    count = count + 1
    if key > max_index then max_index = key end
  end
  if count ~= max_index then return nil end
  return count
end

function M.new_pattern(length)
  length = length or 16
  assert(integer_between(length, 1, 16), "length must be 1..16")
  return {
    length = length,
    pitch_events = {},
    time_events = {}
  }
end

-- Drafts may have partially populated memories. A playable pattern requires
-- a complete time stream; that stricter check belongs to the compiler.
function M.validate(pattern)
  if type(pattern) ~= "table" then
    return false, "pattern must be a table"
  end
  if not integer_between(pattern.length, 1, 16) then
    return false, "pattern length must be 1..16"
  end
  local pitch_count = array_size(pattern.pitch_events)
  local time_count = array_size(pattern.time_events)
  if pitch_count == nil or time_count == nil then
    return false, "pitch_events and time_events must be dense arrays (maximum 16 entries)"
  end
  if time_count > pattern.length then
    return false, "time memory exceeds pattern length"
  end
  for i, entry in ipairs(pattern.pitch_events) do
    if type(entry) ~= "table" or not integer_between(entry.note, 0, 119) then
      return false, "invalid pitch at entry " .. i
    end
    if entry.accent ~= nil and type(entry.accent) ~= "boolean" then
      return false, "accent must be boolean at entry " .. i
    end
    if entry.slide ~= nil and type(entry.slide) ~= "boolean" then
      return false, "slide must be boolean at entry " .. i
    end
  end
  for i, entry in ipairs(pattern.time_events) do
    if entry ~= "N" and entry ~= "T" and entry ~= "R" then
      return false, "invalid timing command at step " .. i
    end
  end
  return true
end

function M.describe(pattern)
  local ok, err = M.validate(pattern)
  if not ok then return nil, err end
  return string.format(
    "Draft state: %d time slots, %d pitch entries, %d time events",
    pattern.length, #pattern.pitch_events, #pattern.time_events
  )
end

return M
