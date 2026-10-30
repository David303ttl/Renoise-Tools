-- Verify read-only writer occupancy state and temporary-object reporting.
dofile('tests/bootstrap.lua')('acid')
local columns=dofile('tests/acid/phrase_columns.lua')

-- Explicit bounded host capacities for the fixed three-step source.
local CAPACITY_LINES=16
local CAPACITY_NOTE_COLUMNS=4
local CAPACITY_EFFECT_COLUMNS=2

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
local insertions,last_render,copy_observer={},nil,nil
local pause_render,fail_delete,forced_insert=false,false,nil
local instrument={phrases={},samples={{sample_buffer={has_sample_data=true}}},plugin_properties={plugin_loaded=false,alias_instrument_index=0,alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},midi_output_properties={device_name=""}}
local EMPTY_SCRIPT_DIAGNOSTIC="compile error: no script content present."
local script={paragraphs={},compile_error='',runtime_error='',
  parameters={},pending_changes=0,editor_visible=true,committed_observable=committed}
function script:commit()
  self.compile_error=#self.paragraphs==0 and EMPTY_SCRIPT_DIAGNOSTIC or ""
  self.runtime_error=""
  committed:fire()
end
local function make_script()
  return setmetatable({paragraphs={},compile_error='',runtime_error='',parameters={},
    pending_changes=0,editor_visible=true},{__index=script})
