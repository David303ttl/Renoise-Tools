-- SPDX-License-Identifier: GPL-3.0-only
-- Detached request values and live checkpoints, separate from cleanup permission.
local ownership=require("renoise.phrase_ownership")
local capabilities=require("renoise.target_capabilities")
local validator=require("writers.phrase_validator")
local sequencer=require("model.sequencer")
local pitch_bend=require("writers.phrase_pitch_bend")
local policies=require("model.policies")
local store=require("renoise.pattern_store")
local M={}
local MAX_PHRASE_ID=2147483647
local COPY_SUFFIX=" copy"
local COPY_PREFIX_LENGTH=27
local RAW_FIELDS={"song","instrument","phrase","token","draft_capture"}
local VALUE_FIELDS={"kind","operation","origin","target_kind","trigger","epoch","session","target_revision",
  "edit_revision","metadata_revision","operation_serial","source","output_policy","pb_range","id","baseline",
  "planning_inputs","capabilities","capacities","timing_model","groove_enabled",
  "label","label_custom"}

local function capacities()
  local api=renoise.InstrumentPhrase
  return {max_lines=api.MAX_NUMBER_OF_LINES,max_note_columns=api.MAX_NUMBER_OF_NOTE_COLUMNS,
    max_effect_columns=api.MAX_NUMBER_OF_EFFECT_COLUMNS,play_pattern=api.PLAY_PATTERN,
    key_tracking_none=api.KEY_TRACKING_NONE}
end

local function inputs(profile,limits)
  local fields={}
  for _,key in ipairs({"sample","plugin","midi","alias","read_error"}) do fields[key]=profile[key] end
  return {capabilities=fields,capacities=limits,
    options={pitch_bend_delivery=pitch_bend.delivery_enabled,
      normal_volume=policies.NORMAL_VOLUME,accent_volume=policies.ACCENT_VOLUME}}
end

local function token_current(record)
  if record.failed or not record.access or not record.values then return false end
  local ok,current=pcall(function() return record.token:is_current() end)
  return ok and current==true
end

local function request_values_match(record,request,light_values)
  local actual={}
  for _,key in ipairs(VALUE_FIELDS) do actual[key]=request[key] end
  if not light_values then
    if ownership.compare(record.values,actual)~=true then return false end
  else
  local function same_value(expected,supplied)
    if type(expected)=="table" or type(supplied)=="table" then
      return ownership.compare(expected,supplied)==true
    end
    return expected==supplied
  end
  for _,key in ipairs(VALUE_FIELDS) do
    if key=="baseline" then
      local expected=record.values.baseline
      local supplied=actual.baseline
      if expected==nil then
        if supplied~=nil then return false end
      elseif type(supplied)~="table" or
          getmetatable(supplied)~=nil or rawget(supplied,"snapshot")~=nil or
          not same_value(expected,supplied) then
        return false
      end
    elseif not same_value(record.values[key],actual[key]) then
      return false
    end
  end
  end
  local prepared_ok=sequencer.validate_prepared(request.prepared_resolution,record.values.source)
  local captured_ok=sequencer.validate_prepared(record.prepared_resolution,record.values.source)
  if not prepared_ok or not captured_ok or
      not rawequal(request.prepared_resolution.provenance,record.prepared_resolution.provenance) then
    return false
  end
  return true
end

local function normalized_baseline(metadata,snapshot)
  if type(metadata)~="table" or type(snapshot)~="table" then return nil end
  local copy=ownership.copy_snapshot(metadata)
  if not copy then return nil end
  copy.snapshot=snapshot
  return copy
end

local function resolve_committed_baseline(baseline)
  if type(baseline)~="table" or type(baseline.snapshot)~="table" then
    return nil,"Committed recovery baseline is unavailable"
  end
  local snapshot,_,identity=validator.retained_baseline(baseline.snapshot)
  if not snapshot or not identity or
      not validator.is_retained_baseline_identity(identity,snapshot) then
    return nil,"Committed recovery baseline proof is unavailable"
  end
  local metadata={id=baseline.id,source=baseline.source,settings=baseline.settings,
    planning_inputs=baseline.planning_inputs}
  local normalized=normalized_baseline(metadata,snapshot)
  if not normalized then return nil,"Committed recovery baseline metadata is invalid" end
  return normalized
end

