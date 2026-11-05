local M = {}
local FIXTURE_NAME = "acceptance-metadata-recovery.xrns"
local OWNED_LABEL = "Verified owned label"
local NEW_LABEL = "Verified New label"
local FOREIGN_NAME = "Metadata foreign sentinel"
local FOREIGN_NOTE = 55
local FOREIGN_LINE = 8
local PREPARE_TIMEOUT_SECONDS = 120
local prepared

local function cleanup(state)
  if state.notifier then
    local idle = renoise.tool().app_idle_observable
    if idle:has_notifier(state.notifier) then idle:remove_notifier(state.notifier) end
    state.notifier = nil
  end
  if state.dialog and state.dialog.visible then state.dialog:close() end
  if state.context then state.context:release_document(); state.context = nil end
  if rawequal(prepared, state) then prepared = nil end
end

local function exercise(state)
  local song, instrument, phrase = state.song, state.instrument, state.phrase
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local sequence = require("model.sequencer")
  local original_song, original_current, original_capture = renoise.song, ownership.is_current, ownership.capture_recovery
  local mode, writes, renders, recovery_reads = nil, 0, 0, 0
  local checks = {}
  local proxy = setmetatable({}, {
    __index = function(_, key)
      local value = song[key]
      if type(value) == "function" then return function(_, ...) return value(song, ...) end end
      return value
    end,
    __newindex = function(_, key, value)
      assert(key == "tool_data", "Fault proxy only permits metadata writes")
      writes = writes + 1
      song.tool_data = mode == "third" and "injected uncertain metadata" or value
    end,
  })
  local ok, reason = pcall(function()
    ownership.is_current = function(candidate)
      if rawequal(candidate, proxy) then return rawequal(original_song(), song) end
      return original_current(candidate)
    end
    renoise.song = function() return proxy end
    state.context = require("runtime.context").new({writer = require("writers.phrase_writer"),
      sink = function() renders = renders + 1; error("Label operation requested a render") end})
    local context = state.context
    context:attach_document(proxy)
    context:open_dialog()
    local target_snapshot = assert(ownership.snapshot(phrase))
    local target_name = phrase.name
    local source, policy, pb = store.read_entry(song, state.id)
    local foreign_snapshots = {}
    for i, foreign in ipairs(state.foreign) do foreign_snapshots[i] = assert(ownership.snapshot(foreign)) end
    local function native_exact()
      assert(#instrument.phrases == 2 and rawequal(instrument.phrases[1], phrase)
        and rawequal(instrument.phrases[2], state.foreign[1]), "Target inventory changed")
      assert(#state.other.phrases == 1 and rawequal(state.other.phrases[1], state.foreign[2]),
        "Unrelated instrument inventory changed")
      assert(phrase.name == target_name and ownership.id(phrase) == state.id
        and ownership.compare(target_snapshot, assert(ownership.snapshot(phrase))),
        "Label operation changed target native phrase")
      for i, foreign in ipairs(state.foreign) do
        assert(foreign.name == FOREIGN_NAME and ownership.compare(foreign_snapshots[i],
          assert(ownership.snapshot(foreign))), "Label operation changed a foreign phrase")
      end
      local current, current_policy, current_pb = store.read_entry(song, state.id)
      assert(sequence.same_source(source, current) and current_policy == policy and current_pb == pb,
        "Label operation changed committed source or settings")
    end
    ownership.capture_recovery = function()
      recovery_reads = recovery_reads + 1
      error("Unrelated native phrase recovery is unavailable")
    end
    for _, destination in ipairs({"owned"}) do
      local target = destination == "owned" and phrase or nil
      assert(context:restore_editor_target(instrument, target), "Cannot restore label destination")
      local revision = context:revision_state()
      assert(context:rename_label("Accepted " .. destination, true))
      assert(context:revision_state().edit_revision == revision.edit_revision,
        "Label changed musical revision")
      assert(context:revision_state().metadata_revision == revision.metadata_revision + 1,
        "Label did not advance metadata revision")
      native_exact()
      checks[destination .. "_rename_without_render"] = true
      local before, editor = song.tool_data, context:editor_state()
      revision = context:revision_state()
      mode = "third"
      assert(not context:rename_label("Rejected " .. destination, true), "Uncertain rename succeeded")
      assert(context:integrity_state().blocked and song.tool_data ~= before, "Uncertain write did not block")
      assert(context:editor_state().label == editor.label
        and context:revision_state().metadata_revision == revision.metadata_revision,
        "Failed metadata advanced accepted state or history")
      local blocked_writes = writes
      assert(not context:rename_label("Blocked", true) and writes == blocked_writes)
      assert(not context:request_generation("manual") and renders == 0)
      -- A separate native edit does not authorize clearing the metadata blocker.
      local foreign = state.foreign[2]
      local cell = foreign:line(FOREIGN_LINE):note_column(1)
      cell.note_value = cell.note_value + 1
      foreign_snapshots[2] = assert(ownership.snapshot(foreign))
      song.tool_data = before .. "\n"
      mode = nil
      song.tool_data = before
      assert(context:integrity_state().blocked, "restoring exact bytes cleared the blocker")
      assert(not context:rename_label("Still blocked", true) and writes == blocked_writes,
        "restored bytes allowed another metadata write")
      checks.uncertain_write_remains_blocked = true
      checks.unrelated_native_edit_preserved = true
      native_exact()
      checks[destination .. "_uncertain_write_blocked"] = true
      checks[destination .. "_unrelated_native_edit_preserved"] = true
    end
    local _, _, _, label, custom = store.read_entry(song, state.id)
    assert(label == "Accepted owned" and custom == true)
    local draft = store.read_draft(proxy, instrument, nil)
    assert(draft == nil, "failed label write created an unrelated New Phrase draft")
    assert(renders == 0 and recovery_reads == 0)
    checks.zero_generation_and_recovery_reads = true
  end)
  if state.context then pcall(function() state.context:release_document() end); state.context = nil end
  renoise.song, ownership.is_current, ownership.capture_recovery = original_song, original_current, original_capture
  state.action = {status = ok and "PASS" or "FAIL", reason = not ok and tostring(reason) or nil,
    checks = checks, recovery_reads = recovery_reads, renders = renders,
    injection = "synthetic metadata setter and recovery-read faults with native song storage and phrases"}
