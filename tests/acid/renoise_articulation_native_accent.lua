-- Create a disposable flat-velocity reference phrase for accent response measurements.
local song=assert(renoise.song(),"Open the disposable ACID song first")
local case_id=rawget(_G,"ACID_ACCENT_CONTROL_CASE") or "alternating"
assert(case_id=="alternating" or case_id=="consecutive","Accent control must be alternating or consecutive")
local probe
for _,instrument in ipairs(song.instruments) do
  if instrument.name=="ACID ARTICULATION PROBE" then assert(not probe,"Multiple articulation probes exist"); probe=instrument end
end
assert(probe and #probe.samples==1,"Create the disposable articulation probe first")
local sample=probe.samples[1]
assert(sample.sample_buffer.has_sample_data and sample.sample_buffer.number_of_frames==168,"Reference probe sample is missing")
assert(#probe.phrases<renoise.Instrument.MAX_NUMBER_OF_PHRASES,"Probe has no free phrase slot")
assert(song.transport.bpm==120 and song.transport.lpb==8 and song.transport.tpl==12,
  "Native accent control requires 120 BPM, LPB 8 and TPL 12")
local phrase_name="ACID native accent "..case_id
for _,existing in ipairs(probe.phrases) do
  assert(existing.name~=phrase_name,"This native accent phrase already exists; use a fresh disposable song")
end
local source=debug.getinfo(1,"S").source:gsub("\\","/")
local root=assert(source:match("^@(.*)/tests/acid/renoise_articulation_native_accent.lua$"),
  "Load this helper from its repository file path")
local output_path=root.."/tmp/acid-articulation/native_accent_"..case_id.."_"..tostring(os.time())..".txt"
local previous=io.open(output_path,"rb")
if previous then previous:close(); error("Refusing to overwrite accent-control metadata") end
sample.modulation_set_index=0
sample.sample_mapping.map_velocity_to_volume=true
assert(sample.modulation_set_index==0 and sample.sample_mapping.map_velocity_to_volume,"Could not configure the flat mapped-velocity profile")
local phrase=probe:insert_phrase_at(#probe.phrases+1)
phrase.name=phrase_name
phrase.number_of_lines=8
phrase.visible_note_columns=1
phrase.visible_effect_columns=1
phrase.lpb=8
phrase.looping=false
phrase.loop_start=1
phrase.loop_end=phrase.number_of_lines
phrase.key_tracking=renoise.InstrumentPhrase.KEY_TRACKING_NONE
local accent_steps=case_id=="alternating" and {2,4} or {2,3}
local accent_by_step={}
for _,step in ipairs(accent_steps) do accent_by_step[step]=true end
local event_count=case_id=="alternating" and 4 or 3
local velocities={}
for step=1,event_count do velocities[step]=accent_by_step[step] and 255 or 89 end
for step=1,event_count do
  local note=phrase:line((step-1)*2+1).note_columns[1]
  note.note_value=48
  note.volume_value=velocities[step]
  phrase:line((step-1)*2+2).note_columns[1].note_value=renoise.PatternLine.NOTE_OFF
end
probe.phrase_program=#probe.phrases
for index,instrument in ipairs(song.instruments) do if rawequal(instrument,probe) then song.selected_instrument_index=index; break end end
local output=assert(io.open(output_path,"wb"))
output:write("format=ACID-NATIVE-ACCENT-1\ncase_id=native_accent_"..case_id.."\nmapping.map_velocity_to_volume=true\nsample.modulation_set_index=0\n")
output:write("sample.frame_count="..sample.sample_buffer.number_of_frames.."\naccent_velocity_cells=89,255\naccent_steps="..table.concat(accent_steps,",").."\n")
output:write("event_count="..event_count.."\nphrase_program="..probe.phrase_program.."\nphrase.name="..phrase.name.."\nphrase.line_count="..phrase.number_of_lines.."\nphrase.looping=false\n")
output:write("transport.bpm="..song.transport.bpm.."\ntransport.lpb="..song.transport.lpb.."\ntransport.tpl="..song.transport.tpl.."\n")
for line=1,phrase.number_of_lines do local cell=phrase:line(line).note_columns[1]; output:write("phrase.line."..line.."="..cell.note_value..","..cell.volume_value.."\n") end
output:close()
print("Native flat accent control ready: "..case_id..", phrase program "..probe.phrase_program)
print("Metadata: "..output_path)


