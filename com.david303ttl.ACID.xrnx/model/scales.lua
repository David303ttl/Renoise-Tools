-- SPDX-License-Identifier: GPL-3.0-only
-- Root-relative scale definitions and custom text parsing.
local bundled = require("model.scale_data")
local M = {}
M.PITCH_CLASSES = 12
M.MAX_TEXT_BYTES = 256 * 1024
M.MAX_NAME_BYTES = 64
M.MAX_CATEGORY_BYTES = 48
local UTF8_BOM = "\239\187\191"

local function copy_array(source)
  local result = {}
  for i, value in ipairs(source or {}) do result[i] = value end
  return result
end

local function copy_entry(entry)
  return {
    name = entry.name,
    category = entry.category or "Custom",
    intervals = copy_array(entry.intervals),
    aliases = copy_array(entry.aliases)
  }
end

function M.builtin()
  local result = M.merge({}, bundled)
  table.sort(result, function(left, right) return left.name < right.name end)
  return result
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.parse(text)
  if type(text) ~= "string" then return nil, "input must be text" end
  if #text > M.MAX_TEXT_BYTES then return nil, "input exceeds " .. M.MAX_TEXT_BYTES .. " bytes" end
  if text:sub(1, #UTF8_BOM) == UTF8_BOM then text = text:sub(#UTF8_BOM + 1) end
  local result, category, line_number = {}, "Custom", 0
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    line_number = line_number + 1
    local content = trim(line)
    if content ~= "" and (content:sub(1, 1) ~= "#" or content:find("=", 1, true)) then
      if content:sub(1, 1) == "#" then
        return nil, "line " .. line_number .. ": scale name cannot begin with #"
      end
      local section = content:match("^%[([^%]]+)%]$")
      if section then
        section = trim(section)
        if section == "" then return nil, "line " .. line_number .. ": category cannot be empty" end
        if #section > M.MAX_CATEGORY_BYTES then
          return nil, "line " .. line_number .. ": category exceeds " .. M.MAX_CATEGORY_BYTES .. " bytes"
        end
        if section:find("[%c%[%]]") then
          return nil, "line " .. line_number .. ": category contains unsupported characters"
        end
        category = section
      else
        local name, values = content:match("^([^=]+)=(.*)$")
        if not name then return nil, "line " .. line_number .. ": expected Name = intervals" end
        name, values = trim(name), trim(values)
        if name == "" then return nil, "line " .. line_number .. ": scale name cannot be empty" end
        if #name > M.MAX_NAME_BYTES then
          return nil, "line " .. line_number .. ": scale name exceeds " .. M.MAX_NAME_BYTES .. " bytes"
        end
        if name:sub(1, 1) == "#" or name:find("[%c%[%]]") then
          return nil, "line " .. line_number .. ": scale name contains unsupported characters"
        end
        local intervals, seen = {}, {}
        values = values:gsub(",", " ")
        for token in values:gmatch("%S+") do
          if not token:match("^%d+$") then
            return nil, "line " .. line_number .. ": interval must be an integer from 0 to 11"
          end
          local value = tonumber(token)
          if value < 0 or value >= M.PITCH_CLASSES then
            return nil, "line " .. line_number .. ": interval must be from 0 to 11"
          end
          if seen[value] then return nil, "line " .. line_number .. ": duplicate interval " .. value end
          seen[value], intervals[#intervals + 1] = true, value
        end
        if #intervals == 0 then return nil, "line " .. line_number .. ": at least one interval is required" end
        if not seen[0] then return nil, "line " .. line_number .. ": intervals must include root 0" end
        table.sort(intervals)
        result[#result + 1] = {name = name, category = category,
          intervals = intervals, aliases = {}}
      end
    end
  end
  return result
end

local function membership_key(entry)
  local values, seen = {}, {}
  for _, interval in ipairs(entry.intervals or {}) do
    if type(interval) == "number" and interval % 1 == 0 and interval >= 0 and interval < M.PITCH_CLASSES then
      seen[interval] = true
    end
  end
  for interval = 0, M.PITCH_CLASSES - 1 do
    if seen[interval] then values[#values + 1] = tostring(interval) end
  end
  return table.concat(values, ",")
end

function M.merge(existing, incoming)
  local result, by_key = {}, {}
  local function add(entry)
    local key = membership_key(entry)
    if key == "" then return end
    local current = by_key[key]
    if not current then
      current = copy_entry(entry)
      by_key[key], result[#result + 1] = current, current
      return
    end
    local names = {entry.name}
    for _, alias in ipairs(entry.aliases or {}) do names[#names + 1] = alias end
    for _, name in ipairs(names) do
      if type(name) == "string" and name ~= "" and name ~= current.name then
        local found = false
        for _, alias in ipairs(current.aliases) do
          if alias == name then found = true; break end
        end
        if not found then current.aliases[#current.aliases + 1] = name end
      end
    end
  end
  for _, entry in ipairs(existing or {}) do add(entry) end
  for _, entry in ipairs(incoming or {}) do add(entry) end
  return result
end

function M.mask(entry, root)
  assert(type(root) == "number" and root % 1 == 0 and root >= 0 and root < M.PITCH_CLASSES,
    "root must be an integer from 0 to 11")
  local allowed, result = {}, {}
  for _, interval in ipairs(entry.intervals or {}) do
    assert(type(interval) == "number" and interval % 1 == 0 and interval >= 0 and interval < M.PITCH_CLASSES,
      "scale intervals must be integers from 0 to 11")
    allowed[interval] = true
  end
  for pitch = 0, M.PITCH_CLASSES - 1 do
    result[pitch + 1] = allowed[(pitch - root) % M.PITCH_CLASSES] == true
  end
  return result
end

function M.encode(entries)
  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = "[" .. entry.category .. "]"
    local intervals = table.concat(entry.intervals, " ")
    lines[#lines + 1] = entry.name .. " = " .. intervals
    for _, alias in ipairs(entry.aliases or {}) do
      lines[#lines + 1] = alias .. " = " .. intervals
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

return M

