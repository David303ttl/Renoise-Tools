-- SPDX-License-Identifier: GPL-3.0-only
-- Live-song recovery evidence and read-only proofs for explicit revalidation.
local ownership=require("renoise.phrase_ownership")
local validator=require("writers.phrase_validator")
local capabilities=require("renoise.target_capabilities")
local pitch_bend=require("writers.phrase_pitch_bend")
local M={}

local function label(object,fallback)
  local ok,value=pcall(function() return object.name end)
  return ok and type(value)=="string" and value or fallback
end

function M.new(song,drafts,idle)
  local entries={}
  local serial=0
  local proofs=setmetatable({},{__mode="k"})
  local owner={}
  local captures=setmetatable({},{__mode="k"})

  function owner:capture_mutation()
    local ok,capture=pcall(function()
      assert(song.tool_data==nil or type(song.tool_data)=="string","Cannot inspect song store")
      local result={operation="mutation",store=song.tool_data,instruments={}}
      for _,instrument in ipairs(song.instruments) do
        local item={instrument=instrument,phrases={}}
        for _,phrase in ipairs(instrument.phrases) do
          item.phrases[#item.phrases+1]={phrase=phrase,name=phrase.name,
            snapshot=assert(ownership.snapshot(phrase))}
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
    local record={reason="Song integrity requires revalidation",recovery={}}
    if captures[evidence] then
      record.mutation=captures[evidence]
      captures[evidence]=nil
    end
    local ok=pcall(function()
      if record.mutation then return end
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
      record.instrument=evidence.instrument
      record.phrase=evidence.phrase
      record.baseline=ownership.copy_snapshot(evidence.baseline)
      record.committed_baseline=ownership.copy_snapshot(evidence.committed_baseline)
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

  local function current_baseline(entry)
    local profile,err=capabilities.inspect(entry.instrument)
    if not profile then return nil,err end
    local api=renoise.InstrumentPhrase
    local candidate,reason=validator.classify(song,entry.instrument,entry.phrase,profile,{
      max_lines=api.MAX_NUMBER_OF_LINES,max_note_columns=api.MAX_NUMBER_OF_NOTE_COLUMNS,
      max_effect_columns=api.MAX_NUMBER_OF_EFFECT_COLUMNS,play_pattern=api.PLAY_PATTERN,
      key_tracking_none=api.KEY_TRACKING_NONE},{pitch_bend_delivery=pitch_bend.delivery_enabled})
    if not candidate then return nil,reason end
    return ownership.copy_snapshot({id=ownership.id(entry.phrase),source=candidate.source,
      settings=candidate.settings,snapshot=candidate.baseline,planning_inputs=candidate.planning_inputs})
  end

  local function verify()
    if song==nil then return nil,"No current document is attached" end
    if #entries==0 then return nil,"No integrity blocker has recovery evidence" end
    local current,current_error=ownership.is_current(song)
    if not current then return nil,current_error end
    local settled,reason=idle()
    if not settled then return nil,reason or "The writer has not settled" end
    local undo=type(song.is_undo_redoing)=="function" and song:is_undo_redoing()
    if type(undo)~="boolean" or undo then
      return nil,"Native undo or redo is processing or unavailable"
    end
    for _,entry in ipairs(entries) do
      if entry.incomplete then return nil,"Recovery evidence is incomplete; use native undo or a known-good saved song" end
      if entry.mutation then
        local captured=entry.mutation
        if song.tool_data~=captured.store or #song.instruments~=#captured.instruments then
          return nil,"Mutation state has not been restored"
        end
        for i,item in ipairs(captured.instruments) do
          if not rawequal(song.instruments[i],item.instrument) or #item.instrument.phrases~=#item.phrases then
            return nil,"Mutation destination inventory has not been restored"
          end
          for j,saved in ipairs(item.phrases) do
            if not rawequal(item.instrument.phrases[j],saved.phrase) or saved.phrase.name~=saved.name
              or not ownership.compare(saved.snapshot,assert(ownership.snapshot(saved.phrase))) then
              return nil,"Mutation phrase state has not been restored"
            end
          end
        end
      else
        for _,item in ipairs(entry.recovery) do
          if item.phrase==nil then return nil,"Recovery object evidence is incomplete" end
          for _,instrument in ipairs(song.instruments) do
            for _,phrase in ipairs(instrument.phrases) do
              if rawequal(phrase,item.phrase) then
                return nil,"Recovery phrase remains: "..item.label.."; preserve and remove it natively before revalidation"
              end
            end
          end
        end
        if entry.operation=="create" and not entry.committed then
          if not ownership.membership(song,entry.instrument) or song.tool_data~=entry.pre_store
            or #entry.instrument.phrases~=#entry.destination_phrases then
            return nil,"Create destination/store preconditions have not been restored"
          end
          for i,phrase in ipairs(entry.destination_phrases) do
            if not rawequal(entry.instrument.phrases[i],phrase) then
              return nil,"Create destination preconditions have not been restored"
            end
          end
        else
          local baseline,baseline_error=current_baseline(entry)
          if not baseline then return nil,baseline_error end
          local before=not entry.committed and entry.baseline and ownership.compare(entry.baseline,baseline)
          local committed=entry.committed_baseline and ownership.compare(entry.committed_baseline,baseline)
          if not before and not committed then
            return nil,"Destination/source consistency cannot be verified; use native undo or a known-good saved song"
          end
        end
        if entry.draft_capture and (not drafts or not drafts.is_current(song,entry.draft_capture)) then
          return nil,"Captured draft preconditions have changed; preserve the detached draft"
        end
      end
    end
    return true
  end

  function owner:status()
    local ok,verified,reason=pcall(verify)
    if not ok then verified=nil;reason="Cannot inspect recovery consistency" end
    local result=self:state()
    result.verified=verified==true
    result.reason=reason or result.reason
    if not verified then return result end
    local proof={}
    proofs[proof]=serial
    return result,proof
  end

  function owner:clear(proof)
    if proofs[proof]~=serial then return false,"Revalidation proof is stale or unknown" end
    local ok,verified,reason=pcall(verify)
    if not ok or not verified then return false,reason or "Cannot inspect recovery consistency" end
    entries={}
    serial=serial+1
    proofs=setmetatable({},{__mode="k"})
    return true
  end

  function owner:release()
    song=nil;drafts=nil;idle=nil;entries={};proofs={};captures={}
  end

  return owner
end

return M
