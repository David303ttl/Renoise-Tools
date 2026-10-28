-- SPDX-License-Identifier: GPL-3.0-only
-- Merge gate and glide operations before touching native phrase cells.
local control=require("model.control_signals")
local M={}
local function location(op)
  return string.format("TIME step %02d, cycle %d, phrase line 0x%02X",
    op.time_step or op.step or 1,op.cycle or 1,op.line-1)
end
M.location=location

function M.plan(timeline,semantic,commands)
  local lines,err=control.release_lines(timeline,2)
  if not lines then
    local edge
    for _,event in ipairs(timeline.events or {}) do
      if event.kind=="gate_off" and event.reason~="rest" then edge=event;break end
    end
    return nil,location({line=edge and math.floor(edge.at/128)+1 or 1,
      time_step=edge and edge.step,cycle=edge and edge.cycle})..": "..err
  end
  local merged={operations={},release_lines={},effects={}}
  local occupied={}
  local function append(op)
    local event=semantic and semantic.steps[math.floor((op.line-1)/2)+1]
    op.time_step=op.time_step or (event and (event.source_step or event.step))
    op.cycle=op.cycle or (event and event.cycle) or 1
    if op.line<1 or op.line%1~=0 or op.line>timeline.steps*2 then
      return nil,location(op)..": operation outside musical phrase lines"
    end
    if op.kind=="release" and event and op.line%2==1
      and (event.kind=="note" or (event.kind=="rest" and event.releases)) then
      return nil,location(op)..": OFF conflicts with semantic note or release"
    end
    if occupied[op.line] then
      return nil,location(op)..": contradictory gate/glide operations; required command cannot be omitted"
    end
    occupied[op.line]=true
    merged.operations[#merged.operations+1]=op
    return true
  end
  for _,line in ipairs(lines) do
    local ok,why=append({line=line,kind="release"})
    if not ok then return nil,why end
    merged.release_lines[line]=true
  end
  for _,command in ipairs(commands or {}) do
    local op={}
    for key,value in pairs(command) do op[key]=value end
    local ok,why=append(op)
    if not ok then return nil,why end
    merged.effects[op.line]=op.amount
  end
  return merged
end

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

function M.apply(phrase,timeline)
  local merged,err=M.plan(timeline,timeline.semantic)
  if not merged then return nil,err end
  return M.apply_plan(phrase,merged)
end
return M
