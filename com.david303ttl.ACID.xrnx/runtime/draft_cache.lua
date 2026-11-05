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
local MIN_OWNERSHIP_ID=1
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
  return sequencer.copy_source(record.pattern),record.output_policy,record.pb_range,metadata(record),
    record.label,record.label_custom
end
local function proof(song,instrument,phrase,options,previous_baseline,previous_identity,previous_snapshot)
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
  if type(result)~="table" or type(result.baseline)~="table" then
    return nil,"Draft validator did not provide a verified phrase baseline"
  end
  local id_ok,id=pcall(ownership.id,phrase)
  if not id_ok or not policies.is_integer(id) or id<MIN_OWNERSHIP_ID then
    return nil,"Cannot inspect draft phrase identity"
  end
  local identity=result.baseline_identity
  local retained_snapshot,retained_identity
  if validator.is_retained_baseline_identity(identity,result.baseline) then
    retained_snapshot=result.baseline
    retained_identity=identity
  else
    local retained_ok,retained,_,resolved_identity=pcall(validator.retained_baseline,result.baseline)
    if retained_ok and retained then
      retained_snapshot=retained
      retained_identity=resolved_identity
    end
  end
  if not validator.is_retained_baseline_identity(retained_identity,retained_snapshot) then
    return nil,"Draft validator did not provide a retained verified baseline"
  end
  identity=retained_identity
  local candidate={id=id,source=result.source,settings=result.settings,
    snapshot=retained_snapshot,planning_inputs=result.planning_inputs}
  if previous_baseline then
    local previous_identity_ok=validator.is_retained_baseline_identity(previous_identity,previous_snapshot)
    if identity and previous_identity_ok and rawequal(identity,previous_identity) and
        rawequal(candidate.snapshot,previous_snapshot) then
      local same=previous_baseline.id==candidate.id and
        ownership.compare(previous_baseline.source,candidate.source)==true and
        ownership.compare(previous_baseline.settings,candidate.settings)==true and
        ownership.compare(previous_baseline.planning_inputs,candidate.planning_inputs)==true
      if not same then return nil,"Committed draft source or planning inputs changed" end
      return previous_baseline,nil,identity,candidate.snapshot
    end
    local same,difference=ownership.compare(previous_baseline,candidate)
    if not same then return nil,"Committed draft baseline changed: "..tostring(difference) end
    return previous_baseline,nil,identity,candidate.snapshot
  end
  local readable,baseline,baseline_error=pcall(function()
    local source,source_error=sequencer.copy_source(result.source)
    if not source then return nil,source_error end
    local detached,copy_error=copied({id=id,settings=result.settings,
      planning_inputs=result.planning_inputs})
    if not detached then return nil,copy_error end
    detached.source=source
    detached.snapshot=retained_snapshot
    return detached
  end)
  if not readable then return nil,"Cannot inspect verified draft baseline" end
  if not baseline or not policies.is_integer(baseline.id) or baseline.id<MIN_OWNERSHIP_ID or
      type(baseline.settings)~="table" or type(baseline.snapshot)~="table" or
      type(baseline.planning_inputs)~="table" or
      not policies.valid_output_policy(baseline.settings.output_policy) or
      not policies.valid_pb_range(baseline.settings.pb_range) then
    return nil,baseline_error or "Incomplete verified draft baseline"
  end
  return baseline,nil,identity,candidate.snapshot
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
local function baseline(song,instrument,phrase,options,previous_baseline,previous_identity,previous_snapshot)
  if phrase then return proof(song,instrument,phrase,options,previous_baseline,previous_identity,previous_snapshot) end
  return scratch_baseline(song,instrument)
end
local function matching(phrase,left,right)
  if phrase==nil then return left~=nil and right~=nil end
  return left~=nil and right~=nil and ownership.compare(left,right)==true
end
local function retain_identity(previous,identity,snapshot)
  if identity or not previous or
      not validator.is_retained_baseline_identity(previous.baseline_identity,previous.verified_snapshot) then
    return identity,snapshot
  end
  return previous.baseline_identity,previous.verified_snapshot
end
local function scratch_changed(captured,current)
  return captured.index~=current.index or captured.name~=current.name or not current.durable
end
local function scratch_warning(current)
  if not current.durable then return "New Phrase scratch is session-only because its instrument name is ambiguous" end
  return "New Phrase scratch is session-only because its saved instrument position or name changed"