end

function M.run(case_name, done, helpers)
  if case_name == "metadata-recovery-cold" then
    local song = renoise.song()
    local baseline = helpers.baseline(song)
    local context
    local ok, reason = pcall(function()
      local store = require("renoise.pattern_store")
      local ownership = require("renoise.phrase_ownership")
      local instrument = song.instruments[1]
      assert(#instrument.phrases == 2 and #song.instruments[2].phrases == 1)
      local phrase = instrument.phrases[1]
      local id = assert(ownership.id(phrase))
      local source, _, _, label, custom = store.read_entry(song, id)
      local draft, _, _, draft_label, draft_custom = store.read_draft(song, instrument, nil)
      assert(source and label == "Accepted owned" and custom == true)
      assert(draft == nil, "Cold reopen found an unrequested New Phrase draft")
      assert(song.instruments[2].phrases[1]:line(FOREIGN_LINE):note_column(1).note_value == FOREIGN_NOTE + 1,
        "Cold reopen lost unrelated native edits")
      context = require("runtime.context").new({writer = require("writers.phrase_writer"),
        sink = function() error("Cold restore requested a render") end})
      context:attach_document(song); context:open_dialog()
      for _, target in ipairs({"owned"}) do
        assert(context:restore_editor_target(instrument, phrase))
        local editor = context:editor_state()
        assert(editor.label == "Accepted owned" and editor.label_custom)
      end
      assert(helpers.baseline(song) == baseline, "Cold restoration mutated persisted native state")
    end)
    if context then context:release_document() end
    done({status = ok and "PASS" or "FAIL", case = case_name, reason = not ok and tostring(reason) or nil,
      reopened_baseline = baseline, read_only_restore = ok, owned_and_new_labels_exact = ok})
    return true
  end
  if case_name == "metadata-recovery" then
    local state = prepared
    if not state then done({status = "FAIL", case = case_name, reason = "No prepared metadata dialog"}); return true end
    local result = state.action or {status = "FAIL", reason = "Perform the guarded dialog action first"}
    if result.status == "PASS" then
      local ok, reason = pcall(function()
        assert(rawequal(renoise.song(), state.song), "Prepared document changed")
        local saved, err = helpers.save(state.song, FIXTURE_NAME)
        assert(saved, err)
        result.roundtrip_fixture = FIXTURE_NAME
        result.saved_baseline = helpers.baseline(state.song)
      end)
      if not ok then result.status, result.reason = "FAIL", tostring(reason) end
    end
    cleanup(state)
    result.case = case_name
    done(result)
    return true
  end
  if case_name ~= "metadata-recovery-prepare" then return false end
  if prepared then cleanup(prepared) end
  local song = renoise.song()
  local state = {song = song, instrument = song.selected_instrument, foreign = {}}
  local ok, reason = pcall(function()
    assert(not song.transport.playing and #state.instrument.phrases == 1,
      "Reopen the one-phrase revision fixture before metadata acceptance")
    assert(song.selected_instrument_index == 1, "Expected first fixture instrument")
    state.phrase = state.instrument.phrases[1]
    state.id = assert(require("renoise.phrase_ownership").id(state.phrase))
    state.instrument.name = "Metadata owned and New destinations"
    state.other = song:insert_instrument_at(2)
    state.other.name = "Metadata unrelated instrument"
    state.foreign = {state.instrument:insert_phrase_at(2), state.other:insert_phrase_at(1)}
    for _, foreign in ipairs(state.foreign) do
      foreign.name, foreign.number_of_lines = FOREIGN_NAME, FOREIGN_LINE
      foreign:line(FOREIGN_LINE):note_column(1).note_value = FOREIGN_NOTE
    end
    local function action()
      if state.action then return end
      exercise(state)
      if state.dialog and state.dialog.visible then state.dialog:close() end
    end
    local vb = renoise.ViewBuilder()
    state.dialog = renoise.app():show_custom_dialog("ACID metadata recovery acceptance", vb:column {
      margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN,
      vb:text {text = "Press Enter to test owned and New labels, storage failure and recovery."},
      vb:button {text = "Test metadata recovery", notifier = action},
    }, function(_, key)
      if (key.name == "enter" or key.name == "return") and key.state ~= "released" then action(); return nil end
      return key
    end, {send_key_repeat = false, send_key_release = false})
    assert(state.dialog and state.dialog.visible, "Metadata recovery dialog did not open")
    local idle, deadline = renoise.tool().app_idle_observable, os.time() + PREPARE_TIMEOUT_SECONDS
    state.notifier = function()
      if not rawequal(renoise.song(), song) or os.time() >= deadline then cleanup(state) end
    end
    idle:add_notifier(state.notifier)
  end)
  if not ok then cleanup(state); done({status = "FAIL", case = case_name, reason = tostring(reason)}); return true end
  prepared = state
  done({status = "PASS", case = case_name, action_ready = true, dialog_visible = state.dialog.visible})
  return true
end

return M
