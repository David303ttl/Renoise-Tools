-- SPDX-License-Identifier: GPL-3.0-only
-- Metadata-only resolution of one explicitly selected matching ID collision.
local ownership=require("renoise.phrase_ownership")
local store=require("renoise.pattern_store")
local eligibility=require("runtime.eligibility")
local capabilities=require("renoise.target_capabilities")
local M={}

local MINIMUM_COLLISION_SIZE=2
local CLONED_ENTRY_COUNT=1

local function read_name(phrase)
  local ok,name=pcall(function() return phrase.name end)
  if not ok or type(name)~="string" then return nil,"Cannot inspect phrase ownership name" end
  return name
end

local function capture_group(song,id)
  local groups,reason=ownership.inventory(song)
  if not groups then return nil,reason end
  local holders=groups[id]
  if type(holders)~="table" or #holders<MINIMUM_COLLISION_SIZE then
    return nil,"Select a colliding ACID phrase"
  end
  local result={}
  for _,holder in ipairs(holders) do
    local name,name_error=read_name(holder.phrase)
    if not name then return nil,name_error end
    local snapshot,snapshot_error=ownership.snapshot(holder.phrase)
    if not snapshot then return nil,snapshot_error end
    local index,index_error=ownership.snapshot_index(snapshot)
    if not index then return nil,index_error end
    local profile,profile_error=capabilities.inspect(holder.instrument)
    if not profile or profile.read_error then
      return nil,profile_error or (profile and profile.read_error) or "Cannot inspect collision output"
    end
    result[#result+1]={instrument=holder.instrument,phrase=holder.phrase,name=name,
      snapshot=snapshot,index=index,profile=profile}
  end
  return result
end

local function same_group(song,id,expected)
  local groups,reason=ownership.inventory(song)
  if not groups then return false,reason end
  local current=groups[id]
  if not current then return false,"Collision group changed" end
  if #current~=#expected then return false,"Collision group changed" end
  for _,saved in ipairs(expected) do
    local found
    for _,item in ipairs(current) do
      if rawequal(item.instrument,saved.instrument) and rawequal(item.phrase,saved.phrase) then
        found=item;break
      end
    end
    if not found then return false,"Collision group changed" end
    local profile,profile_error=capabilities.inspect(found.instrument)
    if not profile or profile.read_error or not capabilities.same(profile,saved.profile) then
      return false,profile_error or "A colliding holder output changed before resolution"
    end
    local matches,snapshot_error=ownership.matches_snapshot(found.phrase,saved.snapshot,nil,saved.index)
    if not matches then
      return false,snapshot_error or "A colliding holder changed before resolution"
    end
  end
  return true
end

local function same_record(song,id,source,policy,pb_range)
  local current,current_policy,current_pb=store.read_entry(song,id)
  if not current then return false,current_policy end
  if not ownership.compare(source,current) or current_policy~=policy or current_pb~=pb_range then
    return false,"Committed source/settings changed before resolution"
  end
  return true
end

local function verify_committed_baseline(song,target,id,source,policy,pb_range)
  local profile,profile_error=capabilities.inspect(target.instrument)
  if not profile then return nil,profile_error end
  local compatible,reason=eligibility.compatibility(target.phrase,source,policy,pb_range,profile)
  if not compatible then return nil,reason end
  return ownership.copy_snapshot({id=id,source=compatible.source,settings=compatible.settings,
    snapshot=compatible.baseline,planning_inputs=compatible.planning_inputs})
end

