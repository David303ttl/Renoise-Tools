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
local EDITOR_FIXTURE_OPERATION = "editor-responsiveness fixture lifecycle"
local REQUIRED_SELECTION_SCOPE = "required"
local FIXTURE_SELECTION_SCOPE = "harness-fixture"
local PRODUCTION_LATENCY_DEVICE_OPTION = "midi_output_device"
local PRODUCTION_LATENCY_CASES = {
  ["production-latency-8x8"] = { instruments = 8, owned_per_instrument = 8,
    receiver_counts = { sample = 3, vst = 3, midi = 2 } },
  ["production-latency-16x8"] = { instruments = 16, owned_per_instrument = 8,
    receiver_counts = { sample = 6, vst = 6, midi = 4 } },
}
local ACCEPTANCE_PROFILES = { Warm = true, Detailed = true }
local PROFILED_ACCEPTANCE_CASES = {
  ["editor-responsiveness"] = true,
  ["multi-instrument-workflow"] = true,
}
local prepared_independence_undo = nil
local prepared_revision_undo = nil

local function selection_trace_passes(trace)
  if type(trace) ~= "table" or #trace == 0 then return false end
  for _, event in ipairs(trace) do
    if event.selection_scope == REQUIRED_SELECTION_SCOPE then
      if event.selection_stable ~= true then return false end
    elseif event.selection_scope == FIXTURE_SELECTION_SCOPE then
      if event.operation ~= EDITOR_FIXTURE_OPERATION or
          (event.event ~= "phrase-list-change" and event.event ~= "selected-phrase-change") or
          event.selection_stable ~= nil then
        return false
      end
    else
      return false
    end
  end
  return true
end

local function native_selection(song)
  return {
    instrument = song.selected_instrument,
    phrase = song.selected_phrase,
    instrument_index = song.selected_instrument_index,
    phrase_index = song.selected_phrase_index,
  }
end

local function same_native_selection(left, right)
  return left ~= nil and right ~= nil and
    rawequal(left.instrument, right.instrument) and rawequal(left.phrase, right.phrase) and
    left.instrument_index == right.instrument_index and left.phrase_index == right.phrase_index
end

local function same_native_color(left, right)
  if left == nil or right == nil then return false end
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for index, value in ipairs(left) do
    if value ~= right[index] then return false end
  end
  return #left == #right
end

local function production_output_matches(snapshot,expected)
  if #snapshot.lines~=#expected.lines then return false,"line inventory" end
  for field,value in pairs(expected.properties) do
    if snapshot.properties[field]~=value then return false,"property "..field end
  end
  local note_fields={"note_value","instrument_value","volume_value","panning_value",
    "delay_value","effect_number_value","effect_amount_value","is_empty"}
  local effect_fields={"number_value","amount_value","is_empty"}
  for line,actual in ipairs(snapshot.lines) do
    local wanted=expected.lines[line]
    if #actual.notes~=#wanted.note_columns or #actual.effects~=#wanted.effect_columns then
      return false,"column inventory at line "..line
    end
    for column,cell in ipairs(actual.notes) do
      local target=wanted and wanted.note_columns[column] or expected.empty_note
      for _,field in ipairs(note_fields) do
        if cell[field]~=target[field] then
          return false,"note "..line..":"..column.." "..field
        end
      end
    end
    for column,cell in ipairs(actual.effects) do
      local target=wanted and wanted.effect_columns[column] or expected.empty_effect
      for _,field in ipairs(effect_fields) do
        if cell[field]~=target[field] then
          return false,"effect "..line..":"..column.." "..field
        end
      end
    end
  end
  return true
end

local function editor_fixture_passes(prerequisites, result)
  return prerequisites == true and type(result) == "table" and
    result.editor_fixture_inventory_restored == true and
    result.editor_fixture_native_selection_restored == true
end

local function draft_values_preserved(current_source,current_policy,current_pb,recoveries,
    expected_source,expected_policy,expected_pb,same_source)
  local function matches(source,policy,pb)
    return source~=nil and same_source(source,expected_source) and
      policy==expected_policy and pb==expected_pb
  end
  if matches(current_source,current_policy,current_pb) then return true,"current" end
  for _,entry in ipairs(recoveries or {}) do
    if matches(entry.pattern,entry.output_policy,entry.pb_range) then return true,"recovery" end
  end
  return false
end

local function install_profile_wrapper(profile_mode,target,key,wrap)
  if profile_mode~="Detailed" or type(target)~="table" or type(target[key])~="function" then
    return nil,false
  end
  local original=target[key]
  target[key]=wrap(original)
  return original,true
end

local function callback_latency_acceptance(profile_mode,action_timings)
  if profile_mode=="Detailed" then return "NOT_CLAIMED" end
  return "NOT_GATED"
end

local function source_value(value,encode,json)
  if type(value)~="table" then return value end
  local copy={}
  for key,item in pairs(value) do copy[key]=source_value(item,encode,json) end
  if encode and #value>0 then return json.array(copy) end
  return copy
end

local function resolve_acceptance_profile(case_name,profile_mode)
  if profile_mode~=nil and not PROFILED_ACCEPTANCE_CASES[case_name] then
    return nil,"instrumentation profile is only valid for editor-responsiveness and multi-instrument-workflow"
  end
  if not PROFILED_ACCEPTANCE_CASES[case_name] then return nil end
  profile_mode=profile_mode or "Warm"
  if not ACCEPTANCE_PROFILES[profile_mode] then
    return nil,"instrumentation profile must be Warm or Detailed"
  end
  return profile_mode
end

local function production_latency_fixture(case_name)
  local config=PRODUCTION_LATENCY_CASES[case_name]
  if not config then return nil end
  return {
    instruments=config.instruments,
    owned_per_instrument=config.owned_per_instrument,
    receiver_counts={sample=config.receiver_counts.sample,vst=config.receiver_counts.vst,
      midi=config.receiver_counts.midi},
  }
end

local function production_latency_functional_status(gui_result)
  return type(gui_result)=="table" and gui_result.status=="PASS" and
    gui_result.editor_fixture_inventory_restored==true and
    gui_result.editor_fixture_native_selection_restored==true and
    gui_result.editor_fixture_store_restored==true and
    type(gui_result.gui_live_first_edit_elapsed_ms)=="number"
end

local function diagnostic_performance(measurements)
  for _,measurement in ipairs(measurements or {}) do
    if measurement.instrumentation_profile=="Warm" then return "NOT_GATED" end
  end
  return "NOT_MEASURED"
end

local function create_acceptance_sample(instrument,label)
  if #instrument.samples==0 then instrument:insert_sample_at(1) end
  local sample=instrument.samples[1]
  local buffer=sample.sample_buffer
  local frame_count=256
  if not buffer:create_sample_data(44100,16,1,frame_count) then
    return nil,label.." sample allocation failed"
  end
  buffer:prepare_sample_data_changes()
  local finalized=false
  local ok,err=pcall(function()
    for frame=1,frame_count do
      buffer:set_sample_data(1,frame,math.sin(frame*math.pi*2/frame_count)*0.2)
    end
    buffer:finalize_sample_data_changes()
    finalized=true
  end)
  if not finalized then pcall(buffer.finalize_sample_data_changes,buffer) end
  if not ok then return nil,label.." sample data setup failed: "..tostring(err) end
  sample.name=label.." sample"
  return true
