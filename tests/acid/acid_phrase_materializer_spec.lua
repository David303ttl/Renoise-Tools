dofile("tests/bootstrap.lua")("acid")
renoise={PatternLine={EMPTY_NOTE=121,EMPTY_INSTRUMENT=255,EMPTY_VOLUME=255,
  EMPTY_PANNING=255,EMPTY_DELAY=0,EMPTY_EFFECT_NUMBER=0,EMPTY_EFFECT_AMOUNT=0},
  InstrumentPhrase={MAX_NUMBER_OF_LINES=4,MAX_NUMBER_OF_NOTE_COLUMNS=4,MAX_NUMBER_OF_EFFECT_COLUMNS=2}}

local fixture=dofile("tests/acid/complete_phrase_fixture.lua")
local ownership=require("renoise.phrase_ownership")
local materializer=require("writers.phrase_materializer")
local limits={max_lines=4,max_note_columns=4,max_effect_columns=2}

local function find_upvalue(fn,wanted)
  for index=1,100 do
    local name,value=debug.getupvalue(fn,index)
    if name==nil then break end
    if name==wanted then return value end
  end
end

local write_output=assert(find_upvalue(materializer.apply,"write_output"))
local same_cell=assert(find_upvalue(write_output,"same_cell"))
local note_fields=assert(find_upvalue(same_cell,"note_fields"))
local effect_fields=assert(find_upvalue(write_output,"effect_fields"))
local function reference_same_cell(left,right,fields)
  if type(left)~="table" or type(right)~="table" or left.is_empty~=right.is_empty then return false end
  for _,field in ipairs(fields) do
    if left[field]~=right[field] then return false end
  end
  return true
end
local function cell(fields,is_empty)
  local value={is_empty=is_empty}
  for _,field in ipairs(fields) do value[field]=0 end
  return value
end
local parity_cases=0
local function check_same_cell(left,right,fields)
  parity_cases=parity_cases+1
  assert(same_cell(left,right,fields)==reference_same_cell(left,right,fields),
    "same-cell comparison differs from field-loop semantics at case "..parity_cases)
end
for _,fields in ipairs({note_fields,effect_fields}) do
  local left=cell(fields,true)
  local right=cell(fields,true)
  check_same_cell(nil,right,fields)
  check_same_cell(left,nil,fields)
  check_same_cell(false,right,fields)
  check_same_cell(left,0,fields)
  check_same_cell("invalid",right,fields)
  check_same_cell(left,false,fields)
  check_same_cell(left,right,fields)
  right.is_empty=false
  check_same_cell(left,right,fields)
  right.is_empty=true
  for _,field in ipairs(fields) do
    right[field]=1
    check_same_cell(left,right,fields)
    right[field]=0
  end
end
assert(parity_cases==25,"same-cell parity matrix must contain 25 cases")

local function output()
  local expected={properties={number_of_lines=3,lpb=16,shuffle=0,looping=true,
    loop_start=2,loop_end=3,playback_mode=1,key_tracking=1},lines={},
    empty_note={note_value=121,instrument_value=255,volume_value=255,panning_value=255,
      delay_value=0,effect_number_value=0,effect_amount_value=0,is_empty=true},
    empty_effect={number_value=0,amount_value=0,is_empty=true}}
  for line=1,4 do
    expected.lines[line]={note_columns={},effect_columns={}}
    for column=1,4 do
      local cell={}
      for key,value in pairs(expected.empty_note) do cell[key]=value end
      expected.lines[line].note_columns[column]=cell
    end
    for column=1,2 do
      local cell={}
      for key,value in pairs(expected.empty_effect) do cell[key]=value end
      expected.lines[line].effect_columns[column]=cell
    end
  end
  local note=expected.lines[1].note_columns[1]
  note.note_value=60;note.volume_value=90;note.is_empty=false
  local effect=expected.lines[2].effect_columns[2]
  effect.number_value=257;effect.amount_value=33;effect.is_empty=false
  return expected,{visible_note_columns=1,visible_effect_columns=2,
    instrument_column_visible=false,volume_column_visible=true,panning_column_visible=false,
    delay_column_visible=false,sample_effects_column_visible=false}
end