end
function script:render_to_pattern(_,callback)
  local phrase=instrument.phrases[#instrument.phrases]
  local values=assert(self.paragraphs[1]:match('local values = { (.-) }\nreturn pattern'))
  local step,count=0,0
  for token in (values..','):gmatch('(.-),') do
    local volume=tonumber(token:match('volume = ([%d.]+)'))
    local note=tonumber(token:match('key = (%d+)'))
    if volume then
      local line=(step-1)*4+1
      phrase.cells[line].volume_value=volume==1 and 255 or 89
    end
    if note or token:find('"off"',1,true) or token:match('^%s*false%s*$') then
      step=step+1
      local line=(step-1)*4+1
      if note or token:find('"off"',1,true) then
        phrase.cells[line].note_value=note or 120
        count=count+1
      end
    end
  end
  if pause_render then last_render=callback
  else callback(nil,count,0) end
  return true
end
local properties={'name','number_of_lines','lpb','shuffle','playback_mode','looping',
  'loop_start','loop_end','key_tracking','base_note','autoseek','visible_note_columns',
  'visible_effect_columns','instrument_column_visible','volume_column_visible',
  'panning_column_visible','delay_column_visible','sample_effects_column_visible'}
function instrument:insert_phrase_at(index)
  if forced_insert then
    table.insert(self.phrases,index,forced_insert)
    insertions[#insertions+1]=forced_insert
    return forced_insert
  end
  local phrase={name='',number_of_lines=16,lpb=16,shuffle=0,playback_mode=1,
    key_tracking=1,base_note=48,autoseek=false,visible_note_columns=1,
    visible_effect_columns=0,looping=false,loop_start=1,loop_end=16,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,script=make_script(),cells={}}
  for line=1,CAPACITY_LINES do
    phrase.cells[line]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function phrase:line(line) return columns.line(self,line) end
  function phrase:column_is_muted() return false end
  function phrase:column_name(column) return "column "..tostring(column) end
  function phrase:copy_from(other)
    if copy_observer then copy_observer(self) end
    columns.copy(self,other)
    for _,key in ipairs(properties) do self[key]=other[key] end
    self.cells={}
    for line,cell in ipairs(other.cells) do
      local copy={}
      for key,value in pairs(cell) do copy[key]=value end
      self.cells[line]=copy
    end
  end
  table.insert(self.phrases,index,phrase)
  insertions[#insertions+1]=phrase
  return phrase
end
function instrument:delete_phrase_at(index)
  if fail_delete then return end
  table.remove(self.phrases,index)
end
local song={instruments={instrument},transport={timing_model=2}}
_G.renoise={InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1,
    MAX_NUMBER_OF_LINES=CAPACITY_LINES,
    MAX_NUMBER_OF_NOTE_COLUMNS=CAPACITY_NOTE_COLUMNS,
    MAX_NUMBER_OF_EFFECT_COLUMNS=CAPACITY_EFFECT_COLUMNS},
  Transport={TIMING_MODEL_SPEED=1,TIMING_MODEL_LPB=2},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function()return song end,tool=function()return {app_idle_observable=idle} end}
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

local idle_count,token=writer.state()
assert(idle_count=='idle' and token==nil and select('#',writer.state())==2,
  'writer.state must expose only a detached status and token')
assert(writer.temporaries==nil and writer.register_temporary==nil
  and writer.list_temporaries==nil,'writer exposed temporary registry authority')

local function generate(target,options)
  local request,rejection=writer_request.build(renoise.song(),1,pattern,target or 1,
    options or {output_policy='play_once'})
  if not request then return false,rejection end
  local operation=request.kind=='create' and writer.create or writer.regenerate
  return operation(request,completion)
end

local first_token={current=true}
function first_token:is_current() return self.current==true end
local before=#insertions
assert(generate(1,{output_policy='play_once',token=first_token}))
local first_busy,first_busy_token=writer.state()
assert(first_busy=='busy' and rawequal(first_busy_token,first_token),
  'writer.state did not return the exact operation token')
assert(boundary:request_generation('manual')==false
  and captured_requests==0 and sink_requests==0,
  'runtime admitted capture or sink while the real writer was occupied')
idle:fire()
assert(status and status.status=='committed',tostring(status and status.message))
local created=insertions[before+1]
assert(created and rawequal(instrument.phrases[1],created))
local completed_status,completed_token=writer.state()
assert(completed_status=='idle' and completed_token==nil,'committed write stayed occupied')
assert(writer.is_temporary(song,instrument,created)==false,
  'committed create destination remained temporary')
assert(boundary:request_generation('manual')==true
  and captured_requests==1 and sink_requests==1,
  'runtime did not admit the test sink after real writer retirement')

local second_token={current=true}
function second_token:is_current() return self.current==true end
pause_render=true
before=#insertions
assert(generate(2,{output_policy='play_once',token=second_token}))
local busy_status,busy_token=writer.state()
assert(busy_status=='busy' and rawequal(busy_token,second_token),
  'writer.state did not return the exact operation token')
local staging=insertions[before+1]
assert(staging and rawequal(instrument.phrases[#instrument.phrases],staging))
assert(writer.is_temporary(song,instrument,staging)==true)
assert(writer.is_temporary(song,instrument,created)==false,
  'existing destination was reported as temporary')
assert(writer.is_temporary(song,instrument,{})==false,
  'unrecorded object was reported as temporary')
local other_instrument={phrases={staging}}
local other_song={instruments={other_instrument}}
assert(writer.is_temporary(song,other_instrument,staging)==false
  and writer.is_temporary(other_song,instrument,staging)==false,
  'temporary lookup accepted a cross-instrument or cross-song pairing')
local content_equal={name=staging.name,cells=staging.cells}
local content_equality={__eq=function() return true end}
setmetatable(content_equal,content_equality)
setmetatable(staging,content_equality)
assert(content_equal==staging and not rawequal(content_equal,staging),
  'phrase identity fixture must compare equal by content but not by identity')
assert(writer.is_temporary(song,instrument,staging)==true
  and writer.is_temporary(song,instrument,content_equal)==false,
  'temporary lookup used content equality instead of raw identity')
assert(#instrument.phrases==2 and staging.name==writer.PHRASE_NAME,
  'read-only inspection changed the staging phrase')
idle:fire()
assert(last_render,'paused render did not start')
last_render('inspection cleanup',0,0)
completed_status,completed_token=writer.state()
assert(completed_status=='idle' and completed_token==nil)
assert(#instrument.phrases==1 and writer.is_temporary(song,instrument,staging)==false,
  'failed render cleanup left a temporary phrase recorded')

-- The explicit contract requires an operation token. A missing token is
-- rejected before insertion rather than becoming tokenless occupancy.
local missing_token_request=assert(writer_request.build(song,1,pattern,2,
  {output_policy='play_once'}))
missing_token_request.token=nil
local missing_token_before=#insertions
local missing_token_started,missing_token_rejection=writer.create(missing_token_request,completion)
assert(not missing_token_started and missing_token_rejection.code=='source.token',
  'writer accepted a request without an operation token')
assert(writer.state()=='idle' and #instrument.phrases==1
  and #insertions==missing_token_before,
  'missing-token rejection mutated the host or retained occupancy')

local external_token={current=true}
function external_token:is_current() return true end
pause_render=true
before=#insertions
assert(generate(2,{output_policy='play_once',token=external_token}))
busy_status,busy_token=writer.state()
assert(busy_status=='busy' and rawequal(busy_token,external_token),
  'writer.state did not return the exact operation token')
assert(boundary:request_generation('live_edit')==false
  and captured_requests==1 and sink_requests==1,
  'runtime dispatched while the real writer was occupied')
staging=insertions[before+1]
assert(writer.is_temporary(song,instrument,staging)==true)
idle:fire()
local staging_index
for index,item in ipairs(instrument.phrases) do
  if rawequal(item,staging) then staging_index=index end
end
assert(staging_index,'staging phrase missing before external removal')
instrument:delete_phrase_at(staging_index)
assert(writer.is_temporary(song,instrument,staging)==false,
  'temporary lookup ignored current raw membership')
last_render('external removal',0,0)
assert(writer.state()=='idle' and #instrument.phrases==1)

local shared_eq={__eq=function() return true end}
local function adversarial_token()
  local value={current=true}
  function value:is_current() return self.current==true end
  return setmetatable(value,shared_eq)
end
local exact_token,impostor_token=adversarial_token(),adversarial_token()
assert(exact_token==impostor_token and not rawequal(exact_token,impostor_token),
  'adversarial tokens do not exercise equality without raw identity')
pause_render=true
before=#insertions
assert(generate(2,{output_policy='play_once',token=exact_token}))
local eq_busy,eq_token=writer.state()
assert(eq_busy=='busy' and rawequal(eq_token,exact_token))
staging=insertions[before+1]
assert(writer.cancel(impostor_token)==false and writer.state()=='busy',
  'cancel accepted a non-identical token through __eq')
local still_busy,still_token=writer.state()
assert(still_busy=='busy' and rawequal(still_token,exact_token)
  and #instrument.phrases==2 and writer.is_temporary(song,instrument,staging)==true,
  'impostor cancel changed occupancy or temporary bookkeeping')
assert(writer.cancel(exact_token)==true)
local cancelled_busy,cancelled_token=writer.state()
assert(cancelled_busy=='busy' and rawequal(cancelled_token,exact_token)
  and #instrument.phrases==2 and writer.is_temporary(song,instrument,staging)==true,
  'in-flight cancellation released native render occupancy before its callback')
last_render('cancelled native render',0,0)
assert(writer.state()=='idle' and #instrument.phrases==1
  and writer.is_temporary(song,instrument,staging)==false)

local release_token={current=true}
function release_token:is_current() return true end
before=#insertions
assert(generate(2,{output_policy='play_once',token=release_token}))
local released_stage=insertions[before+1]
idle:fire()
writer.release()
local released_status,released_identity=writer.state()
assert(released_status=='busy' and rawequal(released_identity,release_token),
  'release lost the exact operation token')
writer.release()
local repeated_status,repeated_identity=writer.state()
assert(repeated_status=='busy' and rawequal(repeated_identity,release_token),
  'repeated release overwrote the exact operation token')
assert(writer.is_temporary(song,instrument,released_stage)==false,
  'release retained temporary registry references')
assert(writer.cancel(release_token)==true,
  'released matching token was not recognized')
local still_released,still_released_token=writer.state()
assert(still_released=='busy' and rawequal(still_released_token,release_token)
  and writer.is_temporary(song,instrument,released_stage)==false,
  'after-release cancel retired the pending native render')
last_render('released terminal',0,0)
assert(writer.state()=='idle' and select('#',writer.state())==2)
assert(writer.is_temporary(song,instrument,released_stage)==false,
  'late terminal revived scrubbed temporary bookkeeping')
local released_index
for index,item in ipairs(instrument.phrases) do
  if rawequal(item,released_stage) then released_index=index end
end
assert(released_index,'released staging phrase missing')
instrument:delete_phrase_at(released_index)
assert(writer.is_temporary(song,instrument,released_stage)==false
  and #instrument.phrases==1)

fail_delete=true
before=#insertions
assert(generate(2,{output_policy='play_once'}))
local recovery_stage=insertions[before+1]
idle:fire()
last_render('render failed',0,0)
assert(writer.state()=='idle' and #instrument.phrases==2)
assert(recovery_stage.name=='ACID RECOVERY STAGING')
assert(writer.is_temporary(song,instrument,recovery_stage)==true,
  'retained recovery phrase was not reported as temporary')
fail_delete=false
local recovery_index
for index,item in ipairs(instrument.phrases) do
  if rawequal(item,recovery_stage) then recovery_index=index end
end
assert(recovery_index,'retained recovery phrase missing')
instrument:delete_phrase_at(recovery_index)
assert(writer.is_temporary(song,instrument,recovery_stage)==false
  and #instrument.phrases==1)

pause_render=false
local observed={}
copy_observer=function(phrase)
  observed[phrase]=writer.is_temporary(song,instrument,phrase)
end
before=#insertions
assert(generate(1,{output_policy='play_once',token=first_token}))
idle:fire()
copy_observer=nil
assert(status and status.status=='committed',tostring(status and status.message))
local regenerated_staging,regenerated_backup=insertions[before+1],insertions[before+2]
assert(regenerated_staging and regenerated_backup,'regeneration did not insert stage and backup')
assert(observed[regenerated_backup]==true,
  'regeneration backup was not reported as temporary during copy')
assert(writer.is_temporary(song,instrument,regenerated_staging)==false
  and writer.is_temporary(song,instrument,regenerated_backup)==false,
  'committed regeneration left temporary bookkeeping')
assert(#instrument.phrases==1 and writer.state()=='idle')

-- Integration through the explicit contract: capture returns a real request
-- carrying the runtime token, and the sink dispatches it through the matching
-- facade. Only the writer's single terminal result calls done.
local real_delivered,real_accepted
local real_boundary=context.new{
  writer=writer,
  capture=function(_,request_token)
    local request,rejection=writer_request.build(song,1,pattern,1,
      {output_policy='play_once',token=request_token})
    assert(request,type(rejection)=='table' and rejection.message or rejection)
    return request
  end,
  sink=function(request,done)
    local operation=request.kind=='create' and writer.create or writer.regenerate
    real_accepted=operation(request,function(result)
      real_delivered=result
      done(result)
    end)
    if real_accepted then return true end
    return false,'real writer rejected the request'
  end,
}
assert(real_boundary:request_generation('manual')==true and real_accepted==true)
assert(real_boundary:state().status=='pending' and writer.state()=='busy',
  'legacy writer status notification settled the runtime delivery record')
idle:fire()
assert(real_delivered and real_delivered.status=='committed',
  tostring(real_delivered and real_delivered.message))
assert(real_boundary:state().status=='idle' and writer.state()=='idle')
assert(#instrument.phrases==1)

-- A stale temporary record for the same object in another song must not hide
-- a later valid record for the queried song.
local original_song_lookup=renoise.song
local shadow_phrase=instrument:insert_phrase_at(#instrument.phrases+1)
table.remove(instrument.phrases,#instrument.phrases)
local shadow_song={instruments={instrument},transport={timing_model=2}}
local shadow_token_a,shadow_token_b={current=true},{current=true}
function shadow_token_a:is_current() return true end
function shadow_token_b:is_current() return true end
forced_insert=shadow_phrase
fail_delete=true
pause_render=true
assert(generate(#instrument.phrases+1,{output_policy='play_once',token=shadow_token_a}))
assert(writer.cancel(shadow_token_a)==true)
local shadow_first_render=last_render
assert(shadow_first_render,'first shadow render did not start')
shadow_first_render('shadow first cancellation',0,0)
assert(writer.state()=='idle','first shadow cancellation did not settle')
table.remove(instrument.phrases,#instrument.phrases)
renoise.song=function() return shadow_song end
assert(generate(#instrument.phrases+1,{output_policy='play_once',token=shadow_token_b}))
assert(writer.cancel(shadow_token_b)==true)
assert(writer.is_temporary(shadow_song,instrument,shadow_phrase)==true,
  'earlier mismatched temporary record shadowed a later valid record')
local shadow_second_render=last_render
assert(shadow_second_render,'second shadow render did not start')
shadow_second_render('shadow second cancellation',0,0)
assert(writer.state()=='idle','second shadow cancellation did not settle')
pause_render=false
fail_delete=false
forced_insert=nil
local shadow_index
for index,item in ipairs(instrument.phrases) do
  if rawequal(item,shadow_phrase) then shadow_index=index end
end
assert(shadow_index,'shadow test phrase missing')
instrument:delete_phrase_at(shadow_index)
assert(writer.is_temporary(shadow_song,instrument,shadow_phrase)==false
  and writer.is_temporary(song,instrument,shadow_phrase)==false)
renoise.song=original_song_lookup
assert(#instrument.phrases==1)
print('ACID writer inspection state and temporary-object checks passed (mocked Renoise)')
