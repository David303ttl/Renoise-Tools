-- Development-only native fixture probe. It builds a deterministic disposable
-- song and saves it once the host confirms the new document is current.
local tool = renoise.tool()
local probe_started = false

local function join_path(base, relative)
  local clean_base = tostring(base or ""):gsub("[\\/]+$", "")
  local clean_relative = tostring(relative or ""):gsub("[/]", "\\")
  return clean_base .. "\\" .. clean_relative
end

local function read_configuration(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  if type(contents) ~= "string" then return nil end

  local allowed = {
    target = true,
    manifest = true,
    tool_data_hex = true,
    nonce = true
  }
  local values = {}
  for line in contents:gmatch("[^\r\n]+") do
    local key, value = line:match("^([a-z_]+)=(.*)$")
    if not key or not allowed[key] or values[key] or value == "" or value:find("%z") then
      return nil
    end
    values[key] = value
  end
  for key in pairs(allowed) do
    if not values[key] then return nil end
  end
  if not values.tool_data_hex:match("^[0-9a-f]+$") or #values.tool_data_hex % 2 ~= 0 then
    return nil
  end
  if not values.nonce:match("^[0-9a-f]+$") then return nil end

  local bytes = {}
  for index = 1, #values.tool_data_hex, 2 do
    bytes[#bytes + 1] = string.char(tonumber(values.tool_data_hex:sub(index, index + 1), 16))
  end
  return {
    target = values.target,
    manifest = values.manifest,
    tool_data = table.concat(bytes),
    nonce = values.nonce
  }
end

if probe_started then return end
local configuration = read_configuration(join_path(tool.bundle_path, "..\\acid-fixture-probe.conf"))
if not configuration then return end
probe_started = true

local phase = "fresh"
local started = false
local active = true
local idle_count = 0
local marker_written = false
local new_document_seen = false
local registrations = {}

local function detach()
  for _, registration in ipairs(registrations) do
    local observable, callback = registration[1], registration[2]
    if observable:has_notifier(callback) then observable:remove_notifier(callback) end
  end
  registrations = {}
end

local function write_marker(status, detail, bytes)
  if marker_written then return end
  marker_written = true
  active = false
  detach()
  local lines = { "status=" .. status }
  if detail then lines[#lines + 1] = "detail=" .. (tostring(detail):gsub("[\r\n]+", " ")) end
  if bytes then lines[#lines + 1] = "bytes=" .. tostring(bytes) end
  lines[#lines + 1] = "nonce=" .. configuration.nonce
  local file = io.open(configuration.target .. ".done", "wb")
  if not file then return end
  file:write(table.concat(lines, "\n") .. "\n")
  file:close()
end

local records = {}

local function record(path, expected, read)
  records[#records + 1] = { path = path, expected = expected, read = read }
end

local function write_note_column(prefix, column, values)
  column.note_value = values.note_value
  record(prefix .. ".note_value", values.note_value, function() return column.note_value end)
  column.instrument_value = values.instrument_value
  record(prefix .. ".instrument_value", values.instrument_value, function() return column.instrument_value end)
  column.volume_value = values.volume_value
  record(prefix .. ".volume_value", values.volume_value, function() return column.volume_value end)
  column.panning_value = values.panning_value
  record(prefix .. ".panning_value", values.panning_value, function() return column.panning_value end)
  column.delay_value = values.delay_value
  record(prefix .. ".delay_value", values.delay_value, function() return column.delay_value end)
  column.effect_number_value = values.effect_number_value
  record(prefix .. ".effect_number_value", values.effect_number_value, function() return column.effect_number_value end)
  column.effect_amount_value = values.effect_amount_value
  record(prefix .. ".effect_amount_value", values.effect_amount_value, function() return column.effect_amount_value end)
end

local function write_effect_column(prefix, column, values)
  column.number_value = values.number_value
  record(prefix .. ".number_value", values.number_value, function() return column.number_value end)
  column.amount_value = values.amount_value
  record(prefix .. ".amount_value", values.amount_value, function() return column.amount_value end)
end

local function write_phrase_properties(prefix, phrase, values)
  phrase.name = values.name
  record(prefix .. ".name", values.name, function() return phrase.name end)
  phrase.number_of_lines = values.number_of_lines
  record(prefix .. ".properties.number_of_lines", values.number_of_lines, function() return phrase.number_of_lines end)
  phrase.lpb = values.lpb
  record(prefix .. ".properties.lpb", values.lpb, function() return phrase.lpb end)
  phrase.shuffle = values.shuffle
  record(prefix .. ".properties.shuffle", values.shuffle, function() return phrase.shuffle end)
  phrase.looping = values.looping
  record(prefix .. ".properties.looping", values.looping, function() return phrase.looping end)
  phrase.loop_end = values.loop_end
  record(prefix .. ".properties.loop_end", values.loop_end, function() return phrase.loop_end end)
  phrase.loop_start = values.loop_start
  record(prefix .. ".properties.loop_start", values.loop_start, function() return phrase.loop_start end)
  phrase.playback_mode = values.playback_mode
  record(prefix .. ".properties.playback_mode", values.playback_mode, function() return phrase.playback_mode end)
  phrase.key_tracking = values.key_tracking
  record(prefix .. ".properties.key_tracking", values.key_tracking, function() return phrase.key_tracking end)
  phrase.base_note = values.base_note
  record(prefix .. ".properties.base_note", values.base_note, function() return phrase.base_note end)
  phrase.autoseek = values.autoseek
  record(prefix .. ".properties.autoseek", values.autoseek, function() return phrase.autoseek end)
  phrase.visible_note_columns = values.visible_note_columns
  record(prefix .. ".properties.visible_note_columns", values.visible_note_columns, function() return phrase.visible_note_columns end)
  phrase.visible_effect_columns = values.visible_effect_columns
  record(prefix .. ".properties.visible_effect_columns", values.visible_effect_columns, function() return phrase.visible_effect_columns end)
  phrase.instrument_column_visible = values.instrument_column_visible
  record(prefix .. ".properties.instrument_column_visible", values.instrument_column_visible, function() return phrase.instrument_column_visible end)
  phrase.volume_column_visible = values.volume_column_visible
  record(prefix .. ".properties.volume_column_visible", values.volume_column_visible, function() return phrase.volume_column_visible end)
  phrase.panning_column_visible = values.panning_column_visible
  record(prefix .. ".properties.panning_column_visible", values.panning_column_visible, function() return phrase.panning_column_visible end)
  phrase.delay_column_visible = values.delay_column_visible
  record(prefix .. ".properties.delay_column_visible", values.delay_column_visible, function() return phrase.delay_column_visible end)
  phrase.sample_effects_column_visible = values.sample_effects_column_visible
  record(prefix .. ".properties.sample_effects_column_visible", values.sample_effects_column_visible, function() return phrase.sample_effects_column_visible end)
end

local function write_phrase_columns(prefix, phrase, label, muted_column)
  for column_index = 1, 12 do
    local name = string.format("%s-note-%02d", label, column_index)
    phrase:set_column_name(column_index, name)
    record(prefix .. ".note_columns." .. column_index .. ".name", name, function()
      return phrase:column_name(column_index)
    end)
    local muted = column_index == muted_column
    phrase:set_column_is_muted(column_index, muted)
    record(prefix .. ".note_columns." .. column_index .. ".muted", muted, function()
      return phrase:column_is_muted(column_index)
    end)
  end
end

local function write_values_manifest()
  local lines = {}
  for _, item in ipairs(records) do
    lines[#lines + 1] = item.path .. "=" .. tostring(item.expected)
  end
  lines[#lines + 1] = "tool_data_length=" .. tostring(#configuration.tool_data)
  local file, open_error = io.open(configuration.manifest, "wb")
  if not file then error("values manifest write failed: " .. tostring(open_error)) end
  file:write(table.concat(lines, "\n") .. "\n")
  file:close()
end

local function verify_records()
  for _, item in ipairs(records) do
    local ok, actual = pcall(item.read)
    if not ok or actual ~= item.expected then return item.path end
  end
  return nil
end

local function verify_structure(song, instrument1, instrument2)
  if #song.instruments ~= 2 then return "instruments.count" end
  if #instrument1.phrases ~= 2 then return "instruments.1.phrases.count" end
  if #instrument1.phrase_mappings ~= 1 then return "instruments.1.phrase_mappings.count" end
  if #instrument2.phrases ~= 0 then return "instruments.2.phrases.count" end
  if #instrument2.phrase_mappings ~= 0 then return "instruments.2.phrase_mappings.count" end
  return nil
end

local function build_fixture(song)
  song.transport.bpm = 120
  record("transport.bpm", 120, function() return song.transport.bpm end)

  while #song.instruments > 0 do
    local before = #song.instruments
    local deleted, delete_error = pcall(function() song:delete_instrument_at(1) end)
    if not deleted then
      -- Renoise refuses to remove its last instrument; the leftover slot is
      -- removed after the two fixture instruments have been inserted.
      if before == 1 then break end
      error(delete_error)
    end
    if #song.instruments >= before then break end
  end

  local instrument1 = song:insert_instrument_at(1)
  instrument1.name = "Fixture Lead"
  record("instruments.1.name", "Fixture Lead", function() return instrument1.name end)

  local phrase1 = instrument1:insert_phrase_at(1)
  local phrase1_prefix = "instruments.1.phrases.1"
  write_phrase_properties(phrase1_prefix, phrase1, {
    name = "fixture-snapshot-phrase",
    number_of_lines = 16,
    lpb = 4,
    shuffle = 0,
    looping = true,
    loop_start = 1,
    loop_end = 16,
    playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN,
    key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE,
    base_note = 48,
    autoseek = false,
    visible_note_columns = 1,
    visible_effect_columns = 1,
    instrument_column_visible = false,
    volume_column_visible = true,
    panning_column_visible = false,
    delay_column_visible = false,
    sample_effects_column_visible = false
  })
  write_phrase_columns(phrase1_prefix, phrase1, "fixture", 2)

  local line1 = phrase1:line(1)
  write_note_column(phrase1_prefix .. ".lines.1.note_columns.1", line1.note_columns[1], {
    note_value = 48,
    instrument_value = 255,
    volume_value = 96,
    panning_value = 128,
    delay_value = 2,
    effect_number_value = 0,
    effect_amount_value = 0
  })
  write_note_column(phrase1_prefix .. ".lines.1.note_columns.2", line1.note_columns[2], {
    note_value = 60,
    instrument_value = 255,
    volume_value = 255,
    panning_value = 255,
    delay_value = 0,
    effect_number_value = 0,
    effect_amount_value = 0
  })

  local line4 = phrase1:line(4)
  write_effect_column(phrase1_prefix .. ".lines.4.effect_columns.1", line4.effect_columns[1], {
    number_value = 12,
    amount_value = 64
  })
  write_effect_column(phrase1_prefix .. ".lines.4.effect_columns.2", line4.effect_columns[2], {
    number_value = 13,
    amount_value = 65
  })

  local line64 = phrase1:line(64)
  write_note_column(phrase1_prefix .. ".lines.64.note_columns.1", line64.note_columns[1], {
    note_value = 36,
    instrument_value = 255,
    volume_value = 255,
    panning_value = 255,
    delay_value = 0,
    effect_number_value = 0,
    effect_amount_value = 0
  })
  write_effect_column(phrase1_prefix .. ".lines.64.effect_columns.8", line64.effect_columns[8], {
    number_value = 14,
    amount_value = 70
  })

  local mapping = instrument1:insert_phrase_mapping_at(1, phrase1)
  local mapping_prefix = phrase1_prefix .. ".mapping"
  local mapping_key_tracking = renoise.InstrumentPhraseMapping.KEY_TRACKING_TRANSPOSE
  mapping.key_tracking = mapping_key_tracking
  record(mapping_prefix .. ".key_tracking", mapping_key_tracking, function() return mapping.key_tracking end)
  mapping.base_note = 48
  record(mapping_prefix .. ".base_note", 48, function() return mapping.base_note end)
  mapping.note_range = { 36, 60 }
  record(mapping_prefix .. ".note_range.1", 36, function() return mapping.note_range[1] end)
  record(mapping_prefix .. ".note_range.2", 60, function() return mapping.note_range[2] end)
  mapping.looping = false
  record(mapping_prefix .. ".looping", false, function() return mapping.looping end)
  mapping.loop_start = 1
  record(mapping_prefix .. ".loop_start", 1, function() return mapping.loop_start end)
  mapping.loop_end = 16
  record(mapping_prefix .. ".loop_end", 16, function() return mapping.loop_end end)

  local phrase2 = instrument1:insert_phrase_at(2)
  local phrase2_prefix = "instruments.1.phrases.2"
  write_phrase_properties(phrase2_prefix, phrase2, {
    name = "fixture-plain-arp",
    number_of_lines = 8,
    lpb = 4,
    shuffle = 0,
    looping = false,
    loop_start = 1,
    loop_end = 8,
    playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN,
    key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE,
    base_note = 48,
    autoseek = false,
    visible_note_columns = 1,
    visible_effect_columns = 0,
    instrument_column_visible = false,
    volume_column_visible = false,
    panning_column_visible = false,
    delay_column_visible = false,
    sample_effects_column_visible = false
  })
  write_phrase_columns(phrase2_prefix, phrase2, "plain", nil)
  for _, entry in ipairs({
    { line = 1, note = 57, volume = 96 },
    { line = 3, note = 64, volume = 96 },
    { line = 5, note = 69, volume = 64 }
  }) do
    local line = phrase2:line(entry.line)
    write_note_column(phrase2_prefix .. ".lines." .. entry.line .. ".note_columns.1", line.note_columns[1], {
      note_value = entry.note,
      instrument_value = 255,
      volume_value = entry.volume,
      panning_value = 255,
      delay_value = 0,
      effect_number_value = 0,
      effect_amount_value = 0
    })
  end

  local instrument2 = song:insert_instrument_at(2)
  instrument2.name = "Fixture Pad"
  record("instruments.2.name", "Fixture Pad", function() return instrument2.name end)

  while #song.instruments > 2 do
    song:delete_instrument_at(3)
  end
  return instrument1, instrument2
end

local function build_and_verify(song)
  local instrument1, instrument2 = build_fixture(song)
  write_values_manifest()
  local structural_mismatch = verify_structure(song, instrument1, instrument2)
  if structural_mismatch then return structural_mismatch end
  return verify_records()
end

local function on_new_document()
  new_document_seen = true
end

local function on_idle()
  if not active then return end
  idle_count = idle_count + 1
  if idle_count > 600 then
    write_marker("error", "completion confirmation timed out")
    return
  end

  if phase == "fresh" then
    phase = "fresh_waiting"
    new_document_seen = false
    local ok, call_error = pcall(function() renoise.app():new_song_no_template() end)
    if not ok then
      write_marker("error", "new_song_no_template failed: " .. tostring(call_error))
    end
  elseif phase == "fresh_waiting" then
    if new_document_seen then phase = "build" end
  elseif phase == "build" then
    local song_ok, song = pcall(function() return renoise.song() end)
    if not song_ok or not song then
      write_marker("error", "current song is unavailable")
      return
    end
    local build_ok, mismatch = pcall(build_and_verify, song)
    if not build_ok then
      write_marker("error", "fixture build failed: " .. tostring(mismatch))
      return
    end
    if mismatch then
      write_marker("unsupported", mismatch)
      return
    end
    phase = "save"
  elseif phase == "save" then
    local song_ok, song = pcall(function() return renoise.song() end)
    if not song_ok or not song then
      write_marker("error", "current song is unavailable before save")
      return
    end
    local data_ok, data_error = pcall(function() song.tool_data = configuration.tool_data end)
    if not data_ok then
      write_marker("error", "tool_data write failed: " .. tostring(data_error))
      return
    end
    local stored_ok, stored_data = pcall(function() return song.tool_data end)
    if not stored_ok or stored_data ~= configuration.tool_data then
      write_marker("unsupported", "tool_data")
      return
    end
    local save_ok, save_error = pcall(function() renoise.app():save_song_as(configuration.target) end)
    if not save_ok then
      write_marker("error", "save_song_as failed: " .. tostring(save_error))
      return
    end
    phase = "confirm"
  elseif phase == "confirm" then
    local song_ok, song = pcall(function() return renoise.song() end)
    if song_ok and song and song.file_name == configuration.target then
      local file = io.open(configuration.target, "rb")
      if file then
        local size = file:seek("end")
        file:close()
        if size and size > 0 then
          write_marker("ok", nil, size)
        end
      end
    end
  end
end

local function register(observable, callback)
  observable:add_notifier(callback)
  registrations[#registrations + 1] = { observable, callback }
end

local function start()
  if started then return end
  started = true
  register(tool.app_new_document_observable, on_new_document)
  register(tool.app_idle_observable, on_idle)
end

start()