local function readonly_empty(cell,is_note)
  local values={}
  for key,value in pairs(cell) do values[key]=value end
  return setmetatable({}, {__index=function(_,key)
    if key=="is_empty" then
      if is_note then return values.note_value==121 and values.instrument_value==255 and
        values.volume_value==255 and values.panning_value==255 and values.delay_value==0 and
        values.effect_number_value==0 and values.effect_amount_value==0 end
      return values.number_value==0 and values.amount_value==0
    end
    return values[key]
  end,__newindex=function(_,key,value) values[key]=value end})
end

local function destination()
  local phrase=fixture({max_lines=4,max_note_columns=4,max_effect_columns=2,number_of_lines=4})
  local cell_accesses={notes=0,effects=0}
  phrase.name="source phrase"
  phrase.lpb=8;phrase.looping=true;phrase.loop_start=2;phrase.loop_end=4
  phrase.visible_note_columns=3;phrase.visible_effect_columns=1
  phrase.instrument_column_visible=true
  phrase.mapping={key_tracking=3,base_note=43,note_range={36,47},looping=true,loop_start=2,loop_end=4}
  phrase.script.paragraphs={"return pattern {}"}
  phrase.script.parameters={{name="sentinel",value=23}}
  phrase.script.editor_visible=true
  for _,line in ipairs(phrase.lines) do
    for column,cell in ipairs(line.note_columns) do line.note_columns[column]=readonly_empty(cell,true) end
    for column,cell in ipairs(line.effect_columns) do line.effect_columns[column]=readonly_empty(cell,false) end
    local note_column,effect_column=line.note_column,line.effect_column
    function line:note_column(column)
      cell_accesses.notes=cell_accesses.notes+1
      return note_column(self,column)
    end
    function line:effect_column(column)
      cell_accesses.effects=cell_accesses.effects+1
      return effect_column(self,column)
    end
    setmetatable(line,{__index=function(_,key)
      if key=="is_empty" then
        for _,cell in ipairs(line.note_columns) do if not cell.is_empty then return false end end
        for _,cell in ipairs(line.effect_columns) do if not cell.is_empty then return false end end
        return true
      end
    end})
  end
  phrase.lines[4].note_columns[4].note_value=72
  phrase.lines[4].note_columns[4].is_empty=false
  phrase.cell_accesses=cell_accesses
  return phrase
end

local function track_phrase_property_writes(phrase)
  local keys={"number_of_lines","lpb","shuffle","looping","loop_start","loop_end",
    "playback_mode","key_tracking","visible_note_columns","visible_effect_columns",
    "instrument_column_visible","volume_column_visible","panning_column_visible",
    "delay_column_visible","sample_effects_column_visible"}
  local values,writes={},{}
  for _,key in ipairs(keys) do
    values[key]=phrase[key]
    writes[key]=0
    phrase[key]=nil
  end
  setmetatable(phrase,{__index=function(_,key) return values[key] end,
    __newindex=function(_,key,value)
      writes[key]=writes[key]+1
      values[key]=value
    end})
  return writes
end

local required,visibility=output()
local planning_inputs={sample=true,plugin=false,mode="test"}
local planned_output={expected=required,required_visibility=visibility,
  source={steps={{note=60}}},settings={output_policy="sample",pb_range=12}}
local phrase=destination()
local before=assert(ownership.snapshot(phrase,limits))
local before_index=assert(ownership.snapshot_index(before,limits))
local before_copy=assert(ownership.copy_snapshot(before))
phrase.cell_accesses.notes,phrase.cell_accesses.effects=0,0
local applied,token=materializer.apply(phrase,required,visibility,before,limits,
  planned_output,planning_inputs,before_index)
assert(applied,token)
assert(type(token)=="table" and next(token)==nil,"materializer must return an opaque empty token")
assert(phrase.cell_accesses.notes==14 and phrase.cell_accesses.effects==7,
  "apply accessed unchanged phrase cells: "..phrase.cell_accesses.notes.." note, "..
    phrase.cell_accesses.effects.." effect")
