dofile("tests/bootstrap.lua")("acid")

renoise={}
renoise.PatternLine={EMPTY_NOTE=121,EMPTY_INSTRUMENT=255,EMPTY_VOLUME=255,
  EMPTY_PANNING=255,EMPTY_DELAY=0,EMPTY_EFFECT_NUMBER=0,EMPTY_EFFECT_AMOUNT=0}
renoise.InstrumentPhrase={MAX_NUMBER_OF_LINES=2,MAX_NUMBER_OF_NOTE_COLUMNS=3,
  MAX_NUMBER_OF_EFFECT_COLUMNS=2}
assert(renoise.PatternLine.EMPTY_NOTE==121 and renoise.PatternLine.EMPTY_EFFECT_NUMBER==0)

local note_reads,effect_reads=0,0
local function cell(fields,kind)
  return setmetatable({}, {__index=function(_,key)
    if key=="is_empty" then return fields.is_empty end
    if fields[key]~=nil then
      if kind=="note" then note_reads=note_reads+1 else effect_reads=effect_reads+1 end
      return fields[key]
    end
  end})
end

local hidden_note=cell({is_empty=false,note_value=64,instrument_value=17,volume_value=91,
  panning_value=42,delay_value=12,effect_number_value=5,effect_amount_value=19},"note")
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
