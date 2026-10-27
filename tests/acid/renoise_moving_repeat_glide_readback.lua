-- Record the actual phrase cells and playback settings for moving glide evidence.
local song=assert(renoise.song(),"Open the disposable articulation song first")
local source=debug.getinfo(1,"S").source:gsub("\\","/")
local root=assert(source:match("^@(.*)/tests/acid/renoise_moving_repeat_glide_readback.lua$"),"Load this script from its repository path")
local instrument
for _,candidate in ipairs(song.instruments) do if candidate.name=="ACID ARTICULATION PROBE" then assert(not instrument,"Multiple articulation probes exist");instrument=candidate end end
assert(instrument,"Diagnostic probe is missing")
local names={"ACID MOVING SLIDE FOUR SEMITONE","ACID MOVING SLIDE OCTAVE","ACID MOVING GLIDE HOLD 48","ACID MOVING GLIDE HOLD 52","ACID MOVING GLIDE HOLD 60"}
local indices={}
for index,phrase in ipairs(instrument.phrases) do if phrase.name:find("ACID MOVING",1,true)==1 then assert(not indices[phrase.name],"Duplicate moving phrase");indices[phrase.name]=index end end
local output_path=root.."/tmp/acid-articulation/moving_repeat_glide_readback_"..tostring(os.time())..".txt"
local out=assert(io.open(output_path,"wb"),"Create tmp/acid-articulation first")
local function record(key,value) assert(out:write(key.."="..tostring(value):gsub("[\r\n]"," ").."\n")) end
record("format","ACID-MOVING-GLIDE-READBACK-1")
record("phrase_playback_mode",instrument.phrase_playback_mode)
record("transport.bpm",song.transport.bpm)
record("transport.lpb",song.transport.lpb)
record("transport.tpl",song.transport.tpl)
local sample=assert(instrument.samples[1])
for _,key in ipairs({"volume","transpose","fine_tune","loop_start","loop_end","loop_mode","interpolation_mode","new_note_action","modulation_set_index"}) do record("sample."..key,sample[key]) end
for _,key in ipairs({"base_note","map_velocity_to_volume","map_key_to_pitch"}) do record("mapping."..key,sample.sample_mapping[key]) end
record("buffer.sample_rate",sample.sample_buffer.sample_rate)
record("buffer.number_of_frames",sample.sample_buffer.number_of_frames)
for _,name in ipairs(names) do
 local index=assert(indices[name],"Expected moving phrase is missing: "..name)
 local phrase=instrument.phrases[index]
 record("phrase."..index..".name",phrase.name)
 record("phrase."..index..".program",index)
 for _,key in ipairs({"number_of_lines","lpb","looping","loop_start","loop_end"}) do record("phrase."..index.."."..key,phrase[key]) end
 for line=1,phrase.number_of_lines do
  local note=phrase:line(line).note_columns[1]
  if note.note_value~=renoise.PatternLine.EMPTY_NOTE or note.effect_number_value~=0 or note.effect_amount_value~=0 then
   record("phrase."..index..".line."..line,table.concat({note.note_value,note.instrument_value,note.volume_value,note.effect_number_value,note.effect_amount_value},","))
  end
 end
end
out:close()
print("Moving Repeat glide readback written: "..output_path)
return output_path
