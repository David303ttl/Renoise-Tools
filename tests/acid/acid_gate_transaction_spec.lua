dofile('tests/bootstrap.lua')('acid')

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
local instrument={phrases={},samples={{sample_buffer={has_sample_data=true}}}}
local contaminate=false
local wrong_volume=nil
local script={paragraphs={},compile_error='',runtime_error='',committed_observable=committed}
function script:commit() committed:fire() end
function script:render_to_pattern(_,callback)
  local phrase=instrument.phrases[#instrument.phrases]
  local values=assert(self.paragraphs[1]:match('local values = { (.-) }\nreturn pattern'))
  local step,count=0,0
  for token in (values..','):gmatch('(.-),') do
    local volume=tonumber(token:match('volume = ([%d.]+)'))
    if volume then
      phrase.cells[(step-1)*2+1].volume_value=volume==1 and 255 or 89
    end
    local note=tonumber(token:match('key = (%d+)'))
    if note or token:find('"off"',1,true) or token:match('^%s*false%s*$') then
      step=step+1
      if note or token:find('"off"',1,true) then
        phrase.cells[(step-1)*2+1].note_value=note or 120
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
  'loop_start','loop_end','key_tracking','visible_note_columns','visible_effect_columns'}
function instrument:insert_phrase_at(index)
  local phrase={name='',number_of_lines=16,visible_note_columns=1,
    visible_effect_columns=0,looping=false,loop_start=1,loop_end=16,script=script,cells={}}
  for line=1,257 do
    phrase.cells[line]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function phrase:line(line) return {note_columns={self.cells[line]},effect_columns={}} end
  function phrase:column_is_muted() return false end
  function phrase:copy_from(other)
    for _,key in ipairs(properties) do self[key]=other[key] end
    self.cells={}
    for line,cell in ipairs(other.cells) do
      local copy={}
      for key,value in pairs(cell) do copy[key]=value end
      self.cells[line]=copy
    end
  end
  table.insert(self.phrases,index,phrase)
  return phrase
end
function instrument:delete_phrase_at(index) table.remove(self.phrases,index) end
local song={instruments={instrument}}
_G.renoise={InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function()return song end,tool=function()return {app_idle_observable=idle} end}
local writer=require('writers.phrase_writer')
local seq=require('model.sequencer')
local pitch=dofile('tests/acid/pitch_fixture.lua')
local store=require('model.pattern_store')
local ownership=require('writers.phrase_ownership')
local status
local function generate(pattern)
  assert(writer.generate(1,function(message)status=message end,pattern,1,
    {output_policy='play_once'}))
  for _=1,6 do idle:fire() end
end
local pattern=seq.new_pattern(3)
pattern.pitch_events[1]=pitch(48)
pattern.pitch_events[2]=pitch(48)
for i,command in ipairs({'N','T','T'}) do pattern.time_events[i]=command end
generate(pattern)
assert(status:find('generated',1,true),status)
local target=instrument.phrases[1]
assert(target.cells[1].note_value==48)
assert(target.cells[2].note_value==121 and target.cells[4].note_value==121)
assert(target.cells[6].note_value==120,'Play Once NTT must release at 2.5 steps')
assert(ownership.status(target)=='owned')
local raw,name=song.tool_data,target.name
local original_commit=store.commit
store.commit=function(target_song,candidate)
  target_song.tool_data=candidate.raw
  error('injected persistence failure after gate application')
end
for i,command in ipairs({'N','N','T'}) do pattern.time_events[i]=command end
pattern.pitch_events[1]=pitch(50)
generate(pattern)
store.commit=original_commit
assert(status:find('injected persistence failure',1,true),status)
assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],target))
assert(song.tool_data==raw and target.name==name and ownership.status(target)=='owned')
assert(target.cells[1].note_value==48 and target.cells[2].note_value==121)
assert(target.cells[6].note_value==120)
contaminate=true
generate(pattern)
assert(status:find('FAILED',1,true),status)
assert(song.tool_data==raw and target.name==name and #instrument.phrases==1)
contaminate=false
-- A renderer that preserves notes but loses or changes accent levels must never
-- replace the sealed destination or its persisted source.
for _,volume in ipairs({0,90,128,255}) do
  wrong_volume=volume
  generate(pattern)
  assert(status:find('Phrase volume mismatch',1,true),status)
  assert(song.tool_data==raw and target.name==name and #instrument.phrases==1)
  assert(rawequal(instrument.phrases[1],target) and ownership.status(target)=='owned')
  assert(target.cells[1].note_value==48 and target.cells[1].volume_value==89)
end
wrong_volume=nil
generate(pattern)
assert(status:find('generated',1,true),status)
assert(target.cells[1].note_value==50 and target.cells[2].note_value==120)
assert(target.cells[3].note_value==48 and target.cells[4].note_value==121)
assert(target.cells[6].note_value==120)
local restored,output_policy=store.load(song,target)
assert(restored and output_policy=='play_once' and restored.time_events[2]=='N'
  and restored.pitch_events[1].note==50)
assert(ownership.status(target)=='owned')
-- Unity accent uses pattrns' empty/full-volume sentinel, not explicit 0x80.
raw,name=song.tool_data,target.name
pattern.pitch_events[1].accent=true
for _,volume in ipairs({0,89,128}) do
  wrong_volume=volume
  generate(pattern)
  assert(status:find('Phrase volume mismatch',1,true),status)
  assert(song.tool_data==raw and target.name==name and #instrument.phrases==1)
  assert(target.cells[1].volume_value==89 and ownership.status(target)=='owned')
end
wrong_volume=nil
generate(pattern)
assert(status:find('generated',1,true),status)
assert(target.cells[1].volume_value==255 and target.cells[3].volume_value==89)
assert(store.load(song,target).pitch_events[1].accent)
print('ACID one-shot gate generation, regeneration and transaction rollback passed (mocked Renoise)')
