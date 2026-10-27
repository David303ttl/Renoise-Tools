-- Start the selected disposable articulation phrase at its song-pattern trigger.
local song = renoise.song()
assert(song, "Open the disposable ACID song copy first")

local probe_index
for index, instrument in ipairs(song.instruments) do
  if instrument.name == "ACID ARTICULATION PROBE" then
    probe_index = index
    break
  end
end
assert(probe_index, "Create the articulation probe instrument first")
local probe = song.instruments[probe_index]
assert(probe.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
  "Probe phrases must use Selective playback")
assert(probe.phrase_program >= 1 and probe.phrase_program <= #probe.phrases,
  "Select a valid probe phrase program before starting playback")

local track_index
for index, track in ipairs(song.tracks) do
  if track.name == "ACID ARTICULATION TRIGGER" then
    assert(not track_index, "Multiple trigger tracks exist; inspect the disposable song")
    track_index = index
  end
end
assert(track_index, "Create the articulation song-pattern trigger first")
assert(song.tracks[track_index].max_note_columns > 0,
  "The articulation trigger track cannot hold notes")

local pattern_index
for index, pattern in ipairs(song.patterns) do
  if pattern.name == "ACID ARTICULATION TRIGGER" then
    assert(not pattern_index, "Multiple trigger patterns exist; inspect the disposable song")
    pattern_index = index
  end
end
assert(pattern_index, "Create the articulation song-pattern trigger first")

local sequence_index
for index, assigned_pattern in ipairs(song.sequencer.pattern_sequence) do
  if assigned_pattern == pattern_index then
    assert(not sequence_index, "Trigger pattern appears more than once in the sequence")
    sequence_index = index
  end
end
assert(sequence_index, "Trigger pattern is not assigned to the song sequence")
local pattern = song.patterns[pattern_index]
local pattern_track = pattern:track(track_index)
assert(pattern_track:line(1).note_columns[1].note_value == 48,
  "Trigger pattern must start with note 48 on line 1")
assert(pattern_track:line(1).note_columns[1].instrument_value == probe_index - 1,
  "Trigger note must address the articulation probe instrument")
local stop_line
for line_index = 2, pattern.number_of_lines do
  local cell = pattern_track:line(line_index).note_columns[1]
  if not cell.is_empty then
    assert(cell.note_value == renoise.PatternLine.NOTE_OFF and not stop_line,
      "Trigger pattern must contain exactly one OFF and no additional notes")
    stop_line = line_index
  end
end
assert(stop_line, "Trigger pattern must send OFF after the capture interval")
assert((pattern.number_of_lines - stop_line + 1) * 60 / (120 * 8) >= 2,
  "Trigger pattern must leave at least two seconds before sequence wrap")

local start_position = renoise.SongPos(sequence_index, 1)
song.transport:stop()
song.transport.bpm = 120
song.transport.lpb = 8
song.transport.tpl = 12
song.transport:start_at(start_position)
print("Started phrase program " .. tostring(probe.phrase_program)
  .. " at its dedicated song-pattern trigger; OFF at line " .. tostring(stop_line)
  .. ", sequence wrap after " .. tostring(pattern.number_of_lines * 60 / (120 * 8)) .. " seconds.")
