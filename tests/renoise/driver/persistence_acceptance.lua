local M = {}
local SOURCE_ID = 1
local SOURCE_LENGTH = 4
local DRAFT_LENGTH = 3
local PB_RANGE = 0
local LABEL = "Failure baseline"
local CHANGED_LABEL = "Changed label"
local THIRD_VALUE = "injected third-party storage"
local INSTRUMENT_NAME = "Persistence failure fixture"

function M.failures(done)
  local song = renoise.song()
  local store = require("renoise.pattern_store")
  local sequence = require("model.sequencer")
  local ownership = require("renoise.phrase_ownership")
  local original_is_current = ownership.is_current
  local original_song = renoise.song
  local context
  local checks = {}
  local previous = song.tool_data
  local proxy, mode, writes
  local ok, reason = pcall(function()
    local instrument = song.instruments[song.selected_instrument_index]
    assert(instrument and #instrument.phrases == 0, "requires an empty disposable instrument")
    assert(previous == nil or previous == "", "requires empty disposable song data")
    instrument.name=INSTRUMENT_NAME
    local phrase = instrument:insert_phrase_at(1)
    phrase.name = assert(ownership.make_name(phrase, SOURCE_ID))
    local source = sequence.new_pattern(SOURCE_LENGTH)
    local draft = sequence.new_pattern(DRAFT_LENGTH)
    assert(store.save(song, SOURCE_ID, source, "repeat", PB_RANGE))
    assert(store.update_label(song, instrument, phrase, LABEL, true, song.tool_data,
      source, "repeat", PB_RANGE))
    assert(store.write_draft_metadata(song, instrument, phrase, draft, "repeat", PB_RANGE, LABEL, true))
    local baseline = song.tool_data
    local snapshot = assert(ownership.snapshot(phrase))
    local phrase_name = phrase.name
    proxy = setmetatable({}, {
      __index = function(_, key)
        local value=song[key]
        if type(value)=="function" then return function(_,...)return value(song,...)end end
        return value
      end,
      __newindex = function(_, key, value)
        assert(key == "tool_data", "fault proxy only permits tool data writes")
        writes = writes + 1
        if mode == "before" then error("injected failure before storage mutation", 0) end
        song.tool_data = mode == "third" and THIRD_VALUE or value
        if mode == "after" then error("injected failure after storage mutation", 0) end
      end,
    })
    ownership.is_current = function(candidate)
      if rawequal(candidate, proxy) then
        return rawequal(original_song(), song) or nil, "Native acceptance document changed"
      end
      return original_is_current(candidate)
    end
    local function native_unchanged()
      assert(#instrument.phrases == 1 and rawequal(instrument.phrases[1], phrase),
        "failure changed native phrase inventory")
      assert(phrase.name == phrase_name and ownership.compare(snapshot, assert(ownership.snapshot(phrase))),
        "failure changed native phrase preimage")
    end
    local function labels_unchanged()
      local _, _, _, label, custom = store.read_entry(song, SOURCE_ID)
      assert(label == LABEL and custom == true, "failure changed canonical label")
      local saved, _, _, pending, pending_custom = store.read_draft(song, instrument, phrase)
      assert(saved and saved.length == DRAFT_LENGTH and pending == LABEL and pending_custom == true,
        "failure changed saved draft or label")
    end
    writes = 0
    assert(not store.update_label(proxy, instrument, phrase, CHANGED_LABEL, true, "stale raw",
      draft, "repeat", PB_RANGE))
    assert(writes == 0 and song.tool_data == baseline, "stale metadata attempted storage mutation")
    checks.stale_metadata_zero_writes = true
    for _, fault in ipairs({"before", "after", "third"}) do
      song.tool_data = baseline
      mode, writes = fault, 0
      local saved, _, outcome = store.update_label(proxy, instrument, phrase, CHANGED_LABEL, true,
        baseline, draft, "repeat", PB_RANGE)
      assert(not saved, "injected failure returned success")
      if fault == "third" then
        assert(outcome == store.LABEL_WRITE_UNCERTAIN and song.tool_data == THIRD_VALUE and writes == 1,
          "uncertain storage was overwritten or accepted")
      else
        assert(outcome == store.LABEL_WRITE_UNCHANGED and song.tool_data == baseline,
          "failed write did not preserve exact previous bytes")
        assert(writes == (fault == "after" and 2 or 1), "unexpected failure write count")
        labels_unchanged()
      end
      native_unchanged()
      checks[fault] = true
    end
    mode = nil
    song.tool_data = baseline
    labels_unchanged()
    renoise.song = function() return proxy end
    context = require("runtime.context").new({
      writer = require("writers.phrase_writer"),
      capture = function() return nil, "acceptance does not generate" end,
      sink = function() return false, "acceptance does not audition" end,
    })
    context:attach_document(proxy)
    context:open_dialog()
    context:bind_new(instrument)
    assert(context:restore_editor_target(instrument, nil), "cannot install pending editor source")
    local context_baseline = song.tool_data
    mode, writes = "third", 0
    local renamed,rename_error=context:rename_label(CHANGED_LABEL, true)
    assert(not renamed, "uncertain editor rename succeeded")
    assert(context:integrity_state().blocked and song.tool_data == THIRD_VALUE,
      "uncertain editor rename did not block integrity: "..tostring(rename_error).."; writes="..tostring(writes))
    local blocked_writes = writes
    assert(not context:rename_label("Blocked rename", true) and writes == blocked_writes,
      "blocked editor attempted another metadata write")
    mode = nil
    song.tool_data = context_baseline
    assert(context:integrity_state().blocked, "byte restoration cleared blocker implicitly")
    assert(context:integrity_state().blocked, "byte restoration cleared blocker implicitly")
    assert(not context:rename_label("Still blocked", true) and writes == blocked_writes,
      "restored bytes allowed writes after integrity failure")
    checks.sticky_blocker_survives_storage_restore = true
    checks.no_retry_after_integrity_failure = true    native_unchanged()
    checks.native_phrase_preimage = true
    checks.canonical_and_draft_cache_isolation = true
  end)
  if context then pcall(function() context:release_document() end) end
  renoise.song = original_song
  ownership.is_current = original_is_current
  local restored = pcall(function() song.tool_data = previous end)
  done({status = ok and restored and "PASS" or "FAIL", case = "persistence-failures",
    reason = not ok and tostring(reason) or (not restored and "failed to restore tool data" or nil),
    injection = "synthetic setter faults forwarding native song storage", checks = checks})
  return true
end

return M
