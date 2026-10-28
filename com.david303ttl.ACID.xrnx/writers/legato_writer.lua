-- SPDX-License-Identifier: GPL-3.0-only
-- Emit overlapping native notes for receiver-controlled legato portamento.
local M={}

function M.apply(phrase,plan)
  phrase.visible_note_columns=plan.columns
  phrase.delay_column_visible=true
  phrase.volume_column_visible=true
  for line_index=1,phrase.number_of_lines do
    local line=phrase:line(line_index)
    for column=1,plan.columns do
      local cell=line and line.note_columns[column]
      if not cell then return nil,"Missing legato note column at line "..line_index end
      local expected=plan.cells[line_index] and plan.cells[line_index][column] or {}
      cell.note_value=expected.note_value or 121
      cell.volume_value=expected.volume_value or 255
      cell.delay_value=expected.delay_value or 0
      cell.instrument_value=255
      cell.panning_value=255
      cell.effect_number_value=0
      cell.effect_amount_value=0
    end
  end
  return true
end

return M
