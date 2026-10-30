-- Test-only request factory for the explicit writer API.
-- Production code never infers a request from positional arguments. Callers
-- dispatch the returned request through writer.create or writer.regenerate so
-- the tests exercise the same create(request, done) contract as production.
local ownership=require("renoise.phrase_ownership")
local capabilities=require("renoise.target_capabilities")
local pitch_bend=require("writers.phrase_pitch_bend")
local validator=require("writers.phrase_validator")
local planner=require("model.output_planner")
local sequencer=require("model.sequencer")
local policies=require("model.policies")

local M={}

local function limits()
  local api=renoise.InstrumentPhrase
  return {max_lines=api.MAX_NUMBER_OF_LINES or 512,
    max_note_columns=api.MAX_NUMBER_OF_NOTE_COLUMNS or 12,
    max_effect_columns=api.MAX_NUMBER_OF_EFFECT_COLUMNS or 8,
    play_pattern=api.PLAY_PATTERN,key_tracking_none=api.KEY_TRACKING_NONE}
end

local function planning_inputs(profile,caps)
  local fields={}
  for _,key in ipairs({"sample","plugin","midi","alias","read_error"}) do
    fields[key]=profile[key]
  end
  local copied={}
  for _,key in ipairs({"max_lines","max_note_columns","max_effect_columns","play_pattern",
      "key_tracking_none"}) do copied[key]=caps[key] end
  return {capabilities=fields,capacities=copied,
    options={pitch_bend_delivery=pitch_bend.delivery_enabled}}
end

local function token()
  local value={current=true}
  function value:is_current() return self.current==true end
  return value
end

function M.build(song,instrument_index,pattern,target_index,options)
  options=options or {}
  local instrument=song.instruments and song.instruments[instrument_index]
  if not instrument then return nil,"Missing test instrument" end
  target_index=target_index or (#instrument.phrases==0 and 1 or 1)
  local phrase,kind,target_kind
  if target_index<=#instrument.phrases then
    phrase=instrument.phrases[target_index]
    kind,target_kind="regenerate","owned"
  else
    kind,target_kind="create","new"
  end
  local profile=assert(capabilities.inspect(instrument))
  local caps=limits()
  local output_policy=options.output_policy or policies.DEFAULT_OUTPUT_POLICY
  local pb_range=options.pb_range==nil and policies.DEFAULT_PB_RANGE or options.pb_range
  if not policies.valid_output_policy(output_policy) then
    return nil,{kind="failure",status="failed",code="source.output_policy",category="source",
      message="Invalid phrase output policy",reason="Invalid phrase output policy",verified=false}
  end
  if not policies.valid_pb_range(pb_range) then
    return nil,{kind="failure",status="failed",code="source.pb_range",category="source",
      message="Invalid PB range",reason="Invalid PB range",verified=false}
  end
  local source_valid,source_error=sequencer.validate(pattern)
  if not source_valid then
    return nil,{kind="failure",status="failed",code="source.invalid",category="source",
      message=source_error,reason=source_error,verified=false,token=options.token}
  end
  local output,planning_error=planner.plan(pattern,output_policy,pb_range,caps,profile,
    {pitch_bend_delivery=pitch_bend.delivery_enabled})
  if not output then
    return nil,{kind="failure",status="failed",code="phrase.unrepresentable",category="phrase",
      message=planning_error,reason=planning_error,verified=false,token=options.token}
  end
  local baseline
  if phrase then
    local candidate=validator.classify(song,instrument,phrase,profile,caps,
      {pitch_bend_delivery=pitch_bend.delivery_enabled})
    if candidate then
      baseline={id=ownership.id(phrase),source=candidate.source,settings=candidate.settings,
        snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs}
    end
  end
  local operation_token=options.token or token()
  local captured_instrument_index=instrument_index
  local captured_profile=profile
  local captured_limits=caps
  local captured_baseline=baseline
  local captured_policy=output_policy
  local captured_pb_range=pb_range
  local request={kind=kind,target_kind=target_kind,token=operation_token,song=song,
    instrument=instrument,phrase=phrase,source=output.source,output_policy=output_policy,
    pb_range=pb_range,id=baseline and baseline.id,baseline=baseline,
    capabilities=profile,capacities=caps,planning_inputs=planning_inputs(profile,caps),
    timing_model=song.transport and song.transport.timing_model,
    groove_enabled=song.transport and song.transport.groove_enabled==true,
    draft_capture=options.draft_capture,epoch=options.epoch or 1}
  function request:is_current()
    return operation_token:is_current()
  end
  function request:validate_checkpoint()
    if not operation_token:is_current() then return false,"generation was invalidated" end
    local ok,current_song=pcall(renoise.song)
    if not ok or not rawequal(current_song,song) then return false,"song changed during generation" end
    local current_instrument=song.instruments and song.instruments[captured_instrument_index]
    if not rawequal(current_instrument,instrument) then
      return false,"target instrument changed during generation"
    end
    local current_profile=capabilities.inspect(instrument)
    if not capabilities.same(captured_profile,current_profile) then
      return false,"target output capabilities changed during generation"
    end
    if kind=="regenerate" then
      local found
      for index,item in ipairs(instrument.phrases) do
        if rawequal(item,phrase) then
          if found then return false,"target phrase was removed during generation" end
          found=index
        end
      end
      if not found then return false,"target phrase was removed during generation" end
      if ownership.id(phrase)~=captured_baseline.id or ownership.status(phrase)~="owned" then
        return false,"target phrase changed during generation"
      end
      local candidate,reason=validator.classify(song,instrument,phrase,current_profile,captured_limits,
        {pitch_bend_delivery=pitch_bend.delivery_enabled})
      if not candidate then return false,reason end
      local actual={id=ownership.id(phrase),source=candidate.source,settings=candidate.settings,
        snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs}
      if not ownership.compare(captured_baseline,actual) then
        return false,"Committed target baseline changed"
      end
    end
    local timing=renoise.Transport.TIMING_MODEL_LPB
    if timing==nil or song.transport.timing_model~=timing then
      return false,"transport changed to unsupported timing during generation"
    end
    return true
  end
  function request:mutate(supplied,action)
    if not rawequal(supplied,operation_token) then error("Invalid mutation token",0) end
    if not operation_token:is_current() then error("Request mutation was revoked",0) end
    return action()
  end
  function request:cleanup_authorized(supplied)
    return rawequal(supplied,operation_token) and not request.settled
  end
  function request:cleanup_mutate(supplied,action)
    if not self:cleanup_authorized(supplied) or type(action)~='function' then
      error('Cleanup mutation is not authorized',0)
    end
    return action()
  end
  function request:record_blocker(_,evidence)
    request.blocker=evidence
    return true
  end
  return request
end

return M
