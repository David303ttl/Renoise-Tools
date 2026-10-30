dofile('tests/bootstrap.lua')('acid')
local columns=dofile('tests/acid/phrase_columns.lua')

-- Explicit bounded host capacities keep mocked transactions proportional to the
-- representative patterns below. Pure planner tests cover the full 1..32 range.
local CAPACITY_LINES=128
local CAPACITY_NOTE_COLUMNS=4
local CAPACITY_EFFECT_COLUMNS=2

local function observable()
  local handlers={}
  return {
    add_notifier=function(_,f) handlers[f]=true end,
    remove_notifier=function(_,f) handlers[f]=nil end,
    fire=function()
      local pending={}
      for f in pairs(handlers) do pending[#pending+1]=f end
      for _,f in ipairs(pending) do f() end
    end
  }
end
local idle,committed=observable(),observable()
local instrument={phrases={},samples={{sample_buffer={has_sample_data=true}}},plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""}}
local contaminate=false
local wrong_volume=nil
local EMPTY_SCRIPT_DIAGNOSTIC="compile error: no script content present."
local script={paragraphs={},compile_error='',runtime_error='',committed_observable=committed,
  parameters={},pending_changes=0,editor_visible=true}
local function make_script()
  return setmetatable({paragraphs={},compile_error='',runtime_error='',parameters={},
    pending_changes=0,editor_visible=true},{__index=script})
end
function script:commit()
  self.compile_error=#self.paragraphs==0 and EMPTY_SCRIPT_DIAGNOSTIC or ""
  self.runtime_error=""
  committed:fire()
end
function script:render_to_pattern(_,callback)
  local phrase=instrument.phrases[#instrument.phrases]
  local values=assert(self.paragraphs[1]:match('local values = { (.-) }\nreturn pattern'))
  local step,count=0,0
  for token in (values..','):gmatch('(.-),') do
    local volume=tonumber(token:match('volume = ([%d.]+)'))
    local note=tonumber(token:match('key = (%d+)'))
    if volume then
      local line=(step-1)*4+1
      phrase.cells[line].volume_value=volume==1 and 255 or 89
    end
    if note or token:find('"off"',1,true) or token:match('^%s*false%s*$') then
      step=step+1
      local line=(step-1)*4+1
      if note or token:find('"off"',1,true) then
        phrase.cells[line].note_value=note or 120
        count=count+1
      end
    end
  end
  if contaminate then phrase.cells[2].delay_value=1 end
  if wrong_volume then phrase.cells[1].volume_value=wrong_volume end
  callback(nil,count,0)
  return true
end
local properties={'name','number_of_lines','lpb','playback_mode','looping',
  'loop_start','loop_end','key_tracking','base_note','autoseek','visible_note_columns',
  'visible_effect_columns','instrument_column_visible','volume_column_visible',
  'panning_column_visible','delay_column_visible','sample_effects_column_visible'}
function instrument:insert_phrase_at(index)
  local phrase={name='',number_of_lines=16,visible_note_columns=CAPACITY_NOTE_COLUMNS,
    visible_effect_columns=CAPACITY_EFFECT_COLUMNS,looping=false,loop_start=1,loop_end=16,lpb=16,shuffle=0,
    playback_mode=1,key_tracking=1,base_note=48,autoseek=false,
    instrument_column_visible=true,volume_column_visible=true,
    panning_column_visible=true,delay_column_visible=true,
    sample_effects_column_visible=true,mapping=nil,script=make_script(),cells={}}
  for line=1,CAPACITY_LINES do
    phrase.cells[line]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function phrase:line(line) return columns.line(self,line) end
  function phrase:column_is_muted() return false end
  function phrase:column_name(line) return "column "..tostring(line) end
  function phrase:copy_from(other)
    columns.copy(self,other)
    for _,key in ipairs(properties) do self[key]=other[key] end
    self.cells={}
    for line=1,CAPACITY_LINES do
      local original=other.cells[line] or {}
      local copy={}
      for key,value in pairs(original) do copy[key]=value end
      self.cells[line]=copy
    end
  end
  table.insert(self.phrases,index,phrase)
  return phrase
end
function instrument:delete_phrase_at(index) table.remove(self.phrases,index) end
local song={instruments={instrument},transport={timing_model=2}}
_G.renoise={InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1,
    MAX_NUMBER_OF_LINES=CAPACITY_LINES,
    MAX_NUMBER_OF_NOTE_COLUMNS=CAPACITY_NOTE_COLUMNS,
    MAX_NUMBER_OF_EFFECT_COLUMNS=CAPACITY_EFFECT_COLUMNS},
  Transport={TIMING_MODEL_SPEED=1,TIMING_MODEL_LPB=2},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function()return song end,tool=function()return {app_idle_observable=idle} end}
