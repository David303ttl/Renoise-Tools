local M={}
local command_fields={panning_string="panning_value",number_string="number_value"}
local command_strings={panning_value="panning_string",number_value="number_string"}
local function command_cell(cell)
  return setmetatable(cell,{
    __index=function(value,key)
      local field=command_strings[key]
      local text=field and rawget(value,field)
      if text then return text:byte(1)*256+text:byte(2) end
    end,
    __newindex=function(value,key,item)
      local numeric=command_fields[key]
      local text=command_strings[key]
      if numeric then rawset(value,numeric,nil)
      elseif text then rawset(value,text,nil) end
      rawset(value,key,item)
    end
  })
end
function M.line(phrase,index)
  if not phrase.cells[index] then return nil end
  phrase.extra_cells=phrase.extra_cells or {}
  local columns=phrase.extra_cells[index] or {}
  phrase.extra_cells[index]=columns
  columns[1]=phrase.cells[index]
  for column=2,12 do
    columns[column]=columns[column] or {note_value=121,instrument_value=255,
      volume_value=255,panning_value=255,delay_value=0,
      effect_number_value=0,effect_amount_value=0}
  end
  for column=1,12 do command_cell(columns[column]) end
  phrase.effect_cells=phrase.effect_cells or {}
  phrase.effect_cells[index]=phrase.effect_cells[index] or {}
  local effects=phrase.effect_cells[index]
  for column=1,8 do
    effects[column]=command_cell(effects[column] or {number_value=0,amount_value=0})
  end
  return {note_columns=columns,effect_columns=effects}
end
function M.copy(destination,source)
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
