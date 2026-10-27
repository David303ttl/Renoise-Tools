-- Add an isolated song-pattern trigger for the articulation probe phrases.
local song = renoise.song()
assert(song, "Open the disposable ACID song copy first")

-- Override these globals in the terminal before running this helper.
local capture_steps = rawget(_G, "ACID_ARTICULATION_CAPTURE_STEPS") or 68
local tail_seconds = rawget(_G, "ACID_ARTICULATION_TAIL_SECONDS") or 5.5
local bpm = rawget(_G, "ACID_ARTICULATION_BPM") or 120
assert(bpm == 90 or bpm == 120 or bpm == 150,
  "Capture BPM must be 90, 120 or 150")
assert(type(capture_steps) == "number" and capture_steps > 0
  and capture_steps < math.huge
  and capture_steps == math.floor(capture_steps), "Capture steps must be a positive finite integer")
assert(type(tail_seconds) == "number" and tail_seconds >= 2 and tail_seconds < math.huge,
  "Capture tail must be at least two seconds")
local seconds_per_line = 60 / (bpm * 8)
local stop_line = capture_steps * 2 + 1
local pattern_lines = stop_line + math.ceil(tail_seconds / seconds_per_line) - 1
assert(pattern_lines <= renoise.Pattern.MAX_NUMBER_OF_LINES,
  "Capture exceeds the 512-line host pattern capacity; use a shorter capture or separate runs")

local probe_name = rawget(_G, "ACID_ARTICULATION_PROBE_NAME") or "ACID ARTICULATION PROBE"
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
assert(#probe.phrases >= (probe_name == "ACID ARTICULATION PROBE" and 7 or 2),
  "Expected the independent articulation control phrases")
assert(probe.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
  "Probe phrases must use Selective playback")
assert(probe.phrase_program >= 1 and probe.phrase_program <= #probe.phrases,
  "Select a valid probe phrase program before creating the trigger")

local trigger_track
for _, track in ipairs(song.tracks) do
  if track.name == "ACID ARTICULATION TRIGGER" then
    assert(not trigger_track, "Multiple trigger tracks exist; use a fresh disposable song copy")
    trigger_track = track
  end
end

local pattern_index
for index, pattern in ipairs(song.patterns) do
  if pattern.name == "ACID ARTICULATION TRIGGER" then
    assert(not pattern_index, "Multiple trigger patterns exist; use a fresh disposable song copy")
    pattern_index = index
  end
end

local sequence_index
if pattern_index then
  sequence_index = #song.sequencer.pattern_sequence
  assert(sequence_index > 0 and song.sequencer:pattern(sequence_index) == pattern_index,
    "The named trigger pattern is not the last sequencer entry; inspect the disposable song")
else
  sequence_index = #song.sequencer.pattern_sequence + 1
end
song:describe_undo("Create disposable ACID articulation trigger")

if not trigger_track then
  trigger_track = song:insert_track_at(math.max(1, #song.tracks - 1))
  trigger_track.name = "ACID ARTICULATION TRIGGER"
end
assert(trigger_track.max_note_columns > 0,
  "The named trigger track is not a note track; inspect the disposable song")
trigger_track.visible_note_columns = 1
local track_index
for index, existing in ipairs(song.tracks) do
  if rawequal(existing, trigger_track) then
    track_index = index
    break
  end
end
assert(track_index, "Could not locate the new trigger track")

if not pattern_index then
  pattern_index = song.sequencer:insert_new_pattern_at(sequence_index)
end
local pattern = song.patterns[pattern_index]
pattern.name = "ACID ARTICULATION TRIGGER"
local pattern_track = pattern:track(track_index)
-- Validate the existing owned cells before resizing or relocating OFF.
local old_stop_line
for line_index = 1, pattern.number_of_lines do
  local line = pattern_track:line(line_index)
  for index, column in pairs(line.note_columns) do
    assert(index == 1 or column.is_empty,
      "Named trigger contains additional note columns; inspect the disposable song")
  end
  for _, column in pairs(line.effect_columns) do
    assert(column.is_empty, "Named trigger contains effects; inspect the disposable song")
  end
  local cell = line.note_columns[1]
  assert(cell.volume_value == 255 and cell.panning_value == 255
    and cell.delay_value == 0 and cell.effect_number_value == 0
    and cell.effect_amount_value == 0,
    "Named trigger contains articulation modifiers; inspect the disposable song")
  if not cell.is_empty then
    if line_index == 1 then
      local previous_probe = song.instruments[cell.instrument_value + 1]
      assert(cell.note_value == 48 and previous_probe
        and (previous_probe.name == "ACID ARTICULATION PROBE"
          or previous_probe.name == "ACID ARTICULATION MONO PROBE"),
        "Named trigger start contains unexpected data; inspect the disposable song")
    else
      assert(cell.note_value == renoise.PatternLine.NOTE_OFF and not old_stop_line,
        "Named trigger contains unexpected data; inspect the disposable song")
      old_stop_line = line_index
    end
  end
end
if old_stop_line then pattern_track:line(old_stop_line).note_columns[1]:clear() end
pattern.number_of_lines = pattern_lines
local start_note = pattern_track:line(1).note_columns[1]
local stop_note = pattern_track:line(stop_line).note_columns[1]
start_note.note_value = 48
start_note.instrument_value = probe_index - 1
stop_note.note_value = renoise.PatternLine.NOTE_OFF

song.selected_instrument_index = probe_index
song.selected_sequence_index = sequence_index
song.selected_track_index = track_index
song.transport.bpm = bpm
song.transport.lpb = 8
song.transport.tpl = 12
song.transport.playback_pos = renoise.SongPos(sequence_index, 1)

print("Configured trigger: note 48 at line 1, OFF at line " .. tostring(stop_line) .. ".")
print("Host hold: " .. tostring(capture_steps) .. " steps ("
  .. tostring(capture_steps * seconds_per_line * 2) .. " seconds at " .. tostring(bpm)
  .. " BPM); pattern length: "
  .. tostring(pattern_lines) .. " lines (" .. tostring(pattern_lines * seconds_per_line) .. " seconds).")
print("Stop capture before sequence wrap; available tail: "
  .. tostring((pattern_lines - stop_line + 1) * seconds_per_line) .. " seconds.")
print("Selected phrase program: " .. tostring(probe.phrase_program))
print("Record in Audacity, then start Renoise song playback at the selected trigger pattern.")
