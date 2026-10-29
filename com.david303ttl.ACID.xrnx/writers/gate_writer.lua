-- SPDX-License-Identifier: GPL-3.0-only
-- Merge gate and glide operations before touching native phrase cells.
local M={}
local planner=require("model.output_planner")
local location=planner.location
M.location=location
M.plan=planner.plan_gates

function M.apply_plan(phrase,merged)
  local targets={}
  for _,op in ipairs(merged.operations) do
    local line=phrase:line(op.line)
    local cell=line and line.note_columns and line.note_columns[1]
    local expected=op.note or 121
    if not cell or cell.note_value~=expected then
      return nil,location(op)..": missing or occupied note cell"
    end
    if (cell.delay_value or 0)~=0 or (cell.effect_number_value or 0)~=0
      or (cell.effect_amount_value or 0)~=0 or (cell.instrument_value or 255)~=255
      or (cell.panning_value or 255)~=255
      or ((cell.volume_value or 255)~=255 and
        (op.kind=="release" or cell.volume_value<0 or cell.volume_value>128)) then
      return nil,location(op)..": occupied delay, instrument, volume, panning or effect field"
    end
    targets[#targets+1]={cell=cell,op=op,note=cell.note_value,
      number=cell.effect_number_value or 0,amount=cell.effect_amount_value or 0}
  end
  local ok,write_error=pcall(function()
    for _,target in ipairs(targets) do
      if target.op.kind=="release" then target.cell.note_value=120
      else
        target.cell.effect_number_string=target.op.command
        target.cell.effect_amount_value=target.op.amount
      end
    end
  end)
  if not ok then
    local restored=true
    for _,target in ipairs(targets) do
      local reverted=pcall(function()
        target.cell.note_value=target.note
        target.cell.effect_number_value=target.number
        target.cell.effect_amount_value=target.amount
      end)
      if not reverted then restored=false end
    end
    return nil,"articulation write failed: "..tostring(write_error)..
      (restored and " (cell writes rolled back)" or " (cell rollback failed)")
  end
  local lines={}
  for line in pairs(merged.release_lines) do lines[#lines+1]=line end
  table.sort(lines)
  return {early_releases=#lines,release_lines=lines}
end

function M.apply(phrase,timeline,lines_per_step)
  local merged,err=M.plan(timeline,timeline.semantic,nil,lines_per_step)
  if not merged then return nil,err end
  return M.apply_plan(phrase,merged)
end
return M
