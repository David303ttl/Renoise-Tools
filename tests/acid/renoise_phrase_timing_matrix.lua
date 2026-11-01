-- Build single-trigger Renoise renders for a selected ACID-owned phrase.
local M = {}

local source = debug.getinfo(1, "S").source
assert(source:sub(1, 1) == "@", "Load this helper from its file path")
local script_path = source:sub(2):gsub("\\", "/")
local repo_root = assert(script_path:match("^(.*)/tests/acid/renoise_phrase_timing_matrix.lua$"),
  "Could not resolve the repository root")
local output_directory = repo_root .. "/tmp/acid-m4-acceptance"
local config_path = output_directory .. "/timing_runner_config.txt"
local render_helper = repo_root .. "/tests/acid/renoise_render_capture.lua"
local probe_name = "ACID ARTICULATION PROBE"
local trigger_name = "ACID TIMING MATRIX TRIGGER"
local tool = renoise.tool()

local function read_config()
  local config = { scope = "single", bpm = 120, lpb = 8, traversals = 4 }
  local file = io.open(config_path, "rb")
  if not file then return config end
  for line in file:lines() do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then config[key] = value:match("^%s*(.-)%s*$") end
  end
  file:close()
  config.bpm = tonumber(config.bpm)
  config.lpb = tonumber(config.lpb)
  config.traversals = tonumber(config.traversals) or 4
  config.meter_beats_per_bar = tonumber(config.meter_beats_per_bar)
  config.meter_lines_per_beat = tonumber(config.meter_lines_per_beat)
  config.pattern_boundary_lines = tonumber(config.pattern_boundary_lines)
  config.pre_roll_alignment_lines = tonumber(config.pre_roll_alignment_lines)
  return config
end

local function find_probe(song)
  local found, found_index
  for index, instrument in ipairs(song.instruments) do
    if instrument.name == probe_name then
      assert(not found, "More than one reference probe instrument exists")
      found, found_index = instrument, index
    end
  end
  assert(found, "The disposable reference probe instrument is missing")
  return found, found_index
end

local function find_last_acid_phrase(instrument)
  for index = #instrument.phrases, 1, -1 do
    local phrase = instrument.phrases[index]
    if phrase.name:match("^ACID 0%.1 #") then return phrase, index end
  end
  error("The reference instrument has no generated ACID phrase")
end

local function validate_phrase(phrase)
  assert(phrase.lpb == 16 or phrase.lpb == 12,
    "The generated phrase LPB must be 16 or 12")
  local mode = phrase.lpb == 16 and "straight" or "triplet"
  assert(phrase.looping, "Phrase timing captures require Repeat output")
  assert(phrase.shuffle == 0, "Phrase shuffle must be zero")
  local steps = (phrase.number_of_lines - 1) / 8
  assert(steps >= 1 and steps <= 32 and steps == math.floor(steps),
    "Repeat phrase line count does not encode a 1–32 step source")
  assert(phrase.number_of_lines == steps * 8 + 1,
    "Repeat phrase must contain two complete cycles and an empty sentinel")
  assert(phrase.loop_start == steps * 4 + 1 and phrase.loop_end == steps * 8 + 1,
    "Repeat phrase loop endpoints do not match the cold and steady cycles")

  local note_count, off_count = 0, 0
  local source_note
  for line_index = 1, phrase.number_of_lines do
    local line = assert(phrase:line(line_index), "Phrase line is unavailable")
    local column = assert(line.note_columns[1], "Phrase note column 1 is unavailable")
    local within_cycle = (line_index - 1) % (steps * 4)
    if line_index == phrase.number_of_lines then
      assert(column.note_value == renoise.PatternLine.EMPTY_NOTE,
        "Repeat sentinel line must be empty")
    elseif within_cycle % 4 == 0 then
      if source_note == nil then
        source_note = column.note_value
        assert(source_note >= 0 and source_note < renoise.PatternLine.EMPTY_NOTE,
          "All-NOTE timing source must contain a playable note")
      else
        assert(column.note_value == source_note,
          "All-NOTE timing source pitches must match at every step")
      end
      assert(column.delay_value == 0,
        "Timing source NOTE must not carry a sub-line delay")
      note_count = note_count + 1
    elseif within_cycle % 4 == 2 then
      assert(column.note_value == renoise.PatternLine.NOTE_OFF,
        "Every NOTE must have its midpoint OFF two lines after its start")
      off_count = off_count + 1
    else
      assert(column.note_value == renoise.PatternLine.EMPTY_NOTE,
        "Non-event phrase subdivision must be empty")
    end
  end
  assert(note_count == steps * 2 and off_count == steps * 2,
    "Phrase readback has missing or duplicated NOTE/OFF events")
  return mode, steps, note_count, off_count, source_note
