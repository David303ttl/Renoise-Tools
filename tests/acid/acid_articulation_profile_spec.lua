dofile("tests/bootstrap.lua")("acid")
renoise={Instrument={OVERLAP_MODE_ALL=1},InstrumentTriggerOptions={QUANTIZE_NONE=1},
 Sample={INTERPOLATE_LINEAR=2,NEW_NOTE_ACTION_NOTE_CUT=1,LOOP_MODE_FORWARD=2},
 SampleModulationDevice={TARGET_VOLUME=1,OPERATOR_MUL=3},
 SampleEnvelopeModulationDevice={PLAYMODE_LINES=2,LOOP_MODE_OFF=1}}
local checker=require("renoise.articulation_profile")
local function reference()
 local envelope={is_active=true,target=1,operator=3,bipolar=false,tempo_synced=false,
  play_mode=2,loop_mode=1,sustain_enabled=true,sustain_position=31,length=37,
  fade_amount=765.765,points={}}
 for _,point in ipairs({{1,0},{11,1},{31,0.65},{32,0.65},{36,0},{37,0}}) do
  envelope.points[#envelope.points+1]={time=point[1],value=point[2],scaling=0}
 end
 local buffer={has_sample_data=true,sample_rate=44100,bit_depth=32,
  number_of_channels=1,number_of_frames=168}
 function buffer:sample_data(channel,frame)
  assert(channel==1 and frame>=1 and frame<=168)
  return 0.35*(2*((frame-1)/168)-1)
 end
 return {samples={{volume=3,panning=0.5,transpose=0,fine_tune=0,
  beat_sync_enabled=false,oneshot=false,autoseek=false,autofade=false,
  oversample_enabled=false,interpolation_mode=2,new_note_action=1,mute_group=0,
  loop_start=1,loop_end=168,loop_mode=2,loop_release=false,device_chain_index=0,
  slice_markers={},modulation_set_index=0,sample_buffer=buffer,
  sample_mapping={base_note=48,map_key_to_pitch=true,map_velocity_to_volume=false,
   note_range={0,119},velocity_range={0,127}}}},volume=1,transpose=0,
  sample_mapping_overlap_mode=1,trigger_options={monophonic=false,monophonic_glide=0,quantize=1,scale_mode="None",scale_key=1,mts_esp_tuning=false,tuning={}},
  plugin_properties={plugin_loaded=false},midi_output_properties={device_name=""},
  sample_device_chains={},sample_modulation_sets={{volume_input={value=1},panning_input={value=0},pitch_input={value=0},cutoff_input={value=63.5},resonance_input={value=63.5},drive_input={value=0},filter_type="None",pitch_range=12,devices={envelope}}}}
end
local instrument=reference()
assert(checker.check(instrument,"reference_flat"))
assert(not checker.check(instrument,"reference_accent"))
instrument.samples[1].sample_mapping.map_velocity_to_volume=true
assert(checker.check(instrument,"reference_accent"))
assert(not checker.check(instrument,"reference_flat"))
instrument.samples[1].sample_mapping.map_velocity_to_volume=false
assert(not checker.check(instrument,"reference_diagnostic",{fade_amount=765.765}))
instrument.samples[1].modulation_set_index=1
assert(checker.check(instrument,"reference_diagnostic",{fade_amount=765.765}))
assert(not checker.check(instrument,"reference_diagnostic"))
local changes={
 {function(i)i.trigger_options.tuning={1} end,"custom tuning"},
 {function(i)i.trigger_options.scale_mode="Major" end,"scale_mode"},
 {function(i)i.samples[1].volume=1 end,"sample.volume"},
 {function(i)i.samples[1].sample_mapping.map_velocity_to_volume=true end,"mapping.map_velocity_to_volume"},
 {function(i)i.trigger_options.monophonic=true end,"trigger_options.monophonic"},
 {function(i)i.samples[1].new_note_action=3 end,"sample.new_note_action"},
 {function(i)i.samples[1].loop_end=167 end,"sample.loop_end"},
 {function(i)i.samples[1].sample_buffer.sample_data=function()return 0 end end,"waveform frame"},
 {function(i)i.sample_device_chains[1]={} end,"FX chain count"},
 {function(i)i.plugin_properties.plugin_loaded=true end,"plugin_loaded"},
 {function(i)i.midi_output_properties.device_name="Synth" end,"MIDI output"},
 {function(i)i.samples[1].sample_buffer.sample_rate=48000 end,"sample_rate"},
 {function(i)i.samples[1].sample_mapping.note_range={12,119} end,"note_range start"},
 {function(i)i.samples[2]=i.samples[1] end,"samples count"}}
for _,change in ipairs(changes) do
 local altered=reference();change[1](altered)
 local result,message=checker.check(altered,"reference_flat")
 assert(not result and message:find(change[2],1,true),message)
end
for _,change in ipairs({
 function(e)e.tempo_synced=true end,function(e)e.points[3].value=0.5 end,
 function(e)e.is_active=false end,function(e)e.fade_amount=23.936 end,
 function(e)e.target=3 end,function(e)e.sustain_enabled=false end}) do
 local altered=reference();altered.samples[1].modulation_set_index=1
 change(altered.sample_modulation_sets[1].devices[1])
 assert(not checker.check(altered,"reference_diagnostic",{fade_amount=765.765}))
end
-- Frozen proxies reject writes to existing fields as well as new fields.
local function freeze(object)
 if type(object)~="table" then return object end
 local backing={}
 for key,value in pairs(object) do backing[key]=freeze(value) end
 -- Lua 5.1 has no table __len; retain dense list storage for array access.
 if #object>0 then return backing end
 return setmetatable({}, {__index=backing,
  __newindex=function()error("profile inspection attempted mutation")end})
end
assert(checker.check(freeze(reference()),"reference_flat"))
assert(not checker.check({samples={}},"reference_flat"))
assert(not checker.check(nil,"reference_flat"))
assert(not checker.check(reference(),"unknown"))
print("ACID reference articulation profile recognition checks passed (playback unverified)")