local writer=require('writers.phrase_writer')
local writer_request=dofile('tests/acid/writer_request.lua')
local seq=require('model.sequencer')
local pitch=dofile('tests/acid/pitch_fixture.lua')
local store=require('renoise.pattern_store')
local ownership=require('renoise.phrase_ownership')
local status
local function status_message(value)
  return type(value)=='table' and value.message or value
end
local function assert_complete(expected_status)
  assert(type(status)=='table' and (status.kind=='success' or status.kind=='failure'),
    'missing typed terminal result')
  assert(status.status==expected_status,
    'expected '..expected_status..', got '..tostring(status.status)..': '..tostring(status.message))
end
local function start(pattern,pb_range,target,options)
  options=options or {}
  options.output_policy=options.output_policy or 'play_once'
  options.pb_range=pb_range
  local request,rejection=writer_request.build(song,1,pattern,target or 1,options)
  if not request then return false,rejection end
  local operation=request.kind=='create' and writer.create or writer.regenerate
  return operation(request,function(value)status=value end)
end
local function generate(pattern,pb_range,target)
  local ok,rejection=start(pattern,pb_range,target)
  assert(ok,type(rejection)=='table' and
    (tostring(rejection.code)..': '..tostring(rejection.message)) or tostring(rejection))
  for _=1,6 do idle:fire() end
end
local pattern=seq.new_pattern(3)
pattern.pitch_events[1]=pitch(48)
pattern.pitch_events[2]=pitch(48)
for i,command in ipairs({'N','T','T'}) do pattern.time_events[i]=command end
local initial_options={output_policy='play_once',pb_range=12}
assert(start(pattern,12,1,initial_options))
initial_options.pb_range=24
for _=1,6 do idle:fire() end
assert_complete('committed')
assert(status_message(status):find('generated',1,true),status.message)
local target=instrument.phrases[1]
assert(target.number_of_lines==12 and target.lpb==16 and not target.looping
  and target.loop_start==1 and target.loop_end==12)
assert(target.cells[1].note_value==48)
assert(target.cells[2].note_value==121 and target.cells[3].note_value==121
  and target.cells[4].note_value==121)
assert(target.cells[11].note_value==120,'Play Once NTT must release at the final step midpoint')
assert(ownership.status(target)=='owned')
local initial_source,initial_policy,initial_pb_range=store.load(song,instrument,target)
assert(initial_source and initial_policy=='play_once' and initial_pb_range==12,
  'writer did not freeze and persist the requested PB range')
assert(initial_source.pitch_events[1].note==48 and pattern.pitch_events[1].note==48,
  'PB Range is not part of canonical PITCH/TIME source')
local raw,name=song.tool_data,target.name
local invalid_started,invalid_result=start(pattern,4,1)
assert(not invalid_started and invalid_result.code=='source.pb_range'
  and invalid_result.category=='source')
assert(song.tool_data==raw and target.name==name and #instrument.phrases==1,
  'invalid PB range mutated the phrase destination')
local original_commit=store.commit
store.commit=function(target_song,candidate)
  assert(original_commit(target_song,candidate))
  error('injected persistence failure after gate application')
