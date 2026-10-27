-- Temporary Renoise 3.5/API 6.2 endpoint render probe.
-- Requires a disposable, otherwise blank song and selected ACID LOOP PROBE instrument.
local song = renoise.song()
assert(song, "Open the disposable probe song")
local instrument = song.selected_instrument
assert(instrument and instrument.name == "ACID LOOP PROBE",
  'Select the dedicated instrument named "ACID LOOP PROBE"')
local instrument_index = song.selected_instrument_index
assert(#instrument.samples > 0, "Probe instrument has no samples")
local has_sample_data = false
for _, sample in ipairs(instrument.samples) do
  if sample.sample_buffer and sample.sample_buffer.has_sample_data then
    has_sample_data = true
    break
  end
end
assert(has_sample_data, "Probe instrument has no sample data")
assert(#song.patterns == 1 and #song.sequencer.pattern_sequence == 1,
  "Use a disposable song with one pattern and one sequence position")
assert(song:pattern(1).is_empty, "The only song pattern must be empty")
for track_index, pattern_track in ipairs(song:pattern(1).tracks) do
  assert(#pattern_track.automation == 0, "The song pattern must have no automation")
end
assert(song.sequencer_track_count >= 1,
  "Song must contain a regular track so the probe track can be inserted")
assert(#instrument.phrases + 8 <= renoise.Instrument.MAX_NUMBER_OF_PHRASES,
  "Insufficient phrase slots for eight length cases")
local render_tool = renoise.tool and renoise.tool() or nil
local output_root = os.getenv("TEMP")
assert(output_root and output_root ~= "", "TEMP environment variable is missing")
local separator = package.config:sub(1, 1)
local run_id = tostring(os.time())
local lengths = {1, 16, 17, 32, 33, 48, 49, 64}
local sample_rate = 44100
local bit_depth = 16
local song_lpb = 8

local function path_for(length)
  return output_root .. separator .. "acid_loop_endpoint_" .. run_id .. "_" .. length .. ".wav"
end

local outputs = {}
for _, length in ipairs(lengths) do
  local filename = path_for(length)
  local existing = io.open(filename, "rb")
  if existing then existing:close(); error("Refusing to overwrite " .. filename) end
  outputs[#outputs + 1] = filename
end

local old_instrument_mode = instrument.phrase_playback_mode
local old_program = instrument.phrase_program
local old_lpb = song.transport.lpb
local pattern = song:pattern(1)
local old_pattern_lines = pattern.number_of_lines
local old_track_count = #song.tracks
local phrase_objects = {}
local phrase_indices = {}
local probe_track
local idle_notifier
local current_render
local idle_count = 0
local finished = false
local render_index = 0
local setup_ok, setup_error = pcall(function()
  song:describe_undo("Prepare disposable ACID loop render probe")
  local track_index = song.sequencer_track_count
  probe_track = song:insert_track_at(track_index)
  probe_track.name = "TEMP ACID LOOP RENDER PROBE"
  probe_track.visible_note_columns = 1
  pattern.number_of_lines = 512
  local trigger = pattern:track(track_index):line(1).note_columns[1]
  trigger.note_value = 48
  trigger.instrument_value = instrument_index - 1
  song.transport.lpb = song_lpb
  instrument.phrase_playback_mode = renoise.Instrument.PHRASES_PLAY_SELECTIVE

  for _, steps in ipairs(lengths) do
    local period_lines = 2 * steps
    local endpoint_line = period_lines + 1
    local phrase = instrument:insert_phrase_at(#instrument.phrases + 1)
    phrase_objects[#phrase_objects + 1] = phrase
    phrase_indices[#phrase_indices + 1] = #instrument.phrases
    phrase.name = "TEMP LOOP ENDPOINT " .. steps
    phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    phrase.number_of_lines = endpoint_line
    phrase.visible_note_columns = 1
    phrase.visible_effect_columns = 0
    phrase.instrument_column_visible = false
    phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
    phrase.lpb = song_lpb
    phrase.shuffle = 0
    phrase.autoseek = false
    phrase.looping = false
    phrase.loop_end = endpoint_line
    phrase.loop_start = 1
    for step = 1, steps do
      local note = 36 + ((step - 1) % 25)
      phrase:line(2 * step - 1).note_columns[1].note_value = note
      phrase:line(2 * step - 1).note_columns[1].instrument_value = 255
    end
    phrase:line(period_lines).note_columns[1].note_value = 55
    phrase:line(period_lines).note_columns[1].instrument_value = 255
    -- A distinctive event exactly at loop_end should be omitted if end is exclusive.
    phrase:line(endpoint_line).note_columns[1].note_value = 60
    phrase:line(endpoint_line).note_columns[1].instrument_value = 255
    phrase.looping = true
  end
end)

local function find_track_index()
  if not probe_track then return nil end
  for index, track in ipairs(song.tracks) do
    if rawequal(track, probe_track) then return index end
  end
end

local function delete_created_phrases()
  local failures = {}
  for object_index = #phrase_objects, 1, -1 do
    local target = phrase_objects[object_index]
    local phrase_index
    for index, phrase in ipairs(instrument.phrases) do
      if rawequal(phrase, target) then phrase_index = index; break end
    end
    if phrase_index then
      local deleted = pcall(function() instrument:delete_phrase_at(phrase_index) end)
      local remains = false
      for _, phrase in ipairs(instrument.phrases) do
        if rawequal(phrase, target) then remains = true; break end
      end
      if not deleted or remains then failures[#failures + 1] = target.name end
    end
  end
  return failures
end

local function cleanup()
  if idle_notifier and render_tool then
    pcall(function() render_tool.app_idle_observable:remove_notifier(idle_notifier) end)
    idle_notifier = nil
  end
  local problems = {}
  local deleted = delete_created_phrases()
  for _, name in ipairs(deleted) do problems[#problems + 1] = "phrase " .. name end
  local track_index = find_track_index()
  if track_index then
    local ok = pcall(function() song:delete_track_at(track_index) end)
    if not ok or find_track_index() then problems[#problems + 1] = "temporary track" end
  end
  if pattern and pattern.number_of_lines ~= old_pattern_lines then
    local ok = pcall(function() pattern.number_of_lines = old_pattern_lines end)
    if not ok or pattern.number_of_lines ~= old_pattern_lines then
      problems[#problems + 1] = "original pattern length"
    end
  end
  pcall(function() song.transport.lpb = old_lpb end)
  pcall(function() instrument.phrase_program = old_program end)
  pcall(function() instrument.phrase_playback_mode = old_instrument_mode end)
  if #song.tracks ~= old_track_count then problems[#problems + 1] = "track count changed" end
  return problems
end

local function finish(ok, message)
  if finished then return end
  finished = true
  current_render = nil
  local problems = cleanup()
  if ok then
    print("Endpoint WAV renders completed:")
    for _, filename in ipairs(outputs) do print(filename) end
  else
    print("Endpoint render probe failed: " .. tostring(message))
  end
  if #problems > 0 then
    error("Probe cleanup needs inspection: " .. table.concat(problems, ", "))
  end
  if not ok then error(tostring(message)) end
end

if not setup_ok then
  local problems = cleanup()
  error("Probe setup failed: " .. tostring(setup_error) ..
    (#problems > 0 and ("; cleanup needs inspection: " .. table.concat(problems, ", ")) or "; temporary objects removed"))
end

local render_next
render_next = function()
  if finished then return end
  render_index = render_index + 1
  if render_index > #lengths then
    finish(true)
    return
  end
  local steps = lengths[render_index]
  local phrase_index = phrase_indices[render_index]
  local render_lines = 4 * 2 * steps
  instrument.phrase_program = phrase_index
  current_render = outputs[render_index]
  idle_count = 0
  local options = {
    start_pos = renoise.SongPos(1, 1),
    end_pos = renoise.SongPos(1, render_lines),
    sample_rate = sample_rate,
    bit_depth = bit_depth,
    interpolation = "precise",
    priority = "high"
  }
  local started, err = song:render(options, current_render, function()
    local done = current_render
    print(string.format("Rendered TIME %d; range 1..%d contains at least four expected cycles.",
      steps, render_lines))
    current_render = nil
    render_next()
  end)
  if not started then finish(false, err or "Renoise refused the WAV render") end
end

idle_notifier = function()
  if not current_render or finished then return end
  if not song.rendering then
    idle_count = idle_count + 1
    if idle_count > 200 then
      finish(false, "render stopped without a success callback: " .. current_render)
    end
  else
    idle_count = 0
  end
end
if render_tool then render_tool.app_idle_observable:add_notifier(idle_notifier) end
render_next()
print("Started eight offline WAV renders. Each has four nominal phrase periods; no host retrigger is used.")
print(string.format("BPM %.1f, song/phrase LPB %d, sample rate %d, bit depth %d.",
  song.transport.bpm, song_lpb, sample_rate, bit_depth))
