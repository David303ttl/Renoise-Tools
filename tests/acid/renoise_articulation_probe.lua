-- Build a disposable sampler profile and native phrases for audio capture.
local song = renoise.song()
assert(song, "Open the disposable ACID song copy first")
assert(#song.instruments < renoise.Song.MAX_NUMBER_OF_INSTRUMENTS,
  "Song has no free instrument slot")
for _, instrument in ipairs(song.instruments) do
  assert(instrument.name ~= "ACID ARTICULATION PROBE",
    "A probe instrument already exists; use a fresh disposable song copy")
end

local instrument
local inserted_index
local function remove_created_instrument()
  if not instrument then return end
  for index, existing in ipairs(song.instruments) do
    if rawequal(existing, instrument) then
      pcall(function() song:delete_instrument_at(index) end)
      return
    end
  end
end

local function require_device_path(modulation_set)
  for _, path in ipairs(modulation_set.available_devices) do
    local normalized = string.lower(path)
    if string.find(normalized, "envelope", 1, true)
      and not string.find(normalized, "ahdrs", 1, true) then
      return path
    end
  end
  error("No point-envelope modulation device is available for the volume domain")
end

local function set_note(phrase, line_index, note_value)
  local line = assert(phrase:line(line_index), "Probe phrase line is missing")
  local note = assert(line.note_columns[1], "Probe note column is missing")
  note.note_value = note_value
  note.instrument_value = 255
end

local function set_off(phrase, line_index)
  local note = assert(phrase:line(line_index).note_columns[1], "Probe note column is missing")
  note.note_value = renoise.PatternLine.NOTE_OFF
end

