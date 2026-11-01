-- Isolated-host behavior probe. This tool records observations only; it does
-- not certify the profile or write trusted preflight evidence.
local tool = renoise.tool()
local root = "Main Menu:Tools:Renoise Test Host Spike:"
local log_path = tool.bundle_path .. "/spike-observations.jsonl"
local armed_path = tool.bundle_path .. "/spike-observations.armed"
local state_path = tool.bundle_path .. "/spike-observations.state"
local sequence = 0
local active_flow = "async_document_lifecycle"
local armed = false
local old_song_identity = ""
local registrations = {}
local operation_state = "idle"
local current_fixture_path = ""
local pending_dirty_operation = "unknown"
local song_generation = 0
local menu_names = {
  "Initialize log and create fresh test song",
  "Save current song as disposable fixture",
  "Mark current fixture dirty (tempo +1 BPM)",
  "Request new song (clean flow)",
  "Request new song (dirty prompt flow)",
  "Load fixture (dirty prompt flow)",
  "Load fixture (clean flow)",
  "Record dirty prompt canceled",
  "Record dirty prompt saved",
  "Record dirty prompt discarded"
}

local function escape_json(value)
  value = tostring(value or "")
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  value = value:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
  return value
end

local function current_song_snapshot()
  local ok, song = pcall(function() return renoise.app().current_song end)
  if not ok then return "", "unavailable", tostring(song) end
  if not song then return "", "none", "Application current_song is nil" end
  local identity = song_generation
  local file_ok, file_name = pcall(function() return song.file_name end)
  if not file_ok then return "", tostring(identity), tostring(file_name) end
  return file_name or "", tostring(identity), ""
end

local function comparable_path(path)
  return tostring(path or ""):gsub("\\", "/"):gsub("/+", "/"):gsub("/+$", ""):lower()
end

local function append(flow, event_name, result, detail, artifact_path)
  if not armed then return false end
  sequence = sequence + 1
  local current_file, current_identity, diagnostic = current_song_snapshot()
  local file, err = io.open(log_path, "a")
  if not file then
    renoise.app():show_status("Spike log write failed: " .. tostring(err))
    return false
  end
  local text = string.format(
    '{"sequence":%d,"flow":"%s","result":"%s","observedAtUtc":"%s","event":"%s","songFile":"%s","songIdentity":"%s","details":"%s","diagnostic":"%s","artifactPath":"%s"}\n',
    sequence,
    escape_json(flow),
    escape_json(result),
    escape_json(os.date("!%Y-%m-%dT%H:%M:%SZ")),
    escape_json(event_name),
    escape_json(current_file),
    escape_json(current_identity),
    escape_json(detail),
    escape_json(diagnostic),
    escape_json(artifact_path or "")
  )
  file:write(text)
  file:close()
  return true
end

local function menu(name, callback)
  local full_name = root .. name
  if tool:has_menu_entry(full_name) then tool:remove_menu_entry(full_name) end
  tool:add_menu_entry({name = full_name, invoke = callback})
end

