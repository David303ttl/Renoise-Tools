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
      status = passed and "PASS" or "FAIL",
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
    changed_source.pitch_events[1].note = 5
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

function M.run(case_name, done)
  if type(done) ~= "function" then return false, "completion callback is required" end
  if case_name == "make-independent" then return run_make_independent(done) end
  if case_name == "draft-recovery" then return run_draft_recovery(done) end
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
          if source.pitch_events[1].note == 5 then new_id, new_phrase = id, phrase
          elseif source.pitch_events[1].note == 4 then old_id, old_source = id, source end
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
    changed_source.pitch_events[1].note = 6
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
