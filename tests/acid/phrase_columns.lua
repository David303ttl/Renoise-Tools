local M={}
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
  return {note_columns=columns,effect_columns={}}
end
function M.copy(destination,source)
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