end

function M.detach(song,instrument,phrase,reason,source,output_policy,pb_range)
  local valid,err=valid_target(song,instrument,phrase)
  if not valid then return nil,err end
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  if record and record.detached then return false end
  if not record and source==nil then return false end
  local pattern=source or record.pattern
  local copied_pattern,pattern_error=sequencer.copy_source(pattern)
  if not copied_pattern then return nil,pattern_error end
  local entry=assert(copied({token=next_token(),pattern=copied_pattern,
    output_policy=record and record.output_policy or output_policy,
    pb_range=record and record.pb_range or pb_range,
    label=record and record.label or "Untitled",
    label_custom=record and record.label_custom or false,
    baseline=record and record.baseline or nil,
    labels=record and record.labels or labels(instrument,phrase),
    reason=type(reason)=="string" and reason or "Draft target changed",
    revision=next_token(),session_only=true}))
  entry.pattern=copied_pattern
  if source~=nil then entry.output_policy=output_policy;entry.pb_range=pb_range end
  state(song,true).recovery[entry.token]=entry
  records=records or bucket(song,instrument,true)
  records[phrase or NEW]={detached=true,reason=entry.reason}
  return entry.token
end

function M.detach_for_native_revision(song,phrase,reason,instrument,source,output_policy,pb_range)
  if not object(song,"Song") or not object(phrase,"InstrumentPhrase") then return false end
  local session=state(song,instrument~=nil and source~=nil)
  if not session then return false end
  local detached=false
  local found=false
  for owner,records in pairs(session.instruments) do
    if records[phrase] and not records[phrase].detached then
      local token=M.detach(song,owner,phrase,reason or "Native phrase revision changed",
        instrument and rawequal(owner,instrument) and source or nil,output_policy,pb_range)
      detached=token~=false and token~=nil or detached
      found=true
    end
  end
  if not found and instrument and source then
    local token=M.detach(song,instrument,phrase,reason or "Native phrase revision changed",
      source,output_policy,pb_range)
    detached=token~=false and token~=nil or detached
  end
  return detached
end

function M.put(song,instrument,phrase,pattern,output_policy,pb_range,options,label_value,label_custom)
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
  local records=bucket(song,instrument,true)
  local previous=records[phrase or NEW]
  if previous and previous.detached then previous=nil end
  if label_value==nil then
    if previous then label_value=previous.label or "Untitled"
    elseif phrase then
      local id=ownership.validate_identity(song,instrument,phrase)
      local stored_label
      if id then local _,_,_,value=store.read_entry(song,id);stored_label=value end
      label_value=stored_label or "Untitled"
    else label_value="Untitled" end
  end
  if label_custom==nil then
    if previous then label_custom=previous.label_custom==true
    elseif phrase then
      local id=ownership.validate_identity(song,instrument,phrase)
      local stored_custom
      if id then local _,_,_,_,value=store.read_entry(song,id);stored_custom=value end
      label_custom=stored_custom==true
    else label_custom=false end
  end
  local retained_baseline=previous and previous.baseline
  local verified,validation_error,verified_identity,verified_snapshot=baseline(song,instrument,phrase,options,
    phrase and previous and previous.baseline or nil,previous and previous.baseline_identity,
    previous and previous.verified_snapshot)
  if phrase~=nil and previous and rawequal(verified,previous.baseline) then
    verified_identity,verified_snapshot=retain_identity(previous,verified_identity,verified_snapshot)
  end
  local previous_matches=previous~=nil and verified~=nil and
    (phrase~=nil and rawequal(previous.baseline,verified) or
      matching(phrase,previous.baseline,verified))
  if previous and not previous_matches then
    M.detach(song,instrument,phrase,validation_error or "Committed draft baseline changed")
    previous=nil
    verified=nil
    validation_error=validation_error or "Committed draft baseline changed"
  end
  if previous and verified and previous_matches and
       sequencer.same_source(previous.pattern,source) and
       previous.output_policy==output_policy and previous.pb_range==pb_range and
       previous.label==label_value and previous.label_custom==label_custom and
       (phrase~=nil or not scratch_changed(previous.baseline,verified)) then
    local saved,save_error=store.write_draft_metadata(song,instrument,phrase,source,output_policy,pb_range,label_value,label_custom)
    if not saved then return nil,save_error,metadata(previous) end
    previous.persistent=true
    previous.warning=nil
    previous.baseline_identity=verified_identity
    previous.verified_snapshot=verified_snapshot
    return true,nil,metadata(previous)
  end
  local revision=next_token()
  local record={pattern=source,output_policy=output_policy,pb_range=pb_range,
    baseline=phrase==nil and retained_baseline or verified,
    labels=labels(instrument,phrase),token=previous and previous.token or next_token(),
    label=label_value,label_custom=label_custom,revision=revision,persistent=false,baseline_identity=verified_identity,
    verified_snapshot=verified_snapshot}
  records[phrase or NEW]=record
  if not verified then return nil,validation_error,metadata(record) end
  if phrase==nil and scratch_changed(record.baseline,verified) then
    record.warning=scratch_warning(verified)
    return nil,record.warning,metadata(record)
  end
  local saved,save_error=store.write_draft_metadata(song,instrument,phrase,source,output_policy,pb_range,label_value,label_custom)
  if not saved then return nil,save_error,metadata(record) end
  record.persistent=true
  return true,nil,metadata(record)
