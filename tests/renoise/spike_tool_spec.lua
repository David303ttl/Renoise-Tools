local source = assert(loadfile("tests/renoise/spike_tool/main.lua"))
local root = "Main Menu:Tools:Renoise Test Host Spike:"
local bundle_path = "C:/isolated/spike"
local log_path = bundle_path .. "/spike-observations.jsonl"
local armed_path = bundle_path .. "/spike-observations.armed"
local fixture_path = bundle_path .. "/spike-fixture.xrns"
local files = {}
local writes = 0
local removals = 0
local app_calls = {}
local menus = {}
local observables = {}
local song = { file_name = "old.xrns", identity = "song-old", transport = { bpm = 120 } }
local old_io_open, old_os_remove, old_os_date = io.open, os.remove, os.date

local function observable()
  local result = { notifiers = {} }
  function result:add_notifier(callback) self.notifiers[callback] = true end
  function result:has_notifier(callback) return self.notifiers[callback] == true end
  function result:remove_notifier(callback) self.notifiers[callback] = nil end
  function result:fire()
    local callbacks = {}
    for callback in pairs(self.notifiers) do callbacks[#callbacks + 1] = callback end
    for _, callback in ipairs(callbacks) do callback() end
  end
  return result
end

for _, name in ipairs({
  "app_release_document_observable",
  "app_new_document_observable",
  "app_became_active_observable",
  "app_resigned_active_observable",
  "app_saved_document_observable",
  "app_idle_observable",
  "tool_will_unload_observable",
  "tool_finished_loading_observable"
}) do
  observables[name] = observable()
end

local function file_handle(path, mode)
  local data = files[path] or ""
  local handle = {}
  function handle:write(value)
    data = data .. value
    files[path] = data
    return self
  end
  function handle:read(format)
    if format == "*a" then return data end
    return nil
  end
  function handle:lines()
    local lines = {}
    for line in data:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local index = 0
    return function()
      index = index + 1
      return lines[index]
    end
  end
  function handle:close() return true end
  if mode == "w" then
    writes = writes + 1
    files[path] = ""
    data = ""
  elseif mode == "a" then
    writes = writes + 1
  elseif mode ~= "r" and mode ~= "rb" then
    error("unexpected file mode " .. tostring(mode))
  elseif files[path] == nil then
    return nil, "file not found"
  end
  return handle
end

io.open = file_handle
os.remove = function(path)
  removals = removals + 1
  files[path] = nil
  return true
end
os.date = function() return "2026-01-02T03:04:05Z" end

local tool = { bundle_path = bundle_path, menu_entries = {} }
function tool:has_menu_entry(name) return self.menu_entries[name] ~= nil end
function tool:remove_menu_entry(name) self.menu_entries[name] = nil end
function tool:add_menu_entry(entry) self.menu_entries[entry.name] = entry.invoke end
for name, item in pairs(observables) do tool[name] = item end

local app = setmetatable({}, { __index = function(_, key) if key == "current_song" then return song end end })
function app:show_status(message) app_calls[#app_calls + 1] = { name = "show_status", value = message } end
function app:new_song_no_template() app_calls[#app_calls + 1] = { name = "new_song" } end
function app:load_song(path) app_calls[#app_calls + 1] = { name = "load_song", value = path } end
function app:save_song_as(path)
  files[path] = "saved fixture"
  app_calls[#app_calls + 1] = { name = "save_song_as", value = path }
end

renoise = {
  tool = function() return tool end,
  app = function() return app end,
  song = function() return setmetatable(song, { __tostring = function(value) return value.identity end }) end
}

local function invoke(name)
  local callback = tool.menu_entries[root .. name]
  assert(callback, "missing menu entry: " .. name)
  callback()
end

local function log_lines()
  local lines = {}
  for line in (files[log_path] or ""):gmatch("([^\n]+)\n") do lines[#lines + 1] = line end
  return lines
end

local function assert_event(line, flow, event, result)
  assert(line, "missing event: " .. event)
  assert(line:find('"flow":"' .. flow .. '"', 1, true), "wrong flow: " .. line)
  assert(line:find('"event":"' .. event .. '"', 1, true), "wrong event: " .. line)
  if result then assert(line:find('"result":"' .. result .. '"', 1, true), "wrong result: " .. line) end
end

local ok, err = pcall(function()
  source()
  assert(writes == 0 and removals == 0, "loading the spike must not write or remove files")
  assert(#app_calls == 0, "loading the spike must not start a host operation")
  assert(observables.app_release_document_observable:has_notifier(next(observables.app_release_document_observable.notifiers)))
  print("PASS passive load registers observers without disk or Renoise operations")

  invoke("Initialize log and create fresh test song")
  assert(files[armed_path] == "armed\n", "explicit initialization should arm observations")
  assert(app_calls[#app_calls].name == "new_song", "initialization should request a new song")
  local lines = log_lines()
  assert(#lines == 2, "initialization should record setup and request events")
  assert_event(lines[1], "async_document_lifecycle", "observation_log_initialized", "observed")
  assert_event(lines[2], "async_document_lifecycle", "request_new_song", "requested")
  print("PASS explicit initialization arms and records the asynchronous request")

  observables.app_release_document_observable:fire()
  song = { file_name = "new.xrns", identity = "song-new", transport = { bpm = 120 } }
  observables.app_new_document_observable:fire()
  lines = log_lines()
  assert_event(lines[3], "async_document_lifecycle", "app_release_document", "observed")
  assert(lines[3]:find("oldSongIdentity=0", 1, true), "release event must capture the old song")
  assert_event(lines[4], "async_document_lifecycle", "app_new_document", "observed")
  assert(lines[4]:find("generationAdvanced=true", 1, true), "new-document event must advance the document generation")
  observables.app_idle_observable:fire()
  assert(app_calls[#app_calls].name == "save_song_as", "first new-document callback should schedule fixture save")
  local fixture = app_calls[#app_calls].value
  assert(fixture:find("spike%-fixture%-.+%.xrns$"), "fixture path should be unique and disposable")
  fixture_path = fixture
  song.file_name = fixture
  observables.app_saved_document_observable:fire()
  observables.app_idle_observable:fire()
  assert(app_calls[#app_calls].name == "new_song", "successful fixture save should schedule the second new song")
  observables.app_release_document_observable:fire()
  song = { file_name = "second-new.xrns", identity = "song-second-new", transport = { bpm = 120 } }
  observables.app_new_document_observable:fire()
  observables.app_idle_observable:fire()
  assert(app_calls[#app_calls].name == "load_song" and app_calls[#app_calls].value == fixture,
    "second new-document callback should schedule the saved fixture load")
  observables.app_release_document_observable:fire()
  song = { file_name = fixture, identity = "song-loaded-fixture", transport = { bpm = 120 } }
  observables.app_new_document_observable:fire()
  lines = log_lines()
  assert_event(lines[3], "async_document_lifecycle", "app_release_document", "observed")
  assert(lines[3]:find("oldSongIdentity=0", 1, true), "release event must capture the old song")
  assert_event(lines[4], "async_document_lifecycle", "app_new_document", "observed")
  assert(lines[4]:find("generationAdvanced=true", 1, true), "new-document event must advance the document generation")
  assert_event(lines[5], "async_document_lifecycle", "request_save_fixture", "requested")
  assert_event(lines[6], "async_document_lifecycle", "app_saved_document", "observed")
  assert_event(lines[7], "async_document_lifecycle", "request_new_song", "requested")
  assert_event(lines[8], "async_document_lifecycle", "app_release_document", "observed")
  assert_event(lines[9], "async_document_lifecycle", "app_new_document", "observed")
  assert_event(lines[10], "async_document_lifecycle", "request_load_song", "requested")
  assert_event(lines[11], "async_document_lifecycle", "app_release_document", "observed")
  assert_event(lines[12], "async_document_lifecycle", "app_new_document", "observed")
  assert_event(lines[13], "async_document_lifecycle", "clean_lifecycle_probe_complete", "observed")
  print("PASS idle-driven clean lifecycle waits for save, new-song, and fixture-load observations")

  invoke("Mark current fixture dirty (tempo +1 BPM)")
  invoke("Request new song (dirty prompt flow)")
  assert(song.transport.bpm == 121, "dirty marker should alter the saved fixture tempo")
  assert_event(log_lines()[15], "dirty_document", "request_new_song", "requested")
  invoke("Record dirty prompt canceled")
  assert_event(log_lines()[16], "dirty_document", "dirty_prompt_cancel", "observed")
  assert(song.file_name == fixture_path, "Cancel should preserve the current fixture document")
  print("PASS dirty-document Cancel records the requested operation and preserves the fixture")

  song = { file_name = fixture_path, identity = "song-fixture-before-save", transport = { bpm = 120 } }
  invoke("Mark current fixture dirty (tempo +1 BPM)")
  invoke("Request new song (dirty prompt flow)")
  invoke("Record dirty prompt saved")
  observables.app_saved_document_observable:fire()
  observables.app_release_document_observable:fire()
  song = { file_name = "dirty-save.xrns", identity = "song-dirty-save", transport = { bpm = 120 } }
  observables.app_new_document_observable:fire()
  assert_event(log_lines()[19], "dirty_document", "dirty_prompt_save", "observed")

  files[fixture_path] = "fixture bytes"
  song = { file_name = fixture_path, identity = "song-fixture-before-load", transport = { bpm = 120 } }
  invoke("Mark current fixture dirty (tempo +1 BPM)")
  invoke("Load fixture (dirty prompt flow)")
  assert(app_calls[#app_calls].name == "load_song" and app_calls[#app_calls].value == fixture_path,
    "dirty load should request the existing fixture")
  invoke("Record dirty prompt discarded")
  observables.app_release_document_observable:fire()
  song = { file_name = "fixture.xrns", identity = "song-fixture", transport = { bpm = 120 } }
  observables.app_new_document_observable:fire()
  lines = log_lines()
  assert_event(lines[24], "dirty_document", "request_load_song", "requested")
  assert_event(lines[26], "dirty_document", "app_release_document", "observed")
  assert_event(lines[27], "dirty_document", "app_new_document", "observed")
  print("PASS dirty fixture load waits for document lifecycle callbacks")

  observables.app_became_active_observable:fire()
  observables.app_resigned_active_observable:fire()
  song.file_name = "saved-fixture.xrns"
  observables.app_saved_document_observable:fire()
  observables.tool_will_unload_observable:fire()
  lines = log_lines()
  assert_event(lines[16], "dirty_document", "dirty_prompt_cancel", "observed")
  assert_event(lines[19], "dirty_document", "dirty_prompt_save", "observed")
  assert_event(lines[25], "dirty_document", "dirty_prompt_discard", "observed")
  assert(lines[16]:find("operation=new_song;choice=Cancel", 1, true), "cancel evidence must identify operation and choice")
  assert(lines[19]:find("operation=new_song;choice=Save", 1, true), "save evidence must identify operation and choice")
  assert(lines[25]:find("operation=load_song;choice=Discard", 1, true), "discard evidence must identify operation and choice")
  assert_event(lines[28], "window_activation", "app_became_active", "observed")
  assert_event(lines[29], "window_activation", "app_resigned_active", "observed")
  assert_event(lines[30], "async_document_lifecycle", "app_saved_document", "observed")
  assert_event(lines[31], "async_document_lifecycle", "tool_will_unload", "observed")
  for index, line in ipairs(lines) do
    assert(line:find('"sequence":' .. index .. ",", 1, true), "event sequence must be monotonic")
  end
  print("PASS prompt, foreground, save, unload, and reload callbacks are observation-only events")

  local before_reload_writes = writes
  local before_reload_removals = removals
  source()
  assert(writes == before_reload_writes and removals == before_reload_removals,
    "reloading an armed spike must not mutate its log or marker")
  observables.tool_finished_loading_observable:fire()
  observables.app_became_active_observable:fire()
  lines = log_lines()
  assert(#lines == 33, "reloading must not leave duplicate observation callbacks registered")
  assert_event(lines[32], "async_document_lifecycle", "tool_finished_loading", "observed")
  assert_event(lines[33], "window_activation", "app_became_active", "observed")
  assert(lines[33]:find('"sequence":33,', 1, true), "reload must resume sequence from existing log")
  print("PASS reload resumes log sequence without passive file mutation")
end)

io.open, os.remove, os.date = old_io_open, old_os_remove, old_os_date
renoise = nil
if not ok then error(err) end
print("All Renoise spike mock checks passed.")