local after=assert(ownership.snapshot(phrase,limits))
assert(ownership.compare(before,before_copy),"apply mutated the caller's preimage snapshot")
assert(after.properties.number_of_lines==3 and after.properties.looping)
assert(after.properties.visible_note_columns==3 and after.properties.visible_effect_columns==2)
assert(after.lines[1].notes[1].note_value==60 and after.lines[2].effects[2].amount_value==33)
assert(after.lines[4].notes[4].note_value==121,"tail cells were not cleared")
assert(after.mapping.note_range[1]==36 and after.mapping.note_range[2]==47)
assert(after.script.paragraphs[1]=="return pattern {}" and after.script.parameters[1].value==23)
assert(after.script.editor_visible==before.script.editor_visible)
assert(before.properties.base_note==after.properties.base_note and before.properties.autoseek==after.properties.autoseek)
assert(before.columns[4].name==after.columns[4].name and before.columns[4].muted==after.columns[4].muted)

local unchanged_geometry,unchanged_visibility=output()
unchanged_geometry.properties.number_of_lines=4
unchanged_geometry.properties.lpb=8
unchanged_geometry.properties.loop_start=2
unchanged_geometry.properties.loop_end=4
unchanged_geometry.lines[2].effect_columns[2].number_value=0
unchanged_geometry.lines[2].effect_columns[2].amount_value=0
unchanged_geometry.lines[2].effect_columns[2].is_empty=true
unchanged_visibility={visible_note_columns=3,visible_effect_columns=1,
  instrument_column_visible=true,volume_column_visible=true,panning_column_visible=false,
  delay_column_visible=false,sample_effects_column_visible=false}
local same_geometry_phrase=destination()
local property_writes=track_phrase_property_writes(same_geometry_phrase)
local same_geometry_before=assert(ownership.snapshot(same_geometry_phrase,limits))
local same_geometry_applied,same_geometry_error=materializer.apply(same_geometry_phrase,
  unchanged_geometry,unchanged_visibility,same_geometry_before,limits)
assert(same_geometry_applied,same_geometry_error)
for key,count in pairs(property_writes) do
  assert(count==0,"same-geometry key edit wrote unchanged phrase property: "..key)
end
local same_geometry_after=assert(ownership.snapshot(same_geometry_phrase,limits))
assert(same_geometry_after.properties.number_of_lines==4 and
  same_geometry_after.properties.loop_start==2 and same_geometry_after.properties.loop_end==4,
  "same-geometry key edit changed phrase geometry")
assert(same_geometry_after.lines[1].notes[1].note_value==60 and
  same_geometry_after.lines[4].notes[4].note_value==121,
  "same-geometry key edit did not update the key and clear the stale tail")

local geometry_limits={max_lines=300,max_note_columns=4,max_effect_columns=2}
local function large_expected(lines,loop_start,loop_end,looping)
  local expected,required_visibility=output()
  expected.properties.number_of_lines=lines
  expected.properties.loop_start=loop_start
  expected.properties.loop_end=loop_end
  expected.properties.looping=looping
  for index=5,geometry_limits.max_lines do
    local notes,effects={},{}
    for column=1,geometry_limits.max_note_columns do
      notes[column]=expected.empty_note
    end
    for column=1,geometry_limits.max_effect_columns do
      effects[column]=expected.empty_effect
    end
    expected.lines[index]={note_columns=notes,effect_columns=effects}
  end
  return expected,required_visibility
end
local function strict_geometry_phrase(lines,loop_start,loop_end,looping)
  local phrase=fixture({max_lines=geometry_limits.max_lines,
    max_note_columns=geometry_limits.max_note_columns,
    max_effect_columns=geometry_limits.max_effect_columns,number_of_lines=lines})
  phrase.loop_start,phrase.loop_end,phrase.looping=loop_start,loop_end,looping
  for _,line in ipairs(phrase.lines) do
    for column,cell in ipairs(line.note_columns) do
      line.note_columns[column]=readonly_empty(cell,true)
    end
    for column,cell in ipairs(line.effect_columns) do
      line.effect_columns[column]=readonly_empty(cell,false)
    end
  end
  local values,writes={},{number_of_lines=0,loop_start=0,loop_end=0,looping=0}
  for key in pairs(writes) do values[key]=phrase[key];phrase[key]=nil end
  setmetatable(phrase,{__index=function(_,key)
      if writes[key] then return values[key] end
      return rawget(phrase,key)
    end,
    __newindex=function(_,key,value)
      if not writes[key] then rawset(phrase,key,value);return end
      writes[key]=writes[key]+1
      values[key]=value
      if key=="number_of_lines" then
        assert(value>=1 and value<=geometry_limits.max_lines,"line count setter out of range")
      end
      assert(values.loop_start>=1 and values.loop_start<=values.number_of_lines and
        values.loop_end>values.loop_start and values.loop_end<=values.number_of_lines,
        "geometry setter exposed an invalid loop range")
    end})
  return phrase,writes
