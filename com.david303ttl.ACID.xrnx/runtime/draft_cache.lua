-- SPDX-License-Identifier: GPL-3.0-only
-- Object-local drafts with verified baselines and detached session recovery.
local policies=require("model.policies")
local sequencer=require("model.sequencer")
local store=require("renoise.pattern_store")
local ownership=require("renoise.phrase_ownership")
local validator=require("writers.phrase_validator")
local capabilities=require("renoise.target_capabilities")
local pitch_bend=require("writers.phrase_pitch_bend")
local M={}
local NEW={}
local sessions=setmetatable({},{__mode="k"})
local captures=setmetatable({},{__mode="k"})
local serial=0
local function next_token() serial=serial+1;return serial end
local function object(value,class)
  local kind=type(value)
  return kind=="table" or kind=="userdata" or kind==class
end
local function valid_target(song,instrument,phrase)
  if not object(song,"Song") or not object(instrument,"Instrument") then
    return nil,"song and instrument objects are required"
  end
  if phrase~=nil then
    local kind=type(phrase)
    if kind~="table" and kind~="userdata" and kind~="InstrumentPhrase" then
      return nil,"An existing draft requires a phrase object"
    end
  end
  return true
end
local function valid_options(options)
  if options~=nil and (type(options)~="table" or getmetatable(options)~=nil or
      (options.validate~=nil and type(options.validate)~="function")) then
    return nil,"Invalid draft options"
  end
  return true
end
local function state(song,create)
  local result=sessions[song]
  if not result and create then
    result={instruments=setmetatable({},{__mode="k"}),recovery={}}
    sessions[song]=result
  end
  return result
end
local function bucket(song,instrument,create)
  if not song or not instrument then return nil end
  local session=state(song,create)
  if not session then return nil end
  local result=session.instruments[instrument]
  if not result and create then result={};session.instruments[instrument]=result end
  return result
end
local function copied(value)
  return ownership.copy_snapshot(value)
end
local function label(object,fallback)
  local ok,name=pcall(function()return object and object.name end)
  return ok and type(name)=="string" and name or fallback
end
local function labels(instrument,phrase)
  return {instrument=label(instrument,"Unavailable instrument"),
    phrase=phrase and label(phrase,"Unavailable phrase") or "New Phrase"}
end
local function metadata(record)
  return {token=record.token,revision=record.revision,recovered=record.recovered==true,
    persistent=record.persistent==true,warning=record.warning}
end
local function values(record)
  return sequencer.copy_source(record.pattern),record.output_policy,record.pb_range,metadata(record)
end
local function proof(song,instrument,phrase,options)
  local ok,result,err=pcall(function()
    if options and options.validate then return options.validate(song,instrument,phrase) end
    local profile,profile_error=capabilities.inspect(instrument)
    if not profile then return nil,profile_error end
    local api=renoise.InstrumentPhrase
    return validator.classify(song,instrument,phrase,profile,{
      max_lines=api.MAX_NUMBER_OF_LINES,max_note_columns=api.MAX_NUMBER_OF_NOTE_COLUMNS,
      max_effect_columns=api.MAX_NUMBER_OF_EFFECT_COLUMNS,play_pattern=api.PLAY_PATTERN,
      key_tracking_none=api.KEY_TRACKING_NONE},{pitch_bend_delivery=pitch_bend.delivery_enabled})
  end)
  if not ok then return nil,"Cannot validate draft baseline" end
  if not result then return nil,err or "Draft target is unavailable" end
  local readable,baseline,baseline_error=pcall(function()
    local source,source_error=sequencer.copy_source(result.source)
    if not source then return nil,source_error end
    return copied({id=ownership.id(phrase),source=source,
      settings=result.settings,snapshot=result.baseline,planning_inputs=result.planning_inputs})
  end)
  if not readable then return nil,"Cannot inspect verified draft baseline" end
  if not baseline or not policies.is_integer(baseline.id) or baseline.id<1 or
      type(baseline.settings)~="table" or type(baseline.snapshot)~="table" or
      type(baseline.planning_inputs)~="table" or
      not policies.valid_output_policy(baseline.settings.output_policy) or
      not policies.valid_pb_range(baseline.settings.pb_range) then
    return nil,baseline_error or "Incomplete verified draft baseline"
  end
  return baseline
