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
  assert(status:find('\nRepeat uses baseline NOTE/TIE/REST;',1,true),
    'repeat verification status must use a real line break')
  assert(not status:find('\\nRepeat uses baseline',1,true),
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