end
local geometry_cases={
  {128,257,20,100,40,210},
  {257,128,40,210,20,100},
  {128,128,30,100,80,120},
  {128,128,80,120,30,100}}
for _,case in ipairs(geometry_cases) do
  local old_lines,new_lines,old_start,old_end,new_start,new_end=unpack(case)
  for _,old_looping in ipairs({false,true}) do
    for _,target_looping in ipairs({false,true}) do
      local strict_phrase,geometry_writes=strict_geometry_phrase(old_lines,
        old_start,old_end,old_looping)
      local geometry_before=assert(ownership.snapshot(strict_phrase,geometry_limits))
      local geometry_expected,geometry_visibility=large_expected(new_lines,new_start,
        new_end,target_looping)
      local geometry_applied,geometry_error=materializer.apply(strict_phrase,
        geometry_expected,geometry_visibility,geometry_before,geometry_limits)
      assert(geometry_applied,geometry_error)
      assert(strict_phrase.number_of_lines==new_lines and
        strict_phrase.loop_start==new_start and strict_phrase.loop_end==new_end and
        strict_phrase.looping==target_looping,"strict geometry target was not applied")
      assert(geometry_writes.loop_start==(old_start~=new_start and 1 or 0) and
        geometry_writes.loop_end==(old_end~=new_end and 1 or 0),
        "geometry writer redundantly toggled a loop endpoint")
      local expected_looping_writes=(old_looping and 1 or 0)+
        (target_looping and 1 or 0)
      assert(geometry_writes.looping==expected_looping_writes,
        "geometry writer redundantly toggled looping")
    end
  end
end
local authorized_name=assert(materializer.name_for_verified_output(token,1))
local rejected_receipt,receipt_error=materializer.consume_verified_output(token,2,
  authorized_name,limits,nil,nil)
assert(not rejected_receipt and receipt_error,"receipt accepted a different phrase ID")
local wrong_limits={max_lines=5,max_note_columns=4,max_effect_columns=2}
rejected_receipt,receipt_error=materializer.consume_verified_output(token,1,
  authorized_name,wrong_limits,nil,nil)
assert(not rejected_receipt and receipt_error,"receipt accepted different phrase capacities")
local receipt,receipt_index,canonical=materializer.consume_verified_output(token,1,authorized_name,
  limits,planned_output,planning_inputs)
assert(receipt and receipt_index,"materializer did not transfer its verified private image")
assert(ownership.compare(after,receipt),"receipt image differs from the verified postimage")
assert(receipt.lines[3].notes[1]==receipt.lines[4].notes[4] and
  receipt.lines[3].effects[1]==receipt.lines[4].effects[2],
  "private postimage did not share canonical empty cells")
assert(after.lines[3].notes[1]~=after.lines[4].notes[4] and
  after.lines[3].effects[1]~=after.lines[4].effects[2],
  "public postimage snapshot shared mutable cells")
local detached_receipt=assert(ownership.copy_snapshot(receipt))
assert(detached_receipt.lines[3].notes[1]~=detached_receipt.lines[4].notes[4] and
  detached_receipt.lines[3].effects[1]~=detached_receipt.lines[4].effects[2],
  "copying a private postimage preserved shared mutable cell aliases")
local postimage_match=ownership.matches_snapshot(phrase,receipt,limits,receipt_index)
assert(postimage_match,"private postimage did not match all native phrase fields")
phrase.lines[4].note_columns[4].delay_value=1
postimage_match=ownership.matches_snapshot(phrase,receipt,limits,receipt_index)
assert(postimage_match==false,"private postimage index missed a hidden tail mutation")
phrase.lines[4].note_columns[4].delay_value=0
assert(ownership.matches_snapshot(phrase,receipt,limits,receipt_index),
  "private postimage stopped matching after exact tail restoration")
assert(ownership.compare(canonical.source,planned_output.source) and
  ownership.compare(canonical.settings,planned_output.settings) and
  ownership.compare(canonical.planning_inputs,planning_inputs) and
  ownership.compare(canonical.required_visibility,visibility),
  "receipt did not retain the canonical planner tuple")
