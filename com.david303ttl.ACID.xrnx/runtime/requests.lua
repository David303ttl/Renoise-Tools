-- SPDX-License-Identifier: GPL-3.0-only
-- Detached request values and live checkpoints, separate from cleanup permission.
local ownership=require("renoise.phrase_ownership")
local capabilities=require("renoise.target_capabilities")
local validator=require("writers.phrase_validator")
local planner=require("model.output_planner")
local pitch_bend=require("writers.phrase_pitch_bend")
local M={}
local RAW_FIELDS={"song","instrument","phrase","token","draft_capture"}
local VALUE_FIELDS={"kind","target_kind","trigger","epoch","session","target_revision",
  "edit_revision","operation_serial","source","output_policy","pb_range","id","baseline",
  "planning_inputs","capabilities","capacities","timing_model","groove_enabled"}

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
    options={pitch_bend_delivery=pitch_bend.delivery_enabled}}
end

local function token_current(record)
  if record.failed or not record.access or not record.values then return false end
  local ok,current=pcall(function() return record.token:is_current() end)
  return ok and current==true
end

local function verify(record,request,admission)
  if not record.access or not record.values then return false,"Request document was released" end
  if not rawequal(request,record.request[1]) then return false,"Unknown runtime request" end
  for _,key in ipairs(RAW_FIELDS) do
    if not rawequal(request[key],record[key]) then return false,"Captured request identity changed: "..key end
  end
  local actual={}
  for _,key in ipairs(VALUE_FIELDS) do actual[key]=request[key] end
  if not ownership.compare(record.values,actual) then return false,"Captured request values changed" end
  for key,value in pairs(record.functions) do
    if not rawequal(request[key],value) then return false,"Captured request callback changed: "..key end
  end
  if not admission and not token_current(record) then return false,"Request authorization was revoked" end
  local state=record.access.current(true)
  if not state or not rawequal(state.song,record.song) or state.epoch~=record.values.epoch or
      state.session~=record.values.session or not state.open then return false,"Request lifetime changed" end
  if not state.target or state.target.kind~=record.values.target_kind or
      not rawequal(state.target.instrument,record.instrument) or
      not rawequal(state.target.phrase,record.phrase) then return false,"Runtime target eligibility changed" end
  for _,key in ipairs({"target_revision","edit_revision","operation_serial"}) do
    if state[key]~=record.values[key] then return false,"Request revision changed: "..key end
  end
  local blocked,block_reason=record.access.blocked()
  if blocked then return false,block_reason or "Song integrity requires revalidation" end
  local occupancy=record.access.occupancy(record.token)
  if not occupancy.available then return false,occupancy.reason or "The writer slot is occupied" end
  local member,membership_error=ownership.membership(record.song,record.instrument,record.phrase)
  if not member then return false,membership_error end
  local transport=record.song.transport
  if type(renoise.Transport.TIMING_MODEL_LPB)~="number" or transport.timing_model~=record.values.timing_model or
      transport.timing_model~=renoise.Transport.TIMING_MODEL_LPB then return false,"Transport timing model changed" end
  if transport.groove_enabled~=record.values.groove_enabled then return false,"Transport groove setting changed" end
  local undo=type(record.song.is_undo_redoing)=="function" and record.song:is_undo_redoing()
  if type(undo)~="boolean" or undo then
    return false,"Native undo or redo is processing or unavailable"
  end
  if not record.access.drafts.is_current(record.song,record.draft_capture) then
    return false,"Captured draft preconditions changed"
  end
  local profile=capabilities.inspect(record.instrument)
  if not capabilities.same(record.profile,profile) then return false,"Instrument capabilities changed" end
  local limits=capacities()
  local planning_inputs=inputs(profile,limits)
  if not ownership.compare(record.values.planning_inputs,planning_inputs) then return false,"Planning inputs changed" end
  if record.values.target_kind=="owned" then
    local candidate,reason=validator.classify(record.song,record.instrument,record.phrase,profile,limits,
      {pitch_bend_delivery=pitch_bend.delivery_enabled})
    if not candidate then return false,reason end
    local baseline={id=ownership.id(record.phrase),source=candidate.source,settings=candidate.settings,
      snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs}
    if not ownership.compare(record.values.baseline,baseline) then return false,"Committed target baseline changed" end
  elseif record.values.target_kind~="new" or record.phrase~=nil then
    return false,"Request has no explicit writable destination"
  end
  local output,reason=planner.plan(record.values.source,record.values.output_policy,record.values.pb_range,
    limits,profile,{pitch_bend_delivery=pitch_bend.delivery_enabled})
  if not output then return false,reason end
  local latest=record.access.current()
  if not latest or not rawequal(latest.song,record.song) or latest.epoch~=state.epoch or
      latest.session~=state.session or latest.open~=state.open or latest.target_revision~=state.target_revision or
      latest.edit_revision~=state.edit_revision or latest.operation_serial~=state.operation_serial or
      (not admission and not token_current(record)) then return false,"Request changed during validation" end
  return true