end
local function scratch_baseline(song,instrument)
  local index,err=ownership.membership(song,instrument,nil)
  if not index then return nil,err end
  local name=label(instrument,nil)
  if not name then return nil,"Cannot inspect New Phrase instrument name" end
  local inspected,matches=pcall(function()
    local count=0
    for _,candidate in ipairs(song.instruments) do if candidate.name==name then count=count+1 end end
    return count
  end)
  return {index=index,name=name,durable=inspected and matches==1}
end
local function baseline(song,instrument,phrase,options)
  if phrase then return proof(song,instrument,phrase,options) end
  return scratch_baseline(song,instrument)
end
local function matching(phrase,left,right)
  if phrase==nil then return left~=nil and right~=nil end
  return left~=nil and right~=nil and ownership.compare(left,right)==true
end
local function scratch_changed(captured,current)
  return captured.index~=current.index or captured.name~=current.name or not current.durable
end
local function scratch_warning(current)
  if not current.durable then return "New Phrase scratch is session-only because its instrument name is ambiguous" end
  return "New Phrase scratch is session-only because its saved instrument position or name changed"
end

function M.detach(song,instrument,phrase,reason)
  local valid,err=valid_target(song,instrument,phrase)
  if not valid then return nil,err end
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  if not record or record.detached then return false end
  local entry=assert(copied({token=next_token(),pattern=record.pattern,
    output_policy=record.output_policy,pb_range=record.pb_range,baseline=record.baseline,
    labels=record.labels,reason=type(reason)=="string" and reason or "Draft target changed",
    session_only=true}))
  state(song,true).recovery[entry.token]=entry
  records[phrase or NEW]={detached=true,reason=entry.reason}
  return entry.token
end

function M.put(song,instrument,phrase,pattern,output_policy,pb_range,options)
  local valid,target_error=valid_target(song,instrument,phrase)
  if not valid then return nil,target_error end
  local options_valid,options_error=valid_options(options)
  if not options_valid then return nil,options_error end
  local source,err=sequencer.copy_source(pattern)
  if not source then return nil,err end
  output_policy=output_policy or policies.DEFAULT_OUTPUT_POLICY
  pb_range=pb_range==nil and policies.DEFAULT_PB_RANGE or pb_range
  if not policies.valid_output_policy(output_policy) then return nil,"invalid phrase output policy" end
  if not policies.valid_pb_range(pb_range) then
    return nil,"invalid PB range"
  end
  local verified,validation_error=baseline(song,instrument,phrase,options)
  local records=bucket(song,instrument,true)
  local previous=records[phrase or NEW]
  if previous and previous.detached then previous=nil end
  if previous and not matching(phrase,previous.baseline,verified) then
    M.detach(song,instrument,phrase,validation_error or "Committed draft baseline changed")
    verified=nil
    validation_error=validation_error or "Committed draft baseline changed"
  end
  local revision=next_token()
  local record={pattern=source,output_policy=output_policy,pb_range=pb_range,
    baseline=phrase==nil and previous and previous.baseline or verified,
    labels=labels(instrument,phrase),token=previous and previous.token or next_token(),
    revision=revision,persistent=false}
  records[phrase or NEW]=record
  if not verified then return nil,validation_error,metadata(record) end
  if phrase==nil and scratch_changed(record.baseline,verified) then
    record.warning=scratch_warning(verified)
    return nil,record.warning,metadata(record)
  end
  local saved,save_error=store.write_draft(song,instrument,phrase,source,output_policy,pb_range)
  if not saved then return nil,save_error,metadata(record) end
  record.persistent=true
  return true,nil,metadata(record)
end

