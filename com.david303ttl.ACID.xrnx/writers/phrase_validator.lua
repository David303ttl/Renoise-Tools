-- ACID 0.1: verify *musical* phrase contents, not pattrns raw pulse count.
-- Native Renoise note_value: 0..119 = notes, 120 = OFF, 121 = empty.
local M = {}
local EMPTY, OFF = 121, 120

function M.verify(phrase, plan, lines_per_step)
  if type(plan) ~= "table" or type(plan.steps) ~= "table"
    or type(plan.length) ~= "number" or plan.length < 1
    or plan.length % 1 ~= 0 then
    return nil, "invalid semantic plan"
  end
  if type(lines_per_step) ~= "number" or lines_per_step < 1
    or lines_per_step % 1 ~= 0 then
    return nil, "invalid lines-per-step"
  end
  local expected_lines = plan.length * lines_per_step
  if phrase.number_of_lines ~= expected_lines then
    return nil, string.format("Expected %d phrase lines, received %s",
      expected_lines, tostring(phrase.number_of_lines))
  end

  local note_count, off_count = 0, 0
  local columns = phrase.visible_note_columns or 1
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
        if cell.note_value ~= wanted then
          return nil, string.format(
            "Phrase mismatch at line %02X column %d: expected %d, got %s",
            line_number-1, column, wanted, tostring(cell.note_value))
        end
      end
    end
  end
  return {notes=note_count, offs=off_count, lines=expected_lines}
end

return M
