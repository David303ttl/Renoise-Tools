-- Add pitch-matched held NOTE controls for the moving Repeat glide probes.
local song=assert(renoise.song(),"Open the disposable articulation song first")
local LINES_PER_STEP=4
local PHRASE_LPB=16
local SOURCE_STEPS=8
local FIRST_PHRASE_LINE=1
local instrument
for _,candidate in ipairs(song.instruments) do
 if candidate.name=="ACID ARTICULATION PROBE" then assert(not instrument,"Multiple articulation probes exist");instrument=candidate end
end
assert(instrument,"Create the diagnostic probe first")
assert(instrument.phrase_playback_mode==renoise.Instrument.PHRASES_PLAY_SELECTIVE,"Probe must use Selective phrase playback")
local expected={"ACID MOVING GLIDE HOLD 48","ACID MOVING GLIDE HOLD 52","ACID MOVING GLIDE HOLD 60"}
local exists={}
for _,phrase in ipairs(instrument.phrases) do exists[phrase.name]=true end
local missing=0
for _,name in ipairs(expected) do if not exists[name] then missing=missing+1 end end
assert(missing>0,"Moving glide hold controls already exist")
assert(#instrument.phrases+missing<=renoise.Instrument.MAX_NUMBER_OF_PHRASES,"No phrase slots for moving glide controls")
for _,name in ipairs(expected) do
 if not exists[name] then
  local note=tonumber(name:match("(%d+)$"))
  local phrase=instrument:insert_phrase_at(#instrument.phrases+1)
  phrase.name=name
  phrase.playback_mode=renoise.InstrumentPhrase.PLAY_PATTERN
   phrase.number_of_lines=SOURCE_STEPS*LINES_PER_STEP+1
  phrase.visible_note_columns=1
  phrase.visible_effect_columns=0
  phrase.instrument_column_visible=false
  phrase.key_tracking=renoise.InstrumentPhrase.KEY_TRACKING_NONE
   phrase.lpb=PHRASE_LPB
  phrase.shuffle=0
  phrase.autoseek=false
  phrase.looping=true
   phrase.loop_start=LINES_PER_STEP+FIRST_PHRASE_LINE
   phrase.loop_end=phrase.number_of_lines
   phrase:line(FIRST_PHRASE_LINE).note_columns[1].note_value=note
   phrase:line(FIRST_PHRASE_LINE).note_columns[1].instrument_value=renoise.PatternLine.EMPTY_INSTRUMENT
  print("Created pitch-matched held control "..name.." at phrase program "..tostring(#instrument.phrases))
 end
end
return "held controls ready"
