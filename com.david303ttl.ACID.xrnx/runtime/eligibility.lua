-- SPDX-License-Identifier: GPL-3.0-only
-- Read-only eligibility for explicit musical and identity operations.
local ownership=require("renoise.phrase_ownership")
local validator=require("writers.phrase_validator")
local store=require("renoise.pattern_store")
local capabilities=require("renoise.target_capabilities")
local pitch_bend=require("writers.phrase_pitch_bend")
local M={}

local MINIMUM_COLLIDING_HOLDERS=2
local MINIMUM_PHRASE_CAPACITY=1
local MINIMUM_EFFECT_COLUMNS=0

local function phrase_limits()
  local ok,api=pcall(function()
    local host=rawget(_G,"renoise")
    return host and host.InstrumentPhrase
  end)
  if not ok or api==nil then return nil,"Phrase API is unavailable" end
  local function read(key)
    local readable,value=pcall(function() return api[key] end)
    if not readable or value==nil then return nil,false end
    return value,true
  end
  local max_lines,lines_ok=read("MAX_NUMBER_OF_LINES")
  local max_notes,notes_ok=read("MAX_NUMBER_OF_NOTE_COLUMNS")
  local max_effects,effects_ok=read("MAX_NUMBER_OF_EFFECT_COLUMNS")
  local play_pattern,play_ok=read("PLAY_PATTERN")
  local key_tracking_none,key_ok=read("KEY_TRACKING_NONE")
  if not lines_ok or not notes_ok or not effects_ok or not play_ok or not key_ok then
    return nil,"Cannot inspect phrase API limits"
  end
  if type(max_lines)~="number" or max_lines%1~=0 or max_lines<MINIMUM_PHRASE_CAPACITY or
      type(max_notes)~="number" or max_notes%1~=0 or max_notes<MINIMUM_PHRASE_CAPACITY or
      type(max_effects)~="number" or max_effects%1~=0 or max_effects<MINIMUM_EFFECT_COLUMNS then
    return nil,"Phrase API limits are invalid"
  end
  return {max_lines=max_lines,max_note_columns=max_notes,max_effect_columns=max_effects,
    play_pattern=play_pattern,key_tracking_none=key_tracking_none}
end

local function read_name(phrase)
  local ok,name=pcall(function() return phrase.name end)
  if not ok or type(name)~="string" then return nil,"Cannot inspect phrase ownership name" end
  return name
end

local function contains_target(group,target)
  if type(group)~="table" then return false end
  local selected_present=false
  for _,holder in ipairs(group) do
    if rawequal(holder.instrument,target.instrument) and rawequal(holder.phrase,target.phrase) then
      selected_present=true
    end
  end
  return selected_present
end

local function same_holders(group,expected,target)
  if type(group)~="table" or #group~=#expected or not contains_target(group,target) then
    return false
  end
  for _,saved in ipairs(expected) do
    local found
    for _,holder in ipairs(group) do
      if rawequal(holder.instrument,saved.instrument) and rawequal(holder.phrase,saved.phrase) then
        found=true;break
      end
    end
    if not found then return false end
  end
  return true
end

local function same_source(song,id,source,policy,pb_range)
  local current,current_policy,current_pb=store.read_entry(song,id)
  if not current then return false,current_policy end
  if not ownership.compare(source,current) or current_policy~=policy or current_pb~=pb_range then
    return false,"Committed source/settings changed during eligibility inspection"
  end
  return true
end

function M.compatibility(phrase,source,policy,pb_range,profile)
  local limits,limits_error=phrase_limits()
  if not limits then return nil,limits_error end
  local proof,proof_error=validator.compatibility(phrase,
    {pattern=source,output_policy=policy,pb_range=pb_range},profile,limits,
    {pitch_bend_delivery=pitch_bend.delivery_enabled})
  if not proof then return nil,proof_error end
  return proof
end

