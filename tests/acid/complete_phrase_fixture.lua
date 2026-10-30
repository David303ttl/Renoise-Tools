-- SPDX-License-Identifier: GPL-3.0-only
-- Complete API-shaped phrase values for snapshot and preservation checks.
-- Optional capacities let focused runtime fixtures advertise small native
-- bounds; omitted capacities retain the full API 6.2 phrase shape.
return function(capacities)
  capacities=capacities or {}
  local max_lines=capacities.max_lines or 512
  local max_note_columns=capacities.max_note_columns or 12
  local max_effect_columns=capacities.max_effect_columns or 8
  local number_of_lines=capacities.number_of_lines or 16
  assert(number_of_lines<=max_lines,"fixture length exceeds advertised line capacity")
  local phrase={name='fixture',number_of_lines=number_of_lines,lpb=8,shuffle=0,looping=false,
    loop_start=1,loop_end=number_of_lines,playback_mode=1,key_tracking=1,base_note=48,autoseek=false,
    visible_note_columns=1,visible_effect_columns=0,instrument_column_visible=false,
    volume_column_visible=true,panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,script={paragraphs={},parameters={},pending_changes=0,editor_visible=true},
    mapping=nil,lines={},column_names={},column_mutes={}}
  for column=1,max_note_columns do phrase.column_names[column]='column '..column;phrase.column_mutes[column]=false end
  function phrase:column_name(column)return self.column_names[column]end
  function phrase:column_is_muted(column)return self.column_mutes[column]end
  function phrase:line(index)return self.lines[index]end
  for index=1,max_lines do
    local line={note_columns={},effect_columns={}}
    function line:note_column(column)return self.note_columns[column]end
    function line:effect_column(column)return self.effect_columns[column]end
    for column=1,max_note_columns do
      line.note_columns[column]={note_value=121,instrument_value=255,volume_value=255,
        panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0,is_empty=true}
    end
    for column=1,max_effect_columns do line.effect_columns[column]={number_value=0,amount_value=0,is_empty=true}end
    phrase.lines[index]=line
  end
  return phrase
end
