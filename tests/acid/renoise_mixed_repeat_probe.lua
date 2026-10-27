-- Temporary Renoise playback/render probe for mixed NOTE, TIE and REST loops.
-- Run in the Scripting Terminal on a disposable song with ACID LOOP PROBE selected.
local song = renoise.song()
assert(song, "Open the disposable probe song first")
local instrument = song.selected_instrument
assert(instrument and instrument.name == "ACID LOOP PROBE",
  'Select the dedicated instrument named "ACID LOOP PROBE"')
assert(#instrument.samples > 0, "Probe instrument has no samples")
local has_sample_data = false
for _, sample in ipairs(instrument.samples) do
  if sample.sample_buffer and sample.sample_buffer.has_sample_data then
    has_sample_data = true
    break
  end
end
assert(has_sample_data, "Load a looping single-cycle saw sample before running")
assert(#song.patterns == 1 and #song.sequencer.pattern_sequence == 1,
  "Use a disposable song with one pattern and one sequence position")
local pattern = song:pattern(1)
assert(pattern.is_empty, "The only song pattern must be empty")
for _, pattern_track in ipairs(pattern.tracks) do
  assert(#pattern_track.automation == 0, "The song pattern must have no automation")
end
assert(song.sequencer_track_count >= 1, "Song needs a regular track for the probe trigger")
assert(#instrument.phrases + 2 <= renoise.Instrument.MAX_NUMBER_OF_PHRASES,
  "Probe instrument has insufficient phrase capacity")

local render_tool
if renoise.tool then
  local tool_ok, tool = pcall(renoise.tool)
  if tool_ok then render_tool = tool end
end
local output_root = os.getenv("TEMP")
assert(output_root and output_root ~= "", "TEMP environment variable is missing")
local separator = package.config:sub(1, 1)
local run_id = tostring(os.time())
local sample_rate, bit_depth, lpb = 44100, 16, 8
local cases = {
  {
    name = "tie_seam_span3",
    commands = {"N", "T", "N", "R", "N", "T", "T", "T"},
    pitches = {36, 43, 48},
    pitch_length = 3,
  },
  {
    name = "rest_seam_span2",
    commands = {"N", "T", "N", "T", "T", "T", "T", "R"},
    pitches = {40, 47},
    pitch_length = 2,
  },
}
local function path_for(name)
  return output_root .. separator .. "acid_mixed_repeat_" .. run_id .. "_" .. name .. ".wav"
end
local outputs = {}
for _, case in ipairs(cases) do
  case.output = path_for(case.name)
  local existing = io.open(case.output, "rb")
  if existing then existing:close(); error("Refusing to overwrite " .. case.output) end
  outputs[#outputs + 1] = case.output
end

local old_mode = instrument.phrase_playback_mode
local old_program = instrument.phrase_program
local old_lpb = song.transport.lpb
local old_pattern_lines = pattern.number_of_lines
local old_track_count = #song.tracks
local trigger_instrument = song.selected_instrument_index - 1
local phrases, phrase_indices = {}, {}
local probe_track, idle_notifier
local render_index, current_render, idle_count = 0, nil, 0
local finished = false

local function track_index()
  for index, track in ipairs(song.tracks) do
    if probe_track and rawequal(track, probe_track) then return index end
  end
end

local function cleanup()
  local problems = {}
  if idle_notifier and render_tool then
    pcall(function() render_tool.app_idle_observable:remove_notifier(idle_notifier) end)
    idle_notifier = nil
  end
  for object_index = #phrases, 1, -1 do
    local target, index = phrases[object_index], nil
    for phrase_index, phrase in ipairs(instrument.phrases) do
      if rawequal(phrase, target) then index = phrase_index; break end
    end
    if index then
      local ok = pcall(function() instrument:delete_phrase_at(index) end)
      local remains = false
      for _, phrase in ipairs(instrument.phrases) do
        if rawequal(phrase, target) then remains = true; break end
      end
      if not ok or remains then problems[#problems + 1] = target.name end
    end
  end
  local index = track_index()
  if index then
    local ok = pcall(function() song:delete_track_at(index) end)
    if not ok or track_index() then problems[#problems + 1] = "temporary trigger track" end
  end
  if pattern.number_of_lines ~= old_pattern_lines then
    local ok = pcall(function() pattern.number_of_lines = old_pattern_lines end)
    if not ok or pattern.number_of_lines ~= old_pattern_lines then
      problems[#problems + 1] = "original pattern length"
    end
  end
  pcall(function() song.transport.lpb = old_lpb end)
  pcall(function() instrument.phrase_program = old_program end)
  pcall(function() instrument.phrase_playback_mode = old_mode end)
  if #song.tracks ~= old_track_count then problems[#problems + 1] = "track count changed" end
  return problems
end

local function finish(ok, message)
  if finished then return end
  finished = true
  current_render = nil
  local problems = cleanup()
  if ok then
    print("Mixed repeat WAV renders completed:")
    for _, filename in ipairs(outputs) do print(filename) end
  else
    print("Mixed repeat probe failed: " .. tostring(message))
  end
  if #problems > 0 then error("Probe cleanup needs inspection: " .. table.concat(problems, ", ")) end
  if not ok then error(tostring(message)) end
end

local setup_ok, setup_error = pcall(function()
  song:describe_undo("Prepare disposable ACID mixed repeat probe")
  local track_number = song.sequencer_track_count
  probe_track = song:insert_track_at(track_number)
  probe_track.name = "TEMP ACID MIXED REPEAT PROBE"
  probe_track.visible_note_columns = 1
  pattern.number_of_lines = 96 -- 16-line cold intro plus five 16-line loop periods.
  local trigger = pattern:track(track_number):line(1).note_columns[1]
  trigger.note_value = 48
  trigger.instrument_value = trigger_instrument
  song.transport.lpb = lpb
  instrument.phrase_playback_mode = renoise.Instrument.PHRASES_PLAY_SELECTIVE

  for _, case in ipairs(cases) do
    local phrase = instrument:insert_phrase_at(#instrument.phrases + 1)
    phrases[#phrases + 1] = phrase
    phrase_indices[#phrase_indices + 1] = #instrument.phrases
    phrase.name = "TEMP MIXED REPEAT " .. case.name
    phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    phrase.number_of_lines = 33 -- cold lines 1..16, loop lines 17..32, exclusive sentinel 33
    phrase.visible_note_columns = 1
    phrase.visible_effect_columns = 0
    phrase.instrument_column_visible = false
    phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
    phrase.lpb = lpb
    phrase.shuffle = 0
    phrase.autoseek = false
    phrase.looping = false
    phrase.loop_end = 33
    phrase.loop_start = 17

    local pitch_cursor = 1
    for step, command in ipairs(case.commands) do
      local line = phrase:line(2 * step - 1)
      local note = line.note_columns[1]
      if command == "N" then
        note.note_value = case.pitches[pitch_cursor]
        note.instrument_value = 255
        pitch_cursor = pitch_cursor % case.pitch_length + 1
      elseif command == "R" then
        note.note_value = renoise.PatternLine.NOTE_OFF
      elseif command ~= "T" then
        error("Unsupported probe command " .. tostring(command))
      end
    end
    assert(pitch_cursor == 1, case.name .. " pitch span was not consumed evenly")

    -- The steady cycle restarts PITCH at P01; preceding TIEs preserve the
    -- voice until the first NOTE or REST. Cells repeat TIME with fixed pitches.
    pitch_cursor = 1
    for step, command in ipairs(case.commands) do
      local line = phrase:line(16 + 2 * step - 1)
      local note = line.note_columns[1]
      if command == "N" then
        note.note_value = case.pitches[pitch_cursor]
        note.instrument_value = 255
        pitch_cursor = pitch_cursor % case.pitch_length + 1
      elseif command == "R" then
        note.note_value = renoise.PatternLine.NOTE_OFF
      end
    end
    assert(pitch_cursor == 1, case.name .. " steady pitch span was not consumed evenly")
    phrase.looping = true
  end
end)

if not setup_ok then
  local problems = cleanup()
  error("Probe setup failed: " .. tostring(setup_error) ..
    (#problems > 0 and ("; cleanup needs inspection: " .. table.concat(problems, ", ")) or "; temporary objects removed"))
end

local function render_next()
  if finished then return end
  render_index = render_index + 1
  if render_index > #cases then finish(true); return end
  local case = cases[render_index]
  instrument.phrase_program = phrase_indices[render_index]
  current_render, idle_count = case.output, 0
  local started, err = song:render({
    start_pos = renoise.SongPos(1, 1),
    end_pos = renoise.SongPos(1, 80), -- 16 cold lines + four 16-line repeats.
    sample_rate = sample_rate,
    bit_depth = bit_depth,
    interpolation = "precise",
    priority = "high",
  }, current_render, function()
    print("Rendered " .. case.name .. " with one host trigger and four steady loop periods.")
    current_render = nil
    render_next()
  end)
  if not started then finish(false, err or "Renoise refused the WAV render") end
end

if render_tool then
  idle_notifier = function()
    if not current_render or finished then return end
    if song.rendering then idle_count = 0 else
      idle_count = idle_count + 1
      if idle_count > 200 then finish(false, "render stopped without callback: " .. current_render) end
    end
  end
  render_tool.app_idle_observable:add_notifier(idle_notifier)
end
render_next()
print("Started two offline WAV renders. Each phrase has an eight-step cold intro and steady loop, with no host retriggers.")
print(string.format("BPM %.1f, song/phrase LPB %d, sample rate %d, bit depth %d.",
  song.transport.bpm, lpb, sample_rate, bit_depth))
print("Pitch-span cases: tie_seam_span3 (36,43,48; trailing TIE holds 48 until NOTE 36 at wrap), rest_seam_span2 (40,47; trailing REST releases before wrap).")
