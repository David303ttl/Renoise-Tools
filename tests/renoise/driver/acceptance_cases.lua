-- Fixed native acceptance cases for the disposable development host.
local M = {}

local function describe_failure(value)
  if type(value) == "table" then
    local fields = {}
    for _, key in ipairs({ "kind", "status", "code", "category", "message", "reason" }) do
      if type(value[key]) == "string" then fields[#fields + 1] = key .. "=" .. value[key] end
    end
    if #fields > 0 then return table.concat(fields, "; ") end
  end
  return tostring(value)
end

local function context_for(song)
  local context_module = require("runtime.context")
  local writer = require("writers.phrase_writer")
  local context = context_module.new({
    writer = writer,
    capture = function() return nil, "native acceptance does not generate through the context" end,
    sink = function() return false, "native acceptance does not use the musical sink" end
  })
  context:attach_document(song)
  context:open_dialog()
  return context
end

local function on_next_idle(callback)
  local idle = renoise.tool().app_idle_observable
  local notifier
  notifier = function()
    pcall(function() idle:remove_notifier(notifier) end)
    callback()
  end
  idle:add_notifier(notifier)
end

local function save_independent_fixture(song)
  local name = "acceptance-independent.xrns"
  local path = renoise.tool().bundle_path .. "\\..\\fixtures\\" .. name
  pcall(os.remove, path)
  local saved, save_error = pcall(function() renoise.app():save_song_as(path) end)
  if not saved then return nil, tostring(save_error) end
  local opened, file = pcall(io.open, path, "rb")
  if not opened or not file then return nil, "Renoise did not create the round-trip song" end
  local size = file:seek("end")
  pcall(function() file:close() end)
  if type(size) ~= "number" or size <= 0 then return nil, "Saved round-trip song is empty" end
  return { fixture = name, bytes = size }
end

local function run_make_independent(done)
  local song = renoise.song()
  local instrument_index = song.selected_instrument_index
  local instrument = song.instruments[instrument_index]
  local sequence = require("model.sequencer")
  local writer = require("writers.phrase_writer")
  local store = require("renoise.pattern_store")
  local ownership = require("renoise.phrase_ownership")
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local source = sequence.new_pattern(8)
  source.pitch_events[1] = sequence.new_pitch(4, 0, true, false)
  local request, request_error = factory.build(song, instrument_index, source)
  if not request then
    done({ status = "FAIL", case = "make-independent", reason = describe_failure(request_error) })
    return true
  end
  local called = false
  local function process_result(result)
    if called then return end
    called = true
    if type(result) ~= "table" or result.kind ~= "success" or result.verified ~= true or not result.phrase then
      done({ status = "FAIL", case = "make-independent",
        reason = type(result) == "table" and describe_failure(result) or "writer did not return a verified phrase" })
      return
    end

    local original = result.phrase
    local old_id = ownership.id(original)
    local original_before = ownership.snapshot(original)
    if not old_id or not original_before then
      done({ status = "FAIL", case = "make-independent", reason = "generated phrase identity or snapshot is unavailable" })
      return
    end
    local duplicate = instrument:insert_phrase_at(#instrument.phrases + 1)
    duplicate:copy_from(original)
    duplicate.name = original.name
    local duplicate_before = ownership.snapshot(duplicate)
    if not duplicate_before or not ownership.compare(original_before, duplicate_before) then
      done({ status = "FAIL", case = "make-independent", reason = "native phrase copy did not preserve the source snapshot" })
      return
    end

    local context = context_for(song)
    local bound = context:bind_phrase(instrument, duplicate)
    if not bound or not rawequal(bound.instrument, instrument) or not rawequal(bound.phrase, duplicate) then
      context:release_document()
      done({ status = "FAIL", case = "make-independent", reason = "copied phrase could not be selected" })
      return
    end
    local eligibility, eligibility_error = context:independence_eligibility()
    if not eligibility then
      context:release_document()
      done({ status = "FAIL", case = "make-independent", reason = tostring(eligibility_error) })
      return
    end
    local changed, outcome = context:make_independent()
    if not changed then
      context:release_document()
      done({ status = "FAIL", case = "make-independent", reason = tostring(outcome) })
      return
    end

    local old_source, old_policy, old_pb = store.read_entry(song, old_id)
    local new_source, new_policy, new_pb = store.read_entry(song, outcome.id)
    local groups = ownership.inventory(song)
    local target = context:target_state()
    local independent_snapshot = ownership.snapshot(duplicate)
    local selected_content_preserved = independent_snapshot and
      ownership.compare(duplicate_before, independent_snapshot, "name")
    local original_after = ownership.snapshot(original)
    local original_unchanged = original_after and ownership.compare(original_before, original_after)
    local source_preserved = old_source and new_source and
      sequence.same_source(old_source, source) and sequence.same_source(new_source, source) and
      old_policy == request.output_policy and new_policy == request.output_policy and
      old_pb == request.pb_range and new_pb == request.pb_range
    local identity_passed = outcome.old_id == old_id and outcome.id ~= old_id and
      ownership.id(original) == old_id and ownership.id(duplicate) == outcome.id and
      selected_content_preserved and original_unchanged and source_preserved and
      groups and #groups[old_id] == 1 and #groups[outcome.id] == 1 and
      rawequal(target.instrument, instrument) and rawequal(target.phrase, duplicate)
    local details = {
      status = identity_passed and "PASS" or "FAIL",
      case = "make-independent",
      old_id = old_id,
      new_id = ownership.id(duplicate),
      holders_before = 2,
      holders_after_old_id = groups and #groups[old_id] or 0,
      holders_after_new_id = groups and #groups[outcome.id] or 0,
      selected_content_preserved = selected_content_preserved == true,
      original_holder_unchanged = original_unchanged == true,
      source_and_settings_preserved = source_preserved == true,
      target_remains_selected = rawequal(target.instrument, instrument) and rawequal(target.phrase, duplicate),
    }
    local changed_source = sequence.copy_source(source)
    changed_source.pitch_events[1] = sequence.new_pitch(5,0,true,false)
    local duplicate_index
    for index, phrase in ipairs(instrument.phrases) do
      if rawequal(phrase, duplicate) then duplicate_index = index; break end
    end
    local regenerate_request, regenerate_error = factory.build(song, instrument_index,
      changed_source, duplicate_index)
    if not regenerate_request or regenerate_request.kind ~= "regenerate" then
      details.status = "FAIL"
      details.reason = describe_failure(regenerate_error or "independent target did not build a regenerate request")
      context:release_document()
      done(details)
      return
    end
    local regenerate_accepted, regenerate_start_error = writer.regenerate(regenerate_request, function(regenerated)
      if type(regenerated) ~= "table" or regenerated.kind ~= "success" or
          regenerated.verified ~= true or not rawequal(regenerated.phrase, duplicate) then
        details.status = "FAIL"
        details.regenerate_error = describe_failure(regenerated or "regeneration did not return the same verified phrase")
        context:release_document()
        done(details)
        return
      end
      on_next_idle(function()
        local regenerated_snapshot = ownership.snapshot(duplicate)
        local regenerated_source, regenerated_policy, regenerated_pb = store.read_entry(song, outcome.id)
        local regenerated_groups = ownership.inventory(song)
        local original_after_regenerate = ownership.snapshot(original)
        details.regenerated_same_object = rawequal(regenerated.phrase, duplicate)
        details.phrase_count_after_regenerate = #instrument.phrases
        details.source_changed_by_regenerate = regenerated_source and
          sequence.same_source(regenerated_source, changed_source) or false
        details.regenerate_settings_preserved = regenerated_policy == request.output_policy and
          regenerated_pb == request.pb_range
        details.original_holder_unchanged_after_regenerate = original_after_regenerate and
          ownership.compare(original_before, original_after_regenerate)
        details.holders_after_regenerate = regenerated_groups and regenerated_groups[outcome.id] and
          #regenerated_groups[outcome.id] or 0
        local regenerate_passed = details.regenerated_same_object and
          details.phrase_count_after_regenerate == 2 and regenerated_snapshot ~= nil and
          details.source_changed_by_regenerate and details.regenerate_settings_preserved and
          details.original_holder_unchanged_after_regenerate and
          details.holders_after_regenerate == 1
        details.status = identity_passed and regenerate_passed and "PASS" or "FAIL"
        details.case = "make-independent"
        details.regeneration_preserved_same_phrase = regenerate_passed == true
        if details.status == "FAIL" then
          context:release_document()
          done(details)
          return
        end
        local saved, save_error = save_independent_fixture(song)
        if not saved then
          details.status = "FAIL"
          details.save_error = save_error
        else
          details.roundtrip_fixture = saved.fixture
          details.roundtrip_bytes = saved.bytes
        end
        context:release_document()
        local function inspect_history(expected_source, expected_snapshot)
          local data_before = song.tool_data
          local check_context = context_for(song)
          check_context:bind_phrase(instrument, duplicate)
          local classification = check_context:target_state()
          local eligible, eligibility_error = check_context:musical_eligibility()
          local stored_source = store.read_entry(song, outcome.id)
          local actual_snapshot = ownership.snapshot(duplicate)
          local actual_id = ownership.id(duplicate)
          local source_matches = stored_source and sequence.same_source(stored_source, expected_source) or false
          local phrase_matches = actual_snapshot and ownership.compare(expected_snapshot, actual_snapshot) or false
          local fully_compatible = source_matches and phrase_matches and actual_id == outcome.id and
            classification.kind == "owned" and eligible ~= nil
          local mismatch = not source_matches or not phrase_matches or actual_id ~= outcome.id
          local safely_blocked = mismatch and
            (classification.kind ~= "owned" or eligible == nil)
          local data_unchanged = song.tool_data == data_before
          check_context:release_document()
          return {
            classification = classification.kind,
            reason = classification.reason or eligibility_error,
            source_matches = source_matches == true,
            phrase_matches = phrase_matches == true,
            id_matches = actual_id == outcome.id,
            safe = fully_compatible or safely_blocked,
            safely_blocked = safely_blocked == true,
            tool_data_unchanged = data_unchanged == true
          }
        end
    on_next_idle(function()
      local can_undo, can_redo = song:can_undo(), song:can_redo()
      details.song_can_undo_after_idle = can_undo
      details.song_can_redo_after_idle = can_redo
      details.undo_available = can_undo
      if not can_undo then
        details.undo_consistency = "unavailable"
        done(details)
        return
      end
      local undo_called, undo_error = pcall(function() song:undo() end)
      if not undo_called then
        details.undo_consistency = "FAIL"
        details.undo_error = tostring(undo_error)
        details.status = "FAIL"
        done(details)
        return
      end
      on_next_idle(function()
        local undo_observation = inspect_history(changed_source, regenerated_snapshot)
        details.undo_observation = undo_observation
        details.song_can_redo_after_undo = song:can_redo()
        if not details.song_can_redo_after_undo then
          details.undo_consistency = "FAIL"
          details.status = "FAIL"
          done(details)
          return
        end
        local redo_called, redo_error = pcall(function() song:redo() end)
        if not redo_called then
          details.undo_consistency = "FAIL"
          details.redo_error = tostring(redo_error)
          details.status = "FAIL"
          done(details)
          return
        end
        on_next_idle(function()
          local redo_observation = inspect_history(changed_source, regenerated_snapshot)
          details.redo_observation = redo_observation
          details.undo_consistency = undo_observation.safe and undo_observation.tool_data_unchanged and
            redo_observation.safe and redo_observation.tool_data_unchanged and "PASS" or "FAIL"
          if details.undo_consistency ~= "PASS" then details.status = "FAIL" end
          done(details)
        end)
        end)
      end)
    end)
    if not regenerate_accepted then
      details.status = "FAIL"
      details.regenerate_error = describe_failure(regenerate_start_error)
      context:release_document()
      done(details)
    end
    end)
  end
  local accepted, start_error = writer.create(request, function(result)
    local idle = renoise.tool().app_idle_observable
    local notifier
    notifier = function()
      pcall(function() idle:remove_notifier(notifier) end)
      process_result(result)
    end
    idle:add_notifier(notifier)
  end)
  if not accepted and not called then
    called = true
    done({ status = "FAIL", case = "make-independent", reason = describe_failure(start_error) })
  end
  return true
end

local function run_draft_recovery(done)
  local song = renoise.song()
  local instrument = song.instruments[song.selected_instrument_index]
  instrument.name = "ACID Native Acceptance Recovery"
  local sequence = require("model.sequencer")
  local policies = require("model.policies")
  local drafts = require("runtime.draft_cache")
  local context = context_for(song)
  local bound = context:bind_new(instrument)
  if not bound or bound.kind ~= "new" then
    context:release_document()
    done({ status = "FAIL", case = "draft-recovery", reason = "New Phrase target could not be selected" })
    return true
  end
  local source = sequence.new_pattern(7)
  source.pitch_events[1] = sequence.new_pitch(7, 0, false, true)
  local saved, save_error = drafts.put(song, instrument, nil, source,
    policies.DEFAULT_OUTPUT_POLICY, policies.DEFAULT_PB_RANGE, context:draft_options())
  if not saved then
    context:release_document()
    done({ status = "FAIL", case = "draft-recovery", reason = tostring(save_error) })
    return true
  end
  local token, detach_error = drafts.detach(song, instrument, nil, "Native acceptance recovery entry")
  local entries = context:recovery_entries()
  local entry = entries and entries[1]
  if not token or not entry or entry.token ~= token then
    context:release_document()
    done({ status = "FAIL", case = "draft-recovery", reason = tostring(detach_error or "recovery entry was not listed") })
    return true
  end

  local copied, copy_result = context:copy_recovery_to_new(token, entry.revision)
  local restored, restored_policy, restored_pb = drafts.get(song, instrument, nil, context:draft_options())
  local copied_ok = copied and restored and sequence.same_source(restored, source) and
    restored_policy == policies.DEFAULT_OUTPUT_POLICY and restored_pb == policies.DEFAULT_PB_RANGE
  local retained = context:recovery_entries()
  local retained_ok = retained and #retained == 1 and retained[1].token == token and retained[1].revision == entry.revision
  local discarded, discard_error = context:discard_recovery(token, entry.revision)
  local after_discard = context:recovery_entries()
  local passed = copied_ok and retained_ok and discarded and after_discard and #after_discard == 0
  local details = {
    status = passed and "PASS" or "FAIL",
    case = "draft-recovery",
    recovery_token = token,
    recovery_revision = entry.revision,
    copied_to_new = copied == true,
    copy_error = not copied and tostring(copy_result) or nil,
    copied_source_preserved = copied_ok == true,
    restored_source_matches = restored and sequence.same_source(restored, source) or false,
    restored_output_policy = restored_policy,
    restored_pb_range = restored_pb,
    recovery_retained_until_discard = retained_ok == true,
    discarded = discarded == true,
    recovery_empty_after_discard = after_discard ~= nil and #after_discard == 0,
    warning = copy_result and copy_result.warning or discard_error
  }
  context:release_document()
  done(details)
  return true
end

local function run_integrity_observers(done)
  local song=renoise.song()
  local instrument=song.instruments[song.selected_instrument_index]
  local sequence=require("model.sequencer")
  local writer=require("writers.phrase_writer")
  local inventory_module=require("runtime.inventory")
  local original_new=inventory_module.new
  local fail_adoption=true
  inventory_module.new=function(...)
    local inventory=original_new(...)
    local adopt=inventory.adopt
    inventory.adopt=function(self,...)
      if fail_adoption then
        fail_adoption=false
        return nil,"Injected native acceptance adoption failure"
      end
      return adopt(self,...)
    end
    return inventory
  end
  local delivered_result
  local sink_calls=0
  local observed={idle=0,busy=0}
  local attached,context_or_error=pcall(function()
    local runtime=require("runtime.context").new({
      writer=writer,
      capture=function() return nil,"The attached runtime owns request capture" end,
      sink=function(request,completion)
        sink_calls=sink_calls+1
        local accepted,reason
        if request.kind=="create" then accepted,reason=writer.create(request,completion)
        elseif request.kind=="regenerate" then accepted,reason=writer.regenerate(request,completion)
        else return false,"Unexpected request kind" end
        if accepted and sink_calls==2 and writer.state()=="busy" then
          local phrase=observed.phrase
          local old=phrase:column_is_muted(1)
          phrase:set_column_is_muted(1,not old)
          phrase:set_column_is_muted(1,old)
          observed.active_mutation=true
        end
        return accepted,reason
      end,
      drafts=require("runtime.draft_cache"),
      cancel=writer.cancel
    })
    runtime:attach_document(song)
    return runtime
  end)
  inventory_module.new=original_new
  if not attached then
    done({status="FAIL",case="integrity-observers",reason=tostring(context_or_error)})
    return true
  end
  local context=context_or_error
  context:open_dialog(function(result) delivered_result=result end)
  if song.transport.timing_model~=renoise.Transport.TIMING_MODEL_LPB then
    context:release_document()
    done({status="FAIL",case="integrity-observers",reason="Native acceptance requires LPB timing"})
    return true
  end
  song.transport.lpb=16
  song.transport.groove_enabled=false
  local bound=context:bind_new(instrument)
  if not bound or bound.kind~="new" then
    context:release_document()
    done({status="FAIL",case="integrity-observers",reason="New Phrase target could not be selected"})
    return true
  end
  local source=sequence.new_pattern(4)
  source.pitch_events[1]=sequence.new_pitch(4,0,true,false)
  source.time_events[1]="N"
  context:transition("edit",{source=source,output_policy="play_once",pb_range=0})
  local accepted,request_error=context:request_generation("manual")
  if not accepted then
    context:release_document()
    done({status="FAIL",case="integrity-observers",reason=tostring(request_error or "initial request rejected")})
    return true
  end
  local function fail(reason)
    pcall(function() context:release_document() end)
    done({status="FAIL",case="integrity-observers",reason=tostring(reason)})
  end
  local function first_commit()
    local result=delivered_result
    if type(result)~="table" or result.status~="integrity_blocked" or result.committed~=true or
        not result.phrase or not context:integrity_state().blocked then
      fail("post-commit adoption failure did not persist a blocker")
      return
    end
    observed.phrase=result.phrase
    context:bind_new(instrument)
    context:close_dialog()
    context:open_dialog(function(value) delivered_result=value end)
    local blocked=context:request_generation("manual")
    if blocked then fail("generation resumed after dialog reopen without revalidation");return end

    local observer=require("runtime.observers").new()
    observer:attach(song,{
      occupancy_state=function()
        local status=writer.state()
        return {status=status}
      end,
      is_temporary=function(_,target_instrument,phrase)
        return writer.is_temporary(song,target_instrument,phrase)
      end,
      mutation_state=function() return {depth=0} end,
      mark_dirty=function() end
    },function(kind,phrase,internal)
      if kind=="content" and rawequal(phrase,observed.phrase) then
        if writer.state()=="busy" then observed.busy=observed.busy+1
        else observed.idle=observed.idle+1 end
      end
    end)
    local phrase=observed.phrase
    local old_name=phrase:column_name(1)
    local old_mute=phrase:column_is_muted(1)
    local changed_name=old_name=="ACID acceptance column" and "ACID acceptance column 2" or "ACID acceptance column"
    phrase:set_column_name(1,changed_name)
    phrase:set_column_is_muted(1,not old_mute)
    phrase:set_column_name(1,old_name)
    phrase:set_column_is_muted(1,old_mute)
    if observed.idle<4 then observer:detach();fail("column name/mute changes did not notify during idle editing");return end
    observer:refresh()
    phrase:set_column_name(1,changed_name)
    phrase:set_column_name(1,old_name)
    if observed.idle<6 then observer:detach();fail("column listeners did not survive observer refresh");return end
    phrase:set_column_name(1,changed_name)
    local status,proof=context:revalidation_status()
    if status.verified or proof then observer:detach();fail("changed committed destination passed revalidation");return end
    phrase:set_column_name(1,old_name)
    status,proof=context:revalidation_status()
    if not status.verified or not context:revalidate(proof) then
      observer:detach();fail(status.reason or "restored destination did not revalidate");return
    end
    context:bind_new(instrument)
    source.pitch_events[1]=sequence.new_pitch(5,0,true,false)
    context:transition("edit",{source=source,output_policy="play_once",pb_range=0})
    delivered_result=nil
    local next_accepted,next_error=context:request_generation("manual")
    if not next_accepted then observer:detach();fail(next_error or "fresh request was rejected after revalidation");return end
    if not observed.active_mutation or observed.busy<2 then
      observer:detach();fail("column mute change was not observed while the native writer was busy");return
    end
    if writer.state()~="busy" then observer:detach();fail("native writer did not remain active after the observer check");return end
    local second_waits=0
    local second_idle=renoise.tool().app_idle_observable
    local wait_second
    wait_second=function()
      if not delivered_result then
        second_waits=second_waits+1
        if second_waits>6000 then
          pcall(function() second_idle:remove_notifier(wait_second) end)
          observer:detach();fail("native writer did not deliver its second terminal result");return
        end
        return
      end
      pcall(function() second_idle:remove_notifier(wait_second) end)
      local committed=delivered_result
      local count=observed.idle+observed.busy
      observer:detach()
      phrase:set_column_name(1,changed_name)
      if count~=observed.idle+observed.busy or observer:state().attached then
        fail("column listeners remained active after detach");return
      end
      local passed=type(committed)=="table" and committed.kind=="success" and committed.verified==true and
        context:integrity_state().blocked==false and sink_calls==2
      context:release_document()
      done({status=passed and "PASS" or "FAIL",case="integrity-observers",
        post_commit_blocked=true,revalidation_required=true,restored_destination_revalidated=true,
        column_name_idle_notifications=observed.idle,column_mute_busy_notifications=observed.busy,
        listeners_detached=not observer:state().attached,generation_calls=sink_calls,
        fresh_commit=committed and committed.status or nil,
        reason=not passed and "fresh generation did not commit after explicit revalidation" or nil})
    end
    second_idle:add_notifier(wait_second)
  end
  local first_waits=0
  local first_idle=renoise.tool().app_idle_observable
  local wait_first
  wait_first=function()
    if delivered_result then
      pcall(function() first_idle:remove_notifier(wait_first) end)
      first_commit();return
    end
    first_waits=first_waits+1
    if first_waits>6000 then
      pcall(function() first_idle:remove_notifier(wait_first) end)
      local writer_status,writer_token=writer.state()
      local runtime_status=context:state()
      fail("native writer did not deliver its first terminal result; writer="..
        tostring(writer_status).." token="..tostring(writer_token~=nil).." runtime="..
        tostring(runtime_status.status).." diagnostic="..
        tostring(runtime_status.last_diagnostic and runtime_status.last_diagnostic.message)..
        " sink_calls="..tostring(sink_calls))
      return
    end
  end
  first_idle:add_notifier(wait_first)
  return true
end

local function run_writer_recovery(done)
  local song=renoise.song()
  local instrument_index=song.selected_instrument_index
  local instrument=song.instruments[instrument_index]
  local writer=require("writers.phrase_writer")
  local sequence=require("model.sequencer")
  local ownership=require("renoise.phrase_ownership")
  local store=require("renoise.pattern_store")
  local drafts=require("runtime.draft_cache")
  local factory=dofile(renoise.tool().bundle_path.."/__dev/writer_request.lua")
  local context,original_clear
  local finished=false
  local pending_idle
  local function finish(ok,reason)
    if finished then return end
    finished=true
    if pending_idle then pcall(function() renoise.tool().app_idle_observable:remove_notifier(pending_idle) end) end
    if original_clear then writer.clear_integrity_blocker=original_clear end
    if context then context:release_document() end
    done({status=ok and "PASS" or "FAIL",case="writer-recovery",reason=reason,
      promoted_identity_preserved=ok,committed_source_preserved=ok,
      contradictory_success_blocked=ok,captured_draft_preserved=ok,
      failed_clear_retryable=ok,exceptional_getters_rejected=ok})
  end
  local function check(action)
    local ok,reason=pcall(action)
    if not ok then finish(false,tostring(reason)) end
  end
  for _,operation in ipairs({writer.create,writer.regenerate}) do
    for _,field in ipairs({"kind","token","epoch"}) do
      local request=setmetatable({}, {__index=function(_,key)
        if key==field then error("Injected admission getter failure",0) end
      end})
      local ok,accepted,rejection=pcall(operation,request,function() finish(false,"Rejected request completed") end)
      if not ok or accepted or not rejection or rejection.kind~="failure" then
        finish(false,"Exceptional facade getter escaped rejection");return true
      end
    end
  end
  song.transport.lpb=16
  song.transport.groove_enabled=false
  local source=sequence.new_pattern(4)
  source.pitch_events[1]=sequence.new_pitch(4,0,true,false)
  source.time_events[1]="N"
  local request,reason=factory.build(song,instrument_index,source,#instrument.phrases+1)
  if not request then finish(false,describe_failure(reason));return true end
  local mutate=request.mutate
  local destination,name,stored
  function request:mutate(token,action)
    local result=mutate(self,token,action)
    if type(result)=="table" and result.committed then
      destination=instrument.phrases[#instrument.phrases]
      name,stored=destination.name,song.tool_data
      error("Injected exception after native source commit",0)
    end
    return result
  end
  local accepted,rejection=writer.create(request,function(result)
    on_next_idle(function() check(function()
      assert(result.kind=="failure" and result.status=="integrity_blocked" and result.committed)
      assert(result.phrase==nil and request.blocker and request.blocker.committed)
      assert(rawequal(instrument.phrases[#instrument.phrases],destination) and destination.name==name)
      assert(song.tool_data==stored and ownership.id(destination))
      assert(sequence.same_source(assert(store.read_entry(song,ownership.id(destination))),source))
      local captured,terminal
      context=require("runtime.context").new({writer=writer,drafts=drafts,cancel=writer.cancel,
        capture=function() return nil,"Attached editor owns capture" end,
        sink=function(value,completion)
          captured=value
          return writer.regenerate(value,function(value_result)
            value_result.integrity_blocked=true
            completion(value_result)
          end)
        end})
      context:attach_document(song)
      context:open_dialog(function(value) terminal=value end)
      assert(context:bind_phrase(instrument,destination).kind=="owned")
      source.pitch_events[1]=sequence.new_pitch(5,0,true,false)
      assert(context:transition("edit",{source=source,output_policy="play_once",pb_range=0}))
      assert(context:request_generation("manual"))
      local waits=0
      local function inspect()
        if finished then return end
        if not terminal then
          waits=waits+1
          if waits>6000 then finish(false,"Native regenerate did not complete; writer="..tostring(writer.state()));return end
          return
        end
        renoise.tool().app_idle_observable:remove_notifier(inspect)
        pending_idle=nil
        check(function()
          assert(terminal.kind=="failure" and terminal.status=="integrity_blocked")
          assert(context:integrity_state().blocked and not context:request_generation("manual"))
          assert(captured.draft_capture and drafts.is_current(song,captured.draft_capture))
          local status,proof=context:revalidation_status()
          assert(status.verified and proof,status.reason)
          original_clear=writer.clear_integrity_blocker
          for _,mode in ipairs({"false","throw"}) do
            writer.clear_integrity_blocker=function()
              if mode=="throw" then error("Injected writer clearance failure",0) end
              return false
            end
            assert(not context:revalidate(proof))
            assert(context:integrity_state().blocked and context:revalidation_status().verified)
            assert(not context:request_generation("manual"))
          end
          writer.clear_integrity_blocker=original_clear
          assert(context:revalidate(proof))
          assert(not context:integrity_state().blocked)
          finish(true)
        end)
      end
      pending_idle=inspect
      renoise.tool().app_idle_observable:add_notifier(inspect)
    end) end)
  end)
  if not accepted then finish(false,describe_failure(rejection)) end
  return true
end

local function run_editor_responsiveness(done)
  local song=renoise.song()
  local unpack_values=unpack or table.unpack
  local function pack_values(...) return {n=select("#",...),...} end
  local instrument_index=song.selected_instrument_index
  local instrument=song.instruments[instrument_index]
  local sequence=require("model.sequencer")
  local editor=require("model.editor_state")
  local writer=require("writers.phrase_writer")
  local ownership=require("renoise.phrase_ownership")
  local validator=require("writers.phrase_validator")
  local factory=dofile(renoise.tool().bundle_path.."\\__dev\\writer_request.lua")
  local original_store=song.tool_data
  local original_instrument_name=instrument.name
  local original_snapshot=ownership.snapshot
  local original_copy_snapshot=ownership.copy_snapshot
  local original_compare=ownership.compare
  local original_matches_snapshot=ownership.matches_snapshot
  local original_classify=validator.classify
  local original_classify_against=validator.classify_against
  local captured_column_name
  local capture_calls,sink_calls=0,0
  local metrics={}
  local scans=0
  local scans_snapshot_wrapper
  local profile={}
  local phrase_profile={}
  local phrase_profile_enabled=false
  local phrase_profile_restore={}
  local gui_open=false
  local gui_draft_seeded=false
  local original_view_builder
  local original_app_factory
  local captured_test_dialog
  local gui_context_module,original_gui_context_new,gui_context,gui_transition_context
  local gui_live_trace_enabled=false
  local gui_live_trace={}
  local gui_observer_event_trace={}
  local gui_inventory_match_trace={}
  local gui_context_created_count=0
  local gui_live_request_trace={}
  local gui_transition_result,gui_transition_error
  local gui_transition_kind,gui_transition_effects
  local profile_names={"snapshot","copy_snapshot","compare","classify","classify_against","matches_snapshot"}
  local function reset_profile()
    for _,name in ipairs(profile_names) do profile[name]={calls=0,elapsed_ms=0} end
  end
  reset_profile()
  local phrase
  local context
  local observer
  local function close_test_gui()
    local dialog_closed=true
    if original_view_builder then
      pcall(function() renoise.ViewBuilder=original_view_builder end)
      original_view_builder=nil
    end
    if original_app_factory then
      pcall(function() renoise.app=original_app_factory end)
      original_app_factory=nil
    end
    if captured_test_dialog then
      local dialog=captured_test_dialog
      captured_test_dialog=nil
      local ok,visible=pcall(function()
        if dialog.visible then dialog:close() end
        return dialog.visible
      end)
      dialog_closed=ok and visible==false
    end
    if gui_open then
      gui_open=false
      if gui_context and type(gui_context.close_dialog)=="function" then
        pcall(function() gui_context:close_dialog() end)
      end
    end
    return dialog_closed
  end
  local function cleanup()
    close_test_gui()
    if gui_context_module and original_gui_context_new then
      pcall(function() gui_context_module.new=original_gui_context_new end)
      gui_context_module=nil
      original_gui_context_new=nil
    end
    for index=#phrase_profile_restore,1,-1 do
      local wrapped=phrase_profile_restore[index]
      pcall(function() wrapped.target[wrapped.key]=wrapped.original end)
      phrase_profile_restore[index]=nil
    end
    if observer then pcall(function() observer:detach() end) end
    if context then pcall(function() context:release_document() end) end
    if original_instrument_name then pcall(function() instrument.name=original_instrument_name end) end
    if gui_draft_seeded then
      pcall(function() require("runtime.draft_cache").clear(song,instrument,phrase) end)
      gui_draft_seeded=false
    end
    ownership.snapshot=original_snapshot
    ownership.copy_snapshot=original_copy_snapshot
    ownership.compare=original_compare
    ownership.matches_snapshot=original_matches_snapshot
    validator.classify=original_classify
    validator.classify_against=original_classify_against
    if phrase then
      for index,item in ipairs(instrument.phrases) do
        if rawequal(item,phrase) then
          pcall(function() instrument:delete_phrase_at(index) end)
          break
        end
      end
    end
    pcall(function() song.tool_data=original_store end)
  end
  local function fail(reason)
    local result={status="FAIL",case="editor-responsiveness",reason=tostring(reason)}
    for key,value in pairs(metrics) do result[key]=value end
    cleanup()
    done(result)
  end
  local function measure_gui_callbacks()
    local callbacks,controls,callback_counts,action_memory_kb={},{},{},{}
    local suppress_captured_notifiers=false
    local anonymous_checkbox_index,anonymous_pitch_page,anonymous_time_page=0,0,0
    local key_items={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B","C+"}
    local octave_items={"DOWN (-1)","NORMAL (0)","UP (+1)"}
    local function profile_function(target,key,name)
      if type(target)~="table" or type(target[key])~="function" then return end
      local original=target[key]
      phrase_profile_restore[#phrase_profile_restore+1]={target=target,key=key,original=original}
      target[key]=function(...)
        local started=os.clock()
        local values=pack_values(original(...))
        if phrase_profile_enabled then
          local item=phrase_profile[name] or {calls=0,elapsed_ms=0}
          item.calls=item.calls+1
          item.elapsed_ms=item.elapsed_ms+(os.clock()-started)*1000
          phrase_profile[name]=item
        end
        return unpack_values(values,1,values.n)
      end
    end
    local function reset_phrase_profile()
      phrase_profile={}
    end
    local function publish_phrase_profile(prefix)
      for _,name in ipairs({"snapshot","copy_snapshot","compare","classify","classify_against",
          "plan","restore_editor_target","transition","render_project","render_step_text",
          "request_new","request_capture","request_checkpoint","writer_create","writer_regenerate"}) do
        local item=phrase_profile[name] or {calls=0,elapsed_ms=0}
        metrics[prefix.."_"..name.."_calls"]=item.calls
        metrics[prefix.."_"..name.."_elapsed_ms"]=item.elapsed_ms
      end
    end
    local planner=require("model.output_planner")
    local request_module=require("runtime.requests")
    local original_requests_new=request_module.new
    request_module.new=function(access)
      local owner=original_requests_new(access)
      profile_function(owner,"capture","request_capture")
      profile_function(owner,"validate_checkpoint","request_checkpoint")
      return owner
    end
    phrase_profile_restore[#phrase_profile_restore+1]={target=request_module,key="new",original=original_requests_new}
    profile_function(writer,"create","writer_create")
    profile_function(writer,"regenerate","writer_regenerate")
    profile_function(request_module,"new","request_new")
    profile_function(ownership,"snapshot","snapshot")
    profile_function(ownership,"copy_snapshot","copy_snapshot")
    profile_function(ownership,"compare","compare")
    profile_function(validator,"classify","classify")
    profile_function(validator,"classify_against","classify_against")
    profile_function(planner,"plan","plan")
    profile_function(editor,"project","render_project")
    profile_function(editor,"step_text","render_step_text")
    local function same_items(actual,expected)
      if type(actual)~="table" or #actual~=#expected then return false end
      for index,value in ipairs(expected) do if actual[index]~=value then return false end end
      return true
    end
    local function control_alias(name,properties)
      if not properties then return nil end
      if properties.id then return properties.id end
      if name=="multiline_textfield" and properties.width==820 then return "acid_responsiveness_status" end
      if name=="valuebox" then return "acid_last_step" end
      if name=="popup" then
        if properties.width==290 then return "acid_instrument_choice" end
        if properties.width==360 then return "acid_phrase_choice" end
        local items=properties.items
        if type(items)=="table" then
          if #items==32 and items[1]=="1" then return "acid_pitch_length" end
          if same_items(items,{"Play Once","Repeat"}) then return "acid_playback" end
          if same_items(items,{"Start","Repeating"}) then return "acid_preview" end
          if same_items(items,key_items) then return "acid_grid_key" end
          if same_items(items,octave_items) then return "acid_grid_octave" end
        end
      elseif name=="checkbox" then
        anonymous_checkbox_index=anonymous_checkbox_index+1
        if anonymous_checkbox_index==1 then return "acid_grid_accent" end
        if anonymous_checkbox_index==2 then return "acid_grid_slide" end
        if anonymous_checkbox_index==3 then return "acid_live_edit" end
      elseif name=="button" then
        if properties.text=="Undo" then return "acid_undo" end
        if properties.text=="Redo" then return "acid_redo" end
        if properties.text=="Reset Source" then return "acid_reset_source" end
        if properties.text=="Previous TIME" then return "acid_previous_time" end
        if properties.text=="Next TIME" then return "acid_next_time" end
        if properties.text=="Retry Live Edit" then return "acid_retry_live" end
        if properties.text=="Generate / Regenerate ACID Phrase" then return "acid_generate" end
        if properties.text=="P" then
          anonymous_pitch_page=anonymous_pitch_page+1
          return "acid_pitch_page_"..tostring(anonymous_pitch_page)
        end
        if properties.text=="T" then
          anonymous_time_page=anonymous_time_page+1
          return "acid_time_page_"..tostring(anonymous_time_page)
        end
      end
      return nil
    end
    local function tracked_callback(id,notifier)
      local callback=function(...)
        callback_counts[id]=(callback_counts[id] or 0)+1
        if suppress_captured_notifiers then return end
        return notifier(...)
      end
      callbacks[id]=callback
      return callback
    end
    local function track_added_notifiers(view,id)
      local original_add_notifier
      local ok=pcall(function()
        original_add_notifier=view.add_notifier
        if type(original_add_notifier)~="function" then return end
        view.add_notifier=function(self,notifier)
          return original_add_notifier(view,tracked_callback(id,notifier))
        end
      end)
      return ok and type(original_add_notifier)=="function"
    end
    local generated_phrase_index
    for index,item in ipairs(instrument.phrases) do
      if rawequal(item,phrase) then generated_phrase_index=index;break end
    end
    if not generated_phrase_index then return nil,"generated phrase is not in the selected instrument" end
    gui_context_module=require("runtime.context")
    original_gui_context_new=gui_context_module.new
    gui_context_module.new=function(options)
      gui_context_created_count=gui_context_created_count+1
      gui_context=original_gui_context_new(options)
      local original_inventory_match=gui_context.matches_mutation_inventory
      if type(original_inventory_match)=="function" then
        gui_context.matches_mutation_inventory=function(self,subject,inventory_kind)
          local called,matches,match_reason=pcall(original_inventory_match,self,subject,inventory_kind)
          if gui_live_trace_enabled and #gui_inventory_match_trace<80 then
            gui_inventory_match_trace[#gui_inventory_match_trace+1]=table.concat({
              "kind="..tostring(inventory_kind),
              "subject_instrument="..tostring(rawequal(subject,instrument)),
              "same_context="..tostring(rawequal(self,gui_context)),
              "called="..tostring(called),"matches="..tostring(matches),
              "reason="..tostring(match_reason or (not called and matches) or "")
            },",")
            metrics.gui_inventory_match_trace=table.concat(gui_inventory_match_trace,";")
          end
          if not called then error(matches,0) end
          return matches,match_reason
        end
      end
      profile_function(gui_context,"restore_editor_target","restore_editor_target")
      local original_request_generation=gui_context.request_generation
      gui_context.request_generation=function(self,trigger,...)
        local tracked=gui_live_trace_enabled and trigger=="live"
        local attempt
        if tracked then
          attempt=#gui_live_request_trace+1
          reset_phrase_profile()
          phrase_profile_enabled=true
        end
        local called,accepted,reason=pcall(original_request_generation,self,trigger,...)
        if tracked then
          phrase_profile_enabled=false
          publish_phrase_profile("gui_live_request_"..tostring(attempt).."_profile")
          local state=self:generation_state()
          gui_live_request_trace[#gui_live_request_trace+1]=table.concat({
            "attempt="..tostring(attempt),"accepted="..tostring(accepted),
            "reason="..tostring(reason or ""),"status="..tostring(state.status),
            "pending="..tostring(state.pending),"writer="..tostring(writer.state())
          },",")
          metrics.gui_live_request_trace=table.concat(gui_live_request_trace,";")
        end
        if not called then error(accepted,0) end
        return accepted,reason
      end
      for _,method_name in ipairs({"flush_pending","close_dialog","release_document","attach_document",
          "open_dialog","reconcile","refresh_inventory","mark_dirty"}) do
        local original_method=gui_context[method_name]
        if type(original_method)=="function" then
          gui_context[method_name]=function(self,...)
            local method_argument=select(1,...)
            local before_generation,before_lifecycle
            if gui_live_trace_enabled then
              pcall(function() before_generation=self:generation_state() end)
              pcall(function() before_lifecycle=self:lifetime_state() end)
            end
            local values=pack_values(pcall(original_method,self,...))
            if gui_live_trace_enabled then
              local after_generation,after_lifecycle
              pcall(function() after_generation=self:generation_state() end)
              pcall(function() after_lifecycle=self:lifetime_state() end)
              if #gui_live_trace<40 then
                gui_live_trace[#gui_live_trace+1]=table.concat({
                  "method="..method_name,
                  "b="..tostring(before_generation and before_generation.status).."/"..
                    tostring(before_generation and before_generation.pending),
                  "a="..tostring(after_generation and after_generation.status).."/"..
                    tostring(after_generation and after_generation.pending),
                  "life="..tostring(before_lifecycle and before_lifecycle.epoch).."/"..
                    tostring(before_lifecycle and before_lifecycle.session).."/"..
                    tostring(before_lifecycle and before_lifecycle.open).."->"..
                    tostring(after_lifecycle and after_lifecycle.epoch).."/"..
                    tostring(after_lifecycle and after_lifecycle.session).."/"..
                    tostring(after_lifecycle and after_lifecycle.open),
                  "arg="..tostring(method_argument or ""),
                  "error="..tostring(not values[1] and values[2] or "")
                },",")
                metrics.gui_live_lifecycle_trace=table.concat(gui_live_trace,";")
              end
            end
            if not values[1] then error(values[2],0) end
            return unpack_values(values,2,values.n)
          end
        end
      end
      local original_transition=gui_context.transition
      gui_context.transition=function(self,...)
        local kind=select(1,...)
        gui_transition_context=self
        local before
        if gui_live_trace_enabled then before=self:generation_state() end
        local transition_values=select(2,...)
        local prior_projection
        if gui_live_trace_enabled and kind=="native_target" then
          pcall(function() prior_projection=self:target_projection() end)
        end
        local started=phrase_profile_enabled and os.clock() or nil
        local values={pcall(original_transition,self,...)}
        gui_transition_kind=kind
        gui_transition_effects=values[1] and values[3] or nil
        if gui_live_trace_enabled and #gui_live_trace<40 then
          local after=self:generation_state()
          local effects=gui_transition_effects
          local parts={
            tostring(kind),"b="..tostring(before and before.status).."/"..tostring(before and before.pending),
            "a="..tostring(after.status).."/"..tostring(after.pending),
            "intent="..tostring(effects and effects.live_intent),
            "accepted="..tostring(effects and effects.accepted),
            "reason="..tostring(effects and effects.reason or "")
          }
          if kind=="native_target" then
            local function object_index(list,object)
              if not list or not object then return 0 end
              for index,item in ipairs(list) do if rawequal(item,object) then return index end end
              return 0
            end
            local request_instrument=type(transition_values)=="table" and transition_values.instrument or nil
            local request_phrase=type(transition_values)=="table" and transition_values.phrase or nil
            local selected_instrument=song.selected_instrument
            local selected_phrase=song.selected_phrase
            local request_phrase_index=object_index(request_instrument and request_instrument.phrases,request_phrase)
            local selected_phrase_index=object_index(selected_instrument and selected_instrument.phrases,selected_phrase)
            local before_phrase=prior_projection and prior_projection.phrase
            local function safe_name(object)
              local ok,name=pcall(function() return object and object.name end)
              return ok and tostring(name) or "?"
            end
            metrics.gui_live_native_target_trace=table.concat({
              "requested_instrument="..tostring(object_index(song.instruments,request_instrument)),
              "requested_phrase="..tostring(request_phrase_index),
              "requested_is_generated="..tostring(rawequal(request_phrase,phrase)),
              "requested_name="..safe_name(request_phrase),
              "selected_instrument="..tostring(song.selected_instrument_index),
              "selected_phrase="..tostring(selected_phrase_index),
              "selected_is_requested="..tostring(rawequal(selected_phrase,request_phrase)),
              "selected_name="..safe_name(selected_phrase),
              "prior_target_kind="..tostring(prior_projection and prior_projection.kind),
              "prior_phrase_is_generated="..tostring(rawequal(before_phrase,phrase))
            },",")
            parts[#parts+1]=metrics.gui_live_native_target_trace
          end
          gui_live_trace[#gui_live_trace+1]=table.concat(parts,",")
        end
        if started then
          local item=phrase_profile.transition or {calls=0,elapsed_ms=0}
          item.calls=item.calls+1
          item.elapsed_ms=item.elapsed_ms+(os.clock()-started)*1000
          phrase_profile.transition=item
        end
        if values[1] then
          gui_transition_result,gui_transition_error=values[2],values[3]
          return values[2],values[3]
        end
        gui_transition_result=nil
        gui_transition_error=values[2]
        error(values[2])
      end
      return gui_context
    end
    original_view_builder=renoise.ViewBuilder
    local builder_factory=original_view_builder
    local wrapped,wrap_error=pcall(function() renoise.ViewBuilder=function(...)
      local builder=builder_factory(...)
      return setmetatable({}, {__index=function(_,name)
        local constructor=builder[name]
        if type(constructor)~="function" then return constructor end
        return function(_,properties,...)
          local properties_table=type(properties)=="table" and properties or nil
          local id=properties_table and properties_table.id
          local alias=control_alias(name,properties_table)
          local original_notifier=properties_table and properties_table.notifier
          if properties_table and type(properties_table.notifier)=="function" then
            if alias then
              properties_table.notifier=tracked_callback(alias,properties_table.notifier)
            end
            if name=="popup" and properties_table.width==360 and
                type(properties_table.items)=="table" then
              for index,item in ipairs(properties_table.items) do
                if item:match("^%d%d:") and tonumber(item:match("^(%d%d):"))==generated_phrase_index then
                  controls.acid_responsiveness_phrase_choice_index=index
                elseif item=="NEW PHRASE (append)" then
                  controls.acid_new_phrase_choice_index=index
                end
              end
            end
          end
          local view=constructor(builder,properties,...)
          if properties_table and original_notifier then properties_table.notifier=original_notifier end
          if id then controls[id]=view end
          if alias then controls[alias]=view end
          if alias then track_added_notifiers(view,alias) end
          if name=="popup" and properties_table and properties_table.width==360 and
              type(properties_table.items)=="table" and properties_table.notifier then
            controls.acid_responsiveness_phrase_choice=view
          end
          return view
        end
      end})
    end end)
    if not wrapped then
      original_view_builder=nil
      return nil,"GUI test view capture could not wrap ViewBuilder: "..tostring(wrap_error)
    end
    original_app_factory=renoise.app
    local app_factory=original_app_factory
    local app_wrapped,app_wrap_error=pcall(function()
      renoise.app=function(...)
        local app=app_factory(...)
        return setmetatable({}, {__index=function(_,name)
          local member=app[name]
          if name=="show_custom_dialog" and type(member)=="function" then
            return function(_, ...)
              captured_test_dialog=member(app,...)
              return captured_test_dialog
            end
          end
          if type(member)=="function" then
            return function(_, ...) return member(app,...) end
          end
          return member
        end})
      end
    end)
    if not app_wrapped then
      pcall(function() renoise.ViewBuilder=builder_factory end)
      pcall(function() renoise.app=app_factory end)
      original_view_builder=nil
      original_app_factory=nil
      return nil,"GUI test dialog capture could not wrap renoise.app: "..tostring(app_wrap_error)
    end
    local observer_module=require("runtime.observers")
    local original_observer_new=observer_module.new
    local cached_gui_module=package.loaded["gui"]
    observer_module.new=function(...)
      local observer=original_observer_new(...)
      local original_attach=observer.attach
      observer.attach=function(self,current_song,current_runtime,callback)
        local observed_callback=callback
        if type(callback)=="function" then
          observed_callback=function(kind,subject,internal,inventory_kind)
            if gui_live_trace_enabled and #gui_observer_event_trace<80 then
              local subject_name="?"
              pcall(function() subject_name=tostring(subject and subject.name or "") end)
              local temporary=false
              if current_runtime and type(current_runtime.is_temporary)=="function" then
                local ok,value=pcall(current_runtime.is_temporary,current_runtime,instrument,subject)
                temporary=ok and value==true
              end
              local occupancy="?"
              if current_runtime and type(current_runtime.occupancy_state)=="function" then
                local ok,value=pcall(current_runtime.occupancy_state,current_runtime)
                occupancy=ok and tostring(value and value.status or "?") or "?"
              end
              local mutation_depth="?"
              if current_runtime and type(current_runtime.mutation_state)=="function" then
                local ok,value=pcall(current_runtime.mutation_state,current_runtime)
                mutation_depth=ok and tostring(value and value.depth or "?") or "?"
              end
              gui_observer_event_trace[#gui_observer_event_trace+1]=table.concat({
                tostring(kind),"subject="..subject_name,
                "generated="..tostring(rawequal(subject,phrase)),
                "instrument="..tostring(rawequal(subject,instrument)),
                "temporary="..tostring(temporary),"internal="..tostring(internal),
                "writer="..occupancy,"mutation="..mutation_depth,
                "inventory_kind="..tostring(inventory_kind),
                "matches_method="..tostring(type(current_runtime and current_runtime.matches_mutation_inventory)=="function")
              },",")
              metrics.gui_observer_event_trace=table.concat(gui_observer_event_trace,";")
            end
            return callback(kind,subject,internal,inventory_kind)
          end
        end
        return original_attach(self,current_song,current_runtime,observed_callback)
      end
      return observer
    end
    package.loaded["gui"]=nil
    local shown,show_error=pcall(function() require("gui").show() end)
    package.loaded["gui"]=cached_gui_module
    observer_module.new=original_observer_new
    pcall(function() renoise.ViewBuilder=builder_factory end)
    original_view_builder=nil
    pcall(function() renoise.app=app_factory end)
    original_app_factory=nil
    if gui_context_module and original_gui_context_new then
      gui_context_module.new=original_gui_context_new
      gui_context_module=nil
      original_gui_context_new=nil
    end
    if not shown then return nil,"GUI construction failed: "..tostring(show_error) end
    gui_open=true
    if not captured_test_dialog then
      close_test_gui()
      return nil,"GUI did not expose its native dialog for teardown"
    end
    local instrument_control=controls.acid_instrument_choice
    local instrument_notifier=callbacks.acid_instrument_choice
    local instrument_choice_index
    if instrument_control and type(instrument_control.items)=="table" then
      local expected_prefix=string.format("%02X:",instrument_index-1)
      for index,item in ipairs(instrument_control.items) do
        if type(item)=="string" and item:sub(1,#expected_prefix)==expected_prefix then
          instrument_choice_index=index
          break
        end
      end
    end
    if not instrument_choice_index or type(instrument_notifier)~="function" then
      close_test_gui()
      return nil,"GUI did not expose the generated phrase instrument choice"
    end
    local instrument_select_started=os.clock()
    local instrument_dispatch_before=callback_counts.acid_instrument_choice or 0
    instrument_control.value=instrument_choice_index
    if (callback_counts.acid_instrument_choice or 0)==instrument_dispatch_before then
      instrument_notifier(instrument_choice_index)
    end
    metrics.gui_instrument_selection_elapsed_ms=(os.clock()-instrument_select_started)*1000
    local phrase_notifier=callbacks.acid_phrase_choice
    local phrase_index
    local actual_phrase_control=controls.acid_phrase_choice
    if actual_phrase_control and type(actual_phrase_control.items)=="table" then
      for index,item in ipairs(actual_phrase_control.items) do
        if type(item)=="string" and item:match("^(%d%d):") and
            tonumber(item:match("^(%d%d):"))==generated_phrase_index then
          phrase_index=index
          break
        end
      end
    end
    if type(phrase_notifier)~="function" or not phrase_index then
      close_test_gui()
      return nil,"GUI phrase selector did not expose the generated phrase callback"
    end
    local phrase_select_started=os.clock()
    reset_phrase_profile()
    phrase_profile_enabled=true
    local phrase_control=actual_phrase_control
    local phrase_dispatch_before=callback_counts.acid_phrase_choice or 0
    if phrase_control then phrase_control.value=phrase_index end
    if (callback_counts.acid_phrase_choice or 0)==phrase_dispatch_before then
      phrase_notifier(phrase_index)
    end
    phrase_profile_enabled=false
    metrics.gui_phrase_selection_elapsed_ms=(os.clock()-phrase_select_started)*1000
    publish_phrase_profile("gui_phrase_initial_profile")
    local time_position_notifier=callbacks.acid_program_time_position
    if type(time_position_notifier)~="function" then
      close_test_gui()
      return nil,"GUI TIME position callback was not captured from the real control"
    end
    local time_position_control=controls.acid_program_time_position
    local time_dispatch_before=callback_counts.acid_program_time_position or 0
    if time_position_control then time_position_control.value=2 end
    if (callback_counts.acid_program_time_position or 0)==time_dispatch_before then
      time_position_notifier(2)
    end
    metrics.gui_time_position_selection_verified=true
    local pitch_position_notifier=callbacks.acid_program_pitch_position
    if type(pitch_position_notifier)~="function" then
      close_test_gui()
      return nil,"GUI PITCH position callback was not captured from the real control"
    end
    local pitch_position_control=controls.acid_program_pitch_position
    local pitch_dispatch_before=callback_counts.acid_program_pitch_position or 0
    if pitch_position_control then pitch_position_control.value=1 end
    if (callback_counts.acid_program_pitch_position or 0)==pitch_dispatch_before then
      pitch_position_notifier(1)
    end
    local key_notifier=callbacks.acid_program_key_popup
    local octave_notifier=callbacks.acid_program_octave_popup
    local command_notifier=callbacks.acid_program_time_command
    if type(key_notifier)~="function" or type(octave_notifier)~="function" or
        type(command_notifier)~="function" then
      close_test_gui()
      return nil,"GUI note/octave/command callback was not captured from the real controls"
    end
    local drafts=require("runtime.draft_cache")
    local persisted=require("renoise.pattern_store")
    local stored,stored_policy,stored_pb=drafts.get(song,instrument,phrase)
    if not stored or stored.length~=32 then
      close_test_gui()
      return nil,"GUI callback target did not load the representative 32-step phrase"
    end
    local original_note=phrase:line(1):note_column(1).note_value
    local samples={note={},octave={},command={}}
    local note_pitch_index=tonumber(controls.acid_program_pitch_position.value) or 1
    if note_pitch_index<1 or note_pitch_index>stored.length then
      close_test_gui()
      return nil,"GUI Program PITCH selection is outside the generated source"
    end
    metrics.gui_program_pitch_position_before_note=note_pitch_index
    local last_saved_source=stored
    local last_saved_policy,last_saved_pb=stored_policy,stored_pb
    local current_key=stored.pitch_events[note_pitch_index].key
    local current_octave=stored.pitch_events[note_pitch_index].octave
    local current_command=stored.time_events[2]
    local function invoke(kind,callback_id,notifier,value,check)
      local memory_before=collectgarbage("count")
      local started=os.clock()
      local control=controls[callback_id]
      suppress_captured_notifiers=true
      if control then control.value=value end
      suppress_captured_notifiers=false
      local dispatch_elapsed=(os.clock()-started)*1000
      if control then
        local callback_started=os.clock()
        notifier(value)
        dispatch_elapsed=dispatch_elapsed+(os.clock()-callback_started)*1000
      end
      metrics["gui_last_"..kind.."_callback_elapsed_ms"]=dispatch_elapsed
      local elapsed=(os.clock()-started)*1000
      metrics["gui_last_"..kind.."_callback_memory_delta_kb"]=collectgarbage("count")-memory_before
      samples[kind][#samples[kind]+1]=elapsed
      local updated,draft_policy,draft_pb=persisted.read_draft(song,instrument,phrase)
      if not updated or sequence.same_source(last_saved_source,updated) then
        metrics["gui_"..kind.."_draft_key_after"]=updated and updated.pitch_events[note_pitch_index].key or -1
        metrics["gui_"..kind.."_control_value_after"]=control and control.value or -1
        metrics["gui_"..kind.."_pitch_selection_after"]=controls.acid_program_pitch_position.value
        metrics["gui_"..kind.."_time_selection_after"]=controls.acid_program_time_position.value
        metrics["gui_"..kind.."_phrase_choice_after"]=controls.acid_phrase_choice.value
        metrics["gui_"..kind.."_instrument_choice_after"]=controls.acid_instrument_choice.value
        metrics["gui_"..kind.."_instrument_native_index_after"]=song.selected_instrument_index
        metrics["gui_"..kind.."_instrument_native_matches"]=rawequal(song.selected_instrument,instrument)
        local status=controls.acid_responsiveness_status
        metrics["gui_"..kind.."_status_after"]=status and tostring(status.text):sub(1,240) or "unavailable"
        local source_state=controls.acid_source_state
        metrics["gui_"..kind.."_source_state_after"]=source_state and tostring(source_state.text):sub(1,120) or "unavailable"
        metrics["gui_"..kind.."_transition_result"]=gui_transition_result==nil and "nil" or "returned"
        metrics["gui_"..kind.."_transition_error"]=tostring(gui_transition_error or "")
        if gui_context then
          local state_ok,state=pcall(function() return gui_context:editor_state() end)
          if state_ok and state then
            metrics["gui_"..kind.."_context_draft_warning"]=tostring(state.draft_warning or "")
            metrics["gui_"..kind.."_context_target_kind"]=tostring(state.target_kind or state.kind or "")
          end
        end
        return nil,"GUI "..kind.." callback did not persist a changed draft: "..
          tostring(draft_policy).."; callback_ms="..string.format("%.2f",elapsed)..
          "; dispatches="..tostring(callback_counts[callback_id] or 0)
      end
      last_saved_source,last_saved_policy,last_saved_pb=updated,draft_policy,draft_pb
      local valid,reason=check(updated)
      if not valid then return nil,reason end
      return true
    end
    local action_timings={}
    action_timings["instrument-target"]=metrics.gui_instrument_selection_elapsed_ms
    local function record_action(name,elapsed,memory_delta_kb)
      metrics["gui_action_"..name.."_elapsed_ms"]=elapsed
      if memory_delta_kb~=nil then
        action_memory_kb[name]=memory_delta_kb
        metrics["gui_action_"..name.."_memory_delta_kb"]=memory_delta_kb
      end
      action_timings[name]=elapsed
    end
    local function value_action(name,alias,value,target_phrase,check,save_required)
      local control=controls[alias]
      if not control then return nil,"GUI control was not captured: "..alias end
      local memory_before=collectgarbage("count")
      local started=os.clock()
      suppress_captured_notifiers=true
      control.value=value
      suppress_captured_notifiers=false
      if callbacks[alias] then
        callbacks[alias](value)
      end
      local elapsed=(os.clock()-started)*1000
      local memory_delta_kb=collectgarbage("count")-memory_before
      record_action(name,elapsed,memory_delta_kb)
      local updated,policy,pb=persisted.read_draft(song,instrument,target_phrase)
      if save_required and not updated then
        return nil,"GUI "..name.." action did not persist its source change: "..tostring(policy)
      end
      if save_required and target_phrase and sequence.same_source(last_saved_source,updated) and
          policy==last_saved_policy and pb==last_saved_pb then
        return nil,"GUI "..name.." action did not change its persisted source or settings"
      end
      if check then
        local valid,reason=check(updated,policy,pb)
        if not valid then return nil,reason end
      end
      if save_required and target_phrase then
        last_saved_source,last_saved_policy,last_saved_pb=updated,policy,pb
      end
      return true,updated,policy,pb
    end
    local function button_action(name,alias,check)
      local callback=callbacks[alias]
      if type(callback)~="function" then return nil,"GUI button callback was not captured: "..alias end
      local memory_before=collectgarbage("count")
      local started=os.clock()
      callback()
      local elapsed=(os.clock()-started)*1000
      local memory_delta_kb=collectgarbage("count")-memory_before
      record_action(name,elapsed,memory_delta_kb)
      if check then
        local valid,reason=check()
        if not valid then return nil,reason end
      end
      return true
    end
    local first_key_value=(stored.pitch_events[1].key+1)%12+1
    local key_values={first_key_value,first_key_value%12+1,(first_key_value+1)%12+1}
    for index,value in ipairs(key_values) do
      local ok,reason=invoke("note","acid_program_key_popup",key_notifier,value,function(updated)
        current_key=value-1
        if updated.pitch_events[note_pitch_index].key~=current_key then
          return false,"GUI note callback did not update the source pitch"
        end
        if controls.acid_program_key_popup.value~=value then
          return false,"GUI note callback did not refresh the key control"
        end
        return true
      end)
      if not ok then close_test_gui();return nil,reason end
    end
    local octave_values={current_octave==0 and 3 or 2,1,3}
    for _,value in ipairs(octave_values) do
      local ok,reason=invoke("octave","acid_program_octave_popup",octave_notifier,value,function(updated)
        current_octave=value-2
        if updated.pitch_events[note_pitch_index].octave~=current_octave then
          return false,"GUI octave callback did not update the source pitch"
        end
        if controls.acid_program_octave_popup.value~=value then
          return false,"GUI octave callback did not refresh the octave control"
        end
        return true
      end)
      if not ok then close_test_gui();return nil,reason end
    end
    suppress_captured_notifiers=true
    controls.acid_program_time_position.value=2
    suppress_captured_notifiers=false
    time_position_notifier(2)
    current_command=last_saved_source.time_events[2]
    local first_command_value=({N=1,T=2,R=3})[current_command]%3+1
    local command_values={first_command_value,first_command_value%3+1,(first_command_value+1)%3+1}
    for _,value in ipairs(command_values) do
      local expected=({"N","T","R"})[value]
      local ok,reason=invoke("command","acid_program_time_command",command_notifier,value,function(updated)
        current_command=expected
        if updated.time_events[2]~=current_command then
          return false,"GUI command callback did not update the source timing"
        end
        if controls.acid_program_time_command.value~=value then
          return false,"GUI command callback did not refresh the command control"
        end
        return true
      end)
      if not ok then close_test_gui();return nil,reason end
    end
    local actions={}
    local function run_value(name,alias,value,target_phrase,check,save_required)
      local ok,reason=value_action(name,alias,value,target_phrase,check,save_required)
      if not ok then close_test_gui();return nil,reason end
      actions[#actions+1]=name
      return true,reason
    end
    local function run_button(name,alias,check)
      local ok,reason=button_action(name,alias,check)
      if not ok then close_test_gui();return nil,reason end
      actions[#actions+1]=name
      return true,reason
    end
    local stored_now,stored_policy,stored_pb=persisted.read_draft(song,instrument,phrase)
    if not stored_now then close_test_gui();return nil,"GUI draft unavailable before settings benchmark: "..tostring(stored_policy) end
    local settings_actions={
      {"last-step","acid_last_step",31,function(updated)return updated.length==31,"LAST STEP did not update the source length" end},
      {"timing-mode","acid_timing",2,function(updated)return updated.timing_mode=="triplet","Timing control did not update source timing" end},
      {"pitch-length","acid_pitch_length",17,function(updated)return updated.pitch_length==17,"PITCH span did not update source pitch length" end},
      {"output-policy","acid_playback",2,function(updated,policy)return policy=="repeat","Output policy did not update the saved draft" end},
      {"pb-range","acid_pb_range",2,function(updated,policy,pb)
        return pb==require("model.policies").PB_CHOICES[2],"PB Range did not update the saved draft"
      end}
    }
    for _,action in ipairs(settings_actions) do
      local ok,reason=run_value(action[1],action[2],action[3],phrase,action[4],true)
      if not ok then return nil,reason end
    end
    local navigation_actions={
      {"pitch-position","acid_program_pitch_position",2},
      {"time-position","acid_program_time_position",3},
      {"preview-mode","acid_preview",2}
    }
    for _,action in ipairs(navigation_actions) do
      local ok,reason=run_value(action[1],action[2],action[3],phrase,function()
        if controls[action[2]].value~=action[3] then return false,"GUI control did not retain the selected value" end
        return true
      end,false)
      if not ok then return nil,reason end
    end
    local grid_ok,grid_error=run_value("grid-view","acid_editor_view",2,phrase,function()
      return controls.acid_grid_panel.visible==true,"Grid view did not update panel visibility"
    end,false)
    if not grid_ok then return nil,grid_error end
    local time_page_one_ok,time_page_one_error=run_button("time-page-1","acid_time_page_1")
    if not time_page_one_ok then return nil,time_page_one_error end
    local grid_pitch_index=tonumber(controls.acid_program_pitch_position.value) or 1
    local grid_pitch_value=(last_saved_source.pitch_events[grid_pitch_index].key+1)%12+1
    local grid_actions={
      {"grid-key","acid_grid_key",grid_pitch_value,function(updated)return updated.pitch_events[grid_pitch_index].key==grid_pitch_value-1,"Grid key did not update the selected source pitch" end},
      {"grid-octave","acid_grid_octave",3,function(updated)return updated.pitch_events[grid_pitch_index].octave==1,"Grid octave did not update the selected source pitch" end},
      {"grid-accent","acid_grid_accent",false,function(updated)return updated.pitch_events[grid_pitch_index].accent==false,"Grid accent did not update the selected source pitch" end},
      {"grid-slide","acid_grid_slide",true,function(updated)return updated.pitch_events[grid_pitch_index].slide==true,"Grid slide did not update the selected source pitch" end},
      {"grid-time-command","acid_grid_time_02",2,function(updated)return updated.time_events[2]=="T","Grid TIME cell did not update source command" end}
    }
    for _,action in ipairs(grid_actions) do
      local profile_grid_key=action[1]=="grid-key"
      if profile_grid_key then reset_phrase_profile();phrase_profile_enabled=true end
      local ok,reason=run_value(action[1],action[2],action[3],phrase,action[4],true)
      if profile_grid_key then
        phrase_profile_enabled=false
        publish_phrase_profile("gui_grid_key_profile")
      end
      if not ok then return nil,reason end
    end
    local page_ok,page_error=run_button("pitch-page-2","acid_pitch_page_2",function()
      return controls.acid_pitch_page_2.text:find("17-32",1,true)~=nil,"PITCH page navigation did not update the page label"
    end)
    if not page_ok then return nil,page_error end
    local time_page_ok,time_page_error=run_button("time-page-2","acid_time_page_2",function()
      return controls.acid_time_page_2.text:find("17-32",1,true)~=nil,"TIME page navigation did not update the page label"
    end)
    if not time_page_ok then return nil,time_page_error end
    local grid_pitch_ok,grid_pitch_error=run_button("grid-pitch-cell","acid_grid_pitch_02")
    if not grid_pitch_ok then return nil,grid_pitch_error end
    local program_view_ok,program_view_error=run_value("program-view","acid_editor_view",1,phrase,function()
      return controls.acid_program_panel.visible==true,"Program view did not update panel visibility"
    end,false)
    if not program_view_ok then return nil,program_view_error end
    local pitch_page_reselect_ok,pitch_page_reselect_error=run_value(
      "program-pitch-reselection","acid_program_pitch_position",18,phrase,function()
        return controls.acid_program_pitch_position.value==18,"Grid pitch selection was not reflected in Program view"
      end,false)
    if not pitch_page_reselect_ok then return nil,pitch_page_reselect_error end
    local undo_ok,undo_error=run_button("undo","acid_undo")
    if not undo_ok then return nil,undo_error end
    local redo_ok,redo_error=run_button("redo","acid_redo")
    if not redo_ok then return nil,redo_error end
    local reset_ok,reset_error=run_button("reset-source","acid_reset_source",function()
      local reset_source=persisted.read_draft(song,instrument,phrase)
      return reset_source~=nil,"Reset Source did not save a new draft revision"
    end)
    if not reset_ok then return nil,reset_error end
    local phrase_choice_ok,phrase_choice_error=run_value("new-phrase-target","acid_phrase_choice",
      controls.acid_new_phrase_choice_index,nil,function()
        return controls.acid_phrase_choice.value==controls.acid_new_phrase_choice_index,
          "New Phrase target was not selected"
      end,false)
    if not phrase_choice_ok then return nil,phrase_choice_error end
    local new_phrase_ok,new_phrase_error=run_value("new-phrase-note","acid_program_key_popup",2,nil,
      function(updated)
        return updated and updated.pitch_events[1].key==1,"New Phrase note callback did not save its draft"
      end,true)
    if not new_phrase_ok then return nil,new_phrase_error end
    local old_target_ok,old_target_error=run_value("owned-phrase-target","acid_phrase_choice",
      phrase_index,phrase,function()
        return controls.acid_phrase_choice.value==phrase_index,"Owned phrase target was not restored"
      end,false)
    if not old_target_ok then return nil,old_target_error end
    local warm_phrase_samples={}
    for sample=1,2 do
      local new_target_ok,new_target_error=run_value("new-phrase-reselection-"..sample,
        "acid_phrase_choice",controls.acid_new_phrase_choice_index,nil,function()
          return controls.acid_phrase_choice.value==controls.acid_new_phrase_choice_index,
            "New Phrase target was not selected during warm reselection"
        end,false)
      if not new_target_ok then return nil,new_target_error end
      reset_phrase_profile()
      phrase_profile_enabled=true
      local warm_started=os.clock()
      local warm_target_ok,warm_target_error=run_value("owned-phrase-reselection-"..sample,
        "acid_phrase_choice",phrase_index,phrase,function()
          return controls.acid_phrase_choice.value==phrase_index,
            "Owned phrase target was not restored during warm reselection"
        end,false)
      phrase_profile_enabled=false
      if not warm_target_ok then return nil,warm_target_error end
      warm_phrase_samples[sample]=(os.clock()-warm_started)*1000
      publish_phrase_profile("gui_phrase_warm_"..sample.."_profile")
    end
    metrics.gui_phrase_warm_reselection_samples_ms=string.format("%.2f,%.2f",
      warm_phrase_samples[1],warm_phrase_samples[2])
    metrics.gui_action_count=#actions
    metrics.gui_action_names=table.concat(actions,",")
    for _,kind in ipairs({"note","octave","command"}) do
      local values=samples[kind]
      local total,maximum=0,0
      local rendered={}
      for index,elapsed in ipairs(values) do
        total=total+elapsed
        if elapsed>maximum then maximum=elapsed end
        rendered[index]=string.format("%.2f",elapsed)
      end
      metrics["gui_"..kind.."_callback_count"]=#values
      metrics["gui_"..kind.."_callback_average_ms"]=total/#values
      metrics["gui_"..kind.."_callback_max_ms"]=maximum
      metrics["gui_"..kind.."_callback_samples_ms"]=table.concat(rendered,",")
    end
    local source_view=controls.acid_source_state
    if not source_view or type(source_view.text)~="string" or
        not source_view.text:find("SOURCE DIRTY",1,true) then
      close_test_gui()
      return nil,"GUI edit callback did not refresh draft status"
    end
    if phrase:line(1):note_column(1).note_value~=original_note then
      close_test_gui()
      return nil,"GUI edit callback changed committed phrase without live generation"
    end
    if writer.state()=="busy" then
      close_test_gui()
      return nil,"GUI edit callback unexpectedly started generation"
    end
    metrics.gui_callback_paths_verified=true
    metrics.gui_callbacks_per_control=3
    metrics.gui_callback_budget_ms=30
    metrics.gui_draft_save_verified=true
    metrics.gui_view_refresh_verified=true
    metrics.gui_unarmed_phrase_unchanged=true
    local slow_actions={}
    for name,elapsed in pairs(action_timings) do
      if elapsed>30 then slow_actions[#slow_actions+1]=name.."="..string.format("%.2f",elapsed) end
    end
    table.sort(slow_actions)
    metrics.gui_over_budget_actions=table.concat(slow_actions,",")
    local live_control=controls.acid_live_edit
    local live_notifier=callbacks.acid_live_edit
    if not live_control or type(live_notifier)~="function" then
      close_test_gui()
      return nil,"GUI Live Edit checkbox callback was not captured"
    end
    local live_key_control=controls.acid_program_key_popup
    local live_key_notifier=callbacks.acid_program_key_popup
    if not live_key_control or type(live_key_notifier)~="function" then
      close_test_gui()
      return nil,"GUI Live Edit note callback was not captured"
    end
    local function live_probe(finished)
      local function set_live_armed(value)
        suppress_captured_notifiers=true
        live_control.value=value
        suppress_captured_notifiers=false
        live_notifier(value)
      end
      local pitch_position=controls.acid_program_pitch_position
      local pitch_position_notifier=callbacks.acid_program_pitch_position
      if not pitch_position or type(pitch_position_notifier)~="function" then
        finished(false,"GUI Live Edit test could not select a source pitch")
        return
      end
      suppress_captured_notifiers=true
      pitch_position.value=1
      suppress_captured_notifiers=false
      pitch_position_notifier(1)
      local live_index=1
      local before_live,live_policy,live_pb=persisted.read_draft(song,instrument,phrase)
      if not before_live or live_index<1 or live_index>before_live.length then
        finished(false,"Live Edit test could not read the selected source pitch")
        return
      end
      local arm_count=callback_counts.acid_live_edit or 0
      metrics.gui_live_checkbox_found=live_control~=nil
      metrics.gui_live_checkbox_callback_found=live_notifier~=nil
      metrics.gui_live_checkbox_value_before=live_control.value==true
      gui_live_trace_enabled=true
      set_live_armed(true)
      local live_context=gui_transition_context or gui_context
      metrics.gui_context_created_count=gui_context_created_count
      metrics.gui_live_transition_context_matches_latest=rawequal(live_context,gui_context)
      local armed=live_context and live_context:generation_state()
      metrics.gui_live_armed_after_toggle=armed and armed.armed==true or false
      metrics.gui_live_busy_after_toggle=armed and armed.busy==true or false
      metrics.gui_live_pending_after_toggle=armed and armed.pending==true or false
      metrics.gui_live_status_after_toggle=armed and tostring(armed.status) or "missing"
      metrics.gui_live_checkbox_value_after=live_control.value==true
      metrics.gui_live_checkbox_callback_dispatches=(callback_counts.acid_live_edit or 0)-arm_count
      if not armed or not armed.armed or armed.busy then
        finished(false,"Live Edit did not arm before the source edit")
        return
      end
      local first_value=(before_live.pitch_events[live_index].key+1)%12+1
      local second_value=first_value%12+1
      local function edit_live_note(value)
        local started=os.clock()
        suppress_captured_notifiers=true
        live_key_control.value=value
        suppress_captured_notifiers=false
        live_key_notifier(value)
        return (os.clock()-started)*1000
      end
      reset_phrase_profile()
      phrase_profile_enabled=true
      metrics.gui_live_first_edit_elapsed_ms=edit_live_note(first_value)
      phrase_profile_enabled=false
      publish_phrase_profile("gui_live_first_profile")
      live_context=gui_transition_context or live_context
      local first_state=live_context:generation_state()
      metrics.gui_live_transition_trace=table.concat(gui_live_trace,";")
      metrics.gui_live_first_edit_busy=first_state.busy==true
      metrics.gui_live_first_edit_armed=first_state.armed==true
      metrics.gui_live_first_edit_pending=first_state.pending==true
      metrics.gui_live_first_edit_status=tostring(first_state.status)
      metrics.gui_live_first_edit_writer_state=tostring(writer.state())
      metrics.gui_live_first_edit_transition_kind=tostring(gui_transition_kind)
      if type(gui_transition_effects)=="table" then
        metrics.gui_live_first_edit_intent=gui_transition_effects.live_intent==true
        metrics.gui_live_first_edit_accepted=gui_transition_effects.accepted==true
        metrics.gui_live_first_edit_rejection=tostring(gui_transition_effects.reason or "")
      end
      if not first_state.armed or not (first_state.busy or first_state.pending) then
        set_live_armed(false)
        finished(false,"First armed note edit did not start generation")
        return
      end
      local idle=renoise.tool().app_idle_observable
      local function continue_when_busy()
      reset_phrase_profile()
      phrase_profile_enabled=true
      metrics.gui_live_busy_edit_elapsed_ms=edit_live_note(second_value)
      phrase_profile_enabled=false
      publish_phrase_profile("gui_live_busy_profile")
      live_context=gui_transition_context or live_context
      local second_state=live_context:generation_state()
      metrics.gui_live_transition_trace=table.concat(gui_live_trace,";")
      metrics.gui_live_second_edit_pending=second_state.pending==true
      local latest_source,latest_policy,latest_pb=persisted.read_draft(song,instrument,phrase)
      if not second_state.armed or not second_state.busy or not second_state.pending or
          not latest_source or latest_source.pitch_events[live_index].key~=second_value-1 or
          sequence.same_source(before_live,latest_source) then
        set_live_armed(false)
        finished(false,"Second armed note edit did not persist as the pending latest source")
        return
      end
      metrics.gui_live_latest_source_verified=true
      metrics.gui_live_output_policy=latest_policy or live_policy
      metrics.gui_live_pb_range=latest_pb or live_pb
      local waits=0
      local settled=false
      local safe_settle
      local settle
      settle=function()
        if settled then return end
        waits=waits+1
        local state=live_context:generation_state()
        local persisted_source=persisted.read_draft(song,instrument,phrase)
        local writer_state=writer.state()
        local last_result=state.last_result
        metrics.gui_live_wait_writer_state=writer_state
        metrics.gui_live_wait_pending=state.pending==true
        metrics.gui_live_wait_status=tostring(state.status)
        metrics.gui_live_wait_result=last_result and tostring(last_result.kind) or "missing"
        metrics.gui_live_wait_reason=last_result and tostring(last_result.reason or last_result.message or "") or ""
        metrics.gui_live_wait_draft_present=persisted_source~=nil
        metrics.gui_live_transition_trace=table.concat(gui_live_trace,";")
        if writer_state=="idle" and not state.pending then
          metrics.gui_live_settle_idle_ticks=waits
          metrics.gui_live_final_result=last_result and last_result.kind or "missing"
          metrics.gui_live_final_status=state.status
          pcall(function() idle:remove_notifier(safe_settle) end)
          if not last_result or last_result.kind~="success" or persisted_source then
            pcall(function() set_live_armed(false) end)
            settled=true
            finished(false,"Live Edit settled without committing latest draft: writer="..
              tostring(writer_state).." status="..tostring(state.status).." result="..
              tostring(last_result and last_result.kind).." reason="..
              tostring(last_result and (last_result.reason or last_result.message) or "")..
              " draft="..tostring(persisted_source~=nil))
            return
          end
        elseif waits<300 then
          return
        else
          pcall(function() idle:remove_notifier(safe_settle) end)
          set_live_armed(false)
          settled=true
          finished(false,"Live Edit did not settle within 300 idle ticks: writer="..
            tostring(writer_state).." status="..tostring(state.status).." pending="..
            tostring(state.pending).." result="..tostring(last_result and last_result.kind)..
            " draft="..tostring(persisted_source~=nil))
          return
        end
        local output_value=phrase:line(live_index):note_column(1).note_value
        local output_matches=output_value==latest_source.pitch_events[live_index].note
        metrics.gui_live_committed_note_value=output_value
        metrics.gui_live_committed_source_match=output_matches
        local disarm_count=callback_counts.acid_live_edit or 0
        set_live_armed(false)
        local disarmed=live_context:generation_state()
        metrics.gui_live_disarmed=not disarmed.armed
        local dialog_closed=close_test_gui()
        metrics.gui_dialog_closed=dialog_closed
        if state.last_result==nil or state.last_result.kind~="success" or
            not output_matches or disarmed.armed or not dialog_closed then
          settled=true
          finished(false,"Live Edit did not commit the latest note or close its dialog cleanly")
          return
        end
        metrics.gui_live_checkbox_dispatches=(callback_counts.acid_live_edit or 0)-arm_count
        metrics.gui_live_disarm_dispatches=(callback_counts.acid_live_edit or 0)-disarm_count
        action_timings["live-first-note"]=metrics.gui_live_first_edit_elapsed_ms
        action_timings["live-busy-note"]=metrics.gui_live_busy_edit_elapsed_ms
        local over_budget={}
        for name,elapsed in pairs(action_timings) do
          if elapsed>30 then over_budget[#over_budget+1]=name.."="..string.format("%.2f",elapsed) end
        end
        table.sort(over_budget)
        metrics.gui_over_budget_actions=table.concat(over_budget,",")
        metrics.gui_over_budget_action_count=#over_budget
        metrics.gui_live_edit_coalescing_verified=true
        settled=true
        if #over_budget>0 then
          finished(false,"GUI actions exceeded 30 ms: "..metrics.gui_over_budget_actions)
        else
          finished(true)
        end
      end
      safe_settle=function()
        local ok,reason=xpcall(settle,function(callback_error)
          if debug and type(debug.traceback)=="function" then
            return debug.traceback(tostring(callback_error),2)
          end
          return tostring(callback_error)
        end)
        if not ok and not settled then
          settled=true
          pcall(function() idle:remove_notifier(safe_settle) end)
          pcall(function() set_live_armed(false) end)
          finished(false,reason)
        end
      end
      idle:add_notifier(safe_settle)
      end
      if first_state.busy then
        local ok,reason=xpcall(continue_when_busy,function(callback_error)
          if debug and type(debug.traceback)=="function" then
            return debug.traceback(tostring(callback_error),2)
          end
          return tostring(callback_error)
        end)
        if not ok then finished(false,reason) end
        return
      end
      local busy_waits=0
      local wait_for_busy
      wait_for_busy=function()
        busy_waits=busy_waits+1
        live_context=gui_transition_context or live_context
        local state=live_context:generation_state()
        metrics.gui_live_first_wait_ticks=busy_waits
        metrics.gui_live_first_wait_writer_state=tostring(writer.state())
        metrics.gui_live_first_wait_status=tostring(state.status)
        metrics.gui_live_first_wait_pending=state.pending==true
        if writer.state()=="busy" and state.busy then
          pcall(function() idle:remove_notifier(wait_for_busy) end)
          local ok,reason=xpcall(continue_when_busy,function(callback_error)
            if debug and type(debug.traceback)=="function" then
              return debug.traceback(tostring(callback_error),2)
            end
            return tostring(callback_error)
          end)
          if not ok then finished(false,reason) end
        elseif busy_waits<300 and (state.pending or writer.state()=="busy") then
          return
        else
          pcall(function() idle:remove_notifier(wait_for_busy) end)
          set_live_armed(false)
          finished(false,"Queued Live Edit never entered a writer job: writer="..
            tostring(writer.state()).." status="..tostring(state.status)..
            " pending="..tostring(state.pending))
        end
      end
      idle:add_notifier(wait_for_busy)
    end
    return true,nil,live_probe
  end
  local function verify_hidden_snapshot_cells()
    local probe_index=#instrument.phrases+1
    local probe
    local ok,reason=pcall(function()
      probe=instrument:insert_phrase_at(probe_index)
      assert(probe,"native phrase insertion returned no phrase")
      probe.number_of_lines=512
      probe.visible_note_columns=1
      probe.visible_effect_columns=1
      local hidden_line=probe:line(512)
      local hidden_note=hidden_line:note_column(12)
      local hidden_effect=hidden_line:effect_column(8)
      local empty_line=probe:line(511)
      local empty_note=empty_line:note_column(1)
      local empty_effect=empty_line:effect_column(1)
      hidden_note.note_value=48
      hidden_note.volume_value=73
      hidden_effect.number_value=12
      hidden_effect.amount_value=90
      local snapshot,snapshot_error=ownership.snapshot(probe)
      assert(snapshot,snapshot_error or "hidden-cell phrase snapshot failed")
      local copied_note=snapshot.lines[512].notes[12]
      local copied_effect=snapshot.lines[512].effects[8]
      assert(copied_note.note_value==hidden_note.note_value and
        copied_note.volume_value==hidden_note.volume_value and copied_note.is_empty==false,
        "snapshot lost inactive hidden note-cell values")
      assert(copied_effect.number_value==hidden_effect.number_value and
        copied_effect.amount_value==hidden_effect.amount_value and copied_effect.is_empty==false,
        "snapshot lost inactive hidden effect-cell values")
      local copied_empty_note=snapshot.lines[511].notes[1]
      for _,key in ipairs({"note_value","instrument_value","volume_value","panning_value",
          "delay_value","effect_number_value","effect_amount_value"}) do
        assert(copied_empty_note[key]==empty_note[key],"snapshot empty note default differs at "..key)
      end
      assert(copied_empty_note.is_empty==true,"snapshot changed an empty note cell")
      local copied_empty_effect=snapshot.lines[511].effects[1]
      for _,key in ipairs({"number_value","amount_value"}) do
        assert(copied_empty_effect[key]==empty_effect[key],"snapshot empty effect default differs at "..key)
      end
      assert(copied_empty_effect.is_empty==true,"snapshot changed an empty effect cell")
      metrics.hidden_snapshot_line=512
      metrics.hidden_snapshot_note_column=12
      metrics.hidden_snapshot_effect_column=8
      metrics.hidden_snapshot_values_verified=true
      metrics.empty_snapshot_defaults_match_native=true
    end)
    if probe then
      for index,item in ipairs(instrument.phrases) do
        if rawequal(item,probe) then
          pcall(function() instrument:delete_phrase_at(index) end)
          break
        end
      end
    end
    return ok,reason
  end
  local source=sequence.new_pattern(32)
  for step=1,32 do
    source.pitch_events[step]=sequence.new_pitch((step-1)%13,0,true,false)
    source.time_events[step]="N"
  end
  local function create_test_context()
    if context then context:release_document() end
    capture_calls=0
    captured_column_name=nil
    context=require("runtime.context").new({
      writer=writer,
      capture=function() return nil,"The editor request-capture path is required" end,
      sink=function(request,completion)
        sink_calls=sink_calls+1
        if request.kind=="regenerate" then return writer.regenerate(request,completion) end
        if request.kind=="create" then return writer.create(request,completion) end
        return false,"Unexpected request kind"
      end,
      cancel=writer.cancel
    })
    local request_module=require("runtime.requests")
    local original_requests_new=request_module.new
    request_module.new=function(access)
      local owner=original_requests_new(access)
      local original_capture=owner.capture
      owner.capture=function(self,...)
        capture_calls=capture_calls+1
        local values=pack_values(original_capture(self,...))
        local request=values[1]
        if request then
          pcall(function()
            captured_column_name=request.baseline.snapshot.columns[1].name
          end)
        end
        return unpack_values(values,1,values.n)
      end
      return owner
    end
    local attached,attach_error=pcall(function() context:attach_document(song) end)
    request_module.new=original_requests_new
    if not attached then return nil,tostring(attach_error) end
    context:open_dialog()
    local bound=context:bind_phrase(instrument,phrase)
    if not bound or bound.kind~="owned" then
      return nil,bound and bound.reason or "long phrase could not be bound"
    end
    local loaded,load_error=context:transition("programmatic",{
      source=source,output_policy="play_once",pb_range=0
    })
    if not loaded then return nil,load_error or "editor source could not be initialized for the target" end
    return true
  end
  local unique_name=string.format("ACID E2E %d %d",os.time(),instrument_index)
  local name_is_unique=false
  for suffix=1,#song.instruments+1 do
    local matches=0
    for _,candidate in ipairs(song.instruments) do
      if candidate.name==unique_name then matches=matches+1 end
    end
    if matches==0 then name_is_unique=true;break end
    unique_name=string.format("ACID E2E %d %d %d",os.time(),instrument_index,suffix)
  end
  if not name_is_unique then fail("Could not assign a unique disposable instrument name for New Phrase draft validation");return true end
  instrument.name=unique_name
  local hidden_snapshot_ok,hidden_snapshot_error=verify_hidden_snapshot_cells()
  if not hidden_snapshot_ok then fail(hidden_snapshot_error);return true end
  local create_request,create_error=factory.build(song,instrument_index,source,#instrument.phrases+1,
    {output_policy="play_once",pb_range=0})
  if not create_request or create_request.kind~="create" then
    done({status="FAIL",case="editor-responsiveness",reason=describe_failure(create_error or "long phrase request was not a create")})
    return true
  end
  local accepted,start_error=writer.create(create_request,function(result)
    local callback_ok,callback_error=xpcall(function()
    if type(result)~="table" or result.kind~="success" or result.verified~=true or not result.phrase then
      fail(describe_failure(result or "long phrase creation failed"));return
    end
    phrase=result.phrase
    local seeded,seed_error=require("runtime.draft_cache").put(song,instrument,phrase,
      source,"play_once",0)
    if not seeded then fail(seed_error or "could not seed GUI callback draft");return end
    gui_draft_seeded=true
    local initialized,initialize_error=create_test_context()
    if not initialized then fail(initialize_error);return end

    local function profile_function(target,key,name)
      local original=target[key]
      target[key]=function(...)
        local started=os.clock()
        local values=pack_values(original(...))
        local elapsed=(os.clock()-started)*1000
        profile[name].calls=profile[name].calls+1
        profile[name].elapsed_ms=profile[name].elapsed_ms+elapsed
        if name=="snapshot" then scans=scans+1 end
        return unpack_values(values,1,values.n)
      end
    end
    local function count_snapshots()
      if scans_snapshot_wrapper then return end
      local snapshot=ownership.snapshot
      scans_snapshot_wrapper=function(...)
        scans=scans+1
        return snapshot(...)
      end
      ownership.snapshot=scans_snapshot_wrapper
    end
    count_snapshots()
    local initial=context:target_projection()
    if initial.kind~="owned" or not rawequal(initial.phrase,phrase) then
      fail("target projection did not return the generated phrase");return
    end
    scans=0
    local fresh_state_started=os.clock()
    for _=1,3 do
      local fresh=context:target_state()
      if fresh.kind~="owned" or not rawequal(fresh.phrase,phrase) then
        fail("fresh admission state changed target identity");return
      end
    end
    local fresh_target_elapsed_ms=(os.clock()-fresh_state_started)*1000
    local fresh_target_scans=scans
    metrics.fresh_admission_calls=3
    metrics.fresh_admission_snapshot_scans=fresh_target_scans
    metrics.fresh_admission_elapsed_ms=fresh_target_elapsed_ms
    scans=0
    local render=editor.project(source)
    local iterations=160
    local started=os.clock()
    for _=1,iterations do
      local projection=context:target_projection()
      local reconciled,reconcile_error=context:reconcile()
      if projection.kind~="owned" or not rawequal(projection.phrase,phrase) or
          not reconciled or not rawequal(reconciled.phrase,phrase) then
        fail(reconcile_error or "unchanged target projection/reconciliation changed identity");return
      end
      for step=1,32 do
        editor.step_text(render,step,1)
        editor.step_text(render,step,2)
      end
    end
    local elapsed_ms=(os.clock()-started)*1000
    local idle_scans=scans
    metrics.representative_steps=32
    metrics.phrase_lines=phrase.number_of_lines
    metrics.unchanged_read_iterations=iterations
    metrics.unchanged_snapshot_scans=idle_scans
    metrics.unchanged_read_elapsed_ms=elapsed_ms
    if idle_scans~=0 then
      fail("unchanged projection/reconcile/render loop scanned phrase snapshots: "..tostring(idle_scans));return
    end

    reset_profile()
    profile_function(ownership,"snapshot","snapshot")
    profile_function(ownership,"copy_snapshot","copy_snapshot")
    profile_function(ownership,"compare","compare")
    profile_function(validator,"classify","classify")
    local allocation_profile={}
    local function profile_allocation(target,key,name)
      local original=target[key]
      local record={calls=0,elapsed_ms=0,memory_delta_kb=0}
      allocation_profile[name]=record
      target[key]=function(...)
        local memory_before=collectgarbage("count")
        local started=os.clock()
        local values=pack_values(original(...))
        record.elapsed_ms=record.elapsed_ms+(os.clock()-started)*1000
        record.memory_delta_kb=record.memory_delta_kb+collectgarbage("count")-memory_before
        record.calls=record.calls+1
        return unpack_values(values,1,values.n)
      end
      return function() target[key]=original end
    end
    local capabilities=require("renoise.target_capabilities")
    local store=require("renoise.pattern_store")
    local restore_allocation_profile={
      profile_allocation(capabilities,"inspect","capabilities_inspect"),
      profile_allocation(store,"read_entry","store_read_entry"),
      profile_allocation(store,"write_draft","store_write_draft"),
      profile_allocation(sequence,"copy_source","copy_source"),
    }
    local profile_started=os.clock()
    local profile_transition_started=os.clock()
    source.pitch_events[1]=sequence.new_pitch(12,0,true,false)
    local profile_called,profiled_edit,profiled_error=pcall(context.transition,context,"edit",{
      source=source,output_policy="play_once",pb_range=0
    })
    for _,restore in ipairs(restore_allocation_profile) do restore() end
    if not profile_called then fail(profiled_edit);return end
    if not profiled_edit then fail(profiled_error or "profiled source edit transition failed");return end
    metrics.profiled_edit_transition_elapsed_ms=(os.clock()-profile_transition_started)*1000
    local profile_render_started=os.clock()
    local profiled_projection=editor.project(source)
    for step=1,32 do
      editor.step_text(profiled_projection,step,1)
      editor.step_text(profiled_projection,step,2)
    end
    metrics.profiled_edit_render_elapsed_ms=(os.clock()-profile_render_started)*1000
    metrics.profiled_edit_sample_elapsed_ms=(os.clock()-profile_started)*1000
    for _,name in ipairs(profile_names) do
      metrics["profiled_edit_"..name.."_calls"]=profile[name].calls
      metrics["profiled_edit_"..name.."_elapsed_ms"]=profile[name].elapsed_ms
    end
    for name,record in pairs(allocation_profile) do
      metrics["profiled_edit_"..name.."_calls"]=record.calls
      metrics["profiled_edit_"..name.."_elapsed_ms"]=record.elapsed_ms
      metrics["profiled_edit_"..name.."_memory_delta_kb"]=record.memory_delta_kb
    end
    ownership.copy_snapshot=original_copy_snapshot
    ownership.compare=original_compare
    validator.classify=original_classify
    count_snapshots()

    reset_profile()
    profile_function(ownership,"copy_snapshot","copy_snapshot")
    profile_function(ownership,"compare","compare")
    profile_function(ownership,"matches_snapshot","matches_snapshot")
    profile_function(validator,"classify","classify")
    profile_function(validator,"classify_against","classify_against")
    local original_ownership_status=ownership.status
    local ownership_status_calls=0
    local function profile_status_edit(edit_source)
      ownership.status=function(...)
        ownership_status_calls=ownership_status_calls+1
        return original_ownership_status(...)
      end
      local called,edited,edit_error=pcall(context.transition,context,"edit",{
        source=edit_source,output_policy="play_once",pb_range=0
      })
      ownership.status=original_ownership_status
      if not called then return nil,edited end
      return edited,edit_error
    end
    scans=0
    local edit_started=os.clock()
    local edit_sample_ms={}
    local edit_sample_text={}
    local edit_transition_elapsed_ms,edit_render_elapsed_ms=0,0
    for sample=1,5 do
      local sample_started=os.clock()
      source.pitch_events[1]=sequence.new_pitch(sample%2,0,true,false)
      local transition_started=os.clock()
      local edited,edit_error=profile_status_edit(source)
      if not edited then fail(edit_error or "unarmed source edit transition failed");return end
      edit_transition_elapsed_ms=edit_transition_elapsed_ms+(os.clock()-transition_started)*1000
      local render_started=os.clock()
      local edited_projection=editor.project(source)
      for step=1,32 do
        editor.step_text(edited_projection,step,1)
        editor.step_text(edited_projection,step,2)
      end
      edit_render_elapsed_ms=edit_render_elapsed_ms+(os.clock()-render_started)*1000
      edit_sample_ms[sample]=(os.clock()-sample_started)*1000
      edit_sample_text[sample]=string.format("%.2f",edit_sample_ms[sample])
    end
    local edit_elapsed_ms=(os.clock()-edit_started)*1000
    local edit_scans=scans
    metrics.unarmed_edit_samples=5
    metrics.unarmed_edit_snapshot_scans=edit_scans
    metrics.unarmed_edit_transition_render_elapsed_ms=edit_elapsed_ms
    metrics.unarmed_edit_transition_elapsed_ms=edit_transition_elapsed_ms
    metrics.unarmed_edit_render_elapsed_ms=edit_render_elapsed_ms
    metrics.unarmed_edit_average_sample_elapsed_ms=edit_elapsed_ms/5
    local max_edit_sample_ms=0
    for _,sample_elapsed in ipairs(edit_sample_ms) do
      if sample_elapsed>max_edit_sample_ms then max_edit_sample_ms=sample_elapsed end
    end
    metrics.unarmed_edit_max_sample_elapsed_ms=max_edit_sample_ms
    metrics.unarmed_edit_sample_timings_ms=table.concat(edit_sample_text,",")
    metrics.unarmed_edit_copy_snapshot_calls=profile.copy_snapshot.calls
    metrics.unarmed_edit_copy_snapshot_elapsed_ms=profile.copy_snapshot.elapsed_ms
    metrics.unarmed_edit_compare_calls=profile.compare.calls
    metrics.unarmed_edit_compare_elapsed_ms=profile.compare.elapsed_ms
    metrics.unarmed_edit_classify_calls=profile.classify.calls
    metrics.unarmed_edit_classify_elapsed_ms=profile.classify.elapsed_ms
    metrics.unarmed_edit_classify_against_calls=profile.classify_against.calls
    metrics.unarmed_edit_classify_against_elapsed_ms=profile.classify_against.elapsed_ms
    metrics.unarmed_edit_matches_snapshot_calls=profile.matches_snapshot.calls
    metrics.unarmed_edit_matches_snapshot_elapsed_ms=profile.matches_snapshot.elapsed_ms
    metrics.unarmed_edit_ownership_status_calls=ownership_status_calls
    ownership.copy_snapshot=original_copy_snapshot
    ownership.compare=original_compare
    ownership.matches_snapshot=original_matches_snapshot
    validator.classify=original_classify
    validator.classify_against=original_classify_against
    if profile.classify_against.calls~=0 then
      fail("clean unarmed source edits invoked full classify_against validation");return
    end
    if profile.matches_snapshot.calls~=0 then
      fail("clean unarmed source edits performed full native cell matching");return
    end
    if ownership_status_calls~=0 then
      fail("clean unarmed source edits hashed native phrase cells for draft persistence");return
    end
    if max_edit_sample_ms>100 then
      fail("source edit transition and render exceeded 100 ms: "..tostring(max_edit_sample_ms));return
    end
    if sink_calls~=0 then fail("unarmed source edits unexpectedly started generation");return end
    local gui_callbacks_ok,gui_callbacks_error,live_probe=measure_gui_callbacks()
    if not gui_callbacks_ok then fail(gui_callbacks_error);return end

    local function continue_after_gui_body()
    local initialized,initialize_error=create_test_context()
    if not initialized then fail(initialize_error);return end
    observer=require("runtime.observers").new()
    observer:attach(song,context,function() end)
    local old_name=phrase:column_name(1)
    local changed_name=old_name=="ACID responsiveness probe" and "ACID responsiveness probe 2" or "ACID responsiveness probe"
    phrase:set_column_name(1,changed_name)
    observer:refresh()
    local fresh=context:reconcile()
    local dirty_scans=scans
    metrics.dirty_snapshot_scans=dirty_scans
    if not fresh or fresh.kind~="unavailable" or not rawequal(fresh.phrase,phrase) then
      phrase:set_column_name(1,old_name)
      fail("column metadata change did not invalidate the stale target baseline");return
    end
    local stale_request,stale_reason=context:request_generation("manual")
    metrics.stale_metadata_request_rejected=not stale_request
    metrics.stale_metadata_capture_calls=capture_calls
    if stale_request or sink_calls~=0 or not stale_reason then
      phrase:set_column_name(1,old_name)
      fail(stale_reason or "changed metadata reached the generation sink");return
    end
    phrase:set_column_name(1,old_name)
    observer:detach()
    local rebound,rebind_error=create_test_context()
    if not rebound then
      phrase:set_column_name(1,old_name)
      fail(rebind_error or "restored phrase could not be rebound");return
    end
    local admission_waits=0
    local completion_idle=renoise.tool().app_idle_observable
    local request_when_idle
    request_when_idle=function()
      if writer.state()=="busy" then
        admission_waits=admission_waits+1
        if admission_waits>6000 then
          pcall(function() completion_idle:remove_notifier(request_when_idle) end)
          phrase:set_column_name(1,old_name);fail("initial phrase creation did not release the writer slot");return
        end
        return
      end
      pcall(function() completion_idle:remove_notifier(request_when_idle) end)
      local requested,request_error=context:request_generation("manual")
      if not requested then phrase:set_column_name(1,old_name);fail(request_error or "fresh request rejected after metadata edit");return end
    local completion_waits=0
    local wait_completion
    wait_completion=function()
      if writer.state()=="busy" then
        completion_waits=completion_waits+1
        if completion_waits>6000 then
          pcall(function() completion_idle:remove_notifier(wait_completion) end)
          phrase:set_column_name(1,old_name);fail("fresh regeneration did not settle");return
        end
        return
      end
      pcall(function() completion_idle:remove_notifier(wait_completion) end)
      local committed=type(context:generation_state().last_result)=="table" and
        context:generation_state().last_result.kind=="success"
      local preserved=phrase:column_name(1)==old_name and captured_column_name==old_name
      local generated_lines=phrase.number_of_lines
      phrase:set_column_name(1,old_name)
      local elapsed=elapsed_ms
      local scan_count=idle_scans
      cleanup()
      local passed=committed and preserved and capture_calls==1 and sink_calls==1
      metrics.phrase_lines=generated_lines
      metrics.unchanged_snapshot_scans=scan_count
      metrics.stale_metadata_request_rejected=true
      metrics.restored_metadata_request_committed=committed
      metrics.metadata_request_used_fresh_baseline=preserved
      metrics.generation_calls=sink_calls
      local result={status=passed and "PASS" or "FAIL",case="editor-responsiveness",
        stale_metadata_request_rejected=true,restored_metadata_request_committed=committed,
        metadata_request_used_fresh_baseline=preserved,generation_calls=sink_calls,
        reason=not passed and "metadata-driven fresh request failed" or nil}
      for key,value in pairs(metrics) do result[key]=value end
      done(result)
    end
    completion_idle:add_notifier(wait_completion)
    end
    completion_idle:add_notifier(request_when_idle)
    end
    local function continue_after_gui()
      local continued,continuation_error=xpcall(continue_after_gui_body,function(callback_error)
        if debug and type(debug.traceback)=="function" then
          return debug.traceback(tostring(callback_error),2)
        end
        return tostring(callback_error)
      end)
      if not continued then fail(continuation_error) end
    end
    local live_probe_idle=renoise.tool().app_idle_observable
    local live_probe_barrier_ticks=0
    local start_live_probe
    start_live_probe=function()
      live_probe_barrier_ticks=live_probe_barrier_ticks+1
      if live_probe_barrier_ticks<2 then return end
      pcall(function() live_probe_idle:remove_notifier(start_live_probe) end)
      metrics.gui_live_dispatch_barrier_ticks=live_probe_barrier_ticks
      local started,start_error=xpcall(function()
        live_probe(function(probe_ok,probe_error)
          if not probe_ok then fail(probe_error or "Live Edit callback probe failed");return end
          continue_after_gui()
        end)
      end,function(callback_error)
        if debug and type(debug.traceback)=="function" then
          return debug.traceback(tostring(callback_error),2)
        end
        return tostring(callback_error)
      end)
      if not started then fail(start_error) end
    end
    live_probe_idle:add_notifier(start_live_probe)
    end,function(callback_error)
      if debug and type(debug.traceback)=="function" then
        return debug.traceback(tostring(callback_error),2)
      end
      return tostring(callback_error)
    end)
    if not callback_ok then fail(callback_error) end
  end)
  if not accepted then fail(describe_failure(start_error or "long phrase writer rejected request")) end
  return true
end

function M.run(case_name, done)
  if type(done) ~= "function" then return false, "completion callback is required" end
  if case_name == "make-independent" then return run_make_independent(done) end
  if case_name == "draft-recovery" then return run_draft_recovery(done) end
  if case_name == "writer-recovery" then return run_writer_recovery(done) end
  if case_name == "integrity-observers" then return run_integrity_observers(done) end
  if case_name == "editor-responsiveness" then return run_editor_responsiveness(done) end
  if case_name == "reopen-independent" then
    local song = renoise.song()
    local instrument_index = song.selected_instrument_index
    local instrument = song.instruments[instrument_index]
    local sequence = require("model.sequencer")
    local store = require("renoise.pattern_store")
    local ownership = require("renoise.phrase_ownership")
    local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
    local old_id, new_id, new_phrase, old_source
    local groups = ownership.inventory(song)
    if groups then
      for _, phrase in ipairs(instrument.phrases) do
        local id = ownership.id(phrase)
        local source = id and store.read_entry(song, id)
        if source and source.pitch_events[1] then
          if source.pitch_events[1].note == sequence.BASE_NOTE+5 then new_id, new_phrase = id, phrase
          elseif source.pitch_events[1].note == sequence.BASE_NOTE+4 then old_id, old_source = id, source end
        end
      end
    end
    if not groups or #instrument.phrases ~= 2 or not old_id or not new_id or old_id == new_id or
        not groups[old_id] or #groups[old_id] ~= 1 or not groups[new_id] or #groups[new_id] ~= 1 then
      done({ status = "FAIL", case = "reopen-independent", reason = "Saved phrase identity/source classification did not survive reload" })
      return true
    end
    local context = context_for(song)
    local bound = context:bind_phrase(instrument, new_phrase)
    local target = context:target_state()
    if not bound or not rawequal(target.instrument, instrument) or not rawequal(target.phrase, new_phrase) then
      context:release_document()
      done({ status = "FAIL", case = "reopen-independent", reason = "Reloaded independent phrase could not be selected" })
      return true
    end
    local changed_source = sequence.copy_source(assert(store.read_entry(song, new_id)))
    changed_source.pitch_events[1] = sequence.new_pitch(6,0,true,false)
    local target_index
    for index, phrase in ipairs(instrument.phrases) do
      if rawequal(phrase, new_phrase) then target_index = index; break end
    end
    local request, request_error = factory.build(song, instrument_index, changed_source, target_index)
    if not request or request.kind ~= "regenerate" then
      context:release_document()
      done({ status = "FAIL", case = "reopen-independent", reason = describe_failure(request_error or "Reloaded target did not build a regenerate request") })
      return true
    end
    local writer = require("writers.phrase_writer")
    local accepted, start_error = writer.regenerate(request, function(result)
      if type(result) ~= "table" or result.kind ~= "success" or result.verified ~= true or
          not rawequal(result.phrase, new_phrase) then
        context:release_document()
        done({ status = "FAIL", case = "reopen-independent", reason = describe_failure(result or "Reloaded phrase regeneration failed") })
        return
      end
      on_next_idle(function()
        local saved_new = store.read_entry(song, new_id)
        local saved_old = store.read_entry(song, old_id)
        local after = ownership.inventory(song)
        local passed = #instrument.phrases == 2 and ownership.id(new_phrase) == new_id and
          saved_new and sequence.same_source(saved_new, changed_source) and
          saved_old and sequence.same_source(saved_old, old_source) and
          after and after[old_id] and #after[old_id] == 1 and
          after[new_id] and #after[new_id] == 1
        context:release_document()
        done({ status = passed and "PASS" or "FAIL", case = "reopen-independent",
          old_id = old_id, new_id = new_id, phrase_count = #instrument.phrases,
          regenerated_same_object = rawequal(result.phrase, new_phrase),
          reloaded_sources_and_ids_preserved = passed == true })
      end)
    end)
    if not accepted then
      context:release_document()
      done({ status = "FAIL", case = "reopen-independent", reason = describe_failure(start_error) })
    end
    return true
  end
  if case_name == "api-probe" then
    local phrase_api = renoise.InstrumentPhrase
    local instrument_api = renoise.Instrument
    local result = {
      status = "PASS",
      case = "api-probe",
      phrase_api_type = type(phrase_api),
      phrase_api_value = tostring(phrase_api),
      instrument_api_type = type(instrument_api),
      instrument_api_value = tostring(instrument_api)
    }
    if phrase_api ~= nil then
      for _, key in ipairs({"MAX_NUMBER_OF_LINES", "MAX_NUMBER_OF_NOTE_COLUMNS",
          "MAX_NUMBER_OF_EFFECT_COLUMNS", "PLAY_PATTERN", "KEY_TRACKING_NONE"}) do
        local ok, value = pcall(function() return phrase_api[key] end)
        result[key:lower()] = ok and value or "unreadable"
      end
    end
    done(result)
    return true
  end
  return false, "native acceptance case is not allowlisted"
end

return M
