-- SPDX-License-Identifier: GPL-3.0-only
-- Complete API-shaped phrase values for snapshot and preservation checks.
return function()
  local phrase={name='fixture',number_of_lines=16,lpb=8,shuffle=0,looping=false,
    loop_start=1,loop_end=16,playback_mode=1,key_tracking=1,base_note=48,autoseek=false,
    visible_note_columns=1,visible_effect_columns=0,instrument_column_visible=false,
    volume_column_visible=true,panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,script={paragraphs={},parameters={},pending_changes=0,editor_visible=true},
    mapping=nil,lines={},column_names={},column_mutes={}}
  for column=1,12 do phrase.column_names[column]='column '..column;phrase.column_mutes[column]=false end
  function phrase:column_name(column)return self.column_names[column]end
  function phrase:column_is_muted(column)return self.column_mutes[column]end
  function phrase:line(index)return self.lines[index]end
  for index=1,512 do
    local line={note_columns={},effect_columns={}}
    function line:note_column(column)return self.note_columns[column]end
    function line:effect_column(column)return self.effect_columns[column]end
    for column=1,12 do
      line.note_columns[column]={note_value=121,instrument_value=255,volume_value=255,
        panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0,is_empty=true}
    end
    for column=1,8 do line.effect_columns[column]={number_value=0,amount_value=0,is_empty=true}end
    phrase.lines[index]=line
  end
  return phrase
end
