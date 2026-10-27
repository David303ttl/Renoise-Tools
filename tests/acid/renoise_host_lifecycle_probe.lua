-- Build one isolated song-pattern host lifecycle control per fresh song copy.
local song = renoise.song()
assert(song, "Open a disposable ACID probe song first")

local case_name = rawget(_G, "ACID_HOST_LIFECYCLE_CASE") or "host_note_off"
assert(case_name == "host_note_off" or case_name == "fresh_retrigger"
  or case_name == "keymapped_trigger" or case_name == "transport_stop_start"
  or case_name == "transport_seek",
  "Unsupported ACID_HOST_LIFECYCLE_CASE")
local bpm = rawget(_G, "ACID_HOST_LIFECYCLE_BPM") or 120
assert(bpm == 90 or bpm == 120 or bpm == 150, "Probe BPM must be 90, 120, or 150")
assert(#song.sequencer.pattern_sequence > 0,
  "Song needs one sequence position before the isolated probe can be appended")

local probe_name = rawget(_G, "ACID_ARTICULATION_PROBE_NAME") or "ACID ARTICULATION PROBE"
local instrument_index
for index, instrument in ipairs(song.instruments) do
  if instrument.name == probe_name then
    assert(not instrument_index, "Multiple articulation probe instruments exist")
    instrument_index = index
  end
end
assert(instrument_index, "Create the ACID articulation probe instrument first")
local instrument = song.instruments[instrument_index]
assert(instrument.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE
  or case_name == "keymapped_trigger", "Selective probe must be in Selective phrase mode")

local track_name = "ACID HOST LIFECYCLE TRIGGER"
local pattern_name = (case_name == "transport_stop_start" or case_name == "transport_seek")
  and "ACID HOST LIFECYCLE TRANSPORT" or "ACID HOST LIFECYCLE " .. string.upper(case_name)
for _, track in ipairs(song.tracks) do
  assert(track.name ~= track_name, "Probe track already exists; open a fresh song copy")
end
for _, pattern in ipairs(song.patterns) do
  assert(pattern.name ~= pattern_name, "Probe pattern already exists; open a fresh song copy")
end

local preroll_steps = 16
local note_on_line = preroll_steps * 2 + 1
local event_line = note_on_line + 16 -- 8 straight sixteenth steps after NOTE at LPB 8.
local is_transport_case = case_name == "transport_stop_start" or case_name == "transport_seek"
local note_off_line = case_name == "fresh_retrigger" and note_on_line + 32
  or (is_transport_case and note_on_line + 128 or event_line)
local phrase_index
local mapped_note

