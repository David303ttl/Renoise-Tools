dofile("tests/bootstrap.lua")("acid")

renoise={}
renoise.PatternLine={EMPTY_NOTE=121,EMPTY_INSTRUMENT=255,EMPTY_VOLUME=255,
  EMPTY_PANNING=255,EMPTY_DELAY=0,EMPTY_EFFECT_NUMBER=0,EMPTY_EFFECT_AMOUNT=0}
renoise.InstrumentPhrase={MAX_NUMBER_OF_LINES=2,MAX_NUMBER_OF_NOTE_COLUMNS=3,
  MAX_NUMBER_OF_EFFECT_COLUMNS=2}
assert(renoise.PatternLine.EMPTY_NOTE==121 and renoise.PatternLine.EMPTY_EFFECT_NUMBER==0)

local note_reads,effect_reads=0,0
local fail_hidden_note_access=false
local function cell(fields,kind)
  return setmetatable({}, {__index=function(_,key)
    if key=="is_empty" then return fields.is_empty end
    if kind=="note" and fail_hidden_note_access and key=="panning_value" then
      error("injected native cell read failure")
    end
    if fields[key]~=nil then
      if kind=="note" then note_reads=note_reads+1 else effect_reads=effect_reads+1 end
      return fields[key]
    end
  end})
end

local hidden_note_values={is_empty=false,note_value=64,instrument_value=17,volume_value=91,
  panning_value=42,delay_value=12,effect_number_value=5,effect_amount_value=19}
local hidden_note=cell(hidden_note_values,"note")
local hidden_effect=cell({is_empty=false,number_value=257,amount_value=88},"effect")
local empty_note={is_empty=true}
local empty_effect={is_empty=true}
local line_one={is_empty=false}
function line_one:note_column(index)
  return index==3 and hidden_note or empty_note
end
function line_one:effect_column(index)
  return index==2 and hidden_effect or empty_effect
end
local line_two={is_empty=true}
function line_two:note_column() error("empty line should not enumerate note cells") end
function line_two:effect_column() error("empty line should not enumerate effect cells") end

local phrase={name="snapshot",number_of_lines=1,lpb=16,shuffle=0,looping=false,
  loop_start=1,loop_end=1,playback_mode=1,key_tracking=1,base_note=48,autoseek=false,
  visible_note_columns=1,visible_effect_columns=0,instrument_column_visible=false,
  volume_column_visible=false,panning_column_visible=false,delay_column_visible=false,
  sample_effects_column_visible=false,mapping=nil,
  script={pending_changes=0,editor_visible=false,paragraphs={},parameters={}}}
function phrase:column_name(index) return "note "..index end
function phrase:column_is_muted() return false end
function phrase:line(index) return index==1 and line_one or line_two end

