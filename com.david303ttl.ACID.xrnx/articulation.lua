-- ACID 0.1: native sample glide placement experiment.
-- This deliberately tests Renoise's 0Gxx command; it is NOT an
-- accuracy-calibrated acid slide renderer (TPL, gate and loops unresolved).
local M = {}

function M.plan(plan, lines_per_step, rate)
  if type(plan) ~= "table" or type(plan.steps) ~= "table"
    or type(plan.length) ~= "number" or plan.length % 1 ~= 0
    or type(lines_per_step) ~= "number" or lines_per_step % 1 ~= 0
    or lines_per_step < 2 then
    return nil, "invalid glide plan or step resolution"
  end
  rate = rate or 0x02
  if type(rate) ~= "number" or rate % 1 ~= 0
    or rate < 1 or rate > 254 then
    return nil, "glide rate must be 01..FE"
  end
  local commands = {}
  for step=1,plan.length do
    local event = plan.steps[step]
    if not event or event.step ~= step then
      return nil, "missing semantic step " .. step
    end
    if event.kind == "note" and event.transition == "slide" then
      if type(event.from_note) ~= "number"
        or type(event.note) ~= "number" then
        return nil, "slide requires explicit source and target"
      end
      local target_line = (step-1) * lines_per_step + 1
      -- Apply Gxx at target pitch, repeat using G00 on the next line.
      -- This only proves local effect placement; subsequent lines and TPL
      -- need real Renoise experimentation before production integration.
      commands[#commands+1] = {
        line=target_line, note=event.note, command="0G", amount=rate
      }
      commands[#commands+1] = {
        line=target_line+1, note=nil, command="0G", amount=0
      }
    end
  end
  return commands
end

function M.apply(phrase, plan, lines_per_step, rate)
  local commands, err = M.plan(plan, lines_per_step, rate)
  if not commands then return nil, err end
  -- Preflight all destinations before modifying anything.
  local targets = {}
  for _, command in ipairs(commands) do
    local line = phrase:line(command.line)
    local cell = line and line.note_columns and line.note_columns[1]
    if not cell then
      return nil, "missing local effect column at line " .. command.line-1
    end
    if command.note ~= nil and cell.note_value ~= command.note then
      return nil, "glide target pitch mismatch at line " .. command.line-1
    end
    if command.note == nil and cell.note_value ~= 121 then
      return nil, "glide continuation must have empty note cell"
    end
    if cell.effect_number_value and cell.effect_number_value ~= 0 then
      return nil, "glide would overwrite existing local effect"
    end
    targets[#targets+1] = {cell=cell, command=command}
  end

  local backups = {}
  for _, entry in ipairs(targets) do
    backups[#backups+1] = {
      cell=entry.cell,
      number=entry.cell.effect_number_value,
      amount=entry.cell.effect_amount_value
    }
  end
  local ok, write_error = pcall(function()
    for _, entry in ipairs(targets) do
      entry.cell.effect_number_string = entry.command.command
      entry.cell.effect_amount_value = entry.command.amount
    end
  end)
  if not ok then
    for _, item in ipairs(backups) do
      pcall(function()
        item.cell.effect_number_value = item.number or 0
        item.cell.effect_amount_value = item.amount or 0
      end)
    end
    return nil, "failed to apply glide: " .. tostring(write_error)
  end
  return {slide_count=#commands/2, commands=#commands, rate=rate}
end

return M
