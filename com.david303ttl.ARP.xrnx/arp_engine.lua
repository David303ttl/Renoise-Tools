-- Pure Lua ordering primitive. This is not yet a full arpeggiator.
-- Does not access Renoise or modify song data.
local M = {}

function M.order_notes(input, mode)
  assert(type(input) == "table", "input must be a note array")
  mode = mode or "up"
  assert(mode == "up" or mode == "down" or mode == "up_down",
    "unsupported ordering mode")

  local ascending = {}
  for _, note in ipairs(input) do
    assert(type(note) == "number" and note % 1 == 0
      and note >= 0 and note <= 119, "invalid Renoise note number")
    ascending[#ascending + 1] = note
  end
  table.sort(ascending)

  if mode == "up" then
    return ascending
  end

  local result = {}
  if mode == "down" then
    for i = #ascending, 1, -1 do
      result[#result + 1] = ascending[i]
    end
  else
    for i = 1, #ascending do
      result[#result + 1] = ascending[i]
    end
    -- Reverse through inner notes; endpoints occur only once per cycle.
    for i = #ascending - 1, 2, -1 do
      result[#result + 1] = ascending[i]
    end
  end
  return result
end

return M
