local M={}
local command_fields={panning_string="panning_value",number_string="number_value",
  effect_number_string="effect_number_value"}
local command_strings={panning_value="panning_string",number_value="number_string",
  effect_number_value="effect_number_string"}
local digits="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local function base36(text)
  if type(text)~="string" or #text<2 then return nil end
  local high=digits:find(text:sub(1,1),1,true)
  local low=digits:find(text:sub(2,2),1,true)
  if not high or not low then return nil end
  return (high-1)*256+(low-1)
end
local command_cell_metatable={
  __index=function(value,key)
    local field=command_strings[key]
    local text=field and rawget(value,field)
    if text then return base36(text) end
  end,
  __newindex=function(value,key,item)
    local numeric=command_fields[key]
    local text=command_strings[key]
    if numeric then rawset(value,numeric,nil)
    elseif text then rawset(value,text,nil) end
    rawset(value,key,item)
  end
}
local function command_cell(cell)
  return setmetatable(cell,command_cell_metatable)
end
local function note_empty(cell)
  return (cell.note_value==121 or cell.note_value==nil) and
    (cell.instrument_value or 255)==255 and (cell.volume_value or 255)==255 and
    (cell.panning_value or 255)==255 and (cell.delay_value or 0)==0 and
    (cell.effect_number_value or 0)==0 and (cell.effect_amount_value or 0)==0
end
local function effect_empty(cell)
  return (cell.number_value or 0)==0 and (cell.amount_value or 0)==0
end
function M.line(phrase,index)
  if not phrase.cells[index] then return nil end
  phrase._line_cache=phrase._line_cache or {}
  local cached=phrase._line_cache[index]
  if not cached then
    phrase.extra_cells=phrase.extra_cells or {}
    local note_columns=phrase.extra_cells[index] or {}
    phrase.extra_cells[index]=note_columns
    note_columns[1]=phrase.cells[index]
    for column=2,12 do
      note_columns[column]=note_columns[column] or {note_value=121,instrument_value=255,
        volume_value=255,panning_value=255,delay_value=0,
        effect_number_value=0,effect_amount_value=0}
    end
    for column=1,12 do command_cell(note_columns[column]) end
    phrase.effect_cells=phrase.effect_cells or {}
    phrase.effect_cells[index]=phrase.effect_cells[index] or {}
    local effect_columns=phrase.effect_cells[index]
    for column=1,8 do
      effect_columns[column]=command_cell(effect_columns[column] or {number_value=0,amount_value=0})
    end
    local line={note_columns=note_columns,effect_columns=effect_columns}
    function line:note_column(column) return self.note_columns[column] end
    function line:effect_column(column) return self.effect_columns[column] end
    phrase._line_cache[index]=line
    cached=line
  end
  cached.note_columns[1]=phrase.cells[index]
  for column=1,12 do
    cached.note_columns[column].is_empty=note_empty(cached.note_columns[column])
  end
  for column=1,8 do
    cached.effect_columns[column].is_empty=effect_empty(cached.effect_columns[column])
  end
  return cached
end
function M.copy(destination,source)
  destination._line_cache=nil
  destination.effect_cells={}
  for index,effects in pairs(source.effect_cells or {}) do
    destination.effect_cells[index]={}
    for column,original in pairs(effects) do
      local cell={}
      for key,value in pairs(original) do cell[key]=value end
      destination.effect_cells[index][column]=command_cell(cell)
    end
  end
  destination.extra_cells={}
  for index,columns in pairs(source.extra_cells or {}) do
    destination.extra_cells[index]={}
    for column=2,12 do
      local cell={}
      for key,value in pairs(columns[column] or {}) do cell[key]=value end
      destination.extra_cells[index][column]=cell
    end
  end
end
return M
