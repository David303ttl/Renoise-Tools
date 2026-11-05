-- Intern repeated native empty cells without hashing or dropping inactive data.
local M = {}

function M.canonical_baseline(value)
  local definitions, interned = {}, {}
  local function encode(item)
    if type(item) == "string" then return string.format("%q", item) end
    if type(item) == "number" then return string.format("%.17g", item) end
    if type(item) ~= "table" then return tostring(item) end
    local keys, parts = {}, {}
    for key in pairs(item) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
      if type(a) ~= type(b) then return type(a) < type(b) end
      return a < b
    end)
    for _, key in ipairs(keys) do parts[#parts + 1] = encode(key) .. "=" .. encode(item[key]) end
    local contents = "{" .. table.concat(parts, ",") .. "}"
    if not interned[contents] then
      definitions[#definitions + 1] = contents
      interned[contents] = #definitions
    end
    return "@" .. tostring(interned[contents])
  end
  local root = encode(value)
  return table.concat(definitions, "\n") .. "\n" .. root
end

function M.persisted_baseline(song)
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local instruments = {}
  for instrument_index, instrument in ipairs(song.instruments) do
    local phrases = {}
    for phrase_index, phrase in ipairs(instrument.phrases) do
      local id = ownership.id(phrase)
      local source, policy, pb = nil, nil, nil
      if id then source, policy, pb = store.read_entry(song, id) end
      local snapshot = ownership.snapshot(phrase)
      assert(snapshot, "Persisted baseline requires a complete phrase snapshot")
      phrases[phrase_index] = { id = id, snapshot = snapshot,
        source = source, output_policy = policy, pb_range = pb }
    end
    instruments[instrument_index] = { name = instrument.name, phrases = phrases }
  end
  local raw = song.tool_data or ""
  local hex = raw:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end)
  return M.canonical_baseline({ instruments = instruments, tool_data_hex = hex,
    tool_data_present = song.tool_data ~= nil })
end

return M