end
for i,command in ipairs({'N','N','T'}) do pattern.time_events[i]=command end
pattern.pitch_events[1]=pitch(50)
generate(pattern)
store.commit=original_commit
assert_complete('failed')
assert(status_message(status):find('injected persistence failure',1,true),status.message)
assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],target))
assert(song.tool_data==raw and target.name==name and ownership.status(target)=='owned')
assert(target.cells[1].note_value==48 and target.cells[2].note_value==121)
assert(target.cells[11].note_value==120)
contaminate=true
generate(pattern)
assert_complete('failed')
assert(status_message(status):find('Unexpected delay',1,true),status.message)
assert(song.tool_data==raw and target.name==name and #instrument.phrases==1)
contaminate=false
-- A renderer that preserves notes but loses or changes accent levels must never
-- replace the sealed destination or its persisted source.
for _,volume in ipairs({0,90,128,255}) do
  wrong_volume=volume
  generate(pattern)
  assert_complete('failed')
  assert(status_message(status):find('Phrase volume mismatch',1,true),status.message)
  assert(song.tool_data==raw and target.name==name and #instrument.phrases==1)
  assert(rawequal(instrument.phrases[1],target) and ownership.status(target)=='owned')
  assert(target.cells[1].note_value==48 and target.cells[1].volume_value==89)
end
wrong_volume=nil
generate(pattern)
assert_complete('committed')
assert(status_message(status):find('generated',1,true),status.message)
assert(target.cells[1].note_value==50 and target.cells[3].note_value==120)
assert(target.cells[5].note_value==48 and target.cells[7].note_value==121)
assert(target.cells[11].note_value==120)
local restored,output_policy,restored_pb_range=store.load(song,instrument,target)
assert(restored and output_policy=='play_once' and restored.time_events[2]=='N'
  and restored.pitch_events[1].note==50)
assert(restored_pb_range==0,'omitted PB range defaults to Off')
assert(ownership.status(target)=='owned')
raw,name=song.tool_data,target.name
local original_load=store.load
store.load=function(target_song,target_instrument,phrase)
  local source,policy,pb_range=original_load(target_song,target_instrument,phrase)
  return source,policy,pb_range==12 and 24 or (pb_range==0 and 12 or pb_range)
end
assert(start(pattern,12,1))
for _=1,6 do idle:fire() end
store.load=original_load
assert_complete('failed')
assert(status_message(status):find('final phrase PB range verification failed',1,true),status.message)
assert(song.tool_data==raw and target.name==name and #instrument.phrases==1
  and rawequal(instrument.phrases[1],target),
  'PB range verification failure did not roll back phrase and source settings')
-- Unity accent uses pattrns' empty/full-volume sentinel, not explicit 0x80.
raw,name=song.tool_data,target.name
pattern.pitch_events[1].accent=true
for _,volume in ipairs({0,89,128}) do
  wrong_volume=volume
  generate(pattern)
  assert_complete('failed')
  assert(status_message(status):find('Phrase volume mismatch',1,true),status.message)
  assert(song.tool_data==raw and target.name==name and #instrument.phrases==1)
  assert(target.cells[1].volume_value==89 and ownership.status(target)=='owned')
end
wrong_volume=nil
generate(pattern)
assert_complete('committed')
assert(status_message(status):find('generated',1,true),status.message)
assert(target.cells[1].volume_value==255 and target.cells[5].volume_value==89)
assert(store.load(song,instrument,target).pitch_events[1].accent)

-- Seeded legal-source writer coverage across all target layer combinations.
local random_state=303503
local function next_random(limit)
  random_state=(random_state*48271)%2147483647
  return random_state%limit
end
local function property_pattern(length)
  local source=seq.new_pattern(length)
  source.pitch_length=1+next_random(32)
  for index=1,32 do
    source.pitch_events[index]=seq.new_pitch(next_random(13),next_random(3)-1,
      next_random(2)==1,next_random(2)==1)
    source.time_events[index]='N'
  end
  source.time_events[1]='N'
  for step=2,length do
    local choice=next_random(3)
    source.time_events[step]=choice==0 and 'N' or (choice==1 and 'T' or 'R')
  end
  return source
end
-- Independent writer boundaries; the pure planner suite owns the full range.
local lengths={1,2,3,17,31,32}
local target_layers={
  {samples={{sample_buffer={has_sample_data=true}}},plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""},plugin_loaded=false,midi_device=''},
  {samples={},plugin_loaded=true,midi_device=''},
  {samples={},plugin_loaded=false,midi_device='MIDI Capture'},
  {samples={{sample_buffer={has_sample_data=true}}},plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""},plugin_loaded=true,midi_device='MIDI Capture'},
  {samples={},plugin_loaded=false,midi_device=''},
}
for target_index,layers in ipairs(target_layers) do
  instrument.samples=layers.samples
  instrument.plugin_properties={plugin_loaded=layers.plugin_loaded,
    alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,
    midi_output_routing_index=0}
  instrument.midi_output_properties={device_name=layers.midi_device,
    instrument_type=1,channel=1}
  local destination=target_index==1 and 1 or #instrument.phrases+1
  local target_lengths=target_index==1 and lengths or {17}
  for _,length in ipairs(target_lengths) do
    local candidate=property_pattern(length)
    generate(candidate,nil,destination)
    assert(status.status=='committed' or status.status=='approximate',
      string.format('target %d length %d: %s',target_index,length,status.message))
    local destination_phrase=instrument.phrases[destination]
    assert(ownership.status(destination_phrase)=='owned')
    local saved,policy=store.load(song,instrument,destination_phrase)
    assert(saved and policy=='play_once' and saved.length==length)
    assert(destination_phrase.number_of_lines==length*4)
    assert(#instrument.phrases==destination,'writer left a staging or recovery phrase')
  end
  if target_index>1 then instrument:delete_phrase_at(destination) end
end
local intervals={1,-1,4,-4,12,-12,25,-25}
local function pitch_at(note,accent,slide)
  if note<36 then return seq.new_pitch(note-24,-1,accent,slide) end
  if note>48 then return seq.new_pitch(note-48,1,accent,slide) end
  return seq.new_pitch(note-36,0,accent,slide)
end
for target_index,layers in ipairs(target_layers) do
  instrument.samples=layers.samples
  instrument.plugin_properties={plugin_loaded=layers.plugin_loaded,
    alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,
    midi_output_routing_index=0}
  instrument.midi_output_properties={device_name=layers.midi_device,
    instrument_type=1,channel=1}
  local destination=target_index==1 and 1 or #instrument.phrases+1
  local target_intervals=target_index==1 and intervals or {1,-25,25}
  for _,interval in ipairs(target_intervals) do
    local candidate=seq.new_pattern(3)
    candidate.pitch_length=2
    local first_note=interval==-25 and 55 or (interval==25 and 35 or 36)
    candidate.pitch_events[1]=pitch_at(first_note,false,true)
    candidate.pitch_events[2]=pitch_at(first_note+interval,true,false)
    candidate.time_events[1],candidate.time_events[2],candidate.time_events[3]='N','N','T'
    generate(candidate,nil,destination)
    assert(status.status=='committed' or status.status=='approximate',
      string.format('target %d interval %+d: %s',target_index,interval,status.message))
    local saved=assert(store.load(song,instrument,instrument.phrases[destination]))
    assert(saved.pitch_events[2].note-saved.pitch_events[1].note==interval)
    assert(#instrument.phrases==destination,'extreme interval render left a staging phrase')
  end
  if target_index>1 then instrument:delete_phrase_at(destination) end
end
instrument.samples={{sample_buffer={has_sample_data=true}}}
instrument.plugin_properties={plugin_loaded=false,alias_instrument_index=0,
  alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0}
instrument.midi_output_properties={device_name='',instrument_type=1,channel=1}
instrument.phrase_playback_mode,instrument.phrase_program=1,1
local wide_slide=seq.new_pattern(2)
wide_slide.pitch_length=2
wide_slide.pitch_events[1]=seq.new_pitch(0,-1,false,false)
wide_slide.pitch_events[2]=seq.new_pitch(12,1,false,true)
wide_slide.time_events[1],wide_slide.time_events[2]='N','N'
assert(start(wide_slide,nil,1,{output_policy='repeat'}))
for _=1,6 do idle:fire() end
assert(status.status=='approximate',type(status.message)=='string' and status.message
  or tostring(status.status))
assert(target.cells[9].effect_number_string=='0G' and target.cells[9].effect_amount_value==255,
  'FF instant transition should retain the target pitch when normal glide duration cannot fit')
local previous_name,previous_raw=target.name,song.tool_data
local invalid_started,invalid_result=start({},nil,1)
assert(not invalid_started and (invalid_result.kind=='success' or invalid_result.kind=='failure')
  and invalid_result.category=='source' and invalid_result.code=='source.invalid')
assert(rawequal(instrument.phrases[1],target) and target.name==previous_name
  and song.tool_data==previous_raw)
-- Capability suspension needs a target committed under the connected-MIDI
-- profile that each attempt restores before its single mutation.
instrument:delete_phrase_at(1)
instrument.samples={{sample_buffer={has_sample_data=true}}}
instrument.plugin_properties={plugin_loaded=false,alias_instrument_index=0,
  alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0}
instrument.midi_output_properties={device_name='Connected Port',instrument_type=1,channel=1}
instrument.phrase_playback_mode,instrument.phrase_program=1,1
renoise.Midi={available_output_devices=function()return {'Connected Port'}end}
assert(start(wide_slide,nil,1,{output_policy='repeat'}))
for _=1,6 do idle:fire() end
target=instrument.phrases[1]
assert(status.status=='approximate',type(status.message)=='string' and status.message
  or tostring(status.status))
previous_name,previous_raw=target.name,song.tool_data
local capability_changes={
  function()instrument.samples={}end,
  function()instrument.plugin_properties.plugin_loaded=true end,
  function()instrument.plugin_properties.alias_instrument_index=1 end,
  function()instrument.plugin_properties.alias_fx_track_index=1 end,
  function()instrument.plugin_properties.alias_fx_device_index=1 end,
  function()instrument.plugin_properties.midi_output_routing_index=1 end,
  function()instrument.midi_output_properties.device_name='Other Port' end,
  function()instrument.midi_output_properties.instrument_type=2 end,
  function()instrument.midi_output_properties.channel=2 end,
  function()instrument.phrase_playback_mode=2 end,
  function()instrument.phrase_program=2 end,
  function()renoise.Midi.available_output_devices=function()return {}end end,
}
for index,mutate in ipairs(capability_changes) do
  instrument.samples={{sample_buffer={has_sample_data=true}}}
  instrument.plugin_properties={plugin_loaded=false,alias_instrument_index=0,
    alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0}
  instrument.midi_output_properties={device_name='Connected Port',instrument_type=1,channel=1}
  instrument.phrase_playback_mode,instrument.phrase_program=1,1
  renoise.Midi={available_output_devices=function()return {'Connected Port'}end}
  local started,detail=start(wide_slide,nil,1,{output_policy='repeat'})
  assert(started,type(detail)=='table' and
    (tostring(detail.code)..': '..tostring(detail.message)) or tostring(detail))
  mutate()
  for _=1,6 do idle:fire() end
  assert(status.status=='suspended' and status.category=='safety'
    and status.code=='safety.target_changed','capability field '..index..' failed to suspend')
  assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],target)
    and target.name==previous_name and song.tool_data==previous_raw,
    'stale target capabilities changed last-good state')
end
print('ACID one-shot gate generation, regeneration and transaction rollback passed (mocked Renoise)')
