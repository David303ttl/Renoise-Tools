dofile('tests/bootstrap.lua')('acid')
local output_planner=require('model.output_planner')
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
function script:commit()
  local on_idle
  on_idle=function()
    idle:remove_notifier(on_idle)
    committed:fire()
  end
  idle:add_notifier(on_idle)
end
function script:render_to_pattern(opts, cb)
  assert(opts.lpb == 16)
  local target = instrument and instrument.phrases[#instrument.phrases] or phrase
  local first_note=tonumber(self.paragraphs[1]:match("key = (%d+)"))
  local notes = {[1]=first_note,[9]=39,[13]=120,[17]=43,[21]=41,[29]=120}
  for i=1,32 do
    target.cells[i].note_value = notes[i] or 121
    target.cells[i].volume_value = i==9 and 255 or (notes[i] and notes[i]<120 and 89 or 255)
  end
  cb(nil, 8, 0)
end
phrase = {script=script,name="", number_of_lines=32,visible_note_columns=1,
  loop_start=1,loop_end=32,instrument_column_visible=false,volume_column_visible=false,
  panning_column_visible=false,delay_column_visible=false,cells={}}
for i=1,32 do phrase.cells[i] = {note_value=121} end
function phrase:line(i) return {note_columns={self.cells[i]}} end
function phrase:column_is_muted() return false end
function phrase:copy_from(other)
  self.number_of_lines=other.number_of_lines
  self.lpb=other.lpb
  self.shuffle=other.shuffle
  self.playback_mode=other.playback_mode
  self.looping=other.looping
  self.loop_start=other.loop_start
  self.loop_end=other.loop_end
  self.key_tracking=other.key_tracking
  self.name=other.name
  self.cells={}
  for i=1,self.number_of_lines do
    self.cells[i]={}
    for k,v in pairs(other.cells[i]) do self.cells[i][k]=v end
  end
end
instrument = {phrases={},samples={{sample_buffer={has_sample_data=true}}},plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""},
  phrase_playback_mode=2,phrase_program=7,phrase_editor_visible=false}