end

local function checkpoint(record,request,admission)
  local ok,valid,reason=pcall(verify,record,request,admission)
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

  function owner:capture(trigger,token)
    local ok,request,reason=pcall(function()
      if not access then return nil,"Request runtime was released" end
      local state=access.current(true)
      local editor=state and state.editor
      local target=state and state.target
      if not editor or not editor.valid then return nil,editor and editor.reason or "No valid editor source is installed" end
      if not target or (target.kind~="new" and target.kind~="owned") then
        return nil,target and target.reason or "No explicit writable target"
      end
      local profile=capabilities.inspect(target.instrument)
      local limits=capacities()
      local output,output_error=planner.plan(editor.source,editor.output_policy,editor.pb_range,limits,profile,
        {pitch_bend_delivery=pitch_bend.delivery_enabled})
      if not output then return nil,output_error end
      local descriptor,draft_guard=access.drafts.capture(state.song,target.instrument,target.phrase,access.draft_options())
      if not descriptor then return nil,draft_guard end
      local transport=state.song.transport
      if type(renoise.Transport.TIMING_MODEL_LPB)~="number" or
          transport.timing_model~=renoise.Transport.TIMING_MODEL_LPB or type(transport.groove_enabled)~="boolean" then
        return nil,"LPB transport timing and groove state are required"
      end
      local values=assert(ownership.copy_snapshot({kind=target.kind=="new" and "create" or "regenerate",
        target_kind=target.kind,trigger=trigger,epoch=state.epoch,session=state.session,
        target_revision=state.target_revision,edit_revision=state.edit_revision,operation_serial=state.operation_serial,
        source=output.source,output_policy=editor.output_policy,pb_range=editor.pb_range,
        id=target.baseline and target.baseline.id,baseline=target.baseline,
        planning_inputs=inputs(profile,limits),capabilities=profile,capacities=limits,
        timing_model=transport.timing_model,groove_enabled=transport.groove_enabled}))
      local request=assert(ownership.copy_snapshot(values))
      -- Capability comparison is keyed by the inspected object; keep that
      -- immutable inspection result while retaining the copied values guard.
      request.capabilities=profile
      local record={access=access,values=values,profile=profile,song=state.song,
        instrument=target.instrument,phrase=target.phrase,token=token,draft_capture=descriptor,
        draft_guard=draft_guard,
        request=setmetatable({request},{__mode="v"}),functions={}}
      for _,key in ipairs(RAW_FIELDS) do request[key]=record[key] end
      request.is_current=function()
        if not token_current(record) then return false end
        if type(record.draft_guard)=="function" and record.draft_capture then
          local ok,current=pcall(record.draft_guard,record.draft_capture.token,
            record.draft_capture.revision)
          return ok and current==true
        end
        return true
      end
      request.validate_checkpoint=function(self) return checkpoint(record,self or record.request[1],false) end
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
        if not rawequal(self,request) or not record.access or not rawequal(supplied_token,record.token) then
          error("Invalid mutation token",0)
        end
        return record.access.mutate(supplied_token,action)
      end
      request.record_blocker=function(self,supplied_token,evidence)
        if not rawequal(self,request) or not record.access or not rawequal(supplied_token,record.token) then
          return false,"Invalid blocker token"
        end
        return record.access.record_blocker(supplied_token,evidence)
      end
      for _,key in ipairs({"is_current","validate_checkpoint","cleanup_authorized","mutate","record_blocker"}) do
        record.functions[key]=request[key]
      end
      records[request]=record
      local valid,validation_error=checkpoint(record,request,true)
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

  function owner:release()
    for request,record in pairs(records) do
      for _,key in ipairs(RAW_FIELDS) do if key~="token" then rawset(request,key,nil);record[key]=nil end end
      record.values=nil;record.profile=nil;record.access=nil;record.draft_guard=nil
    end
    access=nil
    records=setmetatable({},{__mode="k"})
  end

  return owner
end

return M
