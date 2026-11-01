-- Create an independent flat-mapped NOTE/TIE accent retention control.
local song=assert(renoise.song(),"Open the disposable ACID song first")
local LINES_PER_STEP=4
local HALF_STEP_LINE_OFFSET=2
local PHRASE_LPB=16
local FIRST_PHRASE_LINE=1
local probe
for _,instrument in ipairs(song.instruments) do
  if instrument.name=="ACID ARTICULATION PROBE" then assert(not probe,"Multiple articulation probes exist"); probe=instrument end
end
assert(probe and #probe.samples==1,"Create the disposable articulation probe first")
local sample=probe.samples[1]
assert(sample.sample_buffer.has_sample_data and sample.sample_buffer.number_of_frames==168,"Reference probe sample is missing")
assert(#probe.phrases<renoise.Instrument.MAX_NUMBER_OF_PHRASES,"Probe has no free phrase slot")
assert(song.transport.bpm==120 and song.transport.lpb==8 and song.transport.tpl==12,
  "Native tied-accent control requires 120 BPM, LPB 8 and TPL 12")
local phrase_name="ACID native tied accent"
for _,existing in ipairs(probe.phrases) do assert(existing.name~=phrase_name,"This native tied-accent phrase already exists; use a fresh disposable song") end
local source=debug.getinfo(1,"S").source:gsub("\\","/")
local root=assert(source:match("^@(.*)/tests/acid/renoise_articulation_native_tied_accent.lua$"),"Load this helper from its repository file path")
local output_path=root.."/tmp/acid-articulation/native_tied_accent_"..tostring(os.time())..".txt"
local previous=io.open(output_path,"rb")
if previous then previous:close(); error("Refusing to overwrite tied-accent metadata") end
sample.modulation_set_index=0
sample.sample_mapping.map_velocity_to_volume=true
assert(sample.modulation_set_index==0 and sample.sample_mapping.map_velocity_to_volume,"Could not configure the flat mapped-velocity profile")
local phrase=probe:insert_phrase_at(#probe.phrases+1)
phrase.name=phrase_name
phrase.number_of_lines=7*LINES_PER_STEP
phrase.visible_note_columns=1
phrase.visible_effect_columns=1
phrase.lpb=PHRASE_LPB
phrase.looping=false
phrase.loop_start=1
phrase.loop_end=phrase.number_of_lines
phrase.key_tracking=renoise.InstrumentPhrase.KEY_TRACKING_NONE
local velocities={89,255,89}
for index,step in ipairs({1,3,5}) do
  local start_line=(step-1)*LINES_PER_STEP+FIRST_PHRASE_LINE
  local note=phrase:line(start_line).note_columns[1]
  note.note_value=48
  note.volume_value=velocities[index]
end
phrase:line((2-1)*LINES_PER_STEP+FIRST_PHRASE_LINE+HALF_STEP_LINE_OFFSET).note_columns[1].note_value=renoise.PatternLine.NOTE_OFF
phrase:line((4-1)*LINES_PER_STEP+FIRST_PHRASE_LINE+HALF_STEP_LINE_OFFSET).note_columns[1].note_value=renoise.PatternLine.NOTE_OFF
phrase:line((7-1)*LINES_PER_STEP+FIRST_PHRASE_LINE).note_columns[1].note_value=renoise.PatternLine.NOTE_OFF
probe.phrase_program=#probe.phrases
for index,instrument in ipairs(song.instruments) do if rawequal(instrument,probe) then song.selected_instrument_index=index; break end end
local output=assert(io.open(output_path,"wb"))
output:write("format=ACID-NATIVE-ACCENT-1\ncase_id=native_tied_accent\nmapping.map_velocity_to_volume=true\nsample.modulation_set_index=0\n")
output:write("sample.frame_count="..sample.sample_buffer.number_of_frames.."\naccent_velocity_cells=89,255\naccent_steps=2\nevent_count=3\nphrase_program="..probe.phrase_program.."\nphrase.name="..phrase.name.."\nphrase.lpb="..phrase.lpb.."\nphrase.line_count="..phrase.number_of_lines.."\nphrase.looping=false\n")
output:write("transport.bpm="..song.transport.bpm.."\ntransport.lpb="..song.transport.lpb.."\ntransport.tpl="..song.transport.tpl.."\n")
for line=1,phrase.number_of_lines do local cell=phrase:line(line).note_columns[1]; output:write("phrase.line."..line.."="..cell.note_value..","..cell.volume_value.."\n") end
output:close()
print("Native tied-accent control ready: NOTE/TIE/OFF/NOTE/TIE/OFF/NOTE/TIE/REST, phrase program "..probe.phrase_program)
print("Metadata: "..output_path)
