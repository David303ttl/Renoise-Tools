-- SPDX-License-Identifier: GPL-3.0-only
-- Synchronously materialize an ACID phrase revision and commit its source.
local ownership = require("renoise.phrase_ownership")
local store = require("renoise.pattern_store")
local capabilities_api = require("renoise.target_capabilities")
local sequencer = require("model.sequencer")
local output_planner = require("model.output_planner")
local validator = require("writers.phrase_validator")
local materializer = require("writers.phrase_materializer")
local phrase_pitch_bend = require("writers.phrase_pitch_bend")
local policies = require("model.policies")

local M = {}

local current
local delivering = false
local last_diagnostic
local temporary_phrases = {}
local integrity_errors = setmetatable({}, { __mode = "k" })
local CREATE_UNDO = "ACID: Generate phrase"
local REGENERATE_UNDO = "ACID: Regenerate phrase"

local function positive_integer(value)
  return type(value) == "number" and value == value and value % 1 == 0 and value > 0
end

local function phrase_limits()
  local api = renoise.InstrumentPhrase
  if not api then return nil, "Phrase API is unavailable" end
  local limits = {
    max_lines = api.MAX_NUMBER_OF_LINES,
    max_note_columns = api.MAX_NUMBER_OF_NOTE_COLUMNS,
    max_effect_columns = api.MAX_NUMBER_OF_EFFECT_COLUMNS,
    play_pattern = api.PLAY_PATTERN,
    key_tracking_none = api.KEY_TRACKING_NONE,
  }
  if not positive_integer(limits.max_lines) or not positive_integer(limits.max_note_columns) or
      type(limits.max_effect_columns) ~= "number" or limits.max_effect_columns < 0 or
      limits.max_effect_columns % 1 ~= 0 or not positive_integer(limits.play_pattern) or
      not positive_integer(limits.key_tracking_none) then
    return nil, "Native phrase limits are unavailable or invalid"
  end
  return limits
end

