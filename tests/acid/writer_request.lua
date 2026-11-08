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
    options={pitch_bend_delivery=pitch_bend.delivery_enabled,
      normal_volume=policies.NORMAL_VOLUME,accent_volume=policies.ACCENT_VOLUME}}
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
  local baseline,baseline_reference
  if phrase then
    local candidate=validator.classify(song,instrument,phrase,profile,caps,
      {pitch_bend_delivery=pitch_bend.delivery_enabled})
    if candidate then
      baseline={id=ownership.id(phrase),source=candidate.source,settings=candidate.settings,
        snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs}
      local _,_,_,reference=validator.retained_baseline(candidate.baseline)
      baseline_reference=reference
    end
  end
  local operation_token=options.token or token()
  local captured_instrument_index=instrument_index
  local captured_baseline=baseline
  local public_baseline=baseline and {id=baseline.id,source=baseline.source,
    settings=baseline.settings,planning_inputs=baseline.planning_inputs} or nil
  local captured_policy=output_policy
  local captured_pb_range=pb_range
  local request={kind=kind,target_kind=target_kind,token=operation_token,song=song,
    instrument=instrument,phrase=phrase,source=output.source,output_policy=output_policy,
    pb_range=pb_range,id=baseline and baseline.id,baseline=public_baseline,
    capabilities=profile,capacities=caps,planning_inputs=planning_inputs(profile,caps),
    timing_model=song.transport and song.transport.timing_model,
    groove_enabled=song.transport and song.transport.groove_enabled==true,
    draft_capture=options.draft_capture,epoch=options.epoch or 1}
  local expected_revision
  function request:is_current()
    return operation_token:is_current()
  end
  function request:validate_authorization_checkpoint()
    if not operation_token:is_current() then return false,"generation was invalidated" end
    local ok,current_song=pcall(renoise.song)
    if not ok or not rawequal(current_song,song) then return false,"song changed during generation" end
    if not rawequal(song.instruments[captured_instrument_index],instrument) then
      return false,"target instrument changed during generation"
    end
    if kind=="regenerate" then
      local found
      for _,item in ipairs(instrument.phrases) do if rawequal(item,phrase) then found=true;break end end
      local current_id=ownership.id(phrase)
      if not found or (current_id~=captured_baseline.id and current_id~=expected_revision) then
        return false,"target phrase revision changed during generation"
      end
    end
    if song.transport.timing_model~=renoise.Transport.TIMING_MODEL_LPB then
      return false,"transport changed to unsupported timing during generation"
    end
    return true
  end
  function request:retained_baseline_reference(supplied)
    if not rawequal(supplied,operation_token) or not operation_token:is_current() then
      return false,"Request authorization was revoked"
    end
    if kind~="regenerate" then return nil,nil end
    if not baseline_reference then return false,"Test request has no retained baseline proof" end
    return baseline_reference,nil
  end
  function request:mutate(supplied,action)
    if not rawequal(supplied,operation_token) then error("Invalid mutation token",0) end
    if not operation_token:is_current() then error("Request mutation was revoked",0) end
    return action()
  end
  function request:expect_revision(supplied,revision_id)
    if not rawequal(supplied,operation_token) or kind~="regenerate" or
        type(revision_id)~="number" or revision_id%1~=0 or revision_id<1 or
        ownership.id(phrase)~=captured_baseline.id then
      return false,"Test request rejected the authorized revision"
    end
    expected_revision=revision_id
    return true
  end
  function request:record_blocker(_,evidence)
    request.blocker=evidence
    return true
  end
  return request
end

return M
