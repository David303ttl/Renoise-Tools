dofile('tests/bootstrap.lua')('acid')
local output_planner=require('model.output_planner')
local columns=dofile('tests/acid/phrase_columns.lua')

-- Explicit bounded host capacities for representative planned phrase output.
local CAPACITY_LINES=32
local CAPACITY_NOTE_COLUMNS=2
local CAPACITY_EFFECT_COLUMNS=1
local phrase
local instrument
phrase = {script={paragraphs={},parameters={},pending_changes=0,editor_visible=true},name="", number_of_lines=32,visible_note_columns=1,
  visible_effect_columns=0,loop_start=1,loop_end=32,looping=false,lpb=16,shuffle=0,
  playback_mode=1,key_tracking=1,base_note=48,autoseek=false,
  instrument_column_visible=false,volume_column_visible=true,
  panning_column_visible=false,delay_column_visible=false,
  sample_effects_column_visible=false,mapping=nil,cells={}}
for i=1,CAPACITY_LINES do
  phrase.cells[i]={note_value=121,instrument_value=255,volume_value=255,
    panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
end
function phrase:line(i) return columns.line(self,i) end
function phrase:column_is_muted() return false end
function phrase:column_name(i) return "column "..tostring(i) end
function phrase:copy_from(other)
  self.number_of_lines=other.number_of_lines
  self.lpb=other.lpb
  self.shuffle=other.shuffle
  self.playback_mode=other.playback_mode
  self.looping=other.looping
  self.loop_start=other.loop_start
  self.loop_end=other.loop_end
  self.key_tracking=other.key_tracking
  self.base_note=other.base_note
  self.autoseek=other.autoseek
  self.visible_note_columns=other.visible_note_columns
  self.visible_effect_columns=other.visible_effect_columns
  self.instrument_column_visible=other.instrument_column_visible
  self.volume_column_visible=other.volume_column_visible
  self.panning_column_visible=other.panning_column_visible
  self.delay_column_visible=other.delay_column_visible
  self.sample_effects_column_visible=other.sample_effects_column_visible
  self.name=other.name
  self.cells={}
  for i=1,CAPACITY_LINES do
    self.cells[i]={}
    for k,v in pairs(other.cells[i] or {}) do self.cells[i][k]=v end
  end
  columns.copy(self,other)
end
instrument = {phrases={},samples={{sample_buffer={has_sample_data=true}}},plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""},
  phrase_playback_mode=2,phrase_program=7,phrase_editor_visible=false}
function instrument:insert_phrase_at(i)
  assert(i == #self.phrases+1)
  if i == 1 then self.phrases[1]=phrase; return phrase end
  local temp = {script={paragraphs={},parameters={},pending_changes=0,editor_visible=true},name="",number_of_lines=32,visible_note_columns=1,
    visible_effect_columns=0,loop_start=1,loop_end=32,looping=false,lpb=16,shuffle=0,
    playback_mode=1,key_tracking=1,base_note=48,autoseek=false,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,mapping=nil,cells={}}
  for j=1,CAPACITY_LINES do
    temp.cells[j]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function temp:line(j)return columns.line(self,j)end
  function temp:column_is_muted()return false end
  function temp:column_name(j)return "column "..tostring(j)end
  function temp:copy_from(other)
    self.name=other.name
    self.number_of_lines=other.number_of_lines
    self.playback_mode=other.playback_mode
    self.lpb=other.lpb
    self.shuffle=other.shuffle
    self.looping=other.looping
    self.loop_start=other.loop_start
    self.loop_end=other.loop_end
    self.key_tracking=other.key_tracking
    self.base_note=other.base_note
    self.autoseek=other.autoseek
    self.visible_note_columns=other.visible_note_columns
    self.visible_effect_columns=other.visible_effect_columns
    self.instrument_column_visible=other.instrument_column_visible
    self.volume_column_visible=other.volume_column_visible
    self.panning_column_visible=other.panning_column_visible
    self.delay_column_visible=other.delay_column_visible
    self.sample_effects_column_visible=other.sample_effects_column_visible
    for j=1,CAPACITY_LINES do
      local from=other.cells[j] or {}
      self.cells[j]={}
      for k,v in pairs(from) do self.cells[j][k]=v end
    end
    columns.copy(self,other)
  end
  self.phrases[i]=temp
  return temp
end
function instrument:delete_phrase_at(i)
  table.remove(self.phrases,i)
end
local song={instruments={instrument},transport={timing_model=2}}
_G.renoise={
  Transport={TIMING_MODEL_LPB=2,TIMING_MODEL_SPEED=1},
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1,
    MAX_NUMBER_OF_LINES=CAPACITY_LINES,
    MAX_NUMBER_OF_NOTE_COLUMNS=CAPACITY_NOTE_COLUMNS,
    MAX_NUMBER_OF_EFFECT_COLUMNS=CAPACITY_EFFECT_COLUMNS},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function()return song end
}
local writer=require("writers.phrase_writer")
local writer_request=dofile("tests/acid/writer_request.lua")
local store=require("renoise.pattern_store")
local sequencer=require("model.sequencer")
local pitch=dofile("tests/acid/pitch_fixture.lua")
local messages={}
local function message_text(value)
  return type(value)=='table' and value.message or value