local ownership=require("renoise.phrase_ownership")
local snapshot=assert(ownership.snapshot(phrase,{max_lines=2,max_note_columns=3,max_effect_columns=2}))
assert(#snapshot.lines==2 and #snapshot.lines[1].notes==3 and #snapshot.lines[1].effects==2)
assert(snapshot.lines[2].notes[3].note_value==121 and snapshot.lines[2].notes[3].is_empty)
assert(snapshot.lines[2].effects[2].number_value==0 and snapshot.lines[2].effects[2].is_empty)
assert(snapshot.lines[1].notes[3].note_value==64 and snapshot.lines[1].notes[3].instrument_value==17
  and snapshot.lines[1].notes[3].delay_value==12 and snapshot.lines[1].notes[3].effect_amount_value==19)
assert(snapshot.lines[1].effects[2].number_value==257 and snapshot.lines[1].effects[2].amount_value==88)
assert(note_reads==7 and effect_reads==2,
  "empty hidden columns read cell fields: "..note_reads.." note, "..effect_reads.." effect")

local limits={max_lines=2,max_note_columns=3,max_effect_columns=2}
local private_snapshot=assert(ownership.snapshot_for_verification(phrase,limits))
assert(private_snapshot.lines[2].notes[1]==private_snapshot.lines[2].notes[3] and
  private_snapshot.lines[2].effects[1]==private_snapshot.lines[2].effects[2],
  "private verification snapshot did not share canonical empty cells")
assert(snapshot.lines[2].notes[1]~=snapshot.lines[2].notes[3] and
  snapshot.lines[2].effects[1]~=snapshot.lines[2].effects[2],
  "public snapshot shared mutable empty cells")

local hostile=assert(ownership.copy_snapshot(snapshot))
local protected_cell=hostile.lines[1].notes[1]
local protected_value=protected_cell.note_value
local callback_ran=false
setmetatable(hostile.lines[1].notes,{__index=function()
  callback_ran=true
  protected_cell.note_value=protected_value+1
end})
local hostile_index,hostile_error=ownership.snapshot_index(hostile,limits)
assert(not hostile_index and hostile_error and not callback_ran and
  protected_cell.note_value==protected_value,
  "snapshot indexing allowed a metatable callback to alter an already visited cell")

local index=assert(ownership.snapshot_index(snapshot,limits))
index.empty_lines={[1]=true,[2]=true}
index.empty_notes={[1]={[1]=true,[2]=true,[3]=true}}
index.empty_effects={[1]={[1]=true,[2]=true}}
note_reads,effect_reads=0,0
assert(ownership.matches_snapshot(phrase,snapshot,limits,index))
assert(note_reads==7 and effect_reads==2,
  "native exact match did not skip canonical empty cells")
local reduced_limits={max_lines=2,max_note_columns=2,max_effect_columns=2}
local capacity_match=ownership.matches_snapshot(phrase,snapshot,reduced_limits,index)
assert(capacity_match==false,"native matching must reject capacity changes")
hidden_note_values.panning_value=43
local native_match=ownership.matches_snapshot(phrase,snapshot,limits,index)
assert(native_match==false,"native exact match missed hidden note data")
hidden_note_values.panning_value=42
fail_hidden_note_access=true
local unreadable_match,unreadable_error=ownership.matches_snapshot(phrase,snapshot,limits,index)
assert(unreadable_match==nil and unreadable_error=="Cannot compare native phrase to its verified snapshot",
  "native getter failures must remain contained by the snapshot comparison boundary: "..
    tostring(unreadable_match).." / "..tostring(unreadable_error))
fail_hidden_note_access=false
hidden_note_values.panning_value=math.huge
local malformed_match,malformed_error=ownership.matches_snapshot(phrase,snapshot,limits,index)
assert(malformed_match==nil and malformed_error=="Cannot compare native phrase to its verified snapshot",
  "non-finite native cell values must remain unavailable")
hidden_note_values.panning_value=42
local expected_note=snapshot.lines[1].notes[3]
expected_note.panning_value=math.huge
native_match=ownership.matches_snapshot(phrase,snapshot,limits,index)
assert(native_match==false,"non-finite expected cell values must not match")
expected_note.panning_value=42
local hidden_line={is_empty=false}
function hidden_line:note_column(column)
  if column==1 then return cell({is_empty=false,note_value=60,instrument_value=255,
    volume_value=255,panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0},"note") end
  return empty_note
end
function hidden_line:effect_column() return empty_effect end
local original_line=phrase.line
function phrase:line(index) return index==2 and hidden_line or original_line(self,index) end
native_match=ownership.matches_snapshot(phrase,snapshot,limits,index)
assert(native_match==false,"native exact match missed data in an inactive line")
phrase.line=original_line

local recovery=assert(ownership.capture_recovery(phrase,limits))
assert(type(recovery)=="table" and next(recovery)==nil,
  "recovery capture exposed its image through the token")
assert(ownership.matches_recovery(phrase,recovery,"exact",limits),
  "fresh recovery capture did not match the native phrase")
assert(not ownership.recovery_matches_snapshot({},snapshot,"exact"),
  "forged recovery token was accepted")
recovery.extra=true
assert(not ownership.matches_recovery(phrase,recovery,"exact",limits),
  "mutated recovery token was accepted")
recovery.extra=nil
assert(ownership.matches_recovery(phrase,recovery,"exact",limits),
  "restored recovery token could not be used")

local public=assert(ownership.snapshot(phrase,limits))
assert(public.lines[2].notes[1]~=public.lines[2].notes[2] and
  public.lines[2].effects[1]~=public.lines[2].effects[2],
  "public snapshot cells unexpectedly share mutable tables")
public.lines[2].notes[1].note_value=120
assert(not ownership.recovery_matches_snapshot(recovery,public,"exact"),
  "mutated public snapshot matched the recovery image")
public.lines[2].notes[1].note_value=121
assert(ownership.recovery_matches_snapshot(recovery,public,"exact"),
  "public snapshot mutation altered the private recovery image")

local saved_name=phrase.name
phrase.name=saved_name.." changed"
assert(ownership.matches_recovery(phrase,recovery,"name",limits),
  "name-excluded recovery comparison rejected a name-only change")
assert(not ownership.matches_recovery(phrase,recovery,"exact",limits),
  "exact recovery comparison ignored a phrase name change")
phrase.name=saved_name

hidden_note_values.panning_value=43
assert(not ownership.matches_recovery(phrase,recovery,"exact",limits),
  "recovery comparison missed hidden note data")
hidden_note_values.panning_value=42
local old_empty_note=renoise.PatternLine.EMPTY_NOTE
renoise.PatternLine.EMPTY_NOTE=old_empty_note+1
assert(not ownership.matches_recovery(phrase,recovery,"exact",limits),
  "recovery comparison missed empty-cell default metadata")
renoise.PatternLine.EMPTY_NOTE=old_empty_note
assert(ownership.matches_recovery(phrase,recovery,"exact",limits),
  "recovery capture did not recover after native values were restored")

fail_hidden_note_access=true
local recovery_match=ownership.matches_recovery(phrase,recovery,"exact",limits)
assert(recovery_match==false,"recovery comparison accepted a throwing native getter")
fail_hidden_note_access=false

phrase.script.paragraphs={"return 1"}
local scripted=assert(ownership.snapshot(phrase,limits))
local scripted_index=assert(ownership.snapshot_index(scripted,limits))
phrase.script.paragraphs[1]="return 2"
native_match=ownership.matches_snapshot(phrase,scripted,limits,scripted_index)
assert(native_match==false,"native exact match missed phrase script edits")
phrase.script.paragraphs={}

phrase.mapping={key_tracking=1,base_note=48,loop_start=1,loop_end=2,looping=false,
  note_range={0,119}}
local mapped=assert(ownership.snapshot(phrase,limits))
local mapped_index=assert(ownership.snapshot_index(mapped,limits))
phrase.mapping.note_range[1]=1
native_match=ownership.matches_snapshot(phrase,mapped,limits,mapped_index)
assert(native_match==false,"native exact match missed mapping edits")
phrase.mapping=nil

local copied=assert(ownership.copy_snapshot(snapshot))
assert(ownership.compare(snapshot,copied))
copied.name="changed"
copied.properties.lpb=copied.properties.lpb+1
local same,reason=ownership.compare(snapshot,copied)
assert(not same and reason=="Phrase differs at name",tostring(reason))
copied=assert(ownership.copy_snapshot(snapshot))
copied.lines[1].notes[1].note_value=nil
same,reason=ownership.compare(snapshot,copied)
assert(not same and reason=="Phrase differs at lines.1.notes.1.note_value",tostring(reason))
copied=assert(ownership.copy_snapshot(snapshot))
copied.extra=true
same,reason=ownership.compare(snapshot,copied)
assert(not same and reason=="Phrase differs at extra",tostring(reason))
copied=assert(ownership.copy_snapshot(snapshot))
copied.lines[1].notes[3].note_value="invalid"
same,reason=ownership.compare(snapshot,copied)
assert(not same and reason=="Phrase differs at lines.1.notes.3.note_value",tostring(reason))
copied=assert(ownership.copy_snapshot(snapshot))
setmetatable(copied,{})
assert(not ownership.compare(snapshot,copied),"metatable snapshot compared equal")
local cyclic={};cyclic.self=cyclic
assert(not ownership.compare(cyclic,cyclic),"cyclic snapshots were accepted")
print("ACID phrase snapshot empty-line and empty-cell checks passed")
