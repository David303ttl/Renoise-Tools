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

local function run_editor_responsiveness(done)
  local song=renoise.song()
  local instrument_index=song.selected_instrument_index
  local instrument=song.instruments[instrument_index]
  local sequence=require("model.sequencer")
  local editor=require("model.editor_state")
  local writer=require("writers.phrase_writer")
  local ownership=require("renoise.phrase_ownership")
  local validator=require("writers.phrase_validator")
  local factory=dofile(renoise.tool().bundle_path.."\\__dev\\writer_request.lua")
  local original_store=song.tool_data
  local original_snapshot=ownership.snapshot
  local original_copy_snapshot=ownership.copy_snapshot
  local original_compare=ownership.compare
  local original_classify=validator.classify
  local captured_column_name
  local capture_calls,sink_calls=0,0
  local rejected_target_reason
  local metrics={}
  local scans=0
  local profile={}
  local profile_names={"snapshot","copy_snapshot","compare","classify"}
  local function reset_profile()
    for _,name in ipairs(profile_names) do profile[name]={calls=0,elapsed_ms=0} end
  end
  reset_profile()
  local phrase
  local context
  local observer
  local function cleanup()
    if observer then pcall(function() observer:detach() end) end
    if context then pcall(function() context:release_document() end) end
    ownership.snapshot=original_snapshot
    ownership.copy_snapshot=original_copy_snapshot
    ownership.compare=original_compare
    validator.classify=original_classify
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
  local hidden_snapshot_ok,hidden_snapshot_error=verify_hidden_snapshot_cells()
  if not hidden_snapshot_ok then fail(hidden_snapshot_error);return true end
  local create_request,create_error=factory.build(song,instrument_index,source,#instrument.phrases+1,
    {output_policy="play_once",pb_range=0})
  if not create_request or create_request.kind~="create" then
    done({status="FAIL",case="editor-responsiveness",reason=describe_failure(create_error or "long phrase request was not a create")})
    return true
  end
  local accepted,start_error=writer.create(create_request,function(result)
    if type(result)~="table" or result.kind~="success" or result.verified~=true or not result.phrase then
      fail(describe_failure(result or "long phrase creation failed"));return
    end
    phrase=result.phrase
    context=require("runtime.context").new({
      writer=writer,
      capture=function(_,token)
        capture_calls=capture_calls+1
        local target=context:target_state()
        if target.kind~="owned" then
          rejected_target_reason=target.reason
          return nil,target.reason or "Target is not safely owned"
        end
        local request,reason=factory.build(song,instrument_index,source,target.phrase_index,
          {token=token,output_policy="play_once",pb_range=0})
        captured_column_name=request and request.baseline and request.baseline.snapshot.columns[1].name
        return request,reason
      end,
      sink=function(request,completion)
        sink_calls=sink_calls+1
        if request.kind=="regenerate" then return writer.regenerate(request,completion) end
        if request.kind=="create" then return writer.create(request,completion) end
        return false,"Unexpected request kind"
      end,
      cancel=writer.cancel
    })
    context:attach_document(song)
    context:open_dialog()
    local bound=context:bind_phrase(instrument,phrase)
    if not bound or bound.kind~="owned" then fail(bound and bound.reason or "long phrase could not be bound");return end
    local loaded,load_error=context:transition("programmatic",{
      source=source,output_policy="play_once",pb_range=0
    })
    if not loaded then fail(load_error or "editor source could not be initialized for the target");return end

    local unpack_values=unpack or table.unpack
    local function pack_values(...) return {n=select("#",...),...} end
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
      ownership.snapshot=function(...)
        scans=scans+1
        return original_snapshot(...)
      end
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
    local profile_started=os.clock()
    local profile_transition_started=os.clock()
    source.pitch_events[1]=sequence.new_pitch(12,0,true,false)
    local profiled_edit,profiled_error=context:transition("edit",{
      source=source,output_policy="play_once",pb_range=0
    })
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
    ownership.copy_snapshot=original_copy_snapshot
    ownership.compare=original_compare
    validator.classify=original_classify
    count_snapshots()

    scans=0
    local edit_started=os.clock()
    local edit_sample_ms={}
    local edit_sample_text={}
    local edit_transition_elapsed_ms,edit_render_elapsed_ms=0,0
    for sample=1,5 do
      local sample_started=os.clock()
      source.pitch_events[1]=sequence.new_pitch(sample%2,0,true,false)
      local transition_started=os.clock()
      local edited,edit_error=context:transition("edit",{
        source=source,output_policy="play_once",pb_range=0
      })
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
    if max_edit_sample_ms>100 then
      fail("source edit transition and render exceeded 100 ms: "..tostring(max_edit_sample_ms));return
    end
    if sink_calls~=0 then fail("unarmed source edits unexpectedly started generation");return end

    observer=require("runtime.observers").new()
    observer:attach(song,context,function() end)
    local old_name=phrase:column_name(1)
    local changed_name=old_name=="ACID responsiveness probe" and "ACID responsiveness probe 2" or "ACID responsiveness probe"
    phrase:set_column_name(1,changed_name)
    observer:refresh()
    local fresh=context:reconcile()
    local dirty_scans=scans
    metrics.dirty_snapshot_scans=dirty_scans
    if not fresh or fresh.kind~="unavailable" or not rawequal(fresh.phrase,phrase) or dirty_scans==0 then
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
    context:release_document()
    context=require("runtime.context").new({
      writer=writer,
      capture=function(_,token)
        capture_calls=capture_calls+1
        local target=context:target_state()
        if target.kind~="owned" then
          rejected_target_reason=target.reason
          return nil,target.reason or "Target is not safely owned"
        end
        local request,reason=factory.build(song,instrument_index,source,target.phrase_index,
          {token=token,output_policy="play_once",pb_range=0})
        captured_column_name=request and request.baseline and request.baseline.snapshot.columns[1].name
        return request,reason
      end,
      sink=function(request,completion)
        sink_calls=sink_calls+1
        return writer.regenerate(request,completion)
      end,
      cancel=writer.cancel
    })
    context:attach_document(song)
    context:open_dialog()
    local rebound=context:bind_phrase(instrument,phrase)
    if not rebound or rebound.kind~="owned" then
      phrase:set_column_name(1,old_name)
      fail(rebound and rebound.reason or "restored phrase could not be rebound");return
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
  end)
  if not accepted then fail(describe_failure(start_error or "long phrase writer rejected request")) end
  return true
end

function M.run(case_name, done)
  if type(done) ~= "function" then return false, "completion callback is required" end
  if case_name == "make-independent" then return run_make_independent(done) end
  if case_name == "draft-recovery" then return run_draft_recovery(done) end
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