end
local function assert_terminal_status(expected)
  local value=messages[#messages]
  assert(type(value)=='table' and (value.kind=='success' or value.kind=='failure'), 'missing typed terminal result')
  assert(value.status==expected, value.message)
end
local function source_fixture()
  local pattern=sequencer.new_pattern(8)
  pattern.pitch_length=4
  for i,command in ipairs({"N","T","N","R","N","N","T","R"}) do
    pattern.time_events[i]=command
  end
  for i,note in ipairs({36,39,43,41}) do
    pattern.pitch_events[i]=pitch(note,i==2,false)
  end
  return pattern
end
local function generate(callback,pattern,target,options)
  pattern=pattern or source_fixture()
  options=options or {}
  options.output_policy=options.output_policy or "play_once"
  local request,rejection=writer_request.build(song,1,pattern,target,options)
  if not request then return false,rejection end
  local operation=request.kind=="create" and writer.create or writer.regenerate
  return operation(request,callback)
end
local ok,err=generate(function(value)messages[#messages+1]=value end)
assert(ok,err)
assert(phrase.playback_mode==1 and phrase.lpb==16)
assert(phrase.number_of_lines==32 and phrase.looping==false)
assert(instrument.phrase_playback_mode==2 and instrument.phrase_program==7
  and instrument.phrase_editor_visible==false)
assert_terminal_status("committed")
assert(message_text(messages[#messages]):find("generated",1,true),messages[#messages].message)
assert(message_text(messages[#messages]):find("4 notes, 4 OFF",1,true))
local repeat_source=source_fixture()
local repeat_plan,repeat_layout=assert(output_planner.plan_output(repeat_source,"repeat",512))
assert(repeat_plan.length==16 and repeat_layout.looping)
assert(repeat_layout.loop_start==33 and repeat_layout.loop_end==65)
assert(repeat_layout.number_of_lines==65)
assert(repeat_plan.steps[1].cycle==1 and repeat_plan.steps[9].cycle==2)
for _,length in ipairs({1,16,17,32}) do
  local pattern=require("model.sequencer").new_pattern(length)
  for step=1,length do pattern.time_events[step]="N" end
  local physical,layout=assert(output_planner.plan_output(pattern,"repeat",512))
  assert(physical.length==2*length)
  assert(layout.looping and layout.loop_start==4*length+1)
  assert(layout.loop_end==8*length+1 and layout.number_of_lines==8*length+1)
  assert(layout.number_of_lines<=257)
  assert(physical.steps[physical.length].step==physical.length)
end
local before_repeat=#instrument.phrases
local repeat_slide=require("model.sequencer").new_pattern(4)
for i,command in ipairs({"N","T","N","R"}) do repeat_slide.time_events[i]=command end
for i=1,32 do repeat_slide.pitch_events[i]=pitch(36+i%12) end
repeat_slide.pitch_events[1].slide=true
local slide_plan,slide_layout=assert(output_planner.plan_output(repeat_slide,"repeat",512))
assert(slide_plan.loop and slide_layout.looping,
  "A valid SLIDE source must enter the automatic Repeat renderer")
local play_once_plan,play_once_layout=assert(output_planner.plan_output(repeat_slide,"play_once",512))
assert(not play_once_layout.looping and repeat_slide.pitch_events[1].slide,
  "Phrase output policy must not rewrite the musical source")
assert(#instrument.phrases==before_repeat)
-- Sealed ownership permits a second generation to the same phrase.
local first=instrument.phrases[1]
local edited=source_fixture()
edited.pitch_events[1]=pitch(38)
assert(generate(function(value)messages[#messages+1]=value end,edited))
assert(#instrument.phrases==1 and instrument.phrases[1]==first)
assert(message_text(messages[#messages]):find("generated",1,true),message_text(messages[#messages]))
assert(first.cells[1].note_value==38)
assert(require("renoise.pattern_store").load(song,instrument,first).pitch_events[1].note==38)
-- Regeneration adopts a new immutable source revision on the same phrase object.
local ownership=require('renoise.phrase_ownership')
local store=require('renoise.pattern_store')
local materializer=require('writers.phrase_materializer')
local first_id=assert(ownership.id(first))
local old_source=assert(store.load(song,instrument,first))
local script_reference=first.script
local edited_id_source=source_fixture()
edited_id_source.pitch_events[1]=pitch(40)
assert(generate(function(value)messages[#messages+1]=value end,edited_id_source,1))
assert(messages[#messages].kind=='success' and messages[#messages].status=='committed')
assert(rawequal(instrument.phrases[1],first) and #instrument.phrases==1)
assert(rawequal(first.script,script_reference),"regeneration replaced phrase script metadata")
local second_id=assert(ownership.id(first))
assert(second_id~=first_id,"regeneration reused the previous phrase ID")
local history=assert(store.read(song))
assert(history[first_id] and history[second_id]
  and require('model.sequencer').same_source(history[first_id].pattern,old_source)
  and history[second_id].pattern.pitch_events[1].note==40)

-- Corrupt direct output and a write-after-store failure both restore the
-- complete last-good phrase and exact song source bytes.
local before_snapshot=assert(ownership.snapshot(first))
local before_store=song.tool_data
local apply=materializer.apply
materializer.apply=function(target,...)
  local ok,actual,attempted=apply(target,...)
  if not ok then return ok,actual,attempted end
  target.cells[1].note_value=0
  return nil,"injected materialization verification failure",true
end
local failed
assert(generate(function(value)failed=value end,edited,1))
materializer.apply=apply
assert(failed.kind=='failure' and failed.status=='failed')
assert(song.tool_data==before_store and #instrument.phrases==1
  and ownership.compare(before_snapshot,assert(ownership.snapshot(first))))
local commit=store.commit
store.commit=function(target_song,candidate)
  assert(commit(target_song,candidate))
  error('injected source commit failure after write',0)
end
assert(generate(function(value)failed=value end,edited,1))
store.commit=commit
assert(failed.kind=='failure' and failed.message:find('injected source commit failure',1,true))
assert(song.tool_data==before_store and #instrument.phrases==1
  and ownership.compare(before_snapshot,assert(ownership.snapshot(first))))
assert(ownership.id(first)==second_id)

-- A revoked request during the direct mutation rolls the phrase back before
-- the single terminal callback.
local token={valid=true}
function token:is_current()return self.valid end
local cancel_apply=materializer.apply
materializer.apply=function(target,...)
  local ok,actual,reason=cancel_apply(target,...)
  token.valid=false
  assert(writer.cancel(token,'cancelled during direct mutation'))
  return ok,actual,reason
end
local cancelled
assert(generate(function(value)cancelled=value end,edited,1,{token=token}))
materializer.apply=cancel_apply
assert(cancelled.kind=='failure' and cancelled.status=='cancelled',
  tostring(cancelled and cancelled.status)..': '..tostring(cancelled and cancelled.message))
assert(song.tool_data==before_store and #instrument.phrases==1
  and ownership.compare(before_snapshot,assert(ownership.snapshot(first))))

-- Triplet timing and sample slide output come from the same planner used by
-- the direct materializer.
local triplet=source_fixture()
triplet.timing_mode='triplet'
triplet.pitch_events[1].slide=true
local triplet_result
assert(generate(function(value)triplet_result=value end,triplet,1))
assert(triplet_result.status=='committed' or triplet_result.status=='approximate')
assert(first.lpb==12 and first.shuffle==0 and first.cells[9].effect_number_string=='0G')
assert(store.load(song,instrument,first).timing_mode=='triplet')

-- An edited seal blocks regeneration, while a full phrase list still permits
-- in-place regeneration of an existing owned destination.
local committed_note=first.cells[1].note_value
first.cells[1].note_value=committed_note-1
local denied,denial=generate(function()error('rejected write delivered a callback')end,triplet,1)
assert(not denied and denial.kind=='failure' and denial.message:find('not safely ACID-owned',1,true))
first.cells[1].note_value=committed_note
while #instrument.phrases<renoise.Instrument.MAX_NUMBER_OF_PHRASES do
  instrument.phrases[#instrument.phrases+1]={name='unrelated phrase'}
end
local full_count=#instrument.phrases
local full_result
assert(generate(function(value)full_result=value end,triplet,1))
assert(full_result.kind=='success' and #instrument.phrases==full_count
  and rawequal(instrument.phrases[1],first))
print('ACID synchronous phrase writer checks passed (mocked Renoise)')
