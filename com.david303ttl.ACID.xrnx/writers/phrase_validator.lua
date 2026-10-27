-- Verify phrase note and OFF cells against the semantic event plan.
-- Native Renoise note_value: 0..119 = notes, 120 = OFF, 121 = empty.
local M = {}
local EMPTY, OFF = 121, 120

function M.verify(phrase, plan, lines_per_step, layout, articulation)
  if type(plan) ~= "table" or type(plan.steps) ~= "table"
    or type(plan.length) ~= "number" or plan.length < 1
    or plan.length % 1 ~= 0 then
    return nil, "invalid semantic plan"
  end
  if type(lines_per_step) ~= "number" or lines_per_step < 1
    or lines_per_step % 1 ~= 0 then
    return nil, "invalid lines-per-step"
  end
  local musical_lines = plan.length * lines_per_step
  local expected_lines = layout and layout.number_of_lines or musical_lines
  if type(expected_lines)~="number" or expected_lines<musical_lines or
      phrase.number_of_lines ~= expected_lines then
    return nil, string.format("Expected %d phrase lines, received %s",
      expected_lines or musical_lines, tostring(phrase.number_of_lines))
  end
  if layout then
    if type(layout.looping)~="boolean" then
      return nil,"invalid phrase loop layout"
    end
    if layout.looping then
      if type(layout.loop_start)~="number" or type(layout.loop_end)~="number"
        or layout.loop_start%1~=0 or layout.loop_end%1~=0
        or layout.loop_start<1 or layout.loop_end<=layout.loop_start
        or layout.loop_end>expected_lines then
        return nil,"invalid phrase loop range"
      end
      if expected_lines~=musical_lines+1 or layout.loop_end~=expected_lines
        or plan.length%2~=0 or layout.loop_start~=musical_lines/2+1 then
        return nil,"loop phrase requires one empty exclusive-end sentinel line"
      end
    end
    if phrase.looping~=layout.looping then return nil,"phrase loop enablement mismatch" end
    if phrase.loop_start~=layout.loop_start or phrase.loop_end~=layout.loop_end then
      return nil,"phrase loop endpoints mismatch"
    end
  end

  local note_count, off_count = 0, 0
  local columns = phrase.visible_note_columns or 1
  local release_lines=articulation and articulation.release_lines or {}
  local effects=articulation and articulation.effects or {}
  for step = 1, plan.length do
    local event = plan.steps[step]
    if not event or event.step ~= step then
      return nil, "missing semantic step " .. step
    end
    local expected = EMPTY
    if event.kind == "note" then
      expected = event.note
      note_count = note_count + 1
    elseif event.kind == "rest" then
      if event.releases then
        expected = OFF
        off_count = off_count + 1
      end
    elseif event.kind ~= "tie" then
      return nil, "unsupported semantic kind at step " .. step
    end

    for offset = 1, lines_per_step do
      local line_number = (step - 1) * lines_per_step + offset
      local line = phrase:line(line_number)
      if not line or not line.note_columns then
        return nil, "missing phrase note columns at line " .. (line_number-1)
      end
      for column = 1, columns do
        local cell = line.note_columns[column]
        if not cell then
          return nil, "missing note column at line " .. (line_number-1)
        end
        local wanted = (offset == 1 and column == 1) and expected or EMPTY
        if column==1 and release_lines[line_number] then wanted=OFF end
        if cell.note_value ~= wanted then
          return nil, string.format(
            "Phrase mismatch at line %02X column %d: expected %d, got %s",
            line_number-1, column, wanted, tostring(cell.note_value))
        end
        local effect=effects[line_number]
        if column==1 and effect then
          if cell.effect_number_string~="0G" or cell.effect_amount_value~=effect then
            return nil,"Phrase glide mismatch at line "..string.format("%02X",line_number-1)
          end
        elseif (cell.effect_number_value or 0)~=0 or
            (cell.effect_amount_value or 0)~=0 then
          return nil,"Unexpected note-column effect at line "..string.format("%02X",line_number-1)
        end
      end
    end
    for column=1,(phrase.visible_effect_columns or 0) do
      local line_number=(step-1)*lines_per_step+1
      for offset=0,lines_per_step-1 do
        local line=phrase:line(line_number+offset)
        local cell=line and line.effect_columns and line.effect_columns[column]
        if not cell then return nil,"missing effect column at line "..(line_number+offset-1) end
        if (cell.number_value or 0)~=0 or (cell.amount_value or 0)~=0 then
          return nil,"Unexpected effect-column data at line "..(line_number+offset-1)
        end
      end
    end
  end
  if expected_lines>musical_lines then
    for line_number=musical_lines+1,expected_lines do
      local line=phrase:line(line_number)
      if not line or not line.note_columns then
        return nil,"missing exclusive-end sentinel line "..(line_number-1)
      end
      for column=1,columns do
        local cell=line.note_columns[column]
        if not cell or cell.note_value~=EMPTY or
            (cell.effect_number_value or 0)~=0 or
            (cell.effect_amount_value or 0)~=0 then
          return nil,"exclusive-end sentinel must be empty at line "..(line_number-1)
        end
      end
      for column=1,(phrase.visible_effect_columns or 0) do
        local cell=line.effect_columns and line.effect_columns[column]
        if not cell or (cell.number_value or 0)~=0 or (cell.amount_value or 0)~=0 then
          return nil,"exclusive-end sentinel effect must be empty at line "..(line_number-1)
        end
      end
    end
  end
  return {notes=note_count, offs=off_count, lines=expected_lines}
end

return M
