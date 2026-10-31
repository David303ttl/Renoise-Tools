-- Fixed native acceptance cases for the disposable development host.
local M = {}
local MILLISECONDS_PER_SECOND = 1000
local TWO_HOLDER_COUNT = 2
local THREE_HOLDER_COUNT = 3
local THREE_EMPTY_INSTRUMENTS = 3
local MAXIMUM_ELIGIBILITY_PROOFS = 2
local ACCEPTANCE_PATTERN_LENGTH = 8
local ACCEPTANCE_KEY = 0
local ACCEPTANCE_GENERATED_NOTE = 4
local ACCEPTANCE_INDEPENDENT_NOTE = 5
local ACCEPTANCE_REGENERATED_NOTE = 6
local ACCEPTANCE_NOTE_VALUE_LOW = 48
local ACCEPTANCE_NOTE_VALUE_HIGH = 49
local COLD_SENTINEL_PHRASE_NAME = "Imported sentinel"
local FIRST_PHRASE_POSITION = 1
local FIRST_NOTE_LINE = 1
local FIRST_NOTE_COLUMN = 1
local UNDO_ACTION_WAIT_TIMEOUT_SECONDS = 10
local UNDO_PREPARATION_TIMEOUT_SECONDS = 30
local WORKFLOW_INSTRUMENT_COUNT = 3
local WORKFLOW_PHRASES_PER_INSTRUMENT = 4
local WORKFLOW_OWNED_PER_INSTRUMENT = 2
local WORKFLOW_FOREIGN_PER_INSTRUMENT = 2
local prepared_independence_undo = nil
local prepared_revision_undo = nil

local function has_eligibility(value)
  return value ~= nil and value ~= false
end

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

local function classify_write_eligibility(song, instrument, phrase)
  local context = context_for(song)
  local bound = context:bind_phrase(instrument, phrase)
  local target = context:target_state()
  local eligible, reason = context:musical_eligibility()
  local result = {
    bound = bound ~= nil and rawequal(bound.instrument, instrument) and rawequal(bound.phrase, phrase),
    classification = target and target.kind or "unavailable",
    reason = target and target.reason or reason,
    eligible = has_eligibility(eligible),
  }
  context:release_document()
  return result
end