assert(not materializer.consume_verified_output(token,1,authorized_name,limits,nil,nil),
  "materializer receipt was reusable")
local verified,verified_snapshot=materializer.verify(phrase,required,visibility,before,limits)
assert(verified and ownership.compare(after,verified_snapshot))
assert(verified_snapshot.lines[3].notes[1]~=verified_snapshot.lines[4].notes[4] and
  verified_snapshot.lines[3].effects[1]~=verified_snapshot.lines[4].effects[2],
  "public M.verify snapshot shared mutable cells")

local restore_ok,restored=materializer.restore(phrase,before,limits)
assert(restore_ok,restored)
assert(ownership.compare(before,before_copy),"restore mutated the caller's preimage snapshot")
assert(ownership.compare(before,restored),"restore did not recover the complete preimage")
local malformed_restore=assert(ownership.copy_snapshot(before))
malformed_restore.lines[1].notes[1].note_value=nil
local malformed_ok,malformed_error=materializer.restore(phrase,malformed_restore,limits)
assert(not malformed_ok and malformed_error:find("Invalid restore",1,true))
assert(ownership.compare(before,assert(ownership.snapshot(phrase,limits))),
  "malformed restore snapshot changed the destination")

local bad=output()
bad.lines[1].note_columns[1].note_value=nil
local rejected,reason=materializer.apply(destination(),bad,visibility,nil,limits)
assert(not rejected and reason:find("Invalid expected note field",1,true))
local function shared_expected()
  local expected=assert(ownership.copy_snapshot(required))
  expected.lines[4].note_columns[4]=expected.lines[4].note_columns[3]
  expected.lines[4].effect_columns[2]=expected.lines[4].effect_columns[1]
  return expected
end
local malformed_shared=shared_expected()
malformed_shared.lines[4].note_columns[4].note_value=nil
local malformed_destination=destination()
local malformed_before=assert(ownership.snapshot(malformed_destination,limits))
malformed_destination.cell_accesses.notes,malformed_destination.cell_accesses.effects=0,0
local malformed_shared_ok,malformed_shared_error=materializer.apply(malformed_destination,
  malformed_shared,visibility,nil,limits)
assert(not malformed_shared_ok and malformed_shared_error:find("Invalid expected note field",1,true),
  "malformed shared expected cell passed validation")
assert(malformed_destination.cell_accesses.notes==0 and malformed_destination.cell_accesses.effects==0 and
  ownership.compare(malformed_before,assert(ownership.snapshot(malformed_destination,limits))),
  "malformed shared expected cell was rejected after native inspection or writes")

local function shared_expected_row()
  local expected=assert(ownership.copy_snapshot(required))
  expected.lines[4]=expected.lines[3]
  return expected
end
local malformed_shared_row=shared_expected_row()
malformed_shared_row.lines[4].note_columns[1].note_value=nil
local malformed_row_destination=destination()
local malformed_row_before=assert(ownership.snapshot(malformed_row_destination,limits))
malformed_row_destination.cell_accesses.notes,malformed_row_destination.cell_accesses.effects=0,0
local malformed_row_ok,malformed_row_error=materializer.apply(malformed_row_destination,
  malformed_shared_row,visibility,nil,limits)
assert(not malformed_row_ok and malformed_row_error:find("Invalid expected note field: 3/1",1,true),
  "malformed cell in a shared expected row escaped validation")
assert(malformed_row_destination.cell_accesses.notes==0 and malformed_row_destination.cell_accesses.effects==0 and
  ownership.compare(malformed_row_before,assert(ownership.snapshot(malformed_row_destination,limits))),
  "malformed shared expected row was rejected after native inspection or writes")

local malformed_distinct=assert(ownership.copy_snapshot(required))
malformed_distinct.lines[4].note_columns[4].note_value=nil
local distinct_ok,distinct_error=materializer.apply(destination(),malformed_distinct,visibility,nil,limits)
assert(not distinct_ok and distinct_error:find("Invalid expected note field: 4/4",1,true),
  "a malformed distinct public cell escaped full validation")

