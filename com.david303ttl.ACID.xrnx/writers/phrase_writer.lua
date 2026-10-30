-- SPDX-License-Identifier: GPL-3.0-only
-- Render native phrases with guarded replacement and source persistence.
--
-- Public musical operations are explicit:
--   create(request, done)     request.kind == "create", target_kind == "new"
--   regenerate(request, done) request.kind == "regenerate", target_kind == "owned"
-- Both return true once a job is accepted and false, rejection before any host
-- mutation. An accepted job calls done(result) exactly once. The result is a
-- native terminal value: kind "success" or "failure", token, epoch, request,
-- phrase, verified and reason (failure only), plus status/message/diagnostics.
local pattrns = require("writers.pattrns_writer")
local validator = require("writers.phrase_validator")
local gates = require("writers.gate_writer")
local ownership = require("renoise.phrase_ownership")
local store = require("renoise.pattern_store")
local target_capabilities = require("renoise.target_capabilities")
local sequencer = require("model.sequencer")
local legato_writer = require("writers.legato_writer")
local phrase_pitch_bend = require("writers.phrase_pitch_bend")
local script_runner = require("writers.script_runner")
local output_planner = require("model.output_planner")
local policies = require("model.policies")
local M = {}

M.PHRASE_NAME = "ACID 0.1 TEST"
M.RECOVERY_STAGING_NAME = "ACID RECOVERY STAGING"
M.TRANSACTION_BACKUP_NAME = "ACID TRANSACTION BACKUP"
M.RECOVERY_BACKUP_NAME = "ACID RECOVERY BACKUP"
M.EMPTY_SCRIPT_DIAGNOSTIC = "compile error: no script content present."

local STATUS_IDLE = "idle"
local STATUS_BUSY = "busy"
local COMMIT_WAIT_TICKS = 500
local SCRIPT_SETTLE_TICKS = 500
local RENDER_PENDING_TICKS = 500
local RENDER_EVENT_MARGIN = 8
local PINNED_MAX_LINES = 512
local PINNED_NOTE_COLUMNS = 12
local PINNED_EFFECT_COLUMNS = 8
local PINNED_PHRASE_CAPACITY = 126
local UNDO_CREATE = "ACID: Generate phrase"
local UNDO_REGENERATE = "ACID: Regenerate phrase"

local busy = false
local current = nil
local released_token = nil
local delivering = false
local temporaries = {}
local last_diagnostic = nil

local function pack(...) return {n = select("#", ...), ...} end

local function unpack_packed(value)
  return (unpack or table.unpack)(value, 1, value.n)
end

local function failure(request, code, category, message, status)
  message = tostring(message or "Phrase generation failed")
  return {
    kind = "failure", status = status or "failed", token = request and request.token or nil,
    epoch = request and request.epoch or nil, request = request, phrase = nil,
    verified = false, reason = message, code = code, category = category,
    message = message, diagnostics = { message },
  }
end

local function positive_integer(value)
  return type(value) == "number" and value % 1 == 0 and value > 0
end

