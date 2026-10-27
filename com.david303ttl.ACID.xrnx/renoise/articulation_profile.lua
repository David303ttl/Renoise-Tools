-- Recognize the measured reference sampler without changing user instruments.
local M={}
local function expect(actual,expected,path,tolerance)
  local matches=actual==expected
  if tolerance then
    matches=type(actual)=="number" and actual==actual and math.abs(actual-expected)<=tolerance
  end
  if not matches then error(path.." must be "..tostring(expected),0) end
end
local function fields(object,values,path)
  for key,value in pairs(values) do expect(object[key],value,path.."."..key) end
end
local function inspect(instrument,profile,options)
  if profile~="reference_flat" and profile~="reference_diagnostic" and profile~="reference_accent" then
    error("unknown reference profile",0)
  end
  local api=renoise
  expect(#instrument.samples,1,"instrument.samples count")
  fields(instrument,{volume=1,transpose=0,
    sample_mapping_overlap_mode=api.Instrument.OVERLAP_MODE_ALL},"instrument")
  fields(instrument.trigger_options,{monophonic=false,monophonic_glide=0,
    quantize=api.InstrumentTriggerOptions.QUANTIZE_NONE,scale_mode="None",
    scale_key=1,mts_esp_tuning=false},"trigger_options")
  expect(#instrument.trigger_options.tuning,0,"custom tuning count")
  expect(instrument.plugin_properties.plugin_loaded,false,"plugin_loaded")
  expect(instrument.midi_output_properties.device_name,"","MIDI output device")
  expect(#instrument.sample_device_chains,0,"sample FX chain count")
  local sample=instrument.samples[1]
  fields(sample,{volume=3,panning=0.5,transpose=0,fine_tune=0,
    beat_sync_enabled=false,oneshot=false,autoseek=false,autofade=false,
    oversample_enabled=false,interpolation_mode=api.Sample.INTERPOLATE_LINEAR,
    new_note_action=api.Sample.NEW_NOTE_ACTION_NOTE_CUT,mute_group=0,
    loop_start=1,loop_end=168,loop_mode=api.Sample.LOOP_MODE_FORWARD,
    loop_release=false,device_chain_index=0},"sample")
  expect(#sample.slice_markers,0,"sample slice marker count")
  local mapping=sample.sample_mapping
  fields(mapping,{base_note=48,map_key_to_pitch=true,
    map_velocity_to_volume=profile=="reference_accent"},"mapping")
  expect(mapping.note_range[1],0,"mapping.note_range start")
  expect(mapping.note_range[2],119,"mapping.note_range end")
  expect(mapping.velocity_range[1],0,"mapping.velocity_range start")
  expect(mapping.velocity_range[2],127,"mapping.velocity_range end")
  local buffer=sample.sample_buffer
  fields(buffer,{has_sample_data=true,sample_rate=44100,bit_depth=32,
    number_of_channels=1,number_of_frames=168},"sample buffer")
  for frame=1,168 do
    expect(buffer:sample_data(1,frame),0.35*(2*((frame-1)/168)-1),
      "sample waveform frame "..frame,0.0000001)
  end
  if profile~="reference_diagnostic" then
    expect(sample.modulation_set_index,0,"sample.modulation_set_index")
  else
    expect(sample.modulation_set_index,1,"sample.modulation_set_index")
    local modulation=instrument.sample_modulation_sets[1]
    expect(#modulation.devices,1,"reference modulation device count")
    expect(modulation.volume_input.value,1,"modulation.volume_input")
    fields(modulation,{filter_type="None",pitch_range=12},"modulation")
    for key,value in pairs({panning_input=0,pitch_input=0,cutoff_input=63.5,
      resonance_input=63.5,drive_input=0}) do
      expect(modulation[key].value,value,"modulation."..key)
    end
    local envelope=modulation.devices[1]
    fields(envelope,{is_active=true,target=api.SampleModulationDevice.TARGET_VOLUME,
      operator=api.SampleModulationDevice.OPERATOR_MUL,bipolar=false,
      tempo_synced=false,play_mode=api.SampleEnvelopeModulationDevice.PLAYMODE_LINES,
      loop_mode=api.SampleEnvelopeModulationDevice.LOOP_MODE_OFF,
      sustain_enabled=true,sustain_position=31,length=37},"diagnostic envelope")
    if type(options.fade_amount)~="number" or options.fade_amount~=options.fade_amount then
      error("diagnostic profile requires the measured fade_amount",0)
    end
    expect(envelope.fade_amount,options.fade_amount,"diagnostic envelope.fade_amount",0.001)
    local points={{1,0},{11,1},{31,0.65},{32,0.65},{36,0},{37,0}}
    expect(#envelope.points,6,"diagnostic envelope point count")
    for index,point in ipairs(points) do
      local actual=envelope.points[index]
      expect(actual.time,point[1],"envelope point "..index.." time")
      expect(actual.value,point[2],"envelope point "..index.." value",0.000001)
      expect(actual.scaling,0,"envelope point "..index.." scaling",0.000001)
    end
  end
  return {profile=profile,waveform="reference_saw",frames=168,sample_rate=44100}
end
function M.check(instrument,profile,options)
  if not instrument then return nil,"unsupported articulation profile: no instrument" end
  local ok,result=pcall(inspect,instrument,profile,options or {})
  if not ok then return nil,"unsupported articulation profile: "..tostring(result) end
  return result
end
return M