function M.same_independence(expected,current)
  if current.id~=expected.id or current.name~=expected.name or
      current.policy~=expected.policy or current.pb_range~=expected.pb_range or
      not rawequal(current.instrument,expected.instrument) or
      not rawequal(current.phrase,expected.phrase) or
      not ownership.compare(current.source,expected.source) or
      #current.proofs~=#expected.proofs then
    return false,"Collision authorization changed before identity resolution"
  end
  for _,saved in ipairs(expected.proofs) do
    local found
    for _,item in ipairs(current.proofs) do
      if rawequal(item.instrument,saved.instrument) and rawequal(item.phrase,saved.phrase) then
        found=item;break
      end
    end
    if not found or found.name~=saved.name or
        not ownership.compare(found.baseline,saved.baseline) or
        not capabilities.same(found.profile,saved.profile) then
      return false,"A colliding holder changed before identity resolution"
    end
  end
  return true
end

function M.independence(song,target)
  local ok,result,reason=pcall(function()
    local member,err=ownership.membership(song,target.instrument,target.phrase)
    if not member or not target.phrase then return nil,err or "An existing phrase is required" end
    local id=ownership.id(target.phrase)
    local groups,inventory_error=ownership.inventory(song)
    if not groups then return nil,inventory_error end
    local group=id and groups[id]
    if not group or #group<MINIMUM_COLLIDING_HOLDERS then return nil,"Select a colliding ACID phrase" end
    if not contains_target(group,target) then
      return nil,"Selected phrase is not in the collision group"
    end
    local selected_name,name_error=read_name(target.phrase)
    if not selected_name then return nil,name_error end
    local source,policy,pb=store.read_entry(song,id)
    if not source then return nil,policy end
    local first
    local holders={}
    for _,holder in ipairs(group) do
      local name,holder_name_error=read_name(holder.phrase)
      if not name then return nil,holder_name_error end
      if name~=selected_name then return nil,"Colliding holders have different ownership names" end
      local profile,profile_error=capabilities.inspect(holder.instrument)
      if not profile then return nil,profile_error end
      local proof,proof_error=M.compatibility(holder.phrase,source,policy,pb,profile)
      if not proof then return nil,proof_error end
      if first and not ownership.compare(first,proof.baseline) then
        return nil,"Colliding holders have different seals or content"
      end
      first=proof.baseline
      holders[#holders+1]={instrument=holder.instrument,phrase=holder.phrase,
        name=name,baseline=proof.baseline,profile=profile}
    end
    local latest_groups,latest_inventory_error=ownership.inventory(song)
    if not latest_groups then return nil,latest_inventory_error end
    if not same_holders(latest_groups[id],holders,target) then
      return nil,"Collision group changed during eligibility inspection"
    end
    for _,holder in ipairs(holders) do
      local current_profile,profile_error=capabilities.inspect(holder.instrument)
      if not current_profile or current_profile.read_error or
          not capabilities.same(holder.profile,current_profile) then
        return nil,profile_error or (current_profile and current_profile.read_error) or
          "A colliding holder output changed during eligibility inspection"
      end
    end
    for _,holder in ipairs(holders) do
      local name,holder_name_error=read_name(holder.phrase)
      local snapshot,snapshot_error=ownership.snapshot(holder.phrase)
      if not name or not snapshot or name~=holder.name or
          not ownership.compare(holder.baseline,snapshot) then
        return nil,holder_name_error or snapshot_error or
          "A colliding holder changed during eligibility inspection"
      end
    end
    local source_unchanged,source_error=same_source(song,id,source,policy,pb)
    if not source_unchanged then return nil,source_error end
    local final_groups,final_inventory_error=ownership.inventory(song)
    if not final_groups then return nil,final_inventory_error end
    if not same_holders(final_groups[id],holders,target) then
      return nil,"Collision group changed during eligibility inspection"
    end
    local retained_source,copy_error=ownership.copy_snapshot(source)
    if not retained_source then return nil,copy_error end
    return {id=id,holders=#group,instrument=target.instrument,phrase=target.phrase,
      name=selected_name,proofs=holders,source=retained_source,policy=policy,pb_range=pb}
  end)
  if not ok then return nil,"Cannot inspect collision resolution eligibility" end
  return result,reason
end

return M
