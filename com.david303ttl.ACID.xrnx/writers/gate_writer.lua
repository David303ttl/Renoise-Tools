-- Write control-signal gate edges into empty phrase cells; reject collisions.
local control=require("model.control_signals")
local M={}
function M.apply(phrase,timeline)
  local lines,err=control.release_lines(timeline,2)
  if not lines then return nil,err end
  local targets={}
  for _,n in ipairs(lines) do
    local line=phrase:line(n)
    local cell=line and line.note_columns and line.note_columns[1]
    if not cell or cell.note_value~=121 then
      return nil,string.format("gate collision at phrase line %02X",n-1)
    end
    targets[#targets+1]=cell
  end
  local ok,write_error=pcall(function()
    for _,cell in ipairs(targets) do cell.note_value=120 end
  end)
  if not ok then
    for _,cell in ipairs(targets) do pcall(function()cell.note_value=121 end) end
    return nil,"gate write failed: "..tostring(write_error)
  end
  return {early_releases=#targets}
end
return M
