dofile('tests/bootstrap.lua')('acid')

local idle_handlers={}
local committed_handlers={}
local function observable(handlers)
  return {
    add_notifier=function(_,callback) handlers[callback]=true end,
    remove_notifier=function(_,callback) handlers[callback]=nil end,
    fire=function()
      local pending={}
      for callback in pairs(handlers) do pending[#pending+1]=callback end
      for _,callback in ipairs(pending) do callback() end
    end
  }
end
local idle,committed=observable(idle_handlers),observable(committed_handlers)
local instrument
local render_calls={}
local script={paragraphs={},compile_error='',runtime_error='',
  committed_observable=committed}
function script:commit() committed:fire() end
function script:render_to_pattern(options,callback)
  local source=assert(self.paragraphs[1])
  local values=assert(source:match('local values = { (.-) }\nreturn pattern'))
  local phrase=instrument.phrases[#instrument.phrases]
  local total_steps,notes,offs=0,0,0
  for token in (values..','):gmatch('(.-),') do
    local volume=tonumber(token:match('volume = ([%d.]+)'))
    if volume then
      phrase.cells[(total_steps-1)*2+1].volume_value=volume==1 and 255 or 89
    end
    local note=token:match('key = (%d+)')
    if note then
      total_steps=total_steps+1;notes=notes+1
      phrase.cells[(total_steps-1)*2+1].note_value=tonumber(note)
    elseif token:find('"off"',1,true) then
      total_steps=total_steps+1;offs=offs+1
      phrase.cells[(total_steps-1)*2+1].note_value=120
    elseif token:match('^%s*false%s*$') then
      total_steps=total_steps+1
    end
  end
  assert(options.lpb==8)
  assert(options.max_events==total_steps+8)
  render_calls[#render_calls+1]={max_events=options.max_events,steps=total_steps,
    notes=notes,offs=offs}
  callback(nil,notes+offs,0)
  return true
end

local function make_phrase()
  local phrase={script=script,name='',number_of_lines=16,visible_note_columns=1,
    visible_effect_columns=0,loop_start=1,loop_end=16,looping=false,
    instrument_column_visible=false,volume_column_visible=false,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,cells={}}
  local function blank()
    return {note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  for line=1,513 do phrase.cells[line]=blank() end
  function phrase:line(line)
    if not self.cells[line] then return nil end
    return {note_columns={self.cells[line]},effect_columns={}}
  end
  function phrase:column_is_muted() return false end
  function phrase:copy_from(other)
    for _,key in ipairs({'number_of_lines','lpb','playback_mode','looping',
      'loop_start','loop_end','key_tracking','name','visible_note_columns',
      'visible_effect_columns','instrument_column_visible',
      'volume_column_visible','panning_column_visible','delay_column_visible',
      'sample_effects_column_visible'}) do self[key]=other[key] end
    self.cells={}
    for line=1,513 do
      self.cells[line]={}
      for key,value in pairs(other.cells[line]) do self.cells[line][key]=value end
    end
  end
  return phrase
end

instrument={phrases={},samples={{sample_buffer={has_sample_data=true}}},
  phrase_playback_mode=1,phrase_program=3,phrase_editor_visible=false}
function instrument:insert_phrase_at(index)
  assert(index==#self.phrases+1)
  local phrase=make_phrase()
  self.phrases[index]=phrase
  return phrase
end
function instrument:delete_phrase_at(index) table.remove(self.phrases,index) end
local song={instruments={instrument}}
_G.renoise={
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function() return song end,
  tool=function() return {app_idle_observable=idle} end
}

local writer=require('writers.phrase_writer')
local sequencer=require('model.sequencer')
local store=require('model.pattern_store')
local ownership=require('writers.phrase_ownership')
local pitch=dofile('tests/acid/pitch_fixture.lua')
local messages={}
local function source(length,command)
  local pattern=sequencer.new_pattern(length)
  pattern.pitch_length=64
  for index=1,64 do
    pattern.pitch_events[index]=pitch(24+(index-1)%37,index%3==0,false)
  end
  for step=1,length do pattern.time_events[step]=command or 'N' end
  return pattern
end

local function generate(pattern,policy,target_index,options,instrument_index)
  options=options or {}
  if policy~=nil then options.output_policy=policy end
  local ok,err=writer.generate(instrument_index or 1,function(value) messages[#messages+1]=value end,
    pattern,target_index,options)
  assert(ok,err)
  for _=1,6 do idle:fire() end
  local status=messages[#messages]
  assert(type(status)=='table' and status.kind=='complete', 'missing typed terminal result')
  assert(status.status=='committed' or status.status=='approximate',status.message)
  assert(status.message and status.message:find('generated',1,true),status.message)
  return instrument.phrases[target_index],status
end

-- End-to-end source -> cycle plan -> pattrns render -> native phrase layout ->
-- ownership seal and transaction -> exact source round-trip at all grid lengths.
for _,length in ipairs({1,16,17,32,33,48,49,64}) do
  local pattern=source(length)
  local physical,layout=assert(writer.plan_output(pattern,'repeat'))
  assert(physical.length==2*length and #physical.steps==2*length)
  assert(layout.looping and layout.loop_start==2*length+1)
  assert(layout.loop_end==4*length+1 and layout.number_of_lines==4*length+1)
  assert(layout.number_of_lines<=512)
  for step=1,length do
    local cold,steady=physical.steps[step],physical.steps[length+step]
    assert(cold.cycle==1 and steady.cycle==2)
    assert(cold.source_step==step and steady.source_step==step)
    assert(cold.note==pattern.pitch_events[step].note)
    assert(steady.note==pattern.pitch_events[step].note)
  end

  local target=#instrument.phrases+1
  local phrase=generate(pattern,nil,target)
  assert(phrase.number_of_lines==layout.number_of_lines)
  assert(phrase.looping and phrase.loop_start==layout.loop_start)
  assert(phrase.loop_end==layout.loop_end)
  assert(phrase.playback_mode==renoise.InstrumentPhrase.PLAY_PATTERN)
  assert(phrase.cells[1].note_value==pattern.pitch_events[1].note)
  assert(phrase.cells[2*length+1].note_value==pattern.pitch_events[1].note)
  assert(phrase.cells[4*length+1].note_value==121,
    'loop sentinel line must remain empty')
  assert(ownership.status(phrase)=='owned')
  local restored,policy=store.load(song,phrase)
  assert(restored and policy=='repeat')
  assert(restored.length==length and restored.pitch_length==64)
  for index=1,64 do
    assert(restored.pitch_events[index].note==pattern.pitch_events[index].note)
    assert(restored.pitch_events[index].accent==pattern.pitch_events[index].accent)
  end
  for step=1,64 do assert(restored.time_events[step]=='N') end
  assert(instrument.phrase_playback_mode==1 and instrument.phrase_program==3
    and instrument.phrase_editor_visible==false,
    'phrase generation changed instrument-wide trigger settings')
  local render=render_calls[#render_calls]
  assert(render.max_events==2*length+8 and render.steps==2*length)
  assert(render.notes==2*length and render.offs==0)
end

-- Mixed source semantics are carried across both the cold and steady cycle.
local mixed=source(4)
mixed.pitch_length=3
for i,command in ipairs({'N','T','N','R'}) do mixed.time_events[i]=command end
mixed.pitch_events[1]=pitch(36)
mixed.pitch_events[2]=pitch(43)
mixed.pitch_events[3]=pitch(40)
local physical=assert(writer.plan_output(mixed,'repeat'))
assert(physical.steps[1].kind=='note' and physical.steps[2].kind=='tie')
assert(physical.steps[4].kind=='rest' and physical.steps[4].releases)
assert(physical.steps[5].kind=='note' and physical.steps[5].cycle==2)
assert(physical.steps[6].kind=='tie' and physical.steps[6].note==36)
assert(physical.steps[8].kind=='rest' and physical.steps[8].releases)

-- Zero-event cycles still complete, commit source, and leave every line empty.
local rests=source(17,'R')
local rest_phrase=generate(rests,'repeat',#instrument.phrases+1)
assert(rest_phrase.number_of_lines==69 and rest_phrase.looping)
assert(rest_phrase.loop_start==35 and rest_phrase.loop_end==69)
for line=1,69 do assert(rest_phrase.cells[line].note_value==121) end
local rest_source,rest_policy=store.load(song,rest_phrase)
assert(rest_source and rest_policy=='repeat' and rest_source.length==17)
for step=1,17 do assert(rest_source.time_events[step]=='R') end
local rest_render=render_calls[#render_calls]
assert(rest_render.steps==34 and rest_render.notes==0 and rest_render.offs==0)

-- Malformed over-limit input is refused before phrase insertion or persistence.
local too_long=source(64)
too_long.length=65
too_long.time_events[65]='N'
local invalid_plan,invalid_reason=writer.plan_output(too_long,'repeat')
assert(not invalid_plan and invalid_reason)
local too_long_store=song.tool_data
local rejected=writer.generate(1,function() end,too_long,#instrument.phrases+1,
  {output_policy='repeat'})
assert(not rejected)
assert(#instrument.phrases==9 and song.tool_data==too_long_store)

-- Repeat and Play Once are phrase-output choices over the same source.
local policy_source=source(4)
policy_source.pitch_length=2
policy_source.pitch_events[1]=pitch(48)
policy_source.pitch_events[2]=pitch(52)
for i,command in ipairs({'N','T','T','R'}) do policy_source.time_events[i]=command end
local function source_copy(input)
  local copy=sequencer.new_pattern(input.length)
  copy.pitch_length=input.pitch_length
  for index=1,64 do
    local pitch=input.pitch_events[index]
    copy.pitch_events[index]={note=pitch.note,key=pitch.key,octave=pitch.octave,
      accent=pitch.accent,slide=pitch.slide}
    copy.time_events[index]=input.time_events[index]
  end
  return copy
end
local function same_source(left,right)
  if left.length~=right.length or left.pitch_length~=right.pitch_length then return false end
  for index=1,64 do
    local a,b=left.pitch_events[index],right.pitch_events[index]
    if a.note~=b.note or a.key~=b.key or a.octave~=b.octave or
        a.accent~=b.accent or a.slide~=b.slide then return false end
    if left.time_events[index]~=right.time_events[index] then return false end
  end
  return true
end
local original_source=source_copy(policy_source)
local policy_target=#instrument.phrases+1
local repeated=generate(policy_source,'repeat',policy_target)
assert(repeated.looping and ownership.status(repeated)=='owned')
local saved_repeat,saved_repeat_policy=store.load(song,repeated)
assert(saved_repeat_policy=='repeat' and same_source(saved_repeat,original_source))
local one_shot=generate(policy_source,'play_once',policy_target)
assert(not one_shot.looping and ownership.status(one_shot)=='owned')
assert(one_shot.number_of_lines==policy_source.length*2)
assert(one_shot.cells[1].note_value==48 and one_shot.cells[2].note_value==121
  and one_shot.cells[6].note_value==121 and one_shot.cells[7].note_value==120)
local saved_once,saved_once_policy=store.load(song,one_shot)
assert(saved_once_policy=='play_once' and same_source(saved_once,original_source))
local repeated_again=generate(policy_source,'repeat',policy_target)
local saved_again,saved_again_policy=store.load(song,repeated_again)
assert(repeated_again.looping and saved_again_policy=='repeat'
  and same_source(saved_again,original_source))
assert(instrument.phrase_playback_mode==1 and instrument.phrase_program==3
  and instrument.phrase_editor_visible==false,
  'changing phrase output policy changed instrument-wide trigger settings')

-- Large slides and connected accent changes commit ordered phrase events with a warning.
local slide=source(4)
slide.pitch_length=2
slide.pitch_events[1]=pitch(35,false,true)
slide.pitch_events[2]=pitch(60,true,false)
for i,command in ipairs({'N','T','N','R'}) do slide.time_events[i]=command end
local slide_target=#instrument.phrases+1
local slide_phrase,slide_status=generate(slide,'repeat',slide_target)
assert(ownership.status(slide_phrase)=='owned')
assert(slide_phrase.cells[1].note_value==35 and slide_phrase.cells[5].note_value==60)
assert(slide_status.message:find('Articulation approximation:',1,true),
  'slide or connected accent limitations must be reported as nonfatal')

-- Capability inspection is read-only and all target classes receive a native phrase.
local function make_target(samples,plugin,midi)
  local target={phrases={},samples=samples,phrase_playback_mode=1,
    phrase_program=3,phrase_editor_visible=false}
  if plugin then target.plugin_properties={plugin_loaded=true} end
  if midi then target.midi_output_properties={device_name='MIDI Device'} end
  target.insert_phrase_at=instrument.insert_phrase_at
  target.delete_phrase_at=instrument.delete_phrase_at
  return target
end
local original_instrument=instrument
local targets={
  {name='plugin-only',target=make_target({},true,false)},
  {name='MIDI-only',target=make_target({},false,true)},
  {name='empty',target=make_target({},false,false)}
}
for _,item in ipairs(targets) do
  local target_instrument=#song.instruments+1
  song.instruments[target_instrument]=item.target
  instrument=item.target
  local before_policy,before_program,before_editor=instrument.phrase_playback_mode,
    instrument.phrase_program,instrument.phrase_editor_visible
  local target_source=source_copy(slide)
  local target_index=#instrument.phrases+1
  local phrase,status=generate(target_source,'repeat',target_index,nil,target_instrument)
  assert(phrase and ownership.status(phrase)=='owned',item.name..' target did not commit')
  assert(phrase.cells[1].note_value==35 and phrase.cells[5].note_value==60,
    item.name..' target lost ordered note events')
  assert(instrument.phrase_playback_mode==before_policy
    and instrument.phrase_program==before_program
    and instrument.phrase_editor_visible==before_editor,
    item.name..' target settings were changed')
  if item.name=='empty' then
    assert(status.message:find('silent',1,true), 'empty target must report that playback is silent')
  elseif item.name~='sample' then
    assert(not phrase.cells[5].effect_number_string,
      item.name..' target received a sample-only glide command')
    assert(status.message:find('Articulation approximation:',1,true),
      item.name..' target did not report reduced glide fidelity')
  end
end
instrument=original_instrument
print('ACID Repeat end-to-end mocked integration checks passed (playback checked separately in Renoise)')
