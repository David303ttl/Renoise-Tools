package.path = "com.david303ttl.ACID.xrnx/?.lua;" .. package.path
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
function script:commit() committed:fire() end
function script:render_to_pattern(opts, cb)
  assert(opts.lpb == 8)
  local notes = {[1]=36,[5]=39,[7]=120,[9]=43,[11]=41,[15]=120}
  for i=1,16 do
    phrase.cells[i].note_value = notes[i] or 121
  end
  cb(nil, 8, 0)
end
local phrase = {script=script,name="", number_of_lines=16,visible_note_columns=1,cells={}}
for i=1,16 do phrase.cells[i] = {note_value=121} end
function phrase:line(i) return {note_columns={self.cells[i]}} end
local instrument = {phrases={},samples={{sample_buffer={has_sample_data=true}}}}
function instrument:insert_phrase_at(i)
  assert(i==1)
  self.phrases[1]=phrase
  return phrase
end
function instrument:delete_phrase_at(i)
  assert(i==1)
  table.remove(self.phrases,i)
end
local song={instruments={instrument}}
_G.renoise={
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1},
  Instrument={PHRASES_PLAY_SELECTIVE=2},
  song=function()return song end,
  tool=function()return {app_idle_observable=idle} end
}
local writer=require("phrase_writer")
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
assert(not writer.generate(1,function()end))
print("ACID phrase API mock checks passed")
