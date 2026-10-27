-- Create independent moving-slide reference phrases in the disposable probe.
local song=assert(renoise.song(),"Open the disposable articulation song first")
local instrument_index
for index,instrument in ipairs(song.instruments) do
 if instrument.name=="ACID ARTICULATION PROBE" then
  assert(not instrument_index,"Multiple articulation probes exist")
  instrument_index=index
 end
end
assert(instrument_index,"Create the diagnostic probe first")
local instrument=song.instruments[instrument_index]
assert(instrument.phrase_playback_mode==renoise.Instrument.PHRASES_PLAY_SELECTIVE,
 "Probe must use Selective phrase playback")
local phrase_names={
 "ACID MOVING SLIDE FOUR SEMITONE",
 "ACID MOVING SLIDE OCTAVE"
}
for _,phrase in ipairs(instrument.phrases) do
 for _,name in ipairs(phrase_names) do assert(phrase.name~=name,"Phrase already exists: "..name) end
end
assert(#instrument.phrases+2<=renoise.Instrument.MAX_NUMBER_OF_PHRASES,
 "Probe has fewer than two free phrase slots")
local function add_phrase(label,target)
 local name="ACID MOVING SLIDE "..label
 for _,phrase in ipairs(instrument.phrases) do assert(phrase.name~=name,"Phrase already exists: "..name) end
 local phrase=instrument:insert_phrase_at(#instrument.phrases+1)
 phrase.name=name
 phrase.playback_mode=renoise.InstrumentPhrase.PLAY_PATTERN
 phrase.number_of_lines=17
 phrase.visible_note_columns=1
 phrase.visible_effect_columns=1
 phrase.instrument_column_visible=false
 phrase.key_tracking=renoise.InstrumentPhrase.KEY_TRACKING_NONE
 phrase.lpb=8
 phrase.shuffle=0
 phrase.autoseek=false
 phrase.looping=true
 phrase.loop_start=1
 phrase.loop_end=17
 local transitions={{line=1,note=48,amount=target-48},{line=9,note=target,amount=48-target}}
 for _,event in ipairs(transitions) do
  local cell=phrase:line(event.line).note_columns[1]
  cell.note_value=event.note
  cell.instrument_value=renoise.PatternLine.EMPTY_INSTRUMENT
  cell.effect_number_string="0G"
  cell.effect_amount_value=32
  local covered=math.ceil(math.abs(event.amount)*16/32)
  for offset=1,covered-1 do
   local continuation=phrase:line(event.line+offset).note_columns[1]
   continuation.effect_number_string="0G"
   continuation.effect_amount_value=0
  end
 end
 return phrase
end
add_phrase("FOUR SEMITONE",52)
add_phrase("OCTAVE",60)
print("Created two 8-step moving Repeat glide phrases with bidirectional 0G20 and G00 continuation.")
for index,phrase in ipairs(instrument.phrases) do if phrase.name:find("ACID MOVING SLIDE",1,true)==1 then print(index.." "..phrase.name) end end
return "probes ready"
