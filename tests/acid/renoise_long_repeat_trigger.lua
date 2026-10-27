-- Build a disposable multi-pattern host trigger for long Repeat renders.
local song = assert(renoise.song(), "Open the disposable ACID song copy first")
local capture_steps = assert(rawget(_G, "ACID_LONG_CAPTURE_STEPS"),
  "Set ACID_LONG_CAPTURE_STEPS to the total host hold in TIME steps")
local tail_seconds = rawget(_G, "ACID_LONG_CAPTURE_TAIL_SECONDS") or 3
local preroll_seconds = rawget(_G, "ACID_LONG_CAPTURE_PREROLL_SECONDS") or 2
local bpm = rawget(_G, "ACID_ARTICULATION_BPM") or 120
local probe_name = rawget(_G, "ACID_ARTICULATION_PROBE_NAME") or "ACID ARTICULATION PROBE"

assert(not song.transport.playing, "Stop the disposable song before building a long trigger")
assert(bpm == 90 or bpm == 120 or bpm == 150, "Capture BPM must be 90, 120 or 150")
assert(type(capture_steps) == "number" and capture_steps > 0 and capture_steps < math.huge
  and capture_steps == math.floor(capture_steps), "Capture steps must be a positive finite integer")
assert(type(tail_seconds) == "number" and tail_seconds >= 2 and tail_seconds < math.huge,
  "Capture tail must be at least two seconds")
assert(type(preroll_seconds) == "number" and preroll_seconds >= 2 and preroll_seconds < math.huge,
  "Capture pre-roll must be at least two seconds")
assert(probe_name == "ACID ARTICULATION PROBE" or probe_name == "ACID ARTICULATION MONO PROBE",
  "Unsupported articulation probe name")

local probe_index
for index, instrument in ipairs(song.instruments) do
  if instrument.name == probe_name then
    assert(not probe_index, "Multiple articulation probes exist; inspect the disposable song")
    probe_index = index
  end
end
assert(probe_index, "Create the articulation probe instrument first")
local probe = song.instruments[probe_index]
assert(probe.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
  "Long trigger captures require selective phrase playback")
assert(probe.phrase_program >= 1 and probe.phrase_program <= #probe.phrases,
  "Select a valid probe phrase program before creating the trigger")

local trigger_track_name = "ACID LONG CAPTURE"
for _, track in ipairs(song.tracks) do
  assert(track.name ~= trigger_track_name,
    "A long capture trigger already exists; use a fresh disposable song copy")
end
for _, pattern in ipairs(song.patterns) do
  assert(pattern.name ~= "ACID LONG CAPTURE PREROLL"
    and not pattern.name:match("^ACID LONG CAPTURE %d%d$"),
    "Long capture patterns already exist; use a fresh disposable song copy")
end

local seconds_per_line = 60 / (bpm * 8)
local off_global_line = capture_steps * 2 + 1
local tail_lines = math.ceil(tail_seconds / seconds_per_line)
local total_lines = off_global_line + tail_lines - 1
local max_lines = renoise.Pattern.MAX_NUMBER_OF_LINES
local pattern_count = math.ceil(total_lines / max_lines)
local preroll_lines = math.ceil(preroll_seconds / seconds_per_line)
assert(pattern_count >= 1 and pattern_count <= 99,
  "Long capture exceeds the supported 99 trigger patterns")
assert(preroll_lines <= max_lines, "Pre-roll exceeds Renoise's pattern line limit")

song:describe_undo("Create disposable long articulation capture trigger")
local track_index = math.max(1, #song.tracks - 1)
local trigger_track = song:insert_track_at(track_index)
trigger_track.name = trigger_track_name
assert(trigger_track.max_note_columns > 0, "Long capture trigger track must hold notes")
trigger_track.visible_note_columns = 1
for index, candidate in ipairs(song.tracks) do
  if rawequal(candidate, trigger_track) then track_index = index; break end
end
assert(rawequal(song.tracks[track_index], trigger_track), "Could not locate long capture track")

local first_sequence = #song.sequencer.pattern_sequence + 1
local preroll_pattern_index = song.sequencer:insert_new_pattern_at(first_sequence)
local preroll_pattern = song.patterns[preroll_pattern_index]
preroll_pattern.name = "ACID LONG CAPTURE PREROLL"
preroll_pattern.number_of_lines = preroll_lines
local sequence_indices = {}
local pattern_indices = {}
for part = 1, pattern_count do
  local sequence_index = #song.sequencer.pattern_sequence + 1
  local pattern_index = song.sequencer:insert_new_pattern_at(sequence_index)
  local pattern = song.patterns[pattern_index]
  pattern.name = string.format("ACID LONG CAPTURE %02d", part)
  local first_line = (part - 1) * max_lines + 1
  pattern.number_of_lines = math.min(max_lines, total_lines - first_line + 1)
  sequence_indices[part] = sequence_index
  pattern_indices[part] = pattern_index
end

local note_line = 1
local off_part = math.floor((off_global_line - 1) / max_lines) + 1
local off_line = (off_global_line - 1) % max_lines + 1
assert(off_part <= pattern_count, "Host OFF is outside the generated trigger patterns")
local start_pattern = song.patterns[pattern_indices[1]]:track(track_index)
local note = start_pattern:line(note_line).note_columns[1]
note.note_value = 48
note.instrument_value = probe_index - 1
local off_pattern = song.patterns[pattern_indices[off_part]]:track(track_index)
off_pattern:line(off_line).note_columns[1].note_value = renoise.PatternLine.NOTE_OFF

song.selected_instrument_index = probe_index
song.selected_track_index = track_index
song.transport.bpm = bpm
song.transport.lpb = 8
song.transport.tpl = 12
song.transport.groove_enabled = false
song.transport.loop_block_enabled = false
song.transport.loop_pattern = false
song.transport.loop_sequence_range = {}

local final_part = pattern_count
local final_pattern = song.patterns[pattern_indices[final_part]]
local preroll_sequence = first_sequence
local start_sequence = sequence_indices[1]
local end_sequence = sequence_indices[final_part]
local end_line = final_pattern.number_of_lines
song.selected_sequence_index = preroll_sequence
ACID_RENDER_START_SEQUENCE = preroll_sequence
ACID_RENDER_START_LINE = 1
ACID_RENDER_END_SEQUENCE = end_sequence
ACID_RENDER_END_LINE = end_line
ACID_RENDER_CONTEXT = "long_repeat_trigger;steps=" .. tostring(capture_steps)
  .. ";phrase_program=" .. tostring(probe.phrase_program)
song.transport.playback_pos = renoise.SongPos(preroll_sequence, 1)

print("Long trigger ready: " .. tostring(capture_steps) .. " TIME steps, "
  .. tostring(pattern_count) .. " trigger patterns, BPM " .. tostring(bpm) .. ".")
print("Render from silent pre-roll sequence " .. tostring(preroll_sequence)
  .. " through sequence " .. tostring(end_sequence) .. ", line " .. tostring(end_line) .. ".")
print("Host NOTE: sequence " .. tostring(start_sequence) .. ", line 1; OFF: sequence "
  .. tostring(sequence_indices[off_part]) .. ", line " .. tostring(off_line) .. ".")
print("Hold: " .. tostring(capture_steps * 2 * seconds_per_line) .. " seconds; tail at least "
  .. tostring((end_line - off_line + 1) * seconds_per_line) .. " seconds.")
print("Selected phrase program: " .. tostring(probe.phrase_program)
  .. "; existing selective trigger/start checker is not used by this helper.")
