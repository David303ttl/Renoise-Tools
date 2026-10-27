-- Place note-column glide effects; sample voice continuity is not guaranteed.
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
      -- Apply Gxx at the target pitch and G00 on the following line.
      commands[#commands+1] = {
        line=target_line, note=event.note, command="0G", amount=rate,
        step=step, time_step=event.source_step or event.step or step,
        cycle=event.cycle, pitch_index=event.pitch_index, kind="glide"
      }
      commands[#commands+1] = {
        line=target_line+1, note=nil, command="0G", amount=0,
        step=step, time_step=event.source_step or event.step or step,
        cycle=event.cycle, pitch_index=event.pitch_index, kind="continuation"
      }
    end
  end
  return commands
end

function M.apply(phrase, plan, lines_per_step, rate, early_release)
  local commands, err = M.plan(plan, lines_per_step, rate)
  if not commands then return nil, err end
  if early_release then
    local active=false
    for step,ev in ipairs(plan.steps) do
      if ev.kind=="note" then
        if active and ev.transition~="slide" then
          commands[#commands+1]={line=(step-1)*lines_per_step,
            new_note=120,kind="release",step=step-1}
        end
        active=true
      elseif ev.kind=="rest" then active=false end
    end
  end
  table.sort(commands,function(a,b)return a.line<b.line end)
  for i=2,#commands do
    if commands[i].line==commands[i-1].line then
      return nil,"gate/glide collision"
    end
  end
  -- Preflight every write. Gate-off has priority over optional G00
  -- continuation: a released voice must not be prolonged for glide.
  local targets = {}
  local skipped = {}
  for _, command in ipairs(commands) do
    local display_line = command.line - 1 -- Renoise line labels are zero-based
    local location = string.format("%sTIME step %02d, phrase line %02X",
      command.cycle and (command.cycle==1 and "Initial cycle, " or "Repeating cycle, ") or "",
      command.time_step or command.step or (math.floor(display_line / lines_per_step) + 1),display_line)
    local line = phrase:line(command.line)
    local cell = line and line.note_columns and line.note_columns[1]
    if not cell then
      return nil, location .. ": missing note column"
    end
    if command.note ~= nil and cell.note_value ~= command.note then
      return nil, string.format("%s: glide target expects note %d; found %s",
        location, command.note, tostring(cell.note_value))
    end
    if command.note == nil and cell.note_value ~= 121 then
      if command.kind == "continuation" and cell.note_value == 120 then
        skipped[#skipped + 1] = {
          step=command.step, line=display_line,
          reason="0G00 omitted because the gate releases here (OFF)"
        }
      else
        return nil, string.format(
          "%s: glide continuation needs an empty note cell; found %s. " ..
          "Check gate releases and adjacent notes.",
          location, tostring(cell.note_value))
      end
    else
      if (cell.effect_number_value or 0) ~= 0
        or (cell.effect_amount_value or 0) ~= 0 then
        return nil, location ..
          ": existing note-column FX would be overwritten by 0Gxx"
      end
      targets[#targets + 1] = {cell=cell, command=command}
    end
  end

  local backups = {}
  for _, entry in ipairs(targets) do
    backups[#backups+1] = {
      cell=entry.cell,
      note=entry.cell.note_value,
      number=entry.cell.effect_number_value,
      amount=entry.cell.effect_amount_value
    }
  end
  local ok, write_error = pcall(function()
    for _, entry in ipairs(targets) do
      if entry.command.kind=="release" then
        entry.cell.note_value=120
      else
        entry.cell.effect_number_string=entry.command.command
        entry.cell.effect_amount_value=entry.command.amount
      end
    end
  end)
  if not ok then
    for _, item in ipairs(backups) do
      pcall(function()
        item.cell.note_value=item.note
        item.cell.effect_number_value = item.number or 0
        item.cell.effect_amount_value = item.amount or 0
      end)
    end
    return nil, "failed to apply glide: " .. tostring(write_error)
  end
  local releases=0
  for _,op in ipairs(commands) do
    if op.kind=="release" then releases=releases+1 end
  end
  return {
    slide_count=(#commands-releases)/2,
    early_releases=releases, commands=#targets, rate=rate,
    skipped_continuations=skipped
  }
end

return M