local function verify(record,request,admission,light_target,light_values,candidate)
  if not record.access or not record.values then return false,"Request document was released" end
  if not rawequal(request,record.request[1]) then return false,"Unknown runtime request" end
  for _,key in ipairs(RAW_FIELDS) do
    if not rawequal(request[key],record[key]) then return false,"Captured request identity changed: "..key end
  end
  if not request_values_match(record,request,light_values) then
    return false,"Captured request values changed"
  end
  for key,value in pairs(record.functions) do
    if not rawequal(request[key],value) then return false,"Captured request callback changed: "..key end
  end
  if not admission and not token_current(record) then return false,"Request authorization was revoked" end
  local duplicate=record.values.operation=="duplicate"
  local state=record.access.current(true,false,duplicate or not light_target)
  if not state or not rawequal(state.song,record.song) or state.epoch~=record.values.epoch or
      state.session~=record.values.session or not state.open then return false,"Request lifetime changed" end
  if not state.target or state.target.kind~=(duplicate and "owned" or record.values.target_kind) or
      not rawequal(state.target.instrument,record.instrument) or
      not rawequal(state.target.phrase,duplicate and record.origin_phrase or record.phrase) then return false,"Runtime target eligibility changed" end
  for _,key in ipairs({"target_revision","edit_revision","metadata_revision","operation_serial"}) do
    if state[key]~=record.values[key] then return false,"Request revision changed: "..key end
  end
  local blocked,block_reason=record.access.blocked(record.token)
  if blocked then return false,block_reason or "Song integrity requires revalidation" end
  local occupancy=record.access.occupancy(record.token)
  if not occupancy.available then return false,occupancy.reason or "The writer slot is occupied" end
  local transport=record.song.transport
  if type(renoise.Transport.TIMING_MODEL_LPB)~="number" or transport.timing_model~=record.values.timing_model or
      transport.timing_model~=renoise.Transport.TIMING_MODEL_LPB then return false,"Transport timing model changed" end
  if transport.groove_enabled~=record.values.groove_enabled then return false,"Transport groove setting changed" end
  local undo=type(record.song.is_undo_redoing)=="function" and record.song:is_undo_redoing()
  if type(undo)~="boolean" or undo then
    return false,"Native undo or redo is processing or unavailable"
  end
  if record.draft_capture~=nil and
      not record.access.drafts.is_current(record.song,record.draft_capture) then
    return false,"Captured draft preconditions changed"
  end
  local profile=capabilities.inspect(record.instrument)
  if not capabilities.same(record.profile,profile) then return false,"Instrument capabilities changed" end
  local limits=capacities()
  local planning_inputs=inputs(profile,limits)
  if duplicate or record.values.target_kind=="owned" then
    local expected=duplicate and record.values.origin.baseline or record.values.baseline
    local baseline=state.target.baseline
    if not baseline or not rawequal(baseline.snapshot,record.baseline_snapshot) or
        baseline.id~=expected.id or
        not ownership.compare(expected.source,baseline.source) or
        not ownership.compare(expected.settings,baseline.settings) or
        not ownership.compare(expected.planning_inputs,baseline.planning_inputs) or
        not ownership.compare(record.values.planning_inputs.capacities,planning_inputs.capacities) or
        planning_inputs.options.pitch_bend_delivery~=record.values.planning_inputs.options.pitch_bend_delivery or
        policies.NORMAL_VOLUME~=record.values.planning_inputs.options.normal_volume or
        policies.ACCENT_VOLUME~=record.values.planning_inputs.options.accent_volume then
      return false,"Committed target baseline changed"
    end
  elseif record.values.target_kind~="new" or record.phrase~=nil then
    return false,"Request has no explicit writable destination"
  else
    if not ownership.compare(record.values.planning_inputs,planning_inputs) then
      return false,"Planning inputs changed"
    end
  end
  if duplicate then
    local origin=record.values.origin
    local expected_raw=origin.raw
    if candidate~=nil then
      local status=store.candidate_status(candidate)
      if not status or not status.written_verified or status.draft_removal~=false or status.previous_raw~=origin.raw then
        return false,"Duplicate store candidate is not verified"
      end
      expected_raw=status.written_raw
      local entries=store.read(record.song)
      if not entries then return false,"Duplicate store records are unreadable" end
      local added=0
      for id,entry in pairs(entries) do
        local original=record.origin_entries[id]
        if original then
          if not ownership.compare(original,entry) then return false,"Duplicate changed an original source record" end
        else
          added=added+1
          if not sequencer.same_source(entry.pattern,record.values.source) or
              entry.output_policy~=record.values.output_policy or entry.pb_range~=record.values.pb_range or
              entry.label~=record.values.label or entry.label_custom~=true then
            return false,"Duplicate candidate contains an unauthorized source"
          end
        end
      end
      for id in pairs(record.origin_entries) do
        if not entries[id] then return false,"Duplicate removed an original source record" end
      end
      if added~=1 then return false,"Duplicate candidate must add one source" end
    end
    if record.song.tool_data~=expected_raw or record.origin_phrase.name~=origin.name or
        ownership.validate_identity(record.song,record.instrument,record.origin_phrase)~=origin.baseline.id then
      return false,"Duplicate origin identity or storage changed"
    end
    local source,policy,pb,label,custom=store.read_entry(record.song,origin.baseline.id)
    if not source or not sequencer.same_source(source,origin.baseline.source) or
        policy~=origin.baseline.settings.output_policy or pb~=origin.baseline.settings.pb_range or
        label~=origin.label or custom~=origin.label_custom then
      return false,"Duplicate origin source or metadata changed"
    end
    if record.origin_draft and not record.access.drafts.is_current(record.song,record.origin_draft) then
      return false,"Duplicate origin draft changed"
    end
    if record.origin_draft_values then
      local draft,policy,pb,label,custom=store.read_draft(record.song,record.instrument,record.origin_phrase)
      local frozen=record.origin_draft_values
      if not draft or not sequencer.same_source(draft,frozen.source) or policy~=frozen.output_policy or
          pb~=frozen.pb_range or label~=frozen.label or custom~=frozen.label_custom then
        return false,"Duplicate durable draft changed"
      end
    end
  end
  -- The writer plans the frozen source after these fresh authority checks.
  local latest=record.access.current()
  if not latest or not rawequal(latest.song,record.song) or latest.epoch~=state.epoch or
      latest.session~=state.session or latest.open~=state.open or latest.target_revision~=state.target_revision or
       latest.edit_revision~=state.edit_revision or latest.metadata_revision~=state.metadata_revision or
       latest.operation_serial~=state.operation_serial or
      (not admission and not token_current(record)) then return false,"Request changed during validation" end
  return true
