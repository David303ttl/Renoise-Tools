-- Compare native Mono/Glide without local portamento effects on a separate instrument.
local song = assert(renoise.song(), "Open the disposable ACID song copy first")
local rate = rawget(_G, "ACID_ARTICULATION_MONO_GLIDE") or 32
assert(type(rate) == "number" and rate == math.floor(rate) and rate >= 1 and rate <= 255,
  "Native Mono/Glide amount must be an integer from 1 to 255")
local source
for _, instrument in ipairs(song.instruments) do
  assert(instrument.name ~= "ACID ARTICULATION MONO PROBE",
    "A native Mono/Glide probe already exists; use a fresh disposable song copy")
  if instrument.name == "ACID ARTICULATION PROBE" then
    assert(not source, "Multiple articulation reference probes exist")
    source = instrument
  end
end
assert(source and #source.samples == 1 and source.samples[1].modulation_set_index == 1,
  "Create the diagnostic envelope reference probe first; restore its envelope if bypassed")
assert(not source.trigger_options.monophonic and source.trigger_options.monophonic_glide == 0,
  "Reference probe must retain its polyphonic trigger settings")
assert(#song.instruments < renoise.Song.MAX_NUMBER_OF_INSTRUMENTS,
  "Song has no free instrument slot")
local probe
local ok, err = pcall(function()
  song:describe_undo("Create disposable native Mono/Glide comparison")
  probe = song:insert_instrument_at(#song.instruments + 1)
  probe:copy_from(source)
  probe.name = "ACID ARTICULATION MONO PROBE"
  while #probe.phrases > 0 do probe:delete_phrase_at(#probe.phrases) end
  probe.trigger_options.monophonic = true
  probe.trigger_options.monophonic_glide = rate
  assert(probe.trigger_options.monophonic and probe.trigger_options.monophonic_glide == rate,
    "Native Mono/Glide settings did not read back")
  for index, destination in ipairs({ 55, 48 }) do
    local phrase = probe:insert_phrase_at(index)
    phrase.name = index == 1 and "Native Mono/Glide: 48 to 55" or "Native Mono/Glide: same-pitch control"
    phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    phrase.number_of_lines = 32
    phrase.visible_note_columns = 1
    phrase.visible_effect_columns = 1
    phrase.instrument_column_visible = false
    phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
    phrase.lpb = 16
    phrase.shuffle = 0
    phrase.autoseek = false
    phrase.looping = false
    phrase:line(1).note_columns[1].note_value = 48
    phrase:line(9).note_columns[1].note_value = destination
    phrase:line(21).note_columns[1].note_value = renoise.PatternLine.NOTE_OFF
  end
  probe.phrase_playback_mode = renoise.Instrument.PHRASES_PLAY_SELECTIVE
  probe.phrase_program = 1
  song.selected_instrument_index = #song.instruments
end)
if not ok then
  if probe then
    for index, instrument in ipairs(song.instruments) do
      if rawequal(instrument, probe) then song:delete_instrument_at(index); break end
    end
  end
  error("Native Mono/Glide comparison failed; its new instrument was removed: " .. tostring(err))
end
print("Created separate native Mono/Glide probe, amount=" .. tostring(rate)
  .. "; phrases contain no 0G commands. Envelope continuity and glide rate require audio verification.")