end

function M.rebind(song,instrument,phrase,pattern,output_policy,pb_range,selection,options,label_value,label_custom)
  local valid,target_error=valid_target(song,instrument,phrase)
  if not valid then return nil,target_error end
  local options_valid,options_error=valid_options(options)
  if not options_valid then return nil,options_error end
  if type(selection)~="table" or getmetatable(selection)~=nil or
      not policies.is_integer(selection.token) or not policies.is_integer(selection.revision) then
    return nil,"Invalid draft rebind selection"
  end
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  if not record or record.detached or record.token~=selection.token or
      record.revision~=selection.revision then
    return nil,"Draft changed before identity rebind"
  end
  local source,source_error=sequencer.copy_source(pattern)
  if not source then return nil,source_error end
  if not sequencer.same_source(record.pattern,source) or
      record.output_policy~=output_policy or record.pb_range~=pb_range then
    return nil,"Draft values changed before identity rebind"
  end
  label_value=label_value or record.label or "Untitled"
  if label_custom==nil then label_custom=record.label_custom==true end
  local verified,verify_error,verified_identity,verified_snapshot=baseline(song,instrument,phrase,options)
  if not verified then return nil,verify_error end
  if not policies.is_integer(verified.id) or verified.id<MIN_OWNERSHIP_ID then
    return nil,"Committed draft identity is unavailable"
  end
  record.baseline=verified
  record.baseline_identity=verified_identity
  record.verified_snapshot=verified_snapshot
  record.labels=labels(instrument,phrase)
  record.label,record.label_custom=label_value,label_custom
  local write_ok,saved,save_error=pcall(store.write_draft_metadata,song,instrument,phrase,
    source,output_policy,pb_range,label_value,label_custom)
  record.persistent=write_ok and saved==true
  if record.persistent then
    record.warning=nil
  else
    record.warning=write_ok and save_error or saved or "Draft persistence failed"
  end
  return true,record.warning,metadata(record)
end

function M.matches_values(song,instrument,phrase,pattern,output_policy,pb_range,label_value,label_custom)
  if not valid_target(song,instrument,phrase) then return false end
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  if not record or record.detached or record.output_policy~=output_policy or
      record.pb_range~=pb_range or not sequencer.same_source(record.pattern,pattern) or
      (label_value~=nil and (record.label~=label_value or record.label_custom~=label_custom)) then
    return false
  end
  return true,metadata(record)
end

