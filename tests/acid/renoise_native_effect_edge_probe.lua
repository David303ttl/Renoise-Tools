-- Add disposable native phrase controls for 0G rate, REST cancellation, and fresh NOTE.
local song = assert(renoise.song(), "Open the disposable articulation song first")
local LINES_PER_STEP=4
local PHRASE_LPB=16
local instrument
for _, candidate in ipairs(song.instruments) do
  if candidate.name == "ACID ARTICULATION PROBE" then
    assert(not instrument, "Multiple articulation probes exist")
    instrument = candidate
  end
end
assert(instrument, "Create the diagnostic probe first")
assert(instrument.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
  "Probe must use Selective phrase playback")

local cases = {
  { name = "ACID 0G08 RATE SWEEP", length = 12, notes = {
    { step = 0, note = 48 }, { step = 2, note = 52, rate = 8 },
  } },
  { name = "ACID 0G20 RATE SWEEP", length = 12, notes = {
    { step = 0, note = 48 }, { step = 2, note = 52, rate = 0x20 },
  } },
  { name = "ACID 0G40 RATE SWEEP", length = 12, notes = {
    { step = 0, note = 48 }, { step = 2, note = 52, rate = 0x40 },
  } },
  { name = "ACID 0G08 REST CANCEL", length = 8, notes = {
    { step = 0, note = 48 }, { step = 1, note = 52, rate = 8 },
    { step = 2, note_off = true },
  } },
  { name = "ACID 0G08 FRESH NOTE", length = 8, notes = {
    { step = 0, note = 48 }, { step = 1, note = 52, rate = 8 },
    { step = 6, note = 48 },
  } },
  { name = "ACID 0G08 GATED FRESH NOTE", length = 8, notes = {
    { step = 0, note = 48 }, { step = 1, note = 52, rate = 8 },
    { step = 5.5, note_off = true }, { step = 6, note = 48 },
  } },
}

