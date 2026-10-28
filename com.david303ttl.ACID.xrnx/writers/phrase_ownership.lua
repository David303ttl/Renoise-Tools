-- SPDX-License-Identifier: GPL-3.0-only
-- Content seal for current ACID generated phrases; this is not a security token.
local M={}
local PREFIX="ACID 0.1 #"
local function hash(phrase)
  local acc=5381
  local function feed(value)
    local text=tostring(value==nil and "_" or value)
    for i=1,#text do acc=(acc*33+text:byte(i))%2147483647 end
    acc=(acc*33+124)%2147483647
  end
  feed(phrase.number_of_lines)
  feed(phrase.lpb)
  feed(phrase.looping)
  feed(phrase.loop_start)
  feed(phrase.loop_end)
  feed(phrase.playback_mode)
  feed(phrase.key_tracking)
  feed(phrase.base_note)
  feed(phrase.shuffle)
  feed(phrase.autoseek)
  local notes,effects=phrase.visible_note_columns or 1,phrase.visible_effect_columns or 0
  feed(notes);feed(effects)
  feed(phrase.instrument_column_visible)
  feed(phrase.volume_column_visible)
  feed(phrase.panning_column_visible)
  feed(phrase.delay_column_visible)
  feed(phrase.sample_effects_column_visible)
  for column=1,12 do feed(phrase:column_is_muted(column)) end
  for line_index=1,phrase.number_of_lines do
    local line=phrase:line(line_index)
    if not line then return nil,"missing phrase line "..line_index end
    for column=1,notes do
      local note=line.note_columns and line.note_columns[column]
      if not note then return nil,"missing note column at "..line_index end
      feed(note.note_value);feed(note.instrument_value);feed(note.volume_value)
      feed(note.panning_value);feed(note.delay_value)
      feed(note.effect_number_value);feed(note.effect_amount_value)
    end
    for column=1,effects do
      local effect=line.effect_columns and line.effect_columns[column]
      if not effect then return nil,"missing effect column at "..line_index end
      feed(effect.number_value);feed(effect.amount_value)
    end
  end
  return string.format("%08X",acc)
end

function M.id(phrase)
  local id=(phrase.name or ""):match("^ACID 0%.1 #(%d+) %[v3:(%x%x%x%x%x%x%x%x)%]$")
  if not id then return nil end
  local numeric=tonumber(id)
  return numeric and numeric>=1 and numeric<=2147483647 and numeric or nil
end

function M.make_name(phrase,id)
  if type(id)~="number" or id%1~=0 or id<1 or id>2147483647 then
    return nil,"invalid ACID phrase ID"
  end
  local seal,err=hash(phrase)
  if not seal then return nil,err end
  return string.format("%s%d [v3:%s]",PREFIX,id,seal)
end

function M.status(phrase)
  local name=phrase.name or ""
  local seal=name:match("^ACID 0%.1 #%d+ %[v3:(%x%x%x%x%x%x%x%x)%]$")
  if not seal or not name:match("^ACID 0%.1 #(%d+) ") then return "foreign" end
  local id=tonumber(name:match("^ACID 0%.1 #(%d+) "))
  if not id or id<1 or id>2147483647 then return "foreign" end
  local actual,err=hash(phrase)
  if not actual then return "modified",err end
  if seal~=actual then return "modified","ACID phrase was edited after generation" end
  return "owned"
end

return M
