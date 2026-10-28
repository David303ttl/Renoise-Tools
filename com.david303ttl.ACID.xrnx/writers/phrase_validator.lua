-- SPDX-License-Identifier: GPL-3.0-only
-- Verify phrase note and OFF cells against the semantic event plan.
-- Native Renoise note_value: 0..119 = notes, 120 = OFF, 121 = empty.
local M = {}
local EMPTY, OFF = 121, 120

local function verify_fields(cell,has_note,line,column,delay)
  if (cell.delay_value or 0)~=(delay or 0) or (cell.instrument_value or 255)~=255
    or (cell.panning_value or 255)~=255 then
    return nil,string.format("Unexpected delay, instrument or panning at phrase line 0x%02X column %d",line-1,column)
  end
  local volume=cell.volume_value or 255
  if volume~=255 and (not has_note or type(volume)~="number" or volume<0
    or volume>128 or volume%1~=0) then
    return nil,string.format("Unexpected volume or cut command at phrase line 0x%02X column %d",line-1,column)
  end
  return true
end

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
  local volumes=articulation and articulation.volumes or {}
  local native=articulation and articulation.native_notes
  if native and columns~=native.columns then return nil,"Legato column count mismatch" end
  for step = 1, plan.length do
    local event = plan.steps[step]
    if not event or event.step ~= step then
      return nil, "missing semantic step " .. step
    end
    local expected = EMPTY
    if event.kind == "note" then
      expected = event.note
      if not native then note_count = note_count + 1 end
    elseif event.kind == "rest" then
      if event.releases then
        expected = OFF
        if not native then off_count = off_count + 1 end
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
        local native_cell=native and native.cells[line_number] and native.cells[line_number][column]
        if native then
          wanted=native_cell and native_cell.note_value or EMPTY
          if wanted<OFF then note_count=note_count+1
          elseif wanted==OFF then off_count=off_count+1 end
        end
        if column==1 and release_lines[line_number] then
          if wanted~=EMPTY then
            return nil,string.format("Contradictory release at TIME step %02d, cycle %d, phrase line 0x%02X",
              event.source_step or event.step,event.cycle or 1,line_number-1)
          end
          wanted=OFF
          off_count=off_count+1
        end
        if cell.note_value ~= wanted then
          return nil, string.format(
            "Phrase mismatch at line %02X column %d: expected %d, got %s",
            line_number-1, column, wanted, tostring(cell.note_value))
        end
        local fields_ok,fields_error=verify_fields(cell,wanted<OFF,line_number,column,
          native_cell and native_cell.delay_value)
        if not fields_ok then return nil,fields_error end
        local expected_volume=native and (native_cell and native_cell.volume_value or 255)
          or (volumes[line_number] and volumes[line_number][column])
        if expected_volume and expected_volume~=(cell.volume_value or 255) then
          return nil,string.format("Phrase volume mismatch at line 0x%02X column %d",line_number-1,column)
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
        local fields_ok,fields_error=verify_fields(cell,false,line_number,column)
        if not fields_ok then return nil,fields_error end
        if volumes[line_number] and volumes[line_number][column]~=(cell.volume_value or 255) then
          return nil,string.format("Phrase volume mismatch at line 0x%02X column %d",line_number-1,column)
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