local function register(observable, callback)
  observable:add_notifier(callback)
  registrations[#registrations + 1] = {observable = observable, callback = callback}
end

local function request_new_song(flow, detail)
  active_flow = flow
  pending_dirty_operation = flow == "dirty_document" and "new_song" or pending_dirty_operation
  append(flow, "request_new_song", "requested", detail)
  renoise.app():new_song_no_template()
end

local function fixture_path()
  return current_fixture_path
end

local function load_fixture(detail)
  local path = fixture_path()
  if path == "" then
    renoise.app():show_status("Initialize the spike before loading a fixture.")
    return
  end
  local file = io.open(path, "rb")
  if not file then
    renoise.app():show_status("The disposable fixture is missing from this tool folder.")
    append("async_document_lifecycle", "fixture_missing", "failed", path)
    return
  end
  file:close()
  active_flow = detail:find("dirty_prompt_flow", 1, true) and "dirty_document" or "async_document_lifecycle"
  pending_dirty_operation = active_flow == "dirty_document" and "load_song" or pending_dirty_operation
  append(active_flow, "request_load_song", "requested", detail .. ";path=" .. path)
  renoise.app():load_song(path)
end

menu(menu_names[1], function()
  armed = false
  os.remove(armed_path)
  sequence = 0
  local file, err = io.open(log_path, "w")
  if not file then
    renoise.app():show_status("Spike log initialization failed: " .. tostring(err))
    return
  end
  file:close()
  local marker, marker_err = io.open(armed_path, "w")
  if not marker then
    os.remove(log_path)
    renoise.app():show_status("Spike marker write failed: " .. tostring(marker_err))
    return
  end
  marker:write("armed\n")
  marker:close()
  armed = true
  active_flow = "async_document_lifecycle"
  operation_state = "initial_new_waiting"
  local suffix = 0
  repeat
    local stamp = os.date("!%Y%m%dT%H%M%SZ")
    local indexed = suffix == 0 and stamp or (stamp .. "-" .. tostring(suffix))
    current_fixture_path = tool.bundle_path .. "/spike-fixture-" .. indexed .. ".xrns"
    suffix = suffix + 1
    local existing = io.open(current_fixture_path, "rb")
    if existing then existing:close() else break end
  until false
  local state_file, state_error = io.open(state_path, "w")
  if not state_file then
    armed = false
    os.remove(armed_path)
    os.remove(log_path)
    renoise.app():show_status("Spike state write failed: " .. tostring(state_error))
    return
  end
  state_file:write(current_fixture_path .. "\n")
  state_file:close()
  append("async_document_lifecycle", "observation_log_initialized", "observed", "raw observations; no verification flags")
  append("async_document_lifecycle", "request_new_song", "requested", "initialize_fresh_test_song")
  renoise.app():show_status("Creating a fresh test song. Resolve any Renoise save prompt deliberately.")
  renoise.app():new_song_no_template()
end)
menu(menu_names[2], function()
  if fixture_path() == "" then
    renoise.app():show_status("Initialize the spike before saving a fixture.")
    return
  end
  append("async_document_lifecycle", "request_save_fixture", "requested", fixture_path())
  renoise.app():save_song_as(fixture_path())
end)
menu(menu_names[3], function()
  local song = renoise.app().current_song
  if fixture_path() == "" or comparable_path(song.file_name) ~= comparable_path(fixture_path()) then
    renoise.app():show_status("Only the disposable fixture saved by this spike can be modified.")
    return
  end
  local old_bpm = song.transport.bpm
  if old_bpm >= 999 then
    renoise.app():show_status("Fixture tempo is already at the maximum. Restore it below 999 BPM first.")
    return
  end
  song.transport.bpm = old_bpm + 1
  append("dirty_document", "fixture_marked_dirty", "observed", "file=" .. song.file_name .. ";bpm=" .. tostring(old_bpm) .. "->" .. tostring(song.transport.bpm))
  renoise.app():show_status("Disposable fixture tempo changed by 1 BPM; verify the unsaved state in Renoise.")
end)
menu(menu_names[4], function() request_new_song("async_document_lifecycle", "clean_flow") end)
menu(menu_names[5], function() request_new_song("dirty_document", "dirty_prompt_flow;cancel_after_observing_prompt") end)
menu(menu_names[6], function() load_fixture("dirty_prompt_flow;operator_must_observe_dialog_then_choose_Cancel") end)
menu(menu_names[7], function() load_fixture("clean_flow") end)
menu(menu_names[8], function()
  append("dirty_document", "dirty_prompt_cancel", "observed", "operation=" .. pending_dirty_operation .. ";choice=Cancel; operator confirmed prompt and old document preserved")
  pending_dirty_operation = "unknown"
end)
menu(menu_names[9], function()
  append("dirty_document", "dirty_prompt_save", "observed", "operation=" .. pending_dirty_operation .. ";choice=Save; operator confirmed prompt and operation continued")
  pending_dirty_operation = "unknown"
end)
menu(menu_names[10], function()
  append("dirty_document", "dirty_prompt_discard", "observed", "operation=" .. pending_dirty_operation .. ";choice=Discard; operator confirmed prompt and operation continued")
  pending_dirty_operation = "unknown"
end)

local function on_release()
  local _, identity = current_song_snapshot()
  old_song_identity = identity
  append(active_flow, "app_release_document", "observed", "oldSongIdentity=" .. old_song_identity)
end
local function on_new_document()
  song_generation = song_generation + 1
  local _, current_identity = current_song_snapshot()
  local changed = old_song_identity ~= "" and old_song_identity ~= current_identity
  append(active_flow, "app_new_document", "observed", "oldSongIdentity=" .. old_song_identity .. ";currentSongIdentity=" .. current_identity .. ";generationAdvanced=" .. tostring(changed))
  old_song_identity = ""
  if operation_state == "initial_new_waiting" then
    operation_state = "save_fixture_pending"
  elseif operation_state == "clean_new_waiting" then
    operation_state = "load_fixture_pending"
  elseif operation_state == "clean_load_waiting" then
    operation_state = "idle"
    append("async_document_lifecycle", "clean_lifecycle_probe_complete", "observed", "new song and fixture load callbacks observed")
  end
  active_flow = "async_document_lifecycle"
end
local function on_active() append("window_activation", "app_became_active", "observed", "Renoise reported foreground activation") end
local function on_resigned() append("window_activation", "app_resigned_active", "observed", "Renoise reported foreground loss") end
local function on_unload()
  append("async_document_lifecycle", "tool_will_unload", "observed", "tool reload or application exit")
  for _, registration in ipairs(registrations) do
    if registration.observable:has_notifier(registration.callback) then
      registration.observable:remove_notifier(registration.callback)
    end
  end
  registrations = {}
end
local function on_saved()
  local saved_path = current_song_snapshot()
  append("async_document_lifecycle", "app_saved_document", "observed", saved_path)
  if operation_state == "saving_fixture" then
    operation_state = "clean_new_pending"
  end
end
local function on_idle()
  if not armed then return end
  if operation_state == "save_fixture_pending" then
    operation_state = "saving_fixture"
    append("async_document_lifecycle", "request_save_fixture", "requested", fixture_path())
    renoise.app():save_song_as(fixture_path())
  elseif operation_state == "clean_new_pending" then
    operation_state = "clean_new_waiting"
    append("async_document_lifecycle", "request_new_song", "requested", "clean_lifecycle_probe")
    renoise.app():new_song_no_template()
  elseif operation_state == "load_fixture_pending" then
    operation_state = "clean_load_waiting"
    append("async_document_lifecycle", "request_load_song", "requested", "clean_lifecycle_probe;path=" .. fixture_path())
    renoise.app():load_song(fixture_path())
  end
end
local function on_loaded()
  if not armed then return end
  append("async_document_lifecycle", "tool_finished_loading", "observed", "tool load or reload")
end

local marker = io.open(armed_path, "r")
if marker then
  armed = marker:read("*a") == "armed\n"
  marker:close()
end
local state_file = io.open(state_path, "r")
if state_file then
  current_fixture_path = (state_file:read("*l") or "")
  state_file:close()
end
if armed then
  local existing = io.open(log_path, "r")
  if existing then
    for _ in existing:lines() do sequence = sequence + 1 end
    existing:close()
  else
    armed = false
  end
end
local _, initial_identity = current_song_snapshot()
old_song_identity = initial_identity

register(tool.app_release_document_observable, on_release)
register(tool.app_new_document_observable, on_new_document)
register(tool.app_became_active_observable, on_active)
register(tool.app_resigned_active_observable, on_resigned)
register(tool.app_saved_document_observable, on_saved)
register(tool.app_idle_observable, on_idle)
register(tool.tool_will_unload_observable, on_unload)
register(tool.tool_finished_loading_observable, on_loaded)

