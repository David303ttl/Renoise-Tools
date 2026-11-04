local M = {}

local SOURCE_LENGTH = 32
local PITCH_KEY = 1
local PITCH_OCTAVE = 0
local PITCH_CLASS_COUNT = 12
local FIRST_INSTRUMENT_INDEX = 1
local SECOND_INSTRUMENT_INDEX = 2
local INITIAL_PHRASE_INDEX = 1
local NEW_PHRASE_LABEL = "NEW PHRASE (append)"
local FIRST_STEP = 1
local GRID_VIEW = 2
local FIRST_PAGE = 1
local SECOND_PAGE = 2
local PAGE_SIZE = 16
local FIRST_PAGE_START = 1
local SECOND_PAGE_START = PAGE_SIZE + 1
local FIRST_SECOND_PAGE_CELL = 1
local LAST_PAGE_CELL = PAGE_SIZE
local ACTIVE_BOUNDARY_LAST_STEP = FIRST_STEP
local ACTIVE_BOUNDARY_PITCH_LENGTH = SOURCE_LENGTH
local BOUNDARY_PAIRS = {
  {last_step=FIRST_STEP,pitch_length=SOURCE_LENGTH},
  {last_step=PAGE_SIZE,pitch_length=SECOND_PAGE_START},
  {last_step=SECOND_PAGE_START,pitch_length=PAGE_SIZE},
  {last_step=SOURCE_LENGTH,pitch_length=FIRST_STEP},
}
local FIXTURE_NAME = "acceptance-gui-lifecycle.xrns"
local RELEASE_FIXTURE_NAME = "acceptance-gui-lifecycle-release.xrns"
local OPERATION_TIMEOUT_SECONDS = 10
local VALID_SCALE_TEXT = "Lifecycle Scale = 0 2 4 7 9\n"
local INVALID_SCALE_TEXT = "Lifecycle Scale without intervals\n"

local function source_pattern(sequence, key)
  local source = sequence.new_pattern(SOURCE_LENGTH)
  source.pitch_length = SOURCE_LENGTH
  for step = 1, SOURCE_LENGTH do
    source.pitch_events[step] = sequence.new_pitch((key + step - 1) % PITCH_CLASS_COUNT,
      PITCH_OCTAVE, step % 2 == 0, step % 3 == 0)
    source.time_events[step] = ({"N","T","R"})[(step - 1) % 3 + 1]
  end
  return source
end