local metatable_shared=shared_expected()
setmetatable(metatable_shared.lines[4].note_columns[4],{})
local metatable_ok,metatable_error=materializer.apply(destination(),metatable_shared,visibility,nil,limits)
assert(not metatable_ok and metatable_error:find("Invalid expected note cell",1,true),
  "a shared cell with a metatable passed validation")

local saved_empty_note=renoise.PatternLine.EMPTY_NOTE
renoise.PatternLine.EMPTY_NOTE=120
local defaults_mismatch,defaults_error=materializer.apply(destination(),shared_expected(),visibility,nil,limits)
renoise.PatternLine.EMPTY_NOTE=saved_empty_note
assert(not defaults_mismatch and defaults_error:find("Generated note cell differs: 1/2/note_value",1,true),
  "a native empty-cell default mismatch was hidden by canonical-pair reuse")

local original_verification_snapshot=ownership.snapshot_for_verification
ownership.snapshot_for_verification=function(phrase,capacities)
  local actual=assert(original_verification_snapshot(phrase,capacities))
  local original_line=actual.lines[4]
  local corrupted_line={notes={},effects={}}
  for column,cell in ipairs(original_line.notes) do
    local copy={}
    for key,value in pairs(cell) do copy[key]=value end
    corrupted_line.notes[column]=copy
  end
  for column,cell in ipairs(original_line.effects) do
    local copy={}
    for key,value in pairs(cell) do copy[key]=value end
    corrupted_line.effects[column]=copy
  end
  corrupted_line.notes[1].note_value=72
  corrupted_line.notes[1].is_empty=false
  actual.lines[4]=corrupted_line
  return actual
end
local corrupt_call_ok,corrupt_actual_ok,corrupt_actual_error=pcall(function()
  return materializer.apply(destination(),shared_expected(),visibility,nil,limits)
end)
ownership.snapshot_for_verification=original_verification_snapshot
assert(corrupt_call_ok and not corrupt_actual_ok and corrupt_actual_error and
  corrupt_actual_error:find("Generated note cell differs: 4/1/note_value",1,true),
  "a distinct corrupted actual cell was skipped after canonical empty-cell matches")

local shared_for_repeat=shared_expected()
local repeated_destination=destination()
assert(materializer.apply(repeated_destination,shared_for_repeat,visibility,nil,limits),
  "valid shared expected cells were rejected")
local repeated_before=assert(ownership.snapshot(repeated_destination,limits))
shared_for_repeat.lines[4].note_columns[4].volume_value=100
local repeated_ok,repeated_error=materializer.apply(repeated_destination,shared_for_repeat,
  visibility,nil,limits)
assert(not repeated_ok and repeated_error:find("Invalid expected note emptiness",1,true),
  "a shared cell mutation between calls escaped fresh validation")
assert(ownership.compare(repeated_before,assert(ownership.snapshot(repeated_destination,limits))),
  "a shared cell mutated between calls changed native phrase content")

local repeated_shared_row=shared_expected_row()
local repeated_row_destination=destination()
assert(materializer.apply(repeated_row_destination,repeated_shared_row,visibility,nil,limits),
  "valid shared expected rows were rejected")
local repeated_row_before=assert(ownership.snapshot(repeated_row_destination,limits))
repeated_shared_row.lines[4].note_columns[1].volume_value=100
repeated_row_destination.cell_accesses.notes,repeated_row_destination.cell_accesses.effects=0,0
local repeated_row_ok,repeated_row_error=materializer.apply(repeated_row_destination,
  repeated_shared_row,visibility,nil,limits)
assert(not repeated_row_ok and repeated_row_error:find("Invalid expected note emptiness",1,true),
  "a shared expected row mutation between calls escaped fresh validation")
assert(repeated_row_destination.cell_accesses.notes==0 and repeated_row_destination.cell_accesses.effects==0 and
  ownership.compare(repeated_row_before,assert(ownership.snapshot(repeated_row_destination,limits))),
  "a shared expected row mutation changed native phrase content")

local public_verify_phrase=destination()
assert(materializer.apply(public_verify_phrase,required,visibility,nil,limits))
public_verify_phrase.lines[4].note_columns[4].note_value=72
local public_verify_ok,public_verify_error=materializer.verify(public_verify_phrase,
  shared_expected(),visibility,nil,limits)