local function same_inventory(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
  for index = 1, #left do
    if not rawequal(left[index], right[index]) then return false end
  end
  return true
end

local function inventory(instrument)
  local ok, value = pcall(function()
    local copy = {}
    for index, phrase in ipairs(instrument.phrases) do copy[index] = phrase end
    return copy
  end)
  return ok and value or nil
end

local function inventory_addition(before, after)
  if type(before) ~= "table" or type(after) ~= "table" or #after ~= #before + 1 then return nil end
  local added, old_index = nil, 1
  for _, phrase in ipairs(after) do
    if old_index <= #before and rawequal(phrase, before[old_index]) then
      old_index = old_index + 1
    elseif added == nil then
      added = phrase
    else
      return nil
    end
  end
  if old_index ~= #before + 1 then return nil end
  return added
end

local function phrase_index(instrument, phrase)
  local found
  for index, item in ipairs(instrument.phrases) do
    if rawequal(item, phrase) then
      if found then return nil end
      found = index
    end
  end
  return found
end

local function phrase_id_count(song, id)
  local count = 0
  for _, instrument in ipairs(song.instruments) do
    for _, phrase in ipairs(instrument.phrases) do
      if ownership.id(phrase) == id then count = count + 1 end
    end
  end
  return count
end

local function remember_temporary(song, instrument, phrase, token)
  temporary_phrases[#temporary_phrases + 1] = {
    song = song, instrument = instrument, phrase = phrase, token = token,
  }
end

local function forget_temporary(phrase)
  for index = #temporary_phrases, 1, -1 do
    if rawequal(temporary_phrases[index].phrase, phrase) then table.remove(temporary_phrases, index) end
  end
end

function M.is_temporary(song, instrument, phrase)
  if song == nil or instrument == nil or phrase == nil then return false end
  local index = 1
  while index <= #temporary_phrases do
    local item = temporary_phrases[index]
    if rawequal(item.song, song) and rawequal(item.instrument, instrument) and
        rawequal(item.phrase, phrase) then
      local present = phrase_index(instrument, phrase) ~= nil
      if not present then
        table.remove(temporary_phrases, index)
      else
        return true
      end
    else
      index = index + 1
    end
  end
  return false
end

function M.state()
  return current and "busy" or "idle", current and current.token or nil
end

function M.diagnostic()
  if not last_diagnostic then return nil end
  return { code = last_diagnostic.code, message = last_diagnostic.message }
end

function M.clear_integrity_blocker(song)
  if song ~= nil then integrity_errors[song] = nil end
  if last_diagnostic and last_diagnostic.code == "transaction.blocker_recording" then last_diagnostic = nil end
end

local function set_diagnostic(code, message)
  last_diagnostic = { code = code, message = tostring(message) }
end

local function failure(request, code, category, message, status)
  message = tostring(message or "Phrase generation failed")
  return {
    kind = "failure", status = status or "failed",
    token = type(request) == "table" and rawget(request, "token") or nil,
    epoch = type(request) == "table" and rawget(request, "epoch") or nil,
    request = request, phrase = nil, verified = false, reason = message,
    code = code, category = category, message = message, diagnostics = { message },
  }
end

local function token_current(request)
  local ok, value = pcall(function()
    if type(request.is_current) == "function" then return request:is_current() end
    return request.token:is_current()
  end)
  return ok and value == true
end

local function checkpoint(request)
  if type(request) ~= "table" then
    return false, "Request checkpoint is unavailable"
  end
  local validate=request.validate_authorization_checkpoint
  if type(validate)~="function" then return false,"Request authorization checkpoint is unavailable" end
  local ok, valid, reason = pcall(function() return validate(request) end)
  if not ok then return false, "Cannot inspect request checkpoint" end
  if valid ~= true then return false, reason or "Request checkpoint failed" end
  return true
end

local function lpb_timing(song)
  local ok, valid = pcall(function()
    return renoise.Transport.TIMING_MODEL_LPB ~= nil and
      song.transport.timing_model == renoise.Transport.TIMING_MODEL_LPB
  end)
  return ok and valid
end

local function limits_for_writer(limits)
  return { max_lines = limits.max_lines, max_note_columns = limits.max_note_columns,
    max_effect_columns = limits.max_effect_columns }
end

local function snapshot(phrase, limits)
  local ok, value, reason = pcall(ownership.snapshot, phrase, limits)
  if not ok then return nil, tostring(value) end
  if not value then return nil, reason or "Cannot capture complete phrase state" end
  return value
end

local function same_baseline_values(captured, verified)
  if type(captured) ~= "table" or type(verified) ~= "table" or captured.id ~= verified.id or
      not sequencer.same_source(captured.source, verified.source) then return false end
  local settings_match = ownership.compare(captured.settings, verified.settings)
  local inputs_match = ownership.compare(captured.planning_inputs, verified.planning_inputs)
  return settings_match == true and inputs_match == true
end

local function prepare(request, done, kind)
  if type(request) ~= "table" then return nil, failure(request, "source.request", "source", "A runtime request is required") end
  if type(done) ~= "function" then return nil, failure(request, "source.callback", "source", "A terminal callback is required") end
  if request.kind ~= kind then return nil, failure(request, "source.request_kind", "source", "Request kind does not match the writer operation") end
  if request.token == nil then return nil, failure(request, "source.token", "source", "A request token is required") end
  if not policies.valid_output_policy(request.output_policy) then
    return nil, failure(request, "source.output_policy", "source", "Invalid phrase output policy")
  end
  if not policies.valid_pb_range(request.pb_range) then
    return nil, failure(request, "source.pb_range", "source", "Invalid PB range")
  end
  if type(request.source) ~= "table" then return nil, failure(request, "source.missing", "source", "A canonical ACID source is required") end
  local source_valid, source_error = sequencer.validate(request.source)
  if not source_valid then return nil, failure(request, "source.invalid", "source", source_error) end
  local song = request.song
  if song == nil then return nil, failure(request, "safety.no_song", "safety", "Open a song first") end
  local song_ok, current_song = pcall(renoise.song)
  if not song_ok or not rawequal(current_song, song) then
    return nil, failure(request, "safety.song_changed", "safety", "Request song is no longer current")
  end
  if not lpb_timing(song) then return nil, failure(request, "safety.timing_model", "safety", "Phrase generation requires LPB transport timing") end
  local instrument = request.instrument
  local instrument_index = instrument and ownership.membership(song, instrument)
  if not instrument_index then return nil, failure(request, "safety.instrument_missing", "safety", "Choose a valid instrument slot") end
  local limits, limits_error = phrase_limits()
  if not limits then return nil, failure(request, "capability.limits", "capability", limits_error) end
  local profile, profile_error = capabilities_api.inspect(instrument)
  if not profile or profile.read_error then
    return nil, failure(request, "capability.inspect", "capability", profile_error or profile.read_error)
  end
  if type(request.capabilities) ~= "table" or not capabilities_api.same(request.capabilities, profile) then
    return nil, failure(request, "safety.target_changed", "safety", "Target output capabilities changed before generation")
  end

  local replace = kind == "regenerate"
  local target_phrase, old_id, baseline, baseline_reference, baseline_index
  if replace then
    if request.target_kind ~= "owned" or request.phrase == nil then
      return nil, failure(request, "safety.destination", "safety", "Regenerate requires an existing owned phrase")
    end
    target_phrase = request.phrase
    if type(request.retained_baseline_reference) ~= "function" then
      return nil, failure(request, "safety.ownership", "safety", "Request has no retained destination proof")
    end
    local reference_ok, reference, reference_error = pcall(function()
      return request:retained_baseline_reference(request.token)
    end)
    if not reference_ok then
      return nil, failure(request, "safety.ownership", "safety", "Cannot inspect retained destination proof")
    end
    if not reference or reference == false then
      return nil, failure(request, "safety.ownership", "safety",
        "Selected phrase is not safely ACID-owned or was manually edited: " ..
          tostring(reference_error or "retained verified baseline is unavailable"))
    end
    baseline_reference = reference
    local classified, classify_error = validator.classify_against_reference(song, instrument,
      target_phrase, profile, limits,
      { pitch_bend_delivery = phrase_pitch_bend.delivery_enabled }, reference)
    if not classified then
      return nil, failure(request, "safety.ownership", "safety",
        "Selected phrase is not safely ACID-owned or was manually edited: " .. tostring(classify_error))
    end
    local retained_snapshot, retained_index = validator.retained_baseline(reference)
    if not retained_snapshot or not retained_index or not rawequal(retained_snapshot,classified.baseline) then
      return nil, failure(request, "safety.ownership", "safety",
        "Retained destination proof does not match the classified phrase snapshot")
    end
    baseline_index=retained_index
    local id = ownership.id(target_phrase)
    if not positive_integer(request.id) or request.id ~= id or phrase_id_count(song, id) ~= 1 then
      return nil, failure(request, "safety.phrase_identity", "safety", "Request phrase identity does not match the live destination")
    end
    baseline = { id = id, source = classified.source, settings = classified.settings,
      snapshot = classified.baseline, planning_inputs = classified.planning_inputs }
    if not same_baseline_values(request.baseline, baseline) then
      return nil, failure(request, "safety.target_changed", "safety", "Committed target baseline changed before generation")
    end
    old_id = id
  else
    if request.target_kind ~= "new" or request.phrase ~= nil then
      return nil, failure(request, "safety.destination", "safety", "Create requires an explicit New Phrase destination")
    end
  end

  local capacity = renoise.Instrument.MAX_NUMBER_OF_PHRASES
  if not positive_integer(capacity) then return nil, failure(request, "capability.capacity", "capability", "Native phrase capacity is unavailable") end
  if not replace and #instrument.phrases + 1 > capacity then
    return nil, failure(request, "safety.phrase_capacity", "safety", "No phrase slot is available for the new phrase")
  end
  local output, planning_error = output_planner.plan_for_materialization(request.source, request.output_policy, request.pb_range,
    limits, profile, { pitch_bend_delivery = phrase_pitch_bend.delivery_enabled })
  if not output then return nil, failure(request, "phrase.unrepresentable", "phrase", planning_error) end
  if replace then
    local safe, preflight_error = validator.preflight_destination(baseline.snapshot, output)
    if not safe then return nil, failure(request, "phrase.preflight", "phrase", preflight_error) end
  end
  local id, allocation_error = store.allocate(song)
  if not id then return nil, failure(request, "transaction.id_allocation", "transaction", allocation_error) end
  if id == old_id or phrase_id_count(song, id) ~= 0 then
    return nil, failure(request, "safety.duplicate_id", "safety", "Allocated revision ID is not unique")
  end
  local raw_before = song.tool_data
  if raw_before ~= nil and type(raw_before) ~= "string" then
    return nil, failure(request, "transaction.persistence_invalid", "transaction", "ACID song data is not text")
  end
  local guard = function()
    return token_current(request)
  end
  local candidate, candidate_error = store.prepare_revision(song, id, output.source, request.output_policy,
    request.pb_range, guard, request.draft_capture)
  if not candidate then return nil, failure(request, "transaction.persistence_prepare", "transaction", candidate_error) end
  local valid, checkpoint_error = checkpoint(request)
  if not valid then
    store.release_candidate(candidate)
    return nil, failure(request, "safety.target_changed", "safety", checkpoint_error)
  end
  return {
    kind = kind, request = request, done = done, token = request.token, epoch = request.epoch,
    song = song, instrument = instrument, instrument_index = instrument_index,
    target_phrase = target_phrase, target_index = target_phrase and phrase_index(instrument, target_phrase) or nil,
    old_id = old_id, id = id, baseline = baseline, raw_before = raw_before,
    baseline_reference = baseline_reference,
    baseline_index = baseline_index,
    profile = profile, limits = limits, output = output, store_candidate = candidate,
    replace = replace, inventory_before = inventory(instrument), phrase = target_phrase,
    mutating = false, cancel_requested = false, released = false, settled = false,
    committed = false, preimage = nil, final_baseline = nil,
    restore_phrase = false,apply_outcome_unknown=false,
    rollback_guard_required=false,rollback_guard=nil,
  }
end

local function set_phrase_name(phrase, id, verified_output)
  local name, name_error = materializer.name_for_verified_output(verified_output, id)
  if not name then return nil, name_error end
  phrase.name = name
  if phrase.name ~= name or ownership.id(phrase) ~= id then
    return nil, "Phrase revision seal did not persist"
  end
  return name
end

local function safe_remove_created(job, phrase)
  if not phrase or not rawequal(renoise.song(), job.song) or
      not rawequal(job.song.instruments[job.instrument_index], job.instrument) then
    return nil, "Created phrase identity is unavailable for rollback"
  end
  local before = job.inventory_before
  local after = inventory(job.instrument)
  if not after or not rawequal(inventory_addition(before, after), phrase) then
    return nil, "Created phrase inventory changed ambiguously; phrase retained"
  end
  local index = phrase_index(job.instrument, phrase)
  if not index then return nil, "Created phrase is not uniquely present" end
  local ok, err = pcall(function() job.instrument:delete_phrase_at(index) end)
  if not ok then return nil, "Could not remove created phrase: " .. tostring(err) end
  local restored = inventory(job.instrument)
  if not same_inventory(before, restored) then return nil, "Phrase inventory did not restore exactly" end
  forget_temporary(phrase)
  return true
end

local function restore_source(job)
  local status = store.candidate_status(job.store_candidate)
  if status and status.written_verified then
    local ok, current = pcall(function() return job.song.tool_data end)
    job.committed = ok and current == status.written_raw
  end
  if status and status.write_attempted then
    local restored, restore_error = store.restore(job.song, job.store_candidate)
    if not restored then
      if status.written_verified then
        local ok, current = pcall(function() return job.song.tool_data end)
        job.committed = ok and current == status.written_raw
      end
      return nil, restore_error
    end
  end
  if job.song.tool_data ~= job.raw_before then
    job.committed = false
    return nil, "Song source bytes did not restore exactly"
  end
  job.committed = false
  return true
end

local blocker_baseline
local function rollback(job, phrase, preimage, reason,restore_phrase)
  local errors = {}
  local preserve_destination=false
  if job.apply_outcome_unknown then
    preserve_destination=true
    errors[#errors+1]="materializer write outcome is unknown"
  elseif job.rollback_guard_required then
    local guard_ok,guard_matches,guard_error=false,nil,"Verified output rollback guard is unavailable"
    if type(job.rollback_guard)=="function" then
      guard_ok,guard_matches,guard_error=pcall(job.rollback_guard,phrase,
        limits_for_writer(job.limits))
    end
    if not guard_ok or guard_matches~=true then
      preserve_destination=true
      errors[#errors+1]="destination changed after verified materialization: "..tostring(guard_error)
    end
  end
  local source_restored, source_error
  if preserve_destination then
    job.final_baseline=nil
    local status=store.candidate_status(job.store_candidate)
    if status and status.written_verified then
      local readable,current=pcall(function()return job.song.tool_data end)
      job.committed=readable and current==status.written_raw
    end
    source_restored=false
  else
    source_restored,source_error=restore_source(job)
  end
  if not source_restored and not preserve_destination then
    errors[#errors + 1] = "source restore failed: " .. tostring(source_error)
  elseif source_restored then
    job.committed = false
    job.final_baseline = nil
    if phrase and preimage and restore_phrase then
      local restored, restore_error = materializer.restore(phrase, preimage, limits_for_writer(job.limits))
      if not restored then errors[#errors + 1] = "phrase restore failed: " .. tostring(restore_error) end
    end
  end
  if source_restored and not job.replace and phrase then
    local removed, remove_error = safe_remove_created(job, phrase)
    if not removed then errors[#errors + 1] = tostring(remove_error) end
  elseif source_restored and job.replace then
    local after = inventory(job.instrument)
    if not same_inventory(job.inventory_before, after) then errors[#errors + 1] = "regeneration changed phrase inventory" end
  end
  if #errors == 0 then return true end
  if not job.replace and phrase and phrase_index(job.instrument, phrase) then
    remember_temporary(job.song, job.instrument, phrase, job.token)
  end
  local message = tostring(reason) .. "; rollback failed: " .. table.concat(errors, "; ")
  local evidence = {
    operation = job.kind, instrument = job.instrument, phrase = job.target_phrase or phrase,
    baseline = blocker_baseline(job), committed_baseline = job.final_baseline,
    draft_capture = job.request.draft_capture,
    committed = job.committed == true,
    pre_store = job.raw_before, pre_store_absent = job.raw_before == nil,
    destination_phrases = job.inventory_before, reason = message,
    recovery = phrase and phrase_index(job.instrument, phrase) and
      { { instrument = job.instrument, phrase = phrase, role = job.replace and "destination" or "created phrase" } } or {},
  }
  local recorded, record_error = false, nil
  if type(job.request.record_blocker) == "function" then
    local ok, result, detail = pcall(function() return job.request:record_blocker(job.token, evidence) end)
    recorded, record_error = ok and result == true, ok and detail or result
  end
  if not recorded then
    integrity_errors[job.song] = "Phrase rollback failed and its recovery blocker could not be recorded"
    set_diagnostic("transaction.blocker_recording", integrity_errors[job.song] ..
      ": " .. tostring(record_error or "blocker hook unavailable"))
  end
  return nil, message
end

local function mutation_body(job)
  local request, phrase = job.request, job.target_phrase
  if job.replace and type(request.expect_revision) == "function" then
    local expected, revision_error = request:expect_revision(job.token, job.id)
    if expected ~= true then
      error(revision_error or "Request rejected the authorized phrase revision", 0)
    end
  end
  if job.cancel_requested or not token_current(request) then
    error("Generation was invalidated before phrase mutation", 0)
  end
  if not rawequal(renoise.song(), job.song) or
      not rawequal(job.song.instruments[job.instrument_index], job.instrument) then
    error("Target instrument identity changed before phrase mutation", 0)
  end
  local preimage = job.replace and job.baseline.snapshot or nil
  local returned, insert_error
  if not job.replace then
    local before = inventory(job.instrument)
    if not same_inventory(job.inventory_before, before) then error("Instrument phrase inventory changed before create", 0) end
    local inserted
    inserted, returned = pcall(function()
      return job.instrument:insert_phrase_at(#job.instrument.phrases + 1)
    end)
    local after = inventory(job.instrument)
    if not inserted or returned == nil then
      insert_error = inserted and "Insertion returned no phrase" or tostring(returned)
      phrase = inventory_addition(before, after)
      if phrase then job.phrase = phrase; remember_temporary(job.song, job.instrument, phrase, job.token) end
      error("Could not insert new phrase: " .. insert_error, 0)
    end
    phrase = returned
    if not rawequal(inventory_addition(before, after), phrase) then
      phrase = inventory_addition(before, after)
      if phrase then job.phrase = phrase; remember_temporary(job.song, job.instrument, phrase, job.token) end
      error("Phrase insertion did not create exactly one appended object", 0)
    end
    job.phrase = phrase
    remember_temporary(job.song, job.instrument, phrase, job.token)
    preimage = snapshot(phrase, job.limits)
    if not preimage then error("Cannot capture new phrase preimage", 0) end
  else
    if not phrase or phrase_index(job.instrument, phrase) ~= job.target_index or
        ownership.id(phrase) ~= job.old_id then
      error("Regeneration phrase identity changed before mutation", 0)
    end
    preimage = job.baseline.snapshot
  end
  job.preimage = preimage
  if job.cancel_requested or not token_current(request) then error("Generation was invalidated before phrase write", 0) end
  job.apply_outcome_unknown=true
  local applied, after_or_error,write_attempted = materializer.apply(phrase, job.output.expected,
    job.output.required_visibility, preimage, limits_for_writer(job.limits),
    job.output, request.planning_inputs,job.replace and job.baseline_index or nil)
  if (applied~=nil and applied~=true) or type(write_attempted)~="boolean" or
      (applied==true and write_attempted~=true) then
    error("Materializer returned an invalid write-attempt outcome",0)
  end
  job.apply_outcome_unknown=false
  job.restore_phrase=write_attempted
  if applied~=true then
    error(after_or_error or "Phrase materialization failed", 0)
  end
  job.rollback_guard_required=true
  local rollback_guard,guard_error=materializer.rollback_guard(after_or_error)
  if type(rollback_guard)~="function" then
    error(guard_error or "Materializer returned no rollback guard",0)
  end
  job.rollback_guard=rollback_guard
  local counts = { notes = 0, offs = 0, lines = job.output.expected.properties.number_of_lines }
  for line_index = 1, counts.lines do
    for column = 1, job.limits.max_note_columns do
      local note = job.output.expected.lines[line_index].note_columns[column].note_value
      if note < 120 then counts.notes = counts.notes + 1
      elseif note == 120 then counts.offs = counts.offs + 1 end
    end
  end
  if job.cancel_requested or not token_current(request) then error("Generation was invalidated after phrase write", 0) end
  local verified_output = after_or_error
  if type(verified_output) ~= "table" then error("Materializer returned no verified output receipt", 0) end
  local named, name_error = set_phrase_name(phrase, job.id, verified_output)
  if not named then error(name_error, 0) end
  local final_index = phrase_index(job.instrument, phrase)
  if not final_index then error("Committed phrase object is no longer uniquely present", 0) end
  local inventory_after = inventory(job.instrument)
  if job.replace then
    if not same_inventory(job.inventory_before, inventory_after) then error("Regeneration changed phrase inventory", 0) end
  elseif not rawequal(inventory_addition(job.inventory_before, inventory_after), phrase) then
    error("Create inventory no longer contains only the generated phrase addition", 0)
  end
  if job.cancel_requested or not token_current(request) then error("Generation was invalidated before source commit", 0) end
  local committed, commit_error = store.commit(job.song, job.store_candidate)
  if not committed then error("Source revision commit failed: " .. tostring(commit_error), 0) end
  job.committed = true
  local classified, classify_error = validator.classify_verified_postimage(job.song,
    job.instrument, phrase, job.profile, job.limits,
    { pitch_bend_delivery = phrase_pitch_bend.delivery_enabled }, verified_output, job.id, named,
    job.output, request.planning_inputs)
  if not classified then error("Committed source baseline verification failed: " .. tostring(classify_error), 0) end
  if classified.settings.output_policy ~= job.request.output_policy then
    error("final phrase output policy verification failed", 0)
  end
  if classified.settings.pb_range ~= job.request.pb_range then
    error("final phrase PB range verification failed", 0)
  end
  if not sequencer.same_source(classified.source, job.output.source) then
    error("final phrase source snapshot differs from frozen input", 0)
  end
  local baseline = { id = job.id, source = classified.source, settings = classified.settings,
    snapshot = classified.baseline, planning_inputs = classified.planning_inputs }
  if job.cancel_requested or not token_current(request) then error("Generation was invalidated during source commit", 0) end
  job.final_baseline = baseline
  job.final_index = final_index
  counts.raw_events = counts.notes + counts.offs
  job.counts = counts
  if not job.replace then forget_temporary(phrase) end
  return { phrase = phrase, baseline = baseline, counts = counts }
end

local function finish_job(job, result)
  if job.settled then return false end
  job.settled = true
  if current == job then current = nil end
  if job.store_candidate then
    store.release_candidate(job.store_candidate)
    job.store_candidate = nil
  end
  local callback = job.done
  job.done, job.request, job.song, job.instrument = nil, nil, nil, nil
  job.target_phrase, job.phrase, job.output, job.baseline = nil, nil, nil, nil
  job.baseline_reference,job.baseline_index=nil,nil
  job.profile, job.limits, job.preimage = nil, nil, nil
  job.rollback_guard,job.rollback_guard_required,job.apply_outcome_unknown=nil,nil,nil
  if type(callback) == "function" then
    delivering = true
    local ok, err = pcall(callback, result)
    if not ok then print("[ACID] Writer completion delivery error: " .. tostring(err)) end
    delivering = false
  end
  return true
end

local function target_result(job, phrase, index)
  return { instrument_index = job.instrument_index, phrase_index = index,
    phrase_name = phrase and phrase.name or nil }
end

blocker_baseline=function(job)
  local baseline=job.baseline
  if type(baseline)~="table" or not job.baseline_reference then return nil end
  return {id=baseline.id,source=baseline.source,settings=baseline.settings,
    planning_inputs=baseline.planning_inputs,snapshot=job.baseline_reference}
end

local function execute(job)
  current = job
  last_diagnostic = nil
  local undo_ok, undo_error = pcall(function()
    if type(job.song.describe_undo) == "function" then
      job.song:describe_undo(job.replace and REGENERATE_UNDO or CREATE_UNDO)
    end
  end)
  if not undo_ok then
    finish_job(job, failure(job.request, "transaction.undo_description", "transaction", undo_error))
    return
  end
  job.mutating = true
  local mutation_ok, mutation_result = pcall(function()
    return job.request:mutate(job.token, function()
      job.action_started = true
      local body_ok, body_result = pcall(mutation_body, job)
      if body_ok then return { success = true, value = body_result } end
      local reason = tostring(body_result)
      local rollback_ok, restored, rollback_error = pcall(rollback, job, job.phrase,
        job.preimage, reason,job.restore_phrase)
      if not rollback_ok then
        rollback_error = "Rollback raised an error: " .. tostring(restored)
        restored = nil
        local evidence = {
          operation = job.kind, instrument = job.instrument,
          phrase = job.target_phrase or job.phrase,
          baseline = blocker_baseline(job), committed_baseline = job.final_baseline,
          draft_capture = job.request.draft_capture,
          committed = job.committed == true,
          pre_store = job.raw_before, pre_store_absent = job.raw_before == nil,
          destination_phrases = job.inventory_before, reason = rollback_error,
          recovery = job.phrase and phrase_index(job.instrument, job.phrase) and
            { { instrument = job.instrument, phrase = job.phrase,
              role = job.replace and "destination" or "created phrase" } } or {},
        }
        local recorded = false
        if type(job.request.record_blocker) == "function" then
          local ok, result = pcall(function()
            return job.request:record_blocker(job.token, evidence)
          end)
          recorded = ok and result == true
        end
        if not recorded then
          integrity_errors[job.song] = "Phrase rollback raised an error and its recovery blocker could not be recorded"
          set_diagnostic("transaction.blocker_recording", integrity_errors[job.song])
        end
      end
      if not restored then return { success = false, blocked = true, reason = rollback_error } end
      return { success = false, cancelled = job.cancel_requested,
        reason = job.cancel_requested and (job.cancel_reason or reason) or reason }
    end)
  end)
  job.mutating = false
  local outcome = mutation_ok and mutation_result or nil
  if not mutation_ok then
    local reason = tostring(mutation_result)
    local status = job.action_started and "integrity_blocked" or "failed"
    if job.action_started and type(job.request.record_blocker) == "function" then
      local evidence = { operation = job.kind, instrument = job.instrument,
        phrase = job.target_phrase or job.phrase, baseline = blocker_baseline(job),
        committed_baseline = job.final_baseline, committed = job.committed == true,
        pre_store = job.raw_before, pre_store_absent = job.raw_before == nil,
        destination_phrases = job.inventory_before, reason = reason,
        recovery = job.phrase and phrase_index(job.instrument, job.phrase) and
          { { instrument = job.instrument, phrase = job.phrase, role = job.replace and "destination" or "created phrase" } } or {} }
      pcall(function() job.request:record_blocker(job.token, evidence) end)
    end
    local result = failure(job.request, status == "integrity_blocked" and
      "transaction.rollback" or "safety.mutation", status == "integrity_blocked" and
      "integrity" or "safety", reason, status)
    result.target = target_result(job, job.target_phrase or job.phrase, job.target_index or job.final_index)
    result.committed = job.committed == true
    result.baseline = job.final_baseline
    result.recovery = job.phrase and phrase_index(job.instrument, job.phrase) and
      { { instrument = job.instrument, phrase = job.phrase,
        role = job.replace and "destination" or "created phrase" } } or {}
    result.integrity_blocked = status == "integrity_blocked"
    finish_job(job, result)
    return
  end
  if type(outcome) ~= "table" then
    finish_job(job, failure(job.request, "transaction.mutation_result", "transaction",
      "Synchronous mutation returned no transaction result", "integrity_blocked"))
    return
  end
  if not outcome.success then
    local cancelled = outcome.cancelled == true and not outcome.blocked
    local result = failure(job.request,
      outcome.blocked and "transaction.rollback" or cancelled and "safety.cancelled" or "transaction.commit",
      outcome.blocked and "integrity" or cancelled and "safety" or "transaction",
      outcome.reason, outcome.blocked and "integrity_blocked" or cancelled and "cancelled" or "failed")
    result.target = target_result(job, job.target_phrase, job.target_index)
    result.committed = job.committed == true
    result.baseline = job.final_baseline
    result.recovery = job.phrase and phrase_index(job.instrument, job.phrase) and
      { { instrument = job.instrument, phrase = job.phrase, role = "destination" } } or {}
    result.integrity_blocked = outcome.blocked == true
    finish_job(job, result)
    return
  end
  local value = outcome.value
  local diagnostics = job.output.approximations
  if job.profile.diagnostic then diagnostics[#diagnostics + 1] = job.profile.diagnostic end
  local message = string.format("Phrase %02d generated (%d notes, %d OFF). Instrument %02X.",
    job.final_index, value.counts.notes, value.counts.offs, job.instrument_index - 1)
  local result = {
    kind = "success", status = #diagnostics > 0 and "approximate" or "committed",
    token = job.token, epoch = job.epoch, request = job.request, phrase = value.phrase,
    verified = true, committed = true, reason = nil,
    code = #diagnostics > 0 and "capability.approximate" or "phrase.committed",
    category = #diagnostics > 0 and "capability" or "transaction",
    message = message, diagnostics = diagnostics,
    target = target_result(job, value.phrase, job.final_index), counts = value.counts,
    id = job.id, baseline = value.baseline, recovery = {}, integrity_blocked = false,
  }
  finish_job(job, result)
end

local function admit(request, done, kind)
  if current or delivering then return false, failure(request, "transaction.busy", "transaction", "ACID is already generating a phrase") end
  local requested_song = type(request) == "table" and request.song or nil
  if integrity_errors[requested_song] then
    return false, failure(request, "transaction.integrity_blocked", "integrity", integrity_errors[requested_song], "integrity_blocked")
  end
  local built, job, rejection = pcall(prepare, request, done, kind)
  if not built then return false, failure(request, "safety.preflight", "safety", "Cannot inspect the phrase request safely: " .. tostring(job)) end
  if not job then return false, rejection end
  current = job
  execute(job)
  return true
end

function M.create(request, done)
  return admit(request, done, "create")
end

function M.regenerate(request, done)
  return admit(request, done, "regenerate")
end

function M.cancel(token, reason)
  local job = current
  if not job or not rawequal(job.token, token) then return false end
  job.cancel_requested = true
  job.cancel_reason = reason or "Generation cancelled"
  return true
end

function M.release()
  local job = current
  if not job then return nil end
  job.released = true
  job.cancel_requested = true
  job.cancel_reason = "Document released"
  return "The synchronous phrase operation will roll back before it settles."
end

return M
