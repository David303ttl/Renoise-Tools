-- Focused writer safety checks: capacity boundaries, verified backups, guarded
-- rollback, cleanup blockers, postcommit baselines and late native callbacks.
dofile("tests/bootstrap.lua")("acid")
local columns=dofile("tests/acid/phrase_columns.lua")
local pitch=dofile("tests/acid/pitch_fixture.lua")

local EMPTY_SCRIPT_DIAGNOSTIC="compile error: no script content present."
-- Bounded non-boundary phrase caps keep the focused safety checks cheap while
-- still exceeding the largest repeat layout these sources produce.
local PHRASE_MAX_LINES=32
local PHRASE_NOTE_COLUMNS=4
local PHRASE_EFFECT_COLUMNS=1

local function observable()
  local handlers={}
  return {
    add_notifier=function(_,callback) handlers[callback]=true end,
    remove_notifier=function(_,callback) handlers[callback]=nil end,
    fire=function()
      local pending={}
      for callback in pairs(handlers) do pending[#pending+1]=callback end
      for _,callback in ipairs(pending) do callback() end
    end,
  }
end

local idle,committed=observable(),observable()
local instrument,song
local render_mode="sync"
local defer_commit=false
local commit_failure=false
local suppress_commit_notifications=false
local suppress_empty_commit_notification=false
local corrupt_backup=false
local copy_failure_after=nil
local copy_calls=0
local insert_failure=false
local insert_calls=0
local backup_insert_behavior=nil
local inserted_backup_phrase=nil
local fail_inserted_backup_delete=false
local delete_failure=nil
local render_queue={}
local last_render_options=nil
local last_script_steps=nil
local inventory_read_failure=false
local unreadable_inventory=nil

local function make_script()
  local script={paragraphs={},parameters={},pending_changes=0,editor_visible=true,
    compile_error="",runtime_error="",committed_observable=committed}
  function script:commit()
    if commit_failure then error("injected script commit failure",0) end
    self.compile_error=#self.paragraphs==0 and EMPTY_SCRIPT_DIAGNOSTIC or ""
    self.runtime_error=""
    if suppress_commit_notifications or
        (#self.paragraphs==0 and suppress_empty_commit_notification) then return end
    if defer_commit then
      local notify
      notify=function()
        idle:remove_notifier(notify)
        committed:fire()
      end
      idle:add_notifier(notify)
    else
      committed:fire()
    end
  end
  function script:render_to_pattern(options,callback)
    last_render_options=options
    local source=assert(self.paragraphs[1])
    local values=assert(source:match("local values = { (.-) }\nreturn pattern"))
    local pulses=assert(source:match('pulse = { (.-) }'))
    local target=instrument.phrases[#instrument.phrases]
    local step,count=0,0
    local script_steps=0
    for _ in (pulses..","):gmatch("(.-),") do script_steps=script_steps+1 end
    for token in (values..","):gmatch("(.-),") do
      local volume=tonumber(token:match("volume = ([%d%.]+)"))
      local note=tonumber(token:match("key = (%d+)"))
      local off=token:find('"off"',1,true)~=nil
      local empty=token:match("^%s*false%s*$")~=nil
      if volume then
        local line=(math.max(step,1)-1)*4+1
        target.cells[line].volume_value=volume==1 and 255 or 89
      end
      if note or off or empty then
        step=step+1
        local line=(step-1)*4+1
        if note then
          target.cells[line].note_value=note
          count=count+1
        elseif off then
          target.cells[line].note_value=120
          count=count+1
        end
      end
    end
    last_script_steps=script_steps
    if render_mode=="defer" then
      render_queue[#render_queue+1]={callback=callback,count=count}
      return true
    elseif render_mode=="double" then
      callback(nil,count,0)
      callback(nil,count,0)
      return true
    elseif render_mode=="error" then
      callback("injected native render failure",0,0)
      return true
    end
    callback(nil,count,0)
    return true
  end
  return script
end

local function make_phrase()
  local phrase={name="",number_of_lines=16,lpb=16,shuffle=0,looping=false,
    loop_start=1,loop_end=16,playback_mode=1,key_tracking=1,base_note=48,
    autoseek=false,visible_note_columns=1,visible_effect_columns=0,
    instrument_column_visible=false,volume_column_visible=true,
    panning_column_visible=false,delay_column_visible=false,
    sample_effects_column_visible=false,mapping=nil,cells={},
    script=make_script(),column_names={},column_mutes={}}
  for column=1,12 do
    phrase.column_names[column]="column "..column
    phrase.column_mutes[column]=false
  end
  for line=1,PHRASE_MAX_LINES do
    phrase.cells[line]={note_value=121,instrument_value=255,volume_value=255,
      panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}
  end
  function phrase:line(index) return columns.line(self,index) end
  function phrase:column_name(column) return self.column_names[column] end
  function phrase:column_is_muted(column) return self.column_mutes[column] end
  function phrase:set_column_name(column,name) self.column_names[column]=name end
  function phrase:set_column_is_muted(column,muted) self.column_mutes[column]=muted end
  function phrase:copy_from(other)
    copy_calls=copy_calls+1
    if copy_failure_after and copy_calls>copy_failure_after then
      self.cells[1].note_value=0
      error("injected destination copy failure",0)
    end
    for _,key in ipairs({"name","number_of_lines","lpb","shuffle","looping",
      "loop_start","loop_end","playback_mode","key_tracking","base_note",
      "autoseek","visible_note_columns","visible_effect_columns",
      "instrument_column_visible","volume_column_visible",
      "panning_column_visible","delay_column_visible",
      "sample_effects_column_visible"}) do
      self[key]=other[key]
    end
    self.cells={}
    for line=1,PHRASE_MAX_LINES do
      local copy={}
      for key,value in pairs(other.cells[line] or {}) do copy[key]=value end
      self.cells[line]=copy
    end
    for column=1,12 do
      self.column_names[column]=other.column_names[column]
      self.column_mutes[column]=other.column_mutes[column]
    end
    self._line_cache=nil
    self.extra_cells=nil
    self.effect_cells=nil
    if corrupt_backup then
      corrupt_backup=false
      self.cells[1].note_value=0
    end
  end
  return phrase
end

local function new_host(capacity)
  copy_calls,copy_failure_after=0,nil
  insert_calls=0
  instrument={name="Writer safety",phrases={},
    samples={{sample_buffer={has_sample_data=true}}},
    plugin_properties={plugin_loaded=false,alias_instrument_index=0,
      alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0},
    midi_output_properties={device_name="",instrument_type=1,channel=1},
    phrase_playback_mode=2,phrase_program=1}
  function instrument:insert_phrase_at(index)
    insert_calls=insert_calls+1
    if insert_failure then error("injected phrase insertion failure",0) end
    assert(index==#self.phrases+1,"phrase insertion must append")
    local phrase=make_phrase()
    self.phrases[index]=phrase
    if insert_calls==2 then inserted_backup_phrase=phrase end
    if insert_calls==2 and backup_insert_behavior=="throw_after_insert" then
      error("injected backup insertion failure after mutation",0)
    elseif insert_calls==1 and backup_insert_behavior=="throw_after_stage_insert" then
      error("injected staging insertion failure after mutation",0)
    elseif insert_calls==1 and inventory_read_failure then
      unreadable_inventory=self.phrases
      self.phrases=nil
      setmetatable(self,{__index=function(_,key)
        if key=="phrases" and inventory_read_failure then
          error("injected unreadable phrase inventory",0)
        end
      end})
    elseif insert_calls==2 and backup_insert_behavior=="nil_after_insert" then
      return nil
    elseif insert_calls==2 and backup_insert_behavior=="ambiguous_extra" then
      self.phrases[index+1]=make_phrase()
      return nil
    elseif insert_calls==2 and backup_insert_behavior=="ambiguous_reorder" then
      self.phrases={phrase,self.phrases[2],self.phrases[1]}
      return nil
    elseif insert_calls==2 and backup_insert_behavior=="return_existing_backup" then
      return self.phrases[1]
    elseif insert_calls==1 and backup_insert_behavior=="return_existing_stage" then
      return self.phrases[1]
    elseif insert_calls==2 and backup_insert_behavior=="return_foreign_backup" then
      return {}
    elseif insert_calls==1 and backup_insert_behavior=="return_foreign_stage" then
      return {}
    end
    return phrase
  end
  function instrument:delete_phrase_at(index)
    local phrase=self.phrases[index]
    if not phrase then error("missing phrase at index "..tostring(index),0) end
    if fail_inserted_backup_delete and rawequal(phrase,inserted_backup_phrase) then
      error("injected uncertain backup cleanup failure",0)
    end
    if delete_failure and delete_failure(phrase) then
      error("injected phrase deletion failure",0)
    end
    table.remove(self.phrases,index)
  end
  song={instruments={instrument},tool_data="",transport={timing_model=2,lpb=16,
    tpl=12,groove_enabled=false}}
  function song:is_undo_redoing() return false end
  _G.renoise.Instrument.MAX_NUMBER_OF_PHRASES=capacity or 126
  _G.renoise.song=function() return song end
  return song,instrument
end

_G.renoise={
  Transport={TIMING_MODEL_LPB=2,TIMING_MODEL_SPEED=1},
  InstrumentPhrase={PLAY_SCRIPT=2,PLAY_PATTERN=1,KEY_TRACKING_NONE=1,
    MAX_NUMBER_OF_LINES=PHRASE_MAX_LINES,MAX_NUMBER_OF_NOTE_COLUMNS=PHRASE_NOTE_COLUMNS,
    MAX_NUMBER_OF_EFFECT_COLUMNS=PHRASE_EFFECT_COLUMNS},
  Instrument={PHRASES_PLAY_SELECTIVE=2,MAX_NUMBER_OF_PHRASES=126},
  song=function() return song end,
  tool=function() return {app_idle_observable=idle} end,
}

local writer=require("writers.phrase_writer")
local wrequest=dofile("tests/acid/writer_request.lua")
local store=require("renoise.pattern_store")
local ownership=require("renoise.phrase_ownership")
local sequencer=require("model.sequencer")

local release_candidate_calls=0
local store_release_candidate=store.release_candidate
store.release_candidate=function(candidate)
  if candidate~=nil then release_candidate_calls=release_candidate_calls+1 end
  return store_release_candidate(candidate)
end
local allocated_id
local store_allocate=store.allocate
store.allocate=function(target_song)
  local id,err=store_allocate(target_song)
  if id then allocated_id=id end
  return id,err
end

render_mode,defer_commit,corrupt_backup="sync",false,false
insert_failure,delete_failure=false,nil
backup_insert_behavior=nil
inserted_backup_phrase=nil
fail_inserted_backup_delete=false

local function source(note)
  local pattern=sequencer.new_pattern(2)
  pattern.pitch_length=2
  pattern.pitch_events[1]=pitch(note)
  pattern.pitch_events[2]=pitch(note+2)
  pattern.time_events[1]="N"
  pattern.time_events[2]="N"
  return pattern
end

local recorded_blockers=setmetatable({},{__mode="k"})

local function build(pattern,target_index,options)
  local request,reason=wrequest.build(song,1,pattern,target_index,options)
  assert(request,type(reason)=="table" and reason.message or tostring(reason))
  local request_song=song
  local is_current=request.is_current
  local validate_checkpoint=request.validate_checkpoint
  local record_blocker=request.record_blocker
  function request:is_current()
    return not recorded_blockers[request_song] and is_current(self)
  end
  function request:validate_checkpoint()
    if recorded_blockers[request_song] then return false,"Song integrity requires revalidation" end
    return validate_checkpoint(self)
  end
  function request:record_blocker(token,evidence)
    local recorded=record_blocker(self,token,evidence)
    if recorded then recorded_blockers[request_song]=true end
    return recorded
  end
  return request
end

local function start(request,done)
  local operation=request.kind=="create" and writer.create or writer.regenerate
  local calls={}
  local accepted,rejection=operation(request,function(result)
    calls[#calls+1]=result
    if result.kind=="failure" then assert(result.phrase==nil,"failure exposed a destination phrase") end
    if done then done(result) end
  end)
  return accepted,rejection,calls
end

local function assert_writer_blocks_followup()
  local later=build(source(58),2)
  local operation=later.kind=="create" and writer.create or writer.regenerate
  local calls=0
  local accepted,rejection=operation(later,function() calls=calls+1 end)
  assert(not accepted and rejection.status=="integrity_blocked")
  assert(calls==0)
end

local function drain(limit)
  for _=1,limit or 60 do
    idle:fire()
    if writer.state()=="idle" then return end
  end
  error("writer did not settle")
end

local function assert_recorded_blocker_prevents_write()
  local count,raw,inserts=#instrument.phrases,song.tool_data,insert_calls
  local request=build(source(58),count+1)
  local accepted,rejection,calls=start(request)
  if accepted then
    drain()
    assert(#calls==1 and calls[1].kind=="failure" and calls[1].phrase==nil)
  else
    assert(rejection.kind=="failure" and rejection.phrase==nil and #calls==0)
  end
  assert(#instrument.phrases==count and song.tool_data==raw and insert_calls==inserts,
    "recorded integrity blocker allowed a subsequent mutation")
end

local function assert_idle()
  local status=writer.state()
  assert(status=="idle","writer remained "..tostring(status))
end

local function create_owned(note,capacity)
  local host_instrument
  song,host_instrument=new_host(capacity)
  local request=build(source(note),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="success",calls[1] and calls[1].message or "create failed")
  return host_instrument,calls[1].phrase,song
end

local function create_owned_rests()
  local host_instrument
  song,host_instrument=new_host()
  local pattern=sequencer.new_pattern(2)
  pattern.time_events[1],pattern.time_events[2]="R","R"
  local request=build(pattern,1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="success",calls[1] and calls[1].message or "rest phrase create failed")
  return host_instrument,calls[1].phrase,song
end

local function snapshot(phrase)
  return assert(ownership.snapshot(phrase))
end

local function assert_same_snapshot(actual,expected,label)
  local same,difference=ownership.compare(actual,expected)
  assert(same,label..": "..tostring(difference))
end

do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  insert_calls=0
  backup_insert_behavior="throw_after_stage_insert"
  local request=build(source(56),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  backup_insert_behavior=nil
  assert(#calls==1 and calls[1].kind=="failure")
  assert(calls[1].integrity_blocked~=true,calls[1].message)
  assert(rawequal(host_instrument.phrases[1],phrase))
  assert_same_snapshot(snapshot(phrase),before,"failed staging insertion changed destination")
  assert(#host_instrument.phrases==1,
    "uniquely identified phrase from a thrown staging insertion was not cleaned")
end

-- A non-nil insertion result is trusted only when it is the unique inventory
-- addition. A mismatched result is never used as a phrase mutation target.
do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  insert_calls=0
  backup_insert_behavior="return_existing_backup"
  local request=build(source(56),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  backup_insert_behavior=nil
  assert(#calls==1 and calls[1].kind=="failure")
  assert(calls[1].integrity_blocked==true,calls[1].message)
  assert(rawequal(host_instrument.phrases[1],phrase))
  assert_same_snapshot(snapshot(phrase),before,"mismatched backup insertion changed destination")
  assert(#host_instrument.phrases==2,"mismatched backup result was cleaned as if it were the insertion")
end

do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  insert_calls=0
  backup_insert_behavior="return_existing_stage"
  local request=build(source(56),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  backup_insert_behavior=nil
  assert(#calls==1 and calls[1].kind=="failure")
  assert(calls[1].integrity_blocked==true,calls[1].message)
  assert(rawequal(host_instrument.phrases[1],phrase))
  assert_same_snapshot(snapshot(phrase),before,"mismatched staging insertion changed destination")
  assert(#host_instrument.phrases==2,"mismatched staging result was cleaned as if it were the insertion")
end

for _,behavior in ipairs({"return_foreign_backup","return_foreign_stage"}) do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  insert_calls=0
  backup_insert_behavior=behavior
  local request=build(source(56),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  backup_insert_behavior=nil
  assert(#calls==1 and calls[1].kind=="failure")
  assert(calls[1].integrity_blocked==true,calls[1].message)
  assert(rawequal(host_instrument.phrases[1],phrase))
  assert_same_snapshot(snapshot(phrase),before,"foreign insertion result changed destination")
  assert(#host_instrument.phrases==2,
    "foreign insertion result was used to clean or mutate an inventory phrase")
end

local function reseal(phrase)
  phrase.name=assert(ownership.make_name(phrase,assert(ownership.id(phrase))))
end

local function hide_volume_column(phrase)
  phrase.volume_column_visible=false
  phrase.panning_column_visible=true
  phrase.base_note=43
  phrase.autoseek=true
  reseal(phrase)
end

-- Rejection is false with no callback, no host mutation and no occupied slot.
do
  new_host()
  assert_idle()
  local calls=0
  local accepted,rejection=writer.create({},function() calls=calls+1 end)
  assert(not accepted and type(rejection)=="table" and rejection.code=="source.request_kind")
  assert(calls==0 and #instrument.phrases==0 and song.tool_data=="")
  local request=build(source(48),1)
  accepted,rejection=writer.create(request,nil)
  assert(not accepted and rejection.code=="source.callback")
  assert(calls==0 and #instrument.phrases==0 and song.tool_data=="")
  local invalid=build(source(48),1)
  invalid.source={}
  accepted,rejection=writer.create(invalid,function() calls=calls+1 end)
  assert(not accepted and rejection.code=="source.invalid" and rejection.category=="source")
  assert(calls==0 and #instrument.phrases==0 and song.tool_data=="")
  assert_idle()
end

-- Host-dependent preflight getter failures reject before mutation or callback.
do
  new_host()
  local request=build(source(48),1)
  request.instrument=nil
  setmetatable(request,{__index=function(_,key)
    if key=="instrument" then error("injected unreadable instrument identity",0) end
  end})
  local calls=0
  local accepted,rejection=writer.create(request,function() calls=calls+1 end)
  assert(not accepted and rejection.code=="safety.preflight",rejection and rejection.message)
  assert(calls==0 and #instrument.phrases==0 and song.tool_data=="")
  assert_idle()
end

do
  new_host()
  local request=build(source(48),1)
  instrument.phrases=nil
  setmetatable(instrument,{__index=function(_,key)
    if key=="phrases" then error("injected unreadable phrase inventory",0) end
  end})
  local calls=0
  local accepted,rejection=writer.create(request,function() calls=calls+1 end)
  assert(not accepted and type(rejection)=="table")
  assert(calls==0 and song.tool_data=="")
  assert_idle()
end

do
  local host_instrument,phrase=create_owned(48)
  local request=build(source(52),1)
  local original_name=phrase.name
  phrase.name=nil
  setmetatable(phrase,{__index=function(_,key)
    if key=="name" then error("injected unreadable phrase identity",0) end
  end})
  local calls=0
  local accepted,rejection=writer.regenerate(request,function() calls=calls+1 end)
  setmetatable(phrase,nil)
  phrase.name=original_name
  assert(not accepted and type(rejection)=="table")
  assert(calls==0 and #host_instrument.phrases==1 and song.tool_data~="")
  assert_idle()
end

-- Capacity boundaries: create needs one free slot before staging; regenerate
-- needs two before staging and one after the stage exists.
do
  local host_instrument,phrase=create_owned(48,2)
  assert(#host_instrument.phrases==1 and phrase)
  local second=build(source(50),2)
  local accepted,rejection,calls=start(second)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="success")
  assert(#host_instrument.phrases==2)
  local before_raw=song.tool_data
  local before_names={}
  for index,item in ipairs(host_instrument.phrases) do before_names[index]=item.name end
  local full_calls={}
  local full_request=build(source(52),3)
  local full_accepted,full_rejection=writer.create(full_request,function(result)
    full_calls[#full_calls+1]=result
  end)
  assert(not full_accepted and full_rejection.code=="safety.phrase_capacity")
  assert(#full_calls==0 and #host_instrument.phrases==2 and song.tool_data==before_raw)
  for index,item in ipairs(host_instrument.phrases) do
    assert(item.name==before_names[index])
  end
  -- Regenerate with one free slot is rejected before staging.
  local one_free=build(source(54),1)
  local one_accepted,one_rejection=writer.regenerate(one_free,function() error("unexpected callback") end)
  assert(not one_accepted and one_rejection.code=="safety.phrase_capacity")
  assert(#host_instrument.phrases==2 and song.tool_data==before_raw)
  -- Regenerate with two free slots stages, backs up and returns to two phrases.
  _G.renoise.Instrument.MAX_NUMBER_OF_PHRASES=4
  local two_free=build(source(56),1)
  local two_accepted,two_rejection,two_calls=start(two_free)
  assert(two_accepted,two_rejection and two_rejection.message)
  drain()
  assert(#two_calls==1 and two_calls[1].kind=="success",two_calls[1] and two_calls[1].message)
  assert(#host_instrument.phrases==2 and rawequal(host_instrument.phrases[1],phrase))
end

-- Missing and malformed native capacity metadata rejects before mutation.
do
  new_host()
  local request=build(source(48),1)
  local calls=0
  local function rejected(code,expected_phrases)
    local phrase_count=#instrument.phrases
    local raw=song.tool_data
    local accepted,rejection=writer.create(request,function() calls=calls+1 end)
    assert(not accepted and rejection.code==code,rejection and rejection.message)
    assert(calls==0 and #instrument.phrases==(expected_phrases or phrase_count) and
      song.tool_data==raw)
    assert_idle()
  end
  local instrument_api=renoise.Instrument
  for _,value in ipairs({false,0,1.5,-1}) do
    instrument_api.MAX_NUMBER_OF_PHRASES=value
    rejected("capability.capacity")
  end
  instrument_api.MAX_NUMBER_OF_PHRASES=nil
  rejected("capability.capacity")
  instrument_api.MAX_NUMBER_OF_PHRASES=126

  local phrase_api=renoise.InstrumentPhrase
  for _,case in ipairs({
      {key="MAX_NUMBER_OF_LINES",value=false},
      {key="MAX_NUMBER_OF_LINES",value=0},
      {key="MAX_NUMBER_OF_LINES",value=1.5},
      {key="MAX_NUMBER_OF_NOTE_COLUMNS",value=nil},
      {key="MAX_NUMBER_OF_NOTE_COLUMNS",value=0},
      {key="MAX_NUMBER_OF_EFFECT_COLUMNS",value=-1},
      {key="MAX_NUMBER_OF_EFFECT_COLUMNS",value=1.5},
    }) do
    local original=phrase_api[case.key]
    phrase_api[case.key]=case.value
    rejected("capability.limits")
    phrase_api[case.key]=original
  end

  -- A valid integer limit smaller than the live inventory is still unsafe.
  instrument.phrases={make_phrase(),make_phrase()}
  instrument_api.MAX_NUMBER_OF_PHRASES=1
  rejected("safety.phrase_capacity",2)
  instrument_api.MAX_NUMBER_OF_PHRASES=126
end

-- Native idle bounds fire at the documented 500th opportunity. Compile and
-- clear waits fail safely; the render threshold only diagnoses and retains the
-- occupied slot until its native callback settles.
do
  new_host()
  local request=build(source(48),1)
  local accepted,rejection,calls

  suppress_commit_notifications=true
  accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  for _=1,499 do idle:fire() end
  assert(#calls==0 and writer.state()=="busy",
    "compile wait expired before its 500th idle opportunity")
  idle:fire()
  suppress_commit_notifications=false
  assert(#calls==1 and calls[1].kind=="failure" and
    calls[1].code=="transaction.render" and writer.state()=="idle",
    "compile wait did not expire at its 500th idle opportunity")

  new_host()
  suppress_empty_commit_notification=true
  request=build(source(50),1)
  accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  assert(#calls==0 and writer.state()=="busy")
  for _=1,499 do idle:fire() end
  assert(#calls==0 and writer.state()=="busy",
    "script-clear wait expired before its 500th idle opportunity")
  idle:fire()
  suppress_empty_commit_notification=false
  assert(#calls==1 and calls[1].kind=="failure" and
    calls[1].code=="phrase.script_clear" and writer.state()=="idle",
    "script-clear wait did not expire at its 500th idle opportunity")

  new_host()
  render_mode="defer"
  request=build(source(52),1)
  accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  assert(#render_queue==1 and last_render_options and
    last_script_steps and last_render_options.max_events==last_script_steps,
    "render event budget must match the emitted one-event-per-step script bound")
  for _=1,499 do idle:fire() end
  assert(#calls==0 and writer.state()=="busy" and writer.diagnostic()==nil,
    "pending-render diagnostic appeared before its 500th idle opportunity")
  idle:fire()
  local diagnostic=writer.diagnostic()
  assert(#calls==0 and writer.state()=="busy" and diagnostic and
    diagnostic.code=="transaction.render_pending",
    "500th render idle opportunity must diagnose without releasing occupancy")
  local next_request=build(source(54),2)
  local next_calls=0
  local next_accepted,next_rejection=writer.create(next_request,function() next_calls=next_calls+1 end)
  assert(not next_accepted and next_rejection.code=="transaction.busy" and next_calls==0,
    "pending native render admitted a subsequent writer request")
  local queued=table.remove(render_queue,1)
  queued.callback(nil,queued.count,0)
  drain()
  render_mode="sync"
  assert(#calls==1 and calls[1].kind=="success" and writer.state()=="idle")
  assert(writer.diagnostic()==nil,
    "settled native callback left the pending-render diagnostic stale")

  render_mode="defer"
  local fresh_request=build(source(56),2)
  local fresh_accepted,fresh_rejection,fresh_calls=start(fresh_request)
  assert(fresh_accepted,fresh_rejection and fresh_rejection.message)
  assert(#fresh_calls==0 and writer.state()=="busy" and writer.diagnostic()==nil,
    "a fresh accepted request inherited the prior pending-render warning")
  local fresh_render=table.remove(render_queue,1)
  fresh_render.callback(nil,fresh_render.count,0)
  drain()
  render_mode="sync"
  assert(#fresh_calls==1 and fresh_calls[1].kind=="success" and writer.diagnostic()==nil)
end

-- Native backup insertion may mutate the phrase list before throwing or
-- returning nil. Reconcile the exact list and prove rollback removed the
-- inserted backup and staging phrase without touching the owned destination.
for _, behavior in ipairs({ "throw_after_insert", "nil_after_insert" }) do
  local host_instrument,phrase=create_owned(48)
  local original={host_instrument.phrases[1]}
  local raw=song.tool_data
  insert_calls=0
  backup_insert_behavior=behavior
  local request=build(source(56),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  backup_insert_behavior=nil
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="failed" and calls[1].integrity_blocked==false,calls[1].message)
  assert(#host_instrument.phrases==#original and
    rawequal(host_instrument.phrases[1],original[1]),
    "uncertain backup insertion did not restore the exact ordered inventory")
  assert(rawequal(phrase,original[1]) and song.tool_data==raw)
end

-- Failed cleanup retains identified writer objects. Ambiguous additions are
-- recorded as inventory evidence and never renamed or registered as owned.
for _, scenario in ipairs({
    { behavior="throw_after_insert", cleanup_failure=true, recovery_count=1 },
    { behavior="ambiguous_extra", recovery_count=1, reject_blocker=true },
    { behavior="ambiguous_reorder", recovery_count=1 },
  }) do
  local host_instrument,phrase=create_owned(48)
  insert_calls=0
  backup_insert_behavior=scenario.behavior
  fail_inserted_backup_delete=scenario.cleanup_failure==true
  local request=build(source(56),1)
  if scenario.reject_blocker then
    request.record_blocker=function() return false end
  end
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  backup_insert_behavior=nil
  fail_inserted_backup_delete=false
  assert(#calls==1 and calls[1].kind=="failure")
  assert(calls[1].status=="integrity_blocked" and calls[1].integrity_blocked==true,
    calls[1].message)
  local destination_present=false
  for _,item in ipairs(host_instrument.phrases) do
    if rawequal(item,phrase) then destination_present=true end
  end
  assert(destination_present,"uncertain insertion recovery removed the destination")
  local recovery=calls[1].recovery or {}
  assert(#recovery==scenario.recovery_count,calls[1].message)
  if scenario.behavior=="throw_after_insert" then
    assert(recovery[1].phrase and writer.is_temporary(song,host_instrument,recovery[1].phrase),
      "identified retained backup lost temporary registration")
  else
    assert((recovery[1].role=="staging-inventory" or recovery[1].role=="backup-inventory") and
      recovery[1].phrase==nil)
    if not scenario.reject_blocker then
      assert(type(request.blocker)=="table" and request.blocker.reason,
        "ambiguous inventory did not record a blocker")
    end
    for _,item in ipairs(host_instrument.phrases) do
      assert(item.name~=writer.RECOVERY_STAGING_NAME and item.name~=writer.RECOVERY_BACKUP_NAME,
        "unidentified phrase was renamed as recovery material")
      assert(not writer.is_temporary(song,host_instrument,item),
        "unidentified phrase was registered as writer-owned")
    end
    if scenario.reject_blocker then
      assert_writer_blocks_followup()
    else
      assert_recorded_blocker_prevents_write()
    end
  end
end

-- An unreadable inventory after insertion retains scalar recovery evidence and
-- leaves unidentified objects untouched.
do
  new_host()
  inventory_read_failure=true
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  inventory_read_failure=false
  instrument.phrases=unreadable_inventory
  unreadable_inventory=nil
  assert(#calls==1 and calls[1].kind=="failure" and
    calls[1].status=="integrity_blocked" and calls[1].phrase==nil)
  assert(#(calls[1].recovery or {})>0 and calls[1].recovery[1].phrase==nil)
  assert(#instrument.phrases==1 and instrument.phrases[1].name=="")
  assert(not writer.is_temporary(song,instrument,instrument.phrases[1]))
  assert(type(request.blocker)=="table" and request.blocker.reason)
  assert_recorded_blocker_prevents_write()
end

-- Verified backup covers everything except its neutral name and the mapping
-- that native copying does not provide; a corrupted backup rejects before the
-- destination is touched.
do
  local host_instrument,phrase=create_owned(48)
  phrase.mapping={key_tracking=3,base_note=43,note_range={36,47},
    looping=true,loop_start=2,loop_end=6}
  phrase.column_names[3]="Custom"
  phrase.column_mutes[3]=true
  reseal(phrase)
  local before=snapshot(phrase)
  local raw=song.tool_data
  corrupt_backup=true
  local request=build(source(58),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="failed",calls[1].status)
  assert_same_snapshot(snapshot(phrase),before,"corrupted backup changed the destination")
  local mapped_backup=assert(ownership.copy_snapshot(before))
  assert(not ownership.compare_backup(before,mapped_backup),"unexpected backup mapping was accepted")
  assert(not ownership.snapshot(phrase,{max_lines=1,max_note_columns=4,max_effect_columns=2}),
    "snapshot accepted an active phrase beyond the advertised capacity")
  assert(#host_instrument.phrases==1 and rawequal(host_instrument.phrases[1],phrase))
  assert(song.tool_data==raw)
end

-- Mapping, column metadata and the empty script survive a successful
-- regeneration, and the terminal result carries a real postcommit baseline.
do
  local host_instrument,phrase=create_owned(48)
  phrase.mapping={key_tracking=3,base_note=43,note_range={36,47},
    looping=true,loop_start=2,loop_end=6}
  phrase.column_names[3]="Custom"
  phrase.column_mutes[3]=true
  reseal(phrase)
  local before=snapshot(phrase)
  local request=build(source(56),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="success",calls[1] and calls[1].message)
  assert(#host_instrument.phrases==1 and rawequal(host_instrument.phrases[1],phrase))
  local after=snapshot(phrase)
  assert_same_snapshot(after.mapping,before.mapping,"mapping changed")
  assert_same_snapshot(after.columns,before.columns,"column metadata changed")
  assert_same_snapshot(after.script,before.script,"script changed")
  local saved=assert(store.load(song,host_instrument,phrase))
  assert(saved.pitch_events[1].note==56)
  assert(type(calls[1].baseline)=="table" and calls[1].baseline.id==ownership.id(phrase))
end

-- Regeneration expands only visibility required by its output, and rollback
-- restores the original visibility exactly after a failed source commit.
do
  local host_instrument,phrase=create_owned_rests()
  hide_volume_column(phrase)
  assert(phrase.volume_column_visible==false,"rest baseline unexpectedly exposes the volume column")
  local before=snapshot(phrase)
  local accented=source(56)
  accented.pitch_events[1].accent=true
  local request=build(accented,1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="success",calls[1] and calls[1].message)
  assert(phrase.volume_column_visible==true,
    "generated accent output lost its required volume column visibility")
  assert(phrase.panning_column_visible==before.properties.panning_column_visible and
      phrase.base_note==before.properties.base_note and phrase.autoseek==before.properties.autoseek,
    "visibility expansion changed unrelated destination metadata")
  assert(#host_instrument.phrases==1 and rawequal(host_instrument.phrases[1],phrase))
end

do
  local host_instrument,phrase=create_owned_rests()
  hide_volume_column(phrase)
  assert(phrase.volume_column_visible==false,"rest baseline unexpectedly exposes the volume column")
  local before=snapshot(phrase)
  local raw=song.tool_data
  local original_commit=store.commit
  store.commit=function(target_song,candidate)
    assert(original_commit(target_song,candidate))
    error("injected persistence failure after visibility expansion",0)
  end
  local accented=source(56)
  accented.pitch_events[1].accent=true
  local request=build(accented,1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  store.commit=original_commit
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="failed" and calls[1].integrity_blocked==false)
  assert_same_snapshot(snapshot(phrase),before,
    "failed commit did not restore visibility and metadata exactly")
  assert(song.tool_data==raw and #host_instrument.phrases==1 and
      rawequal(host_instrument.phrases[1],phrase))
end

-- A source commit that writes and then throws restores the exact phrase,
-- source data and phrase count from the verified backup.
do
  local host_instrument,phrase=create_owned(48)
  phrase.mapping={key_tracking=3,base_note=43,note_range={36,47},
    looping=true,loop_start=2,loop_end=6}
  phrase.column_names[3]="Rollback metadata"
  phrase.column_mutes[3]=true
  reseal(phrase)
  local before=snapshot(phrase)
  local raw=song.tool_data
  local original_commit=store.commit
  store.commit=function(target_song,candidate)
    assert(original_commit(target_song,candidate))
    error("injected persistence failure after write",0)
  end
  local request=build(source(54),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  store.commit=original_commit
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="failed" and calls[1].integrity_blocked==false)
  assert_same_snapshot(snapshot(phrase),before,"commit failure did not restore the destination")
  assert(song.tool_data==raw)
  assert(#host_instrument.phrases==1 and rawequal(host_instrument.phrases[1],phrase))
end

-- Rollback never overwrites an external destination change. The store is still
-- restored only when it equals this transaction's written value.
do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  local raw=song.tool_data
  local original_commit=store.commit
  store.commit=function(target_song,candidate)
    assert(original_commit(target_song,candidate))
    phrase.cells[1].note_value=77
    error("injected failure after external change",0)
  end
  local request=build(source(52),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  store.commit=original_commit
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="integrity_blocked",calls[1].status)
  assert(calls[1].integrity_blocked==true)
  assert(phrase.cells[1].note_value==77,"rollback overwrote an external destination change")
  assert(song.tool_data==raw,"guarded store rollback did not restore source data")
  assert(#host_instrument.phrases==2,"verified backup was not retained for recovery")
  local recovery=calls[1].recovery or {}
  assert(#recovery==1 and recovery[1].role=="backup")
  assert(rawequal(recovery[1].phrase,host_instrument.phrases[2]))
  assert(recovery[1].phrase.name==writer.RECOVERY_BACKUP_NAME)
  assert(writer.is_temporary(song,host_instrument,recovery[1].phrase),
    "retained recovery backup lost its temporary-object registration")
  assert_same_snapshot(snapshot(recovery[1].phrase).mapping,before.mapping,"backup mapping")
  host_instrument:delete_phrase_at(2)
  assert(not writer.is_temporary(song,host_instrument,recovery[1].phrase),
    "deleted recovery backup remained registered as temporary")
end

-- Without a captured written destination, rollback cannot prove that a partial
-- replacement is this transaction's own change, so it retains the verified
-- backup instead of copying it over an unverifiable destination.
do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  local raw=song.tool_data
  copy_failure_after=1
  local request=build(source(54),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  copy_failure_after=nil
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="integrity_blocked",calls[1].status)
  assert(calls[1].message:find("rollback refused",1,true),calls[1].message)
  assert(phrase.cells[1].note_value==0,"unverified partial copy was overwritten")
  assert(song.tool_data==raw)
  assert(#host_instrument.phrases==2)
  local recovery=calls[1].recovery or {}
  assert(#recovery==1 and recovery[1].role=="backup")
  assert(rawequal(recovery[1].phrase,host_instrument.phrases[2]))
  assert(recovery[1].phrase.name==writer.RECOVERY_BACKUP_NAME)
  assert(writer.is_temporary(song,host_instrument,recovery[1].phrase))
end

-- A guarded store rollback preserves newer song data written after this
-- transaction's candidate and reports a blocking integrity result.
do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  local original_commit=store.commit
  local newer="EXTERNAL STORE DATA"
  store.commit=function(target_song,candidate)
    assert(original_commit(target_song,candidate))
    target_song.tool_data=newer
    error("injected failure after external store change",0)
  end
  local request=build(source(52),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  store.commit=original_commit
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="integrity_blocked",calls[1].status)
  assert(calls[1].message:find("source rollback failed",1,true),calls[1].message)
  assert(song.tool_data==newer,"guarded store rollback overwrote newer data")
  assert_same_snapshot(snapshot(phrase),before,"store rollback failure left the phrase changed")
  assert(#host_instrument.phrases==1 and rawequal(host_instrument.phrases[1],phrase))
end

-- A cleanup failure retires the writer but reports a blocking integrity result
-- with the exact retained object and a neutral recovery name.
do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  local raw=song.tool_data
  local original_commit=store.commit
  store.commit=function() error("injected commit failure",0) end
  local recovery_renames=0
  local tracked_backup
  delete_failure=function(candidate)
    if candidate.name~=writer.TRANSACTION_BACKUP_NAME then return false end
    if not tracked_backup then
      tracked_backup=candidate
      local name=candidate.name
      candidate.name=nil
      setmetatable(candidate,{
        __index=function(_,key) if key=="name" then return name end end,
        __newindex=function(object,key,value)
          if key=="name" then
            if value==writer.RECOVERY_BACKUP_NAME then recovery_renames=recovery_renames+1 end
            name=value
          else rawset(object,key,value) end
        end,
      })
    end
    return true
  end
  local request=build(source(50),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  store.commit=original_commit
  delete_failure=nil
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="integrity_blocked" and calls[1].integrity_blocked==true)
  assert_same_snapshot(snapshot(phrase),before,"cleanup failure left the destination changed")
  assert(song.tool_data==raw)
  local recovery=calls[1].recovery or {}
  assert(#recovery==1 and recovery[1].role=="backup")
  assert(rawequal(recovery[1].phrase,host_instrument.phrases[2]))
  assert(recovery[1].phrase.name==writer.RECOVERY_BACKUP_NAME)
  assert(recovery_renames==1,"retained backup was renamed more than once")
  assert(writer.is_temporary(song,host_instrument,recovery[1].phrase))
  assert(writer.state()=="idle")
end

-- A committed destination with failed backup cleanup is a blocked failure
-- that preserves the committed baseline and recovery object.
do
  local host_instrument,phrase=create_owned(48)
  delete_failure=function(candidate) return candidate.name==writer.TRANSACTION_BACKUP_NAME end
  local request=build(source(52),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  delete_failure=nil
  assert(#calls==1 and calls[1].kind=="failure" and calls[1].status=="integrity_blocked")
  assert(calls[1].phrase==nil and calls[1].committed==true)
  assert(type(calls[1].baseline)=="table" and calls[1].baseline.id==ownership.id(phrase))
  assert(#(calls[1].recovery or {})==1 and #host_instrument.phrases==2)
end

-- A staging cleanup failure during a render failure records a persistent
-- blocker with the exact retained staging object.
do
  new_host()
  render_mode="error"
  delete_failure=function(candidate) return candidate.name==writer.PHRASE_NAME end
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  render_mode="sync"
  delete_failure=nil
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="integrity_blocked" and calls[1].integrity_blocked==true)
  local recovery=calls[1].recovery or {}
  assert(#recovery==1 and recovery[1].role=="staging")
  assert(rawequal(recovery[1].phrase,instrument.phrases[1]))
  assert(recovery[1].phrase.name==writer.RECOVERY_STAGING_NAME)
  assert(writer.is_temporary(song,instrument,recovery[1].phrase),
    "retained recovery staging phrase lost its temporary-object registration")
  assert(type(request.blocker)=="table" and type(request.blocker.recovery)=="table")
  assert(#request.blocker.recovery==1 and request.blocker.reason)
  assert(writer.state()=="idle")
end

-- A committed write without a verifiable postcommit baseline is not success and
-- is rolled back rather than reported with missing evidence.
do
  local host_instrument,phrase=create_owned(48)
  local before=snapshot(phrase)
  local raw=song.tool_data
  local original_commit,original_load=store.commit,store.load
  local postcommit,loads=false,0
  store.commit=function(target_song,candidate)
    local ok,err=original_commit(target_song,candidate)
    if ok then postcommit,loads=true,0 end
    return ok,err
  end
  store.load=function(target_song,target_instrument,target_phrase)
    if postcommit then
      loads=loads+1
      if loads>1 then return nil,"injected postcommit source read failure" end
    end
    return original_load(target_song,target_instrument,target_phrase)
  end
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  store.commit,store.load=original_commit,original_load
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].status=="failed")
  assert(calls[1].message:find("Postcommit baseline",1,true),calls[1].message)
  assert_same_snapshot(snapshot(phrase),before,"missing baseline was reported as success")
  assert(song.tool_data==raw)
end

-- Accepted jobs call the terminal callback once, including synchronous and
-- duplicated native callbacks.
do
  new_host()
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="success","completion was not delivered exactly once")
  idle:fire()
  assert(#calls==1 and writer.state()=="idle")
  -- An accepted job may settle synchronously when staging fails, but it still
  -- reports exactly one terminal result and leaves no occupied slot.
  insert_failure=true
  local cancelled_start=build(source(52),2)
  local sync_accepted,sync_rejection,sync_calls=start(cancelled_start)
  insert_failure=false
  assert(sync_accepted,sync_rejection and sync_rejection.message)
  assert(#sync_calls==1 and sync_calls[1].kind=="failure"
    and sync_calls[1].code=="transaction.stage",sync_calls[1].message)
  assert(#instrument.phrases==1 and writer.state()=="idle")
  new_host()
  commit_failure=true
  local commit_request=build(source(53),1)
  local commit_accepted,commit_rejection,commit_calls=start(commit_request)
  commit_failure=false
  assert(commit_accepted,commit_rejection and commit_rejection.message)
  assert(#commit_calls==1 and commit_calls[1].kind=="failure"
    and commit_calls[1].code=="transaction.render",commit_calls[1].message)
  assert(#instrument.phrases==0 and song.tool_data=="" and writer.state()=="idle",
    "script commit failure must remove the stage and retire accepted work")
  render_mode="double"
  local doubled=build(source(50),2)
  local doubled_accepted,doubled_rejection,doubled_calls=start(doubled)
  assert(doubled_accepted,doubled_rejection and doubled_rejection.message)
  drain()
  render_mode="sync"
  assert(#doubled_calls==1 and doubled_calls[1].kind=="success")
end

-- In-flight cancellation keeps the native render's occupancy until its callback
-- and never commits the cancelled destination.
do
  new_host()
  render_mode="defer"
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  assert(#render_queue==1 and writer.state()=="busy")
  assert(writer.cancel(request.token,"test cancel")==true)
  assert(#calls==0 and writer.state()=="busy","cancellation released a live native render")
  local queued=table.remove(render_queue,1)
  queued.callback(nil,queued.count,0)
  drain()
  render_mode="sync"
  assert(#calls==1 and calls[1].kind=="failure" and calls[1].status=="cancelled")
  assert(#instrument.phrases==0,"cancelled render committed a create")
  assert(song.tool_data=="")
end

-- Release during a native render drops host references, temporary registry
-- entries and GUI delivery. A late callback retires the tombstone only.
do
  new_host()
  render_mode="defer"
  release_candidate_calls=0
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  local stage=instrument.phrases[1]
  assert(stage and writer.is_temporary(song,instrument,stage)==true)
  writer.release()
  assert(release_candidate_calls==1,"release did not scrub the store candidate")
  local status,token=writer.state()
  assert(status=="busy" and rawequal(token,request.token))
  assert(writer.is_temporary(song,instrument,stage)==false,
    "release retained a host temporary registration")
  for _=1,50 do idle:fire() end
  assert(writer.state()=="busy","missing native callback released the render slot")
  local released_diagnostic=writer.diagnostic()
  assert(released_diagnostic and released_diagnostic.code=="transaction.released")
  local queued=table.remove(render_queue,1)
  queued.callback(nil,queued.count,0)
  render_mode="sync"
  assert(#calls==0,"released job delivered a stale GUI completion")
  assert(writer.state()=="idle")
  assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],stage),
    "released stage was not retained as recovery material")
  assert(stage.name==writer.PHRASE_NAME)
  assert(song.tool_data=="","released render committed source data")
  assert(release_candidate_calls==1,"late callback scrubbed a released candidate again")
end

-- A released writer tombstone retains the native script wrapper only; the old
-- song graph becomes collectible before the deferred callback arrives.
do
  new_host()
  render_mode="defer"
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  local stage=instrument.phrases[1]
  local refs=setmetatable({song=song,instrument=instrument,stage=stage,script=stage.script},{__mode="v"})
  writer.release()
  local queued=table.remove(render_queue,1)
  request,stage,instrument,song=nil,nil,nil,nil
  for _=1,3 do collectgarbage("collect") end
  assert(refs.script~=nil,"pending native render lost its script wrapper")
  assert(refs.song==nil and refs.instrument==nil and refs.stage==nil,
    "released render retained the old song object graph")
  queued.callback(nil,0,0)
  queued=nil
  for _=1,3 do collectgarbage("collect") end
  assert(refs.script==nil,"settled render retained its script wrapper")
  assert(#calls==0 and writer.state()=="idle")
  render_mode="sync"
end

-- Bounded checkpoints use the validated workspace capacities rather than the
-- native maximum, and stay below their reported line boundary.
do
  local host_instrument,phrase=create_owned(48)
  local captured=snapshot(phrase)
  assert(#captured.lines==PHRASE_MAX_LINES and
    #captured.lines[1].notes==PHRASE_NOTE_COLUMNS and
    #captured.lines[1].effects==PHRASE_EFFECT_COLUMNS)
  assert(phrase.number_of_lines<PHRASE_MAX_LINES and #host_instrument.phrases==1)
end

-- A create ID is rechecked against live phrases and stored sources immediately
-- before commit; either conflict blocks the write and removes the staging phrase.
do
  new_host()
  render_mode="defer"
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  assert(allocated_id,"create did not allocate an ACID phrase ID")
  local duplicate=instrument:insert_phrase_at(#instrument.phrases+1)
  duplicate.name=string.format("ACID 0.1 #%d [v3:00000000]",allocated_id)
  local queued=table.remove(render_queue,1)
  queued.callback(nil,queued.count,0)
  drain()
  render_mode="sync"
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].code=="safety.duplicate_id",calls[1].code)
  assert(#instrument.phrases==1 and rawequal(instrument.phrases[1],duplicate))
  assert(song.tool_data=="","duplicate live ID committed source data")
end

do
  new_host()
  render_mode="defer"
  local request=build(source(50),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  local saved,save_error=store.save(song,allocated_id,source(58),"play_once",0)
  assert(saved,save_error)
  local queued=table.remove(render_queue,1)
  queued.callback(nil,queued.count,0)
  drain()
  render_mode="sync"
  assert(#calls==1 and calls[1].kind=="failure",calls[1] and calls[1].message)
  assert(calls[1].code=="safety.duplicate_id",calls[1].code)
  assert(#instrument.phrases==0,"duplicate stored ID committed a live phrase")
  assert(song.tool_data~="","stored duplicate evidence was lost")
end

-- Successful termination also scrubs its prepared store candidate exactly once.
do
  new_host()
  release_candidate_calls=0
  local request=build(source(48),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  assert(#calls==1 and calls[1].kind=="success",calls[1] and calls[1].message)
  assert(release_candidate_calls==1,"terminal success retained its store candidate")
  assert_idle()
end

-- Successful regeneration releases its deleted stage and native wrapper.
do
  local host_instrument,phrase=create_owned(48)
  render_mode="defer"
  local request=build(source(52),1)
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  local stage=host_instrument.phrases[2]
  local refs=setmetatable({stage=stage,script=stage.script},{__mode="v"})
  local queued=table.remove(render_queue,1)
  queued.callback(nil,queued.count,0)
  drain()
  assert(#calls==1 and calls[1].kind=="success" and rawequal(calls[1].phrase,phrase))
  assert(#host_instrument.phrases==1)
  stage,queued=nil,nil
  inserted_backup_phrase=nil
  for _=1,3 do collectgarbage("collect") end
  assert(refs.stage==nil and refs.script==nil,"completed regeneration retained its deleted stage")
  render_mode="sync"
end

-- Missing, rejected and throwing blocker hooks produce a blocked terminal
-- result and prevent later direct writer requests from being admitted.
for _, mode in ipairs({ "false", "throw", "missing" }) do
  local host_instrument,phrase=create_owned(48)
  delete_failure=function(candidate) return candidate.name==writer.TRANSACTION_BACKUP_NAME end
  local request=build(source(52),1)
  if mode=="false" then
    request.record_blocker=function() return false end
  elseif mode=="throw" then
    request.record_blocker=function() error("injected blocker hook failure",0) end
  else
    request.record_blocker=nil
  end
  local accepted,rejection,calls=start(request)
  assert(accepted,rejection and rejection.message)
  drain()
  delete_failure=nil
  assert(#calls==1 and calls[1].kind=="failure" and
    calls[1].status=="integrity_blocked" and calls[1].integrity_blocked==true and calls[1].phrase==nil)
  local later=build(source(54),2)
  local later_calls=0
  local later_operation=later.kind=="create" and writer.create or writer.regenerate
  local later_accepted,later_rejection=later_operation(later,function() later_calls=later_calls+1 end)
  assert(not later_accepted and later_rejection.status=="integrity_blocked")
  assert(later_calls==0 and #host_instrument.phrases==2)
  assert(type(writer.diagnostic())=="table" and
    writer.diagnostic().code=="transaction.blocker_recording")
end

print("ACID writer safety checks passed (mocked Renoise; native playback unverified)")