local function nonnegative_integer(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function phrase_limits()
  local api = rawget(_G, "renoise") and renoise.InstrumentPhrase
  if type(api) ~= "table" then return nil, "Phrase API is unavailable" end
  local max_lines = api.MAX_NUMBER_OF_LINES
  local max_note_columns = api.MAX_NUMBER_OF_NOTE_COLUMNS
  local max_effect_columns = api.MAX_NUMBER_OF_EFFECT_COLUMNS
  if max_lines == nil then max_lines = PINNED_MAX_LINES end
  if max_note_columns == nil then max_note_columns = PINNED_NOTE_COLUMNS end
  if max_effect_columns == nil then max_effect_columns = PINNED_EFFECT_COLUMNS end
  if not positive_integer(max_lines) or not positive_integer(max_note_columns) or
      not nonnegative_integer(max_effect_columns) then
    return nil, "Native phrase limits are invalid"
  end
  return {
    max_lines = max_lines, max_note_columns = max_note_columns,
    max_effect_columns = max_effect_columns,
    play_pattern = api.PLAY_PATTERN, key_tracking_none = api.KEY_TRACKING_NONE,
  }
end

local function phrase_capacity()
  local instrument_api = rawget(_G, "renoise") and renoise.Instrument
  local value = type(instrument_api) == "table" and instrument_api.MAX_NUMBER_OF_PHRASES
  if value == nil then value = PINNED_PHRASE_CAPACITY end
  if not positive_integer(value) then return nil, "Native phrase capacity is invalid" end
  return value
end

local function lpb_timing(song)
  local ok, valid = pcall(function()
    local expected = renoise.Transport.TIMING_MODEL_LPB
    return expected ~= nil and song.transport.timing_model == expected
  end)
  return ok and valid
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

local function membership(list, value)
  local ok, found = pcall(function()
    for _, item in ipairs(list) do
      if rawequal(item, value) then return true end
    end
    return false
  end)
  return ok, ok and found == true
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

local function remember_temporary(job, phrase, role)
  if phrase == nil or job.released then return end
  temporaries[#temporaries + 1] = {
    phrase = phrase, role = role, song = job.song, instrument = job.instrument, token = job.token,
  }
end

local function forget_temporary(phrase)
  for index = #temporaries, 1, -1 do
    if rawequal(temporaries[index].phrase, phrase) then
      table.remove(temporaries, index)
    end
  end
end

-- Read-only query for objects this writer inserted and still owns as temporary.
function M.is_temporary(song, instrument, phrase)
  if song == nil or instrument == nil or phrase == nil then return false end
  local index = 1
  while index <= #temporaries do
    local record = temporaries[index]
    if rawequal(record.phrase, phrase) and
        rawequal(record.song, song) and rawequal(record.instrument, instrument) then
      local phrase_ok, phrase_present = membership(instrument.phrases, phrase)
      if not phrase_ok then
        index = index + 1
      elseif not phrase_present then
        table.remove(temporaries, index)
      else
        local instrument_ok, instrument_present = membership(song.instruments, instrument)
        if not instrument_ok then
          index = index + 1
        elseif not instrument_present then
          table.remove(temporaries, index)
        else
          return true
        end
      end
    else
      index = index + 1
    end
  end
  return false
end

-- Read-only inspection: detached status ("idle" or "busy") and the exact
-- opaque operation token passed to create/regenerate, when one was supplied.
function M.state()
  local job = current
  if not job then return STATUS_IDLE, nil end
  if job.released then return STATUS_BUSY, released_token end
  return STATUS_BUSY, job.token
end

-- Detached pending diagnostic. A still-running native render is not terminal.
function M.diagnostic()
  if not last_diagnostic then return nil end
  return { code = last_diagnostic.code, message = last_diagnostic.message }
end

local function set_diagnostic(code, message)
  last_diagnostic = { code = code, message = tostring(message) }
end

local function token_current(job)
  if job.token == nil then return false end
  local ok, value = pcall(function() return job.token:is_current() end)
  return ok and value == true
end

local function request_checkpoint(request)
  if type(request) ~= "table" or type(request.validate_checkpoint) ~= "function" then
    return false, "Request checkpoint is unavailable"
  end
  local ok, valid, reason = pcall(function() return request:validate_checkpoint() end)
  if not ok then return false, "Cannot inspect request checkpoint" end
  if valid ~= true then return false, reason or "Request checkpoint failed" end
  return true
end

local function checkpoint(job)
  if job.settled or job.released or job.cancelled then
    return false, job.cancel_reason or "Generation was invalidated"
  end
  if not token_current(job) then return false, "Generation was invalidated" end
  return request_checkpoint(job.request)
end

local function mutate_host(job, action)
  if job.released or type(job.request) ~= "table" or type(job.request.mutate) ~= "function" then
    return nil, "Request mutation is unavailable"
  end
  local ok, values = pcall(function() return pack(job.request:mutate(job.token, action)) end)
  if not ok then return nil, tostring(values) end
  if values.n == 0 then return true end
  return true, unpack_packed(values)
end

local function cleanup_authorized(job)
  if job.released or type(job.request) ~= "table" or
      type(job.request.cleanup_authorized) ~= "function" then
    return false
  end
  local ok, allowed = pcall(function() return job.request:cleanup_authorized(job.token) end)
  return ok and allowed == true
end

local function delete_phrase_direct(instrument, phrase)
  local index = phrase_index(instrument, phrase)
  if not index then return false end
  instrument:delete_phrase_at(index)
  return phrase_index(instrument, phrase) == nil
end

local function try_delete_phrase(instrument, phrase)
  local ok, removed = pcall(delete_phrase_direct, instrument, phrase)
  return ok and removed == true
end

local function remove_phrase(job, phrase)
  if job.released or phrase == nil then return false end
  local function action() return delete_phrase_direct(job.instrument, phrase) end
  local ok, removed = mutate_host(job, action)
  if ok and removed == true then
    forget_temporary(phrase)
    return true
  end
  -- Cancellation can revoke commit authorization while narrowly scoped cleanup
  -- of this job's own objects remains permitted.
  if cleanup_authorized(job) then
    local cleaned, result = pcall(action)
    if cleaned and result == true then
      forget_temporary(phrase)
      return true
    end
  end
  return false
end

local function cleanup_temporaries(job)
  local recovery, errors = {}, {}
  if job.released then return recovery, nil end
  if job.backup then
    if remove_phrase(job, job.backup) then
      job.backup = nil
    else
      pcall(function() job.backup.name = M.RECOVERY_BACKUP_NAME end)
      recovery[#recovery + 1] = { instrument = job.instrument, phrase = job.backup,
        role = "backup", label = M.RECOVERY_BACKUP_NAME }
      errors[#errors + 1] = "backup cleanup failed"
    end
  end
  if job.temporary and job.phrase then
    if remove_phrase(job, job.phrase) then
      job.temporary = false
    else
      pcall(function() job.phrase.name = M.RECOVERY_STAGING_NAME end)
      recovery[#recovery + 1] = { instrument = job.instrument, phrase = job.phrase,
        role = "staging", label = M.RECOVERY_STAGING_NAME }
      errors[#errors + 1] = "staging cleanup failed"
    end
  end
  return recovery, #errors > 0 and table.concat(errors, " and ") or nil
end

local function unlink(job)
  if job.runner then pcall(function() job.runner:detach() end) end
  if job.idle_observer and job.on_idle then
    pcall(function() job.idle_observer:remove_notifier(job.on_idle) end)
  end
  if job.clear_observer and job.on_clear_commit then
    pcall(function() job.clear_observer:remove_notifier(job.on_clear_commit) end)
  end
  job.runner, job.idle_observer, job.on_idle = nil, nil, nil
  job.clear_observer, job.on_clear_commit = nil, nil
end

local function settle(job, result)
  if job.settled then return false end
  job.settled = true
  job.cancelled = true
  unlink(job)
  current = nil
  busy = false
  released_token = nil
  local done = job.done
  delivering = true
  if type(done) == "function" then
    local ok, failure_message = pcall(done, result)
    if not ok then print("[ACID] Writer completion delivery error: " .. tostring(failure_message)) end
  end
  delivering = false
  job.done = nil
  job.request = nil
  job.song = nil
  job.instrument = nil
  job.phrase = nil
  job.target_phrase = nil
  job.backup = nil
  job.store_candidate = nil
  job.plan, job.layout, job.pattern, job.operations, job.native_notes = nil, nil, nil, nil, nil
  job.capabilities, job.limits, job.draft_capture = nil, nil, nil
  return true
end

local function failure_suffix(job)
  if job.swapped or job.keep_recovery then
    return "; phrase output or recovery state may have changed; inspect the destination before retrying"
  end
  return "; previous ACID phrase remains unchanged"
end

local function terminal_failure(job, status, code, category, reason, extra)
  extra = extra or {}
  reason = tostring(reason or "Phrase generation failed")
  local recovery, cleanup_error = nil, nil
  if not extra.skip_cleanup then
    recovery, cleanup_error = cleanup_temporaries(job)
  end
  local message = reason .. failure_suffix(job)
  local diagnostics = {}
  for _, item in ipairs(job.approximations or {}) do diagnostics[#diagnostics + 1] = item end
  for _, item in ipairs(extra.diagnostics or {}) do diagnostics[#diagnostics + 1] = item end
  if cleanup_error then
    status = "integrity_blocked"
    code = code == "transaction.cancelled" and "transaction.cancelled_recovery" or code
    category = "integrity"
    job.keep_recovery = true
    message = message .. "; " .. cleanup_error .. " and recovery material was retained"
  elseif job.keep_recovery and extra.recovery_message then
    message = message .. "; " .. extra.recovery_message
  end
  if extra.recovery then recovery = extra.recovery end
  if next(recovery or {}) == nil and job.recovery then recovery = job.recovery end
  local result = {
    kind = "failure", status = status, token = job.token, epoch = job.epoch,
    request = job.request, phrase = extra.phrase or job.keep_recovery and job.phrase or nil,
    verified = false, reason = reason, code = code, category = category,
    message = message, diagnostics = diagnostics,
    target = { instrument_index = job.instrument_index, phrase_index = job.target_index },
    counts = extra.counts, recovery = recovery, integrity_blocked = status == "integrity_blocked",
  }
  settle(job, result)
end

local function terminal_success(job, counts, diagnostics, approximation)
  local message = string.format(
    "Phrase %02d generated (%d notes, %d OFF; %d raw events). Instrument %02X.",
    job.target_index, counts.notes, counts.offs, counts.raw_events, job.instrument_index - 1)
  if job.target_warning then message = message .. "\n" .. job.target_warning end
  if #diagnostics > 0 then
    message = message .. "\nArticulation approximation: " .. table.concat(diagnostics, "; ")
  end
  if job.cleanup_warning then message = message .. "\n" .. job.cleanup_warning end
  local result = {
    kind = "success", status = approximation and "approximate" or "committed",
    token = job.token, epoch = job.epoch, request = job.request, phrase = job.destination,
    verified = true, reason = nil,
    code = approximation and "capability.approximate" or "phrase.committed",
    category = approximation and "capability" or "transaction",
    message = message, diagnostics = diagnostics,
    target = { instrument_index = job.instrument_index, phrase_index = job.target_index },
    counts = counts, id = job.id, baseline = job.committed_baseline,
    recovery = job.recovery, integrity_blocked = job.cleanup_warning ~= nil,
  }
  settle(job, result)
end

local function script_is_empty(script)
  if type(script) ~= "table" then return false, "Phrase script is unavailable" end
  local ok, paragraphs, parameters, pending, visible = pcall(function()
    return script.paragraphs, script.parameters, script.pending_changes, script.editor_visible
  end)
  if not ok or type(paragraphs) ~= "table" or type(parameters) ~= "table" then
    return false, "Cannot inspect phrase script"
  end
  if next(paragraphs) ~= nil or next(parameters) ~= nil then return false end
  if pending ~= 0 then return false end
  if visible ~= true then return false, "Phrase script editor state is unreadable" end
  return true
end

local function script_settled(job)
  local empty = script_is_empty(job.phrase.script)
  if not empty then return false end
  local ok, compile_error, runtime_error = pcall(function()
    return job.phrase.script.compile_error, job.phrase.script.runtime_error
  end)
  if not ok or type(compile_error) ~= "string" then return false end
  if compile_error ~= M.EMPTY_SCRIPT_DIAGNOSTIC then return false end
  if runtime_error ~= nil and runtime_error ~= "" then return false end
  return true
end

local function describe_undo(job)
  local song = job.song
  if type(song.describe_undo) ~= "function" then return end
  pcall(function()
    song:describe_undo(job.replace and UNDO_REGENERATE or UNDO_CREATE)
  end)
end

local function build_job(request, done, kind)
  if type(request) ~= "table" then return nil, failure(request, "source.request", "source", "A runtime request is required") end
  if type(done) ~= "function" then return nil, failure(request, "source.callback", "source", "A terminal callback is required") end
  if request.kind ~= kind then
    return nil, failure(request, "source.request_kind", "source", "Request kind does not match the writer operation")
  end
  if request.token == nil then
    return nil, failure(request, "source.token", "source", "A request token is required")
  end
  if not policies.valid_output_policy(request.output_policy) then
    return nil, failure(request, "source.output_policy", "source", "Invalid phrase output policy")
  end
  if not policies.valid_pb_range(request.pb_range) then
    return nil, failure(request, "source.pb_range", "source", "Invalid PB range")
  end
  if type(request.source) ~= "table" then
    return nil, failure(request, "source.missing", "source", "A canonical ACID source is required")
  end
  local source_valid, source_error = sequencer.validate(request.source)
  if not source_valid then
    return nil, failure(request, "source.invalid", "source", source_error)
  end
  local song = request.song
  if song == nil then return nil, failure(request, "safety.no_song", "safety", "Open a song first") end
  local current_ok, current_song = pcall(renoise.song)
  if not current_ok or not rawequal(current_song, song) then
    return nil, failure(request, "safety.song_changed", "safety", "Request song is no longer current")
  end
  if not lpb_timing(song) then
    return nil, failure(request, "safety.timing_model", "safety", "Phrase generation requires LPB transport timing")
  end
  local instrument = request.instrument
  local instrument_index = instrument and ownership.membership(song, instrument)
  if not instrument_index then
    return nil, failure(request, "safety.instrument_missing", "safety", "Choose a valid instrument slot")
  end
  local limits, limits_error = phrase_limits()
  if not limits then return nil, failure(request, "capability.limits", "capability", limits_error) end
  local capabilities, capability_error = target_capabilities.inspect(instrument)
  if not capabilities or capabilities.read_error then
    return nil, failure(request, "capability.inspect", "capability", capability_error or capabilities.read_error)
  end
  if type(request.capabilities) ~= "table" or not target_capabilities.same(request.capabilities, capabilities) then
    return nil, failure(request, "safety.target_changed", "safety", "Target output capabilities changed before generation")
  end
  local snapshot_id
  local replace
  local target_phrase, target_name
  if kind == "create" then
    if request.target_kind ~= "new" or request.phrase ~= nil then
      return nil, failure(request, "safety.destination", "safety", "Create requires an explicit New Phrase destination")
    end
    snapshot_id = store.allocate(song)
    if not snapshot_id then
      return nil, failure(request, "transaction.id_allocation", "transaction", "Cannot allocate an ACID phrase ID")
    end
    if phrase_id_count(song, snapshot_id) ~= 0 then
      return nil, failure(request, "safety.duplicate_id", "safety", "Allocated ACID phrase ID is not unique")
    end
    replace = false
  else
    if request.target_kind ~= "owned" or request.phrase == nil then
      return nil, failure(request, "safety.destination", "safety", "Regenerate requires an existing owned phrase")
    end
    target_phrase = request.phrase
    local id, id_error = ownership.validate_live(song, instrument, target_phrase)
    if not id then
      return nil, failure(request, "safety.ownership", "safety",
        "Selected phrase is not safely ACID-owned or was manually edited: " .. tostring(id_error))
    end
    if not positive_integer(request.id) or request.id ~= id then
      return nil, failure(request, "safety.phrase_identity", "safety", "Request phrase identity does not match the live destination")
    end
    if phrase_id_count(song, id) ~= 1 then
      return nil, failure(request, "safety.duplicate_id", "safety", "Selected ACID phrase ID is duplicated")
    end
    local candidate, classify_error = validator.classify(song, instrument, target_phrase, capabilities, limits,
      { pitch_bend_delivery = phrase_pitch_bend.delivery_enabled })
    if not candidate then return nil, failure(request, "safety.source_missing", "safety", classify_error) end
    local baseline = {
      id = id, source = candidate.source, settings = candidate.settings,
      snapshot = candidate.baseline, planning_inputs = candidate.planning_inputs,
    }
    local same, difference = ownership.compare(request.baseline, baseline)
    if not same then
      return nil, failure(request, "safety.target_changed", "safety",
        "Committed target baseline changed before generation: " .. tostring(difference))
    end
    snapshot_id, replace = id, true
    target_name = target_phrase.name
  end
  local capacity, capacity_error = phrase_capacity()
  if not capacity then return nil, failure(request, "capability.capacity", "capability", capacity_error) end
  local required_slots = replace and 2 or 1
  if #instrument.phrases + required_slots > capacity then
    return nil, failure(request, "safety.phrase_capacity", "safety", "Not enough phrase slots for staging and rollback backup")
  end
  local planned, planning_error = output_planner.plan(request.source, request.output_policy, request.pb_range,
    limits, capabilities, { pitch_bend_delivery = phrase_pitch_bend.delivery_enabled })
  if not planned then return nil, failure(request, "phrase.unrepresentable", "phrase", planning_error) end
  local fixture, plan, layout = planned.source, planned.plan, planned.layout
  local native_notes, operations, approximations = planned.native_notes, planned.operations, planned.approximations
  local script_source, meta = pattrns.emit(plan, { unit = layout.unit, resolution = layout.resolution })
  if not script_source then return nil, failure(request, "phrase.unrepresentable", "phrase", meta) end
  if song.transport.groove_enabled then
    approximations[#approximations + 1] = "Song groove is active; its effect on phrase timing is unverified."
  end
  local pre_store = song.tool_data
  if pre_store ~= nil and type(pre_store) ~= "string" then
    return nil, failure(request, "transaction.persistence_invalid", "transaction", "ACID song data is not text")
  end
  local destination_phrases = {}
  for index, phrase in ipairs(instrument.phrases) do destination_phrases[index] = phrase end
  -- Store commit happens after the destination mutation and before the source
  -- association exists, so a full target classification cannot be re-run here.
  -- Authorization is the live request token; the full checkpoint runs before
  -- and after this synchronous section.
  local guard = function()
    local ok, valid = pcall(function()
      if type(request.is_current) == "function" then return request.is_current() end
      return request.token:is_current()
    end)
    return ok and valid == true
  end
  local store_candidate, prepare_error = store.prepare(song, snapshot_id, fixture, request.output_policy,
    request.pb_range, guard, request.draft_capture)
  if not store_candidate then
    return nil, failure(request, "transaction.persistence_prepare", "transaction", prepare_error)
  end
  return {
    kind = kind, request = request, done = done, token = request.token, epoch = request.epoch,
    song = song, instrument = instrument, instrument_index = instrument_index,
    capabilities = capabilities, limits = limits, id = snapshot_id,
    store_candidate = store_candidate, pre_store = pre_store,
    destination_phrases = destination_phrases,
    target_phrase = target_phrase, target_name = target_name,
    replace = replace, target_index = target_phrase and phrase_index(instrument, target_phrase) or nil,
    expected_events = meta.note_count + meta.off_count,
    plan = plan, layout = layout, pattern = fixture, script_source = script_source,
    output_policy = request.output_policy, pb_range = request.pb_range, volumes = planned.volumes,
    required_visibility = planned.required_visibility,
    operations = operations, approximations = approximations, native_notes = native_notes,
    target_warning = capabilities.diagnostic, temporary = false, cancelled = false, settled = false,
    draft_capture = request.draft_capture, counts = nil,
  }
end

local function context_live(job)
  if job.settled or job.released then return false,"Generation has settled" end
  if job.cancelled then return false,job.cancel_reason or "Generation was cancelled" end
  if not token_current(job) then return false,"generation was invalidated" end
  local ok,song=pcall(renoise.song)
  if not ok or not rawequal(song,job.song) then return false,"song changed during generation" end
  if not phrase_index(job.instrument,job.phrase) then
    return false,"staging phrase was removed during generation"
  end
  if job.replace then
    if not phrase_index(job.instrument,job.target_phrase) then
      return false,"target phrase was removed or duplicated during generation"
    end
  end
  return true
end

local after_clear

local function begin_wait(job)
  job.ticks = 0
  job.on_idle = function()
    if current ~= job or job.settled or job.released then return end
    if job.waiting_for_clear then
      job.ticks = job.ticks + 1
      if job.clear_committed and script_settled(job) then
        job.waiting_for_clear = false
        if job.clear_observer and job.on_clear_commit then
          pcall(function() job.clear_observer:remove_notifier(job.on_clear_commit) end)
        end
        job.clear_observer, job.on_clear_commit = nil, nil
        local completed, completion_error = pcall(after_clear, job)
        if not completed and not job.settled then
          terminal_failure(job, "failed", "phrase.publication", "phrase",
            "Phrase publication failed: " .. tostring(completion_error))
        end
      elseif job.ticks >= SCRIPT_SETTLE_TICKS then
        terminal_failure(job, "failed", "phrase.script_clear", "phrase",
          "Timed out waiting for the generated stage script to clear")
      end
      return
    end
    job.ticks = job.ticks + 1
    local valid, reason = context_live(job)
    if not valid then
      if not job.cancelled then
        job.cancel_reason = reason
        job.cancelled = true
      end
      if not job.render_started then
        if job.runner then job.runner:cancel() end
        terminal_failure(job, "suspended", "safety.target_changed", "safety", reason)
      end
      return
    end
    if job.render_started then
      if job.ticks == RENDER_PENDING_TICKS then
        local message = (job.runner and job.runner.error and job.runner.error .. ". " or "") ..
          "Native phrase rendering has not completed. New writes are blocked; restart Renoise if its callback never arrives."
        set_diagnostic("transaction.render_pending", message)
        job.diagnostic = M.diagnostic()
      end
    elseif job.ticks >= COMMIT_WAIT_TICKS then
      if job.runner then job.runner:cancel() end
      terminal_failure(job, "failed", "transaction.render", "transaction",
        "Timed out waiting for script commitment")
    end
  end
  job.idle_observer = renoise.tool().app_idle_observable
  job.idle_observer:add_notifier(job.on_idle)
end

local function apply_layout(job)
  local ok, error_message = mutate_host(job, function()
    local phrase = job.phrase
    phrase.number_of_lines = job.layout.number_of_lines
    phrase.lpb = job.layout.lpb
    phrase.shuffle = 0
    phrase.looping = job.layout.looping
    phrase.loop_end = job.layout.loop_end
    phrase.loop_start = job.layout.loop_start
  end)
  if not ok then return nil, error_message end
  if job.phrase.lpb ~= job.layout.lpb or job.phrase.shuffle ~= 0 then
    return nil, "Phrase timing metadata verification failed"
  end
  return true
end

local function apply_articulation(job, expected_articulation)
  if job.native_notes then
    local ok, applied, apply_error = mutate_host(job, function()
      return legato_writer.apply(job.phrase, job.native_notes)
    end)
    if not ok then return nil, applied end
    if not applied then return nil, apply_error end
    return { native_notes = job.native_notes }
  elseif job.operations then
    local ok, applied, apply_error = mutate_host(job, function()
      return gates.apply_plan(job.phrase, job.operations)
    end)
    if not ok then return nil, applied end
    if not applied then return nil, apply_error end
    return expected_articulation
  end
  return expected_articulation or { effects = {}, release_lines = {}, volumes = job.volumes }
end

local function clear_stage_script(job, expected_articulation)
  job.expected_articulation = expected_articulation
  local valid, reason = context_live(job)
  if not valid then
    terminal_failure(job, "suspended", "safety.target_changed", "safety", reason)
    return
  end
  job.clear_committed = false
  local ok, error_message = mutate_host(job, function()
    local script = job.phrase.script
    job.clear_observer = script.committed_observable
    if job.clear_observer == nil or type(job.clear_observer.add_notifier) ~= "function" then
      error("Phrase script commit notification is unavailable", 0)
    end
    job.on_clear_commit = function()
      job.clear_committed = true
      if job.clear_observer and job.on_clear_commit then
        pcall(function() job.clear_observer:remove_notifier(job.on_clear_commit) end)
      end
      job.clear_observer, job.on_clear_commit = nil, nil
    end
    job.clear_observer:add_notifier(job.on_clear_commit)
    script.paragraphs = {}
    script:commit()
  end)
  if not ok then
    terminal_failure(job, "failed", "phrase.script_clear", "phrase",
      "Could not clear generated stage script: " .. tostring(error_message))
    return
  end
  job.waiting_for_clear = true
  job.ticks = 0
end

local function snapshot_target_baseline(job, phrase)
  local readable, baseline = pcall(function()
    local candidate = assert(validator.classify(job.song, job.instrument, phrase,
      job.capabilities, job.limits, { pitch_bend_delivery = phrase_pitch_bend.delivery_enabled }))
    return {
      id = ownership.id(phrase), source = candidate.source, settings = candidate.settings,
      snapshot = candidate.baseline, planning_inputs = candidate.planning_inputs,
    }
  end)
  if not readable then return nil end
  return baseline
end

local function record_blocker(job, reason, recovery)
  if job.released or type(job.request) ~= "table" or type(job.request.record_blocker) ~= "function" then
    return false
  end
  job.blocker_recorded = true
  local evidence = {
    operation = job.replace and "regenerate" or "create",
    instrument = job.instrument, phrase = job.target_phrase or job.phrase,
    baseline = job.request and job.request.baseline, committed_baseline = job.committed_baseline,
    draft_capture = job.draft_capture, recovery = recovery or {},
    reason = reason,
  }
  if not job.replace then
    evidence.pre_store = job.pre_store
    evidence.pre_store_absent = job.pre_store == nil
    evidence.destination_phrases = job.destination_phrases
  end
  local ok, recorded = pcall(function() return job.request:record_blocker(job.token, evidence) end)
  return ok and recorded == true
end

local function commit_destination(job)
  local valid, reason = checkpoint(job)
  if not valid then
    terminal_failure(job, "suspended", "safety.target_changed", "safety", reason)
    return
  end
  local capacity, capacity_error = phrase_capacity()
  if not capacity then
    terminal_failure(job, "failed", "capability.capacity", "capability", capacity_error)
    return
  end
  if #job.instrument.phrases + (job.replace and 2 or 1) > capacity then
    terminal_failure(job, "failed", "safety.phrase_capacity", "safety",
      "Not enough phrase slots for staging and rollback backup")
    return
  end
  local outcome
  local ok, error_message = pcall(function()
    outcome = job.request:mutate(job.token, function()
      local result = { committed = false, integrity_blocked = false, message = nil }
      local backup = job.backup
      local destination = job.replace and job.target_phrase or job.phrase
      local destination_before
      if job.replace then
        local captured, snapshot_value = pcall(ownership.snapshot, destination)
        if not captured or snapshot_value == nil then
          result.message = "Cannot capture destination before replacement"
          result.integrity_blocked = true
          return result
        end
        destination_before = snapshot_value
      end
      local function rollback(commit_attempted, cause)
        local phrase_restored = true
        if job.replace and backup then
          local restored, restore_error = pcall(function()
            destination:copy_from(backup)
            destination.name = job.target_name
          end)
          if not restored or destination.name ~= job.target_name or
              ownership.status(destination) ~= "owned" then
            phrase_restored = false
            job.keep_recovery = true
            job.swapped = true
            pcall(function() backup.name = M.RECOVERY_BACKUP_NAME end)
            result.message = "destination rollback failed: " .. tostring(restore_error)
          end
        end
        local store_restored = true
        if commit_attempted then
          local called, restored, restore_error = pcall(store.restore, job.song, job.store_candidate)
          if not called or not restored then
            store_restored = false
            result.message = (result.message and result.message .. "; " or "") ..
              "source rollback failed: " .. tostring(called and restore_error or restored)
          end
        end
        if not job.replace and job.temporary then
          if try_delete_phrase(job.instrument, job.phrase) then
            job.temporary = false
            forget_temporary(job.phrase)
          else
            job.keep_recovery = true
            pcall(function() job.phrase.name = M.RECOVERY_STAGING_NAME end)
            result.message = (result.message and result.message .. "; " or "") .. "staging cleanup failed"
          end
        end
        if job.replace and backup and phrase_restored then
          if try_delete_phrase(job.instrument, backup) then job.backup = nil; forget_temporary(backup)
          else
            job.keep_recovery = true
            pcall(function() backup.name = M.RECOVERY_BACKUP_NAME end)
            result.message = (result.message and result.message .. "; " or "") .. "backup cleanup failed"
          end
        end
        if job.replace and job.temporary then
          if try_delete_phrase(job.instrument, job.phrase) then
            job.temporary = false
            forget_temporary(job.phrase)
          else
            job.keep_recovery = true
            pcall(function() job.phrase.name = M.RECOVERY_STAGING_NAME end)
            result.message = (result.message and result.message .. "; " or "") .. "staging cleanup failed"
          end
        end
        result.integrity_blocked = (not phrase_restored) or (not store_restored) or job.keep_recovery == true
        result.message = result.message or cause
      end
      if job.replace then
        if #job.instrument.phrases + 2 > capacity then
          rollback(false, "Not enough phrase slots for staging and rollback backup")
          return result
        end
        backup = job.instrument:insert_phrase_at(#job.instrument.phrases + 1)
        remember_temporary(job, backup, "backup")
        job.backup = backup
        local backed_up, backup_error = pcall(function()
          backup:copy_from(destination)
          backup.name = M.TRANSACTION_BACKUP_NAME
        end)
        if not backed_up then
          rollback(false, "Could not create destination backup: " .. tostring(backup_error))
          return result
        end
        local captured_backup, backup_snapshot = pcall(ownership.snapshot, backup)
        if not captured_backup or backup_snapshot == nil then
          rollback(false, "Cannot inspect destination backup")
          return result
        end
        local compared, same, difference = pcall(ownership.compare, destination_before,
          backup_snapshot, "name")
        if not compared or not same then
          rollback(false, "Destination backup coverage failed: " .. tostring(difference))
          return result
        end
      end
      local copied, copy_error = pcall(function()
        if job.replace then
          destination:copy_from(job.phrase)
          -- Preflight proves the destination exposes the required output;
          -- preserve its exact visibility and base settings instead of
          -- silently expanding them from the staging phrase.
          local properties = destination_before.properties
          for _, key in ipairs({ "visible_note_columns", "visible_effect_columns",
              "instrument_column_visible", "volume_column_visible", "panning_column_visible",
              "delay_column_visible", "sample_effects_column_visible", "base_note", "autoseek" }) do
            destination[key] = properties[key]
          end
        end
        local name, name_error = ownership.make_name(destination, job.id)
        if not name then error(name_error, 0) end
        destination.name = name
      end)
      if not copied then
        rollback(false, "Phrase replacement failed: " .. tostring(copy_error))
        return result
      end
      local checked, verified, validation_error = pcall(validator.verify, destination, job.plan,
        job.layout.lines_per_step, job.layout, job.expected_articulation)
      if not checked or not verified then
        rollback(false, "Copied phrase validation failed: " ..
          tostring(checked and validation_error or verified))
        return result
      end
      -- A thrown setter may already have changed song data; always inspect and
      -- roll the guarded candidate back after any commit attempt.
      local commit_called, committed, store_error = pcall(store.commit, job.song, job.store_candidate)
      if not commit_called then
        store_error, committed = committed, nil
      end
      if not committed then
        rollback(true, "Source commit failed: " .. tostring(store_error))
        return result
      end
      local final_ok, final_error = pcall(function()
        local status = ownership.status(destination)
        if status ~= "owned" or ownership.id(destination) ~= job.id then
          error("final phrase seal verification failed", 0)
        end
        local saved, saved_policy, saved_pb_range = store.load(job.song, job.instrument, destination)
        if not saved then error("final phrase source association verification failed: " .. tostring(saved_policy), 0) end
        if saved_policy ~= job.output_policy then error("final phrase output policy verification failed", 0) end
        if saved_pb_range ~= job.pb_range then error("final phrase PB range verification failed", 0) end
        if not sequencer.same_source(saved, job.pattern) then
          error("final phrase source snapshot differs from frozen input", 0)
        end
      end)
      if not final_ok then
        rollback(true, "Final phrase/source verification failed: " .. tostring(final_error))
        return result
      end
      job.committed_baseline = snapshot_target_baseline(job, destination)
      job.destination = destination
      job.target_index = phrase_index(job.instrument, destination) or job.target_index
      job.swapped = job.replace
      if backup then
        if try_delete_phrase(job.instrument, backup) then
          forget_temporary(backup)
          job.backup = nil
        else
          job.cleanup_warning = "Committed output; recovery backup remains in the instrument."
          pcall(function() backup.name = M.RECOVERY_BACKUP_NAME end)
          job.recovery = job.recovery or {}
          job.recovery[#job.recovery + 1] = { instrument = job.instrument, phrase = backup,
            role = "backup", label = M.RECOVERY_BACKUP_NAME }
        end
      end
      if job.replace then
        if try_delete_phrase(job.instrument, job.phrase) then
          job.temporary = false
          forget_temporary(job.phrase)
        else
          job.cleanup_warning = (job.cleanup_warning and job.cleanup_warning .. " " or "") ..
            "Committed output; staging phrase remains in the instrument."
          pcall(function() job.phrase.name = M.RECOVERY_STAGING_NAME end)
          job.recovery = job.recovery or {}
          job.recovery[#job.recovery + 1] = { instrument = job.instrument, phrase = job.phrase,
            role = "staging", label = M.RECOVERY_STAGING_NAME }
        end
      else
        job.temporary = false
        forget_temporary(job.phrase)
      end
      result.committed = true
      return result
    end)
  end)
  if not ok then
    local recovery = {}
    if job.phrase and not job.released then
      pcall(function() job.phrase.name = M.RECOVERY_STAGING_NAME end)
      recovery[#recovery + 1] = { instrument = job.instrument, phrase = job.phrase,
        role = "staging", label = M.RECOVERY_STAGING_NAME }
      job.keep_recovery = true
    end
    record_blocker(job, "Synchronous commit raised an exception", recovery)
    terminal_failure(job, "integrity_blocked", "transaction.commit", "integrity",
      "Phrase commit raised an exception: " .. tostring(error_message), { skip_cleanup = true })
    return
  end
  if outcome and outcome.committed then
    job.recovery = job.recovery or {}
    terminal_success(job, job.counts, job.diagnostics or {}, job.approximation)
    return
  end
  local message = outcome and outcome.message or "Phrase commit failed"
  if outcome and outcome.integrity_blocked then
    local evidence = {}
    if job.phrase and not job.released then
      evidence[#evidence + 1] = { instrument = job.instrument, phrase = job.phrase,
        role = "staging", label = job.phrase.name }
    end
    if job.backup and not job.released then
      evidence[#evidence + 1] = { instrument = job.instrument, phrase = job.backup,
        role = "backup", label = job.backup.name }
    end
    job.recovery = evidence
    if #evidence > 0 then message = message .. "; recovery phrase retained" end
    record_blocker(job, message, evidence)
    terminal_failure(job, "integrity_blocked", "transaction.rollback", "integrity", message,
      { skip_cleanup = true, recovery = evidence })
  else
    terminal_failure(job, "failed", "transaction.commit", "transaction", message)
  end
end

after_clear = function(job)
  if job.settled or job.released then return end
  local valid, reason = context_live(job)
  if not valid then
    terminal_failure(job, "suspended", "safety.target_changed", "safety", reason)
    return
  end
  local mutated, mutation_error = mutate_host(job, function()
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    job.phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
  end)
  if not mutated then
    terminal_failure(job, "failed", "phrase.publication", "phrase",
      "Could not finalize generated phrase: " .. tostring(mutation_error))
    return
  end
  local empty, script_error = script_is_empty(job.phrase.script)
  if not empty then
    terminal_failure(job, "failed", "phrase.script_clear", "phrase", script_error)
    return
  end
  local verified, validation_error = validator.verify(job.phrase, job.plan,
    job.layout.lines_per_step, job.layout, job.expected_articulation)
  if not verified then
    terminal_failure(job, "failed", "phrase.validation", "phrase", validation_error)
    return
  end
  commit_destination(job)
end

local function finalize(job, event_count, skipped)
  if current ~= job or job.settled or job.released then return end
  job.render_started = false
  local valid, reason = checkpoint(job)
  if not valid then
    terminal_failure(job, "suspended", "safety.target_changed", "safety", reason)
    return
  end
  if skipped ~= 0 then
    terminal_failure(job, "failed", "phrase.render_count", "phrase",
      "Renoise skipped " .. tostring(skipped) .. " event(s)")
    return
  end
  if type(event_count) ~= "number" or event_count < job.expected_events then
    terminal_failure(job, "failed", "phrase.render_count", "phrase", string.format(
      "Too few raw events: expected at least %d, received %s", job.expected_events, tostring(event_count)))
    return
  end
  local staged, layout_error = apply_layout(job)
  if not staged then
    terminal_failure(job, "failed", "phrase.layout", "phrase", layout_error)
    return
  end
  local first_verified, first_error = validator.verify(job.phrase, job.plan,
    job.layout.lines_per_step, job.layout, { volumes = job.volumes })
  if not first_verified then
    terminal_failure(job, "failed", "phrase.validation", "phrase", first_error)
    return
  end
  local expected = job.operations or { effects = {}, release_lines = {}, volumes = job.volumes }
  expected.volumes = job.volumes
  local applied, articulation_error = apply_articulation(job, expected)
  if not applied then
    terminal_failure(job, "failed", "phrase.validation", "phrase", articulation_error)
    return
  end
  local final_verified, final_error = validator.verify(job.phrase, job.plan,
    job.layout.lines_per_step, job.layout, applied)
  if not final_verified then
    terminal_failure(job, "failed", "phrase.validation", "phrase", final_error)
    return
  end
  job.counts = { notes = final_verified.notes, offs = final_verified.offs,
    lines = final_verified.lines, raw_events = event_count }
  job.diagnostics = {}
  if job.target_warning then job.diagnostics[#job.diagnostics + 1] = job.target_warning end
  for _, item in ipairs(job.approximations or {}) do job.diagnostics[#job.diagnostics + 1] = item end
  job.approximation = #job.diagnostics > 0
  clear_stage_script(job, applied)
end

local function render_done(job, error_message, rendered_events, skipped_events)
  if current ~= job or job.settled then return end
  if job.released then
    local result = {
      kind = "failure", status = "cancelled", token = job.token, epoch = job.epoch,
      request = nil, phrase = nil, verified = false,
      reason = job.cancel_reason or "Document released during native rendering",
      code = "transaction.released", category = "transaction",
      message = "Document released during native rendering; retained recovery material requires inspection",
      diagnostics = {},
    }
    settle(job, result)
    return
  end
  job.render_started = false
  if job.cancelled then
    terminal_failure(job, "cancelled", "transaction.cancelled", "transaction",
      job.cancel_reason or "Generation cancelled")
    return
  end
  local safe, callback_error = pcall(function()
    if error_message and error_message ~= "" then
      terminal_failure(job, "failed", "transaction.render", "transaction",
        "Phrase rendering: " .. tostring(error_message))
      return
    end
    finalize(job, rendered_events, skipped_events)
  end)
  if not safe then
    terminal_failure(job, "failed", "transaction.render", "transaction",
      "Phrase render completion failed: " .. tostring(callback_error))
  end
end

local function stage(job)
  local valid, reason = checkpoint(job)
  if not valid then
    terminal_failure(job, "suspended", "safety.target_changed", "safety", reason)
    return
  end
  describe_undo(job)
  local inserted, insertion_error = mutate_host(job, function()
    local capacity, capacity_error = phrase_capacity()
    if not capacity then error(capacity_error, 0) end
    if #job.instrument.phrases + (job.replace and 2 or 1) > capacity then
      error("Not enough phrase slots for staging and rollback backup", 0)
    end
    local phrase = job.instrument:insert_phrase_at(#job.instrument.phrases + 1)
    job.phrase = phrase
    job.temporary = true
    remember_temporary(job, phrase, "staging")
    phrase.name = M.PHRASE_NAME
    phrase.playback_mode = renoise.InstrumentPhrase.PLAY_SCRIPT
    local visibility = job.required_visibility
    if type(visibility) == "table" then
      for _, key in ipairs({ "visible_note_columns", "visible_effect_columns" }) do
        if type(visibility[key]) == "number" then
          local existing = type(phrase[key]) == "number" and phrase[key] or 0
          phrase[key] = math.max(existing, visibility[key])
        end
      end
      for _, key in ipairs({ "instrument_column_visible", "volume_column_visible",
          "panning_column_visible", "delay_column_visible", "sample_effects_column_visible" }) do
        if visibility[key] == true then phrase[key] = true end
      end
    end
    phrase.script.paragraphs = { job.script_source }
    return phrase
  end)
  if not inserted then
    terminal_failure(job, "failed", "transaction.stage", "transaction",
      "Could not create staging phrase: " .. tostring(insertion_error))
    return
  end
  job.script = job.phrase.script
  local runner, runner_error = script_runner.new(job.script, {
    lpb = job.layout.lpb, max_events = job.plan.length + RENDER_EVENT_MARGIN,
  }, {
    rendering = function()
      if current ~= job or job.settled then return end
      local ready, checkpoint_error = context_live(job)
      if not ready then
        job.suspended_reason = checkpoint_error
        error(checkpoint_error, 0)
      end
      job.render_started = true
      job.ticks = 0
    end,
    done = function(render_error, rendered_events, skipped_events)
      render_done(job, render_error, rendered_events, skipped_events)
    end,
  })
  if not runner then
    terminal_failure(job, "failed", "transaction.render", "transaction", runner_error)
    return
  end
  job.runner = runner
  begin_wait(job)
  local started, start_error = runner:start()
  if not started then
    terminal_failure(job, "failed", "transaction.render", "transaction", start_error)
  end
end

local function start(request, done, kind)
  if busy or current or delivering then
    local message = current and current.released and
      "Native phrase rendering is still pending; restart Renoise if its callback never arrives." or
      "ACID is already generating a phrase"
    return false, failure(request, "transaction.busy", "transaction", message)
  end
  local job, rejection = build_job(request, done, kind)
  if not job then return false, rejection end
  current, busy, released_token = job, true, nil
  local ok, error_message = pcall(stage, job)
  if not ok then
    if current == job then
      terminal_failure(job, "failed", "transaction.stage", "transaction", tostring(error_message))
    else
      pcall(function()
        if job.phrase and job.instrument then try_delete_phrase(job.instrument, job.phrase) end
      end)
    end
    return true
  end
  return true
end

function M.create(request, done)
  if type(request) == "table" and request.kind ~= "create" then
    return false, failure(request, "source.request_kind", "source", "Request kind does not match create")
  end
  return start(request, done, "create")
end

function M.regenerate(request, done)
  if type(request) == "table" and request.kind ~= "regenerate" then
    return false, failure(request, "source.request_kind", "source", "Request kind does not match regenerate")
  end
  return start(request, done, "regenerate")
end

-- Cancellation invalidates commit authorization. Returning true only reports a
-- matching known job; it never retires the writer slot. A compile-wait or
-- clear-wait job can settle synchronously. An in-flight native render remains
-- occupied until its callback arrives.
function M.cancel(token, reason)
  local job = current
  if not job then return false end
  local job_token = job.released and released_token or job.token
  if not rawequal(job_token, token) then return false end
  job.cancelled = true
  job.cancel_reason = reason or "Generation cancelled"
  -- Recording recovery evidence invalidates the request from inside the writer;
  -- that revocation must not settle the job before its terminal evidence.
  if job.blocker_recorded or job.released then return true end
  if job.render_started then return true end
  if job.runner then job.runner:cancel() end
  terminal_failure(job, "cancelled", "transaction.cancelled", "transaction", job.cancel_reason)
  return true
end

-- Release drops host references and GUI delivery while retaining only a
-- host-free tombstone for an in-flight native render. The stage remains as
-- explicitly reported recovery material.
function M.release()
  local job = current
  if not job then return end
  if job.released then return end
  if not job.render_started then
    M.cancel(job.token, "Document released")
    return
  end
  local token, epoch, done = job.token, job.epoch, job.done
  unlink(job)
  for key in pairs(job) do job[key] = nil end
  job.token, job.epoch, job.done = token, epoch, done
  job.released, job.cancelled = true, true
  job.cancel_reason = "Document released during native rendering"
  released_token = token
end

return M
