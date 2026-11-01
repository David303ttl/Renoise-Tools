local script_directory = arg[0]:match("^(.*[/\\])") or ""
local probe_path = script_directory .. "probe/main.lua"
local temp_root = os.getenv("TEMP") or os.getenv("TMP") or "."
local config_path = temp_root .. "\\acid-fixture-probe.conf"
local bundle_path = temp_root .. "\\acid-fixture-probe-spec.xrnx"
local path_counter = 0

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function new_observable()
  local observable = { notifiers = {} }
  function observable:add_notifier(notifier)
    assert(not self.notifiers[notifier], "duplicate notifier")
    self.notifiers[notifier] = true
  end
  function observable:has_notifier(notifier)
    return self.notifiers[notifier] == true
  end
  function observable:remove_notifier(notifier)
    assert(self.notifiers[notifier], "notifier was not attached")
    self.notifiers[notifier] = nil
  end
  function observable:fire()
    local callbacks = {}
    for notifier in pairs(self.notifiers) do callbacks[#callbacks + 1] = notifier end
    for _, notifier in ipairs(callbacks) do
      if self.notifiers[notifier] then notifier() end
    end
  end
  function observable:count()
    local count = 0
    for _ in pairs(self.notifiers) do count = count + 1 end
    return count
  end
  return observable
end

local function unique_path(extension)
  path_counter = path_counter + 1
  local path = temp_root .. "\\acid_probe_spec_" .. tostring(os.time()) .. "_" .. tostring(path_counter) .. extension
  os.remove(path)
  return path
end

local function to_hex(text)
  local bytes = {}
  for index = 1, #text do bytes[#bytes + 1] = string.format("%02x", string.byte(text, index)) end
  return table.concat(bytes)
end

local function empty_note_column()
  return {
    note_value = 121,
    instrument_value = 255,
    volume_value = 255,
    panning_value = 255,
    delay_value = 0,
    effect_number_value = 0,
    effect_amount_value = 0
  }
end

local function empty_effect_column()
  return { number_value = 0, amount_value = 0 }
end

local function make_phrase(name, options)
  local phrase = {
    name = name or "",
    number_of_lines = 16,
    lpb = 4,
    shuffle = 0,
    looping = false,
    loop_start = 1,
    loop_end = 16,
    playback_mode = 1,
    key_tracking = 1,
    base_note = 48,
    autoseek = false,
    visible_note_columns = 1,
    visible_effect_columns = 0,
    instrument_column_visible = false,
    volume_column_visible = false,
    panning_column_visible = false,
    delay_column_visible = false,
    sample_effects_column_visible = false
  }
  phrase.note_column_names = {}
  phrase.note_column_muted = {}
  for column_index = 1, 12 do
    phrase.note_column_names[column_index] = ""
    phrase.note_column_muted[column_index] = false
  end
  local lines = {}
  for line_index = 1, 512 do
    local note_columns, effect_columns = {}, {}
    for column_index = 1, 12 do note_columns[column_index] = empty_note_column() end
    for column_index = 1, 8 do effect_columns[column_index] = empty_effect_column() end
    lines[line_index] = { note_columns = note_columns, effect_columns = effect_columns }
  end
  if options.drop_line and options.drop_note_column and options.drop_field then
    local target = lines[options.drop_line]
    if target then
      local real = target.note_columns[options.drop_note_column]
      target.note_columns[options.drop_note_column] = setmetatable({}, {
        __index = function(_, key) return real[key] end,
        __newindex = function(_, key, value)
          if key ~= options.drop_field then real[key] = value end
        end
      })
    end
  end
  phrase.lines = lines
  function phrase:line(index) return lines[index] end
  function phrase:column_name(index) return self.note_column_names[index] end
  function phrase:set_column_name(index, name) self.note_column_names[index] = name end
  function phrase:column_is_muted(index) return self.note_column_muted[index] end
  function phrase:set_column_is_muted(index, muted) self.note_column_muted[index] = muted end
  return phrase
end

local function make_instrument(name, options)
  local instrument = { name = name or "", phrases = {}, phrase_mappings = {} }
  function instrument:insert_phrase_at(index)
    local phrase = make_phrase("", options)
    table.insert(self.phrases, index, phrase)
    return phrase
  end
  function instrument:delete_phrase_at(index) table.remove(self.phrases, index) end
  function instrument:insert_phrase_mapping_at(index, phrase)
    local mapping = {
      phrase = phrase,
      key_tracking = 1,
      base_note = 48,
      note_range = { 0, 119 },
      looping = false,
      loop_start = 1,
      loop_end = 16
    }
    table.insert(self.phrase_mappings, index, mapping)
    phrase.mapping = mapping
    return mapping
  end
  return instrument
end

local function make_song(options)
  local song = { file_name = "", tool_data = nil, transport = { bpm = 110 }, instruments = {}, insert_calls = 0, delete_calls = 0 }
  function song:insert_instrument_at(index)
    self.insert_calls = self.insert_calls + 1
    local instrument = make_instrument("", options)
    table.insert(self.instruments, index, instrument)
    return instrument
  end
  function song:delete_instrument_at(index)
    self.delete_calls = self.delete_calls + 1
    if #self.instruments <= 1 then error("Renoise needs at least one instrument") end
    table.remove(self.instruments, index)
  end
  song:insert_instrument_at(1)
  song.insert_calls = 0
  return song
end

local function install_host(options)
  options = options or {}
  local state = {
    idle = new_observable(),
    new_document = new_observable(),
    new_song_calls = 0,
    save_calls = {},
    pending_new_song = false
  }
  state.song = make_song(options)
  local tool = {
    bundle_path = bundle_path,
    app_idle_observable = state.idle,
    app_new_document_observable = state.new_document
  }
  local app = {}
  function app:new_song_no_template()
    state.new_song_calls = state.new_song_calls + 1
    state.pending_new_song = true
  end
  function app:save_song_as(path)
    state.save_calls[#state.save_calls + 1] = path
    state.song.file_name = path
    if options.save_never_appears then return end
    local file, open_error = io.open(path, "wb")
    assert(file, open_error)
    file:write("fixture-xrns")
    file:close()
  end
  _G.renoise = {
    API_VERSION = 6.2,
    RENOISE_VERSION = "3.5.4",
    app = function() return app end,
    song = function() return state.song end,
    tool = function() return tool end,
    InstrumentPhrase = {
      PLAY_PATTERN = 1,
      PLAY_SCRIPT = 2,
      KEY_TRACKING_NONE = 1,
      KEY_TRACKING_TRANSPOSE = 2,
      KEY_TRACKING_OFFSET = 3,
      MAX_NUMBER_OF_LINES = 512
    },
    InstrumentPhraseMapping = {
      KEY_TRACKING_NONE = 1,
      KEY_TRACKING_TRANSPOSE = 2,
      KEY_TRACKING_OFFSET = 3
    }
  }
  function state:complete_new_song()
    state.song = make_song(options)
    state.pending_new_song = false
    state.new_document:fire()
  end
  return state
end

local function write_configuration(target, manifest, tool_data_hex, nonce)
  local file, open_error = io.open(config_path, "wb")
  assert(file, open_error)
  file:write(table.concat({
    "target=" .. target,
    "manifest=" .. manifest,
    "tool_data_hex=" .. tool_data_hex,
    "nonce=" .. nonce
  }, "\n") .. "\n")
  file:close()
end

local function load_probe()
  local ok, result = pcall(dofile, probe_path)
  assert(ok, result)
end

local host_globals = {
  assert = true,
  error = true,
  getmetatable = true,
  io = true,
  ipairs = true,
  math = true,
  os = true,
  pairs = true,
  pcall = true,
  print = true,
  rawequal = true,
  renoise = true,
  select = true,
  setmetatable = true,
  string = true,
  table = true,
  tonumber = true,
  tostring = true,
  type = true
}

-- Renoise exposes no writable globals to a tool script: reading or writing an
-- undeclared name raises "variable 'X' is not declared". The sandbox only
-- resolves the host globals above and maps _G to itself so nested lookups are
-- strict too.
local function make_strict_environment()
  local sandbox = {}
  local function undeclared(key)
    error("variable '" .. tostring(key) .. "' is not declared", 2)
  end
  setmetatable(sandbox, {
    __index = function(_, key)
      if key == "_G" then return sandbox end
      if host_globals[key] then return _G[key] end
      return undeclared(key)
    end,
    __newindex = function(_, key)
      return undeclared(key)
    end
  })
  return sandbox
end

local function load_probe_in(environment)
  local chunk, load_error
  if setfenv then
    chunk, load_error = loadfile(probe_path)
    if chunk then setfenv(chunk, environment) end
  else
    chunk, load_error = loadfile(probe_path, "t", environment)
  end
  assert(chunk, load_error)
  local ok, result = pcall(chunk)
  assert(ok, result)
end

local function assert_undeclared_rejected(environment, source, name)
  local chunk
  if setfenv then
    chunk = assert(loadstring(source))
    setfenv(chunk, environment)
  else
    chunk = assert(load(source, "strict environment check", "t", environment))
  end
  local ok, result = pcall(chunk)
  assert(not ok, "strict environment accepted: " .. source)
  local expected = "variable '" .. name .. "' is not declared"
  assert(tostring(result):find(expected, 1, true), "unexpected strict error for " .. source .. ": " .. tostring(result))
end

local function with_restored_global_metatable(callback)
  local saved = getmetatable(_G)
  local ok, result = pcall(callback)
  setmetatable(_G, saved)
  assert(getmetatable(_G) == saved, "global metatable was not restored")
  assert(ok, result)
end

local function read_pairs(path)
  local values = {}
  local file = io.open(path, "rb")
  if not file then return nil end
  for line in file:lines() do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then values[key] = value end
  end
  file:close()
  return values
end

local function marker_path(target) return target .. ".done" end

local function advance_to_build(state)
  state.idle:fire()
  state:complete_new_song()
  state.idle:fire()
  state.idle:fire()
end

local tests = {}
local function test(name, callback) tests[#tests + 1] = { name = name, callback = callback } end

test("missing sidecar leaves the tool idle", function()
  local state = install_host()
  os.remove(config_path)
  load_probe()
  assert_equal(state.idle:count(), 0, "idle notifier registered without a sidecar")
  assert_equal(state.new_document:count(), 0, "document notifier registered without a sidecar")
  state.idle:fire()
  assert_equal(state.new_song_calls, 0, "new song requested without a sidecar")
  assert_equal(#state.song.instruments, 1, "instruments changed without a sidecar")
  assert_equal(#state.save_calls, 0, "save requested without a sidecar")
end)

test("malformed sidecars leave the tool idle", function()
  local cases = {
    "target=\nmanifest=m\ntool_data_hex=00\nnonce=aa\n",
    "target=t\nmanifest=m\ntool_data_hex=0\nnonce=aa\n",
    "target=t\nmanifest=m\ntool_data_hex=zz\nnonce=aa\n",
    "target=t\nmanifest=m\ntool_data_hex=00\nnonce=zz\n",
    "target=t\nmanifest=m\ntool_data_hex=00\n",
    "target=t\nmanifest=m\ntool_data_hex=00\nnonce=aa\nunknown=value\n"
  }
  for index, contents in ipairs(cases) do
    local state = install_host()
    local file = assert(io.open(config_path, "wb"))
    file:write(contents)
    file:close()
    load_probe()
    assert_equal(state.idle:count(), 0, "idle notifier registered for malformed sidecar " .. tostring(index))
    assert_equal(state.new_document:count(), 0, "document notifier registered for malformed sidecar " .. tostring(index))
    state.idle:fire()
    assert_equal(state.new_song_calls, 0, "new song requested for malformed sidecar " .. tostring(index))
    assert_equal(#state.save_calls, 0, "save requested for malformed sidecar " .. tostring(index))
  end
  os.remove(config_path)
end)

test("happy path builds, saves, and confirms the fixture", function()
  local target = unique_path(".xrns")
  local manifest = unique_path(".txt")
  local payload = "ACID-PITCH-TIME-1\n2|repeat|24|triplet|3|17|fixture\n"
  local nonce = string.rep("ab", 16)
  local state = install_host()
  write_configuration(target, manifest, to_hex(payload), nonce)
  load_probe()

  assert_equal(state.new_song_calls, 0, "new song requested during tool load")
  assert_equal(state.idle:count(), 1, "idle notifier was not registered")
  assert_equal(state.new_document:count(), 1, "document notifier was not registered")
  assert_equal(state.song.delete_calls, 0, "song mutated during tool load")

  state.idle:fire()
  assert_equal(state.new_song_calls, 1, "new song was not requested from idle")
  assert_equal(state.song.delete_calls, 0, "song mutated before the new document arrived")

  state:complete_new_song()
  state.idle:fire()
  state.idle:fire()

  assert_equal(#state.save_calls, 0, "save happened before verification")
  assert_equal(#state.song.instruments, 2, "fixture does not contain two instruments")
  assert_equal(state.song.transport.bpm, 120)
  assert(state.song.delete_calls >= 1, "existing instruments were not deleted")
  assert_equal(state.song.insert_calls, 2, "fixture instruments were not inserted")

  local instrument1, instrument2 = state.song.instruments[1], state.song.instruments[2]
  local phrase1, phrase2 = instrument1.phrases[1], instrument1.phrases[2]
  local mapping = instrument1.phrase_mappings[1]
  assert_equal(instrument1.name, "Fixture Lead")
  assert_equal(instrument2.name, "Fixture Pad")
  assert_equal(#instrument2.phrases, 0, "Fixture Pad has phrases")
  assert_equal(#instrument2.phrase_mappings, 0, "Fixture Pad has mappings")
  assert_equal(phrase1.name, "fixture-snapshot-phrase")
  assert_equal(phrase1.number_of_lines, 16)
  assert_equal(phrase1.lpb, 4)
  assert_equal(phrase1.shuffle, 0)
  assert_equal(phrase1.looping, true)
  assert_equal(phrase1.loop_start, 1)
  assert_equal(phrase1.loop_end, 16)
  assert_equal(phrase1.playback_mode, 1)
  assert_equal(phrase1.key_tracking, 1)
  assert_equal(phrase1.base_note, 48)
  assert_equal(phrase1.autoseek, false)
  assert_equal(phrase1.visible_note_columns, 1)
  assert_equal(phrase1.visible_effect_columns, 1)
  assert_equal(phrase1.instrument_column_visible, false)
  assert_equal(phrase1.volume_column_visible, true)
  assert_equal(phrase1.panning_column_visible, false)
  assert_equal(phrase1.delay_column_visible, false)
  assert_equal(phrase1.sample_effects_column_visible, false)

  local line1 = phrase1:line(1)
  assert_equal(line1.note_columns[1].note_value, 48)
  assert_equal(line1.note_columns[1].instrument_value, 255)
  assert_equal(line1.note_columns[1].volume_value, 96)
  assert_equal(line1.note_columns[1].panning_value, 128)
  assert_equal(line1.note_columns[1].delay_value, 2)
  assert_equal(line1.note_columns[1].effect_number_value, 0)
  assert_equal(line1.note_columns[1].effect_amount_value, 0)
  assert_equal(line1.note_columns[2].note_value, 60)
  assert_equal(line1.note_columns[2].instrument_value, 255)
  assert_equal(line1.note_columns[2].volume_value, 255)
  assert_equal(line1.note_columns[2].panning_value, 255)
  assert_equal(line1.note_columns[2].delay_value, 0)
  assert_equal(line1.note_columns[2].effect_number_value, 0)
  assert_equal(line1.note_columns[2].effect_amount_value, 0)
  assert_equal(phrase1:line(4).effect_columns[1].number_value, 12)
  assert_equal(phrase1:line(4).effect_columns[1].amount_value, 64)
  assert_equal(phrase1:line(4).effect_columns[2].number_value, 13)
  assert_equal(phrase1:line(4).effect_columns[2].amount_value, 65)
  assert_equal(phrase1:line(64).note_columns[1].note_value, 36)
  assert_equal(phrase1:line(64).note_columns[1].instrument_value, 255)
  assert_equal(phrase1:line(64).note_columns[1].volume_value, 255)
  assert_equal(phrase1:line(64).note_columns[1].panning_value, 255)
  assert_equal(phrase1:line(64).note_columns[1].delay_value, 0)
  assert_equal(phrase1:line(64).note_columns[1].effect_number_value, 0)
  assert_equal(phrase1:line(64).note_columns[1].effect_amount_value, 0)
  assert_equal(phrase1:line(64).effect_columns[8].number_value, 14)
  assert_equal(phrase1:line(64).effect_columns[8].amount_value, 70)
  assert_equal(phrase1:column_name(1), "fixture-note-01")
  assert_equal(phrase1:column_is_muted(1), false)
  assert_equal(phrase1:column_name(2), "fixture-note-02")
  assert_equal(phrase1:column_is_muted(2), true)
  assert_equal(phrase1:column_name(12), "fixture-note-12")
  assert_equal(phrase1:column_is_muted(12), false)

  assert_equal(mapping.phrase, phrase1)
  assert_equal(mapping.key_tracking, 2)
  assert_equal(mapping.base_note, 48)
  assert_equal(mapping.note_range[1], 36)
  assert_equal(mapping.note_range[2], 60)
  assert_equal(mapping.looping, false)
  assert_equal(mapping.loop_start, 1)
  assert_equal(mapping.loop_end, 16)

  assert_equal(phrase2.name, "fixture-plain-arp")
  assert_equal(phrase2.number_of_lines, 8)
  assert_equal(phrase2.lpb, 4)
  assert_equal(phrase2.shuffle, 0)
  assert_equal(phrase2.looping, false)
  assert_equal(phrase2.loop_start, 1)
  assert_equal(phrase2.loop_end, 8)
  assert_equal(phrase2.playback_mode, 1)
  assert_equal(phrase2.key_tracking, 1)
  assert_equal(phrase2.base_note, 48)
  assert_equal(phrase2.autoseek, false)
  assert_equal(phrase2.visible_note_columns, 1)
  assert_equal(phrase2.visible_effect_columns, 0)
  assert_equal(phrase2.instrument_column_visible, false)
  assert_equal(phrase2.volume_column_visible, false)
  assert_equal(phrase2.panning_column_visible, false)
  assert_equal(phrase2.delay_column_visible, false)
  assert_equal(phrase2.sample_effects_column_visible, false)
  assert_equal(phrase2:line(1).note_columns[1].note_value, 57)
  assert_equal(phrase2:line(1).note_columns[1].volume_value, 96)
  assert_equal(phrase2:line(3).note_columns[1].note_value, 64)
  assert_equal(phrase2:line(3).note_columns[1].volume_value, 96)
  assert_equal(phrase2:line(5).note_columns[1].note_value, 69)
  assert_equal(phrase2:line(5).note_columns[1].volume_value, 64)
  assert_equal(phrase2:column_name(1), "plain-note-01")
  assert_equal(phrase2:column_is_muted(1), false)
  assert_equal(phrase2:column_name(12), "plain-note-12")
  assert_equal(phrase2:column_is_muted(12), false)

  local manifest_values = read_pairs(manifest)
  assert(manifest_values, "values manifest was not written")
  assert_equal(manifest_values["transport.bpm"], "120")
  assert_equal(manifest_values["instruments.1.name"], "Fixture Lead")
  assert_equal(manifest_values["instruments.1.phrases.1.name"], "fixture-snapshot-phrase")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.number_of_lines"], "16")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.lpb"], "4")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.shuffle"], "0")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.looping"], "true")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.loop_start"], "1")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.loop_end"], "16")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.playback_mode"], "1")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.key_tracking"], "1")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.base_note"], "48")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.autoseek"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.visible_note_columns"], "1")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.visible_effect_columns"], "1")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.instrument_column_visible"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.volume_column_visible"], "true")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.panning_column_visible"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.delay_column_visible"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.properties.sample_effects_column_visible"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.1.note_columns.1.note_value"], "48")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.1.note_columns.1.volume_value"], "96")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.1.note_columns.2.note_value"], "60")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.4.effect_columns.1.number_value"], "12")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.4.effect_columns.1.amount_value"], "64")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.4.effect_columns.2.number_value"], "13")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.4.effect_columns.2.amount_value"], "65")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.64.note_columns.1.note_value"], "36")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.64.effect_columns.8.number_value"], "14")
  assert_equal(manifest_values["instruments.1.phrases.1.lines.64.effect_columns.8.amount_value"], "70")
  assert_equal(manifest_values["instruments.1.phrases.1.note_columns.1.name"], "fixture-note-01")
  assert_equal(manifest_values["instruments.1.phrases.1.note_columns.1.muted"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.note_columns.2.name"], "fixture-note-02")
  assert_equal(manifest_values["instruments.1.phrases.1.note_columns.2.muted"], "true")
  assert_equal(manifest_values["instruments.1.phrases.1.note_columns.12.name"], "fixture-note-12")
  assert_equal(manifest_values["instruments.1.phrases.1.note_columns.12.muted"], "false")
  assert_equal(manifest_values["instruments.1.phrases.2.note_columns.1.name"], "plain-note-01")
  assert_equal(manifest_values["instruments.1.phrases.2.note_columns.1.muted"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.mapping.key_tracking"], "2")
  assert_equal(manifest_values["instruments.1.phrases.1.mapping.base_note"], "48")
  assert_equal(manifest_values["instruments.1.phrases.1.mapping.note_range.1"], "36")
  assert_equal(manifest_values["instruments.1.phrases.1.mapping.note_range.2"], "60")
  assert_equal(manifest_values["instruments.1.phrases.1.mapping.looping"], "false")
  assert_equal(manifest_values["instruments.1.phrases.1.mapping.loop_start"], "1")
  assert_equal(manifest_values["instruments.1.phrases.1.mapping.loop_end"], "16")
  assert_equal(manifest_values["instruments.1.phrases.2.name"], "fixture-plain-arp")
  assert_equal(manifest_values["instruments.2.name"], "Fixture Pad")
  assert_equal(manifest_values["tool_data_length"], tostring(#payload))

  assert(not read_pairs(marker_path(target)), "completion marker was written before confirmation")
  state.idle:fire()
  assert_equal(#state.save_calls, 1, "save_song_as was not called once")
  assert_equal(state.save_calls[1], target, "save_song_as used the wrong target")
  assert_equal(state.song.tool_data, payload, "tool_data does not match the decoded payload")
  assert(not read_pairs(marker_path(target)), "completion marker was written before the file was confirmed")

  state.idle:fire()
  local marker = read_pairs(marker_path(target))
  assert(marker, "completion marker was not written")
  assert_equal(marker.status, "ok")
  assert_equal(marker.bytes, "12")
  assert_equal(marker.nonce, nonce)
  assert_equal(state.idle:count(), 0, "idle notifier was not removed")
  assert_equal(state.new_document:count(), 0, "document notifier was not removed")

  os.remove(target)
  os.remove(marker_path(target))
  os.remove(manifest)
  os.remove(config_path)
end)

test("readback mismatch reports unsupported without saving", function()
  local target = unique_path(".xrns")
  local manifest = unique_path(".txt")
  local payload = "ACID-PITCH-TIME-1\n2|repeat|24|triplet|3|17|fixture\n"
  local state = install_host({ drop_line = 64, drop_note_column = 1, drop_field = "note_value" })
  write_configuration(target, manifest, to_hex(payload), string.rep("cd", 16))
  load_probe()
  advance_to_build(state)

  local marker = read_pairs(marker_path(target))
  assert(marker, "completion marker was not written for a mismatch")
  assert_equal(marker.status, "unsupported")
  assert_equal(marker.detail, "instruments.1.phrases.1.lines.64.note_columns.1.note_value")
  assert_equal(#state.save_calls, 0, "save_song_as was called despite a mismatch")
  assert_equal(state.idle:count(), 0, "idle notifier was not removed")
  assert_equal(state.new_document:count(), 0, "document notifier was not removed")
  assert(read_pairs(manifest), "values manifest was not written before verification")

  os.remove(marker_path(target))
  os.remove(manifest)
  os.remove(config_path)
end)

test("unconfirmed save eventually reports an error", function()
  local target = unique_path(".xrns")
  local manifest = unique_path(".txt")
  local payload = "ACID-PITCH-TIME-1\n2|repeat|24|triplet|3|17|fixture\n"
  local state = install_host({ save_never_appears = true })
  write_configuration(target, manifest, to_hex(payload), string.rep("ef", 16))
  load_probe()
  advance_to_build(state)
  state.idle:fire()
  assert_equal(#state.save_calls, 1, "save_song_as was not called")
  for _ = 1, 700 do
    state.idle:fire()
    if read_pairs(marker_path(target)) then break end
  end

  local marker = read_pairs(marker_path(target))
  assert(marker, "completion marker was not written after the timeout")
  assert_equal(marker.status, "error")
  assert_equal(marker.detail, "completion confirmation timed out")
  assert_equal(state.idle:count(), 0, "idle notifier was not removed")
  assert_equal(state.new_document:count(), 0, "document notifier was not removed")

  os.remove(marker_path(target))
  os.remove(manifest)
  os.remove(target)
  os.remove(config_path)
end)

test("strict global environment rejects undeclared reads and writes", function()
  with_restored_global_metatable(function()
    local environment = make_strict_environment()
    assert_undeclared_rejected(environment, "return acid_strict_undeclared_read", "acid_strict_undeclared_read")
    assert_undeclared_rejected(environment, "acid_strict_undeclared_write = true", "acid_strict_undeclared_write")
    assert_undeclared_rejected(environment, "return _G.__acid_native_fixture_probe_started", "__acid_native_fixture_probe_started")
    assert_undeclared_rejected(environment, "_G.__acid_native_fixture_probe_started = true", "__acid_native_fixture_probe_started")
  end)
end)

test("probe loads without starting under a strict global environment", function()
  with_restored_global_metatable(function()
    local state = install_host()
    os.remove(config_path)
    load_probe_in(make_strict_environment())

    assert_equal(state.idle:count(), 0, "idle notifier registered without a sidecar")
    assert_equal(state.new_document:count(), 0, "document notifier registered without a sidecar")
    state.idle:fire()
    assert_equal(state.new_song_calls, 0, "new song requested without a sidecar")
    assert_equal(#state.save_calls, 0, "save requested without a sidecar")
  end)
end)

test("happy path completes under a strict global environment", function()
  with_restored_global_metatable(function()
    local target = unique_path(".xrns")
    local manifest = unique_path(".txt")
    local payload = "ACID-PITCH-TIME-1\n2|repeat|24|triplet|3|17|fixture\n"
    local nonce = string.rep("ab", 16)
    local state = install_host()
    write_configuration(target, manifest, to_hex(payload), nonce)
    load_probe_in(make_strict_environment())

    assert_equal(state.idle:count(), 1, "idle notifier was not registered")
    assert_equal(state.new_document:count(), 1, "document notifier was not registered")
    assert_equal(state.song.delete_calls, 0, "song mutated during tool load")

    state.idle:fire()
    assert_equal(state.new_song_calls, 1, "new song was not requested from idle")
    state:complete_new_song()
    state.idle:fire()
    state.idle:fire()
    assert_equal(state.song.tool_data, nil, "tool_data was written before the save phase")
    assert(read_pairs(manifest), "values manifest was not written during the build")

    state.idle:fire()
    assert_equal(#state.save_calls, 1, "save_song_as was not called")
    assert_equal(state.song.tool_data, payload, "tool_data does not match the decoded payload")

    state.idle:fire()
    local marker = read_pairs(marker_path(target))
    assert(marker, "completion marker was not written")
    assert_equal(marker.status, "ok")
    assert_equal(marker.bytes, "12")
    assert_equal(marker.nonce, nonce)
    assert_equal(state.idle:count(), 0, "idle notifier was not removed")
    assert_equal(state.new_document:count(), 0, "document notifier was not removed")

    os.remove(target)
    os.remove(marker_path(target))
    os.remove(manifest)
    os.remove(config_path)
  end)
end)

for _, case in ipairs(tests) do
  local ok, result = xpcall(case.callback, debug.traceback)
  if not ok then
    io.stderr:write("FAIL " .. case.name .. ": " .. tostring(result) .. "\n")
    os.exit(1)
  end
  print("ok " .. case.name)
end
print("probe spec passed")
