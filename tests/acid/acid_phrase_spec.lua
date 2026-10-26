dofile('tests/bootstrap.lua')('acid')
local function observable()
  local handlers = {}
  return {
    add_notifier=function(_, cb) handlers[cb] = true end,
    remove_notifier=function(_, cb) handlers[cb] = nil end,
    fire=function()
      local copy = {}
      for h in pairs(handlers) do copy[#copy+1] = h end
      for _,h in ipairs(copy) do h() end
    end
  }
end
local idle, committed = observable(), observable()
local script = {paragraphs={},compile_error="",runtime_error="",committed_observable=committed}
local phrase
local instrument
function script:commit() committed:fire() end
function script:render_to_pattern(opts, cb)
  assert(opts.lpb == 8)
  local target = instrument and instrument.phrases[#instrument.phrases] or phrase
  local notes = {[1]=36,[5]=39,[7]=120,[9]=43,[11]=41,[15]=120}
  for i=1,16 do
    target.cells[i].note_value = notes[i] or 121
  end
  cb(nil, 8, 0)
end
phrase = {script=script,name="", number_of_lines=16,visible_note_columns=1,cells={}}
for i=1,16 do phrase.cells[i] = {note_value=121} end
function phrase:line(i) return {note_columns={self.cells[i]}} end
function phrase:copy_from(other)
  self.number_of_lines=other.number_of_lines
  self.lpb=other.lpb
  self.playback_mode=other.playback_mode
  self.looping=other.looping
  self.key_tracking=other.key_tracking
  self.name=other.name
  self.cells={}
  for i=1,self.number_of_lines do
    self.cells[i]={}
    for k,v in pairs(other.cells[i]) do self.cells[i][k]=v end
  end
end
instrument = {phrases={},samples={{sample_buffer={has_sample_data=true}}}}
function instrument:insert_phrase_at(i)
  assert(i == #self.phrases+1)
  if i == 1 then self.phrases[1]=phrase; return phrase end
  local temp = {script=script,name="",number_of_lines=16,visible_note_columns=1,cells={}}
  for j=1,16 do temp.cells[j]={note_value=121} end
  function temp:line(j)return {note_columns={self.cells[j]}}end
  function temp:copy_from(other)
    self.name=other.name
    self.number_of_lines=other.number_of_lines
    self.playback_mode=other.playback_mode
    self.lpb=other.lpb
    self.looping=other.looping
    self.key_tracking=other.key_tracking
    for j=1,self.number_of_lines do
      local from=other.cells[j]
      self.cells[j]={}
      for k,v in pairs(from) do self.cells[j][k]=v end
    end
  end
  self.phrases[i]=temp
  return temp
end
function instrument:delete_phrase_at(i)
  table.remove(self.phrases,i)
end
local song={instruments={instrument}}
_G.renoise={
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1},
  Instrument={PHRASES_PLAY_SELECTIVE=2},
  song=function()return song end,
  tool=function()return {app_idle_observable=idle} end
}
local writer=require("writers.phrase_writer")
local messages={}
local ok,err=writer.generate(1,function(msg)messages[#messages+1]=msg end)
assert(ok,err)
idle:fire()
idle:fire()
idle:fire()
assert(phrase.playback_mode==1 and phrase.lpb==8)
assert(phrase.number_of_lines==16 and phrase.looping==false)
assert(instrument.phrase_program==1)
assert(messages[#messages]:find("generated",1,true))
assert(messages[#messages]:find("4 notes, 2 OFF",1,true))
-- Sealed ownership permits a second generation to the same phrase.
local first=instrument.phrases[1]
assert(writer.generate(1,function(msg)messages[#messages+1]=msg end))
idle:fire();idle:fire();idle:fire()
assert(#instrument.phrases==1 and instrument.phrases[1]==first)
assert(messages[#messages]:find("generated",1,true))
-- Manual edits invalidate the seal.
first.cells[1].note_value=41
local denied,reason=writer.generate(1,function()end)
assert(not denied and reason:find("not safely ACID-owned",1,true))
print("ACID phrase API mock checks passed")