end

local function checkpoint(record,request,admission,light_target,light_values,candidate)
  local ok,valid,reason=pcall(verify,record,request,admission,light_target,light_values,candidate)
  if not admission and (not ok or not valid) then
    record.failed=true
    if record.access and record.access.revoke then
      pcall(record.access.revoke,record.token,"Request checkpoint failed")
    end
  end
  if not ok then return false,"Cannot inspect request checkpoint" end
  return valid,reason
end

function M.new(access)
  local records=setmetatable({},{__mode="k"})
  local owner={}

  function owner:capture(trigger,token,operation)
    local ok,request,reason=pcall(function()
      if not access then return nil,"Request runtime was released" end
      local state=access.current(true,true,false)
      local editor=state and state.editor
      local target=state and state.target
      if operation~=nil and operation~="duplicate" then return nil,"Invalid request operation" end
      local duplicate=operation=="duplicate"
      if not editor or not editor.valid then return nil,editor and editor.reason or "No valid editor source is installed" end
      if not target or (target.kind~="new" and target.kind~="owned") then
        return nil,target and target.reason or "No explicit writable target"
      end
      if duplicate and target.kind~="owned" then return nil,"Duplicate requires a committed owned phrase" end
      if duplicate and #target.instrument.phrases>=renoise.Instrument.MAX_NUMBER_OF_PHRASES then
        return nil,"Instrument phrase capacity is exhausted"
      end
      local baseline_snapshot=target.baseline and target.baseline.snapshot
      local baseline_proof_reference
      if target.kind=="owned" then
        local identity=baseline_snapshot and validator.retained_baseline_identity(baseline_snapshot)
        if not identity or not validator.is_retained_baseline_identity(identity,baseline_snapshot) then
          return nil,"Runtime target did not provide a retained verified baseline"
        end
        local proof_reference,proof_error=access.baseline_reference(target.instrument,target.phrase,
          baseline_snapshot)
        if not proof_reference then
          return nil,proof_error or "Runtime target did not provide retained baseline provenance"
        end
        if type(proof_reference)~="table" then
          return nil,"Runtime target did not provide retained baseline provenance"
        end
        baseline_proof_reference=proof_reference
      end
      local profile=capabilities.inspect(target.instrument)
      local limits=capacities()
      local source,source_error=sequencer.copy_source(duplicate and target.baseline.source or editor.source)
      if not source then return nil,source_error end
      local prepared,prepared_error
      if duplicate then prepared,prepared_error=sequencer.prepare_resolution(source)
      else prepared,prepared_error=sequencer.detach_prepared(editor.prepared_resolution,source) end
      if not prepared then return nil,prepared_error end
      local descriptor,draft_guard,draft_state=access.drafts.capture(state.song,target.instrument,target.phrase,
        access.draft_options(target))
      if not descriptor then
        -- A clean committed source needs no session draft. Those two draft
        -- states grant no removal, while unreadable or dirty drafts reject.
        local baseline=target.kind=="owned" and target.baseline
        local settings=baseline and baseline.settings
        local clean=type(baseline)=="table" and type(baseline.source)=="table" and
          type(settings)=="table" and sequencer.same_source(editor.source,baseline.source) and
          editor.output_policy==settings.output_policy and editor.pb_range==settings.pb_range
        if not clean or (draft_state~="absent" and draft_state~="detached") then
          return nil,draft_guard
        end
        descriptor,draft_guard=nil,nil
      end
      local transport=state.song.transport
      if type(renoise.Transport.TIMING_MODEL_LPB)~="number" or
          transport.timing_model~=renoise.Transport.TIMING_MODEL_LPB or type(transport.groove_enabled)~="boolean" then
        return nil,"LPB transport timing and groove state are required"
      end
      local baseline_metadata=target.baseline and {id=target.baseline.id,
        source=target.baseline.source,settings=target.baseline.settings,
        planning_inputs=target.baseline.planning_inputs}
      local label=editor.label or "Untitled"
      local label_custom=editor.label_custom==true
      local origin,origin_draft_values
      if duplicate then
        local committed,policy,pb,committed_label,custom=store.read_entry(state.song,target.baseline.id)
        if not committed or not sequencer.same_source(committed,source) or
            policy~=target.baseline.settings.output_policy or pb~=target.baseline.settings.pb_range then
          return nil,"Duplicate committed source changed"
        end
        origin=assert(ownership.copy_snapshot({baseline=baseline_metadata,name=target.phrase.name,raw=state.song.tool_data,
          label=committed_label,label_custom=custom}))
        label=committed_label:sub(1,COPY_PREFIX_LENGTH):gsub("[ .%-]+$","")..COPY_SUFFIX
        if not store.valid_label(label) then return nil,"Invalid duplicate label" end
        label_custom=true
        if descriptor then
          local draft,policy,pb,draft_label,draft_custom=store.read_draft(state.song,target.instrument,target.phrase)
          if not draft then return nil,"Duplicate draft is not durably stored" end
          origin_draft_values={source=draft,output_policy=policy,pb_range=pb,label=draft_label,label_custom=draft_custom}
          local matches,metadata=access.drafts.matches_values(state.song,target.instrument,target.phrase,
            editor.source,editor.output_policy,editor.pb_range,editor.label,editor.label_custom)
          if not matches or not metadata.persistent or metadata.token~=descriptor.token or
              metadata.revision~=descriptor.revision or not sequencer.same_source(draft,editor.source) or
              policy~=editor.output_policy or pb~=editor.pb_range or draft_label~=editor.label or
              draft_custom~=editor.label_custom then return nil,"Duplicate draft durability is not verified" end
        end
      end
      local values={kind=target.kind=="new" and "create" or "regenerate",
        target_kind=target.kind,trigger=trigger,epoch=state.epoch,session=state.session,
        target_revision=state.target_revision,edit_revision=state.edit_revision,
        metadata_revision=state.metadata_revision,operation_serial=state.operation_serial,
         source=source,output_policy=editor.output_policy,pb_range=editor.pb_range,
         label=label,label_custom=label_custom,
        id=target.baseline and target.baseline.id,baseline=baseline_metadata,
        planning_inputs=inputs(profile,limits),capabilities=profile,capacities=limits,
        timing_model=transport.timing_model,groove_enabled=transport.groove_enabled}
      if duplicate then
        values.operation,values.origin="duplicate",origin
        values.kind,values.target_kind="create","new"
        values.id,values.baseline=nil,nil
        values.output_policy,values.pb_range=target.baseline.settings.output_policy,target.baseline.settings.pb_range
      end
      local private_capabilities,capability_error=ownership.copy_snapshot(profile)
      if not private_capabilities then return nil,capability_error end
      values.capabilities=private_capabilities
      local request=assert(ownership.copy_snapshot(values))
      -- Capability comparison is keyed by the inspected object; keep that
      -- immutable inspection result while retaining the copied values guard.
      request.capabilities=profile
      local record={access=access,values=values,profile=profile,song=state.song,
        instrument=target.instrument,phrase=target.phrase,token=token,draft_capture=descriptor,
        draft_guard=draft_guard,baseline_snapshot=baseline_snapshot,
         baseline_proof_reference=baseline_proof_reference,prepared_resolution=prepared,
        request=setmetatable({request},{__mode="v"}),functions={}}
      if duplicate then
        record.origin_phrase,record.origin_draft=target.phrase,descriptor
        record.origin_draft_values=origin_draft_values
        record.origin_entries=assert(store.read(state.song))
        record.phrase,record.draft_capture,record.draft_guard=nil,nil,nil
      end
      for _,key in ipairs(RAW_FIELDS) do request[key]=record[key] end
      request.prepared_resolution=prepared
      request.is_current=function()
        if not token_current(record) then return false end
        if record.values.target_kind=="owned" then
          local current_id=ownership.validate_identity(record.song,record.instrument,record.phrase)
          if current_id~=record.values.id and
              (record.expected_revision==nil or current_id~=record.expected_revision) then return false end
        end
        if type(record.draft_guard)=="function" and record.draft_capture then
          local ok,current=pcall(record.draft_guard,record.draft_capture.token,
            record.draft_capture.revision,record.expected_revision)
          return ok and current==true
        end
        return true
      end
      request.validate_checkpoint=function(self) return checkpoint(record,self or record.request[1],false) end
      request.validate_authorization_checkpoint=function(self)
        return checkpoint(record,self or record.request[1],false,true,true)
      end
      if duplicate then
        request.validate_origin_checkpoint=function(self,candidate)
          return checkpoint(record,self,false,false,false,candidate)
        end
        record.functions.validate_origin_checkpoint=request.validate_origin_checkpoint
      end
      request.retained_baseline_reference=function(self,supplied_token)
        if not rawequal(self,request) or not record.access or not rawequal(supplied_token,record.token) then
          return false,"Invalid mutation token"
        end
        if record.values.target_kind=="new" then return nil end
        if record.values.target_kind~="owned" or not record.baseline_proof_reference then
          return false,"Retained target baseline proof is unavailable"
        end
        if record.expected_revision~=nil then
          return false,"Captured baseline proof is unavailable after revision authorization"
        end
        if not token_current(record) then return false,"Request authorization was revoked" end
        if not request_values_match(record,request,true) then
          return false,"Captured request baseline values changed"
        end
        return record.baseline_proof_reference
      end
      request.cleanup_authorized=function(_,supplied_token)
        if not record.access or not rawequal(supplied_token,record.token) then return false end
        local ok,current=pcall(function()
          local state=record.access.current()
          return state and state.epoch==record.values.epoch and rawequal(state.song,record.song)
            and record.access.cleanup_allowed(record.token)
            and ownership.is_current(record.song)~=nil
        end)
        return ok and current==true
      end
      request.mutate=function(self,supplied_token,action)
        if not rawequal(self,request) or not record.access or not rawequal(supplied_token,record.token) or
            type(action)~="function" or record.mutating then
          error("Invalid mutation token",0)
        end
        record.mutating=true
        local values={n=0}
        local unpack_values=unpack or table.unpack
        local ok,reason=pcall(function()
          values={n=0}
          local function capture(...) values={n=select("#",...),...} end
          capture(record.access.mutate(supplied_token,action))
        end)
        record.mutating=false
        if not ok then error(reason,0) end
        return unpack_values(values,1,values.n)
      end
      request.expect_revision=function(self,supplied_token,revision_id)
        if not rawequal(self,request) or not record.access or not rawequal(supplied_token,record.token) then
          return false,"Invalid mutation token"
        end
        if not record.mutating then return false,"Phrase revision changes require the active request mutation" end
        if record.values.target_kind~="owned" or not record.phrase then
          return false,"Only the current owned phrase can change revision identity"
        end
        if record.expected_revision~=nil then return false,"A phrase revision is already authorized" end
        if not policies.is_integer(revision_id) or revision_id<1 or revision_id>MAX_PHRASE_ID or
            revision_id==record.values.id then
          return false,"Invalid fresh phrase revision ID"
        end
        local current_id=ownership.validate_identity(record.song,record.instrument,record.phrase)
        if current_id~=record.values.id then
          return false,"Captured phrase identity changed before revision authorization"
        end
        if record.draft_capture then
          if type(record.draft_guard)~="function" or record.draft_capture.phrase_id~=record.values.id then
            return false,"Captured draft identity is inconsistent with the request baseline"
          end
          local ok,current=pcall(record.draft_guard,record.draft_capture.token,
            record.draft_capture.revision)
          if not ok or current~=true then return false,"Captured draft identity changed before revision authorization" end
        end
        local groups,inventory_error=ownership.inventory(record.song)
        if not groups then return false,inventory_error or "Cannot verify phrase revision availability" end
        if groups[revision_id]~=nil then return false,"Phrase revision ID is already in use" end
        record.expected_revision=revision_id
        return true
      end
      request.cleanup_mutate=function(self,supplied_token,action)
        if not rawequal(self,request) or not record.access or not rawequal(supplied_token,record.token) or
            not self:cleanup_authorized(supplied_token) or type(record.access.cleanup_mutate)~="function" then
          error("Cleanup mutation is not authorized",0)
        end
        return record.access.cleanup_mutate(supplied_token,action)
      end
      request.record_blocker=function(self,supplied_token,evidence)
        if not rawequal(self,request) or not record.access or not rawequal(supplied_token,record.token) then
          return false,"Invalid blocker token"
        end
        if type(evidence)~="table" or getmetatable(evidence)~=nil then
          return false,"Invalid blocker evidence"
        end
        local normalized={}
        for key,value in pairs(evidence) do normalized[key]=value end
        if evidence.baseline~=nil then
          if rawequal(evidence.baseline,record.baseline_proof_reference) then
            normalized.baseline=normalized_baseline(record.values.baseline,record.baseline_snapshot)
            if not normalized.baseline then return false,"Captured recovery baseline is unavailable" end
          elseif type(evidence.baseline)=="table" and
              rawequal(evidence.baseline.snapshot,record.baseline_proof_reference) then
            if not record.values.baseline or
                not ownership.compare(record.values.baseline,{id=evidence.baseline.id,
                  source=evidence.baseline.source,settings=evidence.baseline.settings,
                  planning_inputs=evidence.baseline.planning_inputs}) then
              return false,"Captured recovery baseline metadata changed"
            end
            normalized.baseline=normalized_baseline(record.values.baseline,record.baseline_snapshot)
            if not normalized.baseline then return false,"Captured recovery baseline is unavailable" end
          elseif type(evidence.baseline)=="table" and type(evidence.baseline.snapshot)=="table" then
            local resolved,resolve_error=resolve_committed_baseline(evidence.baseline)
            if not resolved then return false,resolve_error end
            normalized.baseline=resolved
          else
            return false,"Unrecognized recovery baseline proof"
          end
        end
        if evidence.committed_baseline~=nil then
          local resolved,resolve_error=resolve_committed_baseline(evidence.committed_baseline)
          if not resolved then return false,resolve_error end
          normalized.committed_baseline=resolved
        end
        return record.access.record_blocker(supplied_token,normalized)
      end
      for _,key in ipairs({"is_current","validate_checkpoint","validate_authorization_checkpoint",
          "retained_baseline_reference","cleanup_authorized","mutate","expect_revision","cleanup_mutate","record_blocker"}) do
        record.functions[key]=request[key]
      end
      records[request]=record
      local valid,validation_error=checkpoint(record,request,true,true,false)
      if not valid then records[request]=nil;return nil,validation_error end
      return request
    end)
    if not ok then return nil,"Cannot capture runtime request" end
    return request,reason
  end

  function owner:validate_checkpoint(request)
    local record=records[request]
    if not record then return false,"Unknown runtime request" end
    return checkpoint(record,request,false)
  end

  function owner:validate_authorization_checkpoint(request)
    local record=records[request]
    if not record then return false,"Unknown runtime request" end
    return checkpoint(record,request,false,true,true)
  end

  function owner:release()
    for request,record in pairs(records) do
      for _,key in ipairs(RAW_FIELDS) do if key~="token" then rawset(request,key,nil);record[key]=nil end end
      record.values=nil;record.profile=nil;record.access=nil;record.draft_guard=nil;record.baseline_snapshot=nil
      record.baseline_proof_reference=nil
      record.prepared_resolution=nil
      record.origin_phrase=nil;record.origin_draft=nil;record.origin_draft_values=nil;record.origin_entries=nil
      rawset(request,"prepared_resolution",nil)
    end
    access=nil
    records=setmetatable({},{__mode="k"})
  end

  return owner
end

return M
