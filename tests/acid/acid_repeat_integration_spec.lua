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

instrument={phrases={},samples={{sample_buffer={has_sample_data=true}}}}
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
local messages={}
local function source(length,command)
  local pattern=sequencer.new_pattern(length,'extended')
  pattern.pitch_length=64
  pattern.playback='loop'
  for index=1,64 do
    pattern.pitch_events[index]={note=24+(index-1)%60,accent=index%3==0,slide=false}
  end
  for step=1,length do pattern.time_events[step]=command or 'N' end
  return pattern
end

local function generate(pattern,mode,target_index,options)
  local ok,err=writer.generate(1,function(message) messages[#messages+1]=message end,
    mode or 'baseline',pattern,target_index,options)
  assert(ok,err)
  for _=1,6 do idle:fire() end
  local status=messages[#messages]
  assert(status and status:find('generated',1,true),status)
  assert(status:find('\nRepeat baseline renders NOTE/TIE/REST.',1,true),
    'repeat verification status must use a real line break')
  assert(not status:find('\\nRepeat baseline renders',1,true),
    'repeat status must not display an escaped newline literally')
  return instrument.phrases[target_index],status
end

-- End-to-end source -> cycle plan -> pattrns render -> native phrase layout ->
-- ownership seal and transaction -> exact source round-trip at all grid lengths.
for _,length in ipairs({1,16,17,32,33,48,49,64}) do
  local pattern=source(length)
  local physical,layout=assert(writer.plan_repeat(pattern))
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
  local phrase=generate(pattern,'baseline',target)
  assert(phrase.number_of_lines==layout.number_of_lines)
  assert(phrase.looping and phrase.loop_start==layout.loop_start)
  assert(phrase.loop_end==layout.loop_end)
  assert(phrase.playback_mode==renoise.InstrumentPhrase.PLAY_PATTERN)
  assert(phrase.cells[1].note_value==pattern.pitch_events[1].note)
  assert(phrase.cells[2*length+1].note_value==pattern.pitch_events[1].note)
  assert(phrase.cells[4*length+1].note_value==121,
    'loop sentinel line must remain empty')
  assert(ownership.status(phrase)=='owned')
  local restored,mode=assert(store.load(song,phrase))
  assert(mode=='baseline' and restored.playback=='loop')
  assert(restored.length==length and restored.pitch_length==64)
  for index=1,64 do
    assert(restored.pitch_events[index].note==pattern.pitch_events[index].note)
    assert(restored.pitch_events[index].accent==pattern.pitch_events[index].accent)
  end
  for step=1,length do assert(restored.time_events[step]=='N') end
  local render=render_calls[#render_calls]
  assert(render.max_events==2*length+8 and render.steps==2*length)
  assert(render.notes==2*length and render.offs==0)
end

-- Mixed source semantics are carried across both the cold and steady cycle.
local mixed=source(4)
mixed.pitch_length=3
mixed.time_events={'N','T','N','R'}
mixed.pitch_events[1]={note=36,accent=false,slide=false}
mixed.pitch_events[2]={note=43,accent=false,slide=false}
mixed.pitch_events[3]={note=40,accent=false,slide=false}
local physical=assert(writer.plan_repeat(mixed))
assert(physical.steps[1].kind=='note' and physical.steps[2].kind=='tie')
assert(physical.steps[4].kind=='rest' and physical.steps[4].releases)
assert(physical.steps[5].kind=='note' and physical.steps[5].cycle==2)
assert(physical.steps[6].kind=='tie' and physical.steps[6].note==36)
assert(physical.steps[8].kind=='rest' and physical.steps[8].releases)

-- Zero-event cycles still complete, commit source, and leave every line empty.
local rests=source(17,'R')
local rest_phrase=generate(rests,'baseline',#instrument.phrases+1)
assert(rest_phrase.number_of_lines==69 and rest_phrase.looping)
assert(rest_phrase.loop_start==35 and rest_phrase.loop_end==69)
for line=1,69 do assert(rest_phrase.cells[line].note_value==121) end
local rest_source,rest_mode=assert(store.load(song,rest_phrase))
assert(rest_mode=='baseline' and rest_source.length==17)
for step=1,17 do assert(rest_source.time_events[step]=='R') end
local rest_render=render_calls[#render_calls]
assert(rest_render.steps==34 and rest_render.notes==0 and rest_render.offs==0)

-- Malformed over-limit input is refused before phrase insertion or persistence.
local too_long=source(64)
too_long.length=65
too_long.time_events[65]='N'
local invalid_plan,invalid_reason=writer.plan_repeat(too_long)
assert(not invalid_plan and invalid_reason)
local too_long_store=song.tool_data
local rejected=writer.generate(1,function() end,'baseline',too_long,#instrument.phrases+1)
assert(not rejected)
assert(#instrument.phrases==9 and song.tool_data==too_long_store)

-- Unsafe slide seams and nonbaseline Repeat modes fail with useful locations.
local slide=source(16)
slide.pitch_events[1].slide=true
local accepted,diagnostic=writer.generate(1,function() end,'baseline',slide,#instrument.phrases+1)
assert(not accepted and diagnostic:find('slide continuity is unverified',1,true))
assert(diagnostic:find('TIME step',1,true) and diagnostic:find('phrase line',1,true))
local nonbaseline,mode_diagnostic=writer.generate(1,function() end,'retrigger',source(16),
  #instrument.phrases+1)
assert(not nonbaseline and mode_diagnostic:find("audio mode 'retrigger' is unverified",1,true))
assert(mode_diagnostic:find('TIME step',1,true) and mode_diagnostic:find('phrase line',1,true))

-- Reference eligibility gates the real transactional Repeat path before mutation.
local profiles=require('renoise.articulation_profile')
local original_check=profiles.check
local original_transport=song.transport
local original_program=instrument.phrase_playback_mode
local profile_checks=0
profiles.check=function(candidate,name,options)
  profile_checks=profile_checks+1
  assert(candidate==instrument and name=='reference_diagnostic' and options.fade_amount>765)
  return {profile=name}
end
song.transport={bpm=120,lpb=8,tpl=12,groove_enabled=false}
instrument.phrase_playback_mode=renoise.Instrument.PHRASES_PLAY_SELECTIVE
local gate_source=source(2)
gate_source.pitch_length=1;gate_source.pitch_events[1]={note=48,accent=false,slide=false}
gate_source.time_events={'N','R'}
local target=#instrument.phrases+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'retrigger',gate_source,target))
for _=1,6 do idle:fire() end
local gated=instrument.phrases[target]
assert(gated and ownership.status(gated)=='owned' and gated.looping)
assert(gated.cells[3].note_value==120 and gated.cells[7].note_value==120)
assert(gated.cells[9].note_value==121 and profile_checks==2)
local connected=source(4)
connected.pitch_length=1
connected.pitch_events[1]={note=48,accent=false,slide=true}
local connected_target=#instrument.phrases+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',connected,connected_target))
for _=1,6 do idle:fire() end
local connected_phrase=instrument.phrases[connected_target]
assert(connected_phrase and ownership.status(connected_phrase)=='owned')
assert(connected_phrase.cells[3].effect_number_string=='0G')
assert(connected_phrase.cells[17].note_value==121)
local moving=source(8);moving.pitch_length=2
moving.pitch_events[1]={note=48,accent=false,slide=true}
moving.pitch_events[2]={note=52,accent=false,slide=true}
moving.time_events={'N','T','T','T','N','T','T','T'}
local moving_target=#instrument.phrases+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',moving,moving_target))
for _=1,6 do idle:fire() end
local moving_phrase=instrument.phrases[moving_target]
assert(moving_phrase and ownership.status(moving_phrase)=='owned')
assert(moving_phrase.cells[9].effect_number_string=='0G' and
 moving_phrase.cells[9].effect_amount_value==0x20)
assert(moving_phrase.cells[10].effect_number_string=='0G' and
 moving_phrase.cells[10].effect_amount_value==0)
assert(moving_phrase.cells[17].effect_number_string=='0G' and
 moving_phrase.cells[25].effect_number_string=='0G',
 'cold and steady slide targets both receive writer commands')
assert(profile_checks==6,'moving Repeat support context is rechecked before commit')

for _,tempo in ipairs({90,150}) do
 song.transport.bpm=tempo
 for _,case in ipairs({{8,52},{8,60},{9,52},{9,60}}) do
  local length,note=case[1],case[2]
  local candidate=source(length);candidate.pitch_length=2
  candidate.pitch_events[1]={note=48,accent=false,slide=true}
  candidate.pitch_events[2]={note=note,accent=false,slide=true}
  candidate.time_events=length==8 and {'N','T','T','T','N','T','T','T'}
   or {'N','T','T','T','N','T','T','T','T'}
  local target_index=#instrument.phrases+1
  assert(writer.generate(1,function(message)messages[#messages+1]=message end,
   'slide',candidate,target_index))
  for _=1,6 do idle:fire() end
  local phrase=instrument.phrases[target_index]
  assert(phrase and ownership.status(phrase)=='owned'
   and phrase.number_of_lines==length*4+1
   and phrase.loop_start==length*2+1 and phrase.loop_end==length*4+1,
   'the exact moving-slide layout should provisionally render at BPM '..tempo)
 end
 local same_pitch=source(16);same_pitch.pitch_length=1
 same_pitch.pitch_events[1]={note=48,accent=false,slide=true}
 same_pitch.time_events[1]='N'
 for step=2,16 do same_pitch.time_events[step]='T' end
 local same_pitch_target=#instrument.phrases+1
 assert(writer.generate(1,function(message)messages[#messages+1]=message end,
  'slide',same_pitch,same_pitch_target))
 for _=1,6 do idle:fire() end
 local same_pitch_phrase=instrument.phrases[same_pitch_target]
 assert(same_pitch_phrase and ownership.status(same_pitch_phrase)=='owned'
  and same_pitch_phrase.number_of_lines==65
  and same_pitch_phrase.loop_start==33 and same_pitch_phrase.loop_end==65,
  'the captured 16-step same-pitch slide should provisionally render at BPM '..tempo)
 local unsupported_same_pitch=source(4);unsupported_same_pitch.pitch_length=1
 unsupported_same_pitch.pitch_events[1]={note=48,accent=false,slide=true}
 local same_pitch_count=#instrument.phrases
 local same_pitch_started,same_pitch_error=writer.generate(1,function()end,
  'slide',unsupported_same_pitch,same_pitch_count+1)
 assert(not same_pitch_started and #instrument.phrases==same_pitch_count
  and same_pitch_error:find('slide continuity is unverified',1,true),
  'only the captured 16-step same-pitch layout is eligible at 90/150 BPM')
end
song.transport.bpm=120

local octave=source(8);octave.pitch_length=2
octave.pitch_events[1]={note=48,accent=false,slide=true}
octave.pitch_events[2]={note=60,accent=false,slide=true}
octave.time_events={'N','T','T','T','N','T','T','T'}
local octave_target=#instrument.phrases+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',octave,octave_target))
for _=1,6 do idle:fire() end
local octave_phrase=instrument.phrases[octave_target]
assert(octave_phrase and ownership.status(octave_phrase)=='owned')
for line=9,14 do
  assert(octave_phrase.cells[line].effect_number_string=='0G' and
    octave_phrase.cells[line].effect_amount_value==(line==9 and 0x20 or 0),
    'octave glide command coverage must span six lines')
end
assert(octave_phrase.cells[17].effect_number_string=='0G' and
  octave_phrase.cells[22].effect_number_string=='0G')

local tail_hold=source(9);tail_hold.pitch_length=2
tail_hold.pitch_events[1]={note=48,accent=false,slide=true}
tail_hold.pitch_events[2]={note=52,accent=false,slide=true}
tail_hold.time_events={'N','T','T','T','N','T','T','T','T'}
local tail_hold_target=#instrument.phrases+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',tail_hold,tail_hold_target))
for _=1,6 do idle:fire() end
local tail_hold_phrase=instrument.phrases[tail_hold_target]
assert(tail_hold_phrase and ownership.status(tail_hold_phrase)=='owned')
assert(tail_hold_phrase.number_of_lines==37 and tail_hold_phrase.loop_start==19
  and tail_hold_phrase.loop_end==37)
assert(tail_hold_phrase.cells[9].effect_number_string=='0G'
  and tail_hold_phrase.cells[19].effect_number_string=='0G'
  and tail_hold_phrase.cells[27].effect_number_string=='0G',
  'the trailing-TIE extension must preserve cold and steady glide commands')

tail_hold.pitch_events[2].note=60
local octave_tail_target=#instrument.phrases+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',tail_hold,octave_tail_target))
for _=1,6 do idle:fire() end
local octave_tail_phrase=instrument.phrases[octave_tail_target]
assert(octave_tail_phrase and ownership.status(octave_tail_phrase)=='owned')
assert(octave_tail_phrase.number_of_lines==37 and octave_tail_phrase.loop_start==19
  and octave_tail_phrase.loop_end==37)
for _,line in ipairs({9,19,27}) do
  assert(octave_tail_phrase.cells[line].effect_number_string=='0G'
    and octave_tail_phrase.cells[line].effect_amount_value==0x20,
    string.format('octave tie-tail command mismatch at line %d: %s %s',line,
      tostring(octave_tail_phrase.cells[line].effect_number_string),
      tostring(octave_tail_phrase.cells[line].effect_amount_value)))
end

local interrupted=source(8);interrupted.playback='one_shot';interrupted.pitch_length=2
interrupted.pitch_events[1]={note=48,accent=false,slide=true}
interrupted.pitch_events[2]={note=52,accent=false,slide=true}
interrupted.time_events={'N','T','N','T','R','N','T','T'}
local interrupted_target=#instrument.phrases+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',interrupted,interrupted_target))
for _=1,6 do idle:fire() end
local interrupted_phrase=instrument.phrases[interrupted_target]
assert(interrupted_phrase and ownership.status(interrupted_phrase)=='owned')
assert(interrupted_phrase.cells[5].effect_number_string=='0G')
assert(interrupted_phrase.cells[9].note_value==120 and
 interrupted_phrase.cells[11].note_value==48 and
 interrupted_phrase.cells[11].effect_number_value==0,
 'REST must cancel its outgoing slide before the next fresh NOTE')

local function refuses_without_phrase(pattern)
 local count=#instrument.phrases
 local stored=song.tool_data
 local started,why=writer.generate(1,function()end,'slide',pattern,count+1)
 assert(not started and #instrument.phrases==count and song.tool_data==stored,why)
 return why
end
local unsupported=source(8);unsupported.pitch_length=2
unsupported.pitch_events[1]={note=48,accent=false,slide=true}
unsupported.pitch_events[2]={note=53,accent=false,slide=true}
unsupported.time_events={'N','T','T','T','N','T','T','T'}
assert(refuses_without_phrase(unsupported):find('outside the tested 0/±4/±12 set',1,true))
unsupported.pitch_events[2].note=52;unsupported.pitch_events[2].accent=true
assert(refuses_without_phrase(unsupported):find('accented notes are outside',1,true))
local short_hold=source(4);short_hold.pitch_length=2
short_hold.pitch_events[1]={note=48,accent=false,slide=true}
short_hold.pitch_events[2]={note=60,accent=false,slide=true}
short_hold.time_events={'N','T','N','T'}
assert(refuses_without_phrase(short_hold):find('only the tested 8-step',1,true))
local short_four=source(8);short_four.pitch_length=3
short_four.pitch_events[1]={note=48,accent=false,slide=true}
short_four.pitch_events[2]={note=52,accent=false,slide=true}
short_four.pitch_events[3]={note=48,accent=false,slide=true}
short_four.time_events={'N','N','N','T','T','T','T','T'}
assert(refuses_without_phrase(short_four):find('only the tested 8-step',1,true),
 'moving slides outside the captured step layout stay refused')
local short_octave=source(8);short_octave.pitch_length=3
short_octave.pitch_events[1]={note=48,accent=false,slide=true}
short_octave.pitch_events[2]={note=60,accent=false,slide=true}
short_octave.pitch_events[3]={note=48,accent=false,slide=true}
short_octave.time_events={'N','T','N','T','T','N','T','T'}
assert(refuses_without_phrase(short_octave):find('only the tested 8-step',1,true),
 'octave glides without the captured command and settle span stay refused')
local one_shot_accent=source(4);one_shot_accent.playback='one_shot'
one_shot_accent.pitch_length=2
one_shot_accent.pitch_events[1]={note=48,accent=false,slide=true}
one_shot_accent.pitch_events[2]={note=52,accent=true,slide=false}
one_shot_accent.time_events={'N','N','T','R'}
local accent_count=#instrument.phrases
local accent_store=song.tool_data
local accent_started,accent_error=writer.generate(1,function()end,'slide',
 one_shot_accent,accent_count+1)
assert(not accent_started and #instrument.phrases==accent_count and song.tool_data==accent_store)
assert(accent_error:find('connected accent volume changes are unverified',1,true),accent_error)
local held_source_accent=source(4);held_source_accent.playback='one_shot'
held_source_accent.pitch_length=2
held_source_accent.pitch_events[1]={note=48,accent=true,slide=true}
held_source_accent.pitch_events[2]={note=52,accent=false,slide=true}
held_source_accent.time_events={'N','T','N','T'}
assert(refuses_without_phrase(held_source_accent):find(
 'connected accent volume changes are unverified',1,true),
 'an accent held through TIEs must be refused before a connected slide')
local one_shot_source_accent=source(4);one_shot_source_accent.playback='one_shot'
one_shot_source_accent.pitch_length=2
one_shot_source_accent.pitch_events[1]={note=48,accent=true,slide=true}
one_shot_source_accent.pitch_events[2]={note=52,accent=false,slide=false}
one_shot_source_accent.time_events={'N','N','T','R'}
assert(refuses_without_phrase(one_shot_source_accent):find(
 'connected accent volume changes are unverified',1,true))
for _,tempo in ipairs({90,150}) do
 song.transport.bpm=tempo
 local target_index=#instrument.phrases+1
 assert(writer.generate(1,function(message)messages[#messages+1]=message end,
  'retrigger',gate_source,target_index))
 for _=1,6 do idle:fire() end
 assert(instrument.phrases[target_index]
  and ownership.status(instrument.phrases[target_index])=='owned',
  'Repeat Retrigger should provisionally accept the exact 90/150 BPM profile')
end
song.transport.bpm=120
profiles.check=function()return nil,'mismatched profile' end
assert(not writer.generate(1,function()end,'retrigger',gate_source,#instrument.phrases+1))
local tempo_checked=0
profiles.check=function(candidate,name)
 tempo_checked=tempo_checked+1
 assert(candidate==instrument and name=='reference_diagnostic')
 return {profile=name}
end
local tempo_count,tempo_store=#instrument.phrases,song.tool_data
local tempo_target=tempo_count+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'retrigger',gate_source,tempo_target))
song.transport.bpm=91
for _=1,6 do idle:fire() end
assert(tempo_checked==1 and #instrument.phrases==tempo_count
 and song.tool_data==tempo_store and not instrument.phrases[tempo_target],
 string.format('tempo change guard failed: checks=%d phrases=%d/%d store_same=%s target=%s',
  tempo_checked,#instrument.phrases,tempo_count,tostring(song.tool_data==tempo_store),
  tostring(instrument.phrases[tempo_target])))
assert(messages[#messages]:find('GENERATION FAILED',1,true))
song.transport.bpm=120
tempo_checked=0
song.transport.bpm=150
local slide_tempo_count,slide_tempo_store=#instrument.phrases,song.tool_data
local slide_tempo_target=slide_tempo_count+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',moving,slide_tempo_target))
song.transport.bpm=91
for _=1,6 do idle:fire() end
assert(tempo_checked==1 and #instrument.phrases==slide_tempo_count
 and song.tool_data==slide_tempo_store and not instrument.phrases[slide_tempo_target],
 'moving slides must recheck their tempo profile before phrase/source commit')
assert(messages[#messages]:find('GENERATION FAILED',1,true))
song.transport.bpm=120
tempo_checked=0
song.transport.bpm=150
local same_pitch_tempo=source(16);same_pitch_tempo.pitch_length=1
same_pitch_tempo.pitch_events[1]={note=48,accent=false,slide=true}
same_pitch_tempo.time_events[1]='N'
for step=2,16 do same_pitch_tempo.time_events[step]='T' end
local same_pitch_tempo_count,same_pitch_tempo_store=#instrument.phrases,song.tool_data
local same_pitch_tempo_target=same_pitch_tempo_count+1
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'slide',same_pitch_tempo,same_pitch_tempo_target))
song.transport.bpm=91
for _=1,6 do idle:fire() end
assert(tempo_checked==1 and #instrument.phrases==same_pitch_tempo_count
 and song.tool_data==same_pitch_tempo_store and not instrument.phrases[same_pitch_tempo_target],
 'same-pitch tempo changes must abort before phrase/source commit')
assert(messages[#messages]:find('GENERATION FAILED',1,true))
song.transport.bpm=120
local checked=0
profiles.check=function()
 checked=checked+1
 if checked==1 then return {profile='reference_diagnostic'} end
 return nil,'profile changed during rendering'
end
local unchanged_count,unchanged_store=#instrument.phrases,song.tool_data
assert(writer.generate(1,function(message)messages[#messages+1]=message end,
 'retrigger',gate_source,unchanged_count+1))
for _=1,6 do idle:fire() end
assert(checked==2 and #instrument.phrases==unchanged_count and song.tool_data==unchanged_store)
assert(messages[#messages]:find('GENERATION FAILED',1,true))
profiles.check=original_check;song.transport=original_transport
instrument.phrase_playback_mode=original_program
-- If invalidated while rendering is pending, the phrase and store both remain
-- unchanged and the staging phrase is removed after the delayed callback.
local delayed=source(16)
local original_render=script.render_to_pattern
local pending_render
function script:render_to_pattern(_,callback) pending_render=callback;return true end
local stale={valid=true,is_current=function(self) return self.valid end}
local old_count,old_store=#instrument.phrases,song.tool_data
assert(writer.generate(1,function(message) messages[#messages+1]=message end,
  'baseline',delayed,#instrument.phrases+1,{token=stale}))
for _=1,6 do idle:fire() end
assert(type(pending_render)=='function')
stale.valid=false
pending_render(nil,32,0)
assert(#instrument.phrases==old_count and song.tool_data==old_store)
assert(messages[#messages]:find('generation was invalidated',1,true))
script.render_to_pattern=original_render

print('ACID Repeat end-to-end mocked integration checks passed (playback checked separately in Renoise)')