end

local function find_or_create_trigger_track(song)
  for index, track in ipairs(song.tracks) do
    if track.name == trigger_name then
      assert(track.max_note_columns > 0, "Timing trigger track has no note columns")
      track.visible_note_columns = 1
      return track, index
    end
  end
  local index = math.max(1, #song.tracks - 1)
  local track = song:insert_track_at(index)
  track.name = trigger_name
  track.visible_note_columns = 1
  assert(track.max_note_columns > 0, "Timing trigger track has no note columns")
  for position, candidate in ipairs(song.tracks) do
    if rawequal(candidate, track) then return track, position end
  end
  error("Could not locate the new timing trigger track")
end

local function append_pattern(song, sequence_index, name, number_of_lines)
  local pattern_index = song.sequencer:insert_new_pattern_at(sequence_index)
  local pattern = song.patterns[pattern_index]
  pattern.name = name
  pattern.number_of_lines = number_of_lines
  return pattern
end

local function make_case(song, instrument, instrument_index, phrase_index, mode, steps, config, bpm, lpb, ordinal)
  local traversals = config.traversals
  local steps_per_beat = mode == "straight" and 4 or 3
  local cycle_beats = steps / steps_per_beat
  local hold_beats = cycle_beats * traversals
  -- Place NOTE OFF before the next phrase cycle when the cycle boundary falls
  -- between song lines; rounding up could allow a fifth-cycle NOTE to trigger.
  local hold_lines = math.floor(hold_beats * lpb + 0.0000001)
  local pre_roll_lines = math.ceil(2 * bpm * lpb / 60 - 0.0000001)
  if config.pre_roll_alignment_lines then
    assert(config.pre_roll_alignment_lines >= 1
      and config.pre_roll_alignment_lines == math.floor(config.pre_roll_alignment_lines),
      "Pre-roll alignment must be a positive whole number of song lines")
    pre_roll_lines = math.ceil(pre_roll_lines / config.pre_roll_alignment_lines)
      * config.pre_roll_alignment_lines
  end
  local tail_lines = math.ceil(2 * bpm * lpb / 60 - 0.0000001)
  local off_global_line = hold_lines + 1
  local total_lines = hold_lines + tail_lines
  local max_lines = renoise.Pattern.MAX_NUMBER_OF_LINES
  local segment_lines = config.pattern_boundary_lines or max_lines
  assert(segment_lines >= 1 and segment_lines <= max_lines
    and segment_lines == math.floor(segment_lines),
    "Pattern boundary length must be a whole number within Renoise's pattern limit")
  local pattern_count = math.ceil(total_lines / segment_lines)
  assert(pre_roll_lines >= 1 and pre_roll_lines <= max_lines,
    "Silent pre-roll exceeds Renoise's pattern line limit")
  assert(pattern_count >= 1 and pattern_count <= 99,
    "Timing capture exceeds the supported pattern count")

  song.transport.bpm = bpm
  song.transport.lpb = lpb
  if config.meter_beats_per_bar then
    song.transport.metronome_beats_per_bar = config.meter_beats_per_bar
  end
  if config.meter_lines_per_beat then
    song.transport.metronome_lines_per_beat = config.meter_lines_per_beat
  end
  song.selected_instrument_index = instrument_index
  instrument.phrase_program = phrase_index

  local track, track_index = find_or_create_trigger_track(song)
  local first_sequence = #song.sequencer.pattern_sequence + 1
  append_pattern(song, first_sequence,
    string.format("ACID TIMING PREROLL %03d", ordinal), pre_roll_lines)

  local safe_name = string.format("%s_%02d_r%s_bpm%03d_lpb%02d",
    mode, steps, config.run_token, bpm, lpb)
  local sequences, patterns = {}, {}
  for part = 1, pattern_count do
    local sequence_index = #song.sequencer.pattern_sequence + 1
    local first_line = (part - 1) * segment_lines + 1
    local pattern_lines = math.min(segment_lines, total_lines - first_line + 1)
    local pattern = append_pattern(song, sequence_index,
      string.format("ACID TIMING %s %02d", safe_name, part), pattern_lines)
    sequences[part] = sequence_index
    patterns[part] = pattern
  end

  local trigger_track = patterns[1]:track(track_index)
  local note = trigger_track:line(1).note_columns[1]
  note.note_value = 48
  note.instrument_value = instrument_index - 1

  local off_part = math.floor((off_global_line - 1) / segment_lines) + 1
  local off_line = (off_global_line - 1) % segment_lines + 1
  patterns[off_part]:track(track_index):line(off_line).note_columns[1].note_value =
    renoise.PatternLine.NOTE_OFF

  local final_pattern = patterns[pattern_count]
  local preroll_sequence = first_sequence
  song.selected_track_index = track_index
  song.selected_sequence_index = preroll_sequence
  song.transport.playback_pos = renoise.SongPos(preroll_sequence, 1)

  local output_name = string.format("phrase_%s.wav", safe_name)
  local output_path = output_directory .. "/" .. output_name
  local metadata_path = output_path .. ".render.txt"
  local file = io.open(output_path, "rb")
  if file then file:close(); error("Refusing to overwrite " .. output_name) end
  file = io.open(metadata_path, "rb")
  if file then file:close(); error("Refusing to overwrite " .. output_name .. ".render.txt") end

  _G.ACID_RENDER_OUTPUT_PATH = output_path
  _G.ACID_RENDER_START_SEQUENCE = preroll_sequence
  _G.ACID_RENDER_START_LINE = 1
  _G.ACID_RENDER_END_SEQUENCE = sequences[pattern_count]
  _G.ACID_RENDER_END_LINE = final_pattern.number_of_lines
  _G.ACID_RENDER_SAMPLE_RATE = 48000
  _G.ACID_RENDER_BIT_DEPTH = 24
  _G.ACID_RENDER_INTERPOLATION = "precise"
  _G.ACID_RENDER_PRIORITY = "high"
  _G.ACID_RENDER_CONTEXT = string.format(
    "phrase_timing;mode=%s;steps=%d;phrase_program=%d;traversals=%d;cycle_beats=%.9f;hold_beats=%.9f;meter_beats_per_bar=%d;meter_lines_per_beat=%d",
    mode, steps, phrase_index, traversals, cycle_beats, hold_beats,
    song.transport.metronome_beats_per_bar, song.transport.metronome_lines_per_beat)

  return {
    id = safe_name,
    mode = mode,
    steps = steps,
    bpm = bpm,
    lpb = lpb,
    cycle_beats = cycle_beats,
    traversals = traversals,
    hold_lines = hold_lines,
    pre_roll_lines = pre_roll_lines,
    pattern_boundary_lines = segment_lines,
    pattern_count = pattern_count,
    off_sequence = sequences[off_part],
    off_line = off_line,
    pre_roll_sequence = preroll_sequence,
    end_sequence = sequences[pattern_count],
    end_line = final_pattern.number_of_lines,
    output_path = output_path,
    metadata_path = metadata_path,
    instrument_index = instrument_index,
    phrase_index = phrase_index,
    phrase_lpb = instrument.phrases[phrase_index].lpb,
    phrase_line_count = instrument.phrases[phrase_index].number_of_lines,
    phrase_loop_start = instrument.phrases[phrase_index].loop_start,
    phrase_loop_end = instrument.phrases[phrase_index].loop_end,
    track_index = track_index,
    trigger_track = track
  }
end

local function read_render_status(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents:match("status=([^\r\n]+)"), contents
end

local function write_line(path, line)
  local file = assert(io.open(path, "ab"), "Could not write timing matrix receipt")
  file:write(line .. "\n")
  file:close()
end

function M.run()
  assert(not M.active, "A phrase timing matrix is already running")
  local song = assert(renoise.song(), "Open the disposable timing song first")
  local config = read_config()
  assert(config.scope == "single" or config.scope == "matrix",
    "Timing runner scope is '" .. tostring(config.scope) .. "'; expected single or matrix")
  assert(song.file_name:find("acid%-m4%-acceptance", 1, false),
    "Phrase timing captures are restricted to the disposable acceptance song")
  assert(song.transport.timing_model == renoise.Transport.TIMING_MODEL_LPB,
    "Phrase timing captures require the modern LPB timing model")
  assert(not song.transport.playing and not song.rendering,
    "Stop playback and wait for rendering before starting timing captures")
  assert(not song.transport.groove_enabled,
    "Disable groove before running the phrase timing matrix")

  local instrument, instrument_index = find_probe(song)
  assert(instrument.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
    "The reference probe must use Selective phrase triggering")
  local phrase, phrase_index = find_last_acid_phrase(instrument)
  local mode, steps, note_count, off_count, source_note = validate_phrase(phrase)
  assert(mode == "straight" or mode == "triplet")
  assert(config.traversals == 4,
    "Timing captures must include one cold and three steady traversals")

  local cases = {}
  if config.scope == "matrix" then
    for _, bpm in ipairs({ 60, 120, 180 }) do
      for _, lpb in ipairs({ 2, 3, 4, 6, 8, 12, 16, 32 }) do
        cases[#cases + 1] = { bpm = bpm, lpb = lpb }
      end
    end
  else
    assert(config.bpm and config.bpm >= 32 and config.bpm <= 999,
      "Single capture BPM is outside the Renoise range")
    assert(config.lpb and config.lpb >= 1 and config.lpb <= 256,
      "Single capture LPB is outside the Renoise range")
    cases[1] = { bpm = config.bpm, lpb = config.lpb }
  end

  M.active = true
  local original = {
    bpm = song.transport.bpm,
    lpb = song.transport.lpb,
    tpl = song.transport.tpl,
    metronome_beats_per_bar = song.transport.metronome_beats_per_bar,
    metronome_lines_per_beat = song.transport.metronome_lines_per_beat,
    selected_instrument_index = song.selected_instrument_index,
    selected_track_index = song.selected_track_index,
    selected_sequence_index = song.selected_sequence_index,
    playback_pos = song.transport.playback_pos,
    phrase_program = instrument.phrase_program
  }
  local run_token = tostring(os.time())
  config.run_token = run_token
  local run_id = string.format("%s_%02d_%s", mode, steps, run_token)
  local receipt_path = output_directory .. "/phrase_timing_" .. run_id .. ".txt"
  local receipt = assert(io.open(receipt_path, "wb"), "Could not create timing run receipt")
  receipt:write("format=ACID-PHRASE-TIMING-MATRIX-1\n")
  receipt:write("run_id=" .. run_id .. "\n")
  receipt:write("status=running\n")
  receipt:write("source_song=" .. tostring(song.file_name) .. "\n")
  receipt:write("renoise_version=" .. tostring(renoise.RENOISE_VERSION or "unknown") .. "\n")
  receipt:write("instrument=" .. instrument.name .. "\n")
  receipt:write("global_instrument_slot=" .. tostring(instrument_index - 1) .. "\n")
  receipt:write("phrase_playback_mode=selective\n")
  receipt:write("phrase_program=" .. tostring(phrase_index) .. "\n")
  receipt:write("phrase_name=" .. phrase.name:gsub("[\r\n]", " ") .. "\n")
  receipt:write("timing_mode=" .. mode .. "\n")
  receipt:write("steps=" .. tostring(steps) .. "\n")
  receipt:write("phrase_lpb=" .. tostring(phrase.lpb) .. "\n")
  receipt:write("phrase_shuffle=" .. tostring(phrase.shuffle) .. "\n")
  receipt:write("phrase_line_count=" .. tostring(phrase.number_of_lines) .. "\n")
  receipt:write("phrase_loop_start=" .. tostring(phrase.loop_start) .. "\n")
  receipt:write("phrase_loop_end=" .. tostring(phrase.loop_end) .. "\n")
  receipt:write("phrase_note_count=" .. tostring(note_count) .. "\n")
  receipt:write("phrase_off_count=" .. tostring(off_count) .. "\n")
  receipt:write("source_note_value=" .. tostring(source_note) .. "\n")
  receipt:write("traversals=" .. tostring(config.traversals) .. "\n")
  receipt:write("sample_rate=48000\n")
  receipt:write("bit_depth=24\n")
  receipt:write("interpolation=precise\n")
  receipt:write("normalization=none\n")
  receipt:write("groove_enabled=false\n")
  receipt:write("initial_bpm=" .. tostring(original.bpm) .. "\n")
  receipt:write("initial_lpb=" .. tostring(original.lpb) .. "\n")
  receipt:write("initial_tpl=" .. tostring(original.tpl) .. "\n")
  receipt:write("meter_beats_per_bar=" .. tostring(config.meter_beats_per_bar or original.metronome_beats_per_bar) .. "\n")
  receipt:write("meter_lines_per_beat=" .. tostring(config.meter_lines_per_beat or original.metronome_lines_per_beat) .. "\n")
  receipt:write("pattern_boundary_lines=" .. tostring(config.pattern_boundary_lines or "max") .. "\n")
  receipt:write("pre_roll_alignment_lines=" .. tostring(config.pre_roll_alignment_lines or "none") .. "\n")
  receipt:close()

  local index = 0
  local failures = 0
  local active_case
  local poll_timer

  local function restore(status)
    pcall(function() song.transport.bpm = original.bpm end)
    pcall(function() song.transport.lpb = original.lpb end)
    pcall(function() song.transport.tpl = original.tpl end)
    pcall(function() song.transport.metronome_beats_per_bar = original.metronome_beats_per_bar end)
    pcall(function() song.transport.metronome_lines_per_beat = original.metronome_lines_per_beat end)
    pcall(function() instrument.phrase_program = original.phrase_program end)
    pcall(function() song.selected_instrument_index = original.selected_instrument_index end)
    pcall(function() song.selected_track_index = original.selected_track_index end)
    pcall(function() song.selected_sequence_index = original.selected_sequence_index end)
    pcall(function() song.transport.playback_pos = original.playback_pos end)
    write_line(receipt_path, "captures=" .. tostring(index))
    write_line(receipt_path, "failures=" .. tostring(failures))
    write_line(receipt_path, "status=" .. status)
    M.active = false
    renoise.app():show_status(string.format(
      "Phrase timing captures %s: %d completed, %d failed", status, index, failures))
  end

  local advance
  local function handle_finished()
    if not active_case then return end
    local status, contents = read_render_status(active_case.metadata_path)
    if song.rendering or status == "pending" or not status then return end
    tool:remove_timer(poll_timer)
    local result = status == "completed" and "completed" or "failed"
    if result == "failed" then failures = failures + 1 end
    write_line(receipt_path, string.format(
      "capture=%s;status=%s;output=%s;sidecar=%s;duration_check=%s",
      active_case.id, result,
      active_case.output_path:gsub("^" .. repo_root:gsub("([%%%+%-%*%?%[%]%^%$%(%)%.])", "%%%1") .. "/", ""),
      active_case.metadata_path:gsub("^" .. repo_root:gsub("([%%%+%-%*%?%[%]%^%$%(%)%.])", "%%%1") .. "/", ""),
      contents and (contents:match("duration_check=([^\r\n]+)") or "unavailable") or "unavailable"))
    if result == "failed" then
      restore("failed")
      return
    end
    active_case = nil
    if index >= #cases then
      restore("completed")
    else
      tool:add_timer(advance, 1000)
    end
  end

  advance = function()
    if not M.active then return end
    tool:remove_timer(advance)
    index = index + 1
    local case = cases[index]
    local ok, result = pcall(make_case, song, instrument, instrument_index,
      phrase_index, mode, steps, config, case.bpm, case.lpb, index)
    if not ok then
      failures = failures + 1
      write_line(receipt_path, "capture=" .. tostring(index) .. ";status=failed;reason=" .. tostring(result):gsub("[\r\n;]", " "))
      restore("failed")
      return
    end
    active_case = result
    write_line(receipt_path, string.format(
      "prepared=%s;host_note=1:%d:1;host_off=%d:%d;pre_roll_lines=%d;hold_lines=%d;pattern_boundary_lines=%d;pattern_count=%d;cycle_beats=%.9f",
      result.id, result.pre_roll_sequence + 1, result.off_sequence, result.off_line,
      result.pre_roll_lines, result.hold_lines, result.pattern_boundary_lines,
      result.pattern_count, result.cycle_beats))

    local function begin_render()
      tool:remove_timer(begin_render)
      if not M.active or not active_case then return end
      local loaded, render_error = pcall(dofile, render_helper)
      if not loaded then
        failures = failures + 1
        write_line(receipt_path, "capture=" .. active_case.id .. ";status=failed;reason=" .. tostring(render_error):gsub("[\r\n;]", " "))
        restore("failed")
        return
      end
      poll_timer = handle_finished
      tool:add_timer(poll_timer, 100)
    end
    tool:add_timer(begin_render, 1000)
  end

  song:describe_undo("Create phrase timing matrix captures")
  renoise.app():show_status(string.format(
    "Phrase timing run started: %s %d steps, %d capture(s)", mode, steps, #cases))
  tool:add_timer(advance, 100)
end

return M
