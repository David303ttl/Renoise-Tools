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
  local committed_captures=setmetatable({},{__mode="k"})
  local draft_release_tokens=setmetatable({},{__mode="k"})
  local original_song=setmetatable({song},{__mode="v"})

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

  local function committed_delta_matches(instrument,phrase,baseline,pre_evidence,committed_store)
    local before=pre_evidence and captures[pre_evidence]
    if not before or type(committed_store)~="string" or song.tool_data~=committed_store then
      return false,"Committed store or pre-commit recovery evidence is unavailable"
    end
    local ok,matches=pcall(function()
      if #song.instruments~=#before.instruments then return false end
      local target_seen=false
      for instrument_index,saved_instrument in ipairs(before.instruments) do
        local current_instrument=song.instruments[instrument_index]
        if not rawequal(current_instrument,saved_instrument.instrument) or
            #current_instrument.phrases~=#saved_instrument.phrases then return false end
        for phrase_index,saved_phrase in ipairs(saved_instrument.phrases) do
          local current_phrase=current_instrument.phrases[phrase_index]
          if not rawequal(current_phrase,saved_phrase.phrase) then return false end
          local comparison=rawequal(current_phrase,phrase) and "name" or "exact"
          if not ownership.compare(saved_phrase.snapshot,assert(ownership.snapshot(current_phrase)),comparison) then
            return false
          end
          if rawequal(current_phrase,phrase) then
            if target_seen or not rawequal(current_instrument,instrument) or
                not ownership.membership(song,instrument,phrase) or
                not ownership.compare(saved_phrase.snapshot,baseline.snapshot,"name") then
              return false
            end
            target_seen=true
          end
        end
      end
      return target_seen and ownership.id(phrase)==baseline.id
    end)
    if not ok or not matches then
      return false,"Protected phrase state changed before committed recovery capture"
    end
    return true
  end

  function owner:capture_committed(instrument,phrase,baseline,reason,pre_evidence,committed_store)
    if not rawequal(song,original_song[1]) or not instrument or not phrase or type(baseline)~="table" then
      return nil,"Committed recovery target is incomplete"
    end
    local delta_matches,delta_error=committed_delta_matches(instrument,phrase,baseline,
      pre_evidence,committed_store)
    if pre_evidence then captures[pre_evidence]=nil end
    if not delta_matches then return nil,delta_error end
    local descriptor,capture_error=self:capture_mutation()
    if not descriptor then return nil,capture_error end
    committed_captures[descriptor]={instrument=instrument,phrase=phrase,
      baseline=ownership.copy_snapshot(baseline),reason=reason}
    if not committed_captures[descriptor].baseline then
      captures[descriptor]=nil
      committed_captures[descriptor]=nil
      return nil,"Committed recovery baseline is invalid"
    end
    return descriptor
  end

  function owner:record(evidence)
    if song==nil then return false,"No current document is attached" end
    local record={reason="Song integrity requires revalidation",recovery={}}
    if captures[evidence] then
      record.mutation=captures[evidence]
      record.committed_target=committed_captures[evidence]
      if record.committed_target and type(record.committed_target.reason)=="string" then
        record.reason=record.committed_target.reason
      end
      captures[evidence]=nil
      committed_captures[evidence]=nil
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
        if entry.committed_target then
          local target=entry.committed_target
          if not ownership.membership(song,target.instrument,target.phrase) then
            return nil,"Committed phrase identity has not been restored"
          end
          local selected_ok,selected_instrument,selected_phrase=pcall(function()
            return song.selected_instrument,song.selected_phrase
          end)
          if not selected_ok or not rawequal(selected_instrument,target.instrument) or
              not rawequal(selected_phrase,target.phrase) then
            return nil,"Select the committed phrase before revalidation"
          end
          local baseline,baseline_error=current_baseline({instrument=target.instrument,phrase=target.phrase})
          if not baseline then return nil,baseline_error end
          if not ownership.compare(target.baseline,baseline) then
            return nil,"Committed phrase baseline has changed"
          end
        end
      else
        if type(entry.destination_phrases)=="table" and
            (not entry.committed or entry.operation=="regenerate") then
          if not ownership.membership(song,entry.instrument) or
            #entry.instrument.phrases~=#entry.destination_phrases then
            return nil,"Destination phrase inventory has not been restored"
          end
          for i,phrase in ipairs(entry.destination_phrases) do
            if not rawequal(entry.instrument.phrases[i],phrase) then
              return nil,"Destination phrase inventory order has not been restored"
            end
          end
        end
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

  function owner:clear(proof,before_clear)
    if proofs[proof]~=serial then return false,"Revalidation proof is stale or unknown" end
    local ok,verified,reason=pcall(verify)
    if not ok or not verified then return false,reason or "Cannot inspect recovery consistency" end
    if before_clear then
      local cleared,message=before_clear()
      if not cleared then return false,message end
    end
    entries={}
    serial=serial+1
    proofs=setmetatable({},{__mode="k"})
    return true
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
    song=nil;drafts=nil;idle=nil;entries={};proofs={};captures={};committed_captures={}
  end

  function owner:suspend()
    proofs=setmetatable({},{__mode="k"})
    captures=setmetatable({},{__mode="k"})
    committed_captures=setmetatable({},{__mode="k"})
    draft_release_tokens=setmetatable({},{__mode="k"})
    song=nil;drafts=nil;idle=nil
  end

  function owner:resume(current_song,current_drafts,current_idle)
    if not rawequal(current_song,original_song[1]) or song~=nil then
      return false,"Recovery evidence belongs to a different song"
    end
    song=current_song;drafts=current_drafts;idle=current_idle
    proofs=setmetatable({},{__mode="k"})
    return true
  end

  return owner
end

return M