function instrument:insert_phrase_at(i)
  assert(i == #self.phrases+1)
  if i == 1 then self.phrases[1]=phrase; return phrase end
  local temp = {script=script,name="",number_of_lines=32,visible_note_columns=1,
    loop_start=1,loop_end=32,instrument_column_visible=false,volume_column_visible=false,
    panning_column_visible=false,delay_column_visible=false,cells={}}
  for j=1,32 do temp.cells[j]={note_value=121} end
  function temp:line(j)return {note_columns={self.cells[j]}}end
  function temp:column_is_muted()return false end
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
local song={instruments={instrument},transport={timing_model=2}}
_G.renoise={
  Transport={TIMING_MODEL_LPB=2,TIMING_MODEL_SPEED=1},
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function()return song end,
  tool=function()return {app_idle_observable=idle} end
}
local writer=require("writers.phrase_writer")
local store=require("renoise.pattern_store")
local sequencer=require("model.sequencer")
local pitch=dofile("tests/acid/pitch_fixture.lua")
local messages={}
local function message_text(value)
  return type(value)=='table' and value.message or value
end
local function assert_terminal_status(expected)
  local value=messages[#messages]
  assert(type(value)=='table' and value.kind=='complete', 'missing typed terminal result')
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
  return writer.generate(1,callback,pattern,target,options)
end
local ok,err=generate(function(value)messages[#messages+1]=value end)
assert(ok,err)
idle:fire()
idle:fire()
idle:fire()
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
idle:fire();idle:fire();idle:fire()
assert(#instrument.phrases==1 and instrument.phrases[1]==first)
assert(message_text(messages[#messages]):find("generated",1,true),message_text(messages[#messages]))
assert(first.cells[1].note_value==38)
assert(require("renoise.pattern_store").load(song,instrument,first).pitch_events[1].note==38)
-- A failed second capability inspection at renderer start cannot publish output.
local unreadable_status
local previous_phrase_name,previous_source=first.name,song.tool_data
assert(generate(function(value)unreadable_status=value end,edited,1))
instrument.samples=nil
setmetatable(instrument,{__index=function(_,key)
  if key=="samples" then error("sample inventory read failed") end
end})
idle:fire()
setmetatable(instrument,nil)
instrument.samples={{sample_buffer={has_sample_data=true}}}
assert(type(unreadable_status)=="table" and unreadable_status.status=="suspended"
  and unreadable_status.code=="safety.target_changed",
  "an unreadable capability profile during generation must suspend the writer")
assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],first)
  and first.name==previous_phrase_name and song.tool_data==previous_source
  and first.cells[1].note_value==38,
  "an unreadable capability profile authorized destination or source publication")
-- A missing render callback retains staging and blocks overlapping writes.
local base_render=script.render_to_pattern
local render_calls,pending_render=0,nil
local delayed=source_fixture()
delayed.pitch_events[1]=pitch(37)
function script:render_to_pattern(opts,cb)
  render_calls=render_calls+1
  pending_render=cb
  return true
end
assert(generate(function(value)messages[#messages+1]=value end,delayed,1))
for _=1,600 do idle:fire() end
assert(render_calls==1 and type(pending_render)=="function")
assert(#instrument.phrases==2 and instrument.phrases[1]==first)
assert(messages[#messages].code=="transaction.render_pending")
local overlapping,overlap_error=generate(function()end,delayed,1)
assert(not overlapping and overlap_error.code=="transaction.busy")
script.render_to_pattern=base_render
base_render(script,{lpb=16},pending_render)
assert(message_text(messages[#messages]):find("generated",1,true))
assert(first.cells[1].note_value==37)
local restored_source=source_fixture()
restored_source.pitch_events[1]=pitch(38)
assert(generate(function(value)messages[#messages+1]=value end,restored_source,1))
idle:fire();idle:fire();idle:fire()
assert(first.cells[1].note_value==38)
-- In-flight cancellation defers stage deletion until the callback arrives.
local pending_token={valid=true,is_current=function(self)return self.valid end}
function script:render_to_pattern(_,cb) pending_render=cb;return true end
local saved_source=song.tool_data
assert(generate(function(value)messages[#messages+1]=value end,edited,1,{token=pending_token}))
idle:fire()
pending_token.valid=false
local cancelled,pending_status=writer.cancel(pending_token)
assert(not cancelled and pending_status.code=="transaction.cancel_pending")
local stage=instrument.phrases[2]
assert(stage and #instrument.phrases==2)
assert(not generate(function()end,edited,1))
for _=1,600 do idle:fire() end
assert(instrument.phrases[2]==stage and #instrument.phrases==2)
pending_render(nil,8,0)
assert(#instrument.phrases==1 and first.cells[1].note_value==38)
assert(song.tool_data==saved_source)
script.render_to_pattern=base_render
-- Renoise document objects must use rawequal; their == metamethod may throw.
local unsafe_equality={__eq=function()error("unsafe Renoise object equality")end}
setmetatable(song,unsafe_equality)
setmetatable(instrument,unsafe_equality)
setmetatable(first,unsafe_equality)
assert(generate(function(value)messages[#messages+1]=value end,restored_source,1))
idle:fire();idle:fire();idle:fire()
assert(message_text(messages[#messages]):find("generated",1,true),message_text(messages[#messages]))
setmetatable(first,nil)
setmetatable(instrument,nil)
setmetatable(song,nil)
-- Moving a destination while rendering is safe when its object and seal remain unchanged.
function script:render_to_pattern(opts,cb)
  table.insert(instrument.phrases,1,{name="unrelated phrase"})
  return base_render(self,opts,cb)
end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
script.render_to_pattern=base_render
assert(#instrument.phrases==2 and instrument.phrases[2]==first)
assert(instrument.phrase_playback_mode==2 and instrument.phrase_program==7
  and instrument.phrase_editor_visible==false)
table.remove(instrument.phrases,1)
assert(#instrument.phrases==1 and instrument.phrases[1]==first)

-- A source-store edit that arrives during rendering wins over the stale candidate.
local old_store=song.tool_data
function script:render_to_pattern(opts,cb)
  return base_render(self,opts,function(...)
    song.tool_data="newer source written during render"
    cb(...)
  end)
end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
script.render_to_pattern=base_render
assert(song.tool_data=="newer source written during render")
assert(first.cells[1].note_value==38 and #instrument.phrases==1)
song.tool_data=old_store

-- Replacing the captured destination object during render is refused.
function script:render_to_pattern(opts,cb)
  return base_render(self,opts,function(...)
    instrument.phrases[1]={name="replacement phrase"}
    cb(...)
  end)
end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
script.render_to_pattern=base_render
assert(message_text(messages[#messages]):find("target phrase was removed",1,true))
assert(#instrument.phrases==1 and instrument.phrases[1].name=="replacement phrase")
instrument.phrases[1]=first
local original_commit=store.commit
store.commit=function()return nil,"injected source write failure"end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
store.commit=original_commit
assert(message_text(messages[#messages]):find("injected source write failure",1,true))
assert(#instrument.phrases==1 and instrument.phrases[1]==first)
assert(first.cells[1].note_value==38)
local append_failed=generate(function(value)messages[#messages+1]=value end,edited,2)
assert(append_failed)
store.commit=function()return nil,"injected append source failure"end
idle:fire();idle:fire();idle:fire()
store.commit=original_commit
assert(message_text(messages[#messages]):find("injected append source failure",1,true),
  type(messages[#messages])=='table' and messages[#messages].message or messages[#messages])
assert(#instrument.phrases==1)
-- Manual edits invalidate the seal.
first.cells[1].note_value=41
local denied,reason=generate(function()end)
assert(not denied and type(reason)=='table' and reason.status=='error')
assert(reason.message:find("not safely ACID-owned",1,true))
first.cells[1].note_value=38
local render=script.render_to_pattern
function script:render_to_pattern() return false,"renderer unavailable" end
assert(generate(function(value)messages[#messages+1]=value end,edited))
idle:fire();idle:fire();idle:fire()
assert(message_text(messages[#messages]):find("renderer unavailable",1,true))
assert(#instrument.phrases==1 and first.cells[1].note_value==38)
script.render_to_pattern=render
assert(generate(function(value)messages[#messages+1]=value end,edited))
idle:fire();idle:fire();idle:fire()
assert(message_text(messages[#messages]):find("generated",1,true))

-- A partially applied store write must restore the exact old source and phrase.
old_store=song.tool_data
store.commit=function(target,candidate)
  assert(original_commit(target,candidate))
  error("injected exception after source write")
end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
store.commit=original_commit
assert(message_text(messages[#messages]):find("injected exception after source write",1,true))
assert(song.tool_data==old_store and first.cells[1].note_value==38 and #instrument.phrases==1)

-- A newer concurrent source store is preserved when the prepared write is stale.
store.commit=function(target)
  target.tool_data="newer external source"
  return nil,"stale source candidate"
end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
store.commit=original_commit
assert(song.tool_data=="newer external source")
assert(first.cells[1].note_value==38 and #instrument.phrases==1)
song.tool_data=old_store

-- If destination restoration fails, retain an identifiable backup phrase.
local original_copy=first.copy_from
function first:copy_from(other)
  if other.name==writer.PHRASE_NAME then
    self.cells[1].note_value=50
    error("injected partial destination replacement")
  elseif other.name=="ACID TRANSACTION BACKUP" then
    error("injected destination rollback failure")
  end
  return original_copy(self,other)
end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
first.copy_from=original_copy
assert(message_text(messages[#messages]):find("recovery phrase retained",1,true))
assert(#instrument.phrases==2 and instrument.phrases[2].name=="ACID RECOVERY BACKUP")
assert(instrument.phrases[2].cells[1].note_value==38)
instrument:delete_phrase_at(2)
-- Restore the test destination after simulating the intentionally failed rollback.
first.cells[1].note_value=38
first.name=assert(require("renoise.phrase_ownership").make_name(first,1))

-- A committed phrase remains valid when a redundant backup cannot be removed.
local original_delete=instrument.delete_phrase_at
function instrument:delete_phrase_at(index)
  if self.phrases[index] and self.phrases[index].name=="ACID TRANSACTION BACKUP" then
    error("injected backup cleanup failure")
  end
  return original_delete(self,index)
end
assert(generate(function(value)messages[#messages+1]=value end,edited,1))
idle:fire();idle:fire();idle:fire()
instrument.delete_phrase_at=original_delete
assert(message_text(messages[#messages]):find("recovery backup remains",1,true),message_text(messages[#messages]))
assert(#instrument.phrases==2 and instrument.phrases[2].name=="ACID RECOVERY BACKUP")
assert(require("renoise.pattern_store").load(song,instrument,first).pitch_events[1].note==38)
instrument:delete_phrase_at(2)

-- Cancellation settles even when temporary phrase removal fails.
local token={valid=true,is_current=function(self)return self.valid end}
local cancel_message
assert(generate(function(msg)cancel_message=msg end,edited,2,{token=token}))
token.valid=false
local remove=instrument.delete_phrase_at
function instrument:delete_phrase_at(index)
  if self.phrases[index] and self.phrases[index].name==writer.PHRASE_NAME then
    error("injected staging cleanup failure")
  end
  return remove(self,index)
end
local cancelled,cancel_error=writer.cancel(token)
assert(cancelled and type(cancel_error)=='table' and cancel_error.status=='error')
instrument.delete_phrase_at=remove
assert(type(cancel_message)=='table' and cancel_message.status=='error')
assert(cancel_message.message:find("recovery material was retained",1,true))
assert(#instrument.phrases==2 and instrument.phrases[2].name=="ACID RECOVERY STAGING")
instrument:delete_phrase_at(2)
print("ACID phrase API mock checks passed")

-- A slide must finish before the following note's midpoint release.
local slide_source=sequencer.new_pattern(4)
slide_source.pitch_length=2
slide_source.pitch_events[1]=pitch(36,false,true)
slide_source.pitch_events[2]=pitch(44)
for i,command in ipairs({"N","T","N","N"}) do
  slide_source.time_events[i]=command
end
local original_render=script.render_to_pattern
function script:render_to_pattern(opts,cb)
  local target=instrument.phrases[#instrument.phrases]
  local notes={[1]=36,[9]=44,[13]=36}
  for line=1,16 do
    target.cells[line]={note_value=notes[line] or 121,
      volume_value=(line==1 or line==9 or line==13) and 89 or 255,
      instrument_value=255,panning_value=255,delay_value=0,
      effect_number_value=0,effect_amount_value=0}
  end
  cb(nil,16,0)
end
local slide_status
assert(generate(function(value)slide_status=value end,
  slide_source,#instrument.phrases+1))
idle:fire();idle:fire();idle:fire()
script.render_to_pattern=original_render
local slide_phrase=instrument.phrases[#instrument.phrases]
assert(type(slide_status)=='table' and
  (slide_status.status=='committed' or slide_status.status=='approximate'),
  slide_status and slide_status.message)
assert(slide_status.message:find("generated",1,true),slide_status.message)
assert(slide_phrase.cells[9].effect_number_string=="0G",
  "sample slide must retain its native glide command")
assert(slide_phrase.cells[9].effect_amount_value==64,
  "glide rate must fit before the following midpoint release")
assert(slide_phrase.cells[11].note_value==120,
  "the glide continuation line is reserved for the midpoint OFF")
local first_phrase=instrument.phrases[1]
local first_note=first_phrase.cells[1].note_value
local replacement=source_fixture()
replacement.pitch_events[1]=pitch(40)
local replacement_status
assert(generate(function(value)replacement_status=value end,replacement,2))
idle:fire();idle:fire();idle:fire()
assert(type(replacement_status)=='table' and
  (replacement_status.status=='committed' or replacement_status.status=='approximate'),
  replacement_status and replacement_status.message)
assert(replacement_status.message:find("Phrase 02 generated",1,true), replacement_status.message)
assert(#instrument.phrases==2 and instrument.phrases[2]==slide_phrase,
  "regeneration must replace the selected second phrase in place")
assert(slide_phrase.cells[1].note_value==40,
  "the selected second phrase must receive the new source")
assert(first_phrase.cells[1].note_value==first_note,
  "regeneration must leave the preceding phrase unchanged")
print("ACID phrase writer slide and destination regression checks passed")

-- Triplet rendering must use the same LPB in Pattrns and the committed phrase.
-- A misplaced rendered event must leave the previous phrase and source intact.
local triplet_source=source_fixture()
triplet_source.timing_mode="triplet"
local triplet_status
local triplet_target=#instrument.phrases+1
local render_triplet=function(self,opts,cb)
  assert(opts.lpb==12, "triplet script was rendered at the wrong LPB")
  assert(self.paragraphs[1]:find('unit = "1/8"',1,true))
  assert(self.paragraphs[1]:find('resolution = 2/3',1,true))
  local target=instrument.phrases[#instrument.phrases]
  local notes={[1]=36,[9]=39,[13]=120,[17]=43,[21]=41,[29]=120}
  for line=1,32 do
    target.cells[line]={note_value=notes[line] or 121,
      volume_value=line==9 and 255 or (notes[line] and notes[line]<120 and 89 or 255)}
  end
  cb(nil,8,0)
end
script.render_to_pattern=render_triplet
assert(generate(function(value)triplet_status=value end,triplet_source,triplet_target))
idle:fire();idle:fire();idle:fire()
assert(triplet_status.status=='committed' or triplet_status.status=='approximate',triplet_status.message)
local triplet_phrase=instrument.phrases[triplet_target]
assert(triplet_phrase.lpb==12 and triplet_phrase.shuffle==0 and triplet_phrase.number_of_lines==32)
assert(store.load(song,song.instruments[1],triplet_phrase).timing_mode=='triplet')
local triplet_store=song.tool_data
local triplet_first=triplet_phrase.cells[1].note_value
function script:render_to_pattern(opts,cb)
  return render_triplet(self,opts,function(...)
    local target=instrument.phrases[#instrument.phrases]
     target.cells[9].note_value=121
     target.cells[10].note_value=39
    cb(...)
  end)
end
assert(generate(function(value)triplet_status=value end,triplet_source,triplet_target))
idle:fire();idle:fire();idle:fire()
script.render_to_pattern=original_render
assert(triplet_status.status=='error',triplet_status.message)
assert(instrument.phrases[triplet_target]==triplet_phrase and triplet_phrase.cells[1].note_value==triplet_first)
assert(song.tool_data==triplet_store and #instrument.phrases==triplet_target)
-- A silent copy defect must be detected after staging and rolled back.
for _,field in ipairs({"note", "lpb", "shuffle"}) do
  local copy=triplet_phrase.copy_from
  local original_name=triplet_phrase.name
  function triplet_phrase:copy_from(other)
    copy(self,other)
    if other.name==writer.PHRASE_NAME then
      if field=="note" then self.cells[1].note_value=37
      elseif field=="lpb" then self.lpb=16
      else self.shuffle=1 end
    end
  end
  script.render_to_pattern=render_triplet
  assert(generate(function(value)triplet_status=value end,triplet_source,triplet_target))
  idle:fire();idle:fire();idle:fire()
  triplet_phrase.copy_from=copy
  assert(triplet_status.status=='error' and triplet_status.message:find('Copied phrase validation failed',1,true),
    triplet_status.message)
  assert(instrument.phrases[triplet_target]==triplet_phrase and #instrument.phrases==triplet_target)
  assert(triplet_phrase.name==original_name and triplet_phrase.cells[1].note_value==triplet_first)
  assert(triplet_phrase.lpb==12 and triplet_phrase.shuffle==0 and song.tool_data==triplet_store)
end
script.render_to_pattern=original_render
-- Reported host limits are checked before replacing an owned destination.
for _,limit in ipairs({"MAX_NUMBER_OF_LINES","MAX_NUMBER_OF_NOTE_COLUMNS"}) do
  local saved=renoise.InstrumentPhrase[limit]
  renoise.InstrumentPhrase[limit]=limit=="MAX_NUMBER_OF_LINES" and 15 or 0
  local accepted,reason=generate(function(value)triplet_status=value end,triplet_source,triplet_target)
  assert(not accepted and reason,limit.." was ignored")
  assert(instrument.phrases[triplet_target]==triplet_phrase and triplet_phrase.cells[1].note_value==triplet_first)
  assert(song.tool_data==triplet_store and #instrument.phrases==triplet_target)
  renoise.InstrumentPhrase[limit]=saved
end
local bend_source=source_fixture()
bend_source.timing_mode="triplet"
bend_source.pitch_events[1].slide=true
instrument.plugin_properties={plugin_loaded=true,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0}
local saved_effect_limit=renoise.InstrumentPhrase.MAX_NUMBER_OF_EFFECT_COLUMNS
renoise.InstrumentPhrase.MAX_NUMBER_OF_EFFECT_COLUMNS=0
local accepted,reason=generate(function(value)triplet_status=value end,bend_source,triplet_target,{pb_range=12})
assert(not accepted and reason and reason.code=='phrase.unrepresentable', 'effect column limit was ignored')
assert(instrument.phrases[triplet_target]==triplet_phrase and triplet_phrase.cells[1].note_value==triplet_first)
assert(song.tool_data==triplet_store and #instrument.phrases==triplet_target)
renoise.InstrumentPhrase.MAX_NUMBER_OF_EFFECT_COLUMNS=saved_effect_limit
instrument.plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0}
print("ACID triplet renderer metadata and transaction checks passed")

-- Document release leaves only a tombstone until native rendering settles.
local released_callback
function script:render_to_pattern(_,cb) released_callback=cb;return true end
local release_count=#instrument.phrases
local release_source=song.tool_data
assert(generate(function(value)messages[#messages+1]=value end,source_fixture(),1))
idle:fire()
local retained=instrument.phrases[#instrument.phrases]
writer.release()
local released_messages=#messages
local deleted=instrument.delete_phrase_at
instrument.delete_phrase_at=function()error("released instrument accessed")end
for _=1,600 do idle:fire() end
assert(not generate(function()end,source_fixture(),1))
released_callback(nil,8,0)
released_callback(nil,8,0)
assert(#messages==released_messages and song.tool_data==release_source)
assert(#instrument.phrases==release_count+1 and instrument.phrases[#instrument.phrases]==retained)
instrument.delete_phrase_at=deleted
instrument:delete_phrase_at(#instrument.phrases)
script.render_to_pattern=base_render
assert(generate(function(value)messages[#messages+1]=value end,source_fixture(),1))
idle:fire();idle:fire()
assert(messages[#messages].kind=="complete")
print("ACID render cancellation and release checks passed")

-- Invalidated instrument handles cannot prevent terminal notification.
local invalid_callback
function script:render_to_pattern(_,cb) invalid_callback=cb;return true end
assert(generate(function(value)messages[#messages+1]=value end,source_fixture(),1))
idle:fire()
local live_phrases=instrument.phrases
local retained_stage=live_phrases[#live_phrases]
song.instruments={}
instrument.phrases=nil
setmetatable(instrument,{__index=function()error("invalid instrument handle")end})
invalid_callback(nil,8,0)
assert(messages[#messages].kind=="complete" and messages[#messages].status=="suspended")
assert(messages[#messages].message:find("target instrument changed",1,true))
setmetatable(instrument,nil)
instrument.phrases=live_phrases
song.instruments={instrument}
assert(instrument.phrases[#instrument.phrases]==retained_stage)
instrument:delete_phrase_at(#instrument.phrases)
script.render_to_pattern=base_render
assert(generate(function(value)messages[#messages+1]=value end,source_fixture(),1))
idle:fire();idle:fire()
assert(messages[#messages].kind=="complete")
print("ACID invalidated host cleanup checks passed")

-- A native exception cannot prove the renderer stopped using staging.
local thrown_callback
function script:render_to_pattern(_,cb)
  thrown_callback=cb
  error("native call raised after launch")
end
local thrown_count=#instrument.phrases
assert(generate(function(value)messages[#messages+1]=value end,source_fixture(),1))
for _=1,600 do idle:fire() end
assert(#instrument.phrases==thrown_count+1 and not generate(function()end,source_fixture(),1))
assert(messages[#messages].code=="transaction.render_pending")
assert(messages[#messages].message:find("native call raised after launch",1,true))
thrown_callback("render failed",0,0)
assert(#instrument.phrases==thrown_count and messages[#messages].kind=="complete")
script.render_to_pattern=base_render

-- A missing commitment notification times out before native rendering starts.
local commit=script.commit
function script:commit() end
assert(generate(function(value)messages[#messages+1]=value end,source_fixture(),1))
for _=1,500 do idle:fire() end
assert(#instrument.phrases==thrown_count and messages[#messages].kind=="complete")
assert(messages[#messages].message:find("Timed out waiting for script commitment",1,true))
committed:fire()
assert(#instrument.phrases==thrown_count)
script.commit=commit
assert(generate(function(value)messages[#messages+1]=value end,source_fixture(),1))
idle:fire();idle:fire()
assert(messages[#messages].kind=="complete")
print("ACID native exception and commitment timeout checks passed")