local function resolve(song,instrument,phrase,options)
  local valid,target_error=valid_target(song,instrument,phrase)
  if not valid then return nil,target_error end
  local options_valid,options_error=valid_options(options)
  if not options_valid then return nil,options_error end
  local verified,err=baseline(song,instrument,phrase,options)
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  if not verified then
    if record then M.detach(song,instrument,phrase,err) end
    return nil,err
  end
  if record and record.detached then return nil,record.reason,verified end
  if record then
    if not matching(phrase,record.baseline,verified) then
      M.detach(song,instrument,phrase,"Committed draft baseline changed")
      return nil,"Committed draft baseline changed",verified
    end
    if phrase==nil and scratch_changed(record.baseline,verified) then
      record.persistent=false
      record.warning=scratch_warning(verified)
    end
    return record,nil,verified
  end
  local source,policy,pb=store.read_draft(song,instrument,phrase)
  if not source then return nil,policy,verified end
  local revision=next_token()
  record={pattern=assert(sequencer.copy_source(source)),output_policy=policy,pb_range=pb,
    baseline=verified,labels=labels(instrument,phrase),token=next_token(),revision=revision,
    persistent=true,recovered=true}
  bucket(song,instrument,true)[phrase or NEW]=record
  return record,nil,verified
end

function M.get(song,instrument,phrase,options)
  local record,err=resolve(song,instrument,phrase,options)
  if not record then return nil,err end
  return values(record)
end

function M.restore(song,instrument,phrase,options)
  local record,err,verified=resolve(song,instrument,phrase,options)
  if record then return values(record) end
  if not verified or not phrase then return nil,err end
  return sequencer.copy_source(verified.source),verified.settings.output_policy,
    verified.settings.pb_range,{origin="committed"}
end

local function same_capture_descriptor(descriptor,captured)
  return type(descriptor)=="table" and getmetatable(descriptor)==nil and
    descriptor.kind==captured.kind and rawequal(descriptor.instrument,captured.instrument) and
    rawequal(descriptor.phrase,captured.phrase) and descriptor.token==captured.token and
    descriptor.revision==captured.revision and descriptor.instrument_index==captured.instrument_index and
    descriptor.instrument_name==captured.instrument_name and
    descriptor.instrument_name_unique==captured.instrument_name_unique and
    descriptor.phrase_id==captured.phrase_id
end

local function current_capture(song,captured)
  if not rawequal(song,captured.song) or not valid_target(song,captured.instrument,captured.phrase) or
      not ownership.membership(song,captured.instrument,captured.phrase) then return false end
  local records=bucket(song,captured.instrument,false)
  local record=records and records[captured.phrase or NEW]
  if not record or record.detached or record.token~=captured.token or
      record.revision~=captured.revision then return false end
  if captured.kind=="new" then
    local destination=scratch_baseline(song,captured.instrument)
    return destination~=nil and destination.index==captured.instrument_index and
      destination.name==captured.instrument_name and
      destination.durable==captured.instrument_name_unique
  end
  local id=ownership.validate_identity(song,captured.instrument,captured.phrase)
  return id~=nil and id==captured.phrase_id
end

function M.capture(song,instrument,phrase,options)
  local record,err=resolve(song,instrument,phrase,options)
  if not record then return nil,err or "No current session draft" end
  local kind=phrase and "existing" or "new"
  local captured={kind=kind,song=song,instrument=instrument,phrase=phrase,
    token=record.token,revision=record.revision}
  local descriptor={kind=kind,instrument=instrument,phrase=phrase,
    token=record.token,revision=record.revision}
  if kind=="new" then
    local destination=scratch_baseline(song,instrument)
    if not destination then return nil,"Cannot capture New Phrase destination identity" end
    captured.instrument_index=destination.index
    captured.instrument_name=destination.name
    captured.instrument_name_unique=destination.durable
    descriptor.instrument_index=destination.index
    descriptor.instrument_name=destination.name
    descriptor.instrument_name_unique=destination.durable
  else
    local id=ownership.validate_identity(song,instrument,phrase)
    if not id or id~=record.baseline.id then
      return nil,"Cannot capture a unique ACID phrase identity"
    end
    captured.phrase_id=id
    descriptor.phrase_id=id
  end
  captures[descriptor]=captured
  return descriptor,function(token,revision)
    return captured.song~=nil and token==captured.token and revision==captured.revision and
      current_capture(captured.song,captured)
  end