function M.run(song,target,options)
  assert(type(options)=="table" and type(options.guard)=="function" and
    type(options.mutate)=="function","Make Independent runtime hooks are required")
  local permitted,proof_error=options.guard()
  if not permitted then return false,proof_error or "Make Independent is unavailable" end
  local proof,reason=eligibility.independence(song,target)
  if not proof then return false,reason end
  local authorized,authorization_error=options.guard(proof)
  if not authorized then return false,authorization_error or "Collision authorization changed" end
  local id=proof.id
  local expected,group_error=capture_group(song,id)
  if not expected then return false,group_error end
  if #expected~=#proof.proofs then return false,"Collision group changed" end
  for _,item in ipairs(expected) do
    local matched
    for _,verified in ipairs(proof.proofs) do
      if rawequal(item.instrument,verified.instrument) and rawequal(item.phrase,verified.phrase) then
        matched=verified;break
      end
    end
    if not matched or item.name~=matched.name or
        not ownership.compare(item.snapshot,matched.baseline) or
        not capabilities.same(item.profile,matched.profile) then
      return false,"A colliding holder changed during eligibility inspection"
    end
  end
  local selected
  for _,item in ipairs(expected) do
    if rawequal(item.instrument,target.instrument) and rawequal(item.phrase,target.phrase) then
      selected=item;break
    end
  end
  if not selected then return false,"Selected phrase is not in the collision group" end
  local source,policy,pb_range=store.read_entry(song,id)
  if not source then return false,policy end
  if not ownership.compare(source,proof.source) or policy~=proof.policy or pb_range~=proof.pb_range then
    return false,"Committed source/settings changed during eligibility inspection"
  end
  local original_entries,entries_error=store.read(song)
  if not original_entries then return false,entries_error end
  original_entries=assert(ownership.copy_snapshot(original_entries))
  local stable,stable_error=same_record(song,id,source,policy,pb_range)
  if not stable then return false,stable_error end
  local fresh_id,allocation_error=store.allocate(song)
  if not fresh_id then return false,allocation_error end
  local new_name,name_error=ownership.make_name(target.phrase,fresh_id)
  if not new_name then return false,name_error end
  if ownership.id({name=new_name})~=fresh_id then return false,"New ownership name could not be verified" end
  local candidate,prepare_error=store.prepare(song,fresh_id,source,policy,pb_range,function()
    local valid,guard_error=options.guard()
    if not valid then return false,guard_error end
    local same,same_error=same_group(song,id,expected)
    if not same then return false,same_error end
    local record_ok,record_error=same_record(song,id,source,policy,pb_range)
    if not record_ok then return false,record_error end
    local before_entries,before_error=store.read(song)
    if not before_entries or not ownership.compare(original_entries,before_entries) then
      return false,before_error or "Committed source entries changed before resolution"
    end
    local latest,latest_error=store.allocate(song)
    if not latest then return false,latest_error end
    if latest~=fresh_id then return false,"Allocated phrase ID changed before resolution" end
    return options.guard()
  end)
  if not candidate then return false,prepare_error end
  local transaction_ok,accepted,transaction_result=pcall(function()
    return options.mutate(function()
      local valid,guard_error=options.guard()
      if not valid then return false,guard_error end
      local same,same_error=same_group(song,id,expected)
      if not same then return false,same_error end
      local record_ok,record_error=same_record(song,id,source,policy,pb_range)
      if not record_ok then return false,record_error end
      local latest,latest_error=store.allocate(song)
      if not latest or latest~=fresh_id then
        return false,latest_error or "Allocated phrase ID changed before resolution"
      end
      if type(song.describe_undo)=="function" then
        local described,describe_error=pcall(song.describe_undo,song,"ACID: Make Independent")
        if not described then return false,"Cannot describe Make Independent undo: "..tostring(describe_error) end
      end
      local commit_called,committed,commit_error=pcall(store.commit,song,candidate)
      if not commit_called then commit_error,committed=committed,nil end
      local attempted=store.candidate_status(candidate)
      local rename_ok,rename_error=false,commit_error
      if committed then
        rename_ok,rename_error=pcall(function()
          local latest_valid,latest_guard_error=options.guard()
          if not latest_valid then error(latest_guard_error or "Resolution authorization changed",0) end
          local unchanged,unchanged_error=same_group(song,id,expected)
          if not unchanged then error(unchanged_error,0) end
          target.phrase.name=new_name
        end)
      end
      local committed_baseline
      local function verify_commit()
        if not committed or not rename_ok then return false end
        local snapshot,snapshot_error=ownership.snapshot(target.phrase)
        if not snapshot then return false,snapshot_error end
        local same_content=ownership.compare(selected.snapshot,snapshot,"name")
        if not same_content or snapshot.name~=new_name or ownership.id(target.phrase)~=fresh_id then
          return false,"Selected phrase changed beyond its ownership name"
        end
        local new_groups,inventory_error=ownership.inventory(song)
        if not new_groups then return false,inventory_error end
        if not new_groups[fresh_id] or #new_groups[fresh_id]~=1 or
            not rawequal(new_groups[fresh_id][1].phrase,target.phrase) then
          return false,"New phrase ID is not unique"
        end
        local cloned,clone_policy,clone_pb=store.read_entry(song,fresh_id)
        if not cloned or not ownership.compare(source,cloned) or clone_policy~=policy or clone_pb~=pb_range then
          return false,"Cloned committed source/settings could not be verified"
        end
        local old_ok,old_error=same_record(song,id,source,policy,pb_range)
        if not old_ok then return false,old_error end
        committed_baseline,old_error=verify_committed_baseline(song,target,fresh_id,source,policy,pb_range)
        if not committed_baseline then return false,old_error or "Independent phrase baseline could not be verified" end
        local entries,entries_error=store.read(song)
        if not entries then return false,entries_error end
        local entry_count=0
        for existing_id in pairs(entries) do
          entry_count=entry_count+1
          if existing_id~=fresh_id and original_entries[existing_id]==nil then
            return false,"An unexpected committed source entry was added"
          end
        end
        local original_entry_count=0
        for existing_id,entry in pairs(original_entries) do
          original_entry_count=original_entry_count+1
          if not ownership.compare(entry,entries[existing_id]) then
            return false,"Another committed source entry changed"
          end
        end
        if entry_count~=original_entry_count+CLONED_ENTRY_COUNT then
          return false,"Committed source entry set changed beyond the cloned entry"
        end
        for _,item in ipairs(expected) do
          if not rawequal(item.phrase,target.phrase) then
            local name_now,name_reason=read_name(item.phrase)
            local snap_now,snap_reason=ownership.snapshot(item.phrase)
            if not name_now or not snap_now or name_now~=item.name or
                not ownership.compare(item.snapshot,snap_now) then
              return false,name_reason or snap_reason or "Another collision holder changed"
            end
          end
        end
        return true
      end
      local verified,verify_error=verify_commit()
      if committed and rename_ok and verified then
        store.release_candidate(candidate)
        return true,{instrument=target.instrument,phrase=target.phrase,old_id=id,id=fresh_id,
          source=source,output_policy=policy,pb_range=pb_range,baseline=committed_baseline,
          committed_store=song.tool_data}
      end
      local rollback_errors={}
      local current_name,name_read_error=read_name(target.phrase)
      if current_name==new_name then
        local restored,restore_error=pcall(function() target.phrase.name=selected.name end)
        local restored_name=read_name(target.phrase)
        if not restored or restored_name~=selected.name then
          rollback_errors[#rollback_errors+1]="phrase name rollback failed: "..tostring(restore_error or name_read_error)
        end
      elseif current_name~=selected.name then
        rollback_errors[#rollback_errors+1]="phrase name changed outside the transaction"
      end
      if attempted and attempted.write_attempted then
        local restored,restore_error=store.restore(song,candidate)
        if not restored then rollback_errors[#rollback_errors+1]="song data rollback failed: "..tostring(restore_error) end
      end
      local restored_snapshot,snapshot_error=ownership.snapshot(target.phrase)
      if not restored_snapshot or not ownership.compare(selected.snapshot,restored_snapshot) then
        rollback_errors[#rollback_errors+1]="selected phrase restoration could not be verified: " ..
          tostring(snapshot_error or "content changed during rollback")
      end
      for _,item in ipairs(expected) do
        if not rawequal(item.phrase,target.phrase) then
          local restored_name,name_error=read_name(item.phrase)
          local restored_holder,holder_error=ownership.snapshot(item.phrase)
          if not restored_name or not restored_holder or restored_name~=item.name or
              not ownership.compare(item.snapshot,restored_holder) then
            rollback_errors[#rollback_errors+1]="collision holder restoration could not be verified: " ..
              tostring(name_error or holder_error or "holder changed during rollback")
          end
        end
      end
      local source_restored,source_restore_error=same_record(song,id,source,policy,pb_range)
      if not source_restored then
        rollback_errors[#rollback_errors+1]="old source restoration could not be verified: " ..
          tostring(source_restore_error)
      end
      store.release_candidate(candidate)
      if #rollback_errors>0 then error(table.concat(rollback_errors,"; "),0) end
      return false,verify_error or rename_error or commit_error or "Make Independent transaction failed"
    end)
  end)
  store.release_candidate(candidate)
  if not transaction_ok then error(accepted,0) end
  if accepted~=true then return false,transaction_result or "Make Independent mutation was rejected" end
  if type(transaction_result)~="table" then return false,"Make Independent returned no committed result" end
  return true,transaction_result
end

return M