local function resolve(song,instrument,phrase,options)
  local valid,target_error=valid_target(song,instrument,phrase)
  if not valid then return nil,target_error,nil,"invalid" end
  local options_valid,options_error=valid_options(options)
  if not options_valid then return nil,options_error,nil,"invalid" end
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  local verified,err,verified_identity,verified_snapshot=baseline(song,instrument,phrase,options,
    phrase and record and not record.detached and record.baseline or nil,
    record and record.baseline_identity,record and record.verified_snapshot)
  if not verified then
    if record then M.detach(song,instrument,phrase,err) end
    return nil,err,nil,"unverified"
  end
  if record and record.detached then return nil,record.reason,verified,"detached" end
  if phrase~=nil and record and rawequal(verified,record.baseline) then
    verified_identity,verified_snapshot=retain_identity(record,verified_identity,verified_snapshot)
  end
  if record then
    if phrase~=nil and rawequal(record.baseline,verified) then
      record.baseline_identity=verified_identity
      record.verified_snapshot=verified_snapshot
    else
      local matches,difference=matching(phrase,record.baseline,verified)
      if not matches then
      M.detach(song,instrument,phrase,"Committed draft baseline changed")
      return nil,"Committed draft baseline changed",verified,"detached"
      end
      record.baseline_identity=verified_identity
      record.verified_snapshot=verified_snapshot
    end
    if phrase==nil and scratch_changed(record.baseline,verified) then
      record.persistent=false
      record.warning=scratch_warning(verified)
    end
    return record,nil,verified,"session"
  end
  if phrase==nil and not verified.durable then
    return nil,scratch_warning(verified),verified,"absent"
  end
  local source,policy,pb,label_value,label_custom=store.read_draft(song,instrument,phrase)
  if not source then
    if policy then return nil,policy,verified,"error" end
    return nil,policy,verified,"absent"
  end
  local revision=next_token()
  record={pattern=assert(sequencer.copy_source(source)),output_policy=policy,pb_range=pb,
    baseline=verified,labels=labels(instrument,phrase),label=label_value or "Untitled",
    label_custom=label_custom==true,token=next_token(),revision=revision,
    persistent=true,recovered=true,baseline_identity=verified_identity,
    verified_snapshot=verified_snapshot}
  bucket(song,instrument,true)[phrase or NEW]=record
  return record,nil,verified,"session"
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
  local stored_label,stored_custom
  if verified.id and type(store.read_entry)=="function" then
    local _,_,_,label_value,label_custom=store.read_entry(song,verified.id)
    stored_label,stored_custom=label_value,label_custom
  end
  return sequencer.copy_source(verified.source),verified.settings.output_policy,
    verified.settings.pb_range,{origin="committed"},stored_label or "Untitled",stored_custom==true
end

function M.capture_label(song,instrument,phrase)
  if not valid_target(song,instrument,phrase) then return nil,"Invalid label draft target" end
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  if record and record.detached then return nil,"Label draft is detached" end
  local token,revision=record and record.token,record and record.revision
  return function()
    local current_records=bucket(song,instrument,false)
    local current=current_records and current_records[phrase or NEW]
    return current==record and (not current or not current.detached and
      current.token==token and current.revision==revision)
  end
end

function M.accept_label(song,instrument,phrase,label_value,label_custom,guard)
  if not valid_target(song,instrument,phrase) or type(guard)~="function" or
      not guard() or not store.valid_label(label_value) or type(label_custom)~="boolean" then return false end
  local records=bucket(song,instrument,false)
  local record=records and records[phrase or NEW]
  if not record then return true end
  if record.detached then return false end
  record.label=label_value
  record.label_custom=label_custom==true
  record.revision=next_token()
  record.persistent=true
  record.warning=nil
  return true,metadata(record)
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

local function current_capture(song,captured,authorized_revision)
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
  return id~=nil and (id==captured.phrase_id or
    (authorized_revision~=nil and id==authorized_revision))
end

function M.capture(song,instrument,phrase,options)
  local record,err,_,state=resolve(song,instrument,phrase,options)
  if not record then return nil,err or "No current session draft",state end
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
  return descriptor,function(token,revision,authorized_revision)
    return captured.song~=nil and token==captured.token and revision==captured.revision and
      current_capture(captured.song,captured,authorized_revision)
  end,"session"
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
  records[key]=nil
  return true
end

-- The writer may clear a captured draft after a request-authorized immutable
-- revision transition. The ordinary guard remains strict on the captured ID.
function M.compare_and_clear_revision(song,descriptor,revision_id)
  local captured=type(descriptor)=="table" and captures[descriptor]
  if not captured or not same_capture_descriptor(descriptor,captured) or
      captured.kind~="existing" or not policies.is_integer(revision_id) or
      not current_capture(song,captured,revision_id) then return false end
  local current_id=ownership.validate_identity(song,captured.instrument,captured.phrase)
  if current_id~=revision_id then return false end
  local records=bucket(song,captured.instrument,false)
  local record=records and records[captured.phrase]
  if not record or record.detached or record.token~=captured.token or
      record.revision~=captured.revision then return false end
  records[captured.phrase]=nil
  return true
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