local function same_color(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
  for index, value in ipairs(left) do
    if value ~= right[index] then return false end
  end
  return true
end

local function copy_color(color)
  local copy = {}
  for index, value in ipairs(color) do copy[index] = value end
  return copy
end

local function file_basename(path)
  return type(path) == "string" and path:gsub("\\", "/"):match("([^/]+)$") or nil
end

function M.run(done)
  local song = renoise.song()
  local tool = renoise.tool()
  local idle = tool.app_idle_observable
  local app = renoise.app()
  local original_builder, original_app = renoise.ViewBuilder, renoise.app
  local context_module = require("runtime.context")
  local original_context_new = context_module.new
  local sequence = require("model.sequencer")
  local ownership = require("renoise.phrase_ownership")
  local store = require("renoise.pattern_store")
  local writer = require("writers.phrase_writer")
  local request_factory = dofile(tool.bundle_path .. "\\__dev\\writer_request.lua")
  local instrument_index = song.selected_instrument_index
  local instrument = song.instruments[instrument_index]
  local fixture_path = tool.bundle_path .. "\\..\\fixtures\\" .. FIXTURE_NAME
  local release_fixture_path = tool.bundle_path .. "\\..\\fixtures\\" .. RELEASE_FIXTURE_NAME
  local controls, callbacks = {}, {}
  local dialogs, contexts = {}, {}
  local original_scale_preferences
  local scale_preferences_captured = false
  local pending_save_name
  local new_document_seen, new_document_notifier
  local settled, timer, pending_action = false, nil, nil
  local finish_status, finish_reason
  local first_phrase, stale_phrase
  local valid_scale_path, invalid_scale_path
  local checks = {}
  local created_fixtures = {}

  local function finish(status, reason)
    if settled then return end
    settled, finish_status, finish_reason = true, status, reason
    if timer then pcall(function() idle:remove_notifier(timer) end); timer = nil end
    if new_document_notifier then pcall(function() tool.app_new_document_observable:remove_notifier(new_document_notifier) end) end
    renoise.ViewBuilder, renoise.app = original_builder, original_app
    context_module.new = original_context_new
    if scale_preferences_captured then
      tool.preferences.custom_scales.value = original_scale_preferences
    end
    for _, dialog in ipairs(dialogs) do
      pcall(function() if dialog.visible then dialog:close() end end)
    end
    for path in pairs(created_fixtures) do pcall(os.remove, path) end
    if valid_scale_path then pcall(os.remove, valid_scale_path) end
    if invalid_scale_path then pcall(os.remove, invalid_scale_path) end
    done({status=finish_status, case="gui-lifecycle", reason=finish_reason, checks=checks})
  end

  local function later(action)
    assert(not pending_action, "a lifecycle continuation is already pending")
    pending_action = action
    if timer then return end
    timer = function()
      if settled then return end
      local continuation = pending_action
      pending_action = nil
      if not continuation then return end
      local ok, reason = pcall(continuation)
      if not ok then finish("FAIL", tostring(reason)) end
    end
    idle:add_notifier(timer)
  end

  local function wait_until(predicate, description, started, completed, diagnostic)
    started = started or os.clock()
    if predicate() then completed(); return end
    if os.clock() - started > OPERATION_TIMEOUT_SECONDS then
      error(description .. " did not complete before timeout" ..
        (diagnostic and (": " .. diagnostic()) or ""))
    end
    later(function() wait_until(predicate, description, started, completed, diagnostic) end)
  end

  local function begin_save(path, expected_name)
    local existing = io.open(path, "rb")
    if existing then existing:close(); error("disposable XRNS path already exists") end
    created_fixtures[path] = true
    pending_save_name = expected_name
    local ok, reason = pcall(function() app:save_song_as(path) end)
    assert(ok, tostring(reason))
  end

  local function wait_for_save(path, callback)
    wait_until(function()
      if file_basename(song.file_name) ~= pending_save_name then return false end
      local file = io.open(path, "rb")
      if not file then return false end
      local nonempty = file:seek("end") > 0
      file:close()
      return nonempty
    end, "native XRNS save", nil, function()
      pending_save_name = nil
      later(callback)
    end, function()
      return string.format("expected=%s current=%s",
        tostring(pending_save_name), tostring(file_basename(song.file_name)))
    end)
  end

  local function capture_gui()
    controls, callbacks = {}, {}
    local builder_factory = original_builder
    renoise.ViewBuilder = function(...)
      local builder = builder_factory(...)
      return setmetatable({}, {__index=function(_, name)
        local constructor = builder[name]
        if type(constructor) ~= "function" then return constructor end
        return function(_, properties, ...)
          local id = type(properties) == "table" and properties.id
          local notifier = type(properties) == "table" and properties.notifier
          local items = type(properties) == "table" and properties.items
          local phrase_selector = name == "popup" and type(items) == "table" and
            items[#items] == NEW_PHRASE_LABEL
          if type(notifier) == "function" then
            callbacks[id or (phrase_selector and "phrase_choice" or "")] = notifier
          end
          local view = constructor(builder, properties, ...)
          if id then controls[id] = view end
          if id then
            local ok, add_notifier = pcall(function() return view.add_notifier end)
            if ok and type(add_notifier) == "function" then
              pcall(function()
                view.add_notifier = function(_, notifier)
                  callbacks[id] = notifier
                  return add_notifier(view, notifier)
                end
              end)
            end
          end
          if phrase_selector then
            controls.phrase_choice = view
          end
          return view
        end
      end})
    end
    renoise.app = function(...)
      local native_app = original_app(...)
      return setmetatable({}, {__index=function(_, name)
        local member = native_app[name]
        if name == "show_custom_dialog" then
          return function(_, ...)
            local dialog = member(native_app, ...)
            dialogs[#dialogs+1] = dialog
            return dialog
          end
        end
        if type(member) == "function" then return function(_, ...) return member(native_app, ...) end end
        return member
      end})
    end
    context_module.new = function(...)
      local context = original_context_new(...)
      contexts[#contexts+1] = context
      return context
    end
    local ok, reason = pcall(function() require("gui").show() end)
    renoise.ViewBuilder, renoise.app = original_builder, original_app
    context_module.new = original_context_new
    assert(ok, reason)
    assert(dialogs[#dialogs] and dialogs[#dialogs].visible, "production GUI did not open")
    assert(contexts[#contexts], "production GUI did not create its runtime context")
    if not scale_preferences_captured then
      original_scale_preferences = tool.preferences.custom_scales.value
      scale_preferences_captured = true
    end
    return contexts[#contexts]
  end

  local function create_phrase(source, callback)
    local request, request_error = request_factory.build(song, instrument_index, source,
      #instrument.phrases + 1)
    assert(request, tostring(request_error))
    local start_error
    local accepted
    accepted, start_error = writer.create(request, function(result)
      later(function()
        assert(type(result) == "table" and result.kind == "success" and result.verified == true,
          "native phrase creation did not complete successfully: " .. tostring(start_error))
        callback(result.phrase)
      end)
    end)
    assert(accepted, tostring(start_error))
  end

  local function phrase_choice_index(phrase, target_instrument)
    local phrase_index
    for index, candidate in ipairs(target_instrument.phrases) do
      if rawequal(candidate, phrase) then phrase_index = index; break end
    end
    if not phrase_index then return nil end
    local prefix = string.format("%02d: ", phrase_index)
    local popup = controls.phrase_choice
    for index, label in ipairs(popup and popup.items or {}) do
      if type(label) == "string" and label:sub(1, #prefix) == prefix then
        return index
      end
    end
  end

  local function phrase_selector_diagnostic(phrase, target_instrument)
    local context = contexts[#contexts]
    local target = context and context:target_state() or {}
    local popup = controls.phrase_choice
    local item_list = popup and table.concat(popup.items or {}, " | ") or "<missing>"
    local ui_ok, ui_state = pcall(function() return require("gui").get_ui_state() end)
    local phrase_index
    for index, candidate in ipairs(target_instrument.phrases) do
      if rawequal(candidate, phrase) then phrase_index = index; break end
    end
    return string.format(
      "target=%s instrument=%s phrase=%s expected_index=%s popup_value=%s items=%s ui=%s observers=%s idle=%s native_instrument=%s",
      tostring(target.kind), tostring(rawequal(target.instrument, target_instrument)),
      tostring(rawequal(target.phrase, phrase)), tostring(phrase_index),
      tostring(popup and popup.value), item_list,
      tostring(ui_ok and ui_state.dialog_visible),
      tostring(ui_ok and ui_state.native_observers_attached),
      tostring(ui_ok and ui_state.idle_listener_attached), tostring(song.selected_instrument_index))
  end

  local function document_release_diagnostic()
    local ui_ok, ui_state = pcall(function() return require("gui").get_ui_state() end)
    return string.format("song_changed=%s ui=%s observers=%s idle=%s",
      tostring(not rawequal(renoise.song(), song)),
      tostring(ui_ok and ui_state.dialog_visible),
      tostring(ui_ok and ui_state.native_observers_attached),
      tostring(ui_ok and ui_state.idle_listener_attached))
  end

  local function choose_phrase(phrase, target_instrument)
    local popup = assert(controls.phrase_choice, "production phrase selector was not captured")
    local callback = assert(callbacks.phrase_choice, "production phrase selector callback was not captured")
    local selected = assert(phrase_choice_index(phrase, target_instrument),
      "native phrase was missing from the production selector")
    popup.value = selected
    callback(selected)
    local target = contexts[#contexts]:target_state()
    assert(target.kind == "owned" and rawequal(target.phrase, phrase),
      "production phrase selector did not bind the exact native phrase")
  end

  local function choose_instrument(target_instrument)
    local context = assert(contexts[#contexts], "production runtime context was not captured")
    local choices = assert(context:instrument_choices(), "production instrument choices are unavailable")
    local selected
    for index, choice in ipairs(choices) do
      if rawequal(choice.instrument, target_instrument) then selected = index; break end
    end
    assert(selected, "native instrument was missing from the production selector")
    local popup = assert(controls.acid_instrument, "production instrument selector was not captured")
    local callback = assert(callbacks.acid_instrument, "production instrument selector callback was not captured")
    popup.value = selected
    callback(selected)
    local target = context:target_state()
    assert(target.instrument and rawequal(target.instrument, target_instrument),
      "production instrument selector did not bind the exact native instrument")
  end

  local function expect_unchanged(raw, snapshots)
    assert(song.tool_data == raw, "native target change wrote ACID storage")
    for phrase, snapshot in pairs(snapshots) do
      assert(ownership.compare(snapshot, assert(ownership.snapshot(phrase))),
        "native target change mutated a phrase")
    end
  end

  local function verify_boundaries(canonical)
    local source_copy = assert(sequence.copy_source(canonical))
    local function set_value(id, value)
      local control = assert(controls[id], "production boundary control was not captured: " .. id)
      local callback = assert(callbacks[id], "production boundary callback was not captured: " .. id)
      control.value = value
      callback(value)
    end
    local function check_page(kind, page)
      local id = "acid_" .. kind .. "_page_" .. page
      local control = assert(controls[id], "production page control was not captured: " .. id)
      local callback = assert(callbacks[id], "production page callback was not captured: " .. id)
      callback()
      local page_start = page == SECOND_PAGE and SECOND_PAGE_START or FIRST_PAGE_START
      local page_end = page_start + PAGE_SIZE - 1
      local range = string.format("%02d-%02d", page_start, page_end)
      assert(control.text:find(range, 1, true),
        "production " .. kind .. " page label did not show its selected range")
      assert(control.text:find("[*]", 1, true), "production " .. kind .. " page was not highlighted")
    end
    local function check_selected_position(memory, first_cell, last_cell)
      local grid_prefix = memory == "pitch" and "acid_grid_pitch_" or "acid_grid_select_time_"
      local program_prefix = memory == "pitch" and "acid_program_select_pitch_" or
        "acid_program_select_time_"
      local program_page_id = memory == "pitch" and "acid_program_pitch_page_2" or
        "acid_program_time_page_2"
      callbacks[grid_prefix .. string.format("%02d", first_cell)]()
      local first_color = copy_color(controls[grid_prefix .. string.format("%02d", first_cell)].color)
      callbacks[grid_prefix .. string.format("%02d", last_cell)]()
      local last_color = copy_color(controls[grid_prefix .. string.format("%02d", last_cell)].color)
      local cleared_color = controls[grid_prefix .. string.format("%02d", first_cell)].color
      assert(same_color(first_color, last_color) and not same_color(first_color, cleared_color),
        memory:upper() .. " Grid selection did not move from position 17 to 32")
      set_value("acid_editor_view", 1)
      callbacks[program_page_id]()
      local program_cell = controls[program_prefix .. string.format("%02d", last_cell)]
      assert(same_color(program_cell.color, controls[program_page_id].color) and
        same_color(program_cell.color, last_color),
        memory:upper() .. " Program selection did not retain position 32 and its page")
      set_value("acid_editor_view", 2)
      assert(same_color(controls[grid_prefix .. string.format("%02d", last_cell)].color, last_color),
        memory:upper() .. " Grid selection did not restore position 32")
    end
    local function check_pair(pair)
      set_value("acid_last_step", pair.last_step)
      set_value("acid_pitch_length", pair.pitch_length)
      local source = assert(store.read_draft(song, instrument, first_phrase),
        "boundary control change did not persist its source draft")
      assert(source.length == pair.last_step and source.pitch_length == pair.pitch_length,
        "production boundary controls did not preserve unequal lengths")
      local expected = assert(sequence.copy_source(source_copy))
      expected.length, expected.pitch_length = pair.last_step, pair.pitch_length
      assert(sequence.same_source(expected, source),
        "boundary control changed active or inactive memory")
      check_page("pitch", FIRST_PAGE)
      check_page("time", FIRST_PAGE)
      check_page("pitch", SECOND_PAGE)
      check_page("time", SECOND_PAGE)
      check_selected_position("pitch", FIRST_SECOND_PAGE_CELL, LAST_PAGE_CELL)
      check_selected_position("time", FIRST_SECOND_PAGE_CELL, LAST_PAGE_CELL)
      local pitch17 = assert(controls.acid_grid_pitch_header_01).text
      local pitch32 = assert(controls["acid_grid_pitch_header_" .. string.format("%02d", LAST_PAGE_CELL)]).text
      assert((pitch17:find("inactive", 1, true) ~= nil) == (pair.pitch_length < SECOND_PAGE_START),
        "PITCH position 17 did not show the correct active state")
      assert((pitch32:find("inactive", 1, true) ~= nil) == (pair.pitch_length < SOURCE_LENGTH),
        "PITCH position 32 did not show the correct active state")
      local time17 = assert(controls.acid_grid_select_time_01).text
      local time32 = assert(controls["acid_grid_select_time_" .. string.format("%02d", LAST_PAGE_CELL)]).text
      assert((time17:sub(-2) == " *") == (pair.last_step < SECOND_PAGE_START),
        "TIME position 17 did not show the correct active state")
      assert((time32:sub(-2) == " *") == (pair.last_step < SOURCE_LENGTH),
        "TIME position 32 did not show the correct active state")
      local raw = song.tool_data
      callbacks.acid_grid_select_time_01()
      callbacks.acid_grid_pitch_01()
      assert(song.tool_data == raw, "boundary navigation changed durable song data")
      source = assert(store.read_draft(song, instrument, first_phrase))
      expected = assert(sequence.copy_source(source_copy))
      expected.length, expected.pitch_length = pair.last_step, pair.pitch_length
      assert(sequence.same_source(expected, source), "boundary navigation changed source memory")
      if pair.last_step == ACTIVE_BOUNDARY_LAST_STEP and
          pair.pitch_length == ACTIVE_BOUNDARY_PITCH_LENGTH then
        local pair_source = assert(sequence.copy_source(source))
        local expected = assert(sequence.copy_source(source))
        local original_pitch = source.pitch_events[SOURCE_LENGTH]
        local original_key = original_pitch.key
        local changed_key = (original_key + 1) % PITCH_CLASS_COUNT
        callbacks["acid_grid_pitch_" .. string.format("%02d", LAST_PAGE_CELL)]()
        callbacks["acid_grid_key_" .. string.format("%02d", changed_key + 1)]()
        expected.pitch_events[SOURCE_LENGTH] = sequence.new_pitch(changed_key,
          original_pitch.octave, original_pitch.accent, original_pitch.slide)
        source = assert(store.read_draft(song, instrument, first_phrase))
        assert(sequence.same_source(expected, source),
          "active PITCH position 32 Grid edit changed unrelated memory")
        callbacks["acid_grid_key_" .. string.format("%02d", original_key + 1)]()
        source = assert(store.read_draft(song, instrument, first_phrase))
        assert(sequence.same_source(pair_source, source),
          "active PITCH position 32 did not restore its original source")
      end
    end
    local original_view = controls.acid_editor_view.value
    set_value("acid_editor_view", GRID_VIEW)
    for _, pair in ipairs(BOUNDARY_PAIRS) do check_pair(pair) end
    set_value("acid_last_step", SOURCE_LENGTH)
    set_value("acid_pitch_length", SOURCE_LENGTH)
    set_value("acid_editor_view", original_view)
    local source = assert(store.read_draft(song, instrument, first_phrase))
    assert(sequence.same_source(source_copy, source), "boundary checks did not restore the original source")
    checks.native_unequal_length_boundaries = true
  end

  local function with_prompt(answer, action)
    renoise.app = function(...)
      local native_app = original_app(...)
      return setmetatable({}, {__index=function(_, name)
        if name == "show_prompt" then
          return function() return answer end
        end
        local member = native_app[name]
        if type(member) == "function" then return function(_, ...) return member(native_app, ...) end end
        return member
      end})
    end
    local ok, reason = pcall(action)
    renoise.app = original_app
    assert(ok, reason)
  end

  local function import_scale(path)
    renoise.app = function(...)
      local current_app = original_app(...)
      return setmetatable({}, {__index=function(_, name)
        if name == "prompt_for_filename_to_read" then
          return function() return path end
        end
        local member = current_app[name]
        if type(member) == "function" then return function(_, ...) return member(current_app, ...) end end
        return member
      end})
    end
    local ok, reason = pcall(callbacks.acid_scale_import)
    renoise.app = original_app
    assert(ok, tostring(reason))
  end

  local function run_acceptance()
    assert(instrument and #instrument.phrases == 0, "requires an empty selected instrument")
    local context, first_id, saved_draft, first_snapshot, stale_snapshot

    local function verify_restored_song()
      checks.document_release_closed_gui = true
      local reopened_song = renoise.song()
      local reopened_instrument = reopened_song.instruments[instrument_index]
      local reopened_phrase
      for _, phrase in ipairs(reopened_instrument.phrases) do
        if ownership.id(phrase) == first_id then reopened_phrase = phrase; break end
      end
      assert(reopened_phrase, "saved XRNS did not restore the generated phrase identity")
      local restored_draft = assert(store.read_draft(reopened_song, reopened_instrument, reopened_phrase))
      assert(sequence.same_source(saved_draft, restored_draft),
        "saved XRNS did not restore the ungenerated GUI draft")
      checks.xrns_restored_ungenerated_draft = true
      context = capture_gui()
      choose_instrument(reopened_instrument)
      wait_until(function()
        local target = context:target_state()
        return target.instrument and rawequal(target.instrument, reopened_instrument) and
          phrase_choice_index(reopened_phrase, reopened_instrument) ~= nil
      end, "reopened phrase selector refresh", nil, function()
        choose_phrase(reopened_phrase, reopened_instrument)
        assert(sequence.same_source(saved_draft, assert(context:editor_state()).source),
          "production GUI did not automatically restore the saved draft")
        checks.gui_automatically_restored_draft = true
        valid_scale_path, invalid_scale_path = os.tmpname(), os.tmpname()
        local valid_file = assert(io.open(valid_scale_path, "wb"))
        assert(valid_file:write(VALID_SCALE_TEXT)); assert(valid_file:close())
        local invalid_file = assert(io.open(invalid_scale_path, "wb"))
        assert(invalid_file:write(INVALID_SCALE_TEXT)); assert(invalid_file:close())
        import_scale(valid_scale_path)
        local imported_preferences = tool.preferences.custom_scales.value
        assert(imported_preferences:find("Lifecycle Scale", 1, true),
          "production Import did not persist the parsed temporary scale file")
        checks.production_scale_import_succeeded = true
        import_scale(invalid_scale_path)
        assert(tool.preferences.custom_scales.value == imported_preferences and
          tostring(controls.acid_status.text):find("Invalid scale file", 1, true),
          "invalid scale import changed preferences or omitted production feedback")
        checks.invalid_scale_import_feedback = true
        local phrase_snapshot = assert(ownership.snapshot(reopened_phrase))
        callbacks.acid_generate()
        wait_until(function()
          local current_id = ownership.id(reopened_phrase)
          local committed = current_id and store.read_entry(reopened_song, current_id)
          local snapshot = ownership.snapshot(reopened_phrase)
          return committed and sequence.same_source(saved_draft, committed) and
            snapshot and not ownership.compare(phrase_snapshot, snapshot)
        end, "native generation from restored draft", nil, function()
          checks.native_generation_from_restored_draft = true
          finish("PASS")
        end)
      end, function() return phrase_selector_diagnostic(reopened_phrase, reopened_instrument) end)
    end

    local function load_saved_fixture()
      new_document_seen = false
      new_document_notifier = function() new_document_seen = true end
      tool.app_new_document_observable:add_notifier(new_document_notifier)
      app:load_song(fixture_path)
      wait_until(function()
        local ui_state = require("gui").get_ui_state()
        return new_document_seen and not rawequal(renoise.song(), song) and
          ui_state.dialog_visible == false and ui_state.native_observers_attached == false and
          ui_state.idle_listener_attached == false
      end, "song document release", nil, function()
        tool.app_new_document_observable:remove_notifier(new_document_notifier)
        new_document_notifier = nil
        verify_restored_song()
      end, document_release_diagnostic)
    end

    local function verify_deleted_target(inserted)
      choose_phrase(stale_phrase, instrument)
      with_prompt("Proceed", callbacks.acid_program_reenter_pitch)
      for _ = 1, SOURCE_LENGTH do callbacks.acid_program_enter() end
      assert(controls.acid_program_finish.active, "complete staged source did not enable Finish")
      local stale_index
      for index, phrase in ipairs(instrument.phrases) do
        if rawequal(phrase, stale_phrase) then stale_index = index; break end
      end
      assert(stale_index, "staged native target disappeared before deletion check")
      local raw_before_delete = song.tool_data
      instrument:delete_phrase_at(stale_index)
      assert(context:target_state().kind == "unavailable",
        "native target deletion left the editor bound to a valid target")
      callbacks.acid_program_finish()
      expect_unchanged(raw_before_delete, {
        [first_phrase]=first_snapshot,
        [inserted]=assert(ownership.snapshot(inserted)),
      })
      later(function()
        assert(not controls.acid_program_finish.active,
          "stale staged candidate remained eligible for Finish after target deletion")
        checks.deleted_target_finish_rejected = true
        with_prompt("Cancel", callbacks.acid_program_discard)
        begin_save(release_fixture_path, RELEASE_FIXTURE_NAME)
        wait_for_save(release_fixture_path, load_saved_fixture)
      end)
    end

    local function verify_reorder()
      local raw_before_reorder = song.tool_data
      local inserted = instrument:insert_phrase_at(INITIAL_PHRASE_INDEX)
      inserted.name = "Lifecycle foreign phrase"
      local target = context:target_state()
      assert(target.kind == "owned" and rawequal(target.phrase, first_phrase) and
        target.phrase_index == INITIAL_PHRASE_INDEX + 1,
        "native phrase reordering rebound the GUI target by index")
      expect_unchanged(raw_before_reorder, {
        [first_phrase]=first_snapshot,
        [stale_phrase]=stale_snapshot,
      })
      assert(sequence.same_source(saved_draft, assert(store.read_draft(song, instrument, first_phrase))),
        "phrase reorder lost the first draft")
      checks.native_phrase_reordering_safe = true
      begin_save(fixture_path, FIXTURE_NAME)
      wait_for_save(fixture_path, function()
        checks.xrns_saved_with_ungenerated_draft = true
        choose_instrument(instrument)
        wait_until(function() return phrase_choice_index(stale_phrase, instrument) ~= nil end,
          "reordered phrase selector refresh", nil, function() verify_deleted_target(inserted) end,
          function() return phrase_selector_diagnostic(stale_phrase, instrument) end)
      end)
    end

    local function verify_instrument_selection()
      local other_index = instrument_index == FIRST_INSTRUMENT_INDEX and
        SECOND_INSTRUMENT_INDEX or FIRST_INSTRUMENT_INDEX
      assert(song.instruments[other_index], "native selection fixture requires another instrument")
      local raw_before_selection = song.tool_data
      song.selected_instrument_index = other_index
      later(function()
        assert(song.selected_instrument_index == other_index, "native instrument selection did not change")
        song.selected_instrument_index = instrument_index
        later(function()
          assert(song.selected_instrument_index == instrument_index,
            "native instrument selection did not return to the source instrument")
          choose_instrument(instrument)
          wait_until(function()
            local target = context:target_state()
            return target.instrument and rawequal(target.instrument, instrument) and
              phrase_choice_index(first_phrase, instrument) ~= nil
          end, "native phrase selector refresh", nil, function()
            choose_phrase(first_phrase, instrument)
            assert(sequence.same_source(saved_draft,
              assert(store.read_draft(song, instrument, first_phrase))),
              "native instrument selection lost the dirty first draft")
            expect_unchanged(raw_before_selection, {
              [first_phrase]=first_snapshot,
              [stale_phrase]=stale_snapshot,
            })
            checks.native_instrument_selection_rebound = true
            verify_reorder()
          end, function() return phrase_selector_diagnostic(first_phrase, instrument) end)
        end)
      end)
    end

    local function verify_gui_draft(created_stale)
      stale_phrase = created_stale
      context = capture_gui()
      choose_phrase(first_phrase, instrument)
      first_id = assert(ownership.id(first_phrase))
      local canonical = assert(store.read_entry(song, first_id))
      verify_boundaries(canonical)
      local changed_key = canonical.pitch_events[1].key + 1
      assert(changed_key < PITCH_CLASS_COUNT, "fixture pitch cannot be incremented safely")
      assert(callbacks["acid_program_key_" .. string.format("%02d", changed_key + 1)],
        "production Program key callback was not captured")()
      local draft = assert(store.read_draft(song, instrument, first_phrase))
      assert(not sequence.same_source(canonical, draft), "GUI edit did not persist an ungenerated draft")
      saved_draft = assert(sequence.copy_source(draft))
      checks.ungenerated_draft_created = true
      first_snapshot = assert(ownership.snapshot(first_phrase))
      stale_snapshot = assert(ownership.snapshot(stale_phrase))
      verify_instrument_selection()
    end

    create_phrase(source_pattern(sequence, PITCH_KEY), function(created_first)
      first_phrase = created_first
      create_phrase(source_pattern(sequence, PITCH_KEY + 1), verify_gui_draft)
    end)
  end

  if not instrument then
    finish("FAIL", "selected native instrument is unavailable")
    return true
  end
  local ok, reason = pcall(run_acceptance)
  if not ok then finish("FAIL", tostring(reason)) end
  return true
end

return M
