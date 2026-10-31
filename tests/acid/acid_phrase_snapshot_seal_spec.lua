dofile("tests/bootstrap.lua")("acid")
local ownership=require("renoise.phrase_ownership")

local properties={number_of_lines=1,lpb=16,looping=false,loop_start=1,loop_end=1,
  playback_mode=1,key_tracking=1,base_note=48,shuffle=0,autoseek=false,
  visible_note_columns=1,visible_effect_columns=0,instrument_column_visible=true,
  volume_column_visible=true,panning_column_visible=true,delay_column_visible=true,
  sample_effects_column_visible=true}
local note={note_value=48,instrument_value=0,volume_value=0x80,panning_value=0x80,
  delay_value=0,effect_number_value=0,effect_amount_value=0}
local phrase={name="",cells={{note_columns={note},effect_columns={}}}}
for key,value in pairs(properties) do phrase[key]=value end
function phrase:column_is_muted() return false end
function phrase:line(index) return self.cells[index] end

local snapshot={name="",properties=properties,columns={},lines={{notes={note},effects={}}}}
for index=1,12 do snapshot.columns[index]={name="Column "..index,muted=false} end
local expected=assert(ownership.make_name(phrase,37))
local actual=assert(ownership.make_name_from_verified_snapshot(snapshot,37))
assert(actual==expected,"snapshot seal must preserve the existing v3 hash field order")

snapshot.lines[1].notes[1].delay_value=1
local changed=assert(ownership.make_name_from_verified_snapshot(snapshot,37))
assert(changed~=expected,"snapshot seal must include all seven note fields")
assert(not ownership.make_name_from_verified_snapshot(snapshot,0),"invalid phrase IDs must be rejected")
print("ACID snapshot seal matches the live v3 seal algorithm")
