-- Per-song event ownership metadata. Stored in renoise.song().tool_data.
-- A strict snapshot of every occupied first-column cell prevents
-- regeneration from deleting modified output or unrelated user notes.
-- This format is internal, versioned and deliberately rejects corruption.
local M = {}
local fields = {
  "note_value", "instrument_value", "volume_value", "panning_value",
  "delay_value", "effect_number_value", "effect_amount_value"
}

function M.capture(cell)
  local values = {}
  for i, field in ipairs(fields) do values[i] = cell[field] end
  return values
end

function M.matches(cell, expected)
  if not expected then return cell.is_empty end
  for i, field in ipairs(fields) do
    if cell[field] ~= expected[i] then return false end
  end
  return true
end

function M.restore(cell, snapshot)
  cell:clear()
  for i, field in ipairs(fields) do cell[field] = snapshot[i] end
end

local function encode_name(s)
  local out = {}
  for i = 1, #s do out[i] = string.format("%02X", s:byte(i)) end
  return table.concat(out)
end
M.encode_name = encode_name

function M.find(records, pattern_index, destination)
  for i, record in ipairs(records) do
    if record.pattern == pattern_index and record.destination == destination then
      return record, i
    end
  end
end

local function positive_number(value)
  local n = tonumber(value)
  if not n or n % 1 ~= 0 or n < 0 or n > 65535 then return nil end
  return n
end

function M.load(data)
  if data == nil or data == "" then return {} end
  if type(data) ~= "string" or data:sub(1,6) ~= "ARP04\n" then
    return nil, "Unrecognized ARP song metadata; no pattern was modified"
  end
  local records = {}
  for line in data:sub(7):gmatch("([^\n]+)") do
    local parts = {}
    for part in (line.."|"):gmatch("(.-)|") do parts[#parts+1] = part end
    if #parts ~= 9 or parts[1] ~= "R" then
      return nil, "Corrupt ARP metadata; no pattern was modified"
    end
    local p, d, s, count = positive_number(parts[2]),
      positive_number(parts[3]), positive_number(parts[4]),
      positive_number(parts[5])
    if not p or p < 1 or not d or d < 1 or not s or s < 1
      or not count or count < 1 or count > 512
      or not parts[6]:match("^[0-9A-F]*$")
      or not parts[7]:match("^[0-9A-F]*$")
      or not parts[8]:match("^[0-9A-F]*$") then
      return nil, "Invalid ARP metadata header"
    end
    local record = {
      pattern=p, destination=d, source=s, length=count,
      pattern_name=parts[6], dest_name=parts[7], source_name=parts[8],
      events={}
    }
    for item in parts[9]:gmatch("[^;]+") do
      local nums = {}
      for part in item:gmatch("[^,]+") do
        nums[#nums+1] = positive_number(part)
      end
      if #nums ~= 8 or not nums[1] or nums[1] < 1 or nums[1] > count
        or record.events[nums[1]] then
        return nil, "Invalid ARP event ownership metadata"
      end
      local snapshot={}
      for i=2,8 do
        if not nums[i] then return nil, "Corrupt ARP event snapshot" end
        snapshot[i-1]=nums[i]
      end
      record.events[nums[1]]=snapshot
    end
    if M.find(records,p,d) then return nil, "Duplicate ARP metadata record" end
    records[#records+1]=record
  end
  return records
end

function M.save(records)
  local output = {"ARP04"}
  for _,r in ipairs(records) do
    local snapshots={}
    for line=1,r.length do
      if r.events[line] then
        local values={line}
        for _,v in ipairs(r.events[line]) do values[#values+1]=v end
        snapshots[#snapshots+1]=table.concat(values,",")
      end
    end
    output[#output+1]=table.concat({
      "R",r.pattern,r.destination,r.source,r.length,
      r.pattern_name,r.dest_name,r.source_name,table.concat(snapshots,";")
    },"|")
  end
  return table.concat(output,"\n").."\n"
end

return M
