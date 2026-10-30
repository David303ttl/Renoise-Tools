-- SPDX-License-Identifier: GPL-3.0-only
-- Read-only object targets and verified, session-local overwrite baselines.
local ownership=require("renoise.phrase_ownership")
local validator=require("writers.phrase_validator")
local capabilities=require("renoise.target_capabilities")
local pitch_bend=require("writers.phrase_pitch_bend")
local M={}

local function label(object,fallback)
  local ok,name=pcall(function() return object.name end)
  return ok and type(name)=="string" and name or fallback
end

function M.new(song,writer)
  local NEW={}
  local target=nil
  local baselines={}
  local cached_projection=nil
  local owner={}

  local function remember(result)
    cached_projection={kind=result.kind,reason=result.reason,instrument=result.instrument,
      phrase=result.phrase,instrument_name=result.instrument_name,phrase_name=result.phrase_name,
      instrument_index=result.instrument_index,phrase_index=result.phrase_index}
  end

  local function classify(instrument,phrase,adopt,expose_candidate)
    local ok,candidate,reason,kind=pcall(function()
      local profile,profile_error=capabilities.inspect(instrument)
      if not profile then return nil,profile_error,"unavailable" end
      local api=renoise.InstrumentPhrase
      return validator.classify(song,instrument,phrase,profile,{
        max_lines=api.MAX_NUMBER_OF_LINES,max_note_columns=api.MAX_NUMBER_OF_NOTE_COLUMNS,
        max_effect_columns=api.MAX_NUMBER_OF_EFFECT_COLUMNS,play_pattern=api.PLAY_PATTERN,
        key_tracking_none=api.KEY_TRACKING_NONE},{pitch_bend_delivery=pitch_bend.delivery_enabled})
    end)
    if not ok then
      local readable,detail=pcall(tostring,candidate)
      return nil,"Cannot inspect target"..(readable and (": "..detail) or ""),"unavailable"
    end
    if not candidate then return nil,reason,kind or "unavailable" end
    local readable,id=pcall(ownership.id,phrase)
    if not readable then return nil,"Cannot inspect phrase identity","unavailable" end
    local baseline={id=id,source=candidate.source,settings=candidate.settings,
      snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs}
    local bucket=baselines[instrument]
    if not bucket then bucket={};baselines[instrument]=bucket end
    if adopt then
      local adopted,copy_error=ownership.copy_snapshot(baseline)
      if not adopted then return nil,copy_error,"unavailable" end
      bucket[phrase]={baseline=adopted}
      return candidate,nil,"owned",adopted
    end
    if expose_candidate then
      local detached,copy_error=ownership.copy_snapshot(baseline)
      if not detached then return nil,copy_error,"unavailable" end
      baseline=detached
    end
    local previous=bucket[phrase]
    if previous then
      local same,difference=ownership.compare(previous.baseline,baseline)
      if not same and not previous.reason then previous.reason="Verified target baseline changed: "..difference end
      if previous.reason then return nil,previous.reason,"unavailable" end
    else
      previous={baseline=baseline};bucket[phrase]=previous
    end
    return expose_candidate and candidate or true,nil,"owned",previous.baseline
  end

  local function temporary(instrument,phrase)
    if type(writer.is_temporary)~="function" then return false end
    local ok,result=pcall(writer.is_temporary,song,instrument,phrase)
    if not ok then return nil,"Cannot inspect temporary phrase registry" end
    if type(result)~="boolean" then return nil,"Invalid temporary phrase registry result" end
    return result==true
  end

  local function target_state(detach_baseline)
    cached_projection=nil
    if not target then
      local result={kind="unavailable",reason="No target is selected"}
      remember(result)
      return result
    end
    local instrument,phrase=target.instrument,target.phrase
    local result={instrument=instrument,phrase=not rawequal(phrase,NEW) and phrase or nil,
      instrument_name=label(instrument,"Unavailable instrument"),
      phrase_name=rawequal(phrase,NEW) and "New Phrase" or label(phrase,"Unavailable phrase")}
    local index,position=ownership.membership(song,instrument,not rawequal(phrase,NEW) and phrase or nil)
    if not index then result.kind="unavailable";result.reason=position;remember(result);return result end
    result.instrument_index=index
    if rawequal(phrase,NEW) then result.kind="new";remember(result);return result end
    result.phrase_index=position
    local hidden,hidden_error=temporary(instrument,phrase)
    if hidden==nil or hidden then
      result.kind="unavailable";result.reason=hidden_error or "Writer temporary phrases cannot be selected"
      remember(result);return result
    end
    local candidate,reason,kind,baseline=classify(instrument,phrase)
    result.kind=kind;result.reason=reason
    if candidate then
      if detach_baseline then
        result.baseline=ownership.copy_snapshot(baseline)
      else
        result.baseline=baseline
      end
    end
    remember(result)
    return result
  end

  function owner:target_state()
    return target_state(true)
  end

  -- Internal edit persistence uses this fresh proof synchronously and never exposes it.
  function owner:edit_target_state()
    return target_state(false)
  end

  -- UI projections may be reused until a native change or target transition invalidates them.
  function owner:target_projection()
    if not cached_projection then self:target_state() end
    local projection={}
    for key,value in pairs(cached_projection or {}) do projection[key]=value end
    if next(projection)==nil then return {kind="unavailable",reason="No target is selected"} end
    return projection
  end

  function owner:invalidate_projection()
    cached_projection=nil
  end

  function owner:bind_new(instrument)
    target={instrument=instrument,phrase=NEW}
    cached_projection=nil
    return self:target_state()
  end

  function owner:bind_phrase(instrument,phrase)
    if phrase==nil then
      target={instrument=instrument,phrase={}}
    else target={instrument=instrument,phrase=phrase} end
    cached_projection=nil
    return self:target_state()
  end

  function owner:instrument_choices()
    local current,reason=ownership.is_current(song)
    if not current then return nil,reason end
    local ok,result=pcall(function()
      local choices={}
      for index,instrument in ipairs(song.instruments) do
        choices[#choices+1]={instrument=instrument,instrument_index=index,
          instrument_name=label(instrument,"Unavailable instrument")}
      end
      return choices
    end)
    if not ok then return nil,"Cannot inspect instrument inventory" end
    return result
  end

  function owner:phrase_choices(instrument)
    local index,reason=ownership.membership(song,instrument,nil)
    if not index then return nil,reason end
    local ok,result,err=pcall(function()
      local choices={{kind="new",instrument=instrument,instrument_index=index,phrase_name="New Phrase"}}
      for position,phrase in ipairs(instrument.phrases) do
        local hidden,hidden_error=temporary(instrument,phrase)
        if hidden==nil then return nil,hidden_error end
        if not hidden then choices[#choices+1]={instrument=instrument,phrase=phrase,
          instrument_index=index,phrase_index=position,phrase_name=label(phrase,"Unavailable phrase")} end
      end
      return choices
    end)
    if not ok then return nil,"Cannot inspect phrase inventory" end
    return result,err
  end

  -- Replace the verified baseline only with exact postcommit writer evidence.
  function owner:adopt(instrument,phrase,baseline)
    local member,membership_error=ownership.membership(song,instrument,phrase)
    if not member then return nil,membership_error end
    local id=ownership.validate_identity(song,instrument,phrase)
    if not id then return nil,"Committed destination identity is not unique" end
    local copied,copy_error=ownership.copy_snapshot(baseline)
    if not copied then return nil,copy_error end
    if copied.id~=nil and copied.id~=id then return nil,"Committed baseline identity changed" end
    copied.id=id
    local bucket=baselines[instrument]
    if not bucket then bucket={};baselines[instrument]=bucket end
    bucket[phrase]={baseline=copied}
    if target and rawequal(target.instrument,instrument) and rawequal(target.phrase,phrase) then
      cached_projection=nil
    end
    return copied
  end

  function owner:refresh_inventory() return self:target_state() end

  function owner:release()
    song=nil
    writer=nil
    target=nil
    cached_projection=nil
    baselines={}
  end

  function owner:draft_options()
    return {validate=function(expected_song,instrument,phrase)
      if not rawequal(expected_song,song) then return nil,"Draft song is no longer current" end
      return classify(instrument,phrase,false,true)
    end}
  end

  return owner
end

return M
