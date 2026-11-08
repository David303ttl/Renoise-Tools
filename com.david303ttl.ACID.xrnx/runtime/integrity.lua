-- SPDX-License-Identifier: GPL-3.0-only
-- Live-song evidence for fail-closed mutation handling.
local ownership=require("renoise.phrase_ownership")
local validator=require("writers.phrase_validator")
local M={}

local function label(object,fallback)
  local ok,value=pcall(function() return object.name end)
  return ok and type(value)=="string" and value or fallback
end

local function normalize_baseline(baseline)
  if type(baseline)~="table" or type(baseline.snapshot)~="table" or
      type(baseline.source)~="table" or type(baseline.settings)~="table" or
      type(baseline.planning_inputs)~="table" then
    return nil,"Recovery baseline is incomplete"
  end
  local snapshot=baseline.snapshot
  local identity=validator.retained_baseline_identity(snapshot)
  if not identity or not validator.is_retained_baseline_identity(identity,snapshot) then
    local resolved,_,resolved_identity=validator.retained_baseline(baseline.snapshot)
    snapshot,identity=resolved,resolved_identity
  end
  if not snapshot or not identity or not validator.is_retained_baseline_identity(identity,snapshot) then
    return nil,"Recovery baseline proof is unavailable"
  end
  local normalized,copy_error=ownership.copy_snapshot({id=baseline.id,source=baseline.source,
    settings=baseline.settings,planning_inputs=baseline.planning_inputs})
  if not normalized then return nil,copy_error end
  normalized.snapshot=snapshot
  return normalized
end

function M.new(song,drafts)
  local entries={}
  local serial=0
  local owner={}
  local captures=setmetatable({},{__mode="k"})
  local draft_release_tokens=setmetatable({},{__mode="k"})
  local original_song=setmetatable({song},{__mode="v"})

  function owner:capture_metadata(expected_store)
    local ok,store=pcall(function() return song.tool_data end)
    if not ok or (store~=nil and type(store)~="string") or store~=expected_store then
      return nil,"Cannot capture exact metadata recovery evidence"
    end
    local descriptor={}
    captures[descriptor]={operation="metadata",store=store}
    return descriptor
  end

  function owner:capture_mutation()
    local ok,capture=pcall(function()
      assert(song.tool_data==nil or type(song.tool_data)=="string","Cannot inspect song store")
      local result={operation="mutation",store=song.tool_data,instruments={}}
      for _,instrument in ipairs(song.instruments) do
        local item={instrument=instrument,phrases={}}
        for _,phrase in ipairs(instrument.phrases) do
          item.phrases[#item.phrases+1]={phrase=phrase,name=phrase.name,
            snapshot=assert(ownership.capture_recovery(phrase))}
        end
        result.instruments[#result.instruments+1]=item
      end
      return result
    end)
    if not ok then return nil,"Cannot capture mutation recovery evidence" end
    local descriptor={}
    captures[descriptor]=capture
    return descriptor
  end

  function owner:record(evidence)
    if song==nil then return false,"No current document is attached" end
    local record={reason="ACID cannot safely update this song",recovery={}}
    if captures[evidence] then
      if captures[evidence].operation=="metadata" then
        record.metadata=captures[evidence]
      else
        record.mutation=captures[evidence]
      end
      captures[evidence]=nil
    end
    local ok,record_error=pcall(function()
      if record.metadata or record.mutation then return end
      if type(evidence)~="table" or getmetatable(evidence)~=nil then error("Invalid recovery evidence") end
      record.operation=evidence.operation or "regenerate"
      record.committed=evidence.committed==true
      if record.operation~="create" and record.operation~="regenerate" then error("Invalid recovery operation") end
      if record.operation=="create" and not record.committed then
        if not (type(evidence.pre_store)=="string" or
          (evidence.pre_store==nil and evidence.pre_store_absent==true))
          or type(evidence.destination_phrases)~="table" then
          error("Missing create recovery preconditions")
        end
        record.pre_store=evidence.pre_store
        record.destination_phrases={}
        for i,phrase in ipairs(evidence.destination_phrases) do record.destination_phrases[i]=phrase end
      end
      if type(evidence.reason)=="string" then record.reason=evidence.reason end
      if type(evidence.destination_phrases)=="table" and
          (not record.committed or record.operation=="regenerate") and
          record.destination_phrases==nil then
        record.destination_phrases={}
        for i,phrase in ipairs(evidence.destination_phrases) do
          record.destination_phrases[i]=phrase
        end
      end
      record.instrument=evidence.instrument
      record.phrase=evidence.phrase
      if evidence.baseline~=nil then
        local baseline,baseline_error=normalize_baseline(evidence.baseline)
        if not baseline then error(baseline_error,0) end
        record.baseline=baseline
      end
      if evidence.committed_baseline~=nil then
        local baseline,baseline_error=normalize_baseline(evidence.committed_baseline)
        if not baseline then error(baseline_error,0) end
        record.committed_baseline=baseline
      end
      if evidence.draft_capture~=nil then
        record.draft_capture=evidence.draft_capture
      end
      for _,item in ipairs(evidence.recovery or {}) do
        record.recovery[#record.recovery+1]={instrument=item.instrument,phrase=item.phrase,
          role=type(item.role)=="string" and item.role or "recovery",
          label=type(item.label)=="string" and item.label or label(item.phrase,"Recovery phrase")}
      end
    end)
    if not ok then record.incomplete=true end
    entries[#entries+1]=record
    serial=serial+1
    return true
  end

  function owner:state()
    local labels={}
    for _,entry in ipairs(entries) do
      for _,item in ipairs(entry.recovery) do labels[#labels+1]={role=item.role,label=item.label} end
    end
    return {blocked=#entries>0,reason=entries[1] and entries[1].reason or nil,
      serial=serial,recovery=labels}
  end

  function owner:prepare_draft_release()
    local retained={}
    for _,entry in ipairs(entries) do
      if entry.draft_capture then
        if not drafts or not drafts.is_current(song,entry.draft_capture) then
          return nil,"Captured draft preconditions have changed; preserve the detached draft"
        end
        retained[#retained+1]={entry=entry,capture=entry.draft_capture}
      end
    end
    local token={}
    draft_release_tokens[token]=retained
    return token
  end

  function owner:complete_draft_release(token)
    local retained=draft_release_tokens[token]
    if not retained then return false,"Draft release proof is stale or unknown" end
    draft_release_tokens[token]=nil
    for _,item in ipairs(retained) do
      if item.entry.draft_capture==item.capture then
        item.entry.draft_capture=nil
      end
    end
    return true
  end

  function owner:release()
    song=nil;drafts=nil;entries={};captures={}
  end

  function owner:suspend()
    captures=setmetatable({},{__mode="k"})
    draft_release_tokens=setmetatable({},{__mode="k"})
    song=nil;drafts=nil
  end

  function owner:resume(current_song,current_drafts)
    if not rawequal(current_song,original_song[1]) or song~=nil then
      return false,"Recovery evidence belongs to a different song"
    end
    song=current_song;drafts=current_drafts
    return true
  end

  return owner
end

return M