if case_name == "keymapped_trigger" then
  assert(#instrument.phrase_mappings == 0,
    "Keymapped probe needs an unmapped probe instrument; use a fresh probe song copy")
  assert(#instrument.phrases < 126, "No phrase program is available for the keymapped control")
  phrase_index = #instrument.phrases + 1
  local phrase = instrument:insert_phrase_at(phrase_index)
  phrase.name = "Host keymapped held NOTE"
  phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
  phrase.number_of_lines = 128
  phrase.visible_note_columns = 1
  phrase.visible_effect_columns = 0
  phrase.instrument_column_visible = false
  phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
  phrase.lpb = 8
  phrase.shuffle = 0
  phrase.autoseek = false
  phrase.loop_start = 1
  phrase.loop_end = phrase.number_of_lines
  phrase.looping = false
  phrase:line(1).note_columns[1].note_value = 48
  phrase:line(1).note_columns[1].instrument_value = 255
  assert(instrument:can_insert_phrase_mapping_at(1), "Could not insert a probe phrase mapping")
  local mapping = instrument:insert_phrase_mapping_at(1, phrase)
  mapping.note_range = { 48, 48 }
  mapping.key_tracking = renoise.InstrumentPhraseMapping.KEY_TRACKING_NONE
  assert(mapping.phrase == phrase and mapping.note_range[1] == 48
    and mapping.note_range[2] == 48, "The diagnostic phrase key mapping did not read back")
  instrument.phrase_playback_mode = renoise.Instrument.PHRASES_PLAY_KEYMAP
  instrument.phrase_program = 127
  mapped_note = 48
else
  assert(instrument.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
    "Selective probe must be in Selective phrase mode")
  assert(#instrument.phrases < 126, "No phrase program is available for the isolated host control")
  phrase_index = #instrument.phrases + 1
  local phrase = instrument:insert_phrase_at(phrase_index)
  phrase.name = "Host lifecycle held NOTE"
  phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
  phrase.number_of_lines = is_transport_case and 256 or 128
  phrase.visible_note_columns = 1
  phrase.visible_effect_columns = 0
  phrase.instrument_column_visible = false
  phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
  phrase.lpb = 8
  phrase.shuffle = 0
  phrase.autoseek = false
  phrase.loop_start = 1
  phrase.loop_end = phrase.number_of_lines
  phrase.looping = false
  local note = phrase:line(1).note_columns[1]
  note.note_value = 48
  note.instrument_value = 255
  instrument.phrase_program = phrase_index
  mapped_note = 48
end

local trigger_track = song:insert_track_at(math.max(1, #song.tracks - 1))
trigger_track.name = track_name
assert(trigger_track.max_note_columns > 0, "Could not create a note trigger track")
trigger_track.visible_note_columns = 1
local track_index
for index, track in ipairs(song.tracks) do
  if rawequal(track, trigger_track) then track_index = index break end
end
assert(track_index, "Could not resolve the trigger track index")

local sequence_index = #song.sequencer.pattern_sequence + 1
local pattern_index = song.sequencer:insert_new_pattern_at(sequence_index)
local pattern = song.patterns[pattern_index]
pattern.name = pattern_name
pattern.number_of_lines = is_transport_case and 256 or 128
local pattern_track = pattern:track(track_index)
local function put_note(line_index, note_value)
  local cell = pattern_track:line(line_index).note_columns[1]
  cell.note_value = note_value
  if note_value ~= renoise.PatternLine.NOTE_OFF then
    cell.instrument_value = instrument_index - 1
  end
end

put_note(note_on_line, mapped_note)
if case_name == "fresh_retrigger" then
  put_note(event_line, mapped_note)
  put_note(note_off_line, renoise.PatternLine.NOTE_OFF)
else
  put_note(note_off_line, renoise.PatternLine.NOTE_OFF)
end

song.transport.bpm = bpm
song.transport.lpb = 8
song.transport.tpl = 12
song.selected_instrument_index = instrument_index
song.selected_track_index = track_index
song.selected_sequence_index = sequence_index
song.transport.playback_pos = renoise.SongPos(sequence_index, 1)

local seconds_per_line = 60 / (bpm * 8)
print("Created " .. case_name .. " host control in sequence " .. sequence_index .. ".")
print("Phrase program " .. tostring(case_name == "keymapped_trigger" and 127 or phrase_index)
  .. ", " .. tostring(preroll_steps) .. " silent pre-roll steps, trigger note " .. mapped_note
  .. " at line " .. note_on_line .. ", "
  .. (case_name == "fresh_retrigger" and ("same-pitch retrigger at line " .. event_line .. ", ") or "")
  .. "host OFF at line " .. note_off_line .. ".")
print(string.format("Event offsets: retrigger=%s s, host OFF=%.3f s; pattern wrap=%.3f s at %d BPM.",
  case_name == "fresh_retrigger" and string.format("%.3f", (event_line - note_on_line) * seconds_per_line) or "n/a",
  (note_off_line - note_on_line) * seconds_per_line, pattern.number_of_lines * seconds_per_line, bpm))
print("Render/capture the selected sequence only. Events are native song-pattern notes; this helper does not establish acoustic acceptance.")
rawset(_G, "ACID_HOST_LIFECYCLE_CASE", nil)
rawset(_G, "ACID_HOST_LIFECYCLE_BPM", nil)