end

-- This guard remains valid after an authorized destination mutation.
function M.is_current(song,descriptor)
  local captured=type(descriptor)=="table" and captures[descriptor]
  return captured~=nil and same_capture_descriptor(descriptor,captured) and
    current_capture(song,captured)
end

function M.compare_and_clear(song,descriptor,created)
  if not M.is_current(song,descriptor) then return false end
  local records=bucket(song,descriptor.instrument,false)
  local key=descriptor.phrase or NEW
  local record=records[key]
  if created==true and descriptor.kind=="new" and record.origin and
      record.origin.revision==record.revision then
    state(song,true).recovery[record.origin.token]=nil
  end
  records[key]=nil
  return true
end

function M.list(song)
  local session=state(song,false)
  local result={}
  for _,entry in pairs(session and session.recovery or {}) do result[#result+1]=assert(copied(entry)) end
  table.sort(result,function(a,b)return a.token<b.token end)
  return result
end

function M.discard(song,token)
  local session=state(song,false)
  if not session or not session.recovery[token] then return false end
  session.recovery[token]=nil
  return true
end

function M.copy_to_new(song,instrument,token,options)
  local valid,target_error=valid_target(song,instrument,nil)
  if not valid then return nil,target_error end
  local options_valid,options_error=valid_options(options)
  if not options_valid then return nil,options_error end
  local session=state(song,false)
  local entry=session and session.recovery[token]
  if not entry then return nil,"Recovery entry is unavailable" end
  local verified,err=scratch_baseline(song,instrument)
  if not verified then return nil,err end
  local outgoing=resolve(song,instrument,nil,options)
  if outgoing then M.detach(song,instrument,nil,"Scratch preserved before recovery copy") end
  local saved,save_error=M.put(song,instrument,nil,entry.pattern,entry.output_policy,entry.pb_range,options)
  local record=bucket(song,instrument,false)[NEW]
  if not record then return nil,save_error end
  record.origin={token=token,revision=record.revision}
  local source,policy,pb,meta=values(record)
  meta.recovery_token=token
  meta.warning=not saved and save_error or nil
  return source,policy,pb,meta
end

function M.clear(song,instrument,phrase)
  local valid,err=valid_target(song,instrument,phrase)
  if not valid then return nil,err end
  local removed,err=store.clear_draft(song,instrument,phrase)
  if removed==nil then return nil,err end
  local records=bucket(song,instrument,false)
  if records and records[phrase or NEW] then records[phrase or NEW]=nil;return true end
  return removed
end

function M.has(song)
  local session=state(song,false)
  if session then
    if next(session.recovery) then return true end
    for _,records in pairs(session.instruments) do
      for _,record in pairs(records) do if not record.detached then return true end end
    end
  end
  return store.has_drafts(song)
end

function M.has_volatile(song)
  local session=state(song,false)
  if not session then return false end
  if next(session.recovery) then return true end
  for _,records in pairs(session.instruments) do
    for _,record in pairs(records) do if not record.detached and not record.persistent then return true end end
  end
  return false
end

function M.release(song)
  local warning=M.has_volatile(song) and "Session-only ACID drafts were released" or nil
  sessions[song]=nil
  for descriptor,captured in pairs(captures) do
    if rawequal(captured.song,song) then
      rawset(descriptor,"instrument",nil)
      rawset(descriptor,"phrase",nil)
      captured.song,captured.instrument,captured.phrase=nil,nil,nil
      captures[descriptor]=nil
    end
  end
  return true,warning
end

return M