local function source_record_removed(raw, id)
  if type(raw) ~= "string" then return nil end
  local retained, removed = {}, false
  for line in raw:gmatch("([^\n]*)\n") do
    if line:match("^" .. tostring(id) .. "|") then
      removed = true
    else
      retained[#retained + 1] = line
    end
  end
  if not removed then return nil end
  return table.concat(retained, "\n") .. "\n"
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

-- Let a synchronous writer's completion delivery return before starting the
-- next transaction. The first tick may still belong to the idle dispatch that
-- delivered the prior result.
local function after_delivery_idle(callback)
  local idle = renoise.tool().app_idle_observable
  local ticks = 0
  local notifier
  notifier = function()
    ticks = ticks + 1
    if ticks < 2 then return end
    pcall(function() idle:remove_notifier(notifier) end)
    callback()
  end
  idle:add_notifier(notifier)
end

-- Intern repeated native empty cells without hashing or dropping inactive data.
local function canonical_baseline(value)
  local definitions, interned = {}, {}
  local function encode(item)
    if type(item) == "string" then return string.format("%q", item) end
    if type(item) == "number" then return string.format("%.17g", item) end
    if type(item) ~= "table" then return tostring(item) end
    local keys, parts = {}, {}
    for key in pairs(item) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
      if type(a) ~= type(b) then return type(a) < type(b) end
      return a < b
    end)
    for _, key in ipairs(keys) do parts[#parts + 1] = encode(key) .. "=" .. encode(item[key]) end
    local contents = "{" .. table.concat(parts, ",") .. "}"
    if not interned[contents] then
      definitions[#definitions + 1] = contents
      interned[contents] = #definitions
    end
    return "@" .. tostring(interned[contents])
  end
  local root = encode(value)
  return table.concat(definitions, "\n") .. "\n" .. root
end

local function persisted_baseline(song)
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local instruments = {}
  for instrument_index, instrument in ipairs(song.instruments) do
    local phrases = {}
    for phrase_index, phrase in ipairs(instrument.phrases) do
      local id = ownership.id(phrase)
      local source, policy, pb = nil, nil, nil
      if id then source, policy, pb = store.read_entry(song, id) end
      local snapshot = ownership.snapshot(phrase)
      assert(snapshot, "Persisted baseline requires a complete phrase snapshot")
      phrases[phrase_index] = { id = id, snapshot = snapshot,
        source = source, output_policy = policy, pb_range = pb }
    end
    instruments[instrument_index] = { name = instrument.name, phrases = phrases }
  end
  local raw = song.tool_data or ""
  local hex = raw:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end)
  return canonical_baseline({ instruments = instruments, tool_data_hex = hex,
    tool_data_present = song.tool_data ~= nil })
end

local function save_independent_fixture(song, fixture_name)
  local name = fixture_name or "acceptance-independent.xrns"
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

local function add_cold_foreign_sentinel(song, source_phrase)
  local ownership = require("renoise.phrase_ownership")
  for instrument_index, instrument in ipairs(song.instruments) do
    if not rawequal(instrument, song.instruments[song.selected_instrument_index]) and
        #instrument.phrases == 0 then
      local phrase
      local created, create_error = pcall(function()
        phrase = instrument:insert_phrase_at(FIRST_PHRASE_POSITION)
        phrase:copy_from(source_phrase)
        phrase.name = COLD_SENTINEL_PHRASE_NAME
      end)
      if not created then
        if phrase then pcall(instrument.delete_phrase_at, instrument, FIRST_PHRASE_POSITION) end
        return nil, tostring(create_error)
      end
      local snapshot = ownership.snapshot(phrase)
      if not snapshot or ownership.id(phrase) or ownership.status(phrase) ~= "foreign" then
        pcall(instrument.delete_phrase_at, instrument, FIRST_PHRASE_POSITION)
        return nil, "Cold foreign sentinel did not remain source-less"
      end
      return {
        instrument = instrument,
        instrument_index = instrument_index,
        phrase = phrase,
        snapshot = snapshot,
      }
    end
  end
  return nil, "Cold fixture has no empty instrument for the foreign sentinel"
end

local function cleanup_independence_fixture(state)
  if not state then return end
  pcall(function() if state.context then state.context:release_document() end end)
  if state.preserve_fixture then
    pcall(function() state.duplicate.name = state.old_name end)
    pcall(function() state.song.tool_data = state.data_before end)
    return
  end
  pcall(function()
    local instrument = state.instrument
    for _, phrase in ipairs({ state.original, state.duplicate }) do
      if phrase then
        for index, candidate in ipairs(instrument.phrases) do
          if rawequal(candidate, phrase) then
            instrument:delete_phrase_at(index)
            break
          end
        end
      end
    end
    while state.phrase_count_before and #instrument.phrases > state.phrase_count_before do
      instrument:delete_phrase_at(#instrument.phrases)
    end
  end)
  pcall(function() state.song.tool_data = state.data_before end)
end

local function group_contains_exact_phrases(group, expected_phrases)
  if type(group) ~= "table" or #group ~= #expected_phrases then return false end
  local matched = {}
  for _, holder in ipairs(group) do
    local found
    for index, phrase in ipairs(expected_phrases) do
      if rawequal(holder.phrase, phrase) and not matched[index] then
        matched[index] = true
        found = true
        break
      end
    end
    if not found then return false end
  end
  return true
end

local function writer_rejects_regeneration_without_mutation(song, instrument_index, source,
    phrase, factory, writer, ownership)
  local instrument = song.instruments[instrument_index]
  local phrase_index
  for index, candidate in ipairs(instrument.phrases) do
    if rawequal(candidate, phrase) then phrase_index = index; break end
  end
  if not phrase_index then return false end
  local raw_before = song.tool_data
  local snapshot_before = ownership.snapshot(phrase)
  local build_ok, request = pcall(factory.build, song, instrument_index, source, phrase_index)
  if not build_ok or type(request) ~= "table" or request.kind ~= "regenerate" or
      (request.baseline ~= nil and (type(request.baseline) ~= "table" or
        request.baseline.id ~= request.id or rawget(request.baseline, "snapshot") ~= nil)) then
    return false
  end
  local callback_called = false
  local writer_called, accepted = pcall(writer.regenerate, request, function() callback_called = true end)
  local snapshot_after = ownership.snapshot(phrase)
  return writer_called and accepted == false and not callback_called and song.tool_data == raw_before and
    snapshot_before and snapshot_after and
    ownership.compare(snapshot_before, snapshot_after)
end

local function remove_undo_idle_notifier(state, field)
  local notifier = state and state[field]
  if not notifier then return end
  pcall(function() renoise.tool().app_idle_observable:remove_notifier(notifier) end)
  state[field] = nil
end

local function watch_prepared_independence(state)
  local idle = renoise.tool().app_idle_observable
  local deadline = os.time() + UNDO_PREPARATION_TIMEOUT_SECONDS
  local notifier
  notifier = function()
    if not rawequal(prepared_independence_undo, state) then
      remove_undo_idle_notifier(state, "watch_notifier")
      return
    end
    local current_ok, current_song = pcall(renoise.song)
    if not current_ok or not rawequal(current_song, state.song) or os.time() >= deadline then
      remove_undo_idle_notifier(state, "watch_notifier")
      prepared_independence_undo = nil
      if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
      cleanup_independence_fixture(state)
      return
    end
  end
  state.watch_notifier = notifier
  idle:add_notifier(notifier)
end

local function profile_independence_action(context, eligibility, ownership)
  local original_eligibility = eligibility.independence
  local original_snapshot = ownership.snapshot
  local metrics = {
    eligibility_calls = 0,
    eligibility_elapsed_ms = 0,
    snapshot_calls = 0,
    snapshot_elapsed_ms = 0,
  }
  eligibility.independence = function(...)
    local started = os.clock()
    metrics.eligibility_calls = metrics.eligibility_calls + 1
    local ok, result, reason = pcall(original_eligibility, ...)
    metrics.eligibility_elapsed_ms = metrics.eligibility_elapsed_ms +
      (os.clock() - started) * MILLISECONDS_PER_SECOND
    if not ok then error(result, 0) end
    return result, reason
  end
  ownership.snapshot = function(...)
    local started = os.clock()
    metrics.snapshot_calls = metrics.snapshot_calls + 1
    local ok, result, reason = pcall(original_snapshot, ...)
    metrics.snapshot_elapsed_ms = metrics.snapshot_elapsed_ms +
      (os.clock() - started) * MILLISECONDS_PER_SECOND
    if not ok then error(result, 0) end
    return result, reason
  end
  local started = os.clock()
  local called, changed, result = pcall(context.make_independent, context)
  metrics.action_elapsed_ms = (os.clock() - started) * MILLISECONDS_PER_SECOND
  pcall(function()
    eligibility.independence = original_eligibility
    ownership.snapshot = original_snapshot
  end)
  if not called then return nil, changed, metrics end
  return changed, result, metrics
end

local function run_three_holder_probe(song, instrument, original, duplicate, source,
    request, old_id, store, ownership, sequence, eligibility)
  local phrase_count_before = #instrument.phrases
  local store_bytes_before = song.tool_data
  local original_before = ownership.snapshot(original)
  local duplicate_before = ownership.snapshot(duplicate)
  local probe
  local context
  local metrics
  local passed, failure = pcall(function()
    probe = instrument:insert_phrase_at(#instrument.phrases + 1)
    probe:copy_from(original)
    probe.name = original.name
    local probe_before = ownership.snapshot(probe)
    local groups = ownership.inventory(song)
    if not probe_before or not original_before or not duplicate_before or
        not groups or not groups[old_id] or #groups[old_id] ~= THREE_HOLDER_COUNT then
      error("three-holder collision was not established", 0)
    end
    context = context_for(song)
    local bound = context:bind_phrase(instrument, probe)
    if not bound or not rawequal(bound.instrument, instrument) or not rawequal(bound.phrase, probe) then
      error("three-holder probe phrase could not be selected", 0)
    end
    local changed, outcome
    changed, outcome, metrics = profile_independence_action(context, eligibility, ownership)
    if not changed or type(outcome) ~= "table" then
      error(tostring(outcome or "three-holder Make Independent failed"), 0)
    end
    if metrics.eligibility_calls > MAXIMUM_ELIGIBILITY_PROOFS then
      error("three-holder action rebuilt redundant eligibility proofs", 0)
    end
    local probe_after = ownership.snapshot(probe)
    local original_after = ownership.snapshot(original)
    local duplicate_after = ownership.snapshot(duplicate)
    local groups_after = ownership.inventory(song)
    local old_source, old_policy, old_pb = store.read_entry(song, old_id)
    local new_source, new_policy, new_pb = store.read_entry(song, outcome.id)
    local probe_name = probe.name
    local expected_name = ownership.make_name(original, outcome.id)
    local selected_name_only = probe_after and ownership.compare(probe_before, probe_after, "name") and
      probe_name == expected_name and ownership.id(probe) == outcome.id
    local others_unchanged = original_after and duplicate_after and
      ownership.compare(original_before, original_after) and
      ownership.compare(duplicate_before, duplicate_after)
    local sources_preserved = old_source and new_source and
      sequence.same_source(old_source, source) and sequence.same_source(new_source, source) and
      old_policy == request.output_policy and new_policy == request.output_policy and
      old_pb == request.pb_range and new_pb == request.pb_range
    local holders_resolved = groups_after and groups_after[old_id] and #groups_after[old_id] == TWO_HOLDER_COUNT and
      groups_after[outcome.id] and #groups_after[outcome.id] == 1 and
      rawequal(groups_after[outcome.id][1].phrase, probe)
    if not (selected_name_only and others_unchanged and sources_preserved and holders_resolved) then
      error("three-holder resolution changed music, unrelated holders, or source state", 0)
    end
  end)
  if context then pcall(function() context:release_document() end) end
  local probe_index
  for index, phrase in ipairs(instrument.phrases) do
    if rawequal(phrase, probe) then probe_index = index; break end
  end
  if probe_index then
    local deleted, delete_error = pcall(instrument.delete_phrase_at, instrument, probe_index)
    if not deleted and passed then passed, failure = false, tostring(delete_error) end
  elseif passed then
    passed, failure = false, "three-holder probe phrase could not be found for cleanup"
  end
  local restored, restore_error = pcall(function() song.tool_data = store_bytes_before end)
  if not restored and passed then passed, failure = false, tostring(restore_error) end
  local restored_entry, restored_policy, restored_pb = store.read_entry(song, old_id)
  local restored_groups = ownership.inventory(song)
  local restored_original = ownership.snapshot(original)
  local restored_duplicate = ownership.snapshot(duplicate)
  local restored_pair_members = false
  local restored_group = restored_groups and restored_groups[old_id]
  if restored_group and #restored_group == TWO_HOLDER_COUNT then
    local original_found, duplicate_found = false, false
    for _, holder in ipairs(restored_group) do
      original_found = original_found or rawequal(holder.phrase, original)
      duplicate_found = duplicate_found or rawequal(holder.phrase, duplicate)
    end
    restored_pair_members = original_found and duplicate_found
  end
  local pair_restored = #instrument.phrases == phrase_count_before and song.tool_data == store_bytes_before and
    restored_entry and sequence.same_source(restored_entry, source) and
    restored_policy == request.output_policy and restored_pb == request.pb_range and
    restored_pair_members and restored_original and ownership.compare(original_before, restored_original) and
    restored_duplicate and ownership.compare(duplicate_before, restored_duplicate) and
    ownership.id(original) == old_id and ownership.id(duplicate) == old_id
  if not pair_restored and passed then passed, failure = false, "original collision pair or store was not restored" end
  if not passed then return nil, failure, metrics end
  return metrics
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
  local source = sequence.new_pattern(ACCEPTANCE_PATTERN_LENGTH)
  source.pitch_events[1] = sequence.new_pitch(ACCEPTANCE_GENERATED_NOTE, ACCEPTANCE_KEY, true, false)
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

    local eligibility = require("runtime.eligibility")
    local three_holder_profile, three_holder_error = run_three_holder_probe(
      song, instrument, original, duplicate, source, request, old_id, store, ownership,
      sequence, eligibility)
    if not three_holder_profile then
      done({ status = "FAIL", case = "make-independent", reason = tostring(three_holder_error) })
      return
    end

    local context = context_for(song)
    local observer = require("runtime.observers").new()
    local observer_notifications = 0
    observer:attach(song, context, function()
      observer_notifications = observer_notifications + 1
    end)
    local function release_context()
      observer:detach()
      context:close_dialog()
      context:release_document()
    end
    local bound = context:bind_phrase(instrument, duplicate)
    if not bound or not rawequal(bound.instrument, instrument) or not rawequal(bound.phrase, duplicate) then
      release_context()
      done({ status = "FAIL", case = "make-independent", reason = "copied phrase could not be selected" })
      return
    end
    local selected_instrument = song.selected_instrument
    local selected_phrase = song.selected_phrase
    local selected_instrument_index = song.selected_instrument_index
    local selected_phrase_index = song.selected_phrase_index
    local generation_calls = 0
    local original_create, original_regenerate = writer.create, writer.regenerate
    writer.create = function(...)
      generation_calls = generation_calls + 1
      return original_create(...)
    end
    writer.regenerate = function(...)
      generation_calls = generation_calls + 1
      return original_regenerate(...)
    end
    context:transition("arm")
    local proof, eligibility_error = context:independence_eligibility()
    if not proof then
      writer.create, writer.regenerate = original_create, original_regenerate
      release_context()
      done({ status = "FAIL", case = "make-independent", reason = tostring(eligibility_error) })
      return
    end
    local changed, outcome, two_holder_profile = profile_independence_action(context, eligibility, ownership)
    writer.create, writer.regenerate = original_create, original_regenerate
    if not changed or two_holder_profile.eligibility_calls > MAXIMUM_ELIGIBILITY_PROOFS then
      release_context()
      done({ status = "FAIL", case = "make-independent",
        reason = not changed and tostring(outcome) or "two-holder action rebuilt redundant eligibility proofs" })
      return
    end

    observer:refresh()
    local target_after_resolution = context:target_state()
    local selection_unchanged = rawequal(song.selected_instrument, selected_instrument) and
      rawequal(song.selected_phrase, selected_phrase) and
      song.selected_instrument_index == selected_instrument_index and
      song.selected_phrase_index == selected_phrase_index
    local resolution_target_preserved = rawequal(target_after_resolution.instrument, instrument) and
      rawequal(target_after_resolution.phrase, duplicate)
    local armed_after_resolution = context:revision_state().armed
    context:target_projection()
    context:independence_projection()
    context:reconcile()
    local unchanged_refresh_snapshot_calls = 0
    local original_snapshot = ownership.snapshot
    ownership.snapshot = function(...)
      unchanged_refresh_snapshot_calls = unchanged_refresh_snapshot_calls + 1
      return original_snapshot(...)
    end
    local refresh_ok, refresh_error = pcall(function()
      observer:refresh()
      context:target_projection()
      context:independence_projection()
      context:reconcile()
      context:target_projection()
      observer:refresh()
    end)
    ownership.snapshot = original_snapshot
    if not refresh_ok then
      release_context()
      done({ status = "FAIL", case = "make-independent",
        reason = "unchanged observer/display refresh failed: " .. tostring(refresh_error) })
      return
    end
    local original_classification = context:bind_phrase(instrument, original)
    local duplicate_target = context:bind_phrase(instrument, duplicate)
    local duplicate_classification = duplicate_target
    local observer_resolution_passed = generation_calls == 0 and selection_unchanged and
      armed_after_resolution and resolution_target_preserved and observer_notifications > 0 and
      unchanged_refresh_snapshot_calls == 0 and original_classification and
      original_classification.kind == "owned" and duplicate_classification and
      duplicate_classification.kind == "owned" and
      rawequal(duplicate_target.instrument, instrument) and rawequal(duplicate_target.phrase, duplicate)
    if not observer_resolution_passed then
      release_context()
      done({ status = "FAIL", case = "make-independent",
        reason = "identity resolution changed native selection, target, generation, holder classification, or refresh cost",
        generation_calls = generation_calls, selection_unchanged = selection_unchanged,
        armed = armed_after_resolution, observer_notifications = observer_notifications,
        unchanged_refresh_snapshot_calls = unchanged_refresh_snapshot_calls,
        original_classification = original_classification and original_classification.kind,
        duplicate_classification = duplicate_classification and duplicate_classification.kind })
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
      initial_old_id = old_id,
      independent_id_before_regenerate = outcome.id,
      new_id = ownership.id(duplicate),
      holders_before = TWO_HOLDER_COUNT,
      holders_after_old_id = groups and #groups[old_id] or 0,
      holders_after_new_id = groups and #groups[outcome.id] or 0,
      selected_content_preserved = selected_content_preserved == true,
      original_holder_unchanged = original_unchanged == true,
      source_and_settings_preserved = source_preserved == true,
      target_remains_selected = rawequal(target.instrument, instrument) and rawequal(target.phrase, duplicate),
      resolution_kept_live_edit_armed = armed_after_resolution,
      resolution_preserved_native_selection = selection_unchanged,
      resolution_preserved_bound_objects = resolution_target_preserved,
      resolution_made_no_generation = generation_calls == 0,
      unchanged_refresh_snapshot_calls = unchanged_refresh_snapshot_calls,
      observer_notifications = observer_notifications,
    }
    for metric, value in pairs(three_holder_profile) do
      details["three_holder_" .. metric] = value
    end
    for metric, value in pairs(two_holder_profile) do
      details["two_holder_" .. metric] = value
    end
    local changed_source = sequence.copy_source(source)
    changed_source.pitch_events[FIRST_NOTE_LINE] = sequence.new_pitch(
      ACCEPTANCE_INDEPENDENT_NOTE, ACCEPTANCE_KEY, true, false)
    local duplicate_index
    for index, phrase in ipairs(instrument.phrases) do
      if rawequal(phrase, duplicate) then duplicate_index = index; break end
    end
    local regenerate_request, regenerate_error = factory.build(song, instrument_index,
      changed_source, duplicate_index)
    if not regenerate_request or regenerate_request.kind ~= "regenerate" then
      details.status = "FAIL"
      details.reason = describe_failure(regenerate_error or "independent target did not build a regenerate request")
      release_context()
      done(details)
      return
    end
    local regenerate_accepted, regenerate_start_error = writer.regenerate(regenerate_request, function(regenerated)
      local regenerated_id = type(regenerated) == "table" and regenerated.id or nil
      if type(regenerated) ~= "table" or regenerated.kind ~= "success" or
          regenerated.verified ~= true or not rawequal(regenerated.phrase, duplicate) or
          not regenerated_id or regenerated_id == outcome.id then
        details.status = "FAIL"
        details.regenerate_error = describe_failure(regenerated or "regeneration did not return the same verified phrase with a fresh revision")
        release_context()
        done(details)
        return
      end
        local regenerated_snapshot = ownership.snapshot(duplicate)
        local regenerated_source, regenerated_policy, regenerated_pb = store.read_entry(song, regenerated_id)
        local historical_source, historical_policy, historical_pb = store.read_entry(song, outcome.id)
        local regenerated_groups = ownership.inventory(song)
        local original_after_regenerate = ownership.snapshot(original)
        details.regenerated_same_object = rawequal(regenerated.phrase, duplicate)
        details.previous_independent_id = outcome.id
        details.new_id = regenerated_id
        details.phrase_count_after_regenerate = #instrument.phrases
        details.source_changed_by_regenerate = regenerated_source and
          sequence.same_source(regenerated_source, changed_source) or false
        details.regenerate_settings_preserved = regenerated_policy == request.output_policy and
          regenerated_pb == request.pb_range
        details.previous_source_preserved = historical_source and sequence.same_source(historical_source, new_source) and
          historical_policy == request.output_policy and historical_pb == request.pb_range
        details.original_holder_unchanged_after_regenerate = original_after_regenerate and
          ownership.compare(original_before, original_after_regenerate)
        details.holders_after_regenerate = regenerated_groups and regenerated_groups[regenerated_id] and
          #regenerated_groups[regenerated_id] or 0
        details.previous_holders_after_regenerate = regenerated_groups and regenerated_groups[outcome.id] and
          #regenerated_groups[outcome.id] or 0
        local regenerate_passed = details.regenerated_same_object and
          details.phrase_count_after_regenerate == 2 and regenerated_snapshot ~= nil and
          details.source_changed_by_regenerate and details.regenerate_settings_preserved and
          details.previous_source_preserved and details.previous_holders_after_regenerate == 0 and
          ownership.id(duplicate) == regenerated_id and
          details.original_holder_unchanged_after_regenerate and
          details.holders_after_regenerate == 1
        details.status = identity_passed and regenerate_passed and "PASS" or "FAIL"
        details.case = "make-independent"
        details.regeneration_preserved_same_phrase = regenerate_passed == true
        if details.status == "FAIL" then
          release_context()
          done(details)
          return
        end
        local function finish_save()
          local sentinel, sentinel_error = add_cold_foreign_sentinel(song, duplicate)
          if not sentinel then
            details.status = "FAIL"
            details.sentinel_error = sentinel_error
            release_context()
            done(details)
            return
          end
          details.saved_baseline = persisted_baseline(song)
          local saved, save_error = save_independent_fixture(song)
          if not saved then
            details.status = "FAIL"
            details.save_error = save_error
          else
            details.roundtrip_fixture = saved.fixture
            details.roundtrip_bytes = saved.bytes
            details.foreign_sentinel_saved = true
            details.foreign_sentinel_instrument_index = sentinel.instrument_index
            details.foreign_sentinel_phrase_name = sentinel.phrase.name
            details.primary_instrument_phrase_count = #instrument.phrases
          end
          context:close_dialog()
          context:release_document()
          observer:detach()
          details.observer_detached_after_release = not observer:state().attached and observer:refresh() == false
          if not details.observer_detached_after_release then
            details.status = "FAIL"
            details.reason = "native observer remained active after document release"
          end
          done(details)
        end

        after_delivery_idle(function()
          local original_index
          for index, phrase in ipairs(instrument.phrases) do
            if rawequal(phrase, original) then original_index = index; break end
          end
          local original_request, original_request_error = factory.build(song, instrument_index, source, original_index)
          if not original_request or original_request.kind ~= "regenerate" then
            details.status = "FAIL"
            details.original_regenerate_error = describe_failure(original_request_error or
              "original owned phrase did not build a regenerate request")
            release_context()
            done(details)
            return
          end
          local original_snapshot_before = ownership.snapshot(original)
          local duplicate_snapshot_before = ownership.snapshot(duplicate)
          local duplicate_id_before_original_regenerate = regenerated_id
          local original_id_before_regenerate = ownership.id(original)
          local original_accepted, original_start_error = writer.regenerate(original_request, function(original_result)
            local original_regenerated_id = type(original_result) == "table" and original_result.id or nil
            local original_source_after, original_policy_after, original_pb_after
            if original_regenerated_id then
              original_source_after, original_policy_after, original_pb_after = store.read_entry(song, original_regenerated_id)
            end
            local original_historical_source, original_historical_policy, original_historical_pb = store.read_entry(song, old_id)
            local duplicate_source_after, duplicate_policy_after, duplicate_pb_after =
              store.read_entry(song, duplicate_id_before_original_regenerate)
            local duplicate_historical_source, duplicate_historical_policy, duplicate_historical_pb =
              store.read_entry(song, outcome.id)
            local original_snapshot_after = ownership.snapshot(original)
            local duplicate_snapshot_after = ownership.snapshot(duplicate)
            local original_groups = ownership.inventory(song)
            local original_regenerated = type(original_result) == "table" and
              original_result.kind == "success" and original_result.verified == true and
              rawequal(original_result.phrase, original)
            local original_unchanged = original_snapshot_before and original_snapshot_after and
              original_snapshot_before.name ~= original_snapshot_after.name and
              ownership.compare(original_snapshot_before, original_snapshot_after, "name")
            local independent_duplicate_unchanged = duplicate_snapshot_before and duplicate_snapshot_after and
              ownership.id(duplicate) == duplicate_id_before_original_regenerate and
              ownership.compare(duplicate_snapshot_before, duplicate_snapshot_after) and
              duplicate_source_after and sequence.same_source(duplicate_source_after, changed_source) and
              duplicate_policy_after == request.output_policy and duplicate_pb_after == request.pb_range and
              duplicate_historical_source and sequence.same_source(duplicate_historical_source, new_source) and
              duplicate_historical_policy == request.output_policy and duplicate_historical_pb == request.pb_range
            local original_source_preserved = original_source_after and
              sequence.same_source(original_source_after, source) and
              original_policy_after == request.output_policy and original_pb_after == request.pb_range
            local original_historical_source_preserved = original_historical_source and
              sequence.same_source(original_historical_source, source) and
              original_historical_policy == request.output_policy and original_historical_pb == request.pb_range
            local original_groups_preserved = original_groups and original_regenerated_id and
              original_regenerated_id ~= original_id_before_regenerate and
              ownership.id(original) == original_regenerated_id and original_groups[original_regenerated_id] and
              #original_groups[original_regenerated_id] == 1 and
              rawequal(original_groups[original_regenerated_id][1].phrase, original) and
              original_groups[duplicate_id_before_original_regenerate] and
              #original_groups[duplicate_id_before_original_regenerate] == 1 and
              rawequal(original_groups[duplicate_id_before_original_regenerate][1].phrase, duplicate) and
              original_groups[old_id] == nil and original_groups[outcome.id] == nil
            local original_count_unchanged = #instrument.phrases == TWO_HOLDER_COUNT
            local original_regeneration_passed = original_regenerated and original_unchanged and
              independent_duplicate_unchanged and original_source_preserved and
              original_historical_source_preserved and original_groups_preserved and original_count_unchanged
            details.previous_original_id = old_id
            details.old_id = original_regenerated_id
            details.original_regenerated_same_object = original_regenerated == true
            details.original_regenerated_content_unchanged = original_unchanged == true
            details.original_regenerated_revision_name_changed = original_snapshot_before and
              original_snapshot_after and original_snapshot_before.name ~= original_snapshot_after.name or false
            details.duplicate_unchanged_during_original_regeneration = independent_duplicate_unchanged == true
            details.original_source_and_settings_preserved = original_source_preserved == true
            details.previous_original_source_preserved = original_historical_source_preserved == true
            details.original_regeneration_preserved_independent_associations = original_groups_preserved == true
            details.original_regeneration_created_fresh_revision = original_regenerated_id ~= nil and
              original_regenerated_id ~= original_id_before_regenerate
            details.original_regeneration_phrase_count_unchanged = original_count_unchanged
            if not original_regeneration_passed then
              details.status = "FAIL"
              details.original_regenerate_error = original_regenerated and
                "Original regeneration changed its peer, source association, store, or phrase inventory" or
                describe_failure(original_result or "original regeneration did not succeed")
              release_context()
              done(details)
              return
            end
            finish_save()
          end)
          if not original_accepted then
            details.status = "FAIL"
            details.original_regenerate_error = describe_failure(original_start_error)
            release_context()
            done(details)
            return
          end
        end)
    end)
    if not regenerate_accepted then
      details.status = "FAIL"
      details.regenerate_error = describe_failure(regenerate_start_error)
      release_context()
      done(details)
    end
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

local function run_ownership_negatives(done, donor_only)
  local song = renoise.song()
  local instrument_index = song.selected_instrument_index
  local instrument = song.instruments[instrument_index]
  local sequence = require("model.sequencer")
  local store = require("renoise.pattern_store")
  local ownership = require("renoise.phrase_ownership")
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local writer = require("writers.phrase_writer")
  local source = sequence.new_pattern(ACCEPTANCE_PATTERN_LENGTH)
  source.pitch_events[1] = sequence.new_pitch(ACCEPTANCE_GENERATED_NOTE, ACCEPTANCE_KEY, true, false)
  local request, request_error = factory.build(song, instrument_index, source)
  if not request then
    done({ status = "FAIL", case = "ownership-negatives", reason = describe_failure(request_error) })
    return true
  end

  local phrase_count_before = #instrument.phrases
  local store_before = song.tool_data
  local test_phrases = {}
  local function reject_regeneration(phrase)
    return writer_rejects_regeneration_without_mutation(song, instrument_index, source,
      phrase, factory, writer, ownership)
  end
  local function cleanup()
    for _, phrase in ipairs(test_phrases) do
      local phrase_index
      for index, candidate in ipairs(instrument.phrases) do
        if rawequal(candidate, phrase) then phrase_index = index; break end
      end
      if phrase_index then pcall(instrument.delete_phrase_at, instrument, phrase_index) end
    end
    pcall(function() song.tool_data = store_before end)
  end
  local function finish(passed, details)
    cleanup()
    local restored = #instrument.phrases == phrase_count_before and song.tool_data == store_before
    if donor_only then
      local saved, save_error = save_independent_fixture(song, "acceptance-donor.xrns")
      if not saved then passed = false; details.reason = save_error end
    end
    details.cleanup_restored_fixture = restored
    if not restored then passed = false end
    details.status = passed and "PASS" or "FAIL"
    details.case = donor_only and "import-donor" or "ownership-negatives"
    done(details)
  end

  local accepted, start_error = writer.create(request, function(result)
    on_next_idle(function()
      local case_ok, case_error = pcall(function()
      if type(result) ~= "table" or result.kind ~= "success" or result.verified ~= true or
          not result.phrase then
        finish(false, { reason = describe_failure(result or "writer create failed") })
        return
      end
      local original = result.phrase
      test_phrases[#test_phrases + 1] = original
      local donor_path = renoise.tool().bundle_path .. "\\__dev\\import-donor.xrni"
      if donor_only then
        local donor_id = 42
        local name = ownership.make_name(original, donor_id)
        local saved_source = store.save(song, donor_id, source, request.output_policy, request.pb_range)
        original.name = assert(name)
        song.selected_instrument_index = instrument_index
        local exported = saved_source and renoise.app():save_instrument(donor_path)
        finish(exported == true, { donor_phrase = canonical_baseline(ownership.snapshot(original)),
          donor_id = donor_id, native_instrument_exported = exported == true })
        return
      end
      local recipient_before = persisted_baseline(song)
      local recipient_data = song.tool_data
      local recipient_instrument_count = #song.instruments
      local imported_index = recipient_instrument_count + 1
      song:insert_instrument_at(imported_index)
      song.selected_instrument_index = imported_index
      local loaded = renoise.app():load_instrument(donor_path)
      local imported_instrument = song.instruments[imported_index]
      local imported = imported_instrument.phrases[1]
      local imported_snapshot = imported and ownership.snapshot(imported)
      local imported_baseline = imported_snapshot and canonical_baseline(imported_snapshot)
      local import_context = context_for(song)
      local import_bound = imported and import_context:bind_phrase(imported_instrument, imported)
      local independent, independent_error = false, nil
      if import_bound then independent, independent_error = import_context:make_independent() end
      import_context:release_document()
      local import_details = { loaded = loaded, id = imported and ownership.id(imported),
        status = imported and ownership.status(imported), source_missing = not store.read_entry(song, 42),
        independent_refused = not independent, independent_reason = describe_failure(independent_error),
        tool_data_unchanged = song.tool_data == recipient_data }
      local imported_rejected = loaded and imported and ownership.id(imported) == 42 and
        ownership.status(imported) == "owned" and not store.read_entry(song, 42) and
        not independent and independent_error ~= nil and
        writer_rejects_regeneration_without_mutation(song, imported_index, source,
          imported, factory, writer, ownership) and song.tool_data == recipient_data and
        ownership.compare(imported_snapshot, ownership.snapshot(imported))
      song:delete_instrument_at(imported_index)
      while #song.instruments > recipient_instrument_count do
        assert(#song.instruments[#song.instruments].phrases == 0,
          "Unexpected phrase in the native import's trailing instrument slot")
        song:delete_instrument_at(#song.instruments)
      end
      song.selected_instrument_index = instrument_index
      imported_rejected = imported_rejected and recipient_before == persisted_baseline(song)
      import_details.recipient_preserved = recipient_before == persisted_baseline(song)
      if not import_details.recipient_preserved then
        import_details.recipient_before = recipient_before
        import_details.recipient_after = persisted_baseline(song)
      end
      os.remove(donor_path)
      local original_id = ownership.id(original)
      local original_snapshot = ownership.snapshot(original)
      if not original_id or not original_snapshot then
        finish(false, { reason = "created phrase identity or snapshot is unavailable" })
        return
      end

      local function copy_holder(name)
        local phrase = instrument:insert_phrase_at(#instrument.phrases + 1)
        test_phrases[#test_phrases + 1] = phrase
        phrase:copy_from(original)
        phrase.name = name or original.name
        return phrase
      end

      local duplicate = copy_holder()
      local pair_groups = ownership.inventory(song)
      local duplicate_state = classify_write_eligibility(song, instrument, duplicate)
      local original_pair_state = classify_write_eligibility(song, instrument, original)
      local pair_blocked = pair_groups and pair_groups[original_id] and
        #pair_groups[original_id] == TWO_HOLDER_COUNT and
        duplicate_state.classification == "unavailable" and not duplicate_state.eligible and
        original_pair_state.classification == "unavailable" and not original_pair_state.eligible and
        reject_regeneration(original) and reject_regeneration(duplicate)

      local third = copy_holder()
      local third_groups = ownership.inventory(song)
      local third_state = classify_write_eligibility(song, instrument, third)
      local three_blocked = third_groups and third_groups[original_id] and
        #third_groups[original_id] == THREE_HOLDER_COUNT and
        third_state.classification == "unavailable" and not third_state.eligible and
        reject_regeneration(third)

      local note = duplicate:line(FIRST_NOTE_LINE):note_column(FIRST_NOTE_COLUMN)
      note.note_value = note.note_value == ACCEPTANCE_NOTE_VALUE_LOW and
        ACCEPTANCE_NOTE_VALUE_HIGH or ACCEPTANCE_NOTE_VALUE_LOW
      local mismatch_snapshot = ownership.snapshot(duplicate)
      local mismatched_groups = ownership.inventory(song)
      local mismatch_states = {
        original = classify_write_eligibility(song, instrument, original),
        duplicate = classify_write_eligibility(song, instrument, duplicate),
        third = classify_write_eligibility(song, instrument, third),
      }
      local mismatch_blocked = mismatch_snapshot and
        not ownership.compare(original_snapshot, mismatch_snapshot, "exact") and
        mismatched_groups and mismatched_groups[original_id] and
        #mismatched_groups[original_id] == THREE_HOLDER_COUNT and
        mismatch_states.original.classification == "unavailable" and not mismatch_states.original.eligible and
        mismatch_states.duplicate.classification == "unavailable" and not mismatch_states.duplicate.eligible and
        mismatch_states.third.classification == "unavailable" and not mismatch_states.third.eligible and
        reject_regeneration(original) and reject_regeneration(duplicate) and reject_regeneration(third)

      local foreign = copy_holder("Imported phrase")
      local foreign_state = classify_write_eligibility(song, instrument, foreign)
      local foreign_blocked = ownership.id(foreign) == nil and
        foreign_state.classification == "foreign" and not foreign_state.eligible and
        reject_regeneration(foreign)

      for _, phrase in ipairs({ third, duplicate, foreign }) do
        for index, candidate in ipairs(instrument.phrases) do
          if rawequal(candidate, phrase) then
            instrument:delete_phrase_at(index)
            break
          end
        end
      end

      local raw_before_missing = song.tool_data
      local without_source = source_record_removed(raw_before_missing, original_id)
      local missing_set = without_source and pcall(function() song.tool_data = without_source end)
      local missing_state = missing_set and classify_write_eligibility(song, instrument, original) or nil
      local source_less_blocked = missing_set and not store.read_entry(song, original_id) and
        missing_state and missing_state.classification == "unavailable" and
        not missing_state.eligible and reject_regeneration(original)
      local source_restored = pcall(function() song.tool_data = raw_before_missing end)

      finish(imported_rejected and pair_blocked and three_blocked and mismatch_blocked and foreign_blocked and source_less_blocked and source_restored, {
        native_cross_song_import_blocked = imported_rejected == true,
        imported_donor_phrase = imported_baseline,
        import_details = import_details,
        original_id = original_id,
        pair_holder_count = pair_groups and #pair_groups[original_id] or 0,
        pair_blocked = pair_blocked == true,
        three_holder_count = third_groups and #third_groups[original_id] or 0,
        three_holder_blocked = three_blocked == true,
        mismatching_holder_blocked = mismatch_blocked == true,
        mismatch_classifications = {
          original = mismatch_states.original.classification,
          duplicate = mismatch_states.duplicate.classification,
          third = mismatch_states.third.classification,
        },
        source_less_foreign_blocked = foreign_blocked == true,
        missing_source_record_blocked = source_less_blocked == true,
        missing_source_record_restored = source_restored == true,
      })
      end)
      if not case_ok then finish(false, { reason = tostring(case_error) }) end
    end)
  end)
  if not accepted then
    finish(false, { reason = describe_failure(start_error) })
  end
  return true
end

local function run_independence_undo_prepare(done, fixture_only)
  if prepared_independence_undo then
    remove_undo_idle_notifier(prepared_independence_undo, "watch_notifier")
    if prepared_independence_undo.dialog and prepared_independence_undo.dialog.visible then
      pcall(prepared_independence_undo.dialog.close, prepared_independence_undo.dialog)
    end
    cleanup_independence_fixture(prepared_independence_undo)
    prepared_independence_undo = nil
  end
  local song = renoise.song()
  local instrument_index = song.selected_instrument_index
  local instrument = song.instruments[instrument_index]
  local sequence = require("model.sequencer")
  local store = require("renoise.pattern_store")
  local ownership = require("renoise.phrase_ownership")
  local writer = require("writers.phrase_writer")
  local source = sequence.new_pattern(ACCEPTANCE_PATTERN_LENGTH)
  source.pitch_events[1] = sequence.new_pitch(ACCEPTANCE_GENERATED_NOTE, ACCEPTANCE_KEY, true, false)
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local request, request_error = factory.build(song, instrument_index, source)
  if not request then
    done({ status = "FAIL", case = "independence-undo-prepare", reason = describe_failure(request_error) })
    return true
  end
  local phrase_count_before = #instrument.phrases
  local data_before = song.tool_data
  local function prepared(result)
    on_next_idle(function()
      if type(result) ~= "table" or result.kind ~= "success" or result.verified ~= true or not result.phrase then
        cleanup_independence_fixture({ song = song, instrument = instrument,
          phrase_count_before = phrase_count_before, data_before = data_before })
        done({ status = "FAIL", case = "independence-undo-prepare", reason = describe_failure(result) })
        return
      end
      local original = result.phrase
      local duplicate = instrument.phrases[2]
      if fixture_only then
        duplicate = instrument:insert_phrase_at(#instrument.phrases + 1)
        duplicate:copy_from(original)
        duplicate.name = original.name
        local saved, save_error = save_independent_fixture(song, "acceptance-undo.xrns")
        done({ status = saved and "PASS" or "FAIL", case = "independence-undo-fixture",
          reason = save_error, roundtrip_fixture = saved and saved.fixture })
        return
      end
      if #instrument.phrases ~= 2 or song:can_undo() or song:can_redo() then
        done({ status = "FAIL", case = "independence-undo-prepare",
          reason = "Undo acceptance requires a reopened collision fixture with empty history" })
        return
      end
      local context = context_for(song)
      local bound = context:bind_phrase(instrument, duplicate)
      local proof = bound and context:independence_eligibility()
      local old_id = ownership.id(original)
      local before_source, before_policy, before_pb = store.read_entry(song, old_id)
      local state = {
        song = song,
        instrument = instrument,
        instrument_index = instrument_index,
        original = original,
        duplicate = duplicate,
        source = source,
        factory = factory,
        context = context,
        phrase_count_before = phrase_count_before,
        data_before = data_before,
        pre_resolution_data = song.tool_data,
        old_id = old_id,
        old_name = duplicate.name,
        before_snapshot = ownership.snapshot(duplicate),
        before_source = before_source,
        before_policy = before_policy,
        before_pb = before_pb,
        preserve_fixture = true,
        fixture_baseline = persisted_baseline(song),
        key_event_summary = "",
      }
      if not proof then
        cleanup_independence_fixture(state)
        done({ status = "FAIL", case = "independence-undo-prepare",
          reason = "Native collision was not eligible for Make Independent" })
        return
      end
      local dialog
      local function perform_from_user_action()
        if state.action_result then return end
        local called, changed, outcome = pcall(context.make_independent, context)
        state.action_result = { called = called, changed = changed, outcome = outcome }
        if dialog and dialog.visible then pcall(dialog.close, dialog) end
      end
      local vb = renoise.ViewBuilder()
      local content = vb:column {
        margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN,
        spacing = renoise.ViewBuilder.DEFAULT_DIALOG_SPACING,
      }
      content:add_view(vb:text { text = "Press Enter or click the button to resolve the selected collision." })
      content:add_view(vb:button { text = "Make Independent", notifier = perform_from_user_action })
      local function key_handler(_, key_event)
        local key_state = key_event.state or "pressed"
        state.key_event_summary = tostring(key_event.name) .. ":" .. key_state
        if (key_event.name == "enter" or key_event.name == "return") and key_state ~= "released" then
          perform_from_user_action()
          return nil
        end
        return key_event
      end
      local shown, show_error = pcall(function()
        dialog = renoise.app():show_custom_dialog("ACID native undo acceptance", content, key_handler,
          { send_key_repeat = false, send_key_release = false })
      end)
      if not shown or not dialog then
        cleanup_independence_fixture(state)
        done({ status = "FAIL", case = "independence-undo-prepare",
          reason = tostring(show_error or "Native action dialog did not open") })
        return
      end
      state.dialog = dialog
      prepared_independence_undo = state
      watch_prepared_independence(state)
      done({ status = "PASS", case = "independence-undo-prepare", action_ready = true,
        dialog_visible = dialog.visible, focused = dialog.focused })
    end)
  end
  if not fixture_only then
    prepared({ kind = "success", verified = true, phrase = instrument.phrases[1] })
    return true
  end
  local accepted, start_error = writer.create(request, prepared)
  if not accepted then
    done({ status = "FAIL", case = "independence-undo-prepare", reason = describe_failure(start_error) })
  end
  return true
end

local continue_independence_undo

local function run_independence_undo(done)
  local state = prepared_independence_undo
  if not state then
    done({ status = "FAIL", case = "independence-undo", reason = "Native Make Independent action was not prepared" })
    return true
  end
  local same_document, current_song = pcall(renoise.song)
  if not same_document or not rawequal(current_song, state.song) then
    remove_undo_idle_notifier(state, "watch_notifier")
    if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
    prepared_independence_undo = nil
    cleanup_independence_fixture(state)
    done({ status = "FAIL", case = "independence-undo", reason = "Prepared song changed before native action readback" })
    return true
  end
  local function wait_for_action()
    local idle = renoise.tool().app_idle_observable
    local deadline = os.time() + UNDO_ACTION_WAIT_TIMEOUT_SECONDS
    local notifier
    notifier = function()
    local current_ok, current = pcall(renoise.song)
    if not current_ok or not rawequal(current, state.song) then
      pcall(function() idle:remove_notifier(notifier) end)
      prepared_independence_undo = nil
      remove_undo_idle_notifier(state, "watch_notifier")
      if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
      cleanup_independence_fixture(state)
      done({ status = "FAIL", case = "independence-undo", reason = "Prepared song changed before native action readback" })
      return
    end
    if state.action_result then
      pcall(function() idle:remove_notifier(notifier) end)
      prepared_independence_undo = nil
      remove_undo_idle_notifier(state, "watch_notifier")
      continue_independence_undo(state, done)
      return
    end
    if os.time() >= deadline then
      pcall(function() idle:remove_notifier(notifier) end)
      prepared_independence_undo = nil
      remove_undo_idle_notifier(state, "watch_notifier")
      if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
      cleanup_independence_fixture(state)
      done({ status = "FAIL", case = "independence-undo", reason = "User action did not complete Make Independent",
        action_ready = true, action_called = false, key_event_summary = state.key_event_summary,
        dialog_visible = state.dialog and state.dialog.visible or false,
        dialog_focused = state.dialog and state.dialog.focused or false })
      return
    end
    end
    idle:add_notifier(notifier)
  end
  wait_for_action()
  return true
end

continue_independence_undo = function(state, done)
  if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
  local action = state.action_result
  local song, instrument, duplicate = state.song, state.instrument, state.duplicate
  local sequence = require("model.sequencer")
  local store = require("renoise.pattern_store")
  local ownership = require("renoise.phrase_ownership")
  local writer = require("writers.phrase_writer")
  local function cleanup() cleanup_independence_fixture(state) end
  if not action or not action.called or not action.changed or type(action.outcome) ~= "table" then
    cleanup()
    done({ status = "FAIL", case = "independence-undo", reason = "User action did not complete Make Independent",
      action_ready = true, action_called = action and action.called or false,
      action_error = action and describe_failure(action.outcome) or nil,
      key_event_summary = state.key_event_summary })
    return true
  end
  local outcome = action.outcome
  local new_id = outcome.id
  local after_snapshot = ownership.snapshot(duplicate)
  local after_source, after_policy, after_pb = store.read_entry(song, new_id)
  local post_resolution_data = song.tool_data
  local post_resolution_baseline = persisted_baseline(song)
  local can_undo_after_action = song:can_undo()
  local content_matches = after_snapshot and ownership.compare(state.before_snapshot, after_snapshot, "name") or false
  local id_matches = ownership.id(duplicate) == new_id
  local source_matches = after_source and state.before_source and sequence.same_source(after_source, state.before_source) or false
  local settings_match = after_policy == state.before_policy and after_pb == state.before_pb
  if not (can_undo_after_action and content_matches and id_matches and source_matches and settings_match) then
    cleanup()
    done({ status = "FAIL", case = "independence-undo", reason = "User action did not produce an exact undoable post-state",
      can_undo_after_action = can_undo_after_action, content_matches = content_matches,
      id_matches = id_matches, source_matches = source_matches, settings_match = settings_match,
      phrase_id = ownership.id(duplicate), new_id = new_id })
    return true
  end
  local undo_called, undo_error = pcall(function() song:undo() end)
  if not undo_called then
    cleanup()
    done({ status = "FAIL", case = "independence-undo", reason = tostring(undo_error) })
    return true
  end
  on_next_idle(function()
    local undo_data = song.tool_data
    local undo_snapshot = ownership.snapshot(duplicate)
    local undo_original_snapshot = ownership.snapshot(state.original)
    local undo_source, undo_policy, undo_pb = store.read_entry(song, state.old_id)
    local undo_new_source, undo_new_policy, undo_new_pb = store.read_entry(song, new_id)
    local undo_groups = ownership.inventory(song)
    local undo_state = classify_write_eligibility(song, instrument, duplicate)
    local undo_original_state = classify_write_eligibility(song, instrument, state.original)
    local function reject_undo_regeneration(phrase, snapshot_before)
      return writer_rejects_regeneration_without_mutation(song, state.instrument_index, state.source,
        phrase, state.factory, writer, ownership) and song.tool_data == undo_data and snapshot_before and
        ownership.compare(snapshot_before, ownership.snapshot(phrase))
    end
    local undo_duplicate_rejected = reject_undo_regeneration(duplicate, undo_snapshot)
    local undo_original_rejected = reject_undo_regeneration(state.original, undo_original_snapshot)
    local undo_data_mode = undo_data == state.pre_resolution_data and "pre_resolution_restored" or
      undo_data == post_resolution_data and "post_make_independent_retained" or "unexpected"
    local undo_old_association_matches = undo_source and state.before_source and
      sequence.same_source(undo_source, state.before_source) and undo_policy == state.before_policy and
      undo_pb == state.before_pb
    local undo_new_association_matches = undo_new_source and state.before_source and
      sequence.same_source(undo_new_source, state.before_source) and undo_new_policy == after_policy and
      undo_new_pb == after_pb
    local undo_store_safe = undo_old_association_matches and
      ((undo_data_mode == "pre_resolution_restored") or
        (undo_data_mode == "post_make_independent_retained" and undo_new_association_matches))
    local undo_restored = undo_snapshot and undo_original_snapshot and
      ownership.compare(state.before_snapshot, undo_snapshot) and duplicate.name == state.old_name and
      ownership.compare(state.before_snapshot, undo_original_snapshot) and
      ownership.id(duplicate) == state.old_id and undo_groups and
      group_contains_exact_phrases(undo_groups[state.old_id], { state.original, duplicate })
    local undo_requests_rejected = undo_duplicate_rejected and undo_original_rejected
    local undo_safe = undo_restored and undo_store_safe and undo_requests_rejected and
      undo_state.classification == "unavailable" and not undo_state.eligible and
      undo_original_state.classification == "unavailable" and not undo_original_state.eligible and
      song.tool_data == undo_data
    local can_redo = song:can_redo()
    if not can_redo then
      cleanup()
      done({ status = "FAIL", case = "independence-undo", reason = "Make Independent undo created no redo state",
        undo_restored = undo_restored == true, undo_safe = undo_safe == true,
        undo_store_mode = undo_data_mode,
        undo_original_blocked = undo_original_state.classification == "unavailable" and not undo_original_state.eligible,
        undo_duplicate_blocked = undo_state.classification == "unavailable" and not undo_state.eligible })
      return
    end
    local history = {
      { direction = "before_action", baseline = state.fixture_baseline, safe = true },
      { direction = "after_action", baseline = post_resolution_baseline, safe = true },
      { direction = "undo", baseline = persisted_baseline(song), safe = undo_safe == true },
    }
    local undo_count, redo_count, history_safe = 1, 0, undo_safe
    local function walk_history(completed)
      local direction = song:can_undo() and redo_count == 0 and "undo" or "redo"
      if direction == "redo" and not song:can_redo() then completed(); return end
      if #history >= 32 then
        cleanup()
        done({ status = "FAIL", case = "independence-undo", reason = "Native undo chain exceeded its bound", history = canonical_baseline(history) })
        return
      end
      song[direction](song)
      if direction == "undo" then undo_count = undo_count + 1 else redo_count = redo_count + 1 end
      on_next_idle(function()
        local before = persisted_baseline(song)
        local safe = #instrument.phrases == TWO_HOLDER_COUNT
        for _, phrase in ipairs(instrument.phrases) do
          local target = classify_write_eligibility(song, instrument, phrase)
          local id = ownership.id(phrase)
          local snapshot = ownership.snapshot(phrase)
          safe = safe and (id == state.old_id or id == new_id) and snapshot and
            ownership.compare(state.before_snapshot, snapshot, "name")
          if target.classification ~= "owned" or not target.eligible then
            safe = writer_rejects_regeneration_without_mutation(song, state.instrument_index,
              state.source, phrase, state.factory, writer, ownership) and safe
          else
            local source, policy, pb = store.read_entry(song, id)
            safe = safe and source and sequence.same_source(source, state.before_source) and
              policy == state.before_policy and pb == state.before_pb
          end
        end
        safe = safe and before == persisted_baseline(song)
        history_safe = history_safe and safe
        history[#history + 1] = { direction = direction, baseline = before, safe = safe == true }
        walk_history(completed)
      end)
    end
    walk_history(function()
      local redo_data = song.tool_data
      local redo_snapshot = ownership.snapshot(duplicate)
      local redo_new_source, redo_new_policy, redo_new_pb = store.read_entry(song, new_id)
      local redo_old_source = store.read_entry(song, state.old_id)
      local redo_groups = ownership.inventory(song)
      local redo_state = classify_write_eligibility(song, instrument, duplicate)
      local redo_store_matches = redo_data == post_resolution_data
      local redo_restored = redo_snapshot and ownership.compare(state.before_snapshot, redo_snapshot, "name") and
        ownership.id(duplicate) == new_id and redo_new_source and
        sequence.same_source(redo_new_source, state.before_source) and redo_new_policy == after_policy and
        redo_new_pb == after_pb and redo_old_source and sequence.same_source(redo_old_source, state.before_source) and
        redo_groups and group_contains_exact_phrases(redo_groups[state.old_id], { state.original }) and
        group_contains_exact_phrases(redo_groups[new_id], { duplicate })
      local redo_safe = redo_restored and redo_state.classification == "owned" and redo_state.eligible and
        redo_store_matches and song.tool_data == redo_data
      local passed = undo_safe and redo_safe and history_safe and undo_count == redo_count
      local details = {
        old_id = state.old_id,
        new_id = new_id,
        action_used_native_dialog_callback = true,
        can_undo_after_action = can_undo_after_action,
        undo_restored_prior_name_and_content = undo_restored == true,
        undo_store_mode = undo_data_mode,
        undo_old_association_preserved = undo_old_association_matches == true,
        undo_retained_clone_association_preserved = undo_new_association_matches == true,
        undo_both_collision_holders_blocked = undo_state.classification == "unavailable" and
          not undo_state.eligible and undo_original_state.classification == "unavailable" and
          not undo_original_state.eligible,
        undo_collision_remained_blocked = undo_safe == true,
        undo_regeneration_rejected_without_store_repair = undo_requests_rejected == true,
        single_undo_restored_prior_phrase = undo_restored == true,
        complete_logical_undo_grouped = undo_count == 1 and undo_data_mode == "pre_resolution_restored" and undo_restored == true,
        undo_history_exhausted = true,
        undo_state_count = undo_count,
        redo_state_count = redo_count,
        history = canonical_baseline(history),
        redo_restored_new_identity_and_cloned_source = redo_restored == true,
        redo_target_owned_and_eligible = redo_safe == true,
        redo_preserved_complete_post_resolution_store = redo_store_matches,
      }
      cleanup()
      details.cleanup_restored_fixture = #instrument.phrases == state.phrase_count_before and
        song.tool_data == state.data_before and state.fixture_baseline == persisted_baseline(song)
      details.status = passed and details.cleanup_restored_fixture and "PASS" or "FAIL"
      details.case = "independence-undo"
      done(details)
    end)
  end)
  return true
end

local function run_revision_undo_fixture(done, case_name)
  case_name = case_name or "revision-undo-fixture"
  local song = renoise.song()
  local instrument_index = song.selected_instrument_index
  local sequence = require("model.sequencer")
  local writer = require("writers.phrase_writer")
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local source = sequence.new_pattern(ACCEPTANCE_PATTERN_LENGTH)
  source.pitch_events[FIRST_NOTE_LINE] = sequence.new_pitch(ACCEPTANCE_GENERATED_NOTE, ACCEPTANCE_KEY, true, false)
  local request, request_error = factory.build(song, instrument_index, source)
  if not request then
    done({ status = "FAIL", case = case_name, reason = describe_failure(request_error) })
    return true
  end
  local function complete(result)
    if type(result) ~= "table" or result.kind ~= "success" or result.verified ~= true or not result.phrase then
      done({ status = "FAIL", case = case_name, reason = describe_failure(result) })
      return
    end
    local phrase = result.phrase
    local ownership = require("renoise.phrase_ownership")
    local store = require("renoise.pattern_store")
    local id = ownership.id(phrase)
    local stored, policy, pb
    if id then stored, policy, pb = store.read_entry(song, id) end
    local saved, save_error
    if stored and sequence.same_source(stored, source) then
      saved, save_error = save_independent_fixture(song, "acceptance-revision-undo.xrns")
    else
      save_error = "fixture source was not committed exactly"
    end
    done({ status = saved and "PASS" or "FAIL", case = case_name,
      reason = save_error,
      roundtrip_fixture = saved and saved.fixture, phrase_id = id,
      source_key = stored and stored.pitch_events[FIRST_NOTE_LINE].key,
      output_policy = policy, pb_range = pb })
  end
  local accepted, start_error = writer.create(request, complete)
  if not accepted then
    done({ status = "FAIL", case = case_name, reason = describe_failure(start_error) })
  end
  return true
end

local function remove_prepared_revision_undo(state)
  if not state then return end
  remove_undo_idle_notifier(state, "watch_notifier")
  for _, record in ipairs(state.wrappers or {}) do
    pcall(function() record.target[record.key] = record.original end)
  end
  state.wrappers = {}
end

local function probe_gui_idle_notifier(state)
  if state.gui_idle_probe_invoked or type(state.gui_idle_original_notifier) ~= "function" or
      not state.gui_idle_observable then return end
  state.gui_idle_probe_invoked = true
  local observable = state.gui_idle_observable
  local notifier = state.gui_idle_original_notifier
  local before_ok, before = pcall(observable.has_notifier, observable, notifier)
  state.idle_notifier_registered_before_probe = before_ok and before == true
  local called, result = pcall(notifier)
  state.gui_idle_probe_succeeded = called
  if not called then state.gui_idle_probe_error = tostring(result) end
  state.gui_idle_probe_result = called and tostring(result) or nil
  local after_ok, after = pcall(observable.has_notifier, observable, notifier)
  state.idle_notifier_registered_after_probe = after_ok and after == true
  if state.context then
    local lifetime_ok, lifetime = pcall(state.context.lifetime_state, state.context)
    if lifetime_ok and type(lifetime) == "table" then
      state.gui_idle_probe_context_open = lifetime.open == true
      state.gui_idle_probe_song_attached = lifetime.song_attached == true
      state.gui_idle_probe_context_session = lifetime.session
    end
  end
end

local function watch_prepared_revision_undo(state)
  local idle = renoise.tool().app_idle_observable
  local deadline = os.time() + UNDO_PREPARATION_TIMEOUT_SECONDS
  local notifier
  notifier = function()
    if not rawequal(prepared_revision_undo, state) then
      remove_undo_idle_notifier(state, "watch_notifier")
      return
    end
    local ok, current_song = pcall(renoise.song)
    if not ok or not rawequal(current_song, state.song) or os.time() >= deadline then
      remove_undo_idle_notifier(state, "watch_notifier")
      prepared_revision_undo = nil
      if state.action_dialog and state.action_dialog.visible then pcall(state.action_dialog.close, state.action_dialog) end
      if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
      if state.context then pcall(state.context.release_document, state.context) end
      remove_prepared_revision_undo(state)
    end
  end
  state.watch_notifier = notifier
  idle:add_notifier(notifier)
end

local function run_revision_undo_prepare(done, action_mode)
  action_mode = action_mode == "live-edit" and "live-edit" or "generate"
  if action_mode == "live-edit" then
    local completion = done
    done = function(result)
      if type(result) == "table" and result.case == "revision-undo-prepare" then
        result.case = "revision-live-undo-prepare"
      end
      completion(result)
    end
  end
  local previous = prepared_revision_undo
  if previous then
    remove_undo_idle_notifier(previous, "watch_notifier")
    if previous.dialog and previous.dialog.visible then pcall(previous.dialog.close, previous.dialog) end
    if previous.context then pcall(previous.context.release_document, previous.context) end
    remove_prepared_revision_undo(previous)
    prepared_revision_undo = nil
  end
  local song = renoise.song()
  local instrument_index = song.selected_instrument_index
  local instrument = song.instruments[instrument_index]
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local sequence = require("model.sequencer")
  if not instrument or #instrument.phrases ~= 1 or song:can_undo() or song:can_redo() then
    done({ status = "FAIL", case = "revision-undo-prepare",
      reason = "Reopened fixture must contain one phrase and have empty undo history" })
    return true
  end
  local phrase = instrument.phrases[1]
  local old_id = ownership.id(phrase)
  local old_source, old_policy, old_pb
  if old_id then old_source, old_policy, old_pb = store.read_entry(song, old_id) end
  local before_snapshot = ownership.snapshot(phrase)
  if not old_id or not old_source or not before_snapshot then
    done({ status = "FAIL", case = "revision-undo-prepare", reason = "Fixture phrase has no complete owned source" })
    return true
  end
  local fixture_note = phrase:line(FIRST_NOTE_LINE):note_column(FIRST_NOTE_COLUMN).note_value
  if fixture_note ~= old_source.pitch_events[FIRST_NOTE_LINE].note then
    done({ status = "FAIL", case = "revision-undo-prepare",
      reason = "Fixture output does not match its immutable source note" })
    return true
  end

  local context_module = require("runtime.context")
  local original_context_new = context_module.new
  local original_view_builder = renoise.ViewBuilder
  local original_app = renoise.app
    local original_tool = renoise.tool
  local state = { song = song, instrument = instrument, instrument_index = instrument_index,
    phrase = phrase, phrase_index = 1, old_id = old_id, old_source = old_source,
    old_policy = old_policy, old_pb = old_pb, before_snapshot = before_snapshot,
    callbacks = {}, controls = {}, wrappers = {} }
  context_module.new = function(options)
    state.context = original_context_new(options)
    local original_request = state.context.request_generation
    local original_reconcile = state.context.reconcile
    local original_restore_editor_target = state.context.restore_editor_target
    local original_notify_native_change = state.context.notify_native_change
    state.context.request_generation = function(self, ...)
      state.request_count = (state.request_count or 0) + 1
      -- Capture the full tuple separately; this context wrapper is test-only.
      local function pack(...) return { n = select("#", ...), ... } end
      local values = pack(pcall(original_request, self, ...))
      state.request_called = values[1] == true
      state.request_accepted = values[2]
      state.request_reason = values[3]
      if not values[1] then
        state.request_error = tostring(values[2])
        error(values[2], 0)
      end
      local unpack_values = unpack or table.unpack
      return unpack_values(values, 2, values.n)
    end
    if type(original_reconcile) == "function" then
      state.context.reconcile = function(self, ...)
        state.reconcile_count = (state.reconcile_count or 0) + 1
        local function pack(...) return { n = select("#", ...), ... } end
        local values = pack(pcall(original_reconcile, self, ...))
        state.reconcile_last_ok = values[1] == true
        if values[1] then
          local target, effects = values[2], values[3]
          state.reconcile_last_target_kind = type(target) == "table" and target.kind or nil
          state.reconcile_last_effects = type(effects) == "table" and {
            reconcile = effects.reconcile == true,
            native_revision_reconciled = effects.native_revision_reconciled == true,
            hydrate = effects.hydrate == true,
            preserve = effects.preserve == true,
          } or nil
        else
          state.reconcile_last_error = tostring(values[2])
        end
          state.reconcile_history = state.reconcile_history or {}
          state.reconcile_history[#state.reconcile_history + 1] = tostring(state.reconcile_count) .. ":" ..
            tostring(state.reconcile_last_target_kind or "error") .. ":" ..
            tostring(state.reconcile_last_effects and state.reconcile_last_effects.native_revision_reconciled or false)
          while #state.reconcile_history > 12 do table.remove(state.reconcile_history, 1) end
        if not values[1] then error(values[2], 0) end
        local unpack_values = unpack or table.unpack
        return unpack_values(values, 2, values.n)
      end
    end
    if type(original_notify_native_change) == "function" then
      state.context.notify_native_change = function(self, kind, subject, ...)
        state.native_change_count = (state.native_change_count or 0) + 1
        state.native_change_last_kind = tostring(kind)
        state.native_change_last_matches_phrase = rawequal(subject, state.phrase)
        state.native_change_last_matches_instrument = rawequal(subject, state.instrument)
        local function pack(...) return { n = select("#", ...), ... } end
        local values = pack(pcall(original_notify_native_change, self, kind, subject, ...))
        state.native_change_last_ok = values[1] == true
        state.native_change_last_result = values[1] and values[2] == true or false
        if values[1] then state.native_change_last_error = nil
        else state.native_change_last_error = tostring(values[2]) end
        if not values[1] then error(values[2], 0) end
        local unpack_values = unpack or table.unpack
        return unpack_values(values, 2, values.n)
      end
    end
    if type(original_restore_editor_target) == "function" then
      state.context.restore_editor_target = function(self, instrument, phrase, ...)
        state.restore_editor_target_calls = (state.restore_editor_target_calls or 0) + 1
        state.restore_editor_target_matches_phrase = rawequal(phrase, state.phrase)
        local function pack(...) return { n = select("#", ...), ... } end
        local values = pack(pcall(original_restore_editor_target, self, instrument, phrase, ...))
        state.restore_editor_target_last_ok = values[1] == true
          local result = values[1] and type(values[2]) == "table" and values[2] or nil
          state.restore_editor_target_result = result ~= nil
          state.restore_editor_target_kind = result and result.target and result.target.kind or nil
          state.restore_editor_source_available = result and result.source_available == true or false
          state.restore_editor_editor_available = result and type(result.editor) == "table" or false
          state.restore_editor_draft = result and result.draft == true or false
          state.restore_editor_target_reason = result and tostring(result.reason or result.draft_error or "") or
            (values[1] and tostring(values[3] or "") or tostring(values[2]))
        if not values[1] then error(values[2], 0) end
        local unpack_values = unpack or table.unpack
        return unpack_values(values, 2, values.n)
      end
    end
    return state.context
  end
  local wrapped, wrap_error = pcall(function()
    renoise.ViewBuilder = function(...)
      local builder = original_view_builder(...)
      return setmetatable({}, { __index = function(_, kind)
        local constructor = builder[kind]
        if type(constructor) ~= "function" then return constructor end
        return function(_, properties, ...)
          local props = type(properties) == "table" and properties or nil
          local id = props and props.id
          local label = props and props.text
          if id and props.notifier then
            state.callbacks[id] = props.notifier
            if id == "acid_program_key_popup" then
              local notifier = props.notifier
              props.notifier = function(...)
                if state.suppress_key_notifier then return end
                return notifier(...)
              end
            elseif id == "acid_live_edit" then
              local notifier = props.notifier
              props.notifier = function(...)
                if state.suppress_live_notifier then return end
                return notifier(...)
              end
            end
          end
          if label and props.notifier then state.callbacks[label] = props.notifier end
          local view = constructor(builder, properties, ...)
          if id then state.controls[id] = view end
          if kind == "multiline_textfield" and props and props.width == 820 and props.height == 80 then
            state.gui_status_control = view
          end
          if kind == "popup" and props and props.width == 360 and type(props.notifier) == "function" then
            state.callbacks.acid_phrase_choice = props.notifier
            state.controls.acid_phrase_choice = view
          end
          return view
        end
      end })
    end
    renoise.app = function(...)
      local app = original_app(...)
      return setmetatable({}, { __index = function(_, key)
        local member = app[key]
        if key == "show_custom_dialog" and type(member) == "function" then
          return function(_, ...)
            local function pack(...) return { n = select("#", ...), ... } end
            local args = pack(...)
            if args[1] == "ACID - PITCH/TIME" then
              local function dispatch_production_key(dialog, key_event)
                if type(state.production_key_handler) == "function" then
                  return state.production_key_handler(dialog, key_event)
                end
                return key_event
              end
              state.dialog = member(app, args[1], args[2], dispatch_production_key,
                { send_key_repeat = false, send_key_release = false })
              state.action_dialog = state.dialog
              return state.dialog
            end
            return member(app, unpack(args, 1, args.n))
          end
        end
        if type(member) == "function" then return function(_, ...) return member(app, ...) end end
        return member
      end })
    end
    renoise.tool = function(...)
      local tool = original_tool(...)
      return setmetatable({}, { __index = function(_, key)
        local member = tool[key]
        if key ~= "app_idle_observable" or member == nil then
          if type(member) == "function" then return function(_, ...) return member(tool, ...) end end
          return member
        end
        local observable = member
        state.gui_idle_observable = observable
        return setmetatable({}, { __index = function(_, method_name)
          local method = observable[method_name]
          if type(method) ~= "function" then return method end
          return function(_, ...)
            if method_name == "add_notifier" then
              state.gui_idle_registration_count = (state.gui_idle_registration_count or 0) + 1
              state.gui_idle_original_notifier = select(1, ...)
            end
            return method(observable, ...)
          end
        end })
      end })
    end
    require("gui").show()
  end)
  context_module.new = original_context_new
  renoise.ViewBuilder = original_view_builder
  renoise.app = original_app
  renoise.tool = original_tool
  if not wrapped or not state.context or not state.dialog or not state.dialog.visible then
    if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
    if state.context then pcall(state.context.release_document, state.context) end
    remove_prepared_revision_undo(state)
    done({ status = "FAIL", case = "revision-undo-prepare",
      reason = tostring(wrap_error or "Production GUI capture failed") })
    return true
  end
  local key_view = state.controls.acid_program_key_popup
  local key_callback = state.callbacks.acid_program_key_popup
  local generate_callback = state.callbacks["Generate / Regenerate ACID Phrase"]
  local live_control = state.controls.acid_live_edit
  local live_callback = state.callbacks.acid_live_edit
  local phrase_choice = state.callbacks.acid_phrase_choice
  local phrase_view = state.controls.acid_phrase_choice
  if not key_view or type(key_callback) ~= "function" or
      (action_mode == "generate" and type(generate_callback) ~= "function") or
      (action_mode == "live-edit" and (not live_control or type(live_callback) ~= "function")) or
      type(phrase_choice) ~= "function" or not phrase_view or type(phrase_view.items) ~= "table" then
    pcall(state.dialog.close, state.dialog)
    pcall(state.context.release_document, state.context)
    remove_prepared_revision_undo(state)
    done({ status = "FAIL", case = "revision-undo-prepare",
      reason = "Production GUI did not expose the callbacks required by the selected edit action" })
    return true
  end
  state.production_key_handler = function(_, key_event)
    local key_state = key_event.state or "pressed"
    state.dialog_key_event_summary = tostring(key_event.name) .. ":" .. tostring(key_state)
    if (key_event.name == "enter" or key_event.name == "return") and key_state ~= "released" and
        type(state.dispatch_enter) == "function" then
      state.enter_dispatched = true
      state.dispatch_enter()
      return nil
    end
    return key_event
  end
  local phrase_choice_index
  for index, label in ipairs(phrase_view.items) do
    if type(label) == "string" and label:match("^01:") then phrase_choice_index = index; break end
  end
  if not phrase_choice_index then
    pcall(state.dialog.close, state.dialog)
    pcall(state.context.release_document, state.context)
    remove_prepared_revision_undo(state)
    done({ status = "FAIL", case = "revision-undo-prepare",
      reason = "Production phrase chooser did not expose the existing fixture phrase" })
    return true
  end
  phrase_choice(phrase_choice_index)
  local target = state.context:target_state()
  if not target or target.kind ~= "owned" or not rawequal(target.phrase, phrase) then
    pcall(state.dialog.close, state.dialog)
    pcall(state.context.release_document, state.context)
    remove_prepared_revision_undo(state)
    done({ status = "FAIL", case = "revision-undo-prepare", reason = "Production GUI did not bind the fixture phrase" })
    return true
  end
  local before_editor = state.context:editor_state()
  if not before_editor or not sequence.same_source(before_editor.source, old_source) then
    pcall(state.dialog.close, state.dialog)
    pcall(state.context.release_document, state.context)
    remove_prepared_revision_undo(state)
    done({ status = "FAIL", case = "revision-undo-prepare", reason = "GUI source did not hydrate from the fixture row" })
    return true
  end
  state.before_editor = before_editor
  state.action_mode = action_mode
  state.dialog_key_event_summary = ""
  local function generate_from_user_action()
    if state.action_started then return nil end
    state.action_started = true
    local changed_value = (old_source.pitch_events[FIRST_NOTE_LINE].key + 1) % 12 + 1
    if action_mode == "live-edit" then
      state.suppress_live_notifier = true
      live_control.value = true
      state.suppress_live_notifier = false
      local live_called, live_error = pcall(live_callback, true)
      state.live_edit_arm_error = not live_called and tostring(live_error) or nil
      state.live_edit_armed = live_called
    end
    state.suppress_key_notifier = true
    key_view.value = changed_value
    state.suppress_key_notifier = false
    key_callback(changed_value)
    state.edited_source = state.context:editor_state().source
    state.edited_key = state.edited_source and state.edited_source.pitch_events[FIRST_NOTE_LINE].key
    if action_mode == "live-edit" then
      state.live_edit_callback_error = state.live_edit_arm_error
      state.live_edit_callback_invoked = true
    else
      local generate_called, generate_error = pcall(generate_callback)
      state.generate_callback_error = not generate_called and tostring(generate_error) or nil
      state.generate_callback_invoked = true
    end
    return nil
  end
  state.dispatch_enter = generate_from_user_action
  state.action_dialog = state.dialog
  if not state.action_dialog then
    pcall(state.dialog.close, state.dialog)
    pcall(state.context.release_document, state.context)
    remove_prepared_revision_undo(state)
    done({ status = "FAIL", case = "revision-undo-prepare",
      reason = "Production dialog was not captured for native Enter dispatch" })
    return true
  end
  prepared_revision_undo = state
  watch_prepared_revision_undo(state)
  done({ status = "PASS", case = "revision-undo-prepare", action_ready = true,
    gui_open = state.dialog.visible, action_dialog_visible = state.action_dialog.visible, phrase_id = old_id })
  return true
end

local function run_revision_undo(done, requested_mode)
  local state = prepared_revision_undo
  if not state then
    done({ status = "FAIL", case = requested_mode == "live-edit" and "revision-live-undo" or "revision-undo",
      reason = "Production GUI action was not prepared" })
    return true
  end
  local case_name = state.action_mode == "live-edit" and "revision-live-undo" or "revision-undo"
  if not state.action_started then
    prepared_revision_undo = nil
    if state.action_dialog and state.action_dialog.visible then pcall(state.action_dialog.close, state.action_dialog) end
    if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
    if state.context then pcall(state.context.release_document, state.context) end
    remove_prepared_revision_undo(state)
    done({ status = "FAIL", case = case_name, reason = "Guarded Enter did not invoke the real GUI action",
      gui_open = state.dialog and state.dialog.visible == true,
      action_dialog_open = state.action_dialog and state.action_dialog.visible == true })
    return true
  end
  local function fail(reason, details)
    details = details or {}
    local function safe_text(value)
      if value == nil then return nil end
      if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
        return value
      end
      return tostring(value)
    end
    local generation
    if state.context then
      local ok, value = pcall(state.context.generation_state, state.context)
      if ok then generation = value end
    end
    local writer = require("writers.phrase_writer")
    local writer_status, writer_token = writer.state()
    local writer_diagnostic = writer.diagnostic()
    local source_control = state.controls.acid_source_state
    local editor_state
    if state.context then
      local ok, value = pcall(state.context.editor_state, state.context)
      if ok then editor_state = value end
    end
    local editor_pitch = editor_state and editor_state.source and
      editor_state.source.pitch_events and editor_state.source.pitch_events[FIRST_NOTE_LINE]
    local expected_pitch = state.old_source and state.old_source.pitch_events and
      state.old_source.pitch_events[FIRST_NOTE_LINE]
    local editor_matches_old = false
    if editor_state and editor_state.source and state.old_source then
      local ok, value = pcall(require("model.sequencer").same_source,
        editor_state.source, state.old_source)
      editor_matches_old = ok and value == true
    end
    local selected_instrument_index, selected_phrase_index
    pcall(function()
      selected_instrument_index = state.song.selected_instrument_index
      selected_phrase_index = state.song.selected_phrase_index
    end)
    local integrity
    if state.context then
      local ok, value = pcall(state.context.integrity_state, state.context)
      if ok and type(value) == "table" then integrity = value end
    end
    local gui_state
    do
      local ok, value = pcall(function() return require("gui").get_ui_state() end)
      if ok and type(value) == "table" then gui_state = value end
    end
    details.generation_status = details.generation_status or (generation and safe_text(generation.status))
    details.generation_busy = details.generation_busy or (generation and generation.busy == true)
    details.generation_pending = details.generation_pending or (generation and generation.pending == true)
    details.generation_last_result = details.generation_last_result or
      (generation and generation.last_result and safe_text(generation.last_result.kind))
    details.generation_last_result_code = details.generation_last_result_code or
      (generation and generation.last_result and safe_text(generation.last_result.code))
    details.generation_last_result_reason = details.generation_last_result_reason or
      (generation and generation.last_result and safe_text(generation.last_result.reason or generation.last_result.message))
    details.writer_status = details.writer_status or safe_text(writer_status)
    details.writer_token_present = details.writer_token_present or (writer_token ~= nil)
    details.writer_diagnostic_code = details.writer_diagnostic_code or
      (writer_diagnostic and safe_text(writer_diagnostic.code))
    details.writer_diagnostic_message = details.writer_diagnostic_message or
      (writer_diagnostic and safe_text(writer_diagnostic.message))
    details.request_count = details.request_count or state.request_count or 0
    details.request_accepted = details.request_accepted or safe_text(state.request_accepted)
    details.request_reason = details.request_reason or safe_text(state.request_reason)
    details.request_error = details.request_error or safe_text(state.request_error)
    details.generate_callback_invoked = details.generate_callback_invoked or state.generate_callback_invoked == true
    details.live_edit_callback_invoked = state.live_edit_callback_invoked == true
    details.action_mode = state.action_mode
    details.generate_callback_error = details.generate_callback_error or safe_text(state.generate_callback_error)
    details.key_event = details.key_event or safe_text(state.dialog_key_event_summary)
    details.production_dialog_visible = state.dialog and state.dialog.visible == true
    details.action_dialog_same_as_production = rawequal(state.action_dialog, state.dialog)
    details.context_reconcile_calls = state.reconcile_count or 0
    details.context_reconcile_last_ok = state.reconcile_last_ok
    details.context_reconcile_last_target_kind = safe_text(state.reconcile_last_target_kind)
    details.context_reconcile_last_effects = state.reconcile_last_effects
    details.context_reconcile_last_error = safe_text(state.reconcile_last_error)
    details.restore_editor_target_calls = state.restore_editor_target_calls or 0
    details.restore_editor_target_last_ok = state.restore_editor_target_last_ok
    details.restore_editor_target_result = state.restore_editor_target_result
    details.restore_editor_target_reason = safe_text(state.restore_editor_target_reason)
    details.restore_editor_target_matches_phrase = state.restore_editor_target_matches_phrase
    details.restore_editor_target_kind = safe_text(state.restore_editor_target_kind)
    details.restore_editor_source_available = state.restore_editor_source_available
    details.restore_editor_editor_available = state.restore_editor_editor_available
    details.restore_editor_draft = state.restore_editor_draft
    details.idle_notifier_add_count = state.idle_notifier_add_count or 0
    details.idle_notifier_remove_count = state.idle_notifier_remove_count or 0
    details.idle_notifier_registered = state.idle_notifier_registered == true
    details.gui_idle_listener_attached = gui_state and gui_state.idle_listener_attached == true
    details.gui_native_observers_attached = gui_state and gui_state.native_observers_attached == true
    details.gui_native_listener_count = gui_state and gui_state.native_listener_count
    details.gui_native_observer_error = gui_state and safe_text(gui_state.native_observer_error)
    details.gui_observer_error = gui_state and safe_text(gui_state.observer_error)
    details.gui_idle_registration_count = state.gui_idle_registration_count or 0
    details.gui_idle_notifier_captured = type(state.gui_idle_original_notifier) == "function"
    details.idle_notifier_registered_before_probe = state.idle_notifier_registered_before_probe
    details.gui_idle_probe_invoked = state.gui_idle_probe_invoked == true
    details.gui_idle_probe_succeeded = state.gui_idle_probe_succeeded
    details.gui_idle_probe_result = safe_text(state.gui_idle_probe_result)
    details.gui_idle_probe_error = safe_text(state.gui_idle_probe_error)
    details.idle_notifier_registered_after_probe = state.idle_notifier_registered_after_probe
    details.gui_idle_probe_context_open = state.gui_idle_probe_context_open
    details.gui_idle_probe_song_attached = state.gui_idle_probe_song_attached
    details.gui_idle_probe_context_session = state.gui_idle_probe_context_session
    details.verifier_idle_ticks = state.verifier_idle_ticks or 0
    details.verifier_idle_actions = state.verifier_idle_actions or 0
    details.native_change_count = state.native_change_count or 0
    details.native_change_last_kind = safe_text(state.native_change_last_kind)
    details.native_change_last_matches_phrase = state.native_change_last_matches_phrase
    details.native_change_last_matches_instrument = state.native_change_last_matches_instrument
    details.native_change_last_ok = state.native_change_last_ok
    details.native_change_last_result = state.native_change_last_result
    details.native_change_last_error = safe_text(state.native_change_last_error)
    details.reconcile_history = state.reconcile_history and table.concat(state.reconcile_history, ";") or ""
    details.gui_editor_available = editor_state ~= nil
    details.gui_editor_source_key = editor_pitch and safe_text(editor_pitch.key)
    details.gui_editor_source_note = editor_pitch and safe_text(editor_pitch.note)
    details.gui_editor_source_matches_old = editor_matches_old
    details.gui_expected_old_source_key = expected_pitch and safe_text(expected_pitch.key)
    details.gui_key_control_value = state.controls.acid_program_key_popup and
      safe_text(state.controls.acid_program_key_popup.value)
    details.selected_instrument_index = selected_instrument_index
    details.selected_phrase_index = selected_phrase_index
    details.source_state_text = details.source_state_text or
      (source_control and safe_text(source_control.text))
    details.gui_status_text = details.gui_status_text or
      (state.gui_status_control and safe_text(state.gui_status_control.text))
    details.integrity_blocked = details.integrity_blocked or
      (integrity and integrity.blocked == true)
    details.integrity_reason = details.integrity_reason or
      (integrity and safe_text(integrity.reason or integrity.message))
    remove_undo_idle_notifier(state, "watch_notifier")
    state.verifier_stopped = true
    remove_undo_idle_notifier(state, "verifier_notifier")
    prepared_revision_undo = nil
    if state.action_dialog and state.action_dialog.visible then pcall(state.action_dialog.close, state.action_dialog) end
    if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
    if state.context then pcall(state.context.release_document, state.context) end
    remove_prepared_revision_undo(state)
    details.status, details.case, details.reason = "FAIL", case_name, reason
    done(details)
  end
  local function wait_idle(callback)
    if state.verifier_stopped then return end
    if state.verifier_idle_action then
      fail("revision verifier already has a queued idle action")
      return
    end
    state.verifier_idle_action = callback
  end
  local function start_verification()
    local idle = renoise.tool().app_idle_observable
    local function verifier_idle_notifier()
      if state.verifier_stopped then return end
      state.verifier_idle_ticks = (state.verifier_idle_ticks or 0) + 1
      local action = state.verifier_idle_action
      if not action then return end
      state.verifier_idle_action = nil
      state.verifier_idle_actions = (state.verifier_idle_actions or 0) + 1
      local ok, action_error = xpcall(action, function(callback_error)
        if debug and type(debug.traceback) == "function" then
          return debug.traceback(tostring(callback_error), 2)
        end
        return tostring(callback_error)
      end)
      if not ok and not state.verifier_stopped then fail(action_error) end
    end
    state.verifier_notifier = verifier_idle_notifier
    local added, add_error = pcall(idle.add_notifier, idle, verifier_idle_notifier)
    local registered, present = pcall(idle.has_notifier, idle, verifier_idle_notifier)
    if not added or not registered or present ~= true then
      fail("revision verifier idle notifier could not be registered: " .. tostring(add_error or present))
      return
    end
    local sequence = require("model.sequencer")
    local ownership = require("renoise.phrase_ownership")
    local store = require("renoise.pattern_store")
    local function inventory_stable()
      return #state.instrument.phrases == 1 and rawequal(state.instrument.phrases[1], state.phrase)
    end
    local function read_current()
      local id = ownership.id(state.phrase)
      local source, policy, pb
      if id then source, policy, pb = store.read_entry(state.song, id) end
      local snapshot = ownership.snapshot(state.phrase)
      local editor = state.context:editor_state()
      return { id = id, source = source, policy = policy, pb = pb,
        snapshot = snapshot, editor = editor }
    end
    local function coherent(actual, expected_id, expected_source, expected_snapshot, expected_policy, expected_pb,
        require_editor)
      local old_source, old_policy, old_pb = store.read_entry(state.song, state.old_id)
      local new_source, new_policy, new_pb
      if state.new_id then new_source, new_policy, new_pb = store.read_entry(state.song, state.new_id) end
      return inventory_stable() and actual.id == expected_id and actual.source and
        sequence.same_source(actual.source, expected_source) and actual.policy == expected_policy and
        actual.pb == expected_pb and actual.snapshot and ownership.compare(actual.snapshot, expected_snapshot) and
        state.phrase:line(FIRST_NOTE_LINE):note_column(FIRST_NOTE_COLUMN).note_value ==
          expected_source.pitch_events[FIRST_NOTE_LINE].note and
        (require_editor == false or (actual.editor and sequence.same_source(actual.editor.source, expected_source) and
        actual.editor.output_policy == expected_policy and actual.editor.pb_range == expected_pb)) and
        old_source and sequence.same_source(old_source, state.old_source) and
        old_policy == state.old_policy and old_pb == state.old_pb and
        (not state.new_id or (new_source and sequence.same_source(new_source, state.new_source) and
          new_policy == state.new_policy and new_pb == state.new_pb))
    end
    local deadline = os.time() + UNDO_ACTION_WAIT_TIMEOUT_SECONDS
    local function wait_for_commit()
      if os.time() >= deadline then fail("real Generate callback did not settle", {
        generate_callback_invoked = state.generate_callback_invoked == true,
        edited_key = state.edited_key, key_event = state.dialog_key_event_summary })
        return
      end
      local generation = state.context:generation_state()
      if generation.busy or generation.pending or generation.status == "RENDERING" or generation.status == "DIRTY" then
        wait_idle(wait_for_commit)
        return
      end
      local actual = read_current()
      local action_callback_invoked = state.action_mode == "live-edit" and
        state.live_edit_callback_invoked == true or state.generate_callback_invoked == true
      if not state.action_started or not state.enter_dispatched or not state.edited_source or state.edited_key == nil or
          not action_callback_invoked or state.generate_callback_error or state.live_edit_callback_error or
          state.edited_key == state.old_source.pitch_events[FIRST_NOTE_LINE].key or
          not actual.source or not sequence.same_source(actual.source, state.edited_source) or
          not actual.id or actual.id == state.old_id or not actual.snapshot then
        fail("source edit and real Generate did not commit one new coherent revision", {
          generate_callback_invoked = state.generate_callback_invoked == true,
          edited_key = state.edited_key, committed_id = actual.id })
        return
      end
      state.new_id, state.new_source, state.new_policy, state.new_pb = actual.id,
        actual.source, actual.policy, actual.pb
      state.after_snapshot = actual.snapshot
      state.after_editor = actual.editor
      state.phrase_index = 1
      if not coherent(actual, state.new_id, state.new_source, state.after_snapshot,
          state.new_policy, state.new_pb) then
        fail("post-Generate output, immutable source row or GUI editor state disagree")
        return
      end
      if not state.song:can_undo() or state.song:can_redo() then
        fail("native Generate did not create an undoable action from the cleared fixture history")
        return
      end
      wait_idle(function()
        local stable = read_current()
        if not coherent(stable, state.new_id, state.new_source, state.after_snapshot,
            state.new_policy, state.new_pb) then
          fail("an idle callback changed committed output or GUI source without user action")
          return
        end
        local called, undo_error = pcall(function() state.song:undo() end)
        if not called then fail(tostring(undo_error)); return end
        wait_idle(function()
          local restored = read_current()
          if not coherent(restored, state.old_id, state.old_source, state.before_snapshot,
              state.old_policy, state.old_pb, false) then
            local old_row_source, old_row_policy, old_row_pb = store.read_entry(state.song, state.old_id)
            local new_row_source, new_row_policy, new_row_pb
            if state.new_id then
              new_row_source, new_row_policy, new_row_pb = store.read_entry(state.song, state.new_id)
            end
            local actual_note
            pcall(function()
              actual_note = state.phrase:line(FIRST_NOTE_LINE):note_column(FIRST_NOTE_COLUMN).note_value
            end)
            local expected_note = state.old_source.pitch_events[FIRST_NOTE_LINE].note
            fail("one native Undo did not restore the exact phrase, source, settings and GUI state", {
              current_id = restored.id, expected_id = state.old_id,
              gui_source_restored = restored.editor and sequence.same_source(restored.editor.source, state.old_source) or false,
              phrase_identity_preserved = inventory_stable(), native_undo_remaining = state.song:can_undo(),
              undo_source_matches = restored.source and sequence.same_source(restored.source, state.old_source) or false,
              undo_policy_matches = restored.policy == state.old_policy,
              undo_pb_range_matches = restored.pb == state.old_pb,
              undo_output_snapshot_matches = restored.snapshot and ownership.compare(restored.snapshot, state.before_snapshot) or false,
              undo_output_note_actual = actual_note, undo_output_note_expected = expected_note,
              undo_old_source_row_retained = old_row_source and sequence.same_source(old_row_source, state.old_source) or false,
              undo_old_policy_retained = old_row_policy == state.old_policy,
              undo_old_pb_range_retained = old_row_pb == state.old_pb,
              undo_new_source_row_retained = new_row_source and state.new_source and sequence.same_source(new_row_source, state.new_source) or false,
              undo_new_policy_retained = new_row_policy == state.new_policy,
              undo_new_pb_range_retained = new_row_pb == state.new_pb })
            return
          end
          if state.song:can_undo() or not state.song:can_redo() then
            fail("the source and phrase commit was split across native undo states", {
              undo_remaining = state.song:can_undo(), redo_available = state.song:can_redo() })
            return
          end
          local editor_waits, editor_stable_waits = 0, 0
          local editor_deadline = os.time() + UNDO_ACTION_WAIT_TIMEOUT_SECONDS
          local function verify_editor_restored()
            editor_waits = editor_waits + 1
            local stable_undo = read_current()
            if not coherent(stable_undo, state.old_id, state.old_source, state.before_snapshot,
                state.old_policy, state.old_pb, false) then
              fail("idle processing regenerated or desynchronized the restored native phrase revision", {
                current_id = stable_undo.id, expected_id = state.old_id })
              return
            end
            local editor_matches = stable_undo.editor and
              sequence.same_source(stable_undo.editor.source, state.old_source) and
              stable_undo.editor.output_policy == state.old_policy and stable_undo.editor.pb_range == state.old_pb
            if editor_matches then editor_stable_waits = editor_stable_waits + 1
            else editor_stable_waits = 0 end
            if editor_stable_waits >= 2 then
              if not coherent(stable_undo, state.old_id, state.old_source, state.before_snapshot,
                  state.old_policy, state.old_pb) then
                fail("reconciled GUI source does not match the natively restored phrase")
                return
              end
              if state.song:can_undo() or not state.song:can_redo() then
                fail("the source and phrase commit was split while GUI reconciliation settled", {
                  undo_remaining = state.song:can_undo(), redo_available = state.song:can_redo() })
                return
              end
              local redone, redo_error = pcall(function() state.song:redo() end)
              if not redone then fail(tostring(redo_error)); return end
              wait_idle(function()
                local restored_post = read_current()
                if not coherent(restored_post, state.new_id, state.new_source, state.after_snapshot,
                    state.new_policy, state.new_pb) or state.song:can_redo() or not state.song:can_undo() then
                  fail("one native Redo did not restore the exact committed revision")
                  return
                end
                local result = { status = "PASS", case = case_name,
                  action_mode = state.action_mode,
                  action_used_real_gui_callbacks = state.generate_callback_invoked == true or
                    state.live_edit_callback_invoked == true,
                  live_edit_callback_invoked = state.live_edit_callback_invoked == true,
                  action_received_enter = state.enter_dispatched == true,
                  gui_kept_open = state.dialog.visible == true,
                  phrase_object_preserved = inventory_stable(),
                  old_revision_retained = true, new_revision_id = state.new_id,
                  old_revision_id = state.old_id, undo_restored_gui_source = true,
                  gui_reconciliation_idle_count = editor_waits,
                  one_step_undo_and_redo = true, no_idle_regeneration = true }
                remove_undo_idle_notifier(state, "watch_notifier")
                prepared_revision_undo = nil
                state.verifier_stopped = true
                remove_undo_idle_notifier(state, "verifier_notifier")
                if state.action_dialog and state.action_dialog.visible then pcall(state.action_dialog.close, state.action_dialog) end
                if state.dialog and state.dialog.visible then pcall(state.dialog.close, state.dialog) end
                if state.context then pcall(state.context.release_document, state.context) end
                remove_prepared_revision_undo(state)
                done(result)
              end)
              return
            end
            local undo_processing = false
            local processing_ok, processing_value = pcall(state.song.is_undo_redoing, state.song)
            if processing_ok then undo_processing = processing_value == true end
            if editor_waits >= 600 or os.time() >= editor_deadline then
              probe_gui_idle_notifier(state)
              fail("GUI editor did not rehydrate the native Undo revision before the bounded settle timeout", {
                gui_reconciliation_idle_count = editor_waits,
                native_undo_processing = undo_processing,
                gui_editor_available = stable_undo.editor ~= nil,
                gui_source_restored = editor_matches == true,
                gui_idle_registration_count = state.gui_idle_registration_count or 0,
                gui_idle_notifier_captured = type(state.gui_idle_original_notifier) == "function",
                idle_notifier_registered_before_probe = state.idle_notifier_registered_before_probe,
                gui_idle_probe_invoked = state.gui_idle_probe_invoked == true,
                gui_idle_probe_succeeded = state.gui_idle_probe_succeeded,
                gui_idle_probe_result = state.gui_idle_probe_result,
                gui_idle_probe_error = state.gui_idle_probe_error,
                idle_notifier_registered_after_probe = state.idle_notifier_registered_after_probe,
                gui_idle_probe_context_open = state.gui_idle_probe_context_open,
                gui_idle_probe_song_attached = state.gui_idle_probe_song_attached,
                gui_idle_probe_context_session = state.gui_idle_probe_context_session })
              return
            end
            wait_idle(verify_editor_restored)
          end
          verify_editor_restored()
        end)
      end)
    end
    wait_for_commit()
  end
  start_verification()
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
  local observed={}
  local production_context,production_dialog
  local lifecycle_fixture_path
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
    if production_dialog then pcall(function() production_dialog:close() end) end
    if production_context then pcall(function() production_context:release_document() end) end
    if lifecycle_fixture_path then pcall(os.remove,lifecycle_fixture_path);lifecycle_fixture_path=nil end
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

    local store_before_revalidation=song.tool_data
    local recovery_status,recovery_proof=context:revalidation_status()
    if not recovery_status.verified or not recovery_proof or not context:revalidate(recovery_proof) or
        song.tool_data~=store_before_revalidation or sink_calls~=1 then
      fail("read-only revalidation did not clear the verified adoption blocker");return
    end

    context:release_document()
    local context_module=require("runtime.context")
    local original_context_new=context_module.new
    local original_view_builder=renoise.ViewBuilder
    local original_app=renoise.app
    local gui_context,gui_dialog
    local cancel_calls,last_cancel_token=0,nil
    local gui_reconcile_calls,generate_calls=0,0
    local callbacks={}
    context_module.new=function(options)
      local original_cancel=options.cancel
      options.cancel=function(token,reason,...)
        cancel_calls=cancel_calls+1
        last_cancel_token=token
        if type(original_cancel)=="function" then return original_cancel(token,reason,...) end
        return false
      end
      gui_context=original_context_new(options)
      local reconcile=gui_context.reconcile
      gui_context.reconcile=function(self,...)
        gui_reconcile_calls=gui_reconcile_calls+1
        return reconcile(self,...)
      end
      return gui_context
    end
    renoise.ViewBuilder=function(...)
      local builder=original_view_builder(...)
      return setmetatable({}, {__index=function(_,kind)
        local constructor=builder[kind]
        if type(constructor)~="function" then return constructor end
        return function(_,properties,...)
          local props=type(properties)=="table" and properties or nil
          local key=props and (props.id or props.text)
          if key and type(props.notifier)=="function" then
            if key=="Generate / Regenerate ACID Phrase" then
              local notifier=props.notifier
              callbacks[key]=function(...) generate_calls=generate_calls+1;return notifier(...) end
            else
              callbacks[key]=props.notifier
            end
          end
          if kind=="popup" and props and props.width==360 then callbacks.phrase_choice=props.notifier end
          return constructor(builder,properties,...)
        end
      end})
    end
    local gui=require("gui")
    local function show_gui()
      renoise.app=function(...)
        local app=original_app(...)
        return setmetatable({}, {__index=function(_,key)
          local member=app[key]
          if key=="show_custom_dialog" and type(member)=="function" then
            return function(_,...) gui_dialog=member(app,...);return gui_dialog end
          end
          if type(member)=="function" then return function(_,...) return member(app,...) end end
          return member
        end})
      end
      local opened,reason=pcall(gui.show)
      renoise.app=original_app
      return opened,reason
    end
    local gui_opened,gui_error=show_gui()
    context_module.new=original_context_new
    renoise.ViewBuilder=original_view_builder
    if not gui_opened then fail("production GUI failed to open: "..tostring(gui_error));return end
    local generate=callbacks["Generate / Regenerate ACID Phrase"]
    if not gui_context or not gui_dialog or type(generate)~="function" or type(callbacks.phrase_choice)~="function" then
      fail("production GUI capture missed its context, dialog, target or Generate callback");return
    end
    production_context,production_dialog=gui_context,gui_dialog
    local phrase=observed.phrase
    local choices,choices_error=gui_context:phrase_choices(instrument)
    if not choices then fail(choices_error or "production GUI phrase inventory failed");return end
    local phrase_choice_index=0
    local phrase_choice_found=false
    for _,choice in ipairs(choices) do
      if choice.kind~="new" then
        phrase_choice_index=phrase_choice_index+1
        if rawequal(choice.phrase,phrase) then phrase_choice_found=true;break end
      end
    end
    if not phrase_choice_found then fail("committed phrase was absent from production GUI choices");return end
    callbacks.phrase_choice(phrase_choice_index)
    local target=gui_context:target_state()
    if target.kind~="owned" or not rawequal(target.phrase,phrase) then
      fail("production GUI did not bind the committed phrase by object identity");return
    end

    local ownership=require("renoise.phrase_ownership")
    local function ui_state() return gui.get_ui_state() end
    local initial_ui_state=ui_state()
    if not initial_ui_state.native_observers_attached or initial_ui_state.native_listener_count<=0 or
        not initial_ui_state.idle_listener_attached then
      fail("production GUI did not attach native and idle observers exactly once");return
    end
    local initial_listener_count=initial_ui_state.native_listener_count
    local NOTE_COLUMN_COUNT=renoise.InstrumentPhrase.MAX_NUMBER_OF_NOTE_COLUMNS
    local VISIBLE_COLUMN=1
    local HIDDEN_COLUMN=NOTE_COLUMN_COUNT
    local IDLE_TIMEOUT=6000
    local IDLE_RECONCILE_TIMEOUT_SECONDS=30
    if phrase.visible_note_columns~=VISIBLE_COLUMN then
      fail("fixture must have one visible note column for hidden-column checks");return
    end
    local phrase_count=#instrument.phrases
    local original_names,original_mutes={},{}
    for _,column in ipairs({VISIBLE_COLUMN,NOTE_COLUMN_COUNT}) do
      original_names[column]=phrase:column_name(column)
      original_mutes[column]=phrase:column_is_muted(column)
    end
    local matrix={
      {kind="name",column=VISIBLE_COLUMN},
      {kind="mute",column=VISIBLE_COLUMN},
      {kind="name",column=NOTE_COLUMN_COUNT},
      {kind="mute",column=NOTE_COLUMN_COUNT},
    }
    local matrix_index=0
    local idle_reconciled_cases,busy_reconciled_cases,busy_cases,canceled_cases,preserved_cases=0,0,0,0,0
    local function change_column(case,changed)
      if case.kind=="name" then
        local value=changed and (original_names[case.column].." ACID edit") or original_names[case.column]
        phrase:set_column_name(case.column,value)
        return value
      end
      local value=original_mutes[case.column]
      if changed then value=not value end
      phrase:set_column_is_muted(case.column,value)
      return value
    end
    local function wait_idle(action)
      local idle=renoise.tool().app_idle_observable
      local notifier
      notifier=function() pcall(function() idle:remove_notifier(notifier) end);action() end
      idle:add_notifier(notifier)
    end
    local finish_matrix
    local function revalidate_then(action,reconcile_before,reconcile_phase)
      local function continue()
        if reconcile_phase=="idle" then
          idle_reconciled_cases=idle_reconciled_cases+1
        elseif reconcile_phase=="busy" then
          busy_reconciled_cases=busy_reconciled_cases+1
        end
        local integrity_status,proof=gui_context:revalidation_status()
        if integrity_status.blocked then
          if not integrity_status.verified or not proof then
            finish_matrix(false,integrity_status.reason or "integrity blocker has no verified proof");return
          end
          local valid,reason=gui_context:revalidate(proof)
          if not valid then finish_matrix(false,reason or "read-only revalidation failed");return end
        end
        local target_state=gui_context:target_state()
        if target_state.kind~="owned" or not rawequal(target_state.phrase,phrase) then
          finish_matrix(false,target_state.reason or "restored target did not classify as the same Owned phrase");return
        end
        local eligible,eligibility_error=gui_context:musical_eligibility()
        if not eligible or not rawequal(eligible.phrase,phrase) then
          finish_matrix(false,eligibility_error or "restored destination is not eligible for musical writes");return
        end
        action()
      end
      if not reconcile_before then wait_idle(continue);return end
      local deadline=os.time()+IDLE_RECONCILE_TIMEOUT_SECONDS
      local idle=renoise.tool().app_idle_observable
      local notifier
      notifier=function()
        local state=ui_state()
        local target=gui_context:target_state()
        if gui_reconcile_calls>reconcile_before and state.idle_listener_attached and
            target.kind=="owned" and rawequal(target.phrase,phrase) then
          pcall(function() idle:remove_notifier(notifier) end)
          continue()
          return
        end
        if os.time()>=deadline then
          pcall(function() idle:remove_notifier(notifier) end)
          finish_matrix(false,string.format(
            "production idle reconciliation timed out (calls=%d baseline=%d idle=%s target=%s)",
            gui_reconcile_calls,reconcile_before,tostring(state.idle_listener_attached),tostring(target.kind)))
        end
      end
      idle:add_notifier(notifier)
    end
    local function run_next_matrix_case()
      matrix_index=matrix_index+1
      local case=matrix[matrix_index]
      if not case then finish_matrix(true);return end
      if not case.column or
          (case.column==VISIBLE_COLUMN and phrase.visible_note_columns<VISIBLE_COLUMN) or
          (case.column==HIDDEN_COLUMN and phrase.visible_note_columns>=HIDDEN_COLUMN) then
        finish_matrix(false,"native observer case does not match the visible or hidden column setup");return
      end
      if writer.state()~="idle" then
        finish_matrix(false,"writer was not idle at the start of a native observer case");return
      end
      local idle_store=renoise.song().tool_data
      local idle_phrase_count=#instrument.phrases
      local baseline=ownership.snapshot(phrase)
      local reconcile_before=gui_reconcile_calls
      change_column(case,true)
      local changed_snapshot=ownership.snapshot(phrase)
      local changed=ownership.compare(baseline,changed_snapshot)
      if not baseline or not changed_snapshot or changed then
        finish_matrix(false,"idle native column edit did not change the phrase snapshot");return
      end
      local idle_eligible,idle_reason=gui_context:musical_eligibility()
      if idle_eligible then finish_matrix(false,"idle native edit retained write eligibility");return end
      change_column(case,false)
      if renoise.song().tool_data~=idle_store or #instrument.phrases~=idle_phrase_count then
        finish_matrix(false,"idle native observer changed source storage or phrase inventory");return
      end
      revalidate_then(function()
        local store_before=renoise.song().tool_data
        local count_before=#instrument.phrases
        local cancellations_before=cancel_calls
        local busy_reconcile_before=gui_reconcile_calls
        generate()
        local writer_status,writer_token=writer.state()
        if writer_status~="busy" or writer_token==nil then
          finish_matrix(false,"production GUI did not start the requested writer operation");return
        end
        local retained_value=change_column(case,true)
        if cancel_calls<=cancellations_before or not rawequal(last_cancel_token,writer_token) then
          finish_matrix(false,"native column edit did not synchronously cancel the active writer token");return
        end
        busy_cases=busy_cases+1
        canceled_cases=canceled_cases+1
        if writer.state()~="busy" then finish_matrix(false,"writer occupancy ended before terminal delivery");return end
        local expected=ownership.snapshot(phrase)
        local waits=0
        local idle=renoise.tool().app_idle_observable
        local terminal
        terminal=function()
          if writer.state()=="busy" then
            waits=waits+1
            if waits>IDLE_TIMEOUT then
              pcall(function() idle:remove_notifier(terminal) end)
              finish_matrix(false,"canceled writer terminal was not delivered")
            end
            return
          end
          pcall(function() idle:remove_notifier(terminal) end)
          local actual=ownership.snapshot(phrase)
          local matches,reason=ownership.compare(expected,actual)
          local retained=case.kind=="name" and phrase:column_name(case.column)==retained_value or
            case.kind=="mute" and phrase:column_is_muted(case.column)==retained_value
          if not matches or not retained or renoise.song().tool_data~=store_before or
              #instrument.phrases~=count_before or #instrument.phrases~=phrase_count then
            finish_matrix(false,reason or "canceled writer changed destination, source store or inventory")
            return
          end
          preserved_cases=preserved_cases+1
          change_column(case,false)
          revalidate_then(run_next_matrix_case,busy_reconcile_before,"busy")
        end
        idle:add_notifier(terminal)
      end,reconcile_before,"idle")
    end
    finish_matrix=function(ok,reason)
      if not ok then pcall(function() gui_dialog:close() end);fail(reason);return end
      generate()
      if writer.state()~="busy" then pcall(function() gui_dialog:close() end);fail("explicit Generate did not start after matrix");return end
      local waits=0
      local idle=renoise.tool().app_idle_observable
      local fresh_terminal
      fresh_terminal=function()
        if writer.state()=="busy" then
          waits=waits+1
          if waits>IDLE_TIMEOUT then
            pcall(function() idle:remove_notifier(fresh_terminal) end)
            pcall(function() gui_dialog:close() end);fail("fresh explicit Generate did not settle")
          end
          return
        end
        pcall(function() idle:remove_notifier(fresh_terminal) end)
        local generation=gui_context:generation_state()
        local passed=generation.status=="COMMITTED" and not gui_context:integrity_state().blocked and
          #instrument.phrases==phrase_count
        if not passed then fail("fresh explicit Generate failed after revalidation");return end
        local original_mark_dirty=gui_context.mark_dirty
        local dirty_calls=0
        gui_context.mark_dirty=function(self,...)
          dirty_calls=dirty_calls+1
          return original_mark_dirty(self,...)
        end
        local original_session=gui_context:lifetime_state().session
        pcall(function() gui_dialog:close() end)
        production_dialog=gui_dialog
        local close_waits=0
        local closed
        closed=function()
          close_waits=close_waits+1
          if gui_context:lifetime_state().open and close_waits<=IDLE_TIMEOUT then return end
          pcall(function() idle:remove_notifier(closed) end)
          if gui_context:lifetime_state().open then
            gui_context.mark_dirty=original_mark_dirty
            fail("GUI did not close through idle reconciliation");return
          end
          local closed_state=ui_state()
          if closed_state.native_observers_attached or closed_state.native_listener_count~=0 or
              closed_state.idle_listener_attached then
            gui_context.mark_dirty=original_mark_dirty
            fail(string.format("closed GUI retained observers (attached=%s listeners=%s idle=%s error=%s)",
              tostring(closed_state.native_observers_attached),tostring(closed_state.native_listener_count),
              tostring(closed_state.idle_listener_attached),
              tostring(closed_state.native_observer_error or closed_state.observer_error)));return
          end
          local dirty_when_closed=dirty_calls
          local saved_name=phrase:column_name(VISIBLE_COLUMN)
          phrase:set_column_name(VISIBLE_COLUMN,saved_name.." closed")
          local detached_check
          detached_check=function()
            pcall(function() idle:remove_notifier(detached_check) end)
            if dirty_calls~=dirty_when_closed then
              gui_context.mark_dirty=original_mark_dirty
              fail("dialog-scoped native observer remained active after close");return
            end
            local before_new_dialog=gui_context:lifetime_state().session
            local reopened,reopen_error=show_gui()
            if not reopened or not gui_dialog or not gui_context:lifetime_state().open or
                gui_context:lifetime_state().session<=before_new_dialog then
              gui_context.mark_dirty=original_mark_dirty
              fail("production GUI failed to reopen: "..tostring(reopen_error));return
            end
            local reopened_state=ui_state()
            if not reopened_state.native_observers_attached or
                reopened_state.native_listener_count~=initial_listener_count or
                not reopened_state.idle_listener_attached then
              gui_context.mark_dirty=original_mark_dirty
              fail("reopened GUI did not attach one complete native and idle observer set");return
            end
            production_dialog=gui_dialog
            local dirty_before_reopen_edit=dirty_calls
            phrase:set_column_name(VISIBLE_COLUMN,saved_name)
            if dirty_calls<=dirty_before_reopen_edit then
              gui_context.mark_dirty=original_mark_dirty
              fail("reopened dialog did not restore native invalidation");return
            end
            local release_seen=false
            local new_document_count=0
            local new_song_distinct=false
            local original_epoch=gui_context:lifetime_state().epoch
            local new_song_gui_attached=false
            local release_notifier=function()
              release_seen=true
            end
            local new_document_notifier=function()
              new_document_count=new_document_count+1
              if new_document_count==1 then new_song_distinct=not rawequal(renoise.song(),song) end
            end
            local tool=renoise.tool()
            tool.app_release_document_observable:add_notifier(release_notifier)
            tool.app_new_document_observable:add_notifier(new_document_notifier)
            lifecycle_fixture_path=renoise.tool().bundle_path..
              "\\..\\fixtures\\acceptance-integrity-observers.xrns"
            local fixture,save_error=save_independent_fixture(song,"acceptance-integrity-observers.xrns")
            if not fixture then
              pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
              pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
              gui_context.mark_dirty=original_mark_dirty
              fail(save_error or "disposable lifecycle song could not be saved");return
            end
            local app=renoise.app()
            local changed,new_error=pcall(function() app:new_song_no_template() end)
            if not changed then
              pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
              pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
              gui_context.mark_dirty=original_mark_dirty
              fail("native new-song request failed: "..tostring(new_error));return
            end
            local lifecycle_waits=0
            local lifecycle
            lifecycle=function()
              lifecycle_waits=lifecycle_waits+1
              if (not release_seen or new_document_count<1) and lifecycle_waits<=IDLE_TIMEOUT then return end
              pcall(function() idle:remove_notifier(lifecycle) end)
              if not release_seen or new_document_count<1 or gui_context:lifetime_state().song_attached then
                pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
                pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
                gui_context.mark_dirty=original_mark_dirty
                fail("new-song lifecycle retained the old production context");return
              end
              local released_state=ui_state()
              if released_state.native_observers_attached or released_state.native_listener_count~=0 or
                  released_state.idle_listener_attached then
                pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
                pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
                gui_context.mark_dirty=original_mark_dirty
                fail("released song retained native or idle observers");return
              end
              local shown,show_error=show_gui()
              local attached_state=ui_state()
              local attached_lifetime=gui_context:lifetime_state()
              if not shown or not gui_dialog or not attached_lifetime.song_attached or
                  attached_lifetime.epoch<=original_epoch or not attached_state.native_observers_attached or
                  attached_state.native_listener_count<=0 or not attached_state.idle_listener_attached then
                pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
                pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
                gui_context.mark_dirty=original_mark_dirty
                fail("GUI did not attach exactly one observer set to the new song: "..tostring(show_error));return
              end
              local attached_listener_count=attached_state.native_listener_count
              local shown_again,show_again_error=show_gui()
              local repeated_state=ui_state()
              if not shown_again or repeated_state.native_listener_count~=attached_listener_count or
                  not repeated_state.native_observers_attached or not repeated_state.idle_listener_attached then
                pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
                pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
                gui_context.mark_dirty=original_mark_dirty
                fail("repeated new-song GUI show duplicated or lost observers: "..tostring(show_again_error));return
              end
              new_song_gui_attached=true
              local before_load=new_document_count
              local loaded,load_error=pcall(function() app:load_song(renoise.tool().bundle_path..
                "\\..\\fixtures\\acceptance-integrity-observers.xrns") end)
              if not loaded then
                pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
                pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
                gui_context.mark_dirty=original_mark_dirty
                fail("saved disposable song could not be reloaded: "..tostring(load_error));return
              end
              local reload_waits=0
              local reloaded
              reloaded=function()
                reload_waits=reload_waits+1
                if new_document_count<=before_load and reload_waits<=IDLE_TIMEOUT then return end
                pcall(function() idle:remove_notifier(reloaded) end)
                pcall(function() tool.app_release_document_observable:remove_notifier(release_notifier) end)
                pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end)
                gui_context.mark_dirty=original_mark_dirty
                pcall(os.remove,renoise.tool().bundle_path.."\\..\\fixtures\\acceptance-integrity-observers.xrns")
                lifecycle_fixture_path=nil
                local matrix_passed=idle_reconciled_cases==#matrix and busy_reconciled_cases==#matrix and
                  busy_cases==#matrix and
                  canceled_cases==#matrix and preserved_cases==#matrix and generate_calls==#matrix+1
                local old_context_attached=gui_context:lifetime_state().song_attached
                local passed=new_document_count>before_load and new_song_distinct and new_song_gui_attached and
                  not old_context_attached and matrix_passed and generation.status=="COMMITTED"
                local failure_reason
                if new_document_count<=before_load or not new_song_distinct then
                  failure_reason="new-song and reload document events were not observed"
                elseif old_context_attached then
                  failure_reason="old GUI context reattached during song reload"
                elseif not new_song_gui_attached then
                  failure_reason="new-song GUI failed native observer attachment checks"
                elseif not matrix_passed then
                  failure_reason=string.format(
                    "native matrix incomplete (idle_reconciled=%d busy_reconciled=%d busy=%d canceled=%d preserved=%d generates=%d)",
                    idle_reconciled_cases,busy_reconciled_cases,busy_cases,canceled_cases,preserved_cases,generate_calls)
                elseif generation.status~="COMMITTED" then
                  failure_reason="fresh Generate ended with status "..tostring(generation.status)
                end
                production_context,production_dialog=nil,nil
                done({status=passed and "PASS" or "FAIL",case="integrity-observers",
                  post_commit_blocked=true,revalidation_required=true,restored_destination_revalidated=true,
                  visible_hidden_name_mute_idle_busy=matrix_passed,
                  active_writer_canceled=canceled_cases==#matrix,
                  canceled_destination_and_store_preserved=preserved_cases==#matrix,
                  gui_idle_reconciled=idle_reconciled_cases==#matrix and busy_reconciled_cases==#matrix,
                  idle_reconciled_cases=idle_reconciled_cases,busy_reconciled_cases=busy_reconciled_cases,
                  dialog_close_reopen_detached=closed_state.native_listener_count==0 and
                    reopened_state.native_listener_count==initial_listener_count,
                  old_song_released=release_seen,new_song_gui_attached=new_song_gui_attached,
                  listeners_detached=release_seen and released_state.native_listener_count==0 and
                    not released_state.idle_listener_attached,
                  generation_calls=generate_calls,fresh_commit=generation.status,
                  reason=failure_reason})
              end
              idle:add_notifier(reloaded)
            end
            idle:add_notifier(lifecycle)
          end
          idle:add_notifier(detached_check)
        end
        idle:add_notifier(closed)
      end
      idle:add_notifier(fresh_terminal)
    end
    run_next_matrix_case()
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

local run_editor_responsiveness

local function run_multi_instrument_workflow(done, json)
  local song = renoise.song()
  local sequence = require("model.sequencer")
  local writer = require("writers.phrase_writer")
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local start_instrument_count = #song.instruments
  local start_phrase_count = 0
  for _, instrument in ipairs(song.instruments) do start_phrase_count = start_phrase_count + #instrument.phrases end
  if start_instrument_count < WORKFLOW_INSTRUMENT_COUNT or start_phrase_count ~= 0 then
    done({ status = "FAIL", case = "multi-instrument-workflow",
      reason = "acceptance requires the runner's fresh empty song",
      instrument_count = start_instrument_count, phrase_count = start_phrase_count })
    return true
  end

  local instruments, instrument_indices, targets, foreign, list_observers = {}, {}, {}, {}, {}
  local playback_asserted = false
  local playback_tracks = {}
  local playback_transport_started = false
  local native_identity_registry, next_native_identity = {}, 0
  local trace, active_operation = {}, "setup"
  local transaction_count, completed, selection_checks = 0, false, true
  local function selection_state()
    local instrument_index = song.selected_instrument_index
    local phrase_index = song.selected_phrase_index
    local instrument = instrument_index > 0 and song.instruments[instrument_index] or nil
    local phrase = instrument and phrase_index > 0 and instrument.phrases[phrase_index] or nil
    return {
      instrument = instrument,
      phrase = phrase,
      instrument_index = instrument_index,
      phrase_index = phrase_index,
      instrument_identity = instrument_index > 0 and
        ("instrument:" .. tostring(instrument_index) .. ":" .. tostring(instrument and instrument.name or "")) or "none",
      phrase_identity = phrase and
        ((ownership.id(phrase) and ("owned:" .. tostring(ownership.id(phrase)))) or
          ((phrase.name or "") ~= "" and ("phrase:" .. phrase.name) or "phrase:unnamed")) or "none",
    }
  end
  local function same_selection(left, right)
    return rawequal(left.instrument, right.instrument) and
      rawequal(left.phrase, right.phrase) and
      left.instrument_index == right.instrument_index and
      left.phrase_index == right.phrase_index
  end
  -- Renoise can create fresh userdata wrappers for a native object between reads.
  -- Compare wrappers directly instead of using them as table keys for trace IDs.
  local function native_identity(value)
    if value == nil then return 0 end
    for _, record in ipairs(native_identity_registry) do
      if rawequal(record.value, value) then return record.id end
    end
    next_native_identity = next_native_identity + 1
    native_identity_registry[#native_identity_registry + 1] = { value = value, id = next_native_identity }
    return next_native_identity
  end
  local function phrase_names(instrument)
    local names = json.array()
    for index, phrase in ipairs(instrument.phrases) do names[index] = phrase.name end
    return names
  end
  local function phrase_identity_label(phrase)
    local id = ownership.id(phrase)
    if id then return "owned:" .. tostring(id) end
    local name = tostring(phrase.name or "")
    if name:match("^Workflow foreign ") then return "foreign:" .. name end
    return "temporary:" .. (name ~= "" and name or "unnamed")
  end
  local function stop_observers()
    for _, record in ipairs(list_observers) do
      pcall(function() record.observable:remove_notifier(record.notifier) end)
    end
    list_observers = {}
  end
  local function finish(status, reason, extra)
    if completed then return end
    completed = true
    if playback_transport_started then
      pcall(function() song.transport:stop() end)
      playback_transport_started = false
    end
    stop_observers()
    local trace_summary = json.array()
    for index, event in ipairs(trace) do
      trace_summary[index] = {
        operation = event.operation,
        event = event.event,
        instrument_index = event.instrument_index,
        instrument_phrase_count = event.instrument_phrase_count,
        instrument_phrase_names = event.instrument_phrase_names,
        instrument_phrase_identity_order = event.instrument_phrase_identity_order,
        instrument_phrase_identity_labels = event.instrument_phrase_identity_labels,
        selected_instrument_index = event.selected_instrument_index,
        selected_phrase_index = event.selected_phrase_index,
        selected_instrument_identity = event.selected_instrument_identity,
        selected_phrase_identity = event.selected_phrase_identity,
        selected_instrument_label = event.selected_instrument_label,
        selected_phrase_label = event.selected_phrase_label,
        selection_stable = event.selection_stable == true,
      }
    end
    local summary = {
      status = status,
      case = "multi-instrument-workflow",
      reason = reason,
      instrument_count = #instruments,
      phrase_count = 0,
      phrases_per_instrument = json.array(),
      owned_targets = #targets,
      foreign_targets = #foreign,
      transaction_count = transaction_count,
      selection_trace = trace_summary,
      user_navigation_injected = false,
      selection_stable = selection_checks,
      playback_asserted = playback_asserted,
      playback_track_count = #playback_tracks,
      live_edit_asserted = false,
      persistence_asserted = false,
    }
    for index, instrument in ipairs(instruments) do
      local count = #instrument.phrases
      summary.phrase_count = summary.phrase_count + count
      summary.phrases_per_instrument[index] = count
    end
    for key, value in pairs(extra or {}) do summary[key] = value end
    done(summary)
  end
  local function record_selection(event_kind, instrument_index)
    local selected = selection_state()
    local instrument = instruments[instrument_index]
    local event = {
      operation = active_operation,
      event = event_kind,
      instrument_index = instrument_index,
      instrument_phrase_count = instrument and #instrument.phrases or 0,
      instrument_phrase_names = instrument and phrase_names(instrument) or json.array(),
      instrument_phrase_identity_order = json.array(),
      instrument_phrase_identity_labels = json.array(),
      selected_instrument_index = selected.instrument_index,
      selected_phrase_index = selected.phrase_index,
      selected_instrument_identity = native_identity(selected.instrument),
      selected_phrase_identity = native_identity(selected.phrase),
      selected_instrument_label = selected.instrument_identity,
      selected_phrase_label = selected.phrase_identity,
      selection_state = selected,
    }
    if instrument then
      for index, phrase in ipairs(instrument.phrases) do
        event.instrument_phrase_identity_order[index] = native_identity(phrase)
        event.instrument_phrase_identity_labels[index] = phrase_identity_label(phrase)
      end
    end
    trace[#trace + 1] = event
    return selected
  end
  local function attach_list_observer(instrument, instrument_index)
    local observable = instrument.phrases_observable
    local notifier = function() record_selection("phrase-list-change", instrument_index) end
    observable:add_notifier(notifier)
    list_observers[#list_observers + 1] = { observable = observable, notifier = notifier }
  end
  for _, record in ipairs({
      { observable = song.selected_instrument_observable, name = "selected-instrument-change" },
      { observable = song.selected_phrase_observable, name = "selected-phrase-change" },
    }) do
    local event_name = record.name
    local notifier = function() record_selection(event_name, song.selected_instrument_index) end
    record.observable:add_notifier(notifier)
    list_observers[#list_observers + 1] = { observable = record.observable, notifier = notifier }
  end
  local function source_for(key)
    local source = sequence.new_pattern(ACCEPTANCE_PATTERN_LENGTH)
    source.pitch_events[FIRST_NOTE_LINE] = sequence.new_pitch(key, ACCEPTANCE_KEY, true, false)
    return source
  end
  local fixture_selection = selection_state()
  local function inventory_baseline()
    local inventory = {}
    for instrument_index, instrument in ipairs(instruments) do
      local phrases = {}
      for phrase_index, phrase in ipairs(instrument.phrases) do
        local snapshot = ownership.snapshot(phrase)
        if not snapshot then error("native phrase snapshot is unavailable") end
        local id = ownership.id(phrase)
        local source, policy, pb_range
        if id then source, policy, pb_range = store.read_entry(song, id) end
        phrases[phrase_index] = { phrase = phrase, snapshot = snapshot, id = id,
          source = source, output_policy = policy, pb_range = pb_range }
      end
      inventory[instrument_index] = phrases
    end
    return inventory
  end
  local function inventory_unchanged_except(before, target)
    for instrument_index, instrument in ipairs(instruments) do
      local expected = before[instrument_index]
      if not expected or #expected ~= #instrument.phrases then return false end
      for phrase_index, phrase in ipairs(instrument.phrases) do
        local old = expected[phrase_index]
        if not old or not rawequal(old.phrase, phrase) then return false end
        if not rawequal(phrase, target) then
          local snapshot = ownership.snapshot(phrase)
          if not snapshot or not ownership.compare(old.snapshot, snapshot) then return false end
          if ownership.id(phrase) ~= old.id then return false end
          if old.id then
            local source, policy, pb_range = store.read_entry(song, old.id)
            if not source or not old.source or not sequence.same_source(old.source, source) or
                policy ~= old.output_policy or pb_range ~= old.pb_range then return false end
          end
        end
      end
    end
    return true
  end

  local function on_created(target_record, result, next_step, before_phrases)
    if type(result) ~= "table" or result.kind ~= "success" or result.verified ~= true or not result.phrase then
      finish("FAIL", describe_failure(result or "writer create did not return a verified phrase"))
      return
    end
    local instrument = target_record.instrument
    local phrase = result.phrase
    local id = ownership.id(phrase)
    local source, policy, pb_range
    if id then source, policy, pb_range = store.read_entry(song, id) end
    if not id or not source then
      finish("FAIL", "created target has no persisted source association")
      return
    end
    local inventory_ok = #instrument.phrases == #before_phrases + 1 and
      rawequal(instrument.phrases[#instrument.phrases], phrase)
    if inventory_ok then
      for index, old in ipairs(before_phrases) do
        if not rawequal(instrument.phrases[index], old.phrase) then inventory_ok = false; break end
        local snapshot = ownership.snapshot(old.phrase)
        if not snapshot or not ownership.compare(old.snapshot, snapshot) or ownership.id(old.phrase) ~= old.id then
          inventory_ok = false; break
        end
        if old.id then
          local old_source, old_policy, old_pb_range = store.read_entry(song, old.id)
          if not old_source or not old.source or not sequence.same_source(old.source, old_source) or
              old_policy ~= old.output_policy or old_pb_range ~= old.pb_range then
            inventory_ok = false; break
          end
        end
      end
    end
    if not inventory_ok then
      finish("FAIL", "phrase creation changed existing phrase identity, content, order, or count")
      return
    end
    target_record.phrase = phrase
    target_record.id = id
    target_record.source = source
    target_record.output_policy = policy
    target_record.pb_range = pb_range
    next_step()
  end

  local function create_target(target_record, note, next_step)
    local selection_before = selection_state()
    local before_phrases = {}
    for index, phrase in ipairs(target_record.instrument.phrases) do
      local snapshot = ownership.snapshot(phrase)
      if not snapshot then finish("FAIL", "cannot snapshot phrases before create transaction"); return end
      local id = ownership.id(phrase)
      local source, policy, pb_range
      if id then source, policy, pb_range = store.read_entry(song, id) end
      before_phrases[index] = { phrase = phrase, snapshot = snapshot, id = id,
        source = source, output_policy = policy, pb_range = pb_range }
    end
    active_operation = "create instrument " .. tostring(target_record.instrument_index) .. " target " .. tostring(target_record.slot)
    local trace_start = #trace + 1
    local request, request_error = factory.build(song, target_record.instrument_index,
      source_for(note), #target_record.instrument.phrases + 1)
    if not request or request.kind ~= "create" then
      finish("FAIL", describe_failure(request_error or "target creation request was not accepted"))
      return
    end
    transaction_count = transaction_count + 1
    local accepted, start_error = writer.create(request, function(result)
      on_next_idle(function()
        record_selection("transaction-settled", target_record.instrument_index)
        for index = trace_start, #trace do
          trace[index].selection_stable = same_selection(selection_before, trace[index].selection_state)
          if not trace[index].selection_stable then selection_checks = false end
        end
        if not same_selection(selection_before, selection_state()) then selection_checks = false end
        on_created(target_record, result, next_step, before_phrases)
      end)
    end)
    if not accepted then finish("FAIL", describe_failure(start_error)) end
    target_record.selection_before = selection_before
  end

  local function add_foreign(instrument_index, slot)
    local instrument = instruments[instrument_index]
    local selection_before = selection_state()
    local trace_start = #trace + 1
    local phrase = instrument:insert_phrase_at(#instrument.phrases + 1)
    phrase.name = "Workflow foreign " .. tostring(instrument_index) .. " " .. tostring(slot)
    if not same_selection(selection_before, selection_state()) then
      record_selection("transaction-settled", instrument_index)
      selection_checks = false
    end
    for index = trace_start, #trace do
      trace[index].selection_stable = same_selection(selection_before, trace[index].selection_state)
      if not trace[index].selection_stable then selection_checks = false end
    end
    foreign[#foreign + 1] = { instrument = instrument, phrase = phrase, name = phrase.name }
    return phrase
  end

  local instrument_index = 1
  for index = 1, WORKFLOW_INSTRUMENT_COUNT do
    local native_index = index
    local instrument = song.instruments[native_index]
    instrument.name = "Workflow instrument " .. tostring(index)
    instruments[index] = instrument
    instrument_indices[index] = native_index
    attach_list_observer(instrument, index)
  end
  local function create_sample(instrument, label)
    if #instrument.samples == 0 then instrument:insert_sample_at(1) end
    local sample = instrument.samples[1]
    local buffer = sample.sample_buffer
    local frame_count = 256
    if not buffer:create_sample_data(44100, 16, 1, frame_count) then
      return nil, label .. " sample allocation failed"
    end
    buffer:prepare_sample_data_changes()
    local finalized = false
    local ok, err = pcall(function()
      for frame = 1, frame_count do
        buffer:set_sample_data(1, frame, math.sin(frame * math.pi * 2 / frame_count) * 0.2)
      end
      buffer:finalize_sample_data_changes()
      finalized = true
    end)
    if not finalized then pcall(buffer.finalize_sample_data_changes, buffer) end
    if not ok then return nil, label .. " sample data setup failed: " .. tostring(err) end
    sample.name = label .. " sample"
    return true
  end
  local sample_a, sample_a_error = create_sample(instruments[1], "Workflow A")
  local sample_c, sample_c_error = create_sample(instruments[3], "Workflow C")
  if not sample_a or not sample_c then
    finish("FAIL", tostring(sample_a_error or sample_c_error))
    return
  end
  local plugin_properties = instruments[2].plugin_properties
  local plugin_info
  for _, info in ipairs(plugin_properties.available_plugin_infos) do
    local name = type(info.name) == "string" and info.name:lower() or ""
    if name:find("surge", 1, true) and type(info.path) == "string" and info.path ~= "" then
      plugin_info = info
      break
    end
  end
  if not plugin_info then
    finish("FAIL", "Surge VST plugin is not available in Renoise's plugin registry")
    return
  end
  local plugin_loaded, plugin_error = pcall(instruments[2].plugin_properties.load_plugin,
    instruments[2].plugin_properties, plugin_info.path)
  if not plugin_loaded or not instruments[2].plugin_properties.plugin_loaded then
    finish("FAIL", "Surge VST could not be loaded: " .. tostring(plugin_error or plugin_info.name))
    return
  end
  local sequencer_track_indices = {}
  for track_index, track in ipairs(song.tracks) do
    if track.type == renoise.Track.TRACK_TYPE_SEQUENCER then
      sequencer_track_indices[#sequencer_track_indices + 1] = track_index
    end
  end
  while #sequencer_track_indices < 4 do
    song:insert_track_at(#song.tracks)
    sequencer_track_indices = {}
    for track_index, track in ipairs(song.tracks) do
      if track.type == renoise.Track.TRACK_TYPE_SEQUENCER then
        sequencer_track_indices[#sequencer_track_indices + 1] = track_index
      end
    end
  end
  local program_instruments = { instruments[1], instruments[2], instruments[3], instruments[1] }
  local pattern = song.patterns[1]
  for track_slot = 1, 4 do
    local track_index = sequencer_track_indices[track_slot]
    local track = song.tracks[track_index]
    if track.visible_note_columns < 1 then track.visible_note_columns = 1 end
    local column = pattern.tracks[track_index]:line(1):note_column(1)
    local instrument_slot
    for index, instrument in ipairs(song.instruments) do
      if rawequal(instrument, program_instruments[track_slot]) then instrument_slot = index - 1; break end
    end
    if instrument_slot == nil then
      finish("FAIL", "A workflow playback instrument is missing from the song")
      return
    end
    column.note_value = 48 + track_slot - 1
    column.instrument_value = instrument_slot
    playback_tracks[track_slot] = { track_index = track_index, instrument = program_instruments[track_slot],
      note_value = column.note_value, instrument_value = column.instrument_value }
  end
  local function playback_tracks_intact()
    if #playback_tracks ~= 4 then return false end
    for _, record in ipairs(playback_tracks) do
      local track = song.tracks[record.track_index]
      local column = song.patterns[1].tracks[record.track_index]:line(1):note_column(1)
      local instrument = song.instruments[column.instrument_value + 1]
      if column.note_value ~= record.note_value or column.instrument_value ~= record.instrument_value or
          not rawequal(instrument, record.instrument) or track.type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
        return false
      end
    end
    return true
  end
  for _, event in ipairs(trace) do
    if event.operation == "setup" then
      event.selection_stable = same_selection(fixture_selection, event.selection_state)
    end
  end

  local function populate_instrument()
    if instrument_index > WORKFLOW_INSTRUMENT_COUNT then
      if #targets ~= WORKFLOW_INSTRUMENT_COUNT * WORKFLOW_OWNED_PER_INSTRUMENT or
          #foreign ~= WORKFLOW_INSTRUMENT_COUNT * WORKFLOW_FOREIGN_PER_INSTRUMENT then
        finish("FAIL", "fixture did not create the required owned and foreign phrase counts")
        return
      end
      for index, instrument in ipairs(instruments) do
        if #instrument.phrases ~= WORKFLOW_PHRASES_PER_INSTRUMENT then
          finish("FAIL", "instrument phrase count is not the required bounded fixture size")
          return
        end
        local expected_order = {
          targets[(index - 1) * 2 + 1].phrase,
          foreign[(index - 1) * 2 + 1].phrase,
          targets[(index - 1) * 2 + 2].phrase,
          foreign[(index - 1) * 2 + 2].phrase,
        }
        for phrase_index, phrase in ipairs(expected_order) do
          if not rawequal(instrument.phrases[phrase_index], phrase) then
            finish("FAIL", "fixture phrase ordering changed during setup")
            return
          end
        end
      end
      local original_inventory = inventory_baseline()
      local foreign_baselines = {}
      for index, item in ipairs(foreign) do
        foreign_baselines[index] = ownership.snapshot(item.phrase)
        if ownership.id(item.phrase) ~= nil or ownership.status(item.phrase) ~= "foreign" then
          finish("FAIL", "fixture phrase was not classified as foreign")
          return
        end
      end
      local target_cursor = 1
      local function regenerate_next()
        local target_record = targets[target_cursor]
        if not target_record then
          local final_inventory = true
          for index, item in ipairs(foreign) do
            local now = ownership.snapshot(item.phrase)
            if not now or not ownership.compare(foreign_baselines[index], now) or
                ownership.id(item.phrase) ~= nil or ownership.status(item.phrase) ~= "foreign" then
              final_inventory = false
            end
          end
          local ordered = true
          for index, instrument in ipairs(instruments) do
            local expected = original_inventory[index]
            if #instrument.phrases ~= WORKFLOW_PHRASES_PER_INSTRUMENT then ordered = false end
            for phrase_index, old in ipairs(expected) do
              if not rawequal(instrument.phrases[phrase_index], old.phrase) then ordered = false end
            end
          end
          local report_selection_stable = true
          for _, event in ipairs(trace) do
            if event.selection_stable ~= true then report_selection_stable = false end
          end
          local track_programs_valid = playback_tracks_intact()
          local passed = final_inventory and ordered and report_selection_stable and selection_checks and #trace > 0 and
            (#targets == 6) and (#foreign == 6) and transaction_count == 12 and
            playback_asserted and track_programs_valid
          if not passed then
            finish("FAIL", "multi-instrument regeneration changed phrase identity, content, order, count, playback programs, or native selection")
            return
          end
          if type(run_editor_responsiveness) ~= "function" then
            finish("FAIL", "Production GUI workflow probe is unavailable")
            return
          end
          run_editor_responsiveness(function(gui_result)
            local actions = type(gui_result) == "table" and gui_result.gui_action_names or ""
            local navigation_asserted = type(actions) == "string" and
              actions:find("new-phrase-target", 1, true) ~= nil and
              actions:find("owned-phrase-target", 1, true) ~= nil
            local live_edit_asserted = type(gui_result) == "table" and gui_result.status == "PASS" and
              gui_result.gui_live_synchronous_verified == true and
              gui_result.gui_live_final_result == "success" and
              gui_result.gui_live_committed_source_match == true
            local source_rows_verified = true
            for _, target_record in ipairs(targets) do
              local source, policy, pb = store.read_entry(song, target_record.id)
              if not source or not sequence.same_source(source, target_record.source) or
                  policy ~= target_record.output_policy or pb ~= target_record.pb_range then
                source_rows_verified = false
                break
              end
            end
            local gui_passed = type(gui_result) == "table" and gui_result.status == "PASS" and
              navigation_asserted and live_edit_asserted and source_rows_verified
            local gui_details = { user_navigation_injected = navigation_asserted,
              live_edit_asserted = live_edit_asserted,
              persistence_asserted = source_rows_verified,
              source_rows_verified = source_rows_verified,
              gui_live_reason = type(gui_result) == "table" and gui_result.reason or nil,
              gui_live_first_edit_elapsed_ms = type(gui_result) == "table" and
                gui_result.gui_live_first_edit_elapsed_ms or nil,
              gui_live_request_count = type(gui_result) == "table" and
                gui_result.gui_live_request_count or nil,
              gui_live_committed_source_match = type(gui_result) == "table" and
                gui_result.gui_live_committed_source_match or false,
              gui_workflow_status = type(gui_result) == "table" and gui_result.status or "missing",
              gui_workflow_action_names = actions }
            if type(gui_result) == "table" then
              for key, value in pairs(gui_result) do
                if type(key) == "string" and key:find("_profile_", 1, true) then
                  gui_details[key] = value
                end
              end
            end
            finish(gui_passed and "PASS" or "FAIL",
              not gui_passed and (type(gui_result) == "table" and gui_result.reason or "Production GUI Live Edit/navigation/persisted-source checks failed") or nil,
              gui_details)
          end)
          return
        end

        local target = target_record.phrase
        local instrument = target_record.instrument
        local phrase_index
        for index, candidate in ipairs(instrument.phrases) do
          if rawequal(candidate, target) then phrase_index = index; break end
        end
        if not phrase_index or ownership.id(target) ~= target_record.id then
          finish("FAIL", "owned target identity or index was lost before regeneration")
          return
        end
        local before_inventory = inventory_baseline()
        local before_selection = selection_state()
        local old_source = target_record.source
        local changed_source = sequence.copy_source(old_source)
        local old_event = changed_source.pitch_events[FIRST_NOTE_LINE]
        local changed_key = old_event and ((old_event.note - sequence.BASE_NOTE + 1) % 13) or target_cursor
        changed_source.pitch_events[FIRST_NOTE_LINE] = sequence.new_pitch(changed_key, ACCEPTANCE_KEY, true, false)
        local request, request_error = factory.build(song, target_record.instrument_index,
          changed_source, phrase_index)
        if not request or request.kind ~= "regenerate" then
          finish("FAIL", describe_failure(request_error or "owned target did not build a regenerate request"))
          return
        end
        active_operation = "regenerate instrument " .. tostring(target_record.instrument_index) ..
          " target " .. tostring(target_record.slot)
        transaction_count = transaction_count + 1
        local trace_start = #trace + 1
        local previous_id = target_record.id
        local previous_source = target_record.source
        local accepted, start_error = writer.regenerate(request, function(result)
          on_next_idle(function()
            local after_selection = selection_state()
            local new_id = ownership.id(target)
            local target_source, policy, pb_range
            if new_id then target_source, policy, pb_range = store.read_entry(song, new_id) end
            local historical_source, historical_policy, historical_pb
            historical_source, historical_policy, historical_pb = store.read_entry(song, previous_id)
            local target_snapshot = ownership.snapshot(target)
            local expected_output_note = sequence.BASE_NOTE + changed_key
            local expected_output_observed = false
            if target_snapshot then
              for _, line in ipairs(target_snapshot.lines) do
                for _, note in ipairs(line.notes) do
                  if note.note_value == expected_output_note then expected_output_observed = true end
                end
              end
            end
            local selection_stable = same_selection(before_selection, after_selection)
            record_selection("transaction-settled", target_record.instrument_index)
            if not selection_stable then selection_checks = false end
            local target_valid = type(result) == "table" and result.kind == "success" and
              result.verified == true and rawequal(result.phrase, target) and
              new_id and new_id ~= previous_id and
              rawequal(instrument.phrases[phrase_index], target) and
              #instrument.phrases == WORKFLOW_PHRASES_PER_INSTRUMENT and target_snapshot and
              expected_output_observed and
              target_source and sequence.same_source(target_source, changed_source) and
              policy == target_record.output_policy and pb_range == target_record.pb_range and
              historical_source and sequence.same_source(historical_source, previous_source) and
              historical_policy == target_record.output_policy and historical_pb == target_record.pb_range
            local peers_valid = inventory_unchanged_except(before_inventory, target)
            for _, event in ipairs(trace) do
              if event.operation == active_operation and event.selection_stable == nil then
                event.selection_stable = same_selection(before_selection, event.selection_state)
                if not event.selection_stable then selection_checks = false end
              end
            end
            if not selection_stable or not target_valid or not peers_valid then
              finish("FAIL", not selection_stable and "native selection changed during regeneration" or
                (not target_valid and describe_failure(result or "target did not regenerate in place") or
                  "another phrase or instrument changed during regeneration"))
              return
            end
            target_record.id = new_id
            target_record.source = changed_source
            target_cursor = target_cursor + 1
            regenerate_next()
          end)
        end)
        if not accepted then finish("FAIL", describe_failure(start_error)) end
      end
      local transport = song.transport
      local before_beats = transport.playback_pos_beats
      local started, start_error = pcall(transport.start, transport, renoise.Transport.PLAYMODE_RESTART_PATTERN)
      if not started or not transport.playing then
        finish("FAIL", "Four-track playback did not start: " .. tostring(start_error or "transport stopped"))
        return
      end
      playback_transport_started = true
      local playback_waits = 0
      local function verify_playback_progress()
        if completed then return end
        playback_waits = playback_waits + 1
        if playback_tracks_intact() and transport.playing and transport.playback_pos_beats > before_beats then
          playback_asserted = true
          regenerate_next()
          return
        end
        if playback_waits >= 600 then
          finish("FAIL", "Four-track playback did not advance with stable sample/VST program assignments")
          return
        end
        on_next_idle(verify_playback_progress)
      end
      on_next_idle(verify_playback_progress)
      return
    end

    local instrument = instruments[instrument_index]
    local first = { instrument = instrument, instrument_index = instrument_indices[instrument_index], slot = 1 }
    targets[#targets + 1] = first
    create_target(first, instrument_index, function()
      add_foreign(instrument_index, 1)
      local second = { instrument = instrument, instrument_index = instrument_indices[instrument_index], slot = 2 }
      targets[#targets + 1] = second
      create_target(second, instrument_index + WORKFLOW_INSTRUMENT_COUNT, function()
        add_foreign(instrument_index, 2)
        instrument_index = instrument_index + 1
        populate_instrument()
      end)
    end)
  end
  populate_instrument()
  return true
end

run_editor_responsiveness = function(done)
  local song=renoise.song()
  local store=require("renoise.pattern_store")
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
  local captured_baseline_is_opaque
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
          "classify_verified_postimage","classify_against_reference",
          "matches_snapshot","snapshot_index","ownership_status","make_name",
          "capture_recovery","make_name_from_verified_snapshot",
          "preflight_destination","store_allocate","store_prepare_revision","store_commit",
          "materializer_apply","materializer_verify","materializer_restore",
          "context_adopt","runtime_request_guard","runtime_inventory_guard",
          "plan","restore_editor_target","transition","render_project","render_step_text",
          "request_new","request_capture","request_checkpoint","writer_create","writer_regenerate"}) do
        local item=phrase_profile[name] or {calls=0,elapsed_ms=0}
        metrics[prefix.."_"..name.."_calls"]=item.calls
        metrics[prefix.."_"..name.."_elapsed_ms"]=item.elapsed_ms
      end
    end
    local planner=require("model.output_planner")
    local request_module=require("runtime.requests")
    local inventory_module=require("runtime.inventory")
    local materializer=require("writers.phrase_materializer")
    local store=require("renoise.pattern_store")
    local original_requests_new=request_module.new
    local original_inventory_new=inventory_module.new
    request_module.new=function(access)
      local owner=original_requests_new(access)
      profile_function(owner,"capture","request_capture")
      profile_function(owner,"validate_checkpoint","request_checkpoint")
      return owner
    end
    phrase_profile_restore[#phrase_profile_restore+1]={target=request_module,key="new",original=original_requests_new}
    inventory_module.new=function(...)
      local owner=original_inventory_new(...)
      profile_function(owner,"adopt","context_adopt")
      return owner
    end
    phrase_profile_restore[#phrase_profile_restore+1]={target=inventory_module,key="new",original=original_inventory_new}
    profile_function(writer,"create","writer_create")
    profile_function(writer,"regenerate","writer_regenerate")
    profile_function(request_module,"new","request_new")
    profile_function(ownership,"snapshot","snapshot")
    profile_function(ownership,"copy_snapshot","copy_snapshot")
    profile_function(ownership,"compare","compare")
    profile_function(ownership,"matches_snapshot","matches_snapshot")
    profile_function(ownership,"snapshot_index","snapshot_index")
    profile_function(ownership,"status","ownership_status")
    profile_function(ownership,"make_name","make_name")
    profile_function(ownership,"capture_recovery","capture_recovery")
    profile_function(ownership,"make_name_from_verified_snapshot","make_name_from_verified_snapshot")
    profile_function(validator,"classify","classify")
    profile_function(validator,"classify_against","classify_against")
    profile_function(validator,"classify_verified_postimage","classify_verified_postimage")
    profile_function(validator,"classify_against_reference","classify_against_reference")
    profile_function(validator,"preflight_destination","preflight_destination")
    profile_function(store,"allocate","store_allocate")
    profile_function(store,"prepare_revision","store_prepare_revision")
    profile_function(store,"commit","store_commit")
    profile_function(materializer,"apply","materializer_apply")
    profile_function(materializer,"verify","materializer_verify")
    profile_function(materializer,"restore","materializer_restore")
    profile_function(planner,"plan","plan")
    profile_function(planner,"plan_for_materialization","plan")
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
      profile_function(gui_context,"matches_mutation_inventory","runtime_inventory_guard")
      profile_function(gui_context,"request_generation","runtime_request_guard")
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
    local shown,show_error=pcall(function() require("gui").show() end)
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
      local before_revision_id=ownership.id(phrase)
      local before_committed_source,before_committed_policy,before_committed_pb
      if before_revision_id then
        before_committed_source,before_committed_policy,before_committed_pb=
          store.read_entry(song,before_revision_id)
      end
      if not before_live or live_index<1 or live_index>before_live.length then
        finished(false,"Live Edit test could not read the selected source pitch")
        return
      end
      local arm_count=callback_counts.acid_live_edit or 0
      local request_trace_before=#gui_live_request_trace
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
      local current_revision_id=ownership.id(phrase)
      local latest_source,latest_policy,latest_pb=store.read_entry(song,current_revision_id)
      local old_source_retained,old_policy_retained,old_pb_retained
      if before_revision_id then
        old_source_retained,old_policy_retained,old_pb_retained=
          store.read_entry(song,before_revision_id)
      end
      local editor_state=live_context and live_context:editor_state()
      local output_value=phrase:line(live_index):note_column(1).note_value
      local output_matches=latest_source and
        latest_source.pitch_events[live_index].key==first_value-1 and
        output_value==latest_source.pitch_events[live_index].note and
        editor_state and sequence.same_source(editor_state.source,latest_source)
      local writer_state=writer.state()
      local live_result=first_state.last_result
      local draft=persisted.read_draft(song,instrument,phrase)
      local request_count=#gui_live_request_trace-request_trace_before
      metrics.gui_live_transition_trace=table.concat(gui_live_trace,";")
      metrics.gui_live_request_count=request_count
      metrics.gui_live_revision_id_advanced=current_revision_id~=nil and current_revision_id~=before_revision_id
      metrics.gui_live_prior_source_retained=old_source_retained~=nil and
        before_committed_source~=nil and sequence.same_source(old_source_retained,before_committed_source) and
        old_policy_retained==before_committed_policy and old_pb_retained==before_committed_pb
      metrics.gui_live_writer_idle_at_return=writer_state=="idle"
      metrics.gui_live_terminal_status=tostring(first_state.status)
      metrics.gui_live_terminal_result=live_result and tostring(live_result.kind) or "missing"
      metrics.gui_live_final_result=live_result and tostring(live_result.kind) or "missing"
      metrics.gui_live_pending_at_return=first_state.pending==true
      metrics.gui_live_draft_at_return=draft~=nil
      metrics.gui_live_committed_note_value=output_value
      metrics.gui_live_committed_source_match=output_matches==true
      metrics.gui_live_output_policy=latest_policy or live_policy
      metrics.gui_live_pb_range=latest_pb or live_pb
      metrics.gui_live_terminal_before_return=live_result~=nil and writer_state=="idle" and
        live_result.kind=="success" and writer_state=="idle" and
        not first_state.busy and not first_state.pending and not draft
      if not first_state.armed or not metrics.gui_live_terminal_before_return or
          not output_matches or request_count~=1 or
          not metrics.gui_live_revision_id_advanced or not metrics.gui_live_prior_source_retained then
        set_live_armed(false)
        finished(false,"Live Edit did not synchronously commit one coherent source revision: writer="..
          tostring(writer_state).." status="..tostring(first_state.status).." result="..
          tostring(live_result and live_result.kind).." pending="..tostring(first_state.pending)..
          " draft="..tostring(draft~=nil).." requests="..tostring(request_count)..
          " revision_advanced="..tostring(metrics.gui_live_revision_id_advanced)..
          " prior_source_retained="..tostring(metrics.gui_live_prior_source_retained))
        return
      end
      local disarm_count=callback_counts.acid_live_edit or 0
      set_live_armed(false)
      local disarmed=live_context:generation_state()
      metrics.gui_live_disarmed=not disarmed.armed
      local dialog_closed=close_test_gui()
      metrics.gui_dialog_closed=dialog_closed
      if disarmed.armed or not dialog_closed then
        finished(false,"Live Edit did not disarm or close its dialog cleanly")
        return
      end
      metrics.gui_live_checkbox_dispatches=(callback_counts.acid_live_edit or 0)-arm_count
      metrics.gui_live_disarm_dispatches=(callback_counts.acid_live_edit or 0)-disarm_count
      action_timings["live-note"]=metrics.gui_live_first_edit_elapsed_ms
      local over_budget={}
      for name,elapsed in pairs(action_timings) do
        if elapsed>30 then over_budget[#over_budget+1]=name.."="..string.format("%.2f",elapsed) end
      end
      table.sort(over_budget)
      metrics.gui_over_budget_actions=table.concat(over_budget,",")
      metrics.gui_over_budget_action_count=#over_budget
      metrics.gui_live_synchronous_verified=true
      if #over_budget>0 then
        finished(false,"GUI actions exceeded 30 ms: "..metrics.gui_over_budget_actions)
      else
        finished(true)
      end
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
    captured_baseline_is_opaque=nil
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
            captured_baseline_is_opaque=type(request.baseline)=="table" and
              request.baseline.id==request.id and rawget(request.baseline,"snapshot")==nil
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
      local preserved=phrase:column_name(1)==old_name and captured_baseline_is_opaque==true
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

local function inspect_cold_song(expected_target_note, case_name)
  local song = renoise.song()
  local reopened_baseline = persisted_baseline(song)
  local instrument_index = song.selected_instrument_index
  local instrument = song.instruments[instrument_index]
  local sequence = require("model.sequencer")
  local store = require("renoise.pattern_store")
  local ownership = require("renoise.phrase_ownership")
  local groups = ownership.inventory(song)
  local old_id, target_id, old_phrase, target_phrase, old_source, target_source
  local sentinel
  local sentinel_count = 0
  for index, candidate_instrument in ipairs(song.instruments) do
    for _, phrase in ipairs(candidate_instrument.phrases) do
      if phrase.name == COLD_SENTINEL_PHRASE_NAME then
        sentinel_count = sentinel_count + 1
        sentinel = {
          instrument = candidate_instrument,
          instrument_index = index,
          phrase = phrase,
          snapshot = ownership.snapshot(phrase),
        }
      end
    end
  end
  for _, phrase in ipairs(instrument.phrases) do
    local id = ownership.id(phrase)
    local source = id and store.read_entry(song, id)
    if source and source.pitch_events[1] then
      if source.pitch_events[FIRST_NOTE_LINE].note == sequence.BASE_NOTE + ACCEPTANCE_GENERATED_NOTE then
        old_id, old_phrase, old_source = id, phrase, source
      elseif source.pitch_events[FIRST_NOTE_LINE].note == expected_target_note then
        target_id, target_phrase, target_source = id, phrase, source
      end
    end
  end
  if not groups or not old_id or not target_id or old_id == target_id or
      not groups[old_id] or #groups[old_id] ~= 1 or
      not groups[target_id] or #groups[target_id] ~= 1 or
      #instrument.phrases ~= TWO_HOLDER_COUNT or sentinel_count ~= 1 or
      not sentinel or not sentinel.snapshot then
    return nil, "Saved cold-reopen phrases, unique sources, or foreign sentinel are missing"
  end
  local data_before = song.tool_data
  local old_snapshot = ownership.snapshot(old_phrase)
  local target_snapshot = ownership.snapshot(target_phrase)
  if not old_snapshot or not target_snapshot then return nil, "Saved phrase snapshots are unavailable" end
  local context = context_for(song)
  local bound = context:bind_phrase(instrument, target_phrase)
  local classification = context:target_state()
  local eligible, eligibility_error = context:musical_eligibility()
  local restored = context:restore_editor_target(instrument, target_phrase)
  local sentinel_state = classify_write_eligibility(song, sentinel.instrument, sentinel.phrase)
  local source_read, policy_read, pb_read = store.read_entry(song, target_id)
  local read_only = bound and classification.kind == "owned" and eligible ~= nil and
    restored and restored.source and sequence.same_source(restored.source, target_source) and
    restored.output_policy == policy_read and restored.pb_range == pb_read and
    source_read and sequence.same_source(source_read, target_source) and
    song.tool_data == data_before and
    ownership.compare(old_snapshot, ownership.snapshot(old_phrase)) and
    ownership.compare(target_snapshot, ownership.snapshot(target_phrase)) and
    not ownership.id(sentinel.phrase) and ownership.status(sentinel.phrase) == "foreign" and
    sentinel_state.classification == "foreign" and not sentinel_state.eligible and
    ownership.compare(sentinel.snapshot, ownership.snapshot(sentinel.phrase))
  context:release_document()
  if not read_only then
    return nil, eligibility_error or "Cold read-only ownership/source restoration changed native state"
  end
  return {
    song = song,
    instrument = instrument,
    instrument_index = instrument_index,
    old_id = old_id,
    target_id = target_id,
    old_phrase = old_phrase,
    target_phrase = target_phrase,
    old_source = old_source,
    target_source = target_source,
    old_snapshot = old_snapshot,
    target_snapshot = target_snapshot,
    sentinel = sentinel,
    target_policy = policy_read,
    target_pb = pb_read,
    reopened_baseline = reopened_baseline,
  }
end

local function prepare_cold_negative_fixture(state, target_source)
  local song = state.song
  local sequence = require("model.sequencer")
  local store = require("renoise.pattern_store")
  local ownership = require("renoise.phrase_ownership")
  local writer = require("writers.phrase_writer")
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local empty_instruments = {}
  for index, instrument in ipairs(song.instruments) do
    if not rawequal(instrument, state.instrument) and #instrument.phrases == 0 then
      empty_instruments[#empty_instruments + 1] = { index = index, instrument = instrument }
      if #empty_instruments == THREE_EMPTY_INSTRUMENTS then break end
    end
  end
  if #empty_instruments ~= THREE_EMPTY_INSTRUMENTS then
    return nil, "Cold fixture needs three empty instruments for isolated negative associations"
  end
  local function clone_into(destination)
    local phrase = destination:insert_phrase_at(#destination.phrases + 1)
    phrase:copy_from(state.target_phrase)
    return phrase
  end
  local function set_identity(phrase, id)
    local name, name_error = ownership.make_name(phrase, id)
    if not name then return false, name_error end
    phrase.name = name
    return true
  end
  local function can_save_source(id)
    local saved, reason = store.save(song, id, target_source, state.target_policy, state.target_pb)
    if not saved then return false, reason end
    return true
  end
  local duplicate_id, duplicate_error = store.allocate(song)
  if not duplicate_id then return nil, duplicate_error end
  local duplicate_source = clone_into(empty_instruments[1].instrument)
  local identity_ok, identity_error = set_identity(duplicate_source, duplicate_id)
  if not identity_ok then return nil, identity_error end
  local saved, save_error = can_save_source(duplicate_id)
  if not saved then return nil, save_error end
  local matching_source = store.read_entry(song, duplicate_id)
  if ownership.status(duplicate_source) ~= "owned" or not matching_source or
      not sequence.same_source(matching_source, target_source) then
    return nil, "Cold duplicate source was not a valid owned association before collision"
  end
  local duplicate_copy = clone_into(empty_instruments[2].instrument)
  duplicate_copy.name = duplicate_source.name
  local duplicate_data_before_proof = song.tool_data
  local duplicate_source_snapshot = ownership.snapshot(duplicate_source)
  local duplicate_copy_snapshot = ownership.snapshot(duplicate_copy)
  local function independence_is_eligible(instrument, phrase)
    local context = context_for(song)
    local bound = context:bind_phrase(instrument, phrase)
    local bound_exactly = bound and rawequal(bound.instrument, instrument) and rawequal(bound.phrase, phrase)
    local proof = bound_exactly and context:independence_eligibility()
    context:release_document()
    return proof ~= nil and proof ~= false
  end
  local valid_duplicate_pair = ownership.status(duplicate_source) == "owned" and
    ownership.status(duplicate_copy) == "owned" and
    ownership.id(duplicate_source) == duplicate_id and ownership.id(duplicate_copy) == duplicate_id and
    independence_is_eligible(empty_instruments[1].instrument, duplicate_source) and
    independence_is_eligible(empty_instruments[2].instrument, duplicate_copy) and
    song.tool_data == duplicate_data_before_proof and duplicate_source_snapshot and duplicate_copy_snapshot and
    ownership.compare(duplicate_source_snapshot, ownership.snapshot(duplicate_source)) and
    ownership.compare(duplicate_copy_snapshot, ownership.snapshot(duplicate_copy))

  local modified_id, modified_error = store.allocate(song)
  if not modified_id then return nil, modified_error end
  local modified = clone_into(empty_instruments[1].instrument)
  identity_ok, identity_error = set_identity(modified, modified_id)
  if not identity_ok then return nil, identity_error end
  saved, save_error = can_save_source(modified_id)
  if not saved then return nil, save_error end
  local modified_note = modified:line(FIRST_NOTE_LINE):note_column(FIRST_NOTE_COLUMN)
  modified_note.note_value = modified_note.note_value == ACCEPTANCE_NOTE_VALUE_LOW and
    ACCEPTANCE_NOTE_VALUE_HIGH or ACCEPTANCE_NOTE_VALUE_LOW

  local missing_id, missing_error = store.allocate(song)
  if not missing_id then return nil, missing_error end
  local missing_source = clone_into(empty_instruments[3].instrument)
  identity_ok, identity_error = set_identity(missing_source, missing_id)
  if not identity_ok then return nil, identity_error end

  local groups = ownership.inventory(song)
  local changed_group = groups and groups[duplicate_id]
  local modified_groups = groups and groups[modified_id]
  local missing_groups = groups and groups[missing_id]
  if not valid_duplicate_pair or not changed_group or #changed_group ~= TWO_HOLDER_COUNT or
      not modified_groups or #modified_groups ~= 1 or
      not missing_groups or #missing_groups ~= 1 or store.read_entry(song, missing_id) then
    return nil, "Cold negative associations did not have their planned unique/collision inventory"
  end
  local modified_snapshot = ownership.snapshot(modified)
  local changed_state = classify_write_eligibility(song, empty_instruments[2].instrument, duplicate_copy)
  local modified_state = classify_write_eligibility(song, empty_instruments[1].instrument, modified)
  local missing_state = classify_write_eligibility(song, empty_instruments[3].instrument, missing_source)
  local function reject(phrase, instrument_index)
    return writer_rejects_regeneration_without_mutation(song, instrument_index.index,
      target_source, phrase, factory, writer, ownership)
  end
  local duplicate_rejected = changed_state.classification == "unavailable" and not changed_state.eligible and
    reject(duplicate_source, empty_instruments[1]) and reject(duplicate_copy, empty_instruments[2])
  local modified_rejected = ownership.status(modified) == "modified" and modified_snapshot and
    modified_state.classification == "unavailable" and not modified_state.eligible and
    reject(modified, empty_instruments[1])
  local missing_rejected = missing_state.classification == "unavailable" and not missing_state.eligible and
    reject(missing_source, empty_instruments[3])
  if not duplicate_rejected or not modified_rejected or not missing_rejected then
    local function state_text(state)
      return state.classification .. "/eligible=" .. tostring(state.eligible)
    end
    return nil, "Cold negative association was eligible or accepted for regeneration: duplicate=" ..
      state_text(changed_state) .. "/rejected=" .. tostring(duplicate_rejected) ..
      ", modified=" .. state_text(modified_state) .. "/rejected=" .. tostring(modified_rejected) ..
      ", missing=" .. state_text(missing_state) .. "/rejected=" .. tostring(missing_rejected)
  end
  return {
    duplicate_id = duplicate_id,
    modified_id = modified_id,
    missing_id = missing_id,
    phrase_count = #song.instruments[empty_instruments[1].index].phrases +
      #song.instruments[empty_instruments[2].index].phrases +
      #song.instruments[empty_instruments[3].index].phrases,
  }
end

local function run_cold_reopen_regenerate(done)
  local state, inspect_error = inspect_cold_song(require("model.sequencer").BASE_NOTE + ACCEPTANCE_INDEPENDENT_NOTE,
    "cold-reopen-regenerate")
  if not state then
    done({ status = "FAIL", case = "cold-reopen-regenerate", reason = inspect_error })
    return true
  end
  local sequence = require("model.sequencer")
  local store = require("renoise.pattern_store")
  local ownership = require("renoise.phrase_ownership")
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local writer = require("writers.phrase_writer")
  local changed_source = sequence.copy_source(state.target_source)
  changed_source.pitch_events[1] = sequence.new_pitch(ACCEPTANCE_REGENERATED_NOTE, ACCEPTANCE_KEY, true, false)
  local target_index
  for index, phrase in ipairs(state.instrument.phrases) do
    if rawequal(phrase, state.target_phrase) then target_index = index; break end
  end
  local request, request_error = factory.build(state.song, state.instrument_index,
    changed_source, target_index)
  if not request or request.kind ~= "regenerate" then
    done({ status = "FAIL", case = "cold-reopen-regenerate",
      reason = describe_failure(request_error or "Cold target did not resolve to an exact regenerate request") })
    return true
  end
  local terminal_delivered = false
  local accepted, start_error = writer.regenerate(request, function(result)
      terminal_delivered = true
      local regenerated_id = type(result) == "table" and result.id or nil
      local target_source, target_policy, target_pb
      if regenerated_id then target_source, target_policy, target_pb = store.read_entry(state.song, regenerated_id) end
      local historical_target_source, historical_target_policy, historical_target_pb =
        store.read_entry(state.song, state.target_id)
      local old_source = store.read_entry(state.song, state.old_id)
      local groups = ownership.inventory(state.song)
      local target_snapshot = ownership.snapshot(state.target_phrase)
      local old_snapshot = ownership.snapshot(state.old_phrase)
      local expected_target_snapshot = ownership.copy_snapshot(state.target_snapshot)
      local old_output_note = sequence.BASE_NOTE + ACCEPTANCE_INDEPENDENT_NOTE
      local new_output_note = sequence.BASE_NOTE + ACCEPTANCE_REGENERATED_NOTE
      local changed_memory_count = 0
      for _, event in ipairs(state.target_source.pitch_events) do
        if event.note == old_output_note then changed_memory_count = changed_memory_count + 1 end
      end
      local source_change_is_unambiguous = changed_memory_count == 1 and
        state.target_source.pitch_events[1] and
        state.target_source.pitch_events[1].note == old_output_note
      local expected_changed_cell_count = 0
      if expected_target_snapshot and source_change_is_unambiguous then
        for _, line in ipairs(expected_target_snapshot.lines) do
          for _, note in ipairs(line.notes) do
            if note.note_value == old_output_note then
              note.note_value = new_output_note
              expected_changed_cell_count = expected_changed_cell_count + 1
            end
          end
        end
      else
        expected_target_snapshot = nil
      end
      local regenerated_target_matches, target_snapshot_difference = false, "regenerated phrase snapshot is unavailable"
      if expected_target_snapshot and target_snapshot then
        regenerated_target_matches, target_snapshot_difference =
          ownership.compare(expected_target_snapshot, target_snapshot, "name")
      end
      local fresh_revision_identity = regenerated_id ~= nil and regenerated_id ~= state.target_id and
        ownership.id(state.target_phrase) == regenerated_id and
        ownership.status(state.target_phrase) == "owned"
      local old_phrase_unchanged = old_snapshot and ownership.compare(state.old_snapshot, old_snapshot)
      local sentinel_unchanged = state.sentinel and
        ownership.id(state.sentinel.phrase) == nil and
        ownership.status(state.sentinel.phrase) == "foreign" and
        ownership.compare(state.sentinel.snapshot, ownership.snapshot(state.sentinel.phrase))
      local writer_succeeded = type(result) == "table" and result.kind == "success" and result.verified == true
      local same_target_object = writer_succeeded and rawequal(result.phrase, state.target_phrase)
      local target_source_matches = target_source and sequence.same_source(target_source, changed_source)
      local target_settings_preserved = target_policy == state.target_policy and target_pb == state.target_pb
      local historical_target_preserved = historical_target_source and
        sequence.same_source(historical_target_source, state.target_source) and
        historical_target_policy == state.target_policy and historical_target_pb == state.target_pb
      local old_source_preserved = old_source and sequence.same_source(old_source, state.old_source)
      local groups_unique = groups and groups[state.old_id] and #groups[state.old_id] == 1 and
        regenerated_id and groups[regenerated_id] and #groups[regenerated_id] == 1 and
        groups[state.target_id] == nil
      local primary_phrase_count_preserved = #state.instrument.phrases == TWO_HOLDER_COUNT
      local passed = writer_succeeded and same_target_object and primary_phrase_count_preserved and
        terminal_delivered and target_source_matches and target_settings_preserved and
        historical_target_preserved and old_source_preserved and groups_unique and
        source_change_is_unambiguous and expected_changed_cell_count > 0 and
        regenerated_target_matches and fresh_revision_identity and old_phrase_unchanged and sentinel_unchanged
      if not passed then
        done({ status = "FAIL", case = "cold-reopen-regenerate",
          reason = writer_succeeded and "Cold regenerated readback did not match expected native output" or
            describe_failure(result or "Cold regenerate writer did not succeed"),
          writer_succeeded = writer_succeeded == true,
          same_target_object = same_target_object == true,
          primary_phrase_count_preserved = primary_phrase_count_preserved == true,
          target_source_matches = target_source_matches == true,
          target_settings_preserved = target_settings_preserved == true,
          regenerated_note_and_metadata_match = regenerated_target_matches == true,
          source_change_is_unambiguous = source_change_is_unambiguous == true,
          expected_changed_cell_count = expected_changed_cell_count,
          fresh_revision_identity = fresh_revision_identity == true,
          historical_target_preserved = historical_target_preserved == true,
          target_snapshot_difference = target_snapshot_difference,
          old_source_preserved = old_source_preserved == true,
          old_phrase_unchanged = old_phrase_unchanged == true,
          sentinel_unchanged = sentinel_unchanged == true,
          groups_unique = groups_unique == true,
          terminal_delivered = terminal_delivered,
          phrase_count = #state.instrument.phrases })
        return
      end
      local negative_fixture, negative_error = prepare_cold_negative_fixture(state, changed_source)
      if not negative_fixture then
        done({ status = "FAIL", case = "cold-reopen-regenerate", reason = negative_error })
        return
      end
      local saved_baseline = persisted_baseline(state.song)
      local saved, save_error = save_independent_fixture(state.song, "acceptance-cold-regenerated.xrns")
      done({ status = saved and "PASS" or "FAIL", case = "cold-reopen-regenerate",
        reopened_baseline = state.reopened_baseline,
        saved_baseline = saved_baseline,
        roundtrip_fixture = saved and saved.fixture or nil,
        roundtrip_bytes = saved and saved.bytes or nil,
        old_id = state.old_id, previous_target_id = state.target_id, target_id = regenerated_id,
        fresh_revision_identity = fresh_revision_identity == true,
        historical_target_preserved = historical_target_preserved == true,
        regenerated_same_object = rawequal(result.phrase, state.target_phrase),
        phrase_count = #state.instrument.phrases,
        read_only_load_and_owned_source_restore = true,
        other_phrase_and_source_unchanged = old_source and sequence.same_source(old_source, state.old_source) or false,
        persisted_duplicate_id = negative_fixture.duplicate_id,
        persisted_modified_id = negative_fixture.modified_id,
        persisted_missing_source_id = negative_fixture.missing_id,
        persisted_negative_phrase_count = negative_fixture.phrase_count,
        foreign_sentinel_preserved = sentinel_unchanged == true,
        foreign_sentinel_instrument_index = state.sentinel.instrument_index,
        primary_instrument_phrase_count = #state.instrument.phrases,
        regenerated_note_and_metadata_match = regenerated_target_matches == true,
        expected_changed_cell_count = expected_changed_cell_count,
        terminal_delivered = terminal_delivered,
        reason = save_error })
  end)
  if not accepted then
    done({ status = "FAIL", case = "cold-reopen-regenerate", reason = describe_failure(start_error) })
  elseif not terminal_delivered then
    done({ status = "FAIL", case = "cold-reopen-regenerate",
      reason = "Synchronous regeneration returned without terminal delivery" })
  end
  return true
end

local function run_cold_reopen_verify(done)
  local state, inspect_error = inspect_cold_song(require("model.sequencer").BASE_NOTE + ACCEPTANCE_REGENERATED_NOTE,
    "cold-reopen-verify")
  if not state then
    done({ status = "FAIL", case = "cold-reopen-verify", reason = inspect_error })
    return true
  end
  local song = state.song
  local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
  local writer = require("writers.phrase_writer")
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local raw_before = song.tool_data
  local groups = ownership.inventory(song)
  local snapshots = {}
  local duplicate_id, duplicate_holders
  local modified_holder, missing_holder
  for _, instrument in ipairs(song.instruments) do
    for _, phrase in ipairs(instrument.phrases) do
      local snapshot = ownership.snapshot(phrase)
      if not snapshot then
        done({ status = "FAIL", case = "cold-reopen-verify", reason = "Persisted phrase snapshot is unavailable" })
        return true
      end
      snapshots[#snapshots + 1] = { instrument = instrument, phrase = phrase, snapshot = snapshot }
    end
  end
  for id, holders in pairs(groups or {}) do
    if id ~= state.old_id and id ~= state.target_id and #holders >= TWO_HOLDER_COUNT and not duplicate_id then
      duplicate_id, duplicate_holders = id, holders
    elseif id ~= state.old_id and id ~= state.target_id and #holders == 1 then
      local holder = holders[1]
      local source = store.read_entry(song, id)
      local status = ownership.status(holder.phrase)
      if not source and status == "owned" and not missing_holder then missing_holder = holder end
      if source and status == "modified" and not modified_holder then modified_holder = holder end
    end
  end
  local function blocked_regeneration(holder)
    if not holder then return false end
    local source = store.read_entry(song, ownership.id(holder.phrase)) or state.target_source
    return writer_rejects_regeneration_without_mutation(song, holder.instrument_index, source,
      holder.phrase, factory, writer, ownership) and song.tool_data == raw_before
  end
  local duplicate_blocked = duplicate_id and duplicate_holders and #duplicate_holders == TWO_HOLDER_COUNT
  for _, holder in ipairs(duplicate_holders or {}) do
    local state_for_holder = classify_write_eligibility(song, holder.instrument, holder.phrase)
    duplicate_blocked = duplicate_blocked and state_for_holder.classification == "unavailable" and
      not state_for_holder.eligible and blocked_regeneration(holder)
  end
  local modified_blocked = modified_holder and ownership.status(modified_holder.phrase) == "modified"
  if modified_holder then
    local modified_state = classify_write_eligibility(song, modified_holder.instrument, modified_holder.phrase)
    modified_blocked = modified_blocked and modified_state.classification == "unavailable" and
      not modified_state.eligible and blocked_regeneration(modified_holder)
  end
  local missing_blocked = missing_holder and ownership.status(missing_holder.phrase) == "owned" and
    not store.read_entry(song, ownership.id(missing_holder.phrase))
  if missing_holder then
    local missing_state = classify_write_eligibility(song, missing_holder.instrument, missing_holder.phrase)
    missing_blocked = missing_blocked and missing_state.classification == "unavailable" and
      not missing_state.eligible and blocked_regeneration(missing_holder)
  end
  local unchanged = song.tool_data == raw_before
  for _, saved in ipairs(snapshots) do
    unchanged = unchanged and ownership.compare(saved.snapshot, ownership.snapshot(saved.phrase))
  end
  local sentinel_preserved = state.sentinel and not ownership.id(state.sentinel.phrase) and
    ownership.status(state.sentinel.phrase) == "foreign" and
    ownership.compare(state.sentinel.snapshot, ownership.snapshot(state.sentinel.phrase))
  local passed = duplicate_blocked and modified_blocked and missing_blocked and unchanged and sentinel_preserved
  done({ status = passed and "PASS" or "FAIL", case = "cold-reopen-verify",
    reopened_baseline = state.reopened_baseline,
    old_id = state.old_id,
    target_id = state.target_id,
    duplicate_id = duplicate_id,
    modified_id = modified_holder and ownership.id(modified_holder.phrase) or nil,
    missing_source_id = missing_holder and ownership.id(missing_holder.phrase) or nil,
    phrase_count = #state.instrument.phrases,
    owned_source_and_settings_restored_read_only = true,
    persisted_duplicate_rejected = duplicate_blocked == true,
    persisted_modified_association_rejected = modified_blocked == true,
    persisted_missing_source_rejected = missing_blocked == true,
    foreign_sentinel_preserved = sentinel_preserved == true,
    primary_instrument_phrase_count = #state.instrument.phrases,
    no_load_or_inspection_mutation = unchanged == true,
    reason = inspect_error })
  return true
end

local function run_selection_feasibility(done, json)
  local song = renoise.song()
  local instrument = song and song.selected_instrument
  if not instrument or song.transport.playing or #instrument.phrases + 2 >
      renoise.Instrument.MAX_NUMBER_OF_PHRASES then
    done({ status = "FAIL", case = "selection-feasibility",
      reason = "Stop playback and select an instrument with capacity for two temporary phrases" })
    return true
  end
  local instrument_index = song.selected_instrument_index
  local original_phrases = {}
  for index, phrase in ipairs(instrument.phrases) do original_phrases[index] = phrase end
  local original_count = #original_phrases
  local data_before = song.tool_data
  local created, observations = {}, { trace = json.array() }
  local idle = renoise.tool().app_idle_observable
  local notifier
  local settled = false

  local function remove_notifier()
    if notifier and idle:has_notifier(notifier) then idle:remove_notifier(notifier) end
    notifier = nil
  end

  local function phrase_index(target)
    for index, phrase in ipairs(instrument.phrases) do
      if rawequal(phrase, target) then return index end
    end
  end

  local function cleanup()
    remove_notifier()
    if not rawequal(renoise.song(), song) or not rawequal(song.instruments[instrument_index], instrument) then
      return false, "song or instrument changed; disposable probe phrases may need manual cleanup"
    end
    for index = #created, 1, -1 do
      local phrase = created[index]
      local current_index = phrase_index(phrase)
      if current_index then
        local ok, err = pcall(function() instrument:delete_phrase_at(current_index) end)
        if not ok then return false, tostring(err) end
      end
    end
    local preserved = #instrument.phrases == original_count
    for index, phrase in ipairs(original_phrases) do
      if not rawequal(instrument.phrases[index], phrase) then preserved = false end
    end
    return preserved and song.tool_data == data_before,
      "phrase inventory or song tool_data changed during probe cleanup"
  end

  local function finish(ok, reason)
    if settled then return end
    settled = true
    local cleaned, cleanup_error = cleanup()
    ok = ok and cleaned
    done({ status = ok and "PASS" or "FAIL", case = "selection-feasibility",
      reason = reason or (not cleaned and cleanup_error or nil), observations = observations,
      setter_existing_stable = observations.setter_existing_stable == true,
      setter_zero_stable = observations.setter_zero_stable == true,
      cleanup_verified = cleaned == true })
  end

  local function validate_context()
    assert(rawequal(renoise.song(), song), "active song changed")
    assert(not song.transport.playing, "playback started")
    assert(song.selected_instrument_index == instrument_index and
      rawequal(song.instruments[instrument_index], instrument), "selected instrument changed")
  end

  local function wait_idle_pair(label, next_step)
    local count = 0
    notifier = function()
      local ok, err = pcall(function()
        validate_context()
        count = count + 1
        observations.trace[#observations.trace + 1] = { label = label, idle = count,
          selected_phrase_index = song.selected_phrase_index, phrase_count = #instrument.phrases }
        if count == 2 then
          remove_notifier()
          next_step()
        end
      end)
      if not ok then finish(false, tostring(err)) end
    end
    idle:add_notifier(notifier)
  end

  local function perform(label, action, next_step)
    local ok, err = pcall(function()
      validate_context()
      action()
      observations.trace[#observations.trace + 1] = { label = label, immediate = true,
        selected_phrase_index = song.selected_phrase_index, phrase_count = #instrument.phrases }
    end)
    if not ok then finish(false, label .. ": " .. tostring(err)); return end
    wait_idle_pair(label, next_step)
  end

  local function locate_created(target)
    local index = phrase_index(target)
    assert(index, "probe phrase identity is missing")
    return index
  end

  local function structural_pair(label, next_step)
    perform("insert after " .. label, function()
      assert(#instrument.phrases == original_count + 1 and
        rawequal(instrument.phrases[original_count + 1], created[1]),
        "phrase inventory changed unexpectedly")
      local phrase = instrument:insert_phrase_at(original_count + 2)
      assert(phrase and rawequal(instrument.phrases[original_count + 2], phrase),
        "inserted phrase identity is unavailable")
      created[#created + 1] = phrase
    end, function()
      perform("delete after " .. label, function()
        assert(#instrument.phrases == original_count + 2, "phrase inventory changed unexpectedly")
        instrument:delete_phrase_at(locate_created(created[2]))
      end, function()
        created[2] = nil
        next_step()
      end)
    end)
  end

  local function set_zero()
    local ok, err = pcall(function() song.selected_phrase_index = 0 end)
    observations.setter_zero_pcall = ok
    observations.setter_zero_error = not ok and tostring(err) or nil
    local immediate = song.selected_phrase_index
    observations.setter_zero_immediate = immediate
    wait_idle_pair("set index 0", function()
      local trace = observations.trace
      local first = trace[#trace - 1].selected_phrase_index
      local second = trace[#trace].selected_phrase_index
      observations.setter_zero_stable = immediate == 0 and first == 0 and second == 0
      structural_pair("index 0", function()
        perform("delete seed", function()
        assert(#instrument.phrases == original_count + 1, "phrase inventory changed unexpectedly")
          instrument:delete_phrase_at(locate_created(created[1]))
        end, function()
          created[1] = nil
          finish(#instrument.phrases == original_count, "selection feasibility sequence completed")
        end)
      end)
    end)
  end

  local function set_existing()
    local ok, err = pcall(function() song.selected_phrase_index = 1 end)
    observations.setter_existing_pcall = ok
    observations.setter_existing_error = not ok and tostring(err) or nil
    local immediate = song.selected_phrase_index
    observations.setter_existing_immediate = immediate
    wait_idle_pair("set existing index 1", function()
      local trace = observations.trace
      local first = trace[#trace - 1].selected_phrase_index
      local second = trace[#trace].selected_phrase_index
      observations.setter_existing_stable = immediate == 1 and first == 1 and second == 1
      structural_pair("index 1", set_zero)
    end)
  end

  perform("insert seed", function()
    local phrase = instrument:insert_phrase_at(original_count + 1)
    assert(phrase and rawequal(instrument.phrases[original_count + 1], phrase),
      "seed phrase identity is unavailable")
    created[1] = phrase
  end, set_existing)
  return true
end

local function run_direct_output_feasibility(done, json)
  local song = renoise.song()
  local instrument = song and song.selected_instrument
  if not instrument or song.transport.playing or #instrument.phrases + 2 >
      renoise.Instrument.MAX_NUMBER_OF_PHRASES then
    done({ status = "FAIL", case = "direct-output-feasibility",
      reason = "Stop playback and select an instrument with capacity for two temporary phrases" })
    return true
  end
  local instrument_index = song.selected_instrument_index
  local data_before = song.tool_data
  local before_count = #instrument.phrases
  local original_phrases = {}
  for index, phrase in ipairs(instrument.phrases) do original_phrases[index] = phrase end
  local created, matrix = {}, json.array()
  local rollback_exact = false
  local source_transaction_verified = false
  local materializer_apply_calls = 0
  local materializer_apply_total_ms = 0
  local materializer_apply_max_ms = 0
  local materializer_phase_names = { "snapshot", "snapshot_index", "matches_snapshot",
    "compare", "copy_snapshot" }
  local materializer_profile_total = {}
  for _, name in ipairs(materializer_phase_names) do
    materializer_profile_total[name .. "_calls"] = 0
    materializer_profile_total[name .. "_ms"] = 0
  end
  local settled = false
  local function phrase_index(target)
    for index, phrase in ipairs(instrument.phrases) do
      if rawequal(phrase, target) then return index end
    end
  end
  local function cleanup()
    if not rawequal(renoise.song(), song) or not rawequal(song.instruments[instrument_index], instrument) then
      return false, "song or probe instrument changed; created phrases may need manual cleanup"
    end
    for index = #created, 1, -1 do
      local current_index = phrase_index(created[index])
      if current_index then
        local ok, err = pcall(function() instrument:delete_phrase_at(current_index) end)
        if not ok then return false, tostring(err) end
      end
    end
    local preserved = #instrument.phrases == before_count
    for index, phrase in ipairs(original_phrases) do
      if not rawequal(instrument.phrases[index], phrase) then preserved = false end
    end
    return preserved and song.tool_data == data_before,
      "phrase inventory or song tool_data changed during cleanup"
  end
  local function finish(ok, reason)
    if settled then return end
    settled = true
    local clean, cleanup_error = cleanup()
    local profile_total_ms = 0
    for _, name in ipairs(materializer_phase_names) do
      profile_total_ms = profile_total_ms + materializer_profile_total[name .. "_ms"]
    end
    materializer_profile_total.residual_ms = materializer_apply_total_ms - profile_total_ms
    done({ status = ok and clean and "PASS" or "FAIL", case = "direct-output-feasibility",
      reason = reason or (not clean and cleanup_error or nil), cases = matrix,
      rollback_exact = rollback_exact, source_transaction_verified = source_transaction_verified,
      materializer_apply_calls = materializer_apply_calls,
      materializer_apply_total_ms = materializer_apply_total_ms,
      materializer_apply_max_ms = materializer_apply_max_ms,
      materializer_profile = materializer_profile_total,
      cleanup_verified = clean == true,
      phrase_count = #instrument.phrases })
  end

  local loaded, planner, sequence, emitter, ownership, runner_module, gate_writer, store, materializer = pcall(function()
    return require("model.output_planner"), require("model.sequencer"),
      dofile(renoise.tool().bundle_path .. "\\__dev\\reference\\pattrns_writer.lua"),
      require("renoise.phrase_ownership"),
      dofile(renoise.tool().bundle_path .. "\\__dev\\reference\\script_runner.lua"),
      dofile(renoise.tool().bundle_path .. "\\__dev\\reference\\gate_writer.lua"),
      require("renoise.pattern_store"), require("writers.phrase_materializer")
  end)
  if not loaded then finish(false, tostring(planner)); return true end
  local api = renoise.InstrumentPhrase
  local capacities = { max_lines = api.MAX_NUMBER_OF_LINES,
    max_note_columns = api.MAX_NUMBER_OF_NOTE_COLUMNS,
    max_effect_columns = api.MAX_NUMBER_OF_EFFECT_COLUMNS,
    play_pattern = api.PLAY_PATTERN, key_tracking_none = api.KEY_TRACKING_NONE }
  local capabilities = { sample = false, plugin = false, midi = false, alias = false }
  local note_fields = { "note_value", "instrument_value", "volume_value", "panning_value",
    "delay_value", "effect_number_value", "effect_amount_value" }
  local effect_fields = { "number_value", "amount_value" }

  local function context_valid()
    assert(rawequal(renoise.song(), song), "active song changed")
    assert(not song.transport.playing, "playback started")
    assert(song.selected_instrument_index == instrument_index and
      rawequal(song.instruments[instrument_index], instrument), "selected instrument changed")
  end

  local function set_properties(phrase, properties, visibility)
    phrase.looping = false
    phrase.loop_start = 1
    phrase.loop_end = 2
    phrase.number_of_lines = properties.number_of_lines
    for key, value in pairs(properties) do
      if key ~= "looping" and key ~= "loop_start" and key ~= "loop_end" and
          key ~= "number_of_lines" then phrase[key] = value end
    end
    phrase.loop_end = properties.loop_end
    phrase.loop_start = properties.loop_start
    phrase.looping = properties.looping
    for key, value in pairs(visibility) do phrase[key] = value end
  end

  local function write_expected(phrase, output, fail_after, failure_tag)
    local writes = 0
    for line_index = 1, capacities.max_lines do
      local line = phrase:line(line_index)
      local expected = output.expected.lines[line_index]
      for column = 1, capacities.max_note_columns do
        local cell = line:note_column(column)
        for _, field in ipairs(note_fields) do
          cell[field] = expected.note_columns[column][field]
          writes = writes + 1
          if fail_after and writes == fail_after then
            error("injected direct write failure:" .. tostring(failure_tag), 0)
          end
        end
      end
      for column = 1, capacities.max_effect_columns do
        local cell = line:effect_column(column)
        for _, field in ipairs(effect_fields) do
          cell[field] = expected.effect_columns[column][field]
          writes = writes + 1
          if fail_after and writes == fail_after then
            error("injected direct write failure:" .. tostring(failure_tag), 0)
          end
        end
      end
    end
  end

  local function assert_expected(phrase, output, before)
    local snapshot = assert(ownership.snapshot(phrase, capacities))
    for key, expected in pairs(output.expected.properties) do
      assert(snapshot.properties[key] == expected, "property mismatch: " .. key)
    end
    for key, expected in pairs(output.required_visibility) do
      local wanted = expected
      if before then
        local old = before.properties[key]
        if type(expected) == "number" then wanted = math.max(old, expected)
        elseif type(expected) == "boolean" then wanted = old or expected end
      end
      assert(snapshot.properties[key] == wanted, "visibility mismatch: " .. key)
    end
    for line_index = 1, capacities.max_lines do
      local actual, expected = snapshot.lines[line_index], output.expected.lines[line_index]
      for column = 1, capacities.max_note_columns do
        for _, field in ipairs(note_fields) do
          assert(actual.notes[column][field] == expected.note_columns[column][field],
            string.format("note mismatch at line %d column %d field %s", line_index, column, field))
        end
      end
      for column = 1, capacities.max_effect_columns do
        for _, field in ipairs(effect_fields) do
          assert(actual.effects[column][field] == expected.effect_columns[column][field],
            string.format("effect mismatch at line %d column %d field %s", line_index, column, field))
        end
      end
    end
    return snapshot
  end

  local function apply_materialized(phrase, output, before)
    local unpack_values = unpack or table.unpack
    local function pack_values(...)
      return { n = select("#", ...), ... }
    end
    local profile = {}
    local originals = {}
    local wrappers = {}
    for _, name in ipairs(materializer_phase_names) do
      local original = ownership[name]
      if type(original) == "function" then
        originals[name] = original
        profile[name .. "_calls"] = 0
        profile[name .. "_ms"] = 0
        wrappers[#wrappers + 1] = name
      end
    end
    for _, name in ipairs(wrappers) do
      local original = originals[name]
      ownership[name] = function(...)
        local started = os.clock()
        local values = pack_values(pcall(original, ...))
        profile[name .. "_calls"] = profile[name .. "_calls"] + 1
        profile[name .. "_ms"] = profile[name .. "_ms"] +
          (os.clock() - started) * MILLISECONDS_PER_SECOND
        if not values[1] then error(values[2], 0) end
        return unpack_values(values, 2, values.n)
      end
    end
    local started = os.clock()
    local values = pack_values(pcall(materializer.apply,
      phrase, output.expected, output.required_visibility, before, capacities))
    local elapsed = (os.clock() - started) * MILLISECONDS_PER_SECOND
    for index = #wrappers, 1, -1 do
      local name = wrappers[index]
      pcall(function() ownership[name] = originals[name] end)
      local calls_key, time_key = name .. "_calls", name .. "_ms"
      materializer_profile_total[calls_key] = materializer_profile_total[calls_key] + profile[calls_key]
      materializer_profile_total[time_key] = materializer_profile_total[time_key] + profile[time_key]
    end
    local phase_total_ms = 0
    for _, name in ipairs(materializer_phase_names) do
      profile[name .. "_calls"] = profile[name .. "_calls"] or 0
      profile[name .. "_ms"] = profile[name .. "_ms"] or 0
      phase_total_ms = phase_total_ms + profile[name .. "_ms"]
    end
    profile.residual_ms = elapsed - phase_total_ms
    materializer_apply_calls = materializer_apply_calls + 1
    materializer_apply_total_ms = materializer_apply_total_ms + elapsed
    if elapsed > materializer_apply_max_ms then materializer_apply_max_ms = elapsed end
    if not values[1] then error(values[2], 0) end
    return values[2], values[3], values[4], elapsed, profile
  end

  local function seed_detached_preimage(phrase)
    phrase.looping = false
    phrase.loop_start = 1
    phrase.number_of_lines = capacities.max_lines
    phrase.loop_end = capacities.max_lines
    phrase.visible_note_columns = capacities.max_note_columns
    if capacities.max_effect_columns > 0 then
      phrase.visible_effect_columns = capacities.max_effect_columns
    end
    local lines = { 1, math.min(17, capacities.max_lines), capacities.max_lines }
    local note_columns = { 1, capacities.max_note_columns }
    for line_slot, line_index in ipairs(lines) do
      local line = phrase:line(line_index)
      for column_slot, column_index in ipairs(note_columns) do
        local cell = line:note_column(column_index)
        cell.note_value = 48 + line_slot + column_slot
        cell.instrument_value = column_slot
        cell.volume_value = 70 + line_slot
        cell.panning_value = 20 + column_slot
        cell.delay_value = line_slot
        cell.effect_number_value = 1 + column_slot
        cell.effect_amount_value = 10 + line_slot
      end
      if capacities.max_effect_columns > 0 then
        local effect_columns = { 1, capacities.max_effect_columns }
        for column_slot, column_index in ipairs(effect_columns) do
          local cell = line:effect_column(column_index)
          cell.number_value = column_slot
          cell.amount_value = 30 + line_slot
        end
      end
    end
    phrase.number_of_lines = math.min(32, capacities.max_lines)
    phrase.loop_start = 1
    phrase.loop_end = phrase.number_of_lines
    phrase.looping = false
    phrase.visible_note_columns = 1
    if capacities.max_effect_columns > 0 then phrase.visible_effect_columns = 1 end
  end

  local function inject_and_restore(phrase, detached, output, tag, fail_after)
    set_properties(phrase, output.expected.properties, output.required_visibility)
    local fault_ok, fault_error = pcall(function()
      if fail_after then
        write_expected(phrase, output, fail_after, tag)
      else
        error("injected direct write failure:" .. tag, 0)
      end
    end)
    assert(not fault_ok and tostring(fault_error):find("injected direct write failure:" .. tag, 1, true),
      "fault injection did not reach the requested " .. tag .. " point: " .. tostring(fault_error))
    local restored, restore_error = materializer.restore(phrase, detached, capacities)
    assert(restored, "materializer rollback failed after " .. tag .. ": " .. tostring(restore_error))
    local equal, difference = ownership.compare(detached, assert(ownership.snapshot(phrase, capacities)))
    assert(equal, "full detached rollback mismatch after " .. tag .. ": " .. tostring(difference))
  end

  local source_ok, source, source_before = pcall(function()
    local pattern = sequence.new_pattern(4)
    pattern.pitch_length = 3
    pattern.pitch_events[1] = sequence.new_pitch(0, 0, false, false)
    pattern.pitch_events[2] = sequence.new_pitch(4, 0, true, false)
    pattern.pitch_events[3] = sequence.new_pitch(7, 0, false, false)
    pattern.time_events[1], pattern.time_events[2] = "N", "T"
    pattern.time_events[3], pattern.time_events[4] = "N", "R"
    return pattern, assert(sequence.copy_source(pattern))
  end)
  if not source_ok then finish(false, tostring(source)); return true end
  local cases = json.array()
  for _, timing_mode in ipairs({ "straight", "triplet" }) do
    for _, sample in ipairs({ false, true }) do
      for _, policy in ipairs({ "play_once", "repeat" }) do
        cases[#cases + 1] = { timing_mode = timing_mode, sample = sample, policy = policy }
      end
    end
  end

  local function run_case(case_index)
    if settled then return end
    local case = cases[case_index]
    if not case then
      source.timing_mode = source_before.timing_mode
      finish(sequence.same_source(source, source_before) and song.tool_data == data_before,
        "planner parity and rollback matrix completed")
      return
    end
    source.timing_mode = case.timing_mode
    capabilities.sample = case.sample
    local planned, output, plan_error = pcall(planner.plan, source, case.policy, 0, capacities, capabilities,
      { pitch_bend_delivery = false })
    local case_label = case.timing_mode .. "/sample=" .. tostring(case.sample) .. "/" .. case.policy
    if not planned or not output then finish(false, case_label .. ": " .. tostring(planned and plan_error or output)); return end
    local emitted, script_source, emit_error = pcall(emitter.emit, output.plan,
      { unit = output.layout.unit, resolution = output.layout.resolution })
    if not emitted or not script_source then finish(false, case_label .. ": " .. tostring(emitted and emit_error or script_source)); return end
    local direct, rendered, apply_elapsed_ms, apply_profile
    local ok, err = pcall(function()
      context_valid()
      direct = instrument:insert_phrase_at(#instrument.phrases + 1)
      assert(direct, "direct phrase insertion failed")
      created[#created + 1] = direct
      rendered = instrument:insert_phrase_at(#instrument.phrases + 1)
      assert(rendered, "renderer phrase insertion failed")
      created[#created + 1] = rendered
      assert(#instrument.phrases == before_count + 2, "phrase list insertion count mismatch")
      direct.name = "ACID DIRECT OUTPUT PROBE | direct"
      seed_detached_preimage(direct)
      direct.base_note = 53
      direct.autoseek = true
      direct:set_column_name(1, "preserved column")
      direct:set_column_is_muted(capacities.max_note_columns, true)
      local detached = assert(ownership.copy_snapshot(assert(ownership.snapshot(direct, capacities))))
      local phrase_count = #instrument.phrases
      if case_index == 1 then
        local before_transaction = song.tool_data
        local candidate, transaction_error
        local transaction_ok, failure = pcall(function()
          local allocated = assert(store.allocate(song))
          candidate = assert(store.prepare(song, allocated, source, case.policy, 0,
            function() return true end))
          local committed, commit_error = store.commit(song, candidate)
          assert(committed, "source commit failed: " .. tostring(commit_error))
          local committed_source = assert(store.read_entry(song, allocated))
          assert(sequence.same_source(committed_source, source), "committed source did not round-trip")
          local applied, apply_result = apply_materialized(direct, output, detached)
          assert(applied and apply_result, "production materializer failed: " .. tostring(apply_result))
          assert_expected(direct, output, detached)
          local interrupted, interrupt_error = pcall(function()
            error("injected post-commit materialization failure", 0)
          end)
          assert(not interrupted and tostring(interrupt_error) ==
            "injected post-commit materialization failure", "transaction fault did not reach injected point")
          local restored, restore_error = materializer.restore(direct, detached, capacities)
          assert(restored, "production materializer rollback failed: " .. tostring(restore_error))
          local phrase_equal, phrase_difference = ownership.compare(detached,
            assert(ownership.snapshot(direct, capacities)))
          assert(phrase_equal, "phrase restore failed after committed-source rollback: " ..
            tostring(phrase_difference))
          local source_restored, source_restore_error = store.restore(song, candidate)
          assert(source_restored, "source restore failed after materialization error: " ..
            tostring(source_restore_error))
          assert(song.tool_data == before_transaction, "source rollback did not restore exact raw bytes")
          store.release_candidate(candidate)
          candidate = nil
          local rejected_candidate = assert(store.prepare(song, allocated, source, case.policy, 0,
            function() return false end))
          local rejected, rejection_error = store.commit(song, rejected_candidate)
          assert(not rejected and rejection_error and song.tool_data == before_transaction,
            "rejected source request changed raw song data")
          store.release_candidate(rejected_candidate)
        end)
        if not transaction_ok then
          transaction_error = tostring(failure)
          local phrase_restored, phrase_restore_error = pcall(materializer.restore, direct, detached, capacities)
          if not phrase_restored then transaction_error = transaction_error ..
            "; phrase cleanup failed: " .. tostring(phrase_restore_error) end
          if candidate then
            local source_restored, source_restore_error = pcall(store.restore, song, candidate)
            if not source_restored then transaction_error = transaction_error ..
              "; source cleanup failed: " .. tostring(source_restore_error) end
            store.release_candidate(candidate)
          end
          if song.tool_data ~= before_transaction then
            transaction_error = transaction_error .. "; exact source bytes were not restored"
          end
          error(transaction_error, 0)
        end
        source_transaction_verified = true
      end
      local total_writes = capacities.max_lines *
        (capacities.max_note_columns * #note_fields + capacities.max_effect_columns * #effect_fields)
      inject_and_restore(direct, detached, output, "after-properties")
      inject_and_restore(direct, detached, output, "early-cell", 97)
      inject_and_restore(direct, detached, output, "late-cell", total_writes - 1)
      assert(#instrument.phrases == phrase_count, "rollback changed phrase inventory")
      rollback_exact = true
      local applied, apply_result, apply_partial
      applied, apply_result, apply_partial, apply_elapsed_ms, apply_profile =
        apply_materialized(direct, output, detached)
      assert(applied and apply_result, "production materializer failed: " .. tostring(apply_result))
      assert_expected(direct, output, detached)
      assert(direct.name == "ACID DIRECT OUTPUT PROBE | direct" and direct.base_note == 53 and direct.autoseek,
        "direct materialization changed preserved phrase metadata")
      assert(direct:column_name(1) == "preserved column" and
        direct:column_is_muted(capacities.max_note_columns), "direct materialization changed column metadata")
      set_properties(rendered, output.expected.properties, output.required_visibility)
      rendered.playback_mode = api.PLAY_SCRIPT
      rendered.script.paragraphs = { script_source }
    end)
    if not ok then finish(false, case_label .. ": " .. tostring(err)); return end

    local native_runner, runner_error = runner_module.new(rendered.script,
      { lpb = output.layout.lpb, max_events = output.plan.length }, {
        done = function(render_error)
          local completed, completion_error = pcall(function()
            context_valid()
            assert(not render_error or render_error == "", "native renderer failed: " .. tostring(render_error))
            local applied, gate_error = gate_writer.apply_plan(rendered, output.operations)
            assert(applied, "native gate application failed: " .. tostring(gate_error))
            set_properties(rendered, output.expected.properties, output.required_visibility)
            assert_expected(rendered, output)
            assert(#instrument.phrases == before_count + 2, "native renderer changed phrase inventory")
            matrix[#matrix + 1] = { timing_mode = case.timing_mode, sample = case.sample,
              policy = case.policy, parity = true, apply_elapsed_ms = apply_elapsed_ms,
              apply_profile = apply_profile,
              planned_lines = output.expected.properties.number_of_lines,
              semantic_events = output.plan.length, native_capacity_cells = capacities.max_lines *
                (capacities.max_note_columns + capacities.max_effect_columns) }
          end)
          if not completed then finish(false, case_label .. ": " .. tostring(completion_error)); return end
          for index = #created, 1, -1 do
            local phrase = created[index]
            local phrase_position = phrase_index(phrase)
            if phrase_position then instrument:delete_phrase_at(phrase_position) end
          end
          created = {}
          if #instrument.phrases ~= before_count then
            finish(false, "probe phrase cleanup did not restore the original count"); return
          end
          run_case(case_index + 1)
        end
      })
    if not native_runner then finish(false, tostring(runner_error)); return end
    local started, start_error = native_runner:start()
    if not started then finish(false, tostring(start_error)); return end
  end

  run_case(1)
  return true
end

local function run_source_undo_feasibility(done, json)
  local case_name = "source-undo-feasibility"
  local song = renoise.song()
  local instrument = song and song.selected_instrument
  if not song or not instrument or song.transport.playing then
    done({ status = "FAIL", case = case_name,
      reason = "Stop playback and select the instrument for the source undo probe" })
    return true
  end

  local instrument_index = song.selected_instrument_index
  local original_tool_data = song.tool_data
  local original_phrases = {}
  for index, existing_phrase in ipairs(instrument.phrases) do
    original_phrases[index] = existing_phrase
  end
  local ownership = require("renoise.phrase_ownership")
  local phrase
  local settled = false
  local variants = json.array()
  local maximum_history_states = 16

  local function original_inventory_matches()
    if #instrument.phrases ~= #original_phrases + (phrase and 1 or 0) then return false end
    for index, original_phrase in ipairs(original_phrases) do
      if not rawequal(instrument.phrases[index], original_phrase) then return false end
    end
    if phrase and not rawequal(instrument.phrases[#original_phrases + 1], phrase) then return false end
    return true
  end

  local function context_valid()
    assert(rawequal(renoise.song(), song), "active song changed")
    assert(not song.transport.playing, "playback started")
    assert(song.selected_instrument_index == instrument_index and
      rawequal(song.instruments[instrument_index], instrument), "selected instrument changed")
    assert(original_inventory_matches(), "phrase inventory changed during source undo probe")
  end

  local function phrase_snapshot()
    if not phrase then return nil end
    local snapshot, err = ownership.snapshot(phrase)
    assert(snapshot, err or "could not snapshot the probe phrase")
    return snapshot
  end

  local function capture_state()
    context_valid()
    return { tool_data = song.tool_data, phrase = phrase_snapshot() }
  end

  local function state_matches(actual, expected)
    if actual.tool_data ~= expected.tool_data then return false end
    if actual.phrase == nil or expected.phrase == nil then
      return actual.phrase == expected.phrase
    end
    return ownership.compare(actual.phrase, expected.phrase) == true
  end

  local function state_summary(actual, before, after, direction, index)
    return {
      direction = direction,
      index = index,
      tool_data_matches_before = actual.tool_data == before.tool_data,
      tool_data_matches_after = actual.tool_data == after.tool_data,
      phrase_matches_before = actual.phrase == nil and before.phrase == nil or
        actual.phrase ~= nil and before.phrase ~= nil and
          ownership.compare(actual.phrase, before.phrase) == true,
      phrase_matches_after = actual.phrase == nil and after.phrase == nil or
        actual.phrase ~= nil and after.phrase ~= nil and
          ownership.compare(actual.phrase, after.phrase) == true,
      matches_before = state_matches(actual, before),
      matches_after = state_matches(actual, after),
    }
  end

  local function cleanup()
    if not rawequal(renoise.song(), song) or
        not rawequal(song.instruments[instrument_index], instrument) then
      return false, "song or probe instrument changed; manual cleanup may be required"
    end
    local ok, err = pcall(function()
      if phrase then
        local index
        for candidate_index, candidate in ipairs(instrument.phrases) do
          if rawequal(candidate, phrase) then index = candidate_index; break end
        end
        if index then instrument:delete_phrase_at(index) end
      end
      song.tool_data = original_tool_data
    end)
    if not ok then return false, tostring(err) end
    local inventory_restored = #instrument.phrases == #original_phrases
    if inventory_restored then
      for index, original_phrase in ipairs(original_phrases) do
        if not rawequal(instrument.phrases[index], original_phrase) then
          inventory_restored = false
          break
        end
      end
    end
    return inventory_restored and song.tool_data == original_tool_data,
      "cleanup did not restore the original phrase identity order and tool_data"
  end

  local function finish()
    if settled then return end
    settled = true
    local all_grouped, any_undo_state = true, false
    local missing_undo_variants = json.array()
    for _, variant in ipairs(variants) do
      all_grouped = all_grouped and variant.complete_logical_undo_grouped == true
      any_undo_state = any_undo_state or variant.undo_state_count > 0
      if variant.undo_state_count == 0 then missing_undo_variants[#missing_undo_variants + 1] = variant.name end
    end
    local clean, cleanup_error = cleanup()
    done({
      status = all_grouped and clean and "PASS" or "FAIL",
      case = case_name,
      reason = not clean and cleanup_error or
        (not any_undo_state and "No native undo states were exposed to the direct Song API; a real key/menu undo handler may be needed before concluding the behavior is unavailable" or
          not all_grouped and "At least one variant did not undo and redo phrase plus source as one exact logical action" or nil),
      variants = variants,
      variant_count = #variants,
      maximum_history_states = maximum_history_states,
      all_variants_one_step = all_grouped,
      any_native_undo_state = any_undo_state,
      manual_undo_ui_followup_required = #missing_undo_variants > 0,
      variants_without_song_api_undo_states = missing_undo_variants,
      cleanup_verified = clean == true,
      phrase_count = #instrument.phrases,
      original_phrase_count = #original_phrases,
      tool_data_restored = song.tool_data == original_tool_data,
    })
  end

  local function add_variant_record(record)
    variants[#variants + 1] = record
  end

  local run_variant
  local variants_spec = {
    { name = "tool-data-only-describe-undo", description = "ACID source undo probe: tool_data only",
      method = "describe_undo", mutate_phrase = false, split = false },
    { name = "phrase-and-source-sync-describe-undo", description = "ACID source undo probe: synchronous pair",
      method = "describe_undo", mutate_phrase = true, split = false },
    { name = "phrase-then-source-split-describe-undo", description = "ACID source undo probe: split describe_undo",
      method = "describe_undo", mutate_phrase = true, split = true },
    { name = "phrase-then-source-split-batch-once", description = "ACID source undo probe: split batch once",
      method = "describe_batch_undo_once", mutate_phrase = true, split = true },
    { name = "phrase-then-source-split-batch-each", description = "ACID source undo probe: split batch each write",
      method = "describe_batch_undo_each", mutate_phrase = true, split = true },
  }

  run_variant = function(index)
    if settled then return end
    local spec = variants_spec[index]
    if not spec then finish(); return end
    local before
    local record = {
      name = spec.name,
      method = spec.method,
      split_idle = spec.split,
      status = "RUNNING",
      history = json.array(),
      undo_state_count = 0,
      redo_state_count = 0,
    }
    local function next_variant()
      if index >= #variants_spec then finish() else on_next_idle(function() run_variant(index + 1) end) end
    end
    local function fail_variant(err)
      record.status = "ERROR"
      record.error = tostring(err)
      record.complete_logical_undo_grouped = false
      add_variant_record(record)
      next_variant()
    end
    local function prepare_description()
      if spec.method == "describe_undo" then
        assert(type(song.describe_undo) == "function", "Song.describe_undo is unavailable")
        song:describe_undo(spec.description)
      elseif spec.method == "describe_batch_undo_once" or spec.method == "describe_batch_undo_each" then
        assert(type(song.describe_batch_undo) == "function", "Song.describe_batch_undo is unavailable")
        song:describe_batch_undo(spec.description, 5000)
      end
    end
    local function mutate_phrase()
      if not spec.mutate_phrase then return end
      phrase.name = "ACID SOURCE UNDO AFTER " .. tostring(index)
      phrase:line(1):note_column(1).note_value = 49 + index
    end
    local function mutate_source()
      song.tool_data = "ACID-SOURCE-UNDO-PROBE\n" .. spec.name .. "\n"
    end
    local begin_history_walk
    local function start_action()
      before = capture_state()
      record.before_tool_data_present = before.tool_data ~= nil
      record.before_tool_data_length = before.tool_data and #before.tool_data or 0
      prepare_description()
      if spec.split then
        mutate_phrase()
        on_next_idle(function()
          local ok, err = pcall(function()
            context_valid()
            if spec.method == "describe_batch_undo_each" then prepare_description() end
            mutate_source()
          end)
          if not ok then fail_variant(err); return end
          on_next_idle(function()
            local began, begin_error = pcall(begin_history_walk)
            if not began then fail_variant(begin_error) end
          end)
        end)
      else
        mutate_phrase()
        mutate_source()
        on_next_idle(function()
          local began, begin_error = pcall(begin_history_walk)
          if not began then fail_variant(begin_error) end
        end)
      end
    end

    local function state_now()
      return capture_state()
    end

    local function undo_available()
      local ok, available = pcall(function() return song:can_undo() end)
      assert(ok and type(available) == "boolean", "Song.can_undo is unavailable")
      return available
    end

    local function redo_available()
      local ok, available = pcall(function() return song:can_redo() end)
      assert(ok and type(available) == "boolean", "Song.can_redo is unavailable")
      return available
    end

    local after
    local undo_count, redo_count = 0, 0
    local walk_undo, walk_redo

    local function finish_variant()
      local current = capture_state()
      record.undo_state_count = undo_count
      record.redo_state_count = redo_count
      record.before_state_restored = record.undo_reached_before == true
      record.after_state_restored = state_matches(current, after)
      record.complete_logical_undo_grouped = undo_count == 1 and redo_count == 1 and
        record.undo_reached_before == true and record.redo_reached_after == true and
        record.after_state_restored == true
      record.status = record.complete_logical_undo_grouped and "PASS" or "FAIL"
      if not record.complete_logical_undo_grouped then
        record.reason = undo_count == 0 and "No undo state reached the source/phrase action" or
          undo_count ~= 1 and "Undo split the logical source/phrase action across multiple states" or
          redo_count ~= 1 and "Redo split the logical source/phrase action across multiple states" or
          not record.undo_reached_before and "Undo did not restore the exact pre-action phrase and source state" or
          "Redo did not restore the exact post-action phrase and source state"
      end
      add_variant_record(record)
      next_variant()
    end

    walk_undo = function(previous)
      local current = capture_state()
      if state_matches(current, before) then
        record.undo_reached_before = true
        walk_redo()
        return
      end
      if undo_count >= maximum_history_states then
        record.undo_bound_reached = true
        walk_redo()
        return
      end
      local available = undo_available()
      if not available then walk_redo(); return end
      local called, err = pcall(function() song:undo() end)
      if not called then fail_variant(err); return end
      undo_count = undo_count + 1
      on_next_idle(function()
        local ok, err = pcall(function()
          local observed = state_now()
          record.history[#record.history + 1] = state_summary(observed, before, after,
            "undo", undo_count)
          if previous and state_matches(observed, previous) then
            record.undo_stalled = true
            walk_redo()
          else
            walk_undo(current)
          end
        end)
        if not ok then fail_variant(err) end
      end)
    end

    walk_redo = function()
      local current = capture_state()
      if state_matches(current, after) then
        record.redo_reached_after = true
        finish_variant()
        return
      end
      if redo_count >= maximum_history_states then
        record.redo_bound_reached = true
        finish_variant()
        return
      end
      local available = redo_available()
      if not available then finish_variant(); return end
      local called, err = pcall(function() song:redo() end)
      if not called then fail_variant(err); return end
      redo_count = redo_count + 1
      on_next_idle(function()
        local ok, err = pcall(function()
          local observed = state_now()
          record.history[#record.history + 1] = state_summary(observed, before, after,
            "redo", redo_count)
          walk_redo()
        end)
        if not ok then fail_variant(err) end
      end)
    end

    begin_history_walk = function()
      after = capture_state()
      record.after_tool_data_present = after.tool_data ~= nil
      record.after_tool_data_length = after.tool_data and #after.tool_data or 0
      record.history[#record.history + 1] = state_summary(after, before, after, "after_action", 0)
      walk_undo()
    end

    local function begin_after_setup()
      local ok, err = pcall(start_action)
      if not ok then fail_variant(err) end
    end

    if spec.mutate_phrase and not phrase then
      local inserted, returned = pcall(function()
        return instrument:insert_phrase_at(#original_phrases + 1)
      end)
      if not inserted then
        local addition
        for _, candidate in ipairs(instrument.phrases) do
          local was_original = false
          for _, existing_phrase in ipairs(original_phrases) do
            if rawequal(candidate, existing_phrase) then was_original = true; break end
          end
          if not was_original then
            if addition then addition = nil; break end
            addition = candidate
          end
        end
        if addition and #instrument.phrases == #original_phrases + 1 then phrase = addition end
        fail_variant(returned)
        return
      end
      phrase = returned
      if not phrase or not rawequal(instrument.phrases[#original_phrases + 1], phrase) or
          not original_inventory_matches() then
        fail_variant("probe phrase insertion did not append exactly one phrase to the original inventory")
        return
      end
      local setup_ok, setup_error = pcall(function()
        phrase.name = "ACID SOURCE UNDO BASELINE"
        phrase:line(1):note_column(1).note_value = 48
      end)
      if not setup_ok then fail_variant(setup_error); return end
      on_next_idle(begin_after_setup)
    else
      begin_after_setup()
    end
  end

  local function start_matrix()
    run_variant(1)
  end

  local ok, err = pcall(function()
    assert(type(song.can_undo) == "function" and type(song.can_redo) == "function" and
      type(song.undo) == "function" and type(song.redo) == "function",
      "native Song undo/redo API is unavailable")
    assert(not song:can_undo() and not song:can_redo(),
      "start from a fresh disposable song with empty undo and redo history")
    assert(type(json.array) == "function", "JSON array helper is unavailable")
  end)
  if not ok then
    done({ status = "FAIL", case = case_name, reason = tostring(err), variants = variants })
    return true
  end

  start_matrix()
  return true
end

function M.run(case_name, done, json)
  if type(done) ~= "function" then return false, "completion callback is required" end
  if case_name == "make-independent" then return run_make_independent(done) end
  if case_name == "ownership-negatives" then return run_ownership_negatives(done) end
  if case_name == "import-donor" then return run_ownership_negatives(done, true) end
  if case_name == "independence-undo-prepare" then return run_independence_undo_prepare(done) end
  if case_name == "independence-undo-fixture" then return run_independence_undo_prepare(done, true) end
  if case_name == "independence-undo" then return run_independence_undo(done) end
  if case_name == "revision-undo-fixture" then return run_revision_undo_fixture(done) end
  if case_name == "revision-live-undo-fixture" then return run_revision_undo_fixture(done, case_name) end
  if case_name == "revision-undo-prepare" then return run_revision_undo_prepare(done) end
  if case_name == "revision-undo" then return run_revision_undo(done) end
  if case_name == "revision-live-undo-prepare" then return run_revision_undo_prepare(done, "live-edit") end
  if case_name == "revision-live-undo" then return run_revision_undo(done, "live-edit") end
  if case_name == "cold-reopen-regenerate" then return run_cold_reopen_regenerate(done) end
  if case_name == "cold-reopen-verify" then return run_cold_reopen_verify(done) end
  if case_name == "draft-recovery" then return run_draft_recovery(done) end
  if case_name == "writer-recovery" then return run_writer_recovery(done) end
  if case_name == "multi-instrument-workflow" then return run_multi_instrument_workflow(done, json) end
  if case_name == "integrity-observers" then return run_integrity_observers(done) end
  if case_name == "editor-responsiveness" then return run_editor_responsiveness(done) end
  if case_name == "selection-feasibility" then return run_selection_feasibility(done, json) end
  if case_name == "direct-output-feasibility" then return run_direct_output_feasibility(done, json) end
  if case_name == "source-undo-feasibility" then
    return run_source_undo_feasibility(done, json)
  end
  if case_name == "reopen-independent" then
    local song = renoise.song()
    local instrument_index = song.selected_instrument_index
    local instrument = song.instruments[instrument_index]
    local sequence = require("model.sequencer")
    local store = require("renoise.pattern_store")
    local ownership = require("renoise.phrase_ownership")
    local factory = dofile(renoise.tool().bundle_path .. "\\__dev\\writer_request.lua")
    local old_id, new_id, new_phrase, old_source, independent_source
    local groups = ownership.inventory(song)
    if groups then
      for _, phrase in ipairs(instrument.phrases) do
        local id = ownership.id(phrase)
        local source = id and store.read_entry(song, id)
        if source and source.pitch_events[FIRST_NOTE_LINE] then
          if source.pitch_events[FIRST_NOTE_LINE].note == sequence.BASE_NOTE + ACCEPTANCE_INDEPENDENT_NOTE then
            new_id, new_phrase, independent_source = id, phrase, source
          elseif source.pitch_events[FIRST_NOTE_LINE].note == sequence.BASE_NOTE + ACCEPTANCE_GENERATED_NOTE then
            old_id, old_source = id, source
          end
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
  changed_source.pitch_events[FIRST_NOTE_LINE] = sequence.new_pitch(
    ACCEPTANCE_REGENERATED_NOTE, ACCEPTANCE_KEY, true, false)
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
    local terminal_delivered = false
    local accepted, start_error = writer.regenerate(request, function(result)
      terminal_delivered = true
      if type(result) ~= "table" or result.kind ~= "success" or result.verified ~= true or
          not rawequal(result.phrase, new_phrase) then
        context:release_document()
        done({ status = "FAIL", case = "reopen-independent", reason = describe_failure(result or "Reloaded phrase regeneration failed") })
        return
      end
        local regenerated_id = result.id
        local saved_new = regenerated_id and store.read_entry(song, regenerated_id)
        local historical_new = store.read_entry(song, new_id)
        local saved_old = store.read_entry(song, old_id)
        local after = ownership.inventory(song)
        local passed = #instrument.phrases == 2 and regenerated_id ~= nil and regenerated_id ~= new_id and
          ownership.id(new_phrase) == regenerated_id and
          saved_new and sequence.same_source(saved_new, changed_source) and
          historical_new and sequence.same_source(historical_new, independent_source) and
          saved_old and sequence.same_source(saved_old, old_source) and
          after and after[old_id] and #after[old_id] == 1 and
          after[regenerated_id] and #after[regenerated_id] == 1 and after[new_id] == nil
        context:release_document()
        done({ status = passed and "PASS" or "FAIL", case = "reopen-independent",
          old_id = old_id, previous_independent_id = new_id, regenerated_id = regenerated_id,
          phrase_count = #instrument.phrases,
          regenerated_same_object = rawequal(result.phrase, new_phrase),
          terminal_delivered = terminal_delivered,
          reloaded_sources_and_ids_preserved = passed == true })
    end)
    if not accepted then
      context:release_document()
      done({ status = "FAIL", case = "reopen-independent", reason = describe_failure(start_error) })
    elseif not terminal_delivered then
      context:release_document()
      done({ status = "FAIL", case = "reopen-independent",
        reason = "Synchronous regeneration returned without terminal delivery" })
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