end

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
      local source_missing = not store.read_entry(song, 42)
      local imported_rejected = loaded and imported and ownership.id(imported) == 42 and source_missing and
        writer_rejects_regeneration_without_mutation(song, imported_index, source,
          imported, factory, writer, ownership) and song.tool_data == recipient_data and
        ownership.compare(imported_snapshot, ownership.snapshot(imported))
      local import_details = { loaded = loaded, id = imported and ownership.id(imported),
        status = imported and ownership.status(imported), source_missing = source_missing,
        tool_data_unchanged = song.tool_data == recipient_data,
        generation_rejected_without_mutation = imported_rejected == true }      song:delete_instrument_at(imported_index)
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
            if type(id) == "string" and id:match("^acid_program_key_%d%d$") then
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
  local key_view = state.controls.acid_program_key_01
  local key_callback = state.callbacks.acid_program_key_01
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
    local changed_value = (old_source.pitch_events[FIRST_NOTE_LINE].key + 1) % 12
    if action_mode == "live-edit" then
      state.suppress_live_notifier = true
      live_control.value = true
      state.suppress_live_notifier = false
      local live_called, live_error = pcall(live_callback, true)
      state.live_edit_arm_error = not live_called and tostring(live_error) or nil
      state.live_edit_armed = live_called
    end
    local key_button_id=string.format("acid_program_key_%02d",changed_value+1)
    local selected_key_callback=state.callbacks[key_button_id]
    if type(selected_key_callback)~="function" then error("Production GUI did not expose the selected key button") end
    state.suppress_key_notifier = true
    selected_key_callback()
    state.suppress_key_notifier = false
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
    local key_button=editor_pitch and state.controls[string.format("acid_program_key_%02d",editor_pitch.key+1)]
    details.gui_key_button_color = key_button and safe_text(key_button.color)
    details.selected_instrument_index = selected_instrument_index
    details.selected_phrase_index = selected_phrase_index
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
  local context
  local attached,context_or_error=pcall(function()
    context=require("runtime.context").new({
      writer=writer,
      capture=function() return nil,"The attached runtime owns request capture" end,
      sink=function(request,completion)
        sink_calls=sink_calls+1
        if request.kind=="create" then return writer.create(request,completion) end
        if request.kind=="regenerate" then return writer.regenerate(request,completion) end
        return false,"Unexpected request kind"
      end,
      drafts=require("runtime.draft_cache"),
      cancel=writer.cancel
    })
    context:attach_document(song)
    return context
  end)
  inventory_module.new=original_new
  if not attached then
    done({status="FAIL",case="integrity-observers",reason=tostring(context_or_error)})
    return true
  end
  context= context_or_error
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
  on_next_idle(function()
    local result=delivered_result
    local phrase=result and result.phrase
    local ownership=require("renoise.phrase_ownership")
    local committed_name=phrase and phrase.name
    local phrase_count=#instrument.phrases
    local store_bytes=song.tool_data
    local failed=type(result)~="table" or result.status~="integrity_blocked" or
      result.committed~=true or not phrase or not context:integrity_state().blocked
    if failed then
      context:release_document()
      done({status="FAIL",case="integrity-observers",
        reason="post-commit adoption failure did not persist a blocker"})
      return
    end
    context:close_dialog()
    context:open_dialog(function() end)
    local rebound=context:bind_new(instrument)
    local generation_accepted=context:request_generation("manual")
    local duplicate_accepted=context:request_duplicate()
    local persisted=context:integrity_state().blocked and sink_calls==1 and
      #instrument.phrases==phrase_count and song.tool_data==store_bytes and
      phrase.name==committed_name and ownership.status(phrase)=="owned"
    context:release_document()
    local passed=rebound and rebound.kind=="new" and not generation_accepted and
      not duplicate_accepted and persisted
    done({status=passed and "PASS" or "FAIL",case="integrity-observers",
      post_commit_blocked=true,blocked_after_reopen=persisted,
      generate_rejected=not generation_accepted,duplicate_rejected=not duplicate_accepted,
      committed_phrase_and_store_preserved=persisted,
      sink_calls=sink_calls,
      reason=not passed and "blocker did not remain fail-closed after dialog reopen and target change" or nil})
  end)
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
  local factory=dofile(renoise.tool().bundle_path.."\\__dev\\writer_request.lua")
  local context
  local finished=false
  local terminal
  local sink_calls=0
  local function finish(ok,reason,details)
    if finished then return end
    finished=true
    if context then context:release_document() end
    local result={status=ok and "PASS" or "FAIL",case="writer-recovery",reason=not ok and reason or nil,
      sink_calls=sink_calls,blocked_after_reopen=details and details.blocked_after_reopen,
      committed_source_preserved=details and details.committed_source_preserved,
      subsequent_writes_rejected=details and details.subsequent_writes_rejected,
      reopen_bytes_unchanged=details and details.reopen_bytes_unchanged,
      generate_bytes_unchanged=details and details.generate_bytes_unchanged,
      duplicate_bytes_unchanged=details and details.duplicate_bytes_unchanged,
      native_snapshot_unchanged=details and details.native_snapshot_unchanged,
      target_identity_unchanged=details and details.target_identity_unchanged,
      inventory_unchanged=details and details.inventory_unchanged,
      original_row_unchanged=details and details.original_row_unchanged,
      committed_row_unchanged=details and details.committed_row_unchanged,
      target_rebind_kind=details and details.target_rebind_kind}
    done(result)
  end
  song.transport.lpb=16
  song.transport.groove_enabled=false
  local source=sequence.new_pattern(4)
  source.pitch_events[1]=sequence.new_pitch(4,0,true,false)
  source.time_events[1]="N"
  local request,reason=factory.build(song,instrument_index,source,#instrument.phrases+1)
  if not request then
    finish(false,describe_failure(reason))
    return true
  end
  local created
  local accepted,rejection=writer.create(request,function(result)
    created=result
  end)
  if not accepted then
    finish(false,describe_failure(rejection))
    return true
  end
  on_next_idle(function()
    if type(created)~="table" or created.kind~="success" or created.committed~=true or not created.phrase then
      finish(false,"Initial committed destination was not returned by the writer")
      return
    end
    local destination=created.phrase
    local id=ownership.id(destination)
    if not id then finish(false,"Created destination has no ownership ID");return end
    local initial_source,initial_policy,initial_pb=store.read_entry(song,id)
    if not initial_source or not sequence.same_source(initial_source,source) then
      finish(false,"Initial committed source row could not be verified")
      return
    end
    local next_source=sequence.new_pattern(4)
    next_source.pitch_events[1]=sequence.new_pitch(5,0,true,false)
    next_source.time_events[1]="N"
    context=require("runtime.context").new({writer=writer,
      capture=function() return nil,"Native acceptance installs the source directly" end,
      cancel=writer.cancel,drafts=require("runtime.draft_cache"),
      sink=function(value,completion)
        sink_calls=sink_calls+1
        return writer.regenerate(value,function(result)
          result.integrity_blocked=true
          completion(result)
        end)
      end})
    context:attach_document(song)
    context:open_dialog(function(result) terminal=result end)
    if not context:bind_phrase(instrument,destination) or
        not context:transition("edit",{source=next_source,output_policy="play_once",pb_range=0}) or
        not context:request_generation("manual") then
      finish(false,"Native regeneration fixture could not be dispatched")
      return
    end
    on_next_idle(function()
      if type(terminal)~="table" or terminal.kind~="failure" or
          terminal.status~="integrity_blocked" or not context:integrity_state().blocked then
        finish(false,"Contradictory writer success did not establish a blocker")
        return
      end
      local committed_id=ownership.id(destination)
      local committed_name=destination.name
      local committed_native=assert(ownership.snapshot(destination))
      local committed,policy,pb
      if committed_id then committed,policy,pb=store.read_entry(song,committed_id) end
      local original,original_policy,original_pb=store.read_entry(song,id)
      local source_preserved=committed and sequence.same_source(committed,next_source) and
        policy=="play_once" and pb==0 and committed_id~=id and
        original and sequence.same_source(original,initial_source) and
        original_policy==initial_policy and original_pb==initial_pb
      local committed_bytes=song.tool_data
      local phrase_count=#instrument.phrases
      context:close_dialog()
      context:open_dialog(function() end)
      local rebound=context:bind_phrase(instrument,destination)
      local reopen_bytes_unchanged=song.tool_data==committed_bytes
      local reopen_snapshot_unchanged=ownership.compare(committed_native,assert(ownership.snapshot(destination)))
      local generation_accepted=context:request_generation("manual")
      local generate_bytes_unchanged=song.tool_data==committed_bytes
      local duplicate_accepted=context:request_duplicate()
      local duplicate_bytes_unchanged=song.tool_data==committed_bytes
      local blocked=context:integrity_state().blocked
      local inventory_unchanged=#instrument.phrases==phrase_count
      local target_identity_unchanged=destination.name==committed_name and ownership.id(destination)==committed_id
      local native_snapshot_unchanged=reopen_snapshot_unchanged and
        ownership.compare(committed_native,assert(ownership.snapshot(destination)))
      local final_source,final_policy,final_pb=store.read_entry(song,id)
      local final_committed,final_committed_policy,final_committed_pb=store.read_entry(song,committed_id)
      local original_row_unchanged=final_source and sequence.same_source(final_source,initial_source) and
        final_policy==initial_policy and final_pb==initial_pb
      local committed_row_unchanged=final_committed and sequence.same_source(final_committed,next_source) and
        final_committed_policy=="play_once" and final_committed_pb==0
      local unchanged=source_preserved and sink_calls==1 and inventory_unchanged and
        target_identity_unchanged and native_snapshot_unchanged and reopen_bytes_unchanged and
        generate_bytes_unchanged and duplicate_bytes_unchanged and original_row_unchanged and
        committed_row_unchanged
      local passed=rebound and rebound.kind=="unavailable" and blocked and not generation_accepted and
        not duplicate_accepted and unchanged
      finish(passed,passed and nil or "Blocker did not reject writes or preserve the committed phrase after reopen",{
        blocked_after_reopen=blocked,committed_source_preserved=source_preserved,
        subsequent_writes_rejected=not generation_accepted and not duplicate_accepted,
        reopen_bytes_unchanged=reopen_bytes_unchanged,generate_bytes_unchanged=generate_bytes_unchanged,
        duplicate_bytes_unchanged=duplicate_bytes_unchanged,native_snapshot_unchanged=native_snapshot_unchanged,
        target_identity_unchanged=target_identity_unchanged,inventory_unchanged=inventory_unchanged,
        original_row_unchanged=original_row_unchanged,committed_row_unchanged=committed_row_unchanged,
        target_rebind_kind=rebound and rebound.kind or "nil"})
    end)
  end)
  if not accepted then finish(false,describe_failure(rejection)) end
  return true
end
local function run_multi_instrument_workflow(done, json, profile_mode)
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
        selection_scope = event.selection_scope,
        selection_stable = event.selection_stable,
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
      selection_scope = active_operation == EDITOR_FIXTURE_OPERATION and
        FIXTURE_SELECTION_SCOPE or REQUIRED_SELECTION_SCOPE,
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
  local sample_a, sample_a_error = create_acceptance_sample(instruments[1], "Workflow A")
  local sample_c, sample_c_error = create_acceptance_sample(instruments[3], "Workflow C")
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
          local report_selection_stable = selection_trace_passes(trace)
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
          active_operation = EDITOR_FIXTURE_OPERATION
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
            local final_selection_trace_stable = selection_trace_passes(trace)
            local gui_selection_stable = type(gui_result) == "table" and
              gui_result.gui_native_selection_stable == true and
              gui_result.gui_live_native_selection_stable == true
            local gui_prerequisites = type(gui_result) == "table" and gui_result.status == "PASS" and
              navigation_asserted and live_edit_asserted and source_rows_verified and
              final_selection_trace_stable and gui_selection_stable
            local gui_passed = editor_fixture_passes(gui_prerequisites,gui_result)
            local gui_details = { user_navigation_injected = navigation_asserted,
              live_edit_asserted = live_edit_asserted,
              persistence_asserted = source_rows_verified,
              source_rows_verified = source_rows_verified,
              selection_stable = selection_checks and final_selection_trace_stable and gui_selection_stable,
              selection_trace_stable = final_selection_trace_stable,
              gui_native_selection_stable = gui_selection_stable,
              editor_fixture_native_selection_restored = type(gui_result) == "table" and
                gui_result.editor_fixture_native_selection_restored == true,
              editor_fixture_inventory_restored = type(gui_result) == "table" and
                gui_result.editor_fixture_inventory_restored == true,
              editor_fixture_native_selection_changed = type(gui_result) == "table" and
                gui_result.editor_fixture_native_selection_changed == true,
              gui_live_reason = type(gui_result) == "table" and gui_result.reason or nil,
              gui_live_first_edit_elapsed_ms = type(gui_result) == "table" and
                gui_result.gui_live_first_edit_elapsed_ms or nil,
              gui_live_request_count = type(gui_result) == "table" and
                gui_result.gui_live_request_count or nil,
              instrumentation_profile = type(gui_result) == "table" and
                gui_result.instrumentation_profile or profile_mode,
              performance_acceptance = type(gui_result) == "table" and
                gui_result.performance_acceptance or "NOT_MEASURED",
              acceptance_claim = profile_mode == "Detailed" and "FUNCTIONAL_ONLY" or
                "FUNCTIONAL_AND_LATENCY",
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
          end, profile_mode)
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

run_editor_responsiveness = function(done,profile_mode,requested_fixture_instrument_index,latency_only,existing_gui_context)
  profile_mode=profile_mode or "Warm"
  local detailed_profile=profile_mode=="Detailed"
  local song=renoise.song()
  local store=require("renoise.pattern_store")
  local unpack_values=unpack or table.unpack
  local function pack_values(...) return {n=select("#",...),...} end
  local selected_instrument_index=song.selected_instrument_index
  local selected_instrument=song.instruments[selected_instrument_index]
  local fixture_instrument,fixture_instrument_index
  if requested_fixture_instrument_index~=nil then
    fixture_instrument_index=requested_fixture_instrument_index
    fixture_instrument=song.instruments[fixture_instrument_index]
    if rawequal(fixture_instrument,selected_instrument) or not fixture_instrument or
        #fixture_instrument.phrases>=renoise.Instrument.MAX_NUMBER_OF_PHRASES then
      fixture_instrument=nil
    end
  else
    for index,candidate in ipairs(song.instruments) do
      if not rawequal(candidate,selected_instrument) and #candidate.phrases<renoise.Instrument.MAX_NUMBER_OF_PHRASES then
        fixture_instrument,fixture_instrument_index=candidate,index
        break
      end
    end
  end
  if not fixture_instrument then
    done({status="FAIL",case="editor-responsiveness",instrumentation_profile=profile_mode,
      performance_acceptance="NOT_MEASURED",
      reason="A non-selected instrument with phrase capacity is required for the hidden-cell fixture"})
    return true
  end
  local instrument_index=fixture_instrument_index
  local instrument=fixture_instrument
  local original_phrases={}
  for index,item in ipairs(instrument.phrases) do original_phrases[index]=item end
  local native_selection_at_start=native_selection(song)
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
  metrics.instrumentation_profile=profile_mode
  metrics.performance_acceptance=latency_only and "NOT_CLAIMED" or "NOT_MEASURED"
  metrics.acceptance_claim="FUNCTIONAL_ONLY"
  metrics.latency_diagnostic=latency_only==true
  local scans=0
  local scans_snapshot_wrapper
  local profile={}
  local phrase_profile={}
  local phrase_profile_enabled=false
  local phrase_profile_restore={}
  local local_profile_instrumentation={available=false,wrapped=0,reason="disabled"}
  local profiled_local_functions={}
  local matches_snapshot_call_sites={}
  local matches_snapshot_call_site_count=0
  local hotpath_call_sites={}
  local capture_local_call_sites={}
  local capture_local_call_site_count=0
  local gui_open=false
  local gui_draft_seeded=false
  local original_view_builder
  local original_app_factory
  local captured_test_dialog
  local captured_audition,audition_note
  local gui_context_module,original_gui_context_new,gui_context,gui_transition_context
  local gui_live_trace_enabled=false
  local gui_live_sink_counting=false
  local gui_live_sink_dispatches=0
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
  local duplicate_phrase
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
    gui_live_sink_counting=false
    close_test_gui()
    if gui_context_module and original_gui_context_new then
      pcall(function() gui_context_module.new=original_gui_context_new end)
      gui_context_module=nil
      original_gui_context_new=nil
    end
    for index=#phrase_profile_restore,1,-1 do
      local wrapped=phrase_profile_restore[index]
      if wrapped.restore then
        pcall(wrapped.restore)
      else
        pcall(function() wrapped.target[wrapped.key]=wrapped.original end)
      end
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
    if duplicate_phrase then
      for index,item in ipairs(instrument.phrases) do
        if rawequal(item,duplicate_phrase) then
          pcall(function()instrument:delete_phrase_at(index)end)
          break
        end
      end
      duplicate_phrase=nil
    end
    if phrase then
      for index,item in ipairs(instrument.phrases) do
        if rawequal(item,phrase) then
          pcall(function() instrument:delete_phrase_at(index) end)
          break
        end
      end
    end
    local inventory_restored=#instrument.phrases==#original_phrases
    if inventory_restored then
      for index,item in ipairs(original_phrases) do
        if not rawequal(instrument.phrases[index],item) then inventory_restored=false;break end
      end
    end
    metrics.editor_fixture_inventory_restored=inventory_restored
    metrics.editor_fixture_native_selection_restored=
      same_native_selection(native_selection_at_start,native_selection(song))
    local store_set=pcall(function() song.tool_data=original_store end)
    metrics.editor_fixture_store_restored=store_set and song.tool_data==original_store
  end
  local function fail(reason)
    cleanup()
    local result={status="FAIL",case="editor-responsiveness",reason=tostring(reason)}
    for key,value in pairs(metrics) do result[key]=value end
    done(result)
  end
  local function measure_gui_callbacks()
    local callbacks,controls,callback_counts,action_memory_kb={},{},{},{}
    local native_selection_before=native_selection(song)
    metrics.editor_fixture_native_selection_changed=
      not same_native_selection(native_selection_at_start,native_selection_before)
    local suppress_captured_notifiers=false
    local anonymous_checkbox_index,anonymous_pitch_selector,anonymous_time_selector=0,0,0
    local function profile_function(target,key,name)
      if not detailed_profile then return end
      local original,installed=install_profile_wrapper(profile_mode,target,key,function(inner)
        return function(...)
          local started=os.clock()
          local values=pack_values(inner(...))
          if phrase_profile_enabled then
            local item=phrase_profile[name] or {calls=0,elapsed_ms=0}
            item.calls=item.calls+1
            item.elapsed_ms=item.elapsed_ms+(os.clock()-started)*1000
            phrase_profile[name]=item
            if name=="matches_snapshot" then
              local debug_api=rawget(_G,"debug")
              local info=debug_api and type(debug_api.getinfo)=="function" and debug_api.getinfo(2,"nSl")
              local site=info and ((info.name or "anonymous")..":"..tostring(info.currentline)) or "unavailable"
              if matches_snapshot_call_sites[site]~=nil or matches_snapshot_call_site_count<8 then
                if matches_snapshot_call_sites[site]==nil then
                  matches_snapshot_call_site_count=matches_snapshot_call_site_count+1
                end
                matches_snapshot_call_sites[site]=(matches_snapshot_call_sites[site] or 0)+1
              end
            elseif name=="ownership_inventory" or name=="ownership_validate_identity" or
                name=="ownership_membership" or name=="ownership_is_current" or
                name=="capabilities_inspect" or name=="store_read_entry" then
              local debug_api=rawget(_G,"debug")
              local site="unavailable"
              if debug_api and type(debug_api.getinfo)=="function" then
                local stack={}
                for level=2,5 do
                  local info=debug_api.getinfo(level,"nSl")
                  if not info then break end
                  stack[#stack+1]=(info.name or "anonymous")..":"..tostring(info.currentline)
                end
                if #stack>0 then site=table.concat(stack,"<-") end
              end
              local sites=hotpath_call_sites[name]
              if not sites then sites={entries={},count=0,other=0};hotpath_call_sites[name]=sites end
              if sites.entries[site]~=nil then
                sites.entries[site]=sites.entries[site]+1
              else
                if sites.count<8 then
                  sites.entries[site]=1
                  sites.count=sites.count+1
                else
                  sites.other=sites.other+1
                end
              end
            end
          end
          return unpack_values(values,1,values.n)
        end
      end)
      if installed then phrase_profile_restore[#phrase_profile_restore+1]={target=target,key=key,original=original} end
    end
    local function profile_local_functions(target,key,names,prefix)
      if not detailed_profile then return end
      local debug_api=rawget(_G,"debug")
      if type(debug_api)~="table" or type(debug_api.getupvalue)~="function" or
          type(debug_api.setupvalue)~="function" then
        local_profile_instrumentation.reason="debug upvalue access unavailable"
        return
      end
      local fn=type(target)=="table" and target[key]
      if type(fn)~="function" then
        local_profile_instrumentation.reason="profile target unavailable: "..prefix
        return
      end
      local wanted={}
      for _,name in ipairs(names) do wanted[name]=true end
      local wrapped_count=0
      for index=1,64 do
        local upvalue_name,value=debug_api.getupvalue(fn,index)
        if upvalue_name==nil then break end
        if wanted[upvalue_name] and type(value)=="function" and not profiled_local_functions[value] then
          local original=value
          if prefix=="materializer_apply" and upvalue_name=="verify_snapshot" then
            for nested_index=1,64 do
              local nested_name,nested_value=debug_api.getupvalue(original,nested_index)
              if nested_name==nil then break end
              if nested_name=="expected_matches" and type(nested_value)=="function" and
                  not profiled_local_functions[nested_value] then
                local nested_original=nested_value
                local nested_wrapped=function(...)
                  local started=os.clock()
                  local values=pack_values(nested_original(...))
                  if phrase_profile_enabled then
                    local metric="materializer_apply_expected_matches"
                    local item=phrase_profile[metric] or {calls=0,elapsed_ms=0}
                    item.calls=item.calls+1
                    item.elapsed_ms=item.elapsed_ms+(os.clock()-started)*1000
                    phrase_profile[metric]=item
                  end
                  return unpack_values(values,1,values.n)
                end
                if debug_api.setupvalue(original,nested_index,nested_wrapped)==nested_name then
                  profiled_local_functions[nested_wrapped]=true
                  local_profile_instrumentation.wrapped=local_profile_instrumentation.wrapped+1
                  local_profile_instrumentation.available=true
                  local_profile_instrumentation.reason=nil
                  phrase_profile_restore[#phrase_profile_restore+1]={restore=function()
                    debug_api.setupvalue(original,nested_index,nested_original)
                  end}
                end
              end
            end
          end
          if prefix=="materializer_apply" and upvalue_name=="write_output" then
            local function profile_nested(parent_fn,nested_index,nested_name,nested_original)
              if type(nested_original)~="function" or profiled_local_functions[nested_original] then return end
              local wrapped
              if nested_name=="set_if_different" then
                wrapped=function(...)
                  nested_original(...)
                  if phrase_profile_enabled then
                    local metric="materializer_apply_set_if_different"
                    local item=phrase_profile[metric] or {calls=0,elapsed_ms=0}
                    item.calls=item.calls+1
                    phrase_profile[metric]=item
                  end
                end
              else
                wrapped=function(...)
                  local started=os.clock()
                  local values=pack_values(nested_original(...))
                  if phrase_profile_enabled then
                    local metric="materializer_apply_"..nested_name
                    local item=phrase_profile[metric] or {calls=0,elapsed_ms=0}
                    item.calls=item.calls+1
                    item.elapsed_ms=item.elapsed_ms+(os.clock()-started)*1000
                    phrase_profile[metric]=item
                  end
                  return unpack_values(values,1,values.n)
                end
              end
              if debug_api.setupvalue(parent_fn,nested_index,wrapped)==nested_name then
                profiled_local_functions[wrapped]=true
                local_profile_instrumentation.wrapped=local_profile_instrumentation.wrapped+1
                local_profile_instrumentation.available=true
                local_profile_instrumentation.reason=nil
                phrase_profile_restore[#phrase_profile_restore+1]={restore=function()
                  debug_api.setupvalue(parent_fn,nested_index,nested_original)
                end}
              end
            end
            for nested_index=1,64 do
              local nested_name,nested_value=debug_api.getupvalue(original,nested_index)
              if nested_name==nil then break end
              if nested_name=="set_cell" and type(nested_value)=="function" and
                  not profiled_local_functions[nested_value] then
                local set_cell=nested_value
                for cell_index=1,64 do
                  local cell_name,cell_value=debug_api.getupvalue(set_cell,cell_index)
                  if cell_name==nil then break end
                  if cell_name=="set_if_different" then
                    profile_nested(set_cell,cell_index,cell_name,cell_value)
                  end
                end
                profile_nested(original,nested_index,nested_name,set_cell)
              end
            end
          end
          local wrapped=function(...)
            local started=os.clock()
            local values=pack_values(original(...))
            if phrase_profile_enabled then
              local metric=prefix.."_"..upvalue_name
              local item=phrase_profile[metric] or {calls=0,elapsed_ms=0}
              item.calls=item.calls+1
              item.elapsed_ms=item.elapsed_ms+(os.clock()-started)*1000
              phrase_profile[metric]=item
              if prefix=="capture" then
                local debug_api=rawget(_G,"debug")
                local site="unavailable"
                if debug_api and type(debug_api.getinfo)=="function" then
                  for level=2,5 do
                    local info=debug_api.getinfo(level,"nS")
                    if not info then break end
                    if info.what=="Lua" and info.name and info.name~="capture" then
                      site=info.name
                      break
                    end
                  end
                end
                if capture_local_call_sites[site]~=nil or capture_local_call_site_count<8 then
                  if capture_local_call_sites[site]==nil then
                    capture_local_call_site_count=capture_local_call_site_count+1
                  end
                  local item= capture_local_call_sites[site] or {calls=0,elapsed_ms=0}
                  item.calls=item.calls+1
                  item.elapsed_ms=item.elapsed_ms+(os.clock()-started)*1000
                  capture_local_call_sites[site]=item
                end
              end
            end
            return unpack_values(values,1,values.n)
          end
          local set_name=debug_api.setupvalue(fn,index,wrapped)
          if set_name==upvalue_name then
            profiled_local_functions[wrapped]=true
            wrapped_count=wrapped_count+1
            local_profile_instrumentation.wrapped=local_profile_instrumentation.wrapped+1
            local_profile_instrumentation.available=true
            local_profile_instrumentation.reason=nil
            phrase_profile_restore[#phrase_profile_restore+1]={restore=function()
              debug_api.setupvalue(fn,index,original)
            end}
          end
        end
      end
      if wrapped_count==0 and not local_profile_instrumentation.available then
        local_profile_instrumentation.reason="no requested local upvalues found: "..prefix
      end
    end
    local function reset_phrase_profile()
      phrase_profile={}
      matches_snapshot_call_sites={}
      matches_snapshot_call_site_count=0
      capture_local_call_sites={}
      capture_local_call_site_count=0
      hotpath_call_sites={}
    end
    local function publish_phrase_profile(prefix)
      if not detailed_profile then return end
      for _,name in ipairs({"snapshot","copy_snapshot","compare","classify","classify_against",
          "classify_verified_postimage","classify_against_reference",
          "matches_snapshot","snapshot_index","ownership_status","make_name",
          "capture_recovery","make_name_from_verified_snapshot",
          "preflight_destination","store_allocate","store_prepare_revision","store_commit",
          "materializer_apply","materializer_verify","materializer_restore",
          "context_adopt","runtime_request_guard","runtime_inventory_guard",
          "plan","restore_editor_target","transition","render_project","render_step_text",
          "request_new","request_capture","request_checkpoint","writer_create","writer_regenerate",
          "ownership_inventory","ownership_validate_identity","ownership_membership",
          "ownership_is_current","capabilities_inspect","store_read_entry"}) do
        local item=phrase_profile[name] or {calls=0,elapsed_ms=0}
        metrics[prefix.."_"..name.."_calls"]=item.calls
        metrics[prefix.."_"..name.."_elapsed_ms"]=item.elapsed_ms
      end
      for _,name in ipairs({"capture_capture","ownership_match_matches_snapshot",
          "materializer_apply_valid_expected","materializer_apply_write_output",
          "materializer_apply_set_cell","materializer_apply_set_if_different",
          "materializer_apply_verify_snapshot","materializer_apply_expected_matches",
          "materializer_verify_valid_expected","materializer_verify_verify_snapshot"}) do
        local item=phrase_profile[name] or {calls=0,elapsed_ms=0}
        metrics[prefix.."_"..name.."_calls"]=item.calls
        metrics[prefix.."_"..name.."_elapsed_ms"]=item.elapsed_ms
      end
      local sites={}
      for site,count in pairs(matches_snapshot_call_sites) do sites[#sites+1]=site.."="..count end
      table.sort(sites)
      metrics[prefix.."_matches_snapshot_call_sites"]=table.concat(sites,";")
      local capture_sites={}
      for site,item in pairs(capture_local_call_sites) do
        capture_sites[#capture_sites+1]=site.."="..item.calls.."/"..string.format("%.3f",item.elapsed_ms)
      end
      table.sort(capture_sites)
      metrics[prefix.."_capture_local_call_sites"]=table.concat(capture_sites,";")
      for name,sites in pairs(hotpath_call_sites) do
        local entries={}
        for site,count in pairs(sites.entries) do entries[#entries+1]=site.."="..count end
        if sites.other>0 then entries[#entries+1]="other="..sites.other end
        table.sort(entries)
        metrics[prefix.."_"..name.."_call_sites"]=table.concat(entries,";")
      end
      metrics[prefix.."_local_profile_instrumentation_available"]=local_profile_instrumentation.available
      metrics[prefix.."_local_profile_instrumentation_wrapped"]=local_profile_instrumentation.wrapped
      metrics[prefix.."_local_profile_instrumentation_reason"]=local_profile_instrumentation.reason or ""
    end
    local planner=require("model.output_planner")
    local request_module=require("runtime.requests")
    local inventory_module=require("runtime.inventory")
    local materializer=require("writers.phrase_materializer")
    local store=require("renoise.pattern_store")
    local capabilities=require("renoise.target_capabilities")
    local original_requests_new=request_module.new
    local original_inventory_new=inventory_module.new
    if detailed_profile then
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
    end
    profile_local_functions(ownership,"capture_recovery",{"capture"},"capture")
    profile_local_functions(ownership,"matches_snapshot",{"matches_snapshot"},"ownership_match")
    profile_local_functions(materializer,"apply",{"valid_expected","write_output","verify_snapshot",
      "expected_matches"},"materializer_apply")
    profile_local_functions(materializer,"verify",{"valid_expected","verify_snapshot"},"materializer_verify")
    profile_function(writer,"create","writer_create")
    profile_function(writer,"regenerate","writer_regenerate")
    profile_function(request_module,"new","request_new")
    profile_function(ownership,"snapshot","snapshot")
    profile_function(ownership,"copy_snapshot","copy_snapshot")
    profile_function(ownership,"compare","compare")
    profile_function(ownership,"matches_snapshot","matches_snapshot")
    profile_function(ownership,"snapshot_index","snapshot_index")
    profile_function(ownership,"status","ownership_status")
    profile_function(ownership,"inventory","ownership_inventory")
    profile_function(ownership,"validate_identity","ownership_validate_identity")
    profile_function(ownership,"membership","ownership_membership")
    profile_function(ownership,"is_current","ownership_is_current")
    profile_function(ownership,"make_name","make_name")
    profile_function(ownership,"capture_recovery","capture_recovery")
    profile_function(ownership,"make_name_from_verified_snapshot","make_name_from_verified_snapshot")
    profile_function(validator,"classify","classify")
    profile_function(validator,"classify_against","classify_against")
    profile_function(validator,"classify_verified_postimage","classify_verified_postimage")
    profile_function(validator,"classify_against_reference","classify_against_reference")
    profile_function(validator,"preflight_destination","preflight_destination")
    profile_function(store,"allocate","store_allocate")
    profile_function(store,"read_entry","store_read_entry")
    profile_function(store,"prepare_revision","store_prepare_revision")
    profile_function(store,"commit","store_commit")
    profile_function(capabilities,"inspect","capabilities_inspect")
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
        end
      elseif name=="checkbox" then
        anonymous_checkbox_index=anonymous_checkbox_index+1
        if anonymous_checkbox_index==1 then return "acid_grid_accent" end
        if anonymous_checkbox_index==2 then return "acid_grid_slide" end
        if anonymous_checkbox_index==3 then return "acid_live_edit" end
      elseif name=="button" then
        if properties.text=="Undo" then return "acid_undo" end
        if properties.text=="Redo" then return "acid_redo" end
        for index,label in ipairs({"Output"}) do
          if properties.text==label then return "acid_workspace_tab_"..index end
        end
        if properties.text=="Previous TIME" then return "acid_previous_time" end
        if properties.text=="Next TIME" then return "acid_next_time" end
        if properties.text=="Retry Live Edit" then return "acid_retry_live" end
        if properties.text=="Generate / Regenerate ACID Phrase" then return "acid_generate" end
        if properties.text=="NOTE" then return "acid_time_command_note" end
        if properties.text=="TIE" then return "acid_time_command_tie" end
        if properties.text=="REST" then return "acid_time_command_rest" end
        if properties.text=="P" then
          anonymous_pitch_selector=anonymous_pitch_selector+1
          return string.format("acid_program_select_pitch_%02d",anonymous_pitch_selector)
        end
        if properties.text=="T" then
          anonymous_time_selector=anonymous_time_selector+1
          return string.format("acid_program_select_time_%02d",anonymous_time_selector)
        end
      end
      return nil
    end
    local function tracked_callback(id,notifier)
      local callback=function(...)
        if detailed_profile then callback_counts[id]=(callback_counts[id] or 0)+1 end
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
    local function capture_gui_context(wrapped_context)
      local originals={}
      for key,value in pairs(wrapped_context) do originals[key]=value end
      phrase_profile_restore[#phrase_profile_restore+1]={restore=function()
        for key,value in pairs(originals) do wrapped_context[key]=value end
      end}
      gui_context=wrapped_context
      gui_transition_context=gui_context
      if detailed_profile then
        profile_function(gui_context,"matches_mutation_inventory","runtime_inventory_guard")
        profile_function(gui_context,"request_generation","runtime_request_guard")
      end
      local original_inventory_match=gui_context.matches_mutation_inventory
      if detailed_profile and type(original_inventory_match)=="function" then
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
      if detailed_profile then profile_function(gui_context,"restore_editor_target","restore_editor_target") end
      local original_request_generation=gui_context.request_generation
      if detailed_profile then
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
      end
      if detailed_profile then for _,method_name in ipairs({"flush_pending","close_dialog","release_document","attach_document",
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
      end end
      local original_transition=gui_context.transition
      if detailed_profile then gui_context.transition=function(self,...)
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
      end end
      return gui_context
    end
    gui_context_module.new=function(options)
      gui_context_created_count=gui_context_created_count+1
      return capture_gui_context(original_gui_context_new(options))
    end
    if existing_gui_context then capture_gui_context(existing_gui_context) end
    local original_regenerate=writer.regenerate
    writer.regenerate=function(...)
      if gui_live_sink_counting then gui_live_sink_dispatches=gui_live_sink_dispatches+1 end
      return original_regenerate(...)
    end
    phrase_profile_restore[#phrase_profile_restore+1]={target=writer,key="regenerate",original=original_regenerate}
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
    local captured_builder_factory=renoise.ViewBuilder
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
    local audition_module=require("runtime.audition")
    local original_audition_new=audition_module.new
    audition_module.new=function(options)
      local owner=original_audition_new(options)
      local start=owner.start
      owner.start=function(self,note)
        audition_note=note
        return start(self,note)
      end
      captured_audition=owner
      return owner
    end
    phrase_profile_restore[#phrase_profile_restore+1]={target=audition_module,key="new",original=original_audition_new}
    local shown,show_error=pcall(function() require("gui").show() end)
    audition_module.new=original_audition_new
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
    if detailed_profile then reset_phrase_profile();phrase_profile_enabled=true end
    local phrase_control=actual_phrase_control
    local phrase_dispatch_before=callback_counts.acid_phrase_choice or 0
    if phrase_control then phrase_control.value=phrase_index end
    if (callback_counts.acid_phrase_choice or 0)==phrase_dispatch_before then
      phrase_notifier(phrase_index)
    end
    phrase_profile_enabled=false
    metrics.gui_phrase_selection_elapsed_ms=(os.clock()-phrase_select_started)*1000
    publish_phrase_profile("gui_phrase_initial_profile")
    if not controls.acid_program_select_pitch_01 or not controls.acid_program_select_time_01 then
      close_test_gui()
      return nil,"GUI Program PITCH/TIME selectors were not captured"
    end
    local drafts=require("runtime.draft_cache")
    local persisted=require("renoise.pattern_store")
    local stored,stored_policy,stored_pb=drafts.get(song,instrument,phrase)
    if not stored or stored.length~=32 then
      close_test_gui()
      return nil,"GUI callback target did not load the representative 32-step phrase"
    end
    do
      local status=controls.acid_status
      if not status or not controls.acid_feedback then
        close_test_gui();return nil,"GUI shared feedback views were not captured"
      end
      local before_data=song.tool_data
      local before_revision=gui_context:revision_state().edit_revision
      local duplicate=gui_context.request_duplicate
      local checked,check_error=pcall(function()
        assert(status.text=="" and not status.visible,"ready feedback must be empty")
        metrics.gui_feedback_empty_height=controls.acid_feedback.height
        gui_context.request_duplicate=function()return false,"injected duplicate rejection"end
        callbacks.acid_pattern_duplicate()
        local duplicate_message="Couldn't duplicate the phrase. Try again."
        assert(status.text==duplicate_message and status.visible,"duplicate failure must use shared feedback")
        local one_issue_height=status.height
        callbacks.acid_clipboard_paste()
        assert(status.text=="Copy a scope before pasting.\n"..duplicate_message and status.height>one_issue_height,
          "native feedback must retain both failures and expand for both lines")
        metrics.gui_feedback_multiple_height=status.height
        callbacks.acid_clipboard_copy()
        assert(status.text==duplicate_message and status.height==one_issue_height,
          "Copy must clear only the clipboard failure and restore feedback height")
        assert(song.tool_data==before_data and gui_context:revision_state().edit_revision==before_revision,
          "feedback failure/navigation probes must not save or edit source")
        metrics.gui_feedback_issue_ownership_verified=true
      end)
      gui_context.request_duplicate=duplicate
      if not checked then close_test_gui();return nil,tostring(check_error) end
    end
    local original_note=phrase:line(1):note_column(1).note_value
    local samples={note={},octave={},command={}}
    local select_first_pitch_page=callbacks.acid_pitch_page_1
    local select_first_pitch=callbacks.acid_grid_pitch_01
    if type(select_first_pitch_page)~="function" or type(select_first_pitch)~="function" then
      close_test_gui()
      return nil,"GUI Program first PITCH selector was not captured"
    end
    select_first_pitch_page()
    select_first_pitch()
    if not same_native_color(controls.acid_program_select_pitch_01.color,
        controls.acid_program_pitch_page_1.color) then
      close_test_gui()
      return nil,"GUI Program first PITCH selection was not verified"
    end
    local note_pitch_index=1
    metrics.gui_program_pitch_position_before_note=note_pitch_index
    local last_saved_source=stored
    local last_saved_policy,last_saved_pb=stored_policy,stored_pb
    local current_key=stored.pitch_events[note_pitch_index].key
    local current_octave=stored.pitch_events[note_pitch_index].octave
    local current_command=stored.time_events[2]
    local function invoke(kind,callback_id,notifier,value,check)
      local memory_before=detailed_profile and collectgarbage("count") or nil
      local started=os.clock()
      local control=controls[callback_id]
      suppress_captured_notifiers=true
      if control and value~=nil then control.value=value end
      suppress_captured_notifiers=false
      local dispatch_elapsed=detailed_profile and ((os.clock()-started)*1000) or nil
      if control then
        local callback_started=detailed_profile and os.clock() or nil
        notifier(value)
        if detailed_profile then
          dispatch_elapsed=dispatch_elapsed+(os.clock()-callback_started)*1000
        end
      end
      local elapsed=(os.clock()-started)*1000
      if detailed_profile then metrics["gui_last_"..kind.."_callback_elapsed_ms"]=dispatch_elapsed end
      if detailed_profile then
        metrics["gui_last_"..kind.."_callback_memory_delta_kb"]=collectgarbage("count")-memory_before
      end
      samples[kind]=samples[kind] or {}
      samples[kind][#samples[kind]+1]=elapsed
      local updated,draft_policy,draft_pb=persisted.read_draft(song,instrument,phrase)
      if not updated or sequence.same_source(last_saved_source,updated) then
        metrics["gui_"..kind.."_draft_key_after"]=updated and updated.pitch_events[note_pitch_index].key or -1
        local button_color=control and control.color
        metrics["gui_"..kind.."_button_color_after"]=type(button_color)=="table" and
          table.concat(button_color,",") or tostring(button_color or "unavailable")
        metrics["gui_"..kind.."_button_text_after"]=control and control.text or "unavailable"
        metrics["gui_"..kind.."_phrase_choice_after"]=controls.acid_phrase_choice.value
        metrics["gui_"..kind.."_instrument_choice_after"]=controls.acid_instrument_choice.value
        metrics["gui_"..kind.."_instrument_native_index_after"]=song.selected_instrument_index
        metrics["gui_"..kind.."_instrument_native_matches"]=rawequal(song.selected_instrument,instrument)
        local status=controls.acid_responsiveness_status
        metrics["gui_"..kind.."_status_after"]=status and tostring(status.text):sub(1,240) or "unavailable"
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
      local memory_before=detailed_profile and collectgarbage("count") or nil
      local started=os.clock()
      suppress_captured_notifiers=true
      control.value=value
      suppress_captured_notifiers=false
      if callbacks[alias] then
        callbacks[alias](value)
      end
      local elapsed=(os.clock()-started)*1000
      local memory_delta_kb=detailed_profile and (collectgarbage("count")-memory_before) or nil
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
      local memory_before=detailed_profile and collectgarbage("count") or nil
      local started=os.clock()
      callback()
      local elapsed=(os.clock()-started)*1000
      local memory_delta_kb=detailed_profile and (collectgarbage("count")-memory_before) or nil
      record_action(name,elapsed,memory_delta_kb)
      if check then
        local valid,reason=check()
        if not valid then return nil,reason end
      end
      return true
    end
    local function select_grid_position(kind,page,cell)
      local page_prefix=kind=="pitch" and "acid_pitch_page_" or "acid_time_page_"
      local cell_format=kind=="pitch" and "acid_grid_pitch_%02d" or "acid_grid_select_time_%02d"
      local page_id=page_prefix..page
      local cell_id=string.format(cell_format,cell)
      if type(callbacks[page_id])~="function" or type(callbacks[cell_id])~="function" then
        return nil,"GUI "..kind.." grid selector callbacks were not captured"
      end
      callbacks[page_id]()
      callbacks[cell_id]()
      local previous_view=controls.acid_editor_view.value
      if previous_view~=1 then
        suppress_captured_notifiers=true
        controls.acid_editor_view.value=1
        suppress_captured_notifiers=false
        callbacks.acid_editor_view(1)
      end
      if previous_view~=1 then
        suppress_captured_notifiers=true
        controls.acid_editor_view.value=previous_view
        suppress_captured_notifiers=false
        callbacks.acid_editor_view(previous_view)
      end
      local selector_id=string.format(kind=="pitch" and "acid_program_select_pitch_%02d" or
        "acid_program_select_time_%02d",cell)
      local selector=controls[selector_id]
      if not selector then return nil,"GUI "..kind.." selector was not captured" end
      local program_page_id=(kind=="pitch" and "acid_program_pitch_page_" or
        "acid_program_time_page_")..page
      if not controls[program_page_id] or
          not same_native_color(selector.color,controls[program_page_id].color) then
        return nil,"GUI "..kind.." selected position is not highlighted with its page"
      end
      return true
    end
    local first_key_value=(stored.pitch_events[1].key+1)%12+1
    local key_values={first_key_value,first_key_value%12+1,(first_key_value+1)%12+1}
    for index,value in ipairs(key_values) do
      local key_id=string.format("acid_program_key_%02d",value)
      local ok,reason=invoke("note",key_id,callbacks[key_id],nil,function(updated)
        current_key=value-1
        if updated.pitch_events[note_pitch_index].key~=current_key then
          return false,"GUI note callback did not update the source pitch"
        end
        return true
      end)
      if not ok then close_test_gui();return nil,reason end
    end
    local octave_values={current_octave==0 and "up" or "normal","down","up"}
    local octave_map={down=-1,normal=0,up=1}
    for _,value in ipairs(octave_values) do
      local octave_id="acid_program_octave_"..value
      local ok,reason=invoke("octave",octave_id,callbacks[octave_id],nil,function(updated)
        current_octave=octave_map[value]
        if updated.pitch_events[note_pitch_index].octave~=current_octave then
          return false,"GUI octave callback did not update the source pitch"
        end
        return true
      end)
      if not ok then close_test_gui();return nil,reason end
    end
    local time_selected,time_selection_error=select_grid_position("time",1,2)
    if not time_selected then close_test_gui();return nil,time_selection_error end
    metrics.gui_time_position_selection_verified=true
    current_command=last_saved_source.time_events[2]
    local first_command_value=({N=1,T=2,R=3})[current_command]%3+1
    local command_values={first_command_value,first_command_value%3+1,(first_command_value+1)%3+1}
    for _,value in ipairs(command_values) do
      local expected=({"N","T","R"})[value]
      local command_id=({"acid_time_command_note","acid_time_command_tie","acid_time_command_rest"})[value]
      local ok,reason=invoke("command",command_id,callbacks[command_id],nil,function(updated)
        current_command=expected
        if updated.time_events[2]~=current_command then
          return false,"GUI command callback did not update the source timing"
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
    local function verify_program_entry()
      local app_factory=renoise.app
      local native_app=app_factory()
      local expected_prompt
      local prompt_count=0
      local before_data=song.tool_data
      local before_source=assert(persisted.read_draft(song,instrument,phrase))
      local before_phrase=assert(ownership.snapshot(phrase))
      local before_selection=native_selection(song)
      local function unchanged()
        assert(song.tool_data==before_data,"Program candidate changed durable song data")
        local draft=assert(persisted.read_draft(song,instrument,phrase))
        assert(sequence.same_source(before_source,draft),"Program candidate changed canonical draft")
        assert(ownership.compare(before_phrase,assert(ownership.snapshot(phrase))),
          "Program candidate changed native phrase")
        assert(same_native_selection(before_selection,native_selection(song)),
          "Program audition changed native selection")
      end
      local function start_audition(expected_note)
        assert(captured_audition and controls.acid_audition.active,"Audition PITCH unavailable")
        callbacks.acid_audition()
        assert(captured_audition:active(),"Native audition onset failed")
        assert(audition_note==expected_note,"Audition did not use selected resolved pitch")
        unchanged()
      end
      local function released()
        assert(not captured_audition:active(),"Audition remained active across editor action")
        local outcome=assert(captured_audition:last_outcome())
        assert(outcome.onset_ok and outcome.release_attempted and outcome.release_ok,
          "Native audition onset/release failed")
        assert(#outcome.cleanup_errors==0,"Native audition retained timer or notifier")
      end
      local function prompt(title,answer,button_count,action)
        expected_prompt={title=title,answer=answer,count=button_count}
        action()
        assert(expected_prompt==nil,"Program action did not request its confirmation")
      end
      local called,reason=pcall(function()
        renoise.app=function()
          return setmetatable({}, {__index=function(_,name)
            if name=="show_prompt" then return function(_,title,message,buttons)
              if captured_audition then assert(not captured_audition:active(),"Prompt opened before audition release") end
              assert(expected_prompt and title==expected_prompt.title,"Unexpected Program prompt: "..tostring(title))
              assert(#buttons==expected_prompt.count,"Program guard offered incorrect decisions")
              local answer=expected_prompt.answer
              local available=false
              for _,button in ipairs(buttons) do if button==answer then available=true end end
              assert(available,"Program prompt omitted requested decision")
              expected_prompt=nil
              prompt_count=prompt_count+1
              return answer
            end end
            local member=native_app[name]
            if type(member)=="function" then return function(_,...) return member(native_app,...) end end
            return member
          end})
        end
        callbacks.acid_pitch_page_1()
        callbacks.acid_grid_pitch_01()
        local canonical_note=assert(sequence.prepare_resolution(before_source)).resolved_records[1].note
        start_audition(canonical_note)
        start_audition(canonical_note)
        local second_outcome=assert(captured_audition:last_outcome())
        assert(second_outcome.reason=="second audition" and second_outcome.release_ok and
          #second_outcome.cleanup_errors==0,"Second audition did not release prior lifecycle")
        callbacks.acid_pitch_page_1()
        released()
        start_audition(canonical_note)
        prompt("Enter pitches","Proceed",2,callbacks.acid_program_reenter_pitch)
        released()
        assert(not controls.acid_program_finish.active,"Incomplete Program candidate enabled Finish")
        callbacks.acid_program_key_02()
        local candidate=assert(sequence.copy_source(before_source))
        for position=1,candidate.pitch_length do
          candidate.pitch_events[position]=sequence.new_pitch(0,0,false,false)
        end
        candidate.pitch_events[1]=sequence.new_pitch(1,0,false,false)
        local candidate_note=assert(sequence.prepare_resolution(candidate)).resolved_records[1].note
        start_audition(candidate_note)
        assert(not controls.acid_program_finish.active,"Audition marked candidate entered")
        callbacks.acid_program_pitch_page_2()
        released()
        callbacks.acid_program_select_pitch_16()
        callbacks.acid_program_enter()
        assert(not controls.acid_program_finish.active,"Final Enter bypassed missing positions")
        unchanged()
        prompt("Entry in progress","Stay",2,callbacks.acid_undo)
        unchanged()
        callbacks.acid_program_restart()
        for position=1,before_source.pitch_length do callbacks.acid_program_enter() end
        assert(controls.acid_program_finish.active,"Complete Program candidate disabled Finish")
        callbacks.acid_program_restart()
        callbacks.acid_program_key_03()
        assert(not controls.acid_program_finish.active,"Candidate edit retained entered marker")
        unchanged()
        callbacks.acid_program_enter()
        assert(controls.acid_program_finish.active,"Re-entered candidate did not restore Finish")
        prompt("Entry in progress","Cancel",2,callbacks.acid_undo)
        unchanged()
        assert(not controls.acid_program_enter.active,"Discard retained Program candidate")
        prompt("Enter timing","Proceed",2,callbacks.acid_program_reenter_time)
        assert(not controls.acid_audition.active,"TIME stage enabled audition")
        callbacks.acid_audition()
        assert(not captured_audition:active(),"TIME stage started audition")
        callbacks.acid_program_select_time_02()
        local time_command=before_source.time_events[2]=="R" and "N" or "R"
        callbacks[time_command=="R" and "acid_time_command_rest" or "acid_time_command_note"]()
        callbacks.acid_program_restart()
        for position=1,before_source.length do callbacks.acid_program_enter() end
        assert(controls.acid_program_finish.active,"Complete TIME candidate disabled Finish")
        unchanged()
        callbacks.acid_program_finish()
        local finished=assert(persisted.read_draft(song,instrument,phrase))
        local expected=assert(sequence.copy_source(before_source))
        for position=1,expected.length do expected.time_events[position]="N" end
        expected.time_events[2]=time_command
        assert(sequence.same_source(expected,finished),"Finish did not persist exact TIME candidate")
        assert(not controls.acid_program_enter.active,"Finish retained candidate")
        callbacks.acid_undo()
        local restored=assert(persisted.read_draft(song,instrument,phrase))
        assert(sequence.same_source(before_source,restored),"One Undo did not restore pre-stage source")
        assert(ownership.compare(before_phrase,assert(ownership.snapshot(phrase))),"Finish with Live Edit off changed native phrase")
      end)
      renoise.app=app_factory
      if not called then return nil,"Program entry native callbacks: "..tostring(reason) end
      metrics.gui_program_entry_native_checked=true
      metrics.gui_audition_native_functional_checked=true
      metrics.gui_audition_sound_verified=false
      metrics.gui_audition_timer_duration_verified=false
      metrics.gui_program_entry_prompt_responses_simulated=true
      metrics.gui_program_entry_prompt_count=prompt_count
      return true
    end
    local entry_ok,entry_error=verify_program_entry()
    if not entry_ok then close_test_gui();return nil,entry_error end
    local function verify_clipboard()
      local before=assert(gui_context:editor_state())
      local raw=song.tool_data
      local baseline=assert(ownership.snapshot(phrase))
      local selection=native_selection(song)
      local revisions=gui_context:revision_state()
      local function scope(value)
        suppress_captured_notifiers=true
        controls.acid_clipboard_scope.value=value
        suppress_captured_notifiers=false
        callbacks.acid_clipboard_scope(value)
      end
      local ok,reason=pcall(function()
        for index=1,3 do
          scope(index)
          callbacks.acid_clipboard_copy()
          assert(song.tool_data==raw,"Clipboard Copy changed native song storage")
          local after=gui_context:revision_state()
          assert(after.edit_revision==revisions.edit_revision and
            after.operation_serial==revisions.operation_serial,"Clipboard Copy changed request revisions")
          callbacks.acid_clipboard_paste()
          assert(song.tool_data==raw,"Identical clipboard Paste changed native song storage")
        end
        callbacks.acid_program_select_pitch_01()
        local key=(before.source.pitch_events[1].key+1)%12
        callbacks[string.format("acid_program_key_%02d",key+1)]()
        local edited=assert(gui_context:editor_state())
        assert(not sequence.same_source(before.source,edited.source),"Clipboard fixture did not edit pitch")
        local edited_raw=song.tool_data
        scope(1)
        assert(not controls.acid_clipboard_paste.active,"Mismatched clipboard scope enabled Paste")
        callbacks.acid_clipboard_paste()
        assert(song.tool_data==edited_raw,"Mismatched clipboard Paste changed native song storage")
        scope(3)
        callbacks.acid_clipboard_paste()
        local pasted=assert(gui_context:editor_state())
        assert(sequence.same_source(before.source,pasted.source),"Clipboard Paste did not restore all source slots")
        assert(pasted.label==before.label and pasted.label_custom==before.label_custom and
          pasted.output_policy==before.output_policy and pasted.pb_range==before.pb_range,
          "Clipboard Paste changed excluded metadata")
        callbacks.acid_undo()
        assert(sequence.same_source(edited.source,assert(gui_context:editor_state()).source),
          "Clipboard Paste was not one undoable edit")
        callbacks.acid_undo()
        assert(sequence.same_source(before.source,assert(gui_context:editor_state()).source),
          "Clipboard verification did not restore source")
        assert(ownership.compare(baseline,assert(ownership.snapshot(phrase))),
          "Clipboard operations with Live Edit off changed native phrase")
        assert(same_native_selection(selection,native_selection(song)),"Clipboard operations changed native selection")
      end)
      suppress_captured_notifiers=false
      if not ok then return nil,"Clipboard native callbacks: "..tostring(reason) end
      metrics.gui_clipboard_native_functional_checked=true
      return true
    end
    local clipboard_ok,clipboard_error=verify_clipboard()
    if not clipboard_ok then close_test_gui();return nil,clipboard_error end
    local function verify_labels()
      local builder_factory=renoise.ViewBuilder
      local before=assert(gui_context:editor_state())
      local id=assert(ownership.id(phrase))
      local committed,policy,pb=persisted.read_entry(song,id)
      assert(committed,policy)
      local baseline=assert(ownership.snapshot(phrase))
      local revisions=gui_context:revision_state()
      local name=phrase.name
      local label=before.label=="Native label check" and "Native label alternate" or "Native label check"
      local function exact(expected,custom)
        local source,current_policy,current_pb,current_label,current_custom=persisted.read_entry(song,id)
        assert(sequence.same_source(committed,source) and policy==current_policy and pb==current_pb,
          "Label action changed committed source or output settings")
        assert(current_label==expected and current_custom==custom,"Label action did not persist exact metadata")
        local state=assert(gui_context:editor_state())
        assert(state.label==expected and state.label_custom==custom and
          sequence.same_source(before.source,state.source),"Label action changed dirty musical draft")
        assert(gui_context:revision_state().edit_revision==revisions.edit_revision,
          "Label action changed musical edit revision")
        assert(phrase.name==name and ownership.compare(baseline,assert(ownership.snapshot(phrase))),
          "Label action changed native phrase or seal")
      end
      local ok,reason=pcall(function()
        renoise.ViewBuilder=captured_builder_factory
        callbacks.acid_label_rename()
        controls.acid_label_field.value=label
        callbacks.acid_label_save()
        exact(label,true)
        callbacks.acid_undo()
        exact(before.label,before.label_custom)
        callbacks.acid_redo()
        exact(label,true)
        callbacks.acid_label_rename()
        controls.acid_label_field.value=" invalid"
        local raw=song.tool_data
        callbacks.acid_label_save()
        assert(song.tool_data==raw and controls.acid_label_retry.active,
          "Invalid native label was persisted or lacked Retry")
        callbacks.acid_undo()
        exact(label,true)
        callbacks.acid_label_discard()
        callbacks.acid_undo()
        exact(before.label,before.label_custom)
      end)
      renoise.ViewBuilder=builder_factory
      if not ok then return nil,"Label native callbacks: "..tostring(reason) end
      metrics.gui_labels_native_functional_checked=true
      metrics.gui_labels_native_undo_verified=false
      return true
    end
    local labels_ok,labels_error=verify_labels()
    if not labels_ok then close_test_gui();return nil,labels_error end
    local function verify_extended_operations()
      local app_factory,builder_factory=renoise.app,renoise.ViewBuilder
      local native_app=app_factory()
      local baseline=assert(ownership.snapshot(phrase))
      local selection=native_selection(song)
      local original_view=controls.acid_editor_view.value
      local parameters={seed=17,min_note=24,max_note=60,note_weight=2,tie_weight=1,rest_weight=1}
      local operations={"clear_pitch","clear_time","clear_tie","clear_rest","clear_slide",
        "clear_accent","rest_to_note","tie_to_rest","randomize_pitch","randomize_time"}
      local scope_time_length,scope_pitch_length=7,5
      local scope_random_seed=1
      local pitch_record_fields={"note","key","octave","accent","slide"}
      local function state() return assert(gui_context:editor_state()) end
      local function exact(expected)
        local actual=state()
        assert(sequence.same_source(expected.source,actual.source),"Extended operation source differs")
        assert(actual.label==expected.label and actual.label_custom==expected.label_custom and
          actual.output_policy==expected.output_policy and actual.pb_range==expected.pb_range,
          "Extended operation changed excluded metadata")
        local source,policy,pb,label,custom=persisted.read_draft(song,instrument,phrase)
        assert(source and sequence.same_source(expected.source,source),
          "Extended operation durable draft source differs")
        assert(policy==expected.output_policy and pb==expected.pb_range and
          label==expected.label and custom==expected.label_custom,
          "Extended operation durable draft metadata differs")
      end
      local function scope_preserved(before,after,operation,scope)
        assert(after.length==before.length and after.pitch_length==before.pitch_length,
          "Extended operation changed active bounds")
        local edits_pitch=operation:find("pitch",1,true) or operation=="clear_slide" or operation=="clear_accent"
        for position=1,sequence.MAX_STEPS do
          if not edits_pitch or (scope=="active" and position>before.pitch_length) then
            for _,field in ipairs(pitch_record_fields) do
              assert(after.pitch_events[position][field]==before.pitch_events[position][field],
                "Extended operation changed excluded PITCH storage")
            end
          end
          if edits_pitch or (scope=="active" and position>before.length) then
            assert(after.time_events[position]==before.time_events[position],
              "Extended operation changed excluded TIME storage")
          end
        end
      end
      local function value(id,next_value)
        suppress_captured_notifiers=true
        controls[id].value=next_value
        suppress_captured_notifiers=false
        if callbacks[id] then callbacks[id](next_value) end
      end
      local function set_parameters()
        for parameter,next_value in pairs(parameters) do
          if parameter=="seed" then
            value("acid_operation_pitch_seed",next_value)
            value("acid_operation_time_seed",next_value)
          else value("acid_operation_"..parameter,next_value) end
        end
      end
      local ok,reason=pcall(function()
        renoise.ViewBuilder=captured_builder_factory
        renoise.app=function()
          return setmetatable({}, {__index=function(_,name)
            if name=="show_prompt" or name=="show_custom_prompt" then return function()
              error("Routine source operation opened a prompt")
            end end
            local member=native_app[name]
            if type(member)=="function" then return function(_,...) return member(native_app,...) end end
            return member
          end})
        end
        local fixture_before=state()
        local fixture_edits=0
        local function prepare_fixture(action)
          local previous=state().source
          action()
          if not sequence.same_source(previous,state().source) then fixture_edits=fixture_edits+1 end
        end
        value("acid_operation_scope",2)
        set_parameters()
        for _,operation_index in ipairs({9,10}) do
          value("acid_operation",operation_index)
          prepare_fixture(callbacks.acid_operation_open)
        end
        prepare_fixture(function() value("acid_last_step",scope_time_length) end)
        prepare_fixture(function() value("acid_pitch_length",scope_pitch_length) end)
        local scope_source=state().source
        parameters.seed=scope_random_seed
        set_parameters()
        assert(scope_source.length==scope_time_length and scope_source.pitch_length==scope_pitch_length,
          "Operation scope fixture did not retain independent active bounds")
        for _,operation in ipairs({"clear_pitch","clear_time","randomize_pitch","randomize_time"}) do
          assert(not sequence.same_source(
            assert(sequence.operation_candidate(scope_source,operation,"active",parameters)),
            assert(sequence.operation_candidate(scope_source,operation,"all",parameters))),
            "Operation scope fixture does not distinguish inactive storage: "..operation)
        end
        for _,view_index in ipairs({1,2}) do
          value("acid_editor_view",view_index)
          for operation_index,operation in ipairs(operations) do
            for scope_index,scope in ipairs({"active","all"}) do
              set_parameters()
              local before=state()
              local candidate=assert(sequence.operation_candidate(before.source,operation,scope,parameters))
              value("acid_operation",operation_index)
              value("acid_operation_scope",scope_index)
              local raw=song.tool_data
              callbacks.acid_operation_open()
              if operation=="randomize_pitch" or operation=="randomize_time" then
                local seed_control=operation=="randomize_pitch" and controls.acid_operation_pitch_seed
                  or controls.acid_operation_time_seed
                assert(seed_control.value==parameters.seed,
                  "Random Apply changed the displayed seed")
              end
              local expected={source=candidate,label=before.label,label_custom=before.label_custom,
                output_policy=before.output_policy,pb_range=before.pb_range}
              exact(expected)
              scope_preserved(before.source,state().source,operation,scope)
              if sequence.same_source(before.source,candidate) then
                assert(song.tool_data==raw,"No-op operation persisted data")
              else
                callbacks.acid_undo();exact(before)
                callbacks.acid_redo()
                exact(expected)
                scope_preserved(before.source,state().source,operation,scope)
                callbacks.acid_undo();exact(before)
              end
            end
          end
        end
        for index=1,fixture_edits do callbacks.acid_undo() end
        exact(fixture_before)
        local before=state()
        local edits=0
        local function mask(id,next_value)
          local previous=state().source
          value(id,next_value)
          if not sequence.same_source(previous,state().source) then edits=edits+1 end
        end
        mask("acid_mask_enabled",false)
        for class=1,12 do mask(string.format("acid_mask_class_%02d",class),false) end
        assert(not state().source.scale_mask_enabled,"Disabled class edits enabled mask")
        local raw=song.tool_data
        value("acid_mask_enabled",true)
        assert(song.tool_data==raw and not state().source.scale_mask_enabled,
          "Empty enabled mask was accepted")
        mask("acid_mask_class_01",true)
        assert(not state().source.scale_mask_enabled,"Enabling a disabled class enabled mask")
        mask("acid_mask_enabled",true)
        assert(state().source.scale_mask_enabled,"Nonempty mask did not enable")
        local projection=editor.project(state().source)
        for step,event in ipairs(projection.mapping) do
          if event.kind=="note" then
            assert(event.note%12==0,"C-only mask produced another pitch class")
            local text=editor.step_text(projection,step)
            assert(text:find("RAW ",1,true) and text:find("RES "..event.note,1,true),
              "Decoded omitted raw/resolved pitch")
          end
        end
        raw=song.tool_data
        value("acid_mask_class_01",false)
        assert(song.tool_data==raw and state().source.scale_mask[1],"Last enabled class was removed")
        for index=1,edits do callbacks.acid_undo() end
        exact(before)
        for _,view_index in ipairs({1,2}) do
          value("acid_editor_view",view_index)
          callbacks.acid_pattern_reset()
          local reset=state()
          assert(sequence.same_source(sequence.new_pattern(before.source.length),reset.source),
            "Reset did not restore canonical source defaults")
          assert(reset.label==before.label and reset.label_custom==before.label_custom,
            "Reset changed label")
          local policy=require("model.policies")
          assert(reset.output_policy==policy.DEFAULT_OUTPUT_POLICY and reset.pb_range==policy.DEFAULT_PB_RANGE,
            "Reset did not restore output defaults")
          raw=song.tool_data
          callbacks.acid_pattern_reset()
          assert(song.tool_data==raw,"Identical Reset persisted data")
          if not sequence.same_source(before.source,reset.source) or before.output_policy~=reset.output_policy or
              before.pb_range~=reset.pb_range then callbacks.acid_undo();exact(before) end
        end
        do
          local library=require("model.scales")
          local original=state()
          local raw=song.tool_data
          suppress_captured_notifiers=true
          controls.acid_scale_search.text="Major Pentatonic"
          suppress_captured_notifiers=false
          callbacks.acid_scale_search("Major Pentatonic")
          assert(song.tool_data==raw,"Scale search wrote song data")
          local preset
          for index,name in ipairs(controls.acid_scale_choice.items) do
            if name=="Major Pentatonic" then preset=index;break end
          end
          assert(preset,"Native scale browser did not find Major Pentatonic")
          value("acid_scale_choice",preset)
          local applied=state()
          local c_mask=library.mask({intervals={0,2,4,7,9}},0)
          assert(applied.source.scale_mask_enabled,"Native scale selection did not enable MASK")
          for index=1,12 do
            assert(applied.source.scale_mask[index]==c_mask[index],"Native C preset class differs")
          end
          exact(applied)
          raw=song.tool_data
          value("acid_scale_root",3)
          assert(song.tool_data==raw and
            sequence.same_source(state().source,applied.source),"Root browsing changed native source")
          value("acid_scale_choice",preset)
          local d_mask=library.mask({intervals={0,2,4,7,9}},2)
          for index=1,12 do
            assert(state().source.scale_mask[index]==d_mask[index],"Native D preset class differs")
          end
          callbacks.acid_undo()
          exact(applied)
          value("acid_scale_root",1)
          assert(sequence.same_source(state().source,applied.source),"Returning root changed source")
          value("acid_scale_follow",true)
          value("acid_editor_view",1)
          callbacks.acid_program_select_pitch_01()
          local entry_before=state()
          callbacks.acid_program_key_05()
          local after_allowed=state()
          callbacks.acid_program_key_02()
          local after_constrained=state()
          assert(after_constrained.source.pitch_events[1].note%12==0,
            "Follow Scale did not snap disallowed native note")
          if not sequence.same_source(after_allowed.source,after_constrained.source) then
            callbacks.acid_undo()
          end
          if not sequence.same_source(entry_before.source,after_allowed.source) then
            callbacks.acid_undo()
          end
          exact(applied)
          value("acid_scale_follow",false)
          value("acid_operation",9)
          value("acid_operation_scope",1)
          value("acid_operation_pitch_seed",1)
          value("acid_operation_min_note",24)
          value("acid_operation_max_note",60)
          callbacks.acid_operation_open()
          local randomized_one=state()
          assert(controls.acid_operation_pitch_seed.value==1,"Native random Apply changed the seed")
          callbacks.acid_undo()
          value("acid_operation_pitch_seed",2)
          callbacks.acid_operation_open()
          local randomized_two=state()
          assert(randomized_one.source.pitch_events[1].note~=randomized_two.source.pitch_events[1].note,
            "Consecutive random seeds reused the first masked pitch")
          value("acid_operation_pitch_seed",1)
          callbacks.acid_operation_open()
          exact(randomized_one)
          value("acid_operation_pitch_seed",2)
          callbacks.acid_operation_open()
          exact(randomized_two)
          callbacks.acid_undo()
          callbacks.acid_undo()
          callbacks.acid_undo()
          exact(applied)
          callbacks.acid_undo()
          exact(original)
          assert(controls.acid_scale_root.value==1,"Native browser root did not retain session state")
        end
        assert(ownership.compare(baseline,assert(ownership.snapshot(phrase))),
          "Extended operations with Live Edit off changed native phrase")
        value("acid_editor_view",original_view)
        assert(same_native_selection(selection,native_selection(song)),"Extended operations changed selection")
      end)
      renoise.app,renoise.ViewBuilder=app_factory,builder_factory
      suppress_captured_notifiers=false
      if not ok then return nil,"Extended native callbacks: "..tostring(reason) end
      metrics.gui_extended_operations_native_functional_checked=true
      metrics.gui_mask_native_functional_checked=true
      metrics.gui_reset_native_functional_checked=true
      metrics.gui_extended_inactive_memory_scope_checked=true
      metrics.gui_extended_scope_time_length=scope_time_length
      metrics.gui_extended_scope_pitch_length=scope_pitch_length
      return true
    end
    local extended_ok,extended_error=verify_extended_operations()
    if not extended_ok then close_test_gui();return nil,extended_error end
    local function verify_duplicate()
      local before=assert(gui_context:editor_state())
      local raw=song.tool_data
      local baseline=assert(ownership.snapshot(phrase))
      local id=assert(ownership.id(phrase))
      local committed,policy,pb,label=persisted.read_entry(song,id)
      assert(committed,policy)
      local cache=require("runtime.draft_cache")
      local descriptor=assert(cache.capture(song,instrument,phrase,gui_context:draft_options()))
      local count=#instrument.phrases
      local ok,reason=pcall(function()
        callbacks.acid_pattern_duplicate()
        if #instrument.phrases==count+1 then duplicate_phrase=instrument.phrases[#instrument.phrases] end
        assert(duplicate_phrase,"Duplicate did not append one native phrase: "..tostring(controls.acid_status.text))
        local target=gui_context:target_state()
        assert(rawequal(target.phrase,duplicate_phrase),"Verified duplicate was not selected")
        local copied,copied_policy,copied_pb,copied_label,custom=persisted.read_entry(song,ownership.id(duplicate_phrase))
        assert(sequence.same_source(committed,copied) and copied_policy==policy and copied_pb==pb,
          "Native duplicate used dirty source or changed output settings")
        assert(copied_label==label:sub(1,27):gsub("[ .%-]+$","").." copy" and custom==true,
          "Native duplicate label differs from captured metadata")
        assert(ownership.id(duplicate_phrase)~=id and ownership.compare(baseline,assert(ownership.snapshot(phrase))),
          "Native duplicate changed original phrase or reused its ID")
        assert(cache.is_current(song,descriptor),"Native duplicate changed original draft revision")
        assert(sequence.same_source(before.source,assert(persisted.read_draft(song,instrument,phrase))),
          "Native duplicate consumed original dirty draft")
        suppress_captured_notifiers=true
        controls.acid_phrase_choice.value=generated_phrase_index
        suppress_captured_notifiers=false
        callbacks.acid_phrase_choice(generated_phrase_index)
        assert(sequence.same_source(before.source,assert(gui_context:editor_state()).source),
          "Original dirty source did not restore after duplicate")
        assert(rawequal(instrument.phrases[#instrument.phrases],duplicate_phrase))
        instrument:delete_phrase_at(#instrument.phrases)
        duplicate_phrase=nil
        song.tool_data=raw
        assert(song.tool_data==raw,"Duplicate fixture store did not restore exactly")
      end)
      suppress_captured_notifiers=false
      if not ok then return nil,"Duplicate native callbacks: "..tostring(reason) end
      metrics.gui_duplicate_native_functional_checked=true
      return true
    end
    local stored_now,stored_policy,stored_pb=persisted.read_draft(song,instrument,phrase)
    if not stored_now then close_test_gui();return nil,"GUI draft unavailable before settings benchmark: "..tostring(stored_policy) end
    local settings_actions={
      {"last-step","acid_last_step",31,function(updated)return updated.length==31,"LAST STEP did not update the source length" end},
      {"timing-mode","acid_timing",2,function(updated)return updated.timing_mode=="triplet","Timing control did not update source timing" end},
      {"pitch-length","acid_pitch_length",17,function(updated)return updated.pitch_length==17,"PITCH span did not update source pitch length" end},
      {"output-policy","acid_output_policy",2,function(updated,policy)return policy=="repeat","Output policy did not update the saved draft" end},
      {"pb-range","acid_pb_range",2,function(updated,policy,pb)
        return pb==require("model.policies").PB_CHOICES[2],"PB Range did not update the saved draft"
      end}
    }
    for _,action in ipairs(settings_actions) do
      local ok,reason=run_value(action[1],action[2],action[3],phrase,action[4],true)
      if not ok then return nil,reason end
    end
    local selected_pitch_ok,selected_pitch_error=select_grid_position("pitch",1,2)
    if not selected_pitch_ok then return nil,selected_pitch_error end
    actions[#actions+1]="pitch-position"
    local selected_time_ok,selected_time_error=select_grid_position("time",1,3)
    if not selected_time_ok then return nil,selected_time_error end
    actions[#actions+1]="time-position"
    local grid_ok,grid_error=run_value("grid-view","acid_editor_view",2,phrase,function()
      return controls.acid_grid_panel.visible==true,"Grid view did not update panel visibility"
    end,false)
    if not grid_ok then return nil,grid_error end
    local grid_width_before=controls.acid_grid_panel.width
    local pitch_widths_before={}
    for cell=1,16 do
      pitch_widths_before[cell]=controls[string.format("acid_grid_pitch_%02d",cell)].width
    end
    local time_page_one_ok,time_page_one_error=run_button("time-page-1","acid_time_page_1")
    if not time_page_one_ok then return nil,time_page_one_error end
    local grid_pitch_index=2
    note_pitch_index=grid_pitch_index
    local grid_pitch_value=(last_saved_source.pitch_events[grid_pitch_index].key+1)%12+1
    local grid_time_selected,grid_time_selection_error=select_grid_position("time",1,2)
    if not grid_time_selected then close_test_gui();return nil,grid_time_selection_error end
    local grid_command_ok,grid_command_error=invoke("grid-time-command","acid_time_command_tie",
      callbacks.acid_time_command_tie,nil,function(updated)
        return updated.time_events[2]=="T","Grid TIME assignment button did not update source command"
      end)
    if not grid_command_ok then close_test_gui();return nil,grid_command_error end
    actions[#actions+1]="grid-time-command"
    for key_index=1,12 do
      local key_id=string.format("acid_grid_key_%02d",key_index)
      local key_ok,key_error=invoke("grid-label",key_id,callbacks[key_id],nil,function(updated)
        return updated.pitch_events[grid_pitch_index].key==key_index-1,
          "Grid pitch-class sweep did not update raw key"
      end)
      if not key_ok then return nil,key_error end
      if controls.acid_grid_panel.width~=grid_width_before then
        return nil,"Grid panel width changed during pitch-class sweep"
      end
      for cell=1,16 do
        if controls[string.format("acid_grid_pitch_%02d",cell)].width~=pitch_widths_before[cell] then
          return nil,"Grid PITCH cell width changed during pitch-class sweep"
        end
      end
    end
    metrics.gui_grid_pitch_classes_verified=12
    local grid_actions={
      {"grid-key",string.format("acid_grid_key_%02d",grid_pitch_value),nil,function(updated)return updated.pitch_events[grid_pitch_index].key==grid_pitch_value-1,"Grid key did not update the selected source pitch" end},
      {"grid-octave","acid_grid_octave_up",nil,function(updated)return updated.pitch_events[grid_pitch_index].octave==1,"Grid octave did not update the selected source pitch" end},
      {"grid-accent","acid_grid_accent",false,function(updated)return updated.pitch_events[grid_pitch_index].accent==false,"Grid accent did not update the selected source pitch" end},
      {"grid-slide","acid_grid_slide",true,function(updated)return updated.pitch_events[grid_pitch_index].slide==true,"Grid slide did not update the selected source pitch" end}
    }
    for _,action in ipairs(grid_actions) do
      local profile_grid_key=detailed_profile and action[1]=="grid-key"
      if profile_grid_key then reset_phrase_profile();phrase_profile_enabled=true end
      local ok,reason
      if action[2]=="acid_grid_accent" or action[2]=="acid_grid_slide" then
        ok,reason=run_value(action[1],action[2],action[3],phrase,action[4],true)
      else
        ok,reason=invoke(action[1],action[2],callbacks[action[2]],nil,function(updated)
          return action[4](updated)
        end)
        if ok then actions[#actions+1]=action[1] end
      end
      if profile_grid_key then
        phrase_profile_enabled=false
        publish_phrase_profile("gui_grid_key_profile")
      end
      if not ok then return nil,reason end
      if controls.acid_grid_panel.width~=grid_width_before then
        return nil,"Grid panel width changed after "..action[1]
      end
      for cell=1,16 do
        if controls[string.format("acid_grid_pitch_%02d",cell)].width~=pitch_widths_before[cell] then
          return nil,"Grid PITCH cell width changed after "..action[1]
        end
      end
      metrics.gui_grid_width_stable=true
      metrics.gui_grid_width=grid_width_before
    end
    local page_ok,page_error=run_button("pitch-page-2","acid_pitch_page_2",function()
      return controls.acid_pitch_page_2.text:find("17-32",1,true)~=nil,"PITCH page navigation did not update the page label"
    end)
    if not page_ok then return nil,page_error end
    local time_page_ok,time_page_error=run_button("time-page-2","acid_time_page_2",function()
      return controls.acid_time_page_2.text:find("17-32",1,true)~=nil,"TIME page navigation did not update the page label"
    end)
    if not time_page_ok then return nil,time_page_error end
    for _,id in ipairs({"acid_clipboard_scope","acid_clipboard_copy","acid_clipboard_paste"}) do
      if not controls[id] then return nil,"Editor toolbar control is missing: "..id end
    end
    metrics.gui_toolbar_verified=true
    local workspace_panels={"acid_output_panel"}
    for index,panel_id in ipairs(workspace_panels) do
      local tab_ok,tab_error=run_button("workspace-tab-"..index,"acid_workspace_tab_"..index,function()
        return controls[panel_id].visible==true,"Workspace tab did not reveal "..panel_id
      end)
      if not tab_ok then return nil,tab_error end
      if controls.acid_grid_panel.width~=grid_width_before then
        return nil,"Grid panel width changed after workspace tab selection"
      end
    end
    metrics.gui_workspace_tabs_verified=#workspace_panels
    metrics.gui_output_controls_available=controls.acid_output_policy.active~=false and
      controls.acid_pb_range.active~=false
    if not metrics.gui_output_controls_available then
      return nil,"Output tab controls are unavailable"
    end
    local grid_pitch_ok,grid_pitch_error=run_button("grid-pitch-cell","acid_grid_pitch_02")
    if not grid_pitch_ok then return nil,grid_pitch_error end
    local program_view_ok,program_view_error=run_value("program-view","acid_editor_view",1,phrase,function()
      return controls.acid_program_panel.visible==true,"Program view did not update panel visibility"
    end,false)
    if not program_view_ok then return nil,program_view_error end
    local pitch_page_reselect_ok,pitch_page_reselect_error=select_grid_position("pitch",2,2)
    if pitch_page_reselect_ok then actions[#actions+1]="program-pitch-reselection" end
    if not pitch_page_reselect_ok then return nil,pitch_page_reselect_error end
    local undo_ok,undo_error=run_button("undo","acid_undo")
    if not undo_ok then return nil,undo_error end
    local redo_ok,redo_error=run_button("redo","acid_redo")
    if not redo_ok then return nil,redo_error end
    local reset_app_factory=renoise.app
    local reset_app=reset_app_factory()
    renoise.app=function()
      return setmetatable({}, {__index=function(_,name)
        if name=="show_prompt" then return function()
          error("Reset Pattern requested routine confirmation")
        end end
        local member=reset_app[name]
        if type(member)=="function" then return function(_,...) return member(reset_app,...) end end
        return member
      end})
    end
    local reset_ok,reset_error=run_button("reset-pattern","acid_pattern_reset",function()
      local reset_source=persisted.read_draft(song,instrument,phrase)
      return reset_source~=nil,"Reset Pattern did not save a new draft revision"
    end)
    renoise.app=reset_app_factory
    if not reset_ok then return nil,reset_error end
    local new_phrase_choice_index
    for index,item in ipairs(controls.acid_phrase_choice.items or {}) do
      if item=="NEW PHRASE (append)" then new_phrase_choice_index=index;break end
    end
    if not new_phrase_choice_index then return nil,"GUI instrument target has no New Phrase choice" end
    controls.acid_new_phrase_choice_index=new_phrase_choice_index
    local phrase_choice_ok,phrase_choice_error=run_value("new-phrase-target","acid_phrase_choice",
      new_phrase_choice_index,nil,function()
        return controls.acid_phrase_choice.value==new_phrase_choice_index,
          "New Phrase target was not selected"
      end,false)
    if not phrase_choice_ok then return nil,phrase_choice_error end
    local new_phrase_key_id="acid_program_key_02"
    local new_phrase_ok,new_phrase_error=run_button("new-phrase-note",new_phrase_key_id,function()
      local updated=persisted.read_draft(song,instrument,nil)
      return updated and updated.pitch_events[1].key==1,
        "New Phrase key button did not save its draft"
    end)
    if not new_phrase_ok then return nil,new_phrase_error end
    local old_target_ok,old_target_error=run_value("owned-phrase-target","acid_phrase_choice",
      phrase_index,phrase,function()
        return controls.acid_phrase_choice.value==phrase_index,"Owned phrase target was not restored"
      end,false)
    if not old_target_ok then return nil,old_target_error end
    local warm_phrase_samples={}
    for sample=1,2 do
      local new_target_ok,new_target_error=run_value("new-phrase-reselection-"..sample,
        "acid_phrase_choice",new_phrase_choice_index,nil,function()
          return controls.acid_phrase_choice.value==new_phrase_choice_index,
            "New Phrase target was not selected during warm reselection"
        end,false)
      if not new_target_ok then return nil,new_target_error end
      if detailed_profile then reset_phrase_profile();phrase_profile_enabled=true end
      local warm_started=detailed_profile and os.clock() or nil
      local warm_target_ok,warm_target_error=run_value("owned-phrase-reselection-"..sample,
        "acid_phrase_choice",phrase_index,phrase,function()
          return controls.acid_phrase_choice.value==phrase_index,
            "Owned phrase target was not restored during warm reselection"
        end,false)
      phrase_profile_enabled=false
      if not warm_target_ok then return nil,warm_target_error end
      if detailed_profile then
        warm_phrase_samples[sample]=(os.clock()-warm_started)*1000
        publish_phrase_profile("gui_phrase_warm_"..sample.."_profile")
      end
    end
    if detailed_profile then
      metrics.gui_phrase_warm_reselection_samples_ms=string.format("%.2f,%.2f",
        warm_phrase_samples[1],warm_phrase_samples[2])
    end
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
    local edited_state=gui_context and gui_context:editor_state()
    local persisted_source=persisted.read_draft(song,instrument,phrase)
    if not edited_state or not persisted_source or
        not sequence.same_source(edited_state.source,persisted_source) then
      close_test_gui()
      return nil,"GUI edit callback did not persist the updated draft source"
    end
    if phrase:line(1):note_column(1).note_value~=original_note then
      close_test_gui()
      return nil,"GUI edit callback changed committed phrase without live generation"
    end
    metrics.gui_native_selection_stable=same_native_selection(native_selection_before,native_selection(song))
    if not metrics.gui_native_selection_stable then
      close_test_gui()
      return nil,"GUI editor callbacks changed native instrument or phrase selection"
    end
    if writer.state()=="busy" then
      close_test_gui()
      return nil,"GUI edit callback unexpectedly started generation"
    end
    metrics.gui_callback_paths_verified=true
    metrics.gui_callbacks_per_control=3
    metrics.gui_draft_save_verified=true
    metrics.gui_view_refresh_verified=true
    metrics.gui_unarmed_phrase_unchanged=true
    local live_control=controls.acid_live_edit
    local live_notifier=callbacks.acid_live_edit
    if not live_control or type(live_notifier)~="function" then
      close_test_gui()
      return nil,"GUI Live Edit checkbox callback was not captured"
    end
    local live_key_control=controls.acid_program_key_01
    local live_key_notifier=callbacks.acid_program_key_01
    if not live_key_control or type(live_key_notifier)~="function" then
      close_test_gui()
      return nil,"GUI Live Edit note callback was not captured"
    end
    local function live_probe(finished)
      local duplicate_ok,duplicate_error=verify_duplicate()
      if not duplicate_ok then finished(false,duplicate_error);return end
      local native_selection_before=native_selection(song)
      local live_checkbox_dispatches,live_note_dispatches=0,0
      local function set_live_armed(value)
        suppress_captured_notifiers=true
        live_control.value=value
        suppress_captured_notifiers=false
        live_notifier(value)
        live_checkbox_dispatches=live_checkbox_dispatches+1
      end
      if type(callbacks.acid_grid_pitch_01)~="function" then
        finished(false,"GUI Live Edit test could not select a source pitch")
        return
      end
      callbacks.acid_pitch_page_1()
      callbacks.acid_grid_pitch_01()
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
      local sink_dispatches_before=gui_live_sink_dispatches
      metrics.gui_live_checkbox_found=live_control~=nil
      metrics.gui_live_checkbox_callback_found=live_notifier~=nil
      metrics.gui_live_checkbox_value_before=live_control.value==true
      gui_live_trace_enabled=detailed_profile
      local before_arm_data=song.tool_data
      local before_arm_phrase=assert(ownership.snapshot(phrase))
      local before_arm_inventory=#instrument.phrases
      set_live_armed(true)
      if song.tool_data~=before_arm_data or #instrument.phrases~=before_arm_inventory or
          not ownership.compare(before_arm_phrase,assert(ownership.snapshot(phrase))) then
        finished(false,"Arming Live Edit changed persisted source or phrase")
        return
      end
      local live_context=gui_transition_context or gui_context
      metrics.gui_context_created_count=gui_context_created_count
      metrics.gui_live_transition_context_matches_latest=rawequal(live_context,gui_context)
      local armed=live_context and live_context:generation_state()
      metrics.gui_live_armed_after_toggle=armed and armed.armed==true or false
      metrics.gui_live_busy_after_toggle=armed and armed.busy==true or false
      metrics.gui_live_pending_after_toggle=armed and armed.pending==true or false
      metrics.gui_live_status_after_toggle=armed and tostring(armed.status) or "missing"
      metrics.gui_live_checkbox_value_after=live_control.value==true
      metrics.gui_live_checkbox_callback_dispatches=detailed_profile and
        ((callback_counts.acid_live_edit or 0)-arm_count) or live_checkbox_dispatches
      if not armed or not armed.armed or armed.busy then
        finished(false,"Live Edit did not arm before the source edit")
        return
      end
      local first_value=(before_live.pitch_events[live_index].key+1)%12+1
      local second_value=first_value%12+1
      local function edit_live_note(value)
        local raw_store=song.tool_data or ""
        local source_rows=0
        for _ in raw_store:gmatch("\n%d+|") do source_rows=source_rows+1 end
        metrics.gui_live_source_rows_before_callback=source_rows
        metrics.gui_live_tool_data_bytes_before_callback=#raw_store
        local wall_started=os.time()
        local started=os.clock()
        local key_id=string.format("acid_program_key_%02d",value)
        local key_callback=callbacks[key_id]
        if type(key_callback)~="function" then error("Live Edit key button was not captured: "..key_id) end
        key_callback()
        local elapsed=(os.clock()-started)*1000
        metrics.gui_live_edit_wall_seconds=os.difftime(os.time(),wall_started)
        live_note_dispatches=live_note_dispatches+1
        return elapsed
      end
      if detailed_profile then reset_phrase_profile();phrase_profile_enabled=true end
      gui_live_sink_counting=true
      metrics.gui_live_first_edit_elapsed_ms=edit_live_note(first_value)
      gui_live_sink_counting=false
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
      local request_count=gui_live_sink_dispatches-sink_dispatches_before
      metrics.gui_live_request_generation_calls=detailed_profile and
        (#gui_live_request_trace-request_trace_before) or nil
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
      metrics.gui_live_native_selection_stable=
        same_native_selection(native_selection_before,native_selection(song))
      if not first_state.armed or not metrics.gui_live_terminal_before_return or
          not output_matches or request_count~=1 or
          not metrics.gui_live_revision_id_advanced or not metrics.gui_live_prior_source_retained or
          not metrics.gui_live_native_selection_stable then
        set_live_armed(false)
        finished(false,"Live Edit did not synchronously commit one coherent source revision: writer="..
          tostring(writer_state).." status="..tostring(first_state.status).." result="..
          tostring(live_result and live_result.kind).." pending="..tostring(first_state.pending)..
          " draft="..tostring(draft~=nil).." requests="..tostring(request_count)..
          " revision_advanced="..tostring(metrics.gui_live_revision_id_advanced)..
          " prior_source_retained="..tostring(metrics.gui_live_prior_source_retained))
        return
      end
      local controls_ok,controls_error=pcall(function()
        local peers={}
        for _,peer_instrument in ipairs(song.instruments) do
          for _,candidate in ipairs(peer_instrument.phrases) do
            if not rawequal(candidate,phrase) then
              peers[#peers+1]={phrase=candidate,snapshot=assert(ownership.snapshot(candidate))}
            end
          end
        end
        local function value(id,next_value)
          suppress_captured_notifiers=true
          controls[id].value=next_value
          suppress_captured_notifiers=false
          callbacks[id](next_value)
        end
        local function committed(name,action,check)
          local previous_id=assert(ownership.id(phrase))
          local previous=assert(live_context:editor_state())
          local inventory_count=#instrument.phrases
          action()
          local id=assert(ownership.id(phrase))
          local source,policy,pb=store.read_entry(song,id)
          local actual=assert(live_context:editor_state())
          if check then assert(check(actual,previous),"Live "..name.." did not apply its requested value") end
          local generation=live_context:generation_state()
          assert(id~=previous_id and source and sequence.same_source(source,actual.source) and
            policy==actual.output_policy and pb==actual.pb_range,
            "Live "..name.." did not commit exact source/settings: prior="..previous_id..
            " current="..id.." source="..tostring(source and sequence.same_source(source,actual.source))..
            " policy="..tostring(policy).."/"..tostring(actual.output_policy)..
            " pb="..tostring(pb).."/"..tostring(actual.pb_range)..
            " armed="..tostring(generation.armed).." status="..tostring(generation.status)..
            " reason="..tostring(generation.reason or (generation.last_result and generation.last_result.reason)))
          assert(generation.armed and not generation.busy and not generation.pending and
            generation.last_result and generation.last_result.kind=="success" and writer.state()=="idle",
            "Live control did not finish synchronously")
          assert(not persisted.read_draft(song,instrument,phrase) and #instrument.phrases==inventory_count,
            "Live control retained its committed draft or changed phrase inventory")
          for _,peer in ipairs(peers) do
            assert(ownership.compare(peer.snapshot,assert(ownership.snapshot(peer.phrase))),
              "Live control changed a peer phrase")
          end
          metrics.gui_live_control_last_passed=name
        end
        local navigation_data=song.tool_data
        local navigation_phrase=assert(ownership.snapshot(phrase))
        for _,id in ipairs({"acid_pitch_page_2","acid_pitch_page_1","acid_time_page_2",
            "acid_time_page_1","acid_workspace_tab_1"}) do callbacks[id]() end
        value("acid_editor_view",2);value("acid_editor_view",1)
        value("acid_phrase_choice",new_phrase_choice_index)
        value("acid_phrase_choice",phrase_index)
        live_context=gui_transition_context or gui_context
        metrics.gui_live_armed_after_navigation=live_context:generation_state().armed==true
        metrics.gui_live_checkbox_after_navigation=live_control.value==true
        assert(song.tool_data==navigation_data and
          ownership.compare(navigation_phrase,assert(ownership.snapshot(phrase))),
          "Armed navigation changed persisted source or phrase")
        callbacks.acid_grid_pitch_01()
        local pitch=assert(live_context:editor_state()).source.pitch_events[live_index]
        local octave_id=pitch.octave==1 and "acid_program_octave_normal" or "acid_program_octave_up"
        committed("octave",callbacks[octave_id],function(actual)
          return actual.source.pitch_events[live_index].octave==(pitch.octave==1 and 0 or 1)
        end)
        committed("accent",function() value("acid_program_accent",not controls.acid_program_accent.value) end,
          function(actual,previous)
            return actual.source.pitch_events[live_index].accent~=previous.source.pitch_events[live_index].accent
          end)
        committed("slide",function() value("acid_program_slide",not controls.acid_program_slide.value) end,
          function(actual,previous)
            return actual.source.pitch_events[live_index].slide~=previous.source.pitch_events[live_index].slide
          end)
        callbacks.acid_grid_select_time_01()
        local command=assert(live_context:editor_state()).source.time_events[live_index]
        committed("time",callbacks[command=="R" and "acid_time_command_note" or "acid_time_command_rest"],function(actual)
          return actual.source.time_events[live_index]==(command=="R" and "N" or "R")
        end)
        committed("output",function() value("acid_output_policy",controls.acid_output_policy.value==1 and 2 or 1) end,
          function(actual,previous) return actual.output_policy~=previous.output_policy end)
        committed("undo",callbacks.acid_undo)
        committed("redo",callbacks.acid_redo)
        local metadata_id=assert(ownership.id(phrase))
        local metadata_phrase=assert(ownership.snapshot(phrase))
        local metadata_source=assert(live_context:editor_state()).source
        local metadata_label="Live metadata check"
        local builder_factory=renoise.ViewBuilder
        renoise.ViewBuilder=captured_builder_factory
        local renamed,rename_error=pcall(function()
          callbacks.acid_label_rename()
          controls.acid_label_field.value=metadata_label
          callbacks.acid_label_save()
          callbacks.acid_undo();callbacks.acid_redo()
        end)
        renoise.ViewBuilder=builder_factory
        assert(renamed,rename_error)
        local _,_,_,saved_label,saved_custom=store.read_entry(song,metadata_id)
        assert(saved_label==metadata_label and saved_custom==true,
          "Armed label-only history did not persist the accepted label")
        assert(ownership.id(phrase)==metadata_id and
          ownership.compare(metadata_phrase,assert(ownership.snapshot(phrase))) and
          sequence.same_source(metadata_source,assert(live_context:editor_state()).source),
          "Armed label-only history rendered or changed musical source")
        local disabled_phrase=assert(ownership.snapshot(phrase))
        set_live_armed(false)
        callbacks.acid_grid_pitch_01()
        local disabled_source=assert(live_context:editor_state()).source
        local key_value=(disabled_source.pitch_events[live_index].key+1)%12+1
        callbacks[string.format("acid_program_key_%02d",key_value)]()
        local draft,policy,pb=persisted.read_draft(song,instrument,phrase)
        assert(draft and not sequence.same_source(disabled_source,draft) and
          ownership.compare(disabled_phrase,assert(ownership.snapshot(phrase))),
          "Disarmed source edit did not preserve output and durable draft")
        callbacks.acid_undo();callbacks.acid_redo()
        assert(ownership.compare(disabled_phrase,assert(ownership.snapshot(phrase))),
          "Disarmed Undo/Redo rendered output")
        callbacks.acid_generate()
        local manual_source,manual_policy,manual_pb=store.read_entry(song,assert(ownership.id(phrase)))
        assert(manual_source and sequence.same_source(draft,manual_source) and
          policy==manual_policy and pb==manual_pb and not persisted.read_draft(song,instrument,phrase),
          "Manual Regenerate did not apply the disarmed draft")
        metrics.gui_live_individual_controls_checked="pitch,octave,accent,slide,time,output"
        metrics.gui_live_arming_navigation_no_write_checked=true
        metrics.gui_live_label_history_no_render_checked=true
        metrics.gui_live_undo_redo_checked=true
        metrics.gui_disarmed_edit_manual_regenerate_checked=true
      end)
      suppress_captured_notifiers=false
      if not controls_ok then
        set_live_armed(false)
        finished(false,"Live Edit control coverage: "..tostring(controls_error))
        return
      end
      local disarm_count=callback_counts.acid_live_edit or 0
      local live_dispatches_before_disarm=live_checkbox_dispatches
      set_live_armed(false)
      local disarmed=live_context:generation_state()
      metrics.gui_live_disarmed=not disarmed.armed
      local dialog_closed=close_test_gui()
      metrics.gui_dialog_closed=dialog_closed
      if disarmed.armed or not dialog_closed then
        finished(false,"Live Edit did not disarm or close its dialog cleanly")
        return
      end
      metrics.gui_live_checkbox_dispatches=detailed_profile and
        ((callback_counts.acid_live_edit or 0)-arm_count) or live_checkbox_dispatches
      metrics.gui_live_disarm_dispatches=detailed_profile and
        ((callback_counts.acid_live_edit or 0)-disarm_count) or
        (live_checkbox_dispatches-live_dispatches_before_disarm)
      metrics.gui_live_note_callback_dispatches=live_note_dispatches
      action_timings["live-note"]=metrics.gui_live_first_edit_elapsed_ms
      metrics.gui_live_synchronous_verified=true
      metrics.performance_acceptance=callback_latency_acceptance(profile_mode,action_timings)
      finished(true)
    end
    return true,nil,live_probe
  end
  local function verify_hidden_snapshot_cells()
    local original_fixture_phrases={}
    for index,item in ipairs(fixture_instrument.phrases) do original_fixture_phrases[index]=item end
    local probe_index=#fixture_instrument.phrases+1
    local probe
    local ok,reason=pcall(function()
      probe=fixture_instrument:insert_phrase_at(probe_index)
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
      if detailed_profile then
        local line_read_ms,range_read_ms=0,0
        local equal=true
        local line_count=0
        local range_count=0
        for repetition=1,3 do
          local started=os.clock()
          local individual={}
          for index=1,renoise.InstrumentPhrase.MAX_NUMBER_OF_LINES do
            individual[index]=probe:line(index).is_empty
          end
          line_read_ms=line_read_ms+(os.clock()-started)*1000
          line_count=#individual
          started=os.clock()
          local ranged=probe:lines_in_range(1,renoise.InstrumentPhrase.MAX_NUMBER_OF_LINES)
          if type(ranged)~="table" or #ranged~=renoise.InstrumentPhrase.MAX_NUMBER_OF_LINES then
            error("native phrase range read returned an unexpected line count")
          end
          local flags={}
          for index=1,#ranged do flags[index]=ranged[index].is_empty end
          range_read_ms=range_read_ms+(os.clock()-started)*1000
          range_count=#flags
          for index=1,line_count do
            if individual[index]~=flags[index] then equal=false;break end
          end
          assert(equal,"native phrase range read differed from individual line reads")
        end
        metrics.line_access_probe_repetitions=3
        metrics.line_access_probe_line_count=line_count
        metrics.line_access_probe_range_count=range_count
        metrics.line_access_probe_individual_elapsed_ms=line_read_ms
        metrics.line_access_probe_range_elapsed_ms=range_read_ms
        metrics.line_access_probe_flags_equal=equal
        local column_method_ms,column_array_ms=0,0
        for repetition=1,3 do
          local started=os.clock()
          local individual={}
          for index=385,512 do
            local line=probe:line(index)
            local flags={}
            for column=1,12 do flags[column]=line:note_column(column).is_empty end
            for column=1,8 do flags[12+column]=line:effect_column(column).is_empty end
            individual[index]=flags
          end
          column_method_ms=column_method_ms+(os.clock()-started)*1000
          started=os.clock()
          local batched={}
          for index=385,512 do
            local line=probe:line(index)
            local notes,effects=line.note_columns,line.effect_columns
            assert(#notes==12 and #effects==8,"native column arrays omit hidden columns")
            local flags={}
            for column=1,12 do flags[column]=notes[column].is_empty end
            for column=1,8 do flags[12+column]=effects[column].is_empty end
            batched[index]=flags
          end
          column_array_ms=column_array_ms+(os.clock()-started)*1000
          for index=385,512 do
            for column=1,20 do
              assert(individual[index][column]==batched[index][column],"native column array differs")
            end
          end
        end
        metrics.column_access_probe_method_elapsed_ms=column_method_ms
        metrics.column_access_probe_array_elapsed_ms=column_array_ms
        metrics.column_access_probe_lines=128
        metrics.column_access_probe_repetitions=3
        metrics.column_access_probe_flags_equal=true
      end
      metrics.hidden_snapshot_line=512
      metrics.hidden_snapshot_note_column=12
      metrics.hidden_snapshot_effect_column=8
      metrics.hidden_snapshot_values_verified=true
      metrics.empty_snapshot_defaults_match_native=true
    end)
    if probe then
      for index,item in ipairs(fixture_instrument.phrases) do
        if rawequal(item,probe) then
          pcall(function() fixture_instrument:delete_phrase_at(index) end)
          break
        end
      end
    end
    local restored=#fixture_instrument.phrases==#original_fixture_phrases
    if restored then
      for index,item in ipairs(original_fixture_phrases) do
        if not rawequal(fixture_instrument.phrases[index],item) then restored=false;break end
      end
    end
    return ok and restored,reason or (not restored and "hidden-cell fixture inventory was not restored" or nil)
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
        capture_calls=capture_calls+1
        captured_baseline_is_opaque=type(request.baseline)=="table" and
          request.baseline.id==request.id and rawget(request.baseline,"snapshot")==nil
        if request.kind=="regenerate" then return writer.regenerate(request,completion) end
        if request.kind=="create" then return writer.create(request,completion) end
        return false,"Unexpected request kind"
      end,
      cancel=writer.cancel
    })
    local attached,attach_error=pcall(function() context:attach_document(song) end)
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
      if not detailed_profile then return end
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
    local function stop_snapshot_counter()
      if scans_snapshot_wrapper and rawequal(ownership.snapshot,scans_snapshot_wrapper) then
        ownership.snapshot=original_snapshot
      end
      scans_snapshot_wrapper=nil
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
      if not detailed_profile then return function() end end
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
    local profile_started=detailed_profile and os.clock() or nil
    local profile_transition_started=detailed_profile and os.clock() or nil
    source.pitch_events[1]=sequence.new_pitch(12,0,true,false)
    local profile_called,profiled_edit,profiled_error=pcall(context.transition,context,"edit",{
      source=source,output_policy="play_once",pb_range=0
    })
    for _,restore in ipairs(restore_allocation_profile) do restore() end
    if not profile_called then fail(profiled_edit);return end
    if not profiled_edit then fail(profiled_error or "profiled source edit transition failed");return end
    if detailed_profile then
      metrics.profiled_edit_transition_elapsed_ms=(os.clock()-profile_transition_started)*1000
    end
    local profile_render_started=detailed_profile and os.clock() or nil
    local profiled_projection=editor.project(source)
    for step=1,32 do
      editor.step_text(profiled_projection,step,1)
      editor.step_text(profiled_projection,step,2)
    end
    if detailed_profile then
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
      if detailed_profile then
        ownership.status=function(...)
          ownership_status_calls=ownership_status_calls+1
          return original_ownership_status(...)
        end
      end
      local called,edited,edit_error=pcall(context.transition,context,"edit",{
        source=edit_source,output_policy="play_once",pb_range=0
      })
      if detailed_profile then ownership.status=original_ownership_status end
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
    metrics.unarmed_edit_snapshot_scans=edit_scans
    metrics.unarmed_edit_samples=5
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
    if detailed_profile then
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
    end
    ownership.copy_snapshot=original_copy_snapshot
    ownership.compare=original_compare
    ownership.matches_snapshot=original_matches_snapshot
    validator.classify=original_classify
    validator.classify_against=original_classify_against
    if detailed_profile and profile.classify_against.calls~=0 then
      fail("clean unarmed source edits invoked full classify_against validation");return
    end
    if detailed_profile and profile.matches_snapshot.calls~=0 then
      fail("clean unarmed source edits performed full native cell matching");return
    end
    if detailed_profile and ownership_status_calls~=0 then
      fail("clean unarmed source edits hashed native phrase cells for draft persistence");return
    end
    if max_edit_sample_ms>100 then
      fail("source edit transition and render exceeded 100 ms: "..tostring(max_edit_sample_ms));return
    end
    if sink_calls~=0 then fail("unarmed source edits unexpectedly started generation");return end
    if not detailed_profile then stop_snapshot_counter() end
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
      local passed=editor_fixture_passes(
        committed and preserved and capture_calls==1 and sink_calls==1,metrics)
      metrics.phrase_lines=generated_lines
      metrics.unchanged_snapshot_scans=scan_count
      metrics.stale_metadata_request_rejected=true
      metrics.restored_metadata_request_committed=committed
      metrics.metadata_request_used_fresh_baseline=preserved
      metrics.generation_calls=sink_calls
      local result={status=passed and "PASS" or "FAIL",case="editor-responsiveness",
        stale_metadata_request_rejected=true,restored_metadata_request_committed=committed,
        metadata_request_used_fresh_baseline=preserved,generation_calls=sink_calls,
        reason=not passed and (metrics.editor_fixture_inventory_restored~=true and
          "editor responsiveness fixture inventory was not restored" or
          metrics.editor_fixture_native_selection_restored~=true and
            "editor responsiveness fixture did not restore initial native selection" or
          "metadata-driven fresh request failed") or nil}
      for key,value in pairs(metrics) do result[key]=value end
      done(result,gui_context)
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
  local valid_duplicate_pair = ownership.status(duplicate_source) == "owned" and
    ownership.status(duplicate_copy) == "owned" and
    ownership.id(duplicate_source) == duplicate_id and ownership.id(duplicate_copy) == duplicate_id and
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

local function run_production_latency(done,case_name,options,json)
  local config=production_latency_fixture(case_name)
  local song=renoise.song()
  local sequence=require("model.sequencer")
  local writer=require("writers.phrase_writer")
  local ownership=require("renoise.phrase_ownership")
  local store=require("renoise.pattern_store")
  local factory=dofile(renoise.tool().bundle_path.."\\__dev\\writer_request.lua")
  options=type(options)=="table" and options or {}
  local initial_instrument_index=song.selected_instrument_index
  local initial_instrument_count=#song.instruments
  local initial_phrase_count=0
  for _,instrument in ipairs(song.instruments) do initial_phrase_count=initial_phrase_count+#instrument.phrases end
  local midi_device=options[PRODUCTION_LATENCY_DEVICE_OPTION]
  local clock_probe
  local probe_clock,probe_active
  local function stop_clock_probe()
    probe_active=false
    if not probe_clock then return true end
    local tool=renoise.tool()
    local checked,present=pcall(function() return tool:has_timer(probe_clock) end)
    if checked and present==false then return true end
    pcall(function() tool:remove_timer(probe_clock) end)
    checked,present=pcall(function() return tool:has_timer(probe_clock) end)
    return checked and present==false
  end
  local function fail(reason,extra)
    local clock_cleaned=stop_clock_probe()
    local selection_set=pcall(function() song.selected_instrument_index=initial_instrument_index end)
    local selection_restored=selection_set and song.selected_instrument_index==initial_instrument_index
    local result={status="FAIL",case=case_name,reason=reason,
      execution_mode="FUNCTIONAL_DIAGNOSTIC",functional_status="FAIL",
      clock_probe_cleanup_verified=clock_cleaned,
      fixture_cleanup_scope="runner-owned disposable process; per-measurement editor fixture restored separately",
      acceptance_claim="FUNCTIONAL_ONLY",performance_acceptance="NOT_CLAIMED",
      latency_diagnostic=true,instrumentation_profile="Warm",
      final_native_selection_restored=selection_restored}
    for key,value in pairs(extra or {}) do result[key]=value end
    result.performance_acceptance=diagnostic_performance(result.measurements)
    result.clock_probe=clock_probe
    done(result)
  end
  if not config then fail("unknown production latency fixture");return true end
  if initial_phrase_count~=0 or initial_instrument_count<1 then
    fail("production latency diagnostic requires an empty disposable song")
    return true
  end
  if type(midi_device)~="string" or midi_device=="" then
    fail("an explicit MIDI output device is required for this diagnostic")
    return true
  end
  local midi_output_available=false
  for _,name in ipairs(renoise.Midi.available_output_devices()) do
    if name==midi_device then midi_output_available=true;break end
  end
  if not midi_output_available then
    fail("requested MIDI output device is unavailable: "..midi_device)
    return true
  end
  while #song.instruments<config.instruments do
    song:insert_instrument_at(#song.instruments+1)
  end
  local instruments,receivers,targets={},{},{}
  for index=1,config.instruments do instruments[index]=song.instruments[index] end
  for index=1,config.receiver_counts.sample do receivers[#receivers+1]={kind="sample",instrument_index=index} end
  local vst_start=#receivers+1
  for offset=1,config.receiver_counts.vst do
    receivers[#receivers+1]={kind="vst",instrument_index=vst_start+offset-1}
  end
  local midi_start=#receivers+1
  for offset=1,config.receiver_counts.midi do
    receivers[#receivers+1]={kind="midi",instrument_index=midi_start+offset-1}
  end
  local plugin_info
  for _,info in ipairs(instruments[vst_start].plugin_properties.available_plugin_infos) do
    local name=type(info.name)=="string" and info.name:lower() or ""
    if name:find("surge xt",1,true) and type(info.path)=="string" and info.path~="" then
      plugin_info=info;break
    end
  end
  if not plugin_info then
    fail("Surge XT is not available in Renoise's plugin registry")
    return true
  end
  for _,receiver in ipairs(receivers) do
    local instrument=instruments[receiver.instrument_index]
    instrument.name="Latency receiver "..receiver.kind.." "..tostring(receiver.instrument_index)
    if receiver.kind=="sample" then
      local ok,reason=create_acceptance_sample(instrument,instrument.name)
      if not ok then fail(reason);return true end
    elseif receiver.kind=="vst" then
      local properties=instrument.plugin_properties
      local loaded,load_error=pcall(properties.load_plugin,properties,plugin_info.path)
      if not loaded or not properties.plugin_loaded then
        fail("Surge XT could not be loaded: "..tostring(load_error or plugin_info.name));return true
      end
    else
      local assigned,assign_error=pcall(function()
        instrument.midi_output_properties.device_name=midi_device
      end)
      if not assigned or instrument.midi_output_properties.device_name~=midi_device then
        fail("MIDI output device could not be assigned: "..tostring(assign_error or midi_device));return true
      end
    end
  end
  local successful_history_regenerations=0
  local function native_phrase_count()
    local count=0
    for _,instrument in ipairs(song.instruments) do count=count+#instrument.phrases end
    return count
  end
  local function source_for(index,revision)
    local source=sequence.new_pattern(32)
    for step=1,32 do
      source.pitch_events[step]=sequence.new_pitch((step+index+revision)%13,0,true,false)
      source.time_events[step]="N"
    end
    return source
  end
  local function finish_measurements(measurements)
    local phrase_count=native_phrase_count()
    local selection_set=pcall(function() song.selected_instrument_index=initial_instrument_index end)
    local selection_restored=selection_set and song.selected_instrument_index==initial_instrument_index
    if not selection_restored then
      fail("native selection was not restored after diagnostic",{phrase_count_before_measurement=phrase_count})
      return
    end
    local performance=diagnostic_performance(measurements)
    local result={status="PASS",case=case_name,
      execution_mode="FUNCTIONAL_DIAGNOSTIC",functional_status="PASS",
      fixture_cleanup_scope="runner-owned disposable process; per-measurement editor fixture restored separately",
      acceptance_claim="FUNCTIONAL_ONLY",performance_acceptance=performance,
      latency_diagnostic=true,instrumentation_profile="Warm",
      instrument_count=config.instruments,song_instrument_count=#song.instruments,owned_phrase_count=#targets,
      foreign_phrase_count=config.instruments,phrase_count_before_measurement=phrase_count,
      phrase_count_during_measurement=phrase_count+1,
      temporary_phrase_count=1,receiver_counts=config.receiver_counts,
      source_steps=32,history_regenerations=successful_history_regenerations,
      midi_output_device=midi_device,vst_plugin=plugin_info.name,
      vst_preset_mode="startup-default",final_native_selection_restored=selection_restored,
      measurements=measurements}
    result.clock_probe=clock_probe
    done(result)
  end
  local function fail_measurement(reason,measurements,gui_failure)
    local phrase_count=native_phrase_count()
    local owned_count,foreign_count=0,0
    for _,instrument in ipairs(instruments) do
      for _,phrase in ipairs(instrument.phrases) do
        if ownership.id(phrase) then owned_count=owned_count+1 else foreign_count=foreign_count+1 end
      end
    end
    fail(reason,{instrument_count=config.instruments,song_instrument_count=#song.instruments,owned_phrase_count=owned_count,
      foreign_phrase_count=foreign_count,phrase_count_before_measurement=phrase_count,
      phrase_count_during_measurement=phrase_count+1,temporary_phrase_count=1,
      source_steps=32,history_regenerations=successful_history_regenerations,
      measurements=measurements,failed_measurement=gui_failure})
  end
  local measurement_targets={1,1,1,1}
  local measurements=json.array()
  local measured_gui_context
  local function measure_phase(phase,next_step)
    local cursor=1
    local function measure_next()
      local target_index=measurement_targets[cursor]
      if not target_index then next_step();return end
      local instrument= song.instruments[target_index]
      local measurement_profile=cursor==4 and "Detailed" or "Warm"
      local source_rows=0
      local raw_store=song.tool_data or ""
      for _ in raw_store:gmatch("\n%d+|") do source_rows=source_rows+1 end
      local store_bytes=#raw_store
      local phrase_count=native_phrase_count()
      collectgarbage("collect")
      local memory_kb=collectgarbage("count")
      song.selected_instrument_index=target_index==1 and 2 or 1
      run_editor_responsiveness(function(gui_result,returned_context)
        if not production_latency_functional_status(gui_result) then
          fail_measurement(type(gui_result)=="table" and gui_result.reason or
            "production GUI latency helper returned no functional result",measurements,gui_result)
          return
        end
        measured_gui_context=returned_context
        measurements[#measurements+1]={phase=phase,instrument_index=target_index,
          repetition=cursor,instrumentation_profile=measurement_profile,
          source_rows=source_rows,tool_data_bytes=store_bytes,
          callback_source_rows=gui_result.gui_live_source_rows_before_callback,
          callback_tool_data_bytes=gui_result.gui_live_tool_data_bytes_before_callback,
          lua_memory_after_gc_kb=memory_kb,
          song_phrase_count=phrase_count,song_instrument_count=#song.instruments,
          receiver_kind=receivers[target_index].kind,
          owned_phrases_on_instrument=phase=="empty-phrase-inventory" and 0 or config.owned_per_instrument,
          native_phrase_count_during_measurement=#instrument.phrases+1,
          elapsed_ms=gui_result.gui_live_first_edit_elapsed_ms,
          wall_seconds=gui_result.gui_live_edit_wall_seconds,
          performance_acceptance=gui_result.performance_acceptance,
          functional_status=gui_result.status}
        if measurement_profile=="Detailed" then
          measurements[#measurements].profile=gui_result
        end
        cursor=cursor+1
        on_next_idle(measure_next)
      end,measurement_profile,target_index,true,measured_gui_context)
    end
    measure_next()
  end
  local function regenerate_all(round,next_step)
    local cursor=1
    local function regenerate_next()
      local target=targets[cursor]
      if not target then next_step();return end
      local phrase_index
      for index,phrase in ipairs(target.instrument.phrases) do
        if rawequal(phrase,target.phrase) then phrase_index=index;break end
      end
      if not phrase_index then fail_measurement("owned latency fixture phrase disappeared",measurements);return end
      local changed=source_for(target.instrument_index+target.slot,round)
      local request,request_error=factory.build(song,target.instrument_index,changed,phrase_index)
      if not request or request.kind~="regenerate" then
        fail_measurement(tostring(request_error or "history regeneration request was rejected"),measurements);return
      end
      local accepted,start_error=writer.regenerate(request,function(result)
        on_next_idle(function()
          if type(result)~="table" or result.kind~="success" or result.verified~=true or
              not rawequal(result.phrase,target.phrase) or ownership.id(target.phrase)==nil then
            fail_measurement("history regeneration failed: "..describe_failure(result or start_error),measurements);return
          end
          target.source=changed
          successful_history_regenerations=successful_history_regenerations+1
          cursor=cursor+1
          regenerate_next()
        end)
      end)
      if not accepted then fail_measurement(describe_failure(start_error),measurements) end
    end
    regenerate_next()
  end
  local function seed_targets()
    local cursor=1
    local function create_next()
      local target=targets[cursor]
      if not target then
        for _,instrument in ipairs(instruments) do
          local foreign=instrument:insert_phrase_at(#instrument.phrases+1)
          foreign.name="Latency foreign "..tostring(#instrument.phrases)
          if ownership.status(foreign)~="foreign" or ownership.id(foreign)~=nil then
            fail_measurement("foreign latency fixture phrase was not classified as foreign",measurements);return
          end
        end
        local owned_count,foreign_count=0,0
        for _,instrument in ipairs(instruments) do
          if #instrument.phrases~=config.owned_per_instrument+1 then
            fail_measurement("seeded phrase count does not match the latency fixture",measurements);return
          end
          for _,phrase in ipairs(instrument.phrases) do
            if ownership.id(phrase)~=nil and ownership.status(phrase)=="owned" then
              owned_count=owned_count+1
            elseif ownership.id(phrase)==nil and ownership.status(phrase)=="foreign" then
              foreign_count=foreign_count+1
            else
              fail_measurement("seeded phrase ownership classification is inconsistent",measurements);return
            end
          end
        end
        if owned_count~=#targets or foreign_count~=config.instruments or
            native_phrase_count()~=(config.instruments*(config.owned_per_instrument+1)) then
          fail_measurement("seeded native owned, foreign, or total phrase counts do not match",measurements);return
        end
        measure_phase("early",function()
          regenerate_all(1,function()
            regenerate_all(2,function() measure_phase("late",function() finish_measurements(measurements) end) end)
          end)
        end)
        return
      end
      local instrument=target.instrument
      local source=source_for(target.instrument_index+target.slot,0)
      local request,request_error=factory.build(song,target.instrument_index,source,#instrument.phrases+1)
      if not request or request.kind~="create" then
        fail_measurement(tostring(request_error or "owned latency fixture request was rejected"),measurements);return
      end
      local accepted,start_error=writer.create(request,function(result)
        on_next_idle(function()
          local id=type(result)=="table" and result.phrase and ownership.id(result.phrase) or nil
          local stored=id and store.read_entry(song,id)
          if type(result)~="table" or result.kind~="success" or result.verified~=true or
              not result.phrase or not id or not stored then
            fail_measurement("owned latency fixture create failed: "..describe_failure(result or start_error),measurements);return
          end
          target.phrase=result.phrase
          target.source=source
          target.id=id
          cursor=cursor+1
          create_next()
        end)
      end)
      if not accepted then fail_measurement(describe_failure(start_error),measurements) end
    end
    create_next()
  end
  for instrument_index,instrument in ipairs(instruments) do
    for slot=1,config.owned_per_instrument do
      targets[#targets+1]={instrument=instrument,instrument_index=instrument_index,slot=slot}
    end
  end
  for _,instrument in ipairs(instruments) do
    if #instrument.phrases~=0 then fail("instrument phrases must be empty before fixture seeding");return true end
  end
  local wall_started,clock_started=os.time(),os.clock()
  local tool=renoise.tool()
  probe_clock=function()
    if not probe_active then return end
    if not stop_clock_probe() then fail("clock probe timer cleanup failed");return end
    local wall_seconds=os.difftime(os.time(),wall_started)
    clock_probe={requested_timer_ms=2000,os_time_seconds=wall_seconds,
      os_clock_delta=os.clock()-clock_started,wall_resolution_seconds=1}
    measure_phase("empty-phrase-inventory",seed_targets)
  end
  probe_active=true
  local probe_added,probe_error=pcall(function() tool:add_timer(probe_clock,2000) end)
  if not probe_added then fail("clock probe timer registration failed: "..tostring(probe_error)) end
  return true
end

local PRODUCTION_SESSION_CASES = {
  ["production-session-8x8"] = {instruments=8, samples=3, plugins=3, rounds=2},
  ["production-stress-16x8"] = {instruments=16, samples=6, plugins=6, rounds=4},
}
local prepared_production_session

local function run_production_session(done,case_name,options,json)
  options=options or {}
  if options.stage=="undo" then
    if not prepared_production_session or prepared_production_session.case~=case_name then
      done({status="FAIL",case=case_name,reason="no prepared production user action"})
    else prepared_production_session.resume(done) end
    return true
  end
  local config=PRODUCTION_SESSION_CASES[case_name]
  local song=renoise.song()
  local sequence=require("model.sequencer")
  local ownership=require("renoise.phrase_ownership")
  local store=require("renoise.pattern_store")
  local context_module=require("runtime.context")
  local controls,callbacks,targets,foreign={},{},{},{}
  local context,dialog,suppress,settled,key_handler,midi_input,expected_native_selection
  local selected_color
  local trace=json.array()
  local original_builder,original_app=renoise.ViewBuilder,renoise.app
  local original_context_new=context_module.new
  local result={case=case_name,status="FAIL",performance_acceptance="NOT_GATED",
    complete=false,
    instrument_count=config.instruments,created=0,regenerated=0,
    actions=trace,edits=json.array(),phases={seed="NOT_RUN",edits="NOT_RUN",drafts="NOT_RUN",
      native_undo="NOT_RUN",cold_reopen="NOT_RUN",playback="NOT_RUN"}}
  local fixture_name="acceptance-production.xrns"
  local later
  local baseline_path=renoise.tool().bundle_path.."\\..\\fixtures\\acceptance-production-baseline.json"
  local function record_state(phase)
    local path=renoise.tool().bundle_path.."\\..\\fixtures\\acceptance-production-state.json"
    local file=io.open(path,"wb")
    if not file then return false end
    local ok=pcall(function()
      assert(file:write(json.encode({phase=phase,case=case_name,created=result.created,
        regenerated=result.regenerated,status=result.status})))
    end)
    local closed=pcall(function() file:close() end)
    return ok and closed
  end
  local function phrase_value(instrument_index,slot)
    local phrase=song.instruments[instrument_index].phrases[slot]
    assert(phrase,"persisted phrase missing")
    local id=ownership.id(phrase)
    local source,policy,pb
    if id then source,policy,pb=store.read_entry(song,id) end
    return canonical_baseline({snapshot=assert(ownership.snapshot(phrase)),source=source,
      output_policy=policy,pb_range=pb,id=id})
  end
  local function signature(raw)
    local value=0
    for index=1,#raw do value=(value*131+raw:byte(index))%4294967296 end
    return tostring(#raw)..":"..string.format("%08x",value)
  end
  local function save_session(callback)
    local manifest={case=case_name,targets=json.array(),phrases=json.array(),tool_data=song.tool_data}
    for _,target in ipairs(targets) do
      manifest.targets[#manifest.targets+1]={instrument_index=target.instrument_index,slot=target.slot,
        source=json.encode(source_value(target.source,true,json)),policy=target.policy,pb=target.pb}
    end
    local index,slot=1,1
    record_state("saving")
    local function collect_next()
      if index>config.instruments then
        local raw=json.encode(manifest)
        local file=assert(io.open(baseline_path,"wb"))
        assert(file:write(raw))
        assert(file:close())
        result.saved_baseline=signature(raw)
        result.roundtrip_fixture=fixture_name
        assert(save_independent_fixture(song,fixture_name))
        record_state("saved")
        callback()
        return
      end
      manifest.phrases[index]=manifest.phrases[index] or json.array()
      manifest.phrases[index][slot]=phrase_value(index,slot)
      slot=slot+1
      if slot>#song.instruments[index].phrases then index=index+1;slot=1 end
      later(collect_next)
    end
    later(collect_next)
  end
  local function finish(status,reason)
    if settled then return end
    settled=true
    record_state("closing")
    prepared_production_session=nil
    renoise.ViewBuilder,renoise.app=original_builder,original_app
    context_module.new=original_context_new
    if dialog then pcall(function() dialog:close() end) end
    if context then pcall(function() context:release_document() end) end
    pcall(function() song.transport:stop() end)
    if midi_input then pcall(function() midi_input:close() end) end
    result.status,result.reason=status,reason
    record_state("reporting")
    done(result)
    record_state("reported")
  end
  local function checked(action)
    if settled then return end
    local ok,err=pcall(action)
    if not ok then finish("FAIL",tostring(err)) end
  end
  later=function(action) after_delivery_idle(function() checked(action) end) end
  local function invoke(id,value)
    local view,callback=assert(controls[id],"missing control: "..id),assert(callbacks[id],"missing callback: "..id)
    assert(view.active~=false,"inactive control: "..id.."; length="..
      tostring(controls.last_step and controls.last_step.value))
    local before=native_selection(song)
    expected_native_selection=expected_native_selection or before
    assert(same_native_selection(expected_native_selection,before),
      "native selection changed between GUI actions; disposable session requires exclusive input")
    if value~=nil then
      suppress=true
      view.value=value
      suppress=false
    end
    local started,wall=os.clock(),os.time()
    callback(value)
    result.action_count=(result.action_count or 0)+1
    local elapsed=(os.clock()-started)*1000
    result.maximum_callback_ms=math.max(result.maximum_callback_ms or 0,elapsed)
    trace[#trace+1]={control=id,cpu_ms=elapsed,
      wall_seconds=os.difftime(os.time(),wall),ordinal=result.action_count,
      value=value,length=controls.last_step and controls.last_step.value,
      instrument=controls.instrument and controls.instrument.value,
      phrase=controls.phrase and controls.phrase.value,
      target_kind=context:target_projection().kind}
    if #trace>512 then table.remove(trace,1) end
    assert(same_native_selection(before,native_selection(song)),"GUI action changed native selection: "..id)
    assert(not context:integrity_state().blocked,"runtime integrity blocked after "..id)
  end
  local function alias(kind,p)
    if p.id then return p.id end
    if kind=="valuebox" then return "last_step" end
    if kind=="popup" then
      if p.width==290 then return "instrument" end
      if p.width==360 then return "phrase" end
      if p.items and #p.items==32 and p.items[1]=="1" then return "pitch_span" end
      if p.items and p.items[1]=="Play Once" then return "policy" end
    end
    if kind=="button" and p.text=="Generate / Regenerate ACID Phrase" then return "generate" end
    if kind=="button" then
      for index,key_name in ipairs({"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}) do
        if p.text==key_name then return "acid_grid_key_button_"..index end
      end
      if p.text=="NOTE" then return "acid_time_command_note" end
      if p.text=="TIE" then return "acid_time_command_tie" end
      if p.text=="REST" then return "acid_time_command_rest" end
    end
  end
  local function select_position(kind,index)
    local page=math.floor((index-1)/16)+1
    local cell=(index-1)%16+1
    invoke(kind=="pitch" and ("acid_pitch_page_"..page) or ("acid_time_page_"..page))
    invoke(string.format(kind=="pitch" and "acid_grid_pitch_%02d" or
      "acid_grid_select_time_%02d",cell))
    local selector_id=string.format(kind=="pitch" and "acid_grid_pitch_%02d" or
      "acid_grid_select_time_%02d",cell)
    local page_id=(kind=="pitch" and "acid_pitch_page_" or "acid_time_page_")..page
    assert(controls[selector_id] and controls[page_id] and selected_color and
      tostring(controls[page_id].text):find("[*]",1,true) and
      same_native_color(controls[selector_id].color,selected_color),
      "GUI "..kind.." selection is not highlighted with its page")
  end
  local function capture(id,callback)
    callbacks[id]=callback
    return function(...) if not suppress then return callback(...) end end
  end
  local function open_gui()
    context_module.new=function(...)
      assert(context==nil,"production journey opened multiple runtime contexts")
      context=original_context_new(...)
      result.native_changes=json.array()
      local notify=context.notify_native_change
      context.notify_native_change=function(owner,kind,subject,...)
        local events=result.native_changes
        events[#events+1]={kind=kind,action=result.action_count or 0,
          undo=song:is_undo_redoing(),instrument=song.selected_instrument_index,
          phrase=song.selected_phrase_index}
        if #events>64 then table.remove(events,1) end
        return notify(owner,kind,subject,...)
      end
      return context
    end
    renoise.ViewBuilder=function(...)
      local builder=original_builder(...)
      return setmetatable({},{__index=function(_,kind)
        local constructor=builder[kind]
        if type(constructor)~="function" then return constructor end
        return function(_,p,...)
          local id=type(p)=="table" and alias(kind,p)
          if id and p.notifier then p.notifier=capture(id,p.notifier) end
          local view=constructor(builder,p,...)
          if id then
            controls[id]=view
            local add
            if kind=="popup" or kind=="checkbox" or kind=="valuebox" then add=view.add_notifier end
            if type(add)=="function" then
              view.add_notifier=function(_,callback) return add(view,capture(id,callback)) end
            end
          end
          return view
        end
      end})
    end
    renoise.app=function(...)
      local app=original_app(...)
      return setmetatable({},{__index=function(_,key)
        local member=app[key]
        if key=="show_custom_dialog" then
          return function(_,title,view,handler,settings)
            dialog=member(app,title,view,function(window,event)
              if key_handler then return key_handler(window,event) end
              if handler then return handler(window,event) end
              return event
            end,settings)
            return dialog
          end
        end
        if type(member)=="function" then return function(_,...) return member(app,...) end end
        return member
      end})
    end
    local ok,err=pcall(function() require("gui").show() end)
    renoise.ViewBuilder,renoise.app=original_builder,original_app
    context_module.new=original_context_new
    assert(ok,err)
    assert(context and dialog and dialog.visible,"production GUI capture failed")
    selected_color=controls.acid_program_pitch_page_1.color
    invoke("acid_editor_view",2)
    assert(controls.acid_grid_panel.visible==true,"production GUI did not enter Grid view")
  end
  local function select_target(target)
    local raw=song.tool_data
    invoke("instrument",target.instrument_index)
    invoke("phrase",target.slot)
    local projection=context:target_projection()
    assert(projection.kind=="owned" and rawequal(projection.phrase,target.phrase),
      "GUI did not bind the owned destination")
    assert(song.tool_data==raw,"navigation wrote persisted source state")
    local source,policy,pb=store.read_entry(song,ownership.id(target.phrase))
    assert(sequence.same_source(source,target.source) and policy==target.policy and pb==target.pb,
      "committed source belongs to another target")
  end
  local function verify(target)
    assert(rawequal(song.instruments[target.instrument_index].phrases[target.slot],target.phrase),
      "destination membership changed")
    local id=assert(ownership.id(target.phrase),"destination lost ownership")
    local source,policy,pb=store.read_entry(song,id)
    assert(sequence.same_source(source,target.source) and policy==target.policy and pb==target.pb,
      "source/settings mismatch")
    local expected_lines=target.policy=="repeat" and target.source.length*8+1 or target.source.length*4
    assert(target.phrase.number_of_lines==expected_lines,"native phrase length mismatch")
    assert(target.phrase.lpb==(target.source.timing_mode=="triplet" and 12 or 16),"native timing mismatch")
    assert(target.phrase.looping==(target.policy=="repeat"),"native loop policy mismatch")
    if target.policy=="repeat" then
      assert(target.phrase.loop_start==target.source.length*4+1 and
        target.phrase.loop_end==target.source.length*8+1,"native loop boundaries mismatch")
    end
    assert(target.phrase:line(1):note_column(1).note_value==target.source.pitch_events[1].note,
      "native first note mismatch")
    assert(target.phrase:line(1):note_column(1).volume_value==
      (target.source.pitch_events[1].accent and 255 or 89),"native first-note accent mismatch")
    local function release_at(line)
      for column=1,target.phrase.visible_note_columns do
        if target.phrase:line(line):note_column(column).note_value==120 then return true end
      end
      return false
    end
    local active=false
    for step=1,target.source.length do
      local command=target.source.time_events[step]
      if command=="N" then active=true
      elseif command=="R" then
        if active then assert(release_at((step-1)*4+1),"native REST release mismatch") end
        active=false
      end
    end
    if target.policy=="play_once" and active then
      assert(release_at(target.source.length*4-1),"native final one-shot release mismatch")
    end
    local sample=target.instrument_index<=config.samples
    local plugin=not sample and target.instrument_index<=config.samples+config.plugins
    local output=assert(require("model.output_planner").plan(target.source,target.policy,target.pb,
      {max_lines=512,max_note_columns=12,max_effect_columns=8,
        play_pattern=renoise.InstrumentPhrase.PLAY_PATTERN,
        key_tracking_none=renoise.InstrumentPhrase.KEY_TRACKING_NONE},
      {sample=sample,plugin=plugin,midi=not sample and not plugin,alias=false},
      {pitch_bend_delivery=true}))
    local matches,reason=production_output_matches(assert(ownership.snapshot(target.phrase)),output.expected)
    assert(matches,"source-planned native output mismatch: "..tostring(reason))
    target.id=id
  end
  local function checkpoint(callback)
    local owned_index,foreign_index=1,1
    record_state("verifying")
    local function next_phrase()
      local target=targets[owned_index]
      if target then
        verify(target)
        if target.native_value then
          assert(canonical_baseline(assert(ownership.snapshot(target.phrase)))==target.native_value,
            "unrelated native phrase changed")
        end
        owned_index=owned_index+1
      else
        local sentinel=foreign[foreign_index]
        if not sentinel then callback();return end
        assert(ownership.id(sentinel.phrase)==nil,"foreign phrase became owned")
        local matches,reason=ownership.matches_snapshot(sentinel.phrase,sentinel.snapshot,nil,sentinel.index)
        assert(matches,reason or "foreign phrase changed")
        foreign_index=foreign_index+1
      end
      later(next_phrase)
    end
    later(next_phrase)
  end
  local lengths={1,2,7,15,16,17,31,32}
  local spans={1,3,5,4,16,8,13,32}
  local function configure(instrument_index,slot,callback)
    local source=sequence.new_pattern(32)
    invoke("acid_live_edit",false)
    invoke("last_step",32)
    invoke("pitch_span",32)
    local step=0
    local function configure_next()
      step=step+1
      if step>32 then
        source.length,source.pitch_length=lengths[slot],spans[slot]
        source.timing_mode=(instrument_index+slot)%2==0 and "straight" or "triplet"
        local policy=slot%2==0 and "repeat" or "play_once"
        invoke("last_step",source.length)
        invoke("pitch_span",source.pitch_length)
        invoke("acid_timing",source.timing_mode=="straight" and 1 or 2)
        invoke("policy",policy=="repeat" and 2 or 1)
        local pb=instrument_index>config.samples and ({0,2,12,24,48,0,2,12})[slot] or 0
        invoke("acid_pb_range",({[0]=1,[2]=2,[12]=3,[24]=4,[48]=5})[pb])
        callback(source,policy,pb)
        return
      end
      local key=(instrument_index+slot+step)%12
      local octave=slot==3 and step<=2 and 0 or (instrument_index+slot+step)%3-1
      local command=step<=2 and "N" or ({"N","T","R"})[(step+slot)%3+1]
      select_position("pitch",step)
      invoke(string.format("acid_grid_key_button_%02d",key+1))
      invoke("acid_grid_octave_"..(octave==-1 and "down" or octave==0 and "normal" or "up"))
       invoke("acid_grid_accent",step%3==0)
       invoke("acid_grid_slide",step==1 or step%4==0)
      select_position("time",step)
      invoke(command=="N" and "acid_time_command_note" or
        command=="T" and "acid_time_command_tie" or "acid_time_command_rest")
      source.pitch_events[step]=sequence.new_pitch(key,octave,step%3==0,step==1 or step%4==0)
      source.time_events[step]=command
      later(configure_next)
    end
    later(configure_next)
  end
  local function start_playback()
    while song.sequencer_track_count<config.instruments do
      song:insert_track_at(song.sequencer_track_count+1)
    end
    local pattern=song.patterns[song.sequencer.pattern_sequence[1]]
    pattern.number_of_lines=512
    for index=1,config.instruments do
      local instrument=song.instruments[index]
      instrument.phrase_playback_mode=renoise.Instrument.PHRASES_PLAY_SELECTIVE
      instrument.phrase_program=8
      local column=pattern.tracks[index]:line(1):note_column(1)
      column.note_value,column.instrument_value=48,index-1
      pattern.tracks[index]:line(509):note_column(1).note_value=120
    end
    local counts={note=0,off=0,bend=0}
    result.midi_events=json.array()
    result.midi_counts=counts
    midi_input=renoise.Midi.create_input_device(options.midi_output_device,function(message)
      local channel=message[1]%16+1
      if channel<=config.samples+config.plugins or channel>config.instruments then return end
      local kind=math.floor(message[1]/16)
      if kind==9 and message[3]>0 then counts.note=counts.note+1
      elseif kind==8 or (kind==9 and message[3]==0) then counts.off=counts.off+1
      elseif kind==14 then counts.bend=counts.bend+1 end
      if #result.midi_events<256 then
        result.midi_events[#result.midi_events+1]={status=message[1],data1=message[2],data2=message[3]}
      end
    end)
    song.transport:start(renoise.Transport.PLAYMODE_RESTART_PATTERN)
    assert(song.transport.playing,"multitrack transport did not start")
    result.playing_tracks=config.instruments
    expected_native_selection=nil
  end
  local function prepare_native_undo()
    local action_index=1
    local action_target,before,after,before_source,after_source,action_error,action_started
    local function await_editor(expected,callback)
      local deadline=os.time()+UNDO_ACTION_WAIT_TIMEOUT_SECONDS
      local stable=0
      local function poll()
        local state=context:editor_state()
        stable=state and sequence.same_source(state.source,expected) and stable+1 or 0
        if stable>=2 then callback();return end
        if os.time()>=deadline then
          result.undo_expected_source=canonical_baseline(expected)
          result.undo_actual_source=state and canonical_baseline(state.source) or "pending"
          result.gui_state=require("gui").get_ui_state()
          result.selected_instrument_index=song.selected_instrument_index
          result.selected_phrase_index=song.selected_phrase_index
          error("GUI source did not follow native Undo/Redo",0)
        end
        later(poll)
      end
      later(poll)
    end
    local function arm_action()
      action_target=targets[action_index==1 and 1 or #targets]
      select_target(action_target)
      invoke("acid_live_edit",false)
      select_position("pitch",1)
      before=assert(ownership.snapshot(action_target.phrase))
      before_source=sequence.copy_source(action_target.source)
      action_started=false
      result.action_ready=true
      result.action_mode=action_index==1 and "manual" or "live"
      result.status="PASS"
      done(result)
    end
    key_handler=function(_,event)
      if (event.name=="enter" or event.name=="return") and event.state~="released" then
        if action_started then return nil end
        action_started=true
        local ok,err=pcall(function()
          local key=(action_target.source.pitch_events[1].key+1)%12
          if action_index==2 then invoke("acid_live_edit",true) end
          invoke(string.format("acid_grid_key_button_%02d",key+1))
          if action_index==1 then invoke("generate") end
          after_source=sequence.copy_source(before_source)
          local pitch=after_source.pitch_events[1]
          after_source.pitch_events[1]=sequence.new_pitch(key,pitch.octave,pitch.accent,pitch.slide)
          action_target.source=after_source
          verify(action_target)
          after=assert(ownership.snapshot(action_target.phrase))
          action_target.native_value=canonical_baseline(after)
        end)
        if not ok then action_error=tostring(err) end
        return nil
      end
      return event
    end
    prepared_production_session={case=case_name,resume=function(callback)
      done=callback
      checked(function()
        assert(action_started,"guarded Enter did not dispatch the production action")
        assert(not action_error,action_error)
        invoke("acid_live_edit",false)
        song:undo()
        after_delivery_idle(function() checked(function()
          assert(ownership.compare(before,assert(ownership.snapshot(action_target.phrase))),
            "native Undo did not restore phrase cells/name")
          local source,policy,pb=store.read_entry(song,ownership.id(action_target.phrase))
          assert(sequence.same_source(source,before_source) and policy==action_target.policy and pb==action_target.pb,
            "native Undo restored an incoherent source/settings revision")
          await_editor(before_source,function()
            song:redo()
            after_delivery_idle(function() checked(function()
              assert(ownership.compare(after,assert(ownership.snapshot(action_target.phrase))),
                "native Redo did not restore phrase cells/name")
              verify(action_target)
              await_editor(after_source,function()
                checkpoint(function()
                if action_index==1 then
                  action_index=2
                  arm_action()
                else
                  result.phases.native_undo="PASS"
                  result.action_ready=false
                  save_session(function() finish("PASS") end)
                end
                end)
              end)
            end) end)
          end)
        end) end)
      end)
    end}
    arm_action()
  end
  local function run_edits()
    local ordinal=0
    local function finish_edits()
      checkpoint(function()
        result.observer_final=require("gui").get_ui_state()
        assert(result.observer_final.native_listener_count==result.observer_baseline.native_listener_count,
          "native listener count grew during regeneration")
        result.phases.edits="PASS"
        prepare_native_undo()
      end)
    end
    local function boundary_edit(cursor)
      local value=({16,17,32})[cursor]
      if not value then finish_edits();return end
      local target=targets[8]
      select_target(target)
      invoke("acid_live_edit",false)
      local old_id=target.id
      invoke("last_step",value)
      invoke("pitch_span",value)
      invoke("generate")
      local timing=trace[#trace]
      result.edits[#result.edits+1]={ordinal=#result.edits+1,instrument_index=target.instrument_index,
        phrase_index=target.slot,mode="boundary",cpu_ms=timing.cpu_ms,wall_seconds=timing.wall_seconds}
      target.source.length,target.source.pitch_length=value,value
      later(function()
        verify(target)
        assert(target.id~=old_id,"boundary regeneration did not create a source revision")
        target.native_value=canonical_baseline(assert(ownership.snapshot(target.phrase)))
        result.regenerated=result.regenerated+1
        result.boundary_regenerated=cursor
        later(function() boundary_edit(cursor+1) end)
      end)
    end
    local function edit_next()
      ordinal=ordinal+1
      if ordinal>#targets*config.rounds then
        boundary_edit(1)
        return
      end
      local cursor=(ordinal-1)%#targets
      local base_count=config.instruments*8
      local position=cursor==base_count and #targets or
        ((cursor%config.instruments*3)%config.instruments)*8+math.floor(cursor/config.instruments)+1
      local target=targets[position]
      select_target(target)
      local key=(target.source.pitch_events[1].key+1)%12
      local before_id=target.id
      local before_source=sequence.copy_source(target.source)
      local before_policy,before_pb=target.policy,target.pb
      local round=math.floor((ordinal-1)/#targets)
      local live=round%2==1
      local final_round=round==config.rounds-1
      local slot=target.profile_slot
      local length=final_round and lengths[slot] or ({16,17,32})[round+1]
      local span=final_round and spans[slot] or ({17,16,32})[round+1]
      local timing_mode=(target.instrument_index+slot)%2==0 and "straight" or "triplet"
      local policy=slot%2==0 and "repeat" or "play_once"
      if not final_round and round%2==0 then
        timing_mode=timing_mode=="straight" and "triplet" or "straight"
        policy=policy=="repeat" and "play_once" or "repeat"
      end
      local octave=slot==3 and 0 or (target.instrument_index+slot+1)%3-1
      if not final_round then octave=(target.instrument_index+round)%3-1 end
      local accent=not final_round and round%2==0
      local slide=final_round or round%2==1
      local command=final_round and "N" or (round%2==0 and "R" or "T")
      invoke("acid_live_edit",false)
      invoke("last_step",32)
      select_position("pitch",1)
      invoke("acid_grid_octave_"..(octave==-1 and "down" or octave==0 and "normal" or "up"))
      invoke("acid_grid_accent",accent)
      invoke("acid_grid_slide",slide)
      select_position("time",2)
      invoke(command=="N" and "acid_time_command_note" or
        command=="T" and "acid_time_command_tie" or "acid_time_command_rest")
      invoke("last_step",length)
      invoke("pitch_span",span)
      invoke("acid_timing",timing_mode=="straight" and 1 or 2)
      invoke("policy",policy=="repeat" and 2 or 1)
      assert(ownership.id(target.phrase)==before_id,"unarmed settings edit regenerated the phrase")
      select_position("pitch",1)
      invoke("acid_live_edit",live)
      invoke(string.format("acid_grid_key_button_%02d",key+1))
      if not live then invoke("generate") end
      local timing=trace[#trace]
      result.edits[#result.edits+1]={ordinal=ordinal,instrument_index=target.instrument_index,
        phrase_index=target.slot,mode=live and "live" or "manual",cpu_ms=timing.cpu_ms,
        wall_seconds=timing.wall_seconds}
      target.source.length,target.source.pitch_length=length,span
      target.source.timing_mode=timing_mode
      target.source.time_events[2]=command
      target.source.pitch_events[1]=sequence.new_pitch(key,octave,accent,slide)
      target.policy=policy
      later(function()
        verify(target)
        assert(target.id~=before_id,"regeneration did not commit a new immutable revision")
        local retained,retained_policy,retained_pb=store.read_entry(song,before_id)
        assert(sequence.same_source(retained,before_source) and retained_policy==before_policy and retained_pb==before_pb,
          "regeneration changed or removed the previous immutable source revision")
        target.native_value=canonical_baseline(assert(ownership.snapshot(target.phrase)))
        for _,offset in ipairs({1,math.floor(#targets/2)}) do
          local peer=targets[(position+offset-1)%#targets+1]
          assert(canonical_baseline(assert(ownership.snapshot(peer.phrase)))==peer.native_value,
            "regeneration changed an unrelated phrase")
          local source,policy,pb=store.read_entry(song,ownership.id(peer.phrase))
          assert(sequence.same_source(source,peer.source) and policy==peer.policy and pb==peer.pb,
            "regeneration changed an unrelated source/settings revision")
        end
        invoke("acid_live_edit",false)
        result.regenerated=result.regenerated+1
        if ordinal==1 then result.observer_baseline=require("gui").get_ui_state() end
        if ordinal%16==0 then checkpoint(function() later(edit_next) end)
        else later(edit_next) end
      end)
    end
    later(edit_next)
  end
  local function verify_dirty_navigation()
    local target=targets[1]
    select_target(target)
    invoke("acid_live_edit",false)
    select_position("pitch",1)
    local old_id=target.id
    local key=(target.source.pitch_events[1].key+2)%12
    invoke(string.format("acid_grid_key_button_%02d",key+1))
    local expected=sequence.copy_source(target.source)
    expected.pitch_events[1]=sequence.new_pitch(key,expected.pitch_events[1].octave,
      expected.pitch_events[1].accent,expected.pitch_events[1].slide)
    select_target(targets[9])
    select_target(targets[17])
    select_target(target)
    local draft,policy,pb=store.read_draft(song,song.instruments[1],target.phrase)
    assert(sequence.same_source(draft,expected) and policy==target.policy and pb==target.pb,
      "dirty draft lost across instrument switches")
    assert(ownership.id(target.phrase)==old_id,"unarmed draft navigation regenerated a phrase")
    invoke(string.format("acid_grid_key_button_%02d",target.source.pitch_events[1].key+1))
    result.phases.drafts="PASS"
  end
  local function seed()
    local ordinal=0
    local additional_created=false
    local function create_next()
      ordinal=ordinal+1
      if ordinal>config.instruments*8 then
        if not additional_created then
          additional_created=true
          invoke("instrument",1)
          invoke("phrase",#controls.phrase.items)
          configure(1,1,function(source,policy,pb)
          local instrument=song.instruments[1]
          local count=#instrument.phrases
          invoke("generate")
          later(function()
            assert(#instrument.phrases==count+1,"additional explicit Create did not append one phrase")
            local target={instrument_index=1,slot=count+1,profile_slot=1,phrase=instrument.phrases[count+1],
              source=source,policy=policy,pb=pb}
            verify(target)
            assert(target.id~=targets[1].id and not rawequal(target.phrase,targets[1].phrase),
              "equal-content Create reused an existing identity")
            target.native_value=canonical_baseline(assert(ownership.snapshot(target.phrase)))
            targets[#targets+1]=target
            result.explicit_created=1
            later(create_next)
          end)
          end)
          return
        end
        checkpoint(function()
          result.phases.seed="PASS"
          result.owned_phrase_count=#targets
          result.foreign_phrase_count=#foreign
          result.song_instrument_count=#song.instruments
          verify_dirty_navigation()
          start_playback()
          run_edits()
        end)
        return
      end
      local index=math.floor((ordinal-1)/8)+1
      local slot=(ordinal-1)%8+1
      invoke("instrument",index)
      invoke("phrase",#controls.phrase.items)
      configure(index,slot,function(source,policy,pb)
      local instrument=song.instruments[index]
      local before=#instrument.phrases
      invoke("generate")
      later(function()
        assert(#instrument.phrases==before+1,"Create did not append exactly one phrase")
        local target={instrument_index=index,slot=slot,profile_slot=slot,phrase=instrument.phrases[#instrument.phrases],
          source=source,policy=policy,pb=pb}
        verify(target)
        target.native_value=canonical_baseline(assert(ownership.snapshot(target.phrase)))
        targets[#targets+1]=target
        result.created=result.created+1
        if slot==8 then
          local phrase=instrument:insert_phrase_at(#instrument.phrases+1)
          phrase.name="Production foreign "..index
          phrase.number_of_lines=64
          phrase:line(1):note_column(1).note_value=37
          phrase:line(1):note_column(1).volume_value=101
          phrase:line(1):effect_column(1).number_string="0A"
          phrase:line(1):effect_column(1).amount_value=7
          phrase:line(64):note_column(2).note_value=53
          phrase:set_column_name(2,"Foreign memory")
          phrase:set_column_is_muted(2,true)
          phrase.number_of_lines=16
          local snapshot=assert(ownership.snapshot(phrase))
          foreign[#foreign+1]={phrase=phrase,snapshot=snapshot,index=assert(ownership.snapshot_index(snapshot))}
        end
        later(create_next)
      end)
      end)
    end
    later(create_next)
  end
  checked(function()
    options=options or {}
    if options.stage=="cold-regenerate" or options.stage=="cold-verify" then
      local file=assert(io.open(baseline_path,"rb"))
      local raw=file:read("*a")
      file:close()
      local manifest=assert(json.decode(raw))
      assert(manifest.case==case_name,"cold baseline belongs to another scale")
      assert(song.tool_data==manifest.tool_data,"persisted source/drafts changed on cold load")
      result.reopened_baseline=signature(raw)
      local function finish_cold()
        result.phases.cold_reopen="PASS"
        finish("PASS")
      end
      local function regenerate_cold()
        local positions={1,config.samples*8+1,config.instruments*8}
        local cursor=0
        local function next_target()
          cursor=cursor+1
          local position=positions[cursor]
          if not position then save_session(finish_cold);return end
          local target=targets[position]
          select_target(target)
          select_position("pitch",1)
          local pitch=target.source.pitch_events[1]
          local key=(pitch.key+1)%12
          invoke(string.format("acid_grid_key_button_%02d",key+1))
          invoke("generate")
          target.source.pitch_events[1]=sequence.new_pitch(key,pitch.octave,pitch.accent,pitch.slide)
          verify(target)
          result.regenerated=result.regenerated+1
          later(next_target)
        end
        later(next_target)
      end
      local function navigate_cold()
        open_gui()
        local cursor=0
        local function next_target()
          cursor=cursor+1
          local target=targets[cursor]
          if target then select_target(target);later(next_target);return end
          assert(song.tool_data==manifest.tool_data,"cold GUI navigation wrote persisted state")
          if options.stage=="cold-regenerate" then regenerate_cold()
          else finish_cold() end
        end
        later(next_target)
      end
      local function restore_targets()
        local cursor=0
        local function next_target()
          cursor=cursor+1
          local value=manifest.targets[cursor]
          if not value then navigate_cold();return end
          value.source=source_value(assert(json.decode(value.source)),false)
          value.phrase=song.instruments[value.instrument_index].phrases[value.slot]
          targets[#targets+1]=value
          verify(value)
          later(next_target)
        end
        later(next_target)
      end
      local index,slot=1,1
      local function verify_next()
        local values=manifest.phrases[index]
        if not values then restore_targets();return end
        assert(#song.instruments[index].phrases==#values,"cold phrase inventory changed")
        assert(phrase_value(index,slot)==values[slot],"cold native/source association mismatch")
        slot=slot+1
        if slot>#values then index=index+1;slot=1 end
        later(verify_next)
      end
      record_state("cold-verifying")
      later(verify_next)
      return
    end
    for _,instrument in ipairs(song.instruments) do assert(#instrument.phrases==0,"requires empty disposable song") end
    local device=options.midi_output_device
    assert(type(device)=="string" and device~="","explicit MIDI output device required")
    local available=false
    for _,name in ipairs(renoise.Midi.available_output_devices()) do if name==device then available=true end end
    assert(available,"MIDI output unavailable: "..device)
    while #song.instruments<config.instruments do song:insert_instrument_at(#song.instruments+1) end
    local plugin
    for _,info in ipairs(song.instruments[1].plugin_properties.available_plugin_infos) do
      if info.name:lower():find("surge xt",1,true) then plugin=info;break end
    end
    assert(plugin,"Surge XT unavailable")
    result.vst_plugin=plugin.name
    result.midi_output_device=device
    result.receiver_counts={sample=config.samples,vst=config.plugins,
      midi=config.instruments-config.samples-config.plugins}
    for index=1,config.instruments do
      local instrument=song.instruments[index]
      if index<=config.samples then assert(create_acceptance_sample(instrument,"Production "..index))
      elseif index<=config.samples+config.plugins then
        assert(instrument.plugin_properties:load_plugin(plugin.path),"VST load failed")
        assert(instrument.plugin_properties.plugin_loaded,"VST not loaded")
      else
        instrument.midi_output_properties.device_name=device
        instrument.midi_output_properties.channel=index
      end
      instrument.name=string.format("Production receiver %02d",index)
    end
    open_gui()
    seed()
  end)
  return true
end

local playback_state
local function run_production_playback(done,case_name,options,json)
  local song=renoise.song()
  local config=PRODUCTION_SESSION_CASES[case_name]
  local stage=options.stage
  local result={case=case_name,stage=stage,tracks=config.instruments}
  local ok,err=pcall(function()
    if stage=="playback-stop" then
      song.transport:stop()
      if playback_state then
        for index,state in ipairs(playback_state.mutes) do song.tracks[index].mute_state=state end
        for index,program in ipairs(playback_state.programs) do song.instruments[index].phrase_program=program end
        if playback_state.input then playback_state.input:close() end
        result.midi_counts=playback_state.counts
        result.midi_events=playback_state.events
        result.receiver_proofs=playback_state.proofs
      end
      playback_state=nil
      return
    end
    assert(song.sequencer_track_count>=config.instruments,"production playback tracks are missing")
    playback_state=playback_state or {mutes={},programs={},channels={},proofs=json.array(),
      counts={note=0,off=0,bend=0},events=json.array()}
    for index=1,config.instruments do
      local instrument=song.instruments[index]
      assert(instrument.phrases[8] and require("renoise.phrase_ownership").id(instrument.phrases[8]),
        "production playback phrase is missing")
      local kind=index<=config.samples and "sample" or
        (index<=config.samples+config.plugins and "vst" or "midi")
      if kind=="vst" then assert(instrument.plugin_properties.plugin_loaded,"production VST is not loaded") end
      playback_state.mutes[index]=playback_state.mutes[index] or song.tracks[index].mute_state
      playback_state.programs[index]=playback_state.programs[index] or instrument.phrase_program
      local audible=stage=="playback-all" or stage=="playback-"..kind
      song.tracks[index].mute_state=audible and renoise.Track.MUTE_STATE_ACTIVE or renoise.Track.MUTE_STATE_MUTED
      if stage=="playback-midi" and kind=="midi" then
        instrument.phrase_program=3
        local id=assert(require("renoise.phrase_ownership").id(instrument.phrases[3]))
        local source,policy,pb=require("renoise.pattern_store").read_entry(song,id)
        assert(source and policy=="play_once" and pb>0 and source.pitch_events[1].slide,
          "MIDI playback requires a committed one-shot bend fixture")
        local delta=source.pitch_events[2].note-source.pitch_events[1].note
        assert(delta~=0 and math.abs(delta)<=pb,"MIDI fixture has no in-range pitch transition")
        local value=math.floor(8192+delta/pb*(delta<0 and 8192 or 8191)+0.5)
        local proof={channel=index,expected_note=source.pitch_events[1].note,expected_bend=value,
          note=false,off=false,center=false,bend=false}
        playback_state.channels[index]=proof
        playback_state.proofs[#playback_state.proofs+1]=proof
      end
    end
    if stage=="playback-midi" then
      local capture=playback_state
      capture.input=renoise.Midi.create_input_device(options.midi_output_device,function(message)
        local proof=capture.channels[message[1]%16+1]
        if not proof then return end
        local kind=math.floor(message[1]/16)
        if kind==9 and message[3]>0 then
          capture.counts.note=capture.counts.note+1
          if message[2]==proof.expected_note then proof.note=true end
        elseif kind==8 or (kind==9 and message[3]==0) then
          capture.counts.off=capture.counts.off+1
          if message[2]==proof.expected_note then proof.off=true end
        elseif kind==14 then
          capture.counts.bend=capture.counts.bend+1
          local value=message[2]+message[3]*128
          if value==8192 then proof.center=true end
          if proof.center and value==proof.expected_bend then proof.bend=true end
        end
        if #capture.events<256 then
          capture.events[#capture.events+1]={status=message[1],data1=message[2],data2=message[3]}
        end
      end)
    end
    song.transport:start(renoise.Transport.PLAYMODE_RESTART_PATTERN)
    assert(song.transport.playing,"production transport did not start")
  end)
  after_delivery_idle(function()
    result.status=ok and "PASS" or "FAIL"
    result.reason=not ok and tostring(err) or nil
    result.playing=song.transport.playing
    done(result)
  end)
  return true
end

local function run_phrase_midi_delivery(done,options,json)
  local song=renoise.song()
  local case_name="phrase-midi-delivery"
  local input,settled
  local measurements=json.array()
  local function finish(status,reason)
    if settled then return end
    settled=true
    pcall(function() song.transport:stop() end)
    if input then pcall(function() input:close() end) end
    done({case=case_name,status=status,reason=reason,measurements=measurements})
  end
  local function checked(callback)
    if settled then return end
    local ok,err=pcall(callback)
    if not ok then finish("FAIL",tostring(err)) end
  end
  local function later(callback) after_delivery_idle(function() checked(callback) end) end
  checked(function()
    local device=assert(options and options.midi_output_device,"explicit MIDI device required")
    for _,instrument in ipairs(song.instruments) do assert(#instrument.phrases==0,"requires empty disposable song") end
    local instrument=song.instruments[1]
    instrument.midi_output_properties.device_name=device
    instrument.midi_output_properties.channel=8
    local phrase=instrument:insert_phrase_at(1)
    phrase.playback_mode=renoise.InstrumentPhrase.PLAY_PATTERN
    phrase.number_of_lines=16
    phrase.lpb=16
    phrase.key_tracking=renoise.InstrumentPhrase.KEY_TRACKING_NONE
    phrase.looping=false
    phrase.visible_note_columns=2
    phrase.visible_effect_columns=1
    phrase.instrument_column_visible=true
    phrase.panning_column_visible=true
    phrase:line(1):note_column(1).note_value=48
    phrase:line(13):note_column(1).note_value=120
    for _,item in ipairs({{1,8192},{5,12288},{9,8192}}) do
      local line,value=item[1],item[2]
      phrase:line(line):note_column(2).panning_string="M1"
      local effect=phrase:line(line):effect_column(1)
      effect.number_string=string.format("%02X",math.floor(value/128))
      effect.amount_value=value%128
    end
    instrument.phrase_playback_mode=renoise.Instrument.PHRASES_PLAY_SELECTIVE
    instrument.phrase_program=1
    local pattern=song.patterns[song.sequencer.pattern_sequence[1]]
    pattern.number_of_lines=64
    pattern.tracks[1]:line(1):note_column(1).note_value=48
    pattern.tracks[1]:line(1):note_column(1).instrument_value=0
    local active
    input=renoise.Midi.create_input_device(device,function(message)
      if not active then return end
      local kind=math.floor(message[1]/16)
      if kind==14 then
        active.bends=active.bends+1
        if #active.events<32 then
          active.events[#active.events+1]={status=message[1],low=message[2],high=message[3]}
        end
      elseif kind==9 and message[3]>0 then active.notes=active.notes+1 end
    end)
    local variants={255,0,7}
    local cursor=0
    local function next_variant()
      cursor=cursor+1
      local channel=variants[cursor]
      if channel==nil then
        for _,measurement in ipairs(measurements) do
          assert(measurement.notes>0,"probe did not trigger phrase notes")
          assert(measurement.bends==3,"probe did not deliver its three MIDI bend commands")
          for index,high in ipairs({64,96,64}) do
            local event=measurement.events[index]
            assert(event and event.status==231 and event.low==0 and event.high==high,
              "probe bend value/order/channel mismatch")
          end
        end
        finish("PASS");return
      end
      song.transport:stop()
      for _,line in ipairs({1,5,9}) do phrase:line(line):note_column(2).instrument_value=channel end
      active={carrier=channel,bends=0,notes=0,events=json.array(),
        panning_value=phrase:line(1):note_column(2).panning_value,
        effect_number_value=phrase:line(1):effect_column(1).number_value}
      measurements[#measurements+1]=active
      song.transport:start(renoise.Transport.PLAYMODE_RESTART_PATTERN)
      active.start_line=song.transport.playback_pos.line
      local deadline=os.time()+3
      local function wait_playback()
        if os.time()<deadline then later(wait_playback)
        else active.end_line=song.transport.playback_pos.line;later(next_variant) end
      end
      later(wait_playback)
    end
    later(next_variant)
  end)
  return true
end

local function run_layout_sizing(done)
  local FEEDBACK_PROBE_WIDTH=640
  local FEEDBACK_PROBE_MAX_LINES=8
  local FEEDBACK_PROBE_LINE_HEIGHT=22
  local FEEDBACK_PROBE_EMPTY_SIZE={width=1,height=1}
  local vb=renoise.ViewBuilder()
  local function text(label,width,height)
    return vb:text{text=label,size={width=width or 90,height=height or 20}}
  end
  local function button(label,width)
    return vb:button{text=label,size={width=width or 54,height=24}}
  end
  local function popup(items,width)
    return vb:popup{items=items,value=1,size={width=width or 110,height=24}}
  end
  local function row(...)
    return vb:row{spacing=4,views={...}}
  end
  local function record_size(view)
    local size=view.size
    return {width=size.width or size[1],height=size.height or size[2]}
  end
  local function labels(prefix,first,last)
    local result={}
    for index=first,last do result[#result+1]=button(prefix..string.format("%02d",index),34) end
    return result
  end

  local function action_row(...)
    return row(...)
  end
  local pitch_positions=labels("P",1,16)
  local time_positions=labels("T",1,16)
  local function make_key_controls()
    local keys={}
    for _,name in ipairs({"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}) do
      keys[#keys+1]=button(name,34)
    end
    local first,second={},{}
    for index,key in ipairs(keys) do
      local target=index<=6 and first or second
      target[#target+1]=key
    end
    return vb:column{spacing=3,views={vb:row{spacing=3,views=first},
      vb:row{spacing=3,views=second}}}
  end
  local pitch_page_controls=action_row(button("Previous PITCH",100),text("PITCH page 1 / 2",100),
    button("Next PITCH",92))
  local time_page_controls=action_row(button("Previous TIME",100),text("TIME page 1 / 2",100),
    button("Next TIME",92))
  local function make_pitch_controls()
    return action_row(popup({"Octave 4","Octave 5","Octave 6"},105),
      button("Accent",58),button("Slide",48),button("C+",42),button("Audition",64))
  end
  local program_editor=vb:column{id="sizing_program_editor",spacing=4,views={
    text("PITCH",64),vb:row{spacing=3,views=pitch_positions},pitch_page_controls,
    make_key_controls(),make_pitch_controls(),
    text("TIME",64),vb:row{spacing=3,views=time_positions},time_page_controls,
    action_row(button("Note",48),button("Tie",42),button("Rest",48)),
  }}
  local grid_pitch=labels("G",1,16)
  local grid_time=labels("T",1,16)
  local grid_editor=vb:column{id="sizing_grid_editor",spacing=4,views={
    text("PITCH GRID",100),vb:row{spacing=3,views=grid_pitch},
    make_key_controls(),make_pitch_controls(),
    text("TIME GRID",100),vb:row{spacing=3,views=grid_time},
  }}
  local editor_holder=vb:column{id="sizing_editor_holder",spacing=0,views={program_editor}}
  local feedback=vb:column{id="sizing_feedback",spacing=0}
  local feedback_content=vb:multiline_text{id="sizing_feedback_content",text=table.concat({
    "The latest phrase edits could not be saved.",
    "The previous phrase still has unsaved edits.",
    "This phrase is unavailable for editing.",
    "The scale library could not be loaded.",
    "Audition cleanup could not release the active note.",
    "PITCH position 17 is missing.",
    "Generation was rejected; the song cannot be updated safely.",
    "Some generated notes were approximated."},"\n"),
    size={width=FEEDBACK_PROBE_WIDTH,height=FEEDBACK_PROBE_MAX_LINES*FEEDBACK_PROBE_LINE_HEIGHT}}
  local entry=vb:column{id="sizing_entry",spacing=0}
  local entry_content=action_row(text("PITCH entry 07 / 32",122),button("Back",48),
    button("Enter and advance",118),button("Restart",60),button("Finish",52),button("Cancel",54))
  local parameters=vb:column{id="sizing_parameters",spacing=3}
  local parameter_pitch=action_row(text("Seed",40),vb:valuebox{min=1,max=2147483646,value=1,size={width=90,height=24}},
    text("MIDI range",76),vb:valuebox{min=24,max=60,value=24,size={width=68,height=24}},
    text("to",18),vb:valuebox{min=24,max=60,value=60,size={width=68,height=24}})
  local parameter_time=action_row(text("Seed",40),vb:valuebox{min=1,max=2147483646,value=1,size={width=90,height=24}},
    text("NOTE",40),vb:valuebox{min=0,max=1000,value=2,size={width=58,height=24}},
    text("TIE",30),vb:valuebox{min=0,max=1000,value=1,size={width=58,height=24}},
    text("REST",42),vb:valuebox{min=0,max=1000,value=1,size={width=58,height=24}})
  local parameter_repeat=action_row(text("Last used seed: 1",150),button("Repeat last",84))
  local root=vb:column{id="sizing_root",margin=8,spacing=5,views={
    action_row(text("ACID",70),text("Instrument",68),popup({"Instrument 01"},260)),
    action_row(text("Phrase",52),popup({"Phrase 01"},230),button("Rename",58),button("Duplicate",70),button("Reset",52)),
    action_row(text("Length",52),vb:valuebox{min=1,max=32,value=32,size={width=65,height=24}},
      text("Timing",50),popup({"1/16","1/8","1/4"},75),text("Pitch span",70),
      vb:valuebox{min=1,max=32,value=13,size={width=65,height=24}}),
    action_row(popup({"Program","Grid"},100),button("Undo",48),button("Redo",48),
      popup({"PITCH","TIME","ALL"},90),button("Copy",48),button("Paste",48)),
    editor_holder,
    action_row(text("Entry",52),button("Enter pitches",90),button("Enter timing",90)),
    entry,
    action_row(text("Root",40),popup({"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"},70),
      text("Scale",45),popup({"Major","Minor","Custom"},120),button("Follow",55),
      text("Category",62),popup({"All","Western","World"},100),text("Search",45),
      vb:textfield{text="",size={width=100,height=24}},button("Import",52)),
    action_row(text("Scale mask",72),button("Enable",55),
      button("C",32),button("C#",32),button("D",32),button("D#",32),button("E",32),button("F",32),
      button("F#",32),button("G",32),button("G#",32),button("A",32),button("A#",32),button("B",32)),
    action_row(text("Operations",78),popup({"Shift","Transpose","Reverse","Randomize"},150),
      popup({"PITCH","TIME","ALL"},90),button("Apply",56)),
    parameters,
    action_row(text("OUTPUT",72),popup({"Phrase","Pattern"},110),text("Bend range",76),
      vb:valuebox{min=1,max=96,value=2,size={width=60,height=24}},button("Live Edit",68),button("Generate",72)),
    feedback,
  }}

  local dialog
  local idle=renoise.tool().app_idle_observable
  local phase="empty-program"
  local phase_started=os.clock()
  local metrics={probe="planned-full-layout"}
  local settled=false
  local on_idle
  local function finish(status,reason)
    if settled then return end
    settled=true
    pcall(function() idle:remove_notifier(on_idle) end)
    if dialog then pcall(function() if dialog.visible then dialog:close() end end) end
    done({status=status,case="layout-sizing",reason=reason,metrics=metrics})
  end
  local function attach_maximum()
    feedback_content.size={width=FEEDBACK_PROBE_WIDTH,
      height=FEEDBACK_PROBE_MAX_LINES*FEEDBACK_PROBE_LINE_HEIGHT}
    feedback:add_view(feedback_content)
    entry:add_view(entry_content)
    parameters:add_view(parameter_pitch)
    parameters:add_view(parameter_time)
    parameters:add_view(parameter_repeat)
  end
  local function remove_maximum()
    if #feedback.views>0 then
      feedback_content.size=FEEDBACK_PROBE_EMPTY_SIZE
      feedback:remove_view(feedback_content)
    end
    if #entry.views>0 then entry:remove_view(entry_content) end
    if #parameters.views>0 then
      parameters:remove_view(parameter_pitch)
      parameters:remove_view(parameter_time)
      parameters:remove_view(parameter_repeat)
    end
  end
  local function reset_empty_holder(holder)
    holder.size={width=1,height=1}
  end
  on_idle=function()
    if settled then return end
    if os.clock()-phase_started<1.2 then return end
    phase_started=os.clock()
    if phase=="empty-program" then
      metrics.empty_program_root=record_size(root)
      metrics.empty_feedback=record_size(feedback)
      metrics.empty_entry=record_size(entry)
      metrics.empty_parameters=record_size(parameters)
      metrics.empty_editor_holder=record_size(editor_holder)
      metrics.empty_feedback_members=#feedback.views
      metrics.empty_entry_members=#entry.views
      metrics.empty_parameter_members=#parameters.views
      attach_maximum()
      phase="full-program"
      return
    end
    if phase=="full-program" then
      metrics.full_program_root=record_size(root)
      metrics.full_feedback=record_size(feedback)
      metrics.full_feedback_members=#feedback.views
      metrics.full_entry=record_size(entry)
      metrics.full_entry_members=#entry.views
      metrics.full_parameters=record_size(parameters)
      metrics.full_parameter_members=#parameters.views
      remove_maximum()
      reset_empty_holder(feedback)
      reset_empty_holder(entry)
      reset_empty_holder(parameters)
      phase="empty-program-after"
      return
    end
    if phase=="empty-program-after" then
      metrics.empty_program_after_root=record_size(root)
      metrics.empty_program_after_feedback=record_size(feedback)
      metrics.empty_program_after_entry=record_size(entry)
      metrics.empty_program_after_parameters=record_size(parameters)
      editor_holder:remove_view(program_editor)
      reset_empty_holder(editor_holder)
      editor_holder:add_view(grid_editor)
      phase="empty-grid-first"
      return
    end
    if phase=="empty-grid-first" then
      metrics.empty_grid_root=record_size(root)
      metrics.empty_grid_feedback=record_size(feedback)
      metrics.empty_grid_entry=record_size(entry)
      metrics.empty_grid_parameters=record_size(parameters)
      metrics.empty_grid_editor_holder=record_size(editor_holder)
      metrics.empty_grid_feedback_members=#feedback.views
      metrics.empty_grid_entry_members=#entry.views
      metrics.empty_grid_parameter_members=#parameters.views
      attach_maximum()
      phase="full-grid"
      return
    end
    if phase=="full-grid" then
      metrics.grid_editor=record_size(grid_editor)
      metrics.full_grid_root=record_size(root)
      metrics.full_grid_entry=record_size(entry)
      metrics.full_grid_parameters=record_size(parameters)
      remove_maximum()
      reset_empty_holder(feedback)
      reset_empty_holder(entry)
      reset_empty_holder(parameters)
      phase="empty-grid-after"
      return
    end
    if phase=="empty-grid-after" then
      metrics.empty_grid_after_root=record_size(root)
      metrics.empty_grid_after_feedback=record_size(feedback)
      metrics.empty_grid_after_entry=record_size(entry)
      metrics.empty_grid_after_parameters=record_size(parameters)
      editor_holder:remove_view(grid_editor)
      reset_empty_holder(editor_holder)
      editor_holder:add_view(program_editor)
      attach_maximum()
      metrics.full_again_program_root=record_size(root)
      metrics.full_again_feedback=record_size(feedback)
      metrics.full_again_feedback_members=#feedback.views
      metrics.full_again_entry_members=#entry.views
      metrics.full_again_parameter_members=#parameters.views
      phase="full-again-program"
      return
    end
    if phase=="full-again-program" then
      metrics.feedback_cycle_resized=metrics.full_program_root.height>metrics.empty_program_root.height and
        metrics.empty_program_after_root.height==metrics.empty_program_root.height and
        metrics.empty_grid_after_root.height==metrics.empty_grid_root.height and
        metrics.full_grid_root.height>metrics.empty_grid_root.height and
        metrics.empty_program_after_feedback.height==1 and
        metrics.empty_program_after_entry.height==1 and
        metrics.empty_program_after_parameters.height==1 and
        metrics.empty_grid_feedback.height==1 and metrics.empty_grid_entry.height==1 and
        metrics.empty_grid_parameters.height==1 and metrics.empty_grid_editor_holder.height>1 and
        metrics.empty_grid_after_feedback.height==1 and metrics.empty_grid_after_entry.height==1 and
        metrics.empty_grid_after_parameters.height==1 and
        metrics.full_again_program_root.height==metrics.full_program_root.height
      metrics.membership_cycle_valid=metrics.empty_feedback_members==0 and
        metrics.full_feedback_members==1 and metrics.empty_grid_feedback_members==0 and
        metrics.full_again_feedback_members==1 and metrics.empty_entry_members==0 and
        metrics.full_entry_members==1 and metrics.empty_parameter_members==0 and
        metrics.full_parameter_members==3 and metrics.empty_grid_entry_members==0 and
        metrics.empty_grid_parameter_members==0 and metrics.full_again_entry_members==1 and
        metrics.full_again_parameter_members==3
      if metrics.feedback_cycle_resized and metrics.membership_cycle_valid then
        finish("PASS")
      else
        finish("FAIL","native root sizing or holder membership did not follow the empty/full cycle")
      end
    end
  end
  attach_maximum()
  metrics.opened_at_max_program_root=record_size(root)
  local opened,open_error=pcall(function()
    dialog=renoise.app():show_custom_dialog("ACID planned layout sizing probe",root)
  end)
  if not opened then finish("FAIL",tostring(open_error));return true end
  remove_maximum()
  reset_empty_holder(feedback)
  reset_empty_holder(entry)
  reset_empty_holder(parameters)
  phase="empty-program"
  phase_started=os.clock()
  idle:add_notifier(on_idle)
  return true
end

function M.run(case_name, done, json, profile_mode, options)
  if type(done) ~= "function" then return false, "completion callback is required" end
  if case_name=="metadata-recovery-prepare" or case_name=="metadata-recovery" or case_name=="metadata-recovery-cold" then
    M.metadata_recovery=M.metadata_recovery or dofile(renoise.tool().bundle_path.."/__dev/metadata_recovery_acceptance.lua")
    return M.metadata_recovery.run(case_name,done,{save=save_independent_fixture,baseline=persisted_baseline})
  end
  if case_name=="persistence-failures" then
    return dofile(renoise.tool().bundle_path.."/__dev/persistence_acceptance.lua").failures(done)
  end
  if case_name=="metadata-undo-prepare" or case_name=="metadata-undo" then
    M.metadata_undo=M.metadata_undo or dofile(renoise.tool().bundle_path.."/__dev/metadata_undo_acceptance.lua")
    return M.metadata_undo.run(case_name,done)
  end
  if case_name=="phrase-midi-delivery" then return run_phrase_midi_delivery(done,options,json) end
  if PRODUCTION_SESSION_CASES[case_name] then
    if options and type(options.stage)=="string" and options.stage:match("^playback%-") then
      return run_production_playback(done,case_name,options,json)
    end
    return run_production_session(done,case_name,options,json)
  end
  if PRODUCTION_LATENCY_CASES[case_name] then
    if profile_mode~=nil then
      done({status="ERROR",case=case_name,reason="production latency diagnostics use their fixed Warm functional-only measurement"})
      return true
    end
    return run_production_latency(done,case_name,options,json)
  end
  local resolved_profile,profile_error=resolve_acceptance_profile(case_name,profile_mode)
  if profile_error then
    done({status="ERROR",case=case_name,reason=profile_error})
    return true
  end
  profile_mode=resolved_profile
  if case_name == "ownership-negatives" then return run_ownership_negatives(done) end
  if case_name == "import-donor" then return run_ownership_negatives(done, true) end
  if case_name == "revision-undo-fixture" then return run_revision_undo_fixture(done) end
  if case_name == "revision-live-undo-fixture" then return run_revision_undo_fixture(done, case_name) end
  if case_name == "revision-undo-prepare" then return run_revision_undo_prepare(done) end
  if case_name == "revision-undo" then return run_revision_undo(done) end
  if case_name == "revision-live-undo-prepare" then return run_revision_undo_prepare(done, "live-edit") end
  if case_name == "revision-live-undo" then return run_revision_undo(done, "live-edit") end
  if case_name == "cold-reopen-regenerate" then return run_cold_reopen_regenerate(done) end
  if case_name == "cold-reopen-verify" then return run_cold_reopen_verify(done) end
  if case_name == "writer-recovery" then return run_writer_recovery(done) end
  if case_name == "multi-instrument-workflow" then return run_multi_instrument_workflow(done, json,profile_mode) end
  if case_name == "integrity-observers" then return run_integrity_observers(done) end
  if case_name == "editor-responsiveness" then return run_editor_responsiveness(done,profile_mode) end
  if case_name == "layout-sizing" then return run_layout_sizing(done) end
  if case_name == "selection-feasibility" then return run_selection_feasibility(done, json) end
  if case_name == "direct-output-feasibility" then return run_direct_output_feasibility(done, json) end
  if case_name == "source-undo-feasibility" then
    return run_source_undo_feasibility(done, json)
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
