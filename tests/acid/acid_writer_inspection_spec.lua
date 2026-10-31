-- Verify synchronous writer mutation, revision, and completion boundaries.
dofile('tests/bootstrap.lua')('acid')
local columns=dofile('tests/acid/phrase_columns.lua')
local pitch=dofile('tests/acid/pitch_fixture.lua')

-- Explicit bounded host capacities for the fixed three-step source.
local CAPACITY_LINES=16
local CAPACITY_NOTE_COLUMNS=4
local CAPACITY_EFFECT_COLUMNS=2

local function make_phrase()
  local phrase={name='',number_of_lines=16,lpb=16,shuffle=0,playback_mode=1,
    key_tracking=1,base_note=48,autoseek=false,visible_note_columns=1,
    visible_effect_columns=0,looping=false,loop_start=1,loop_end=16,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,
    script={paragraphs={},parameters={},pending_changes=0,editor_visible=true},cells={}}
  for line=1,CAPACITY_LINES do
    phrase.cells[line]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function phrase:line(line)return columns.line(self,line)end
  function phrase:column_is_muted()return false end
  function phrase:column_name(column)return 'column '..tostring(column)end
  return phrase
end
local instrument={phrases={},samples={{sample_buffer={has_sample_data=true}}},
  plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,
    alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=''}}
function instrument:insert_phrase_at(index)
  assert(index==#self.phrases+1)
  local phrase=make_phrase()
  self.phrases[index]=phrase
  return phrase
end
function instrument:delete_phrase_at(index)table.remove(self.phrases,index)end
local song={instruments={instrument},transport={timing_model=2}}
_G.renoise={InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1,
    MAX_NUMBER_OF_LINES=CAPACITY_LINES,
    MAX_NUMBER_OF_NOTE_COLUMNS=CAPACITY_NOTE_COLUMNS,
    MAX_NUMBER_OF_EFFECT_COLUMNS=CAPACITY_EFFECT_COLUMNS},
  Transport={TIMING_MODEL_SPEED=1,TIMING_MODEL_LPB=2},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function()return song end}
local writer=require('writers.phrase_writer')
local writer_request=dofile('tests/acid/writer_request.lua')
local context=require('runtime.context')
local seq=require('model.sequencer')
local pitch=dofile('tests/acid/pitch_fixture.lua')
local store=require('renoise.pattern_store')

local status
local function completion(value) status=value end
local pattern=seq.new_pattern(3)
pattern.pitch_events[1]=pitch(48)
pattern.pitch_events[2]=pitch(48)
pattern.time_events[1],pattern.time_events[2],pattern.time_events[3]='N','T','T'

local captured_requests,sink_requests=0,0
local boundary=context.new{
  writer=writer,
  capture=function(_,request_token)
    captured_requests=captured_requests+1
    return {token=request_token}
  end,
  sink=function(request,done)
    sink_requests=sink_requests+1
    assert(request.token:is_current())
    done({status='committed'})
    return true
  end,
}

local function build(target,options)
  local request,rejection=writer_request.build(renoise.song(),1,pattern,target or 1,
    options or {output_policy='play_once'})
  if not request then return nil,rejection end
  return request
end

local function generate(target,options,done)
  local request,rejection=build(target,options)
  if not request then return false,rejection end
  local operation=request.kind=='create' and writer.create or writer.regenerate
  return operation(request,done or completion)
end

local first_calls,first_mutations=0,0
local first_request=assert(build(1,{output_policy='play_once'}))
local first_mutate=first_request.mutate
function first_request:mutate(token,action)
  first_mutations=first_mutations+1
  return first_mutate(self,token,action)
end
local first_operation=first_request.kind=='create' and writer.create or writer.regenerate
assert(first_operation(first_request,function(value) first_calls=first_calls+1;status=value end))
assert(first_calls==1 and first_mutations==1,
  'accepted create must perform one authorized mutation and deliver one synchronous terminal result')
assert(status and status.kind=='success' and status.status=='committed',
  tostring(status and status.message))
local created=instrument.phrases[1]
assert(created and rawequal(instrument.phrases[1],created))
assert(writer.state()=='idle','synchronous create left writer occupied')
assert(boundary:request_generation('manual')==true
  and captured_requests==1 and sink_requests==1,
  'runtime did not admit the test sink after synchronous writer completion')

local ownership=require('renoise.phrase_ownership')
local store=require('renoise.pattern_store')
local first_id=assert(ownership.id(created))
local old_source=assert(store.load(song,instrument,created))
pattern.pitch_events[1]=pitch(51)
local before_count=#instrument.phrases
local regeneration_calls,regeneration_mutations=0,0
local regeneration_request=assert(build(1,{output_policy='play_once'}))
local regeneration_mutate=regeneration_request.mutate
function regeneration_request:mutate(token,action)
  regeneration_mutations=regeneration_mutations+1
  return regeneration_mutate(self,token,action)
end
assert(writer.regenerate(regeneration_request,function(value)
  regeneration_calls=regeneration_calls+1;status=value
end))
assert(regeneration_calls==1 and regeneration_mutations==1,
  'regeneration must use one mutation and one terminal callback')
assert(status and status.kind=='success' and status.status=='committed',
  tostring(status and status.message))
assert(rawequal(instrument.phrases[1],created) and #instrument.phrases==before_count,
  'regeneration changed phrase identity or inventory')
local second_id=assert(ownership.id(created))
assert(second_id~=first_id,'regeneration reused the prior immutable phrase ID')
local entries=assert(store.read(song))
assert(entries[first_id] and entries[second_id],
  'regeneration did not retain the historical source revision')
assert(require('model.sequencer').same_source(entries[first_id].pattern,old_source))
assert(entries[second_id].pattern.pitch_events[1].note==51)

-- A frozen request cannot reenter while its synchronous mutation is active.
local reentry_calls,nested_calls=0,0
local reentry_request=assert(build(1,{output_policy='play_once'}))
local original_mutate=reentry_request.mutate
function reentry_request:mutate(token,action)
  reentry_calls=reentry_calls+1
  local nested=writer.regenerate(self,function()nested_calls=nested_calls+1 end)
  assert(nested==false,'active request was accepted recursively')
  return original_mutate(self,token,action)
end
local terminal_calls=0
assert(writer.regenerate(reentry_request,function(value)
  terminal_calls=terminal_calls+1
  status=value
  local accepted=writer.regenerate(reentry_request,function()nested_calls=nested_calls+1 end)
  assert(accepted==false,'terminal delivery reentered the same frozen request')
end))
assert(terminal_calls==1 and reentry_calls==1 and nested_calls==0,
  'reentrant dispatch repeated mutation or delivered a nested terminal result')
assert(writer.state()=='idle')

-- Existing targets regenerate at full phrase capacity without an insertion.
while #instrument.phrases<renoise.Instrument.MAX_NUMBER_OF_PHRASES do
  instrument.phrases[#instrument.phrases+1]={name='unrelated phrase'}
end
local full_count=#instrument.phrases
local full_request=assert(build(1,{output_policy='play_once'}))
local full_calls=0
assert(writer.regenerate(full_request,function(value) full_calls=full_calls+1;status=value end))
assert(full_calls==1 and status.kind=='success' and #instrument.phrases==full_count
  and rawequal(instrument.phrases[1],created),
  'full-instrument regeneration inserted a phrase or changed the target')

print('ACID synchronous writer contract checks passed (mocked Renoise)')