local function make_phrase(name, steps, notes, looping, loop_start, loop_end)
  local phrase = instrument:insert_phrase_at(#instrument.phrases + 1)
  phrase.name = name
  phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
  phrase.number_of_lines = steps * 2 + (looping and 1 or 0)
  phrase.visible_note_columns = 1
  phrase.visible_effect_columns = 1
  phrase.instrument_column_visible = false
  phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
  phrase.lpb = 8
  phrase.shuffle = 0
  phrase.autoseek = false
  phrase.loop_start = loop_start or 1
  phrase.loop_end = loop_end or phrase.number_of_lines
  phrase.looping = looping
  for _, event in ipairs(notes) do
    set_note(phrase, event.step * 2 + 1, event.note)
    if event.effect then
      local cell = phrase:line(event.step * 2 + 1).note_columns[1]
      cell.effect_number_string = event.effect
      cell.effect_amount_value = event.amount
    end
    if event.stop_glide then
      local cell = phrase:line(event.step * 2 + 2).note_columns[1]
      cell.effect_number_string = "0G"
      cell.effect_amount_value = 0
    end
  end
  return phrase
end

local function configure_envelope(modulation_set)
  modulation_set.volume_input.value = 1.0
  local path = require_device_path(modulation_set)
  local envelope = modulation_set:insert_device_at(
    path, renoise.SampleModulationDevice.TARGET_VOLUME, 1)
  assert(envelope.tempo_sync_switching_allowed,
    "Volume envelope cannot use the documented millisecond time base")
  envelope.operator = renoise.SampleModulationDevice.OPERATOR_MUL
  envelope.bipolar = false
  envelope.tempo_synced = true
  envelope.play_mode = renoise.SampleEnvelopeModulationDevice.PLAYMODE_LINES
  envelope.loop_mode = renoise.SampleEnvelopeModulationDevice.LOOP_MODE_OFF
  envelope.sustain_enabled = true
  envelope.sustain_position = 31
  envelope.length = 37
  envelope:clear_points()
  envelope.points = {
    { time = 1, value = 0.0, scaling = 0.0 },
    { time = 11, value = 1.0, scaling = 0.0 },
    { time = 31, value = 0.65, scaling = 0.0 },
    { time = 32, value = 0.65, scaling = 0.0 },
    { time = 36, value = 0.0, scaling = 0.0 },
    { time = 37, value = 0.0, scaling = 0.0 },
  }
  local desired_points = { [1] = true, [11] = true, [31] = true, [32] = true, [36] = true, [37] = true }
  for _, point in ipairs(envelope.points) do
    if not desired_points[point.time] then envelope:remove_point_at(point.time) end
  end
  assert(envelope.tempo_synced, "Volume envelope millisecond mode did not stick")
  assert(envelope.operator == renoise.SampleModulationDevice.OPERATOR_MUL
    and not envelope.bipolar, "Volume envelope operator or polarity did not stick")
  assert(envelope.sustain_position == 31 and envelope.sustain_enabled,
    "Volume envelope sustain settings did not stick")
  assert(envelope.length == 37, "Volume envelope length did not read back as 37 ms")
  assert(#envelope.points == 6,
    "Volume envelope point count did not read back as expected: " .. tostring(#envelope.points))
  assert(envelope.points[2].time == 11 and envelope.points[2].value == 1.0,
    "Volume envelope attack point did not read back as expected")
  return envelope
end

local function write_sample_readback(buffer)
  local source = debug.getinfo(1, "S").source
  assert(string.sub(source, 1, 1) == "@", "Probe must be loaded from its file path")
  local script_path = string.gsub(string.sub(source, 2), "\\", "/")
  local repo_root = assert(string.match(script_path,
    "^(.*)/tests/acid/renoise_articulation_probe.lua$"),
    "Could not resolve the repository root from the probe path")
  local path = repo_root .. "/tmp/acid-articulation/reference_saw.txt"
  local file = assert(io.open(path, "wb"), "Could not write the reference sample read-back")
  for frame = 1, 168 do
    file:write(string.format("%.9f\n", buffer:sample_data(1, frame)))
  end
  file:close()
  return path
end

local ok, err = pcall(function()
  song:describe_undo("Create disposable ACID articulation audio probe")
  song.transport.bpm = 120
  song.transport.lpb = 8
  song.transport.tpl = 12
  instrument = song:insert_instrument_at(#song.instruments + 1)
  inserted_index = #song.instruments
  instrument.name = "ACID ARTICULATION PROBE"
  instrument.volume = 1.0
  instrument.transpose = 0
  instrument.sample_mapping_overlap_mode = renoise.Instrument.OVERLAP_MODE_ALL

  if #instrument.samples == 0 then instrument:insert_sample_at(1) end
  assert(#instrument.samples == 1, "Fresh probe instrument must contain exactly one sample slot")
  local sample = instrument.samples[1]
  assert(not sample.sample_buffer.has_sample_data, "Fresh probe sample slot unexpectedly has data")
  sample.name = "168 frame saw 44.1 kHz"
  sample.volume = 3.0
  sample.panning = 0.5
  sample.transpose = 0
  sample.fine_tune = 0
  sample.beat_sync_enabled = false
  sample.oneshot = false
  sample.autoseek = false
  sample.autofade = false
  sample.oversample_enabled = false
  sample.interpolation_mode = renoise.Sample.INTERPOLATE_LINEAR
  sample.new_note_action = renoise.Sample.NEW_NOTE_ACTION_NOTE_CUT

  local mapping = sample.sample_mapping
  mapping.base_note = 48
  mapping.note_range = { 0, 119 }
  mapping.velocity_range = { 0, 127 }
  mapping.map_key_to_pitch = true
  mapping.map_velocity_to_volume = false

  local buffer = sample.sample_buffer
  assert(buffer:create_sample_data(44100, 32, 1, 168), "Could not allocate the reference sample")
  buffer:prepare_sample_data_changes(false)
  local write_ok, write_error = pcall(function()
    for frame = 1, 168 do
      local value = 0.35 * (2.0 * ((frame - 1) / 168.0) - 1.0)
      buffer:set_sample_data(1, frame, value)
    end
  end)
  buffer:finalize_sample_data_changes()
  if not write_ok then error("Could not fill the reference saw: " .. tostring(write_error)) end
  sample.loop_start = 1
  sample.loop_end = 168
  sample.loop_mode = renoise.Sample.LOOP_MODE_FORWARD
  sample.loop_release = false
  assert(sample.volume == 3.0, "Probe sample capture gain did not read back")

  local modulation_set = instrument:insert_sample_modulation_set_at(1)
  modulation_set.name = "ACID diagnostic volume envelope"
  local envelope = configure_envelope(modulation_set)
  sample.modulation_set_index = 1
  assert(sample.modulation_set_index == 1, "Sample did not link to the volume envelope")

  local calibration = {}
  for cycle = 0, 1 do
    for step = 0, 16 do
      calibration[#calibration + 1] = {
        step = cycle * 17 + step,
        note = 36 + (step % 16),
      }
    end
  end
  local calibration_phrase = make_phrase(
    "Grid calibration: pitch span 16 / TIME 17",
    34, calibration, true, 35, 69)
  for step = 0, 33 do
    set_off(calibration_phrase, step * 2 + 2)
  end
  assert(calibration_phrase.number_of_lines == 69,
    "Calibration phrase must retain its exclusive-end sentinel")

  local held = make_phrase("Reference: held NOTE then OFF", 8, {
    { step = 0, note = 48 },
  }, false)
  set_off(held, 11)

  local retrigger = make_phrase("Control: same-pitch retrigger", 8, {
    { step = 0, note = 48 },
    { step = 2, note = 48 },
  }, false)
  set_off(retrigger, 11)

  local rest = make_phrase("Control: REST release before NOTE", 8, {
    { step = 0, note = 48 },
    { step = 3, note = 52 },
  }, false)
  set_off(rest, 5)
  set_off(rest, 15)

  for _, rate in ipairs({ 0x08, 0x20, 0x40 }) do
    local glide = make_phrase(string.format("0G%02X candidate 48 to 55", rate), 8, {
      { step = 0, note = 48 },
      { step = 2, note = 55, effect = "0G", amount = rate, stop_glide = true },
    }, false)
    set_off(glide, 11)
  end

  instrument.phrase_playback_mode = renoise.Instrument.PHRASES_PLAY_SELECTIVE
  instrument.phrase_program = 1
  song.selected_instrument_index = inserted_index
  local sample_readback_path = write_sample_readback(buffer)

  print("Created the ACID articulation probe instrument and seven phrases.")
  print("Profile: 44.1 kHz, 168-frame forward-loop saw, root 48, amplitude 0.35, linear interpolation, NNA Cut.")
  print("Envelope read-back: tempo-synced milliseconds=" .. tostring(envelope.tempo_synced)
    .. ", points=" .. tostring(#envelope.points) .. ", sustain=" .. tostring(envelope.sustain_position)
    .. ", operator=MUL, bipolar=" .. tostring(envelope.bipolar))
  print("Transport initialized: BPM=" .. tostring(song.transport.bpm)
    .. ", LPB=" .. tostring(song.transport.lpb) .. ", TPL=" .. tostring(song.transport.tpl))
  print("Reference frequency at note 48: " .. string.format("%.4f Hz", 44100.0 / 168.0))
  print("Reference sample read-back: " .. sample_readback_path)
  print("Select phrases 1–7 in turn and capture them with the manual protocol.")
end)

if not ok then
  remove_created_instrument()
  error("Articulation probe failed; its newly inserted instrument was removed: " .. tostring(err))
end
