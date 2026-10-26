-- Detect generated phrases and subsequent manual edits.
-- A content seal prevents accidental overwrites; it is not a security token.
local M={}
local PREFIX="ACID 0.1 ["
local LEGACY="ACID 0.1 TEST"
M.LEGACY_NAME=LEGACY

local function hash(phrase)
  local acc=5381
  local function feed(v)
    local s=tostring(v==nil and "_" or v)
    for i=1,#s do acc=(acc*33+s:byte(i))%2147483647 end
    acc=(acc*33+124)%2147483647
  end
  feed(phrase.number_of_lines)
  feed(phrase.lpb)
  feed(phrase.looping)
  feed(phrase.playback_mode)
  feed(phrase.key_tracking)
  feed(phrase.base_note)
  feed(phrase.shuffle)
  feed(phrase.autoseek)
  local notes=phrase.visible_note_columns or 1
  local effects=phrase.visible_effect_columns or 0
  feed(notes)
  feed(effects)
  for i=1,phrase.number_of_lines do
    local line=phrase:line(i)
    if not line then return nil,"missing phrase line "..i end
    for c=1,notes do
      local n=line.note_columns and line.note_columns[c]
      if not n then return nil,"missing note column at "..i end
      feed(n.note_value)
      feed(n.instrument_value)
      feed(n.volume_value)
      feed(n.panning_value)
      feed(n.delay_value)
      feed(n.effect_number_value)
      feed(n.effect_amount_value)
    end
    for c=1,effects do
      local e=line.effect_columns and line.effect_columns[c]
      if not e then return nil,"missing effect column at "..i end
      feed(e.number_value)
      feed(e.amount_value)
    end
  end
  return string.format("%08X",acc)
end

function M.id(phrase)
  local id=(phrase.name or ""):match("^ACID 0%.1 #(%d+) %[%x%x%x%x%x%x%x%x%]$")
  return id and tonumber(id) or nil
end

function M.make_name(phrase,id)
  local seal,err=hash(phrase)
  if not seal then return nil,err end
  if id~=nil then
    assert(type(id)=="number" and id%1==0 and id>=1)
    return string.format("ACID 0.1 #%d [%s]",id,seal)
  end
  return PREFIX..seal.."]"
end

function M.status(phrase)
  local name=phrase.name or ""
  if name==LEGACY then return "legacy" end
  local old=name:match("^ACID 0%.1 %[(%x%x%x%x%x%x%x%x)%]$") or
    name:match("^ACID 0%.1 #%d+ %[(%x%x%x%x%x%x%x%x)%]$")
  if not old then return "foreign" end
  local actual,err=hash(phrase)
  if not actual then return "modified",err end
  if old~=actual then return "modified","ACID phrase was edited after generation" end
  return "owned"
end

return M