assert(not public_verify_ok and public_verify_error:find("Generated note cell differs: 4/4/note_value",1,true),
  "public verify skipped its ordinary full comparison for shared expected cells")

local bad_visibility={}
rejected,reason=materializer.apply(destination(),required,bad_visibility,nil,limits)
assert(not rejected and reason:find("Invalid required phrase visibility",1,true))
rejected,reason=materializer.apply(destination(),required,visibility,nil,
  {max_lines=4,max_note_columns=0,max_effect_columns=2})
assert(not rejected and reason=="Invalid phrase materializer capacities")

local function assert_plan_rejected(expected_arg,visibility_arg,plan,label)
  local untouched=destination()
  local original_lines=untouched.number_of_lines
  untouched.cell_accesses.notes,untouched.cell_accesses.effects=0,0
  local accepted,plan_error=materializer.apply(untouched,expected_arg,visibility_arg,nil,
    limits,plan,planning_inputs)
  assert(not accepted and plan_error,label.." was accepted")
  assert(untouched.number_of_lines==original_lines and
    untouched.cell_accesses.notes==0 and untouched.cell_accesses.effects==0,
    label.." inspected or changed the phrase before rejecting its plan")
end

local equal_but_distinct=assert(ownership.copy_snapshot(required))
assert_plan_rejected(equal_but_distinct,visibility,planned_output,"unbound expected table")
local different_expected,different_visibility=output()
local wrong_output={expected=different_expected,required_visibility=visibility,
  source=planned_output.source,settings=planned_output.settings}
assert_plan_rejected(required,visibility,wrong_output,"mismatched expected/plan tuple")
local wrong_visibility={}
for key,value in pairs(visibility) do wrong_visibility[key]=value end
wrong_visibility.volume_column_visible=false
assert_plan_rejected(required,wrong_visibility,planned_output,"mismatched required visibility")

local stale=destination()
local stale_before=assert(ownership.snapshot(stale,limits))
stale.base_note=stale.base_note+1
local stale_name,stale_mapping,stale_script=stale.name,stale.mapping,stale.script
local stale_ok,stale_error,stale_write_attempted=materializer.apply(stale,required,visibility,stale_before,limits)
assert(not stale_ok and stale_error:find("no longer matches its preimage",1,true))
assert(stale_write_attempted==false,"preimage rejection did not prove that no phrase write was attempted")
assert(stale.lines[1].note_columns[1].note_value==121,"stale preimage was partially written")
assert(stale.name==stale_name and stale.mapping==stale_mapping and stale.script==stale_script,
  "stale preimage rejection changed phrase identity metadata")

local invalid_index_phrase=destination()
local invalid_index_before=assert(ownership.snapshot(invalid_index_phrase,limits))
local invalid_index_ok,invalid_index_error=materializer.apply(invalid_index_phrase,required,visibility,
  invalid_index_before,limits,planned_output,planning_inputs,{})
assert(not invalid_index_ok and invalid_index_error:find("no longer matches its preimage",1,true),
  "an invalid supplied preimage index was ignored or rebuilt")
assert(invalid_index_phrase.lines[1].note_columns[1].note_value==121,
  "an invalid supplied preimage index changed the destination")
local orphan_index_ok,orphan_index_error=materializer.apply(destination(),required,visibility,nil,
  limits,planned_output,planning_inputs,{})
assert(not orphan_index_ok and orphan_index_error:find("without a preimage",1,true),
  "an index without its preimage was ignored")

local failing=destination()
local original=failing.lines[1].note_columns[1]
local fail_once=true
local proxy=setmetatable({}, {__index=original,__newindex=function(_,key,value)
  if key=="note_value" and fail_once then fail_once=false;error("injected setter failure") end
  original[key]=value
end})
failing.lines[1].note_columns[1]=proxy
local preimage=assert(ownership.snapshot(failing,limits))
local write_ok,write_error,write_attempted=materializer.apply(failing,required,visibility,preimage,limits)
assert(not write_ok and write_error:find("injected setter failure",1,true))
assert(write_attempted==true,"partial materialization failure did not retain conservative rollback permission")
local rolled_back,rollback=materializer.restore(failing,preimage,limits)
assert(rolled_back,rollback)
assert(ownership.compare(preimage,rollback),"failed write could not be rolled back exactly")

print("ACID phrase materializer checks passed")
