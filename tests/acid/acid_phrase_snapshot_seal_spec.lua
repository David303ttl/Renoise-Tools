dofile("tests/bootstrap.lua")("acid")
local ownership=require("renoise.phrase_ownership")
local limits={max_lines=1,max_note_columns=1,max_effect_columns=0,number_of_lines=1}
local make_phrase_fixture=dofile("tests/acid/complete_phrase_fixture.lua")
local phrase=make_phrase_fixture(limits)
local note=phrase.lines[1].note_columns[1]
note.note_value=48
note.instrument_value=0
note.volume_value=0x80
note.panning_value=0x80
note.is_empty=false
local snapshot=assert(ownership.snapshot(phrase,limits))
local seal_columns={}
for column=1,12 do seal_columns[column]=phrase:column_is_muted(column) end
local expected=assert(ownership.make_name_from_verified_snapshot(snapshot,37,seal_columns))
phrase.name=expected
assert(ownership.status(phrase)=="owned","snapshot seal must match the live v3 seal algorithm")
local actual=assert(ownership.make_name_from_verified_snapshot(assert(ownership.copy_snapshot(snapshot)),37,seal_columns))
assert(actual==expected,"snapshot seal must preserve the existing v3 hash field order")

local changed_snapshot=assert(ownership.copy_snapshot(snapshot))
changed_snapshot.lines[1].notes[1].delay_value=1
local changed=assert(ownership.make_name_from_verified_snapshot(changed_snapshot,37,seal_columns))
assert(changed~=expected,"snapshot seal must include all seven note fields")
assert(not ownership.make_name_from_verified_snapshot(snapshot,0,seal_columns),"invalid phrase IDs must be rejected")
print("ACID snapshot seal matches the live v3 seal algorithm")
