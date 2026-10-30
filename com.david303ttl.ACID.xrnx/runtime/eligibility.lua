-- SPDX-License-Identifier: GPL-3.0-only
-- Read-only eligibility for explicit musical and identity operations.
local ownership=require("renoise.phrase_ownership")
local validator=require("writers.phrase_validator")
local store=require("renoise.pattern_store")
local capabilities=require("renoise.target_capabilities")
local pitch_bend=require("writers.phrase_pitch_bend")
local M={}

function M.independence(song,target)
  local ok,result,reason=pcall(function()
    local member,err=ownership.membership(song,target.instrument,target.phrase)
    if not member or not target.phrase then return nil,err or "An existing phrase is required" end
    local id=ownership.id(target.phrase)
    local groups,inventory_error=ownership.inventory(song)
    if not groups then return nil,inventory_error end
    local group=id and groups[id]
    if not group or #group<2 then return nil,"Select a colliding ACID phrase" end
    local source,policy,pb=store.read_entry(song,id)
    if not source then return nil,policy end
    local first
    for _,holder in ipairs(group) do
      local profile,profile_error=capabilities.inspect(holder.instrument)
      if not profile then return nil,profile_error end
      local api=renoise.InstrumentPhrase
      local proof,proof_error=validator.compatibility(holder.phrase,
        {pattern=source,output_policy=policy,pb_range=pb},profile,
        {max_lines=api.MAX_NUMBER_OF_LINES,max_note_columns=api.MAX_NUMBER_OF_NOTE_COLUMNS,
          max_effect_columns=api.MAX_NUMBER_OF_EFFECT_COLUMNS,play_pattern=api.PLAY_PATTERN,
          key_tracking_none=api.KEY_TRACKING_NONE},{pitch_bend_delivery=pitch_bend.delivery_enabled})
      if not proof then return nil,proof_error end
      if first and not ownership.compare(first,proof.baseline) then
        return nil,"Colliding holders have different seals or content"
      end
      first=proof.baseline
    end
    return {id=id,holders=#group,instrument=target.instrument,phrase=target.phrase}
  end)
  if not ok then return nil,"Cannot inspect collision resolution eligibility" end
  return result,reason
end

return M
