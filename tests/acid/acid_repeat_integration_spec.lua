dofile('tests/bootstrap.lua')('acid')
local columns=dofile('tests/acid/phrase_columns.lua')

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
function script:commit()
  local on_idle
  on_idle=function()
    idle:remove_notifier(on_idle)
    committed:fire()
  end
  idle:add_notifier(on_idle)
end
function script:render_to_pattern(options,callback)
  local source=assert(self.paragraphs[1])
  local values=assert(source:match('local values = { (.-) }\nreturn pattern'))
  local phrase=instrument.phrases[#instrument.phrases]
  local total_steps,notes,offs=0,0,0
  for token in (values..','):gmatch('(.-),') do
    local volume=tonumber(token:match('volume = ([%d.]+)'))
    local note=token:match('key = (%d+)')
    if volume then
      phrase.cells[(total_steps-1)*4+1].volume_value=volume==1 and 255 or 89
    end
    if note then
      total_steps=total_steps+1;notes=notes+1
      local line=(total_steps-1)*4+1
      phrase.cells[line].note_value=tonumber(note)
    elseif token:find('"off"',1,true) then
      total_steps=total_steps+1;offs=offs+1
      phrase.cells[(total_steps-1)*4+1].note_value=120
    elseif token:match('^%s*false%s*$') then
      total_steps=total_steps+1
    end
  end
  if options.lpb==12 then
    assert(source:find('unit = "1/8"',1,true) and source:find('resolution = 2/3',1,true))
  else
    assert(options.lpb==16 and source:find('unit = "1/16"',1,true))
  end
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
    return columns.line(self,line)
  end
  function phrase:column_is_muted() return false end
  function phrase:copy_from(other)
    columns.copy(self,other)
    for _,key in ipairs({'number_of_lines','lpb','shuffle','playback_mode','looping',
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

instrument={name="Repeat fixture",phrases={},samples={{sample_buffer={has_sample_data=true}}},plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""},
  phrase_playback_mode=1,phrase_program=3,phrase_editor_visible=false}
function instrument:insert_phrase_at(index)
  assert(index==#self.phrases+1)
  local phrase=make_phrase()
  self.phrases[index]=phrase
  return phrase
end
function instrument:delete_phrase_at(index) table.remove(self.phrases,index) end
local song={instruments={instrument},transport={timing_model=2,groove_enabled=false}}
_G.renoise={
  Transport={TIMING_MODEL_SPEED=1,TIMING_MODEL_LPB=2},
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function() return song end,
  tool=function() return {app_idle_observable=idle} end
}

local writer=require('writers.phrase_writer')
local sequencer=require('model.sequencer')
local store=require('renoise.pattern_store')
local ownership=require('renoise.phrase_ownership')
local pitch=dofile('tests/acid/pitch_fixture.lua')
local messages={}
local function source(length,command)
  local pattern=sequencer.new_pattern(length)
  pattern.pitch_length=32
  for index=1,32 do
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
for _,length in ipairs({1,16,17,32}) do
  local pattern=source(length)
  local physical,layout=assert(writer.plan_output(pattern,'repeat'))
  assert(physical.length==2*length and #physical.steps==2*length)
  assert(layout.looping and layout.loop_start==4*length+1)
  assert(layout.loop_end==8*length+1 and layout.number_of_lines==8*length+1)
  assert(layout.number_of_lines<=257)
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
  assert(phrase.cells[4*length+1].note_value==pattern.pitch_events[1].note)
  assert(phrase.cells[8*length+1].note_value==121,
    'loop sentinel line must remain empty')
  assert(ownership.status(phrase)=='owned')
  local restored,policy=store.load(song,instrument,phrase)
  assert(restored and policy=='repeat')
  assert(restored.length==length and restored.pitch_length==32)
  for index=1,32 do
    assert(restored.pitch_events[index].note==pattern.pitch_events[index].note)
    assert(restored.pitch_events[index].accent==pattern.pitch_events[index].accent)
  end
  for step=1,32 do assert(restored.time_events[step]=='N') end
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
assert(rest_phrase.number_of_lines==137 and rest_phrase.looping)
assert(rest_phrase.loop_start==69 and rest_phrase.loop_end==137)
for line=1,137 do assert(rest_phrase.cells[line].note_value==121) end
local rest_source,rest_policy=store.load(song,instrument,rest_phrase)
assert(rest_source and rest_policy=='repeat' and rest_source.length==17)
for step=1,17 do assert(rest_source.time_events[step]=='R') end
local rest_render=render_calls[#render_calls]
assert(rest_render.steps==34 and rest_render.notes==0 and rest_render.offs==0)

-- Malformed over-limit input is refused before phrase insertion or persistence.
local too_long=source(32)
too_long.length=33
too_long.time_events[33]='N'
local invalid_plan,invalid_reason=writer.plan_output(too_long,'repeat')
assert(not invalid_plan and invalid_reason)
local too_long_store=song.tool_data
local rejected=writer.generate(1,function() end,too_long,#instrument.phrases+1,
  {output_policy='repeat'})
assert(not rejected)
assert(#instrument.phrases==5 and song.tool_data==too_long_store)

-- Repeat and Play Once are phrase-output choices over the same source.
local policy_source=source(4)
policy_source.pitch_length=2
policy_source.pitch_events[1]=pitch(48)
policy_source.pitch_events[2]=pitch(52)
for i,command in ipairs({'N','T','T','R'}) do policy_source.time_events[i]=command end
local function source_copy(input)
  local copy=sequencer.new_pattern(input.length)
  copy.pitch_length=input.pitch_length
  for index=1,32 do
    local pitch=input.pitch_events[index]
    copy.pitch_events[index]={note=pitch.note,key=pitch.key,octave=pitch.octave,
      accent=pitch.accent,slide=pitch.slide}
    copy.time_events[index]=input.time_events[index]
  end
  return copy
end
local function same_source(left,right)
  if left.length~=right.length or left.pitch_length~=right.pitch_length then return false end
  for index=1,32 do
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
local saved_repeat,saved_repeat_policy=store.load(song,instrument,repeated)
assert(saved_repeat_policy=='repeat' and same_source(saved_repeat,original_source))
local one_shot=generate(policy_source,'play_once',policy_target)
assert(not one_shot.looping and ownership.status(one_shot)=='owned')
assert(one_shot.number_of_lines==policy_source.length*4)
assert(one_shot.cells[1].note_value==48 and one_shot.cells[2].note_value==121
  and one_shot.cells[10].note_value==121 and one_shot.cells[13].note_value==120)
local saved_once,saved_once_policy=store.load(song,instrument,one_shot)
assert(saved_once_policy=='play_once' and same_source(saved_once,original_source))
local repeated_again=generate(policy_source,'repeat',policy_target)
local saved_again,saved_again_policy=store.load(song,instrument,repeated_again)
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
assert(slide_phrase.cells[1].note_value==35 and slide_phrase.cells[9].note_value==60)
assert(slide_status.message:find('Articulation approximation:',1,true),
  'slide or connected accent limitations must be reported as nonfatal')

-- Capability inspection is read-only and all target classes receive a native phrase.
local function make_target(samples,plugin,midi)
  local target={phrases={},samples=samples,phrase_playback_mode=1,
    phrase_program=3,phrase_editor_visible=false}
  target.plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0}
  target.midi_output_properties={device_name=""}
  if plugin then target.plugin_properties={plugin_loaded=true,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0} end
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
  assert(phrase:line(1).note_columns[1].note_value==35,
    item.name..' target lost its attack')
  assert(instrument.phrase_playback_mode==before_policy
    and instrument.phrase_program==before_program
    and instrument.phrase_editor_visible==before_editor,
    item.name..' target settings were changed')
  if item.name=='empty' then
    assert(phrase.cells[9].note_value==60)
    assert(status.message:find('silent',1,true), 'empty target must report that playback is silent')
  elseif item.name~='sample' then
    local onset=phrase:line(9).note_columns
    assert(onset[2].note_value==60 and onset[2].delay_value==0,
      'legato target must start in another column before the preceding note ends')
    assert(onset[1].note_value==120 and onset[1].delay_value==1,
      'preceding note must release after the target NOTE')
    assert(phrase:line(13).note_columns[2].note_value==120,
      'REST must release the actual sounding column')
    assert(not phrase.cells[9].effect_number_string,
      item.name..' target received a sample-only glide command')
    assert(status.message:find('Articulation approximation:',1,true),
      item.name..' target did not report reduced glide fidelity')

    -- A connected odd-length loop must preserve voice columns at both seams.
    local connected=source(3)
    connected.pitch_length=3
    for index,note in ipairs({36,39,43}) do
      connected.pitch_events[index]=pitch(note,false,true)
    end
    local looped=generate(connected,'repeat',#instrument.phrases+1,nil,target_instrument)
    assert(looped.visible_note_columns==3)
    local seam=looped:line(looped.loop_start).note_columns
    assert(seam[1].note_value==36 and seam[1].delay_value==0)
    assert(seam[3].note_value==120 and seam[3].delay_value==1,
      'Repeat seam must overlap the first target with the final voice')
    assert(ownership.status(looped)=='owned')

    -- Failure after native mutation cannot damage a sealed destination.
    local emitter=require('writers.legato_writer')
    local original_apply=emitter.apply
    local before_name,before_data=looped.name,song.tool_data
    emitter.apply=function(destination,plan)
      assert(original_apply(destination,plan))
      return nil,'injected legato emission failure'
    end
    local failed
    assert(writer.generate(target_instrument,function(value)failed=value end,
      connected,#instrument.phrases,{output_policy='repeat'}))
    for _=1,6 do idle:fire() end
    emitter.apply=original_apply
    assert(failed.kind=='complete' and failed.status=='error')
    assert(looped.name==before_name and song.tool_data==before_data)
    assert(ownership.status(looped)=='owned' and #instrument.phrases==2,
      'failed multi-column emission must preserve the last-good phrase and source')
  end
end
-- Explicit bend generation commits settings and seals the native MIDI payload.
instrument=targets[1].target
local bend_source=source(4)
bend_source.pitch_length=2
bend_source.pitch_events[1]=pitch(36,false,true)
bend_source.pitch_events[2]=pitch(43,false,false)
for index,command in ipairs({'N','T','N','R'}) do bend_source.time_events[index]=command end
local bend_target=#instrument.phrases+1
local phrase_pitch_bend=require('writers.phrase_pitch_bend')
assert(phrase_pitch_bend.delivery_enabled==true)
phrase_pitch_bend.delivery_enabled=false
local fallback,fallback_status=generate(bend_source,'repeat',bend_target,{pb_range=12},2)
assert(fallback:line(9).note_columns[2].note_value==43,
  'unverified phrase delivery must retain the target NOTE')
assert(fallback_status.message:find('delivery is unavailable',1,true))
local _,_,fallback_range=store.load(song,instrument,fallback)
assert(fallback_range==12,'fallback discarded the selected receiver range')
for line=1,fallback.number_of_lines do
  for _,cell in ipairs(fallback:line(line).note_columns) do
    assert(cell.panning_string~='M1','unverified delivery emitted pitch bend')
  end
end
-- Exercise payload transactions without claiming that mocks validate host delivery.
assert(phrase_pitch_bend.delivery_enabled==false)
phrase_pitch_bend.delivery_enabled=true
local bent,bent_status=generate(bend_source,'repeat',bend_target,{pb_range=12},2)
assert(bent_status.message:find('depends on the receiver and routing',1,true),
  'enabled phrase commands must not imply receiver delivery is verified')
assert(ownership.status(bent)=='owned')
local saved_bend,saved_policy,saved_range=store.load(song,instrument,bent)
assert(saved_policy=='repeat' and saved_range==12 and same_source(saved_bend,bend_source))
assert(saved_bend.pb_range==nil,'render settings leaked into canonical memories')
local command_count,noncenter,center=0,false,false
local first_command_line
for line=1,bent.number_of_lines do
  local native=bent:line(line)
  local carrier=native.note_columns[bent.visible_note_columns]
  if carrier.panning_string=='M1' then
    first_command_line=first_command_line or line
    command_count=command_count+1
    assert(carrier.instrument_value==255,'phrase bend must use the receiver default MIDI channel')
    local effect=native.effect_columns[1]
    local value=tonumber(effect.number_string,16)*128+effect.amount_value
    if value==8192 then center=true else noncenter=true end
  end
end
assert(command_count>2 and noncenter and center,'missing native bend ramp or center reset')
local command=bent:line(first_command_line).effect_columns[1]
local original_amount=command.amount_value
command.amount_value=(original_amount+1)%128
assert(ownership.status(bent)=='modified','M1 payload is absent from the content seal')
command.amount_value=original_amount
assert(ownership.status(bent)=='owned')

local bend_id=ownership.id(bent)
local off=generate(bend_source,'repeat',bend_target,{pb_range=0},2)
assert(off==bent and ownership.id(off)==bend_id and ownership.status(off)=='owned')
local off_source,_,off_range=store.load(song,instrument,off)
assert(off_range==0 and same_source(off_source,bend_source))
assert(off:line(9).note_columns[2].note_value==43,'PB Off lost the overlap route')
bent=generate(bend_source,'repeat',bend_target,{pb_range=12},2)
assert(bent==off and ownership.id(bent)==bend_id)

-- Corrupting a staged MIDI payload must fail verification and preserve last-good output.
local bend_emitter=require('writers.legato_writer')
local original_bend_apply=bend_emitter.apply
local bend_name,bend_data,bend_count=bent.name,song.tool_data,#instrument.phrases
bend_emitter.apply=function(destination,plan)
  local ok,err=original_bend_apply(destination,plan)
  if not ok then return ok,err end
  for line in pairs(plan.midi_commands or {}) do
    local effect=destination:line(line).effect_columns[1]
    effect.amount_value=(effect.amount_value+1)%128
    break
  end
  return true
end
local bend_failure
assert(writer.generate(2,function(value)bend_failure=value end,bend_source,bend_target,
  {output_policy='repeat',pb_range=12}))
for _=1,6 do idle:fire() end
bend_emitter.apply=original_bend_apply
assert(bend_failure.kind=='complete' and bend_failure.status=='error')
assert(bend_failure.message:find('Pitch-bend command mismatch',1,true),bend_failure.message)
assert(#instrument.phrases==bend_count and song.tool_data==bend_data and bent.name==bend_name)
assert(ownership.status(bent)=='owned','corrupted staged M1 damaged the last-good destination')
-- In-flight receiver movement must preserve the last-good phrase.
local reorder_failure
assert(writer.generate(2,function(value)reorder_failure=value end,bend_source,bend_target,
  {output_policy='repeat',pb_range=12}))
song.instruments[1],song.instruments[2]=song.instruments[2],song.instruments[1]
for _=1,6 do idle:fire() end
song.instruments[1],song.instruments[2]=song.instruments[2],song.instruments[1]
assert(reorder_failure and reorder_failure.status=='suspended')
assert(reorder_failure.message:find('target instrument moved',1,true),reorder_failure.message)
assert(#instrument.phrases==bend_count and song.tool_data==bend_data and bent.name==bend_name)
assert(ownership.status(bent)=='owned','instrument reorder damaged the last-good phrase')
phrase_pitch_bend.delivery_enabled=true
instrument=original_instrument
-- An edit saved during asynchronous rendering must not reject the source commit
-- or discard the newer draft that Live Edit will apply next.
local original_render=script.render_to_pattern
local delayed_options,delayed_callback
function script:render_to_pattern(options,callback)
  delayed_options,delayed_callback=options,callback
  return true
end
local render_status
local rendering_source=source(4)
local latest_source=source(5)
local count_before=#instrument.phrases
assert(writer.generate(1,function(value)render_status=value end,rendering_source,1,
  {output_policy='repeat'}))
for _=1,6 do idle:fire() end
assert(delayed_callback,'native render did not start')
dofile("tests/acid/draft_baseline_stub.lua")
local draft_cache=require('runtime.draft_cache')
assert(draft_cache.put(song,instrument,instrument.phrases[1],latest_source,'repeat'))
script.render_to_pattern=original_render
original_render(script,delayed_options,delayed_callback)
assert(render_status.kind=='complete' and
  (render_status.status=='committed' or render_status.status=='approximate'),render_status.message)
assert(store.load(song,instrument,instrument.phrases[1]).length==4)
assert(not draft_cache.get(song,instrument,instrument.phrases[1]),
  'a changed committed baseline cannot restore the newer source edit automatically')
assert(draft_cache.list(song)[1].pattern.length==5,
  'a changed committed baseline preserves the newer source edit for recovery')
assert(#instrument.phrases==count_before and ownership.status(instrument.phrases[1])=='owned',
  'ordinary in-flight editing left a recovery or staging phrase')
-- A transport change while the native renderer runs cannot replace last-good output.
local timing_destination=instrument.phrases[1]
local timing_name,timing_data=timing_destination.name,song.tool_data
delayed_callback=nil
function script:render_to_pattern(options,callback)
  delayed_options,delayed_callback=options,callback
  return true
end
assert(writer.generate(1,function(value)render_status=value end,source(6),1,
  {output_policy='repeat'}))
for _=1,6 do idle:fire() end
assert(delayed_callback,'native render did not start for timing change')
song.transport.timing_model=renoise.Transport.TIMING_MODEL_SPEED
script.render_to_pattern=original_render
original_render(script,delayed_options,delayed_callback)
assert(render_status.status=='suspended' and
  render_status.message:find('unsupported timing',1,true),render_status.message)
assert(instrument.phrases[1]==timing_destination and timing_destination.name==timing_name)
assert(song.tool_data==timing_data and #instrument.phrases==count_before)
assert(ownership.status(timing_destination)=='owned')
assert(song.transport.timing_model==renoise.Transport.TIMING_MODEL_SPEED)
song.transport.timing_model=renoise.Transport.TIMING_MODEL_LPB
print('ACID Repeat end-to-end mocked integration checks passed (playback checked separately in Renoise)')

-- Exercise both pulse modes through rendering and protected replacement.
for _,policy in ipairs({'play_once','repeat'}) do
  for _,length in ipairs({1,9,12,15,16,17,32}) do
    local timed=source(length)
    timed.timing_mode='triplet'
    local target=#instrument.phrases+1
    local output=generate(timed,policy,target)
    assert(output.lpb==(timed.timing_mode=='triplet' and 12 or 16) and output.shuffle==0)
    assert(output.number_of_lines==(policy=='repeat' and 8*length+1 or 4*length))
    assert(store.load(song,instrument,output).timing_mode=='triplet')
    local physical_steps=policy=='repeat' and 2*length or length
    for step=1,physical_steps do
      local start=(step-1)*4+1
      assert(output.cells[start].note_value==timed.pitch_events[(step-1)%length+1].note)
      assert(output.cells[start+1].note_value==121)
      assert(output.cells[start+2].note_value==120)
      assert(output.cells[start+3].note_value==121)
    end
    timed.timing_mode='straight'
    output=generate(timed,policy,target)
    assert(output.lpb==16 and output.shuffle==0 and store.load(song,instrument,output).timing_mode=='straight')
    assert(output.number_of_lines==(policy=='repeat' and 8*length+1 or 4*length))
    for step=1,physical_steps do
      local start=(step-1)*4+1
      assert(output.cells[start].note_value==timed.pitch_events[(step-1)%length+1].note)
      assert(output.cells[start+1].note_value==121)
      assert(output.cells[start+2].note_value==120)
      assert(output.cells[start+3].note_value==121)
    end
  end
end
local saved_data=song.tool_data
local saved_count,saved_renders=#instrument.phrases,#render_calls
local allocate=store.allocate
store.allocate=function() error('unsupported timing must not allocate an ID') end
for _,case in ipairs({{renoise.Transport.TIMING_MODEL_SPEED},{99},{}}) do
  local model=case[1]
  song.transport.timing_model=model
  for _,target in ipairs({1,#instrument.phrases+1}) do
    local started,detail=writer.generate(1,function() error('unexpected status') end,
      source(4),target,{output_policy='repeat'})
    assert(not started and detail.code=='safety.timing_model')
    assert(song.tool_data==saved_data and #instrument.phrases==saved_count)
    assert(#render_calls==saved_renders and song.transport.timing_model==model)
  end
end
local lpb_model=renoise.Transport.TIMING_MODEL_LPB
renoise.Transport.TIMING_MODEL_LPB=nil
song.transport.timing_model=nil
local missing_started,missing_detail=writer.generate(1,function() error('unexpected status') end,
  source(4),#instrument.phrases+1,{output_policy='repeat'})
assert(not missing_started and missing_detail.code=='safety.timing_model')
assert(song.tool_data==saved_data and #instrument.phrases==saved_count and #render_calls==saved_renders)
renoise.Transport.TIMING_MODEL_LPB=lpb_model
store.allocate=allocate
song.transport.timing_model=renoise.Transport.TIMING_MODEL_LPB
song.transport.groove_enabled=true
local _,timing_status=generate(source(4),'repeat',#instrument.phrases+1)
assert(timing_status.message:find('Song groove',1,true))
assert(song.transport.timing_model==renoise.Transport.TIMING_MODEL_LPB and song.transport.groove_enabled)