local existing = {}
for _, phrase in ipairs(instrument.phrases) do existing[phrase.name] = true end
local append_existing = rawget(_G, "ACID_NATIVE_EDGE_APPEND_MISSING_AFTER_READBACK") == true
local missing_cases = {}
for _, case in ipairs(cases) do
  if not existing[case.name] then missing_cases[#missing_cases + 1] = case end
end
assert(#instrument.phrases + #missing_cases <= renoise.Instrument.MAX_NUMBER_OF_PHRASES,
  "Probe has insufficient phrase capacity")

local function put_effect(line, rate)
  local cell = line.note_columns[1]
  cell.effect_number_string = "0G"
  cell.effect_amount_value = rate
end

local function expected_cells(case)
  local notes, effects = {}, {}
  for _, event in ipairs(case.notes) do
    local line_index = event.step * LINES_PER_STEP + 1
    notes[line_index] = event.note_off and renoise.PatternLine.NOTE_OFF or event.note
    if event.rate then
      effects[line_index] = event.rate
      local next_event_step = case.length
      for _, candidate in ipairs(case.notes) do
        if candidate.step > event.step and candidate.step < next_event_step then
          next_event_step = candidate.step
        end
      end
      for continuation = line_index + 1, next_event_step * LINES_PER_STEP do
        effects[continuation] = 0
      end
    end
  end
  return notes, effects
end

local function validate_existing_phrase(phrase, case)
  assert(phrase.name == case.name, "Phrase name changed: " .. case.name)
  assert(phrase.playback_mode == renoise.InstrumentPhrase.PLAY_PATTERN,
    "Unexpected phrase playback mode: " .. case.name)
  assert(phrase.number_of_lines == case.length * LINES_PER_STEP,
    "Unexpected line count: " .. case.name)
  assert(phrase.visible_note_columns == 1 and phrase.visible_effect_columns == 1,
    "Unexpected visible columns: " .. case.name)
  assert(not phrase.instrument_column_visible and phrase.lpb == PHRASE_LPB
    and phrase.shuffle == 0 and not phrase.autoseek and not phrase.looping
    and phrase.key_tracking == renoise.InstrumentPhrase.KEY_TRACKING_NONE,
    "Unexpected playback settings: " .. case.name)
  local notes, effects = expected_cells(case)
  for line_index = 1, phrase.number_of_lines do
    local cell = phrase:line(line_index).note_columns[1]
    local note_expected = notes[line_index] or renoise.PatternLine.EMPTY_NOTE
    assert(cell.note_value == note_expected,
      "Unexpected note at " .. case.name .. " line " .. tostring(line_index))
    local effect_expected = effects[line_index]
    if effect_expected ~= nil then
      assert(cell.effect_number_value == 16 and cell.effect_amount_value == effect_expected,
        "Unexpected 0G cell at " .. case.name .. " line " .. tostring(line_index))
    else
      assert(cell.effect_number_value == 0 and cell.effect_amount_value == 0,
        "Unexpected effect at " .. case.name .. " line " .. tostring(line_index))
    end
  end
end

local function write_readback(phase)
  local source = debug.getinfo(1, "S").source:gsub("\\", "/")
  local root = assert(source:match("^@(.*)/tests/acid/renoise_native_effect_edge_probe.lua$"),
    "Load this helper from its repository path")
  local stem = root .. "/tmp/acid-articulation/native_effect_edge_readback_" .. tostring(os.time())
  local path, output
  for suffix = 1, 100 do
    path = stem .. "_" .. tostring(suffix) .. ".txt"
    output = io.open(path, "rb")
    if output then output:close() else break end
  end
  output = assert(io.open(path, "wb"), "Create tmp/acid-articulation first")
  local function record(key, value)
    assert(output:write(key .. "=" .. tostring(value):gsub("[\r\n]", " ") .. "\n"))
  end
  record("format", "ACID-NATIVE-EDGE-READBACK-1")
  record("phase", phase)
  record("instrument.name", instrument.name)
  record("instrument.phrase_playback_mode", instrument.phrase_playback_mode)
  for _, key in ipairs({ "bpm", "lpb", "tpl", "groove_enabled" }) do
    record("transport." .. key, song.transport[key])
  end
  local sample = assert(instrument.samples[1], "Probe sample is missing")
  for _, key in ipairs({ "volume", "transpose", "fine_tune", "loop_start", "loop_end",
      "loop_mode", "interpolation_mode", "new_note_action", "modulation_set_index" }) do
    record("sample." .. key, sample[key])
  end
  local buffer = sample.sample_buffer
  for _, key in ipairs({ "sample_rate", "bit_depth", "number_of_channels", "number_of_frames" }) do
    record("buffer." .. key, buffer[key])
  end
  for _, key in ipairs({ "base_note", "map_key_to_pitch", "map_velocity_to_volume" }) do
    record("mapping." .. key, sample.sample_mapping[key])
  end
  for _, case in ipairs(cases) do
    local index
    for phrase_index, phrase in ipairs(instrument.phrases) do
      if phrase.name == case.name then index = phrase_index; break end
    end
    if index then
      local phrase = instrument.phrases[index]
      record("phrase." .. case.name .. ".program", index)
      for _, key in ipairs({ "number_of_lines", "lpb", "looping", "loop_start", "loop_end" }) do
        record("phrase." .. case.name .. "." .. key, phrase[key])
      end
      for line_index = 1, phrase.number_of_lines do
        local cell = phrase:line(line_index).note_columns[1]
        if cell.note_value ~= renoise.PatternLine.EMPTY_NOTE
            or cell.effect_number_value ~= 0 or cell.effect_amount_value ~= 0 then
          record("phrase." .. case.name .. ".line." .. line_index,
            table.concat({ cell.note_value, cell.instrument_value, cell.volume_value,
              cell.effect_number_value, cell.effect_amount_value }, ","))
        end
      end
    end
  end
  output:close()
  print("Portable native-edge readback: " .. path:sub(#root + 2))
end

-- Write a preflight snapshot before refusing duplicates or reusing validated phrases.
write_readback("before")
for _, case in ipairs(cases) do
  if existing[case.name] then
    assert(append_existing,
      "Phrase already exists; read back first, then set ACID_NATIVE_EDGE_APPEND_MISSING_AFTER_READBACK=true to validate and reuse it: " .. case.name)
    local phrase
    for _, candidate in ipairs(instrument.phrases) do
      if candidate.name == case.name then phrase = candidate; break end
    end
    validate_existing_phrase(assert(phrase), case)
    print("Validated existing phrase cells after readback: " .. case.name)
  end
end

for _, case in ipairs(missing_cases) do
  local phrase = instrument:insert_phrase_at(#instrument.phrases + 1)
  phrase.name = case.name
  phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
  phrase.number_of_lines = case.length * LINES_PER_STEP
  phrase.visible_note_columns = 1
  phrase.visible_effect_columns = 1
  phrase.instrument_column_visible = false
  phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
  phrase.lpb = PHRASE_LPB
  phrase.shuffle = 0
  phrase.autoseek = false
  phrase.looping = false

  for _, event in ipairs(case.notes) do
    local line_index = event.step * LINES_PER_STEP + 1
    local cell = phrase:line(line_index).note_columns[1]
    if event.note_off then
      cell.note_value = renoise.PatternLine.NOTE_OFF
    else
      cell.note_value = event.note
      cell.instrument_value = renoise.PatternLine.EMPTY_INSTRUMENT
      if event.rate then put_effect(phrase:line(line_index), event.rate) end
    end
  end

  -- 0G00 continues the active glide on intervening phrase lines.
  for _, event in ipairs(case.notes) do
    if event.rate then
      local next_event_step = case.length
      for _, candidate in ipairs(case.notes) do
        if candidate.step > event.step and candidate.step < next_event_step then
          next_event_step = candidate.step
        end
      end
      for line_index = event.step * LINES_PER_STEP + 2,
        next_event_step * LINES_PER_STEP do
        put_effect(phrase:line(line_index), 0)
      end
    end
  end
  validate_existing_phrase(phrase, case)
  print(case.name .. " program=" .. tostring(#instrument.phrases)
    .. " lines=" .. tostring(phrase.number_of_lines))
end
write_readback("after")
print("Created " .. tostring(#missing_cases) .. " one-shot native effect edge phrase(s); existing names were left unchanged.")
return "native effect edge probes ready"
