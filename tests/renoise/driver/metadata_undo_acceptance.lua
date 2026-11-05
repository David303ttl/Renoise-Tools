local M = {}

local ACTION_LABEL = "Native undo label"
local PREPARE_TIMEOUT_SECONDS = 120
local SETTLE_IDLE_TICKS = 3
local prepared

local function cleanup(state)
  if state.notifier then
    local idle = renoise.tool().app_idle_observable
    if idle:has_notifier(state.notifier) then idle:remove_notifier(state.notifier) end
    state.notifier = nil
  end
  if state.dialog and state.dialog.visible then state.dialog:close() end
  if state.context then state.context:release_document() end
  if rawequal(prepared, state) then prepared = nil end
end

local function settle(state, action)
  local remaining = SETTLE_IDLE_TICKS
  local idle = renoise.tool().app_idle_observable
  state.notifier = function()
    remaining = remaining - 1
    if remaining > 0 then return end
    idle:remove_notifier(state.notifier)
    state.notifier = nil
    action()
  end
  idle:add_notifier(state.notifier)
end

local function prepare(done)
  if prepared then cleanup(prepared) end
  local song = renoise.song()
  local instrument = song.selected_instrument
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local context = require("runtime.context").new({writer = require("writers.phrase_writer"),
    sink = function() return false, "Metadata acceptance does not generate" end})
  local state = {song = song, instrument = instrument, context = context}
  local ok, err = pcall(function()
    assert(not song.transport.playing, "Stop playback before preparing native metadata undo")
    assert(instrument and #instrument.phrases == 1, "Reopen the one-phrase revision fixture")
    assert(not song:can_undo() and not song:can_redo(), "Reopen the fixture to clear native history")
    state.phrase = instrument.phrases[1]
    state.id = assert(ownership.id(state.phrase), "Fixture phrase has no owned ID")
    state.source, state.policy, state.pb, state.label, state.custom = store.read_entry(song, state.id)
    assert(state.source, "Fixture phrase has no committed source")
    assert(state.label ~= ACTION_LABEL, "Fixture already has the acceptance label")
    state.snapshot = assert(ownership.snapshot(state.phrase))
    state.before = song.tool_data
    context:attach_document(song)
    context:open_dialog()
    local restored = context:restore_editor_target(instrument, state.phrase)
    assert(restored and restored.source_available, "Fixture editor source could not be restored")
    local function rename()
      if state.action then return end
      local called, changed, reason = pcall(context.rename_label, context, ACTION_LABEL, true)
      state.action = {called = called, changed = changed == true, reason = tostring(reason)}
      if state.dialog and state.dialog.visible then state.dialog:close() end
    end
    local vb = renoise.ViewBuilder()
    state.dialog = renoise.app():show_custom_dialog("ACID metadata undo acceptance", vb:column {
      margin = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN,
      vb:text {text = "Press Enter to rename the fixture label, then verify native undo and redo."},
      vb:button {text = "Rename label", notifier = rename},
    }, function(_, key)
      if (key.name == "enter" or key.name == "return") and key.state ~= "released" then
        rename()
        return nil
      end
      return key
    end, {send_key_repeat = false, send_key_release = false})
    assert(state.dialog and state.dialog.visible, "Native metadata action dialog did not open")
  end)
  if not ok then cleanup(state); done({status = "FAIL", case = "metadata-undo-prepare", reason = tostring(err)}); return true end
  prepared = state
  local deadline = os.time() + PREPARE_TIMEOUT_SECONDS
  local idle = renoise.tool().app_idle_observable
  state.notifier = function()
    if not rawequal(renoise.song(), song) or os.time() >= deadline then cleanup(state) end
  end
  idle:add_notifier(state.notifier)
  done({status = "PASS", case = "metadata-undo-prepare", action_ready = true,
    dialog_visible = state.dialog.visible, focused = state.dialog.focused})
  return true
end

local function verify(done)
  local state = prepared
  if not state then done({status = "FAIL", case = "metadata-undo", reason = "Native metadata action was not prepared"}); return true end
  local idle = renoise.tool().app_idle_observable
  if state.notifier then idle:remove_notifier(state.notifier); state.notifier = nil end
  local song = state.song
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local sequence = require("model.sequencer")
  local result = {status = "FAIL", case = "metadata-undo"}
  local function finish(reason)
    result.reason = reason
    cleanup(state)
    done(result)
  end
  local function immutable()
    local source, policy, pb = store.read_entry(song, state.id)
    local snapshot = ownership.snapshot(state.phrase)
    return #state.instrument.phrases == 1 and rawequal(state.instrument.phrases[1], state.phrase) and
      ownership.id(state.phrase) == state.id and snapshot and ownership.compare(state.snapshot, snapshot) and
      source and sequence.same_source(state.source, source) and policy == state.policy and pb == state.pb
  end
  local function check(label, custom, bytes)
    local _, _, _, actual_label, actual_custom = store.read_entry(song, state.id)
    return song.tool_data == bytes and actual_label == label and actual_custom == custom and immutable() == true
  end
  local function guarded(action)
    local ok, err = pcall(action)
    if not ok then finish(tostring(err)) end
  end
  guarded(function()
    assert(rawequal(renoise.song(), song), "Prepared song changed before native undo")
    assert(state.action and state.action.called and state.action.changed,
      state.action and state.action.reason or "Perform the prepared native label action first")
    state.after = song.tool_data
    result.rename_exact = state.after ~= state.before and check(ACTION_LABEL, true, state.after)
    result.can_undo_after_rename = song:can_undo()
    assert(result.rename_exact, "Native rename changed source, settings, ID, or phrase content")
    assert(result.can_undo_after_rename, "Host exposed no native undo state for label metadata")
    song:undo()
    settle(state, function() guarded(function()
      result.undo_exact = check(state.label, state.custom, state.before)
      result.can_redo_after_undo = song:can_redo()
      assert(result.undo_exact, "Native undo did not restore exact metadata bytes and label with immutable source/settings/ID/content")
      assert(result.can_redo_after_undo, "Native metadata undo exposed no redo state")
      song:redo()
      settle(state, function() guarded(function()
        result.redo_exact = check(ACTION_LABEL, true, state.after)
        assert(result.redo_exact, "Native redo did not restore exact metadata bytes and label with immutable source/settings/ID/content")
        result.status = "PASS"
        finish()
      end) end)
    end) end)
  end)
  return true
end

function M.run(case_name, done)
  if case_name == "metadata-undo-prepare" then return prepare(done) end
  if case_name == "metadata-undo" then return verify(done) end
  return false
end

return M
