-- Run manually in Renoise's Scripting Terminal on a disposable probe instrument.
-- This script only appends phrases to that explicitly named instrument.
local song = renoise.song()
assert(song, "Open the disposable probe song first")
local instrument = song.selected_instrument
assert(instrument and instrument.name == "ACID LOOP PROBE",
  'Select the dedicated instrument named "ACID LOOP PROBE"')
assert(#instrument.phrases == 0,
  "Probe instrument already has phrases; use a fresh disposable instrument")
local has_sample_data = false
for _, sample in ipairs(instrument.samples) do
  if sample.sample_buffer and sample.sample_buffer.has_sample_data then
    has_sample_data = true
    break
  end
end
assert(has_sample_data, "Load sample data before running the probe")
assert(#instrument.phrases + 4 <= renoise.Instrument.MAX_NUMBER_OF_PHRASES,
  "Probe instrument has insufficient phrase capacity")

local created = {}
local function set_note(phrase, line_index, note_value)
  local note = phrase:line(line_index).note_columns[1]
  note.note_value = note_value
  note.instrument_value = 255
end

local function make_phrase(name, line_count, loop_start, loop_end, notes)
  local phrase = instrument:insert_phrase_at(#instrument.phrases + 1)
  created[#created + 1] = phrase
  phrase.name = name
  phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
  phrase.number_of_lines = line_count
  phrase.visible_note_columns = 1
  phrase.visible_effect_columns = 0
  phrase.instrument_column_visible = false
  phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
  phrase.lpb = 8
  phrase.shuffle = 0
  phrase.autoseek = false
  phrase.loop_end = loop_end
  phrase.loop_start = loop_start
  for _, event in ipairs(notes) do set_note(phrase, event[1], event[2]) end
  phrase.looping = true
  return phrase
end

local ok, err = pcall(function()
  make_phrase("ACID LOOP PROBE | full 1-8", 8, 1, 8,
    {{1,36},{3,40},{5,43},{7,48},{8,50}})
  make_phrase("ACID LOOP PROBE | full 1-7", 8, 1, 7,
    {{1,36},{3,40},{5,43},{7,48},{8,50}})
  make_phrase("ACID LOOP PROBE | intro + 9-16", 16, 9, 16,
    {{1,36},{3,40},{5,43},{7,48},{9,36},{11,40},{13,43},{15,48},{16,50}})
  make_phrase("ACID LOOP PROBE | NOTE TIE NOTE REST", 8, 1, 8,
    {{1,36},{5,43},{7,renoise.PatternLine.NOTE_OFF}})
end)

if not ok then
  for index = #created, 1, -1 do
    local phrase = created[index]
    for phrase_index, existing in ipairs(instrument.phrases) do
      if rawequal(existing, phrase) then
        pcall(function() instrument:delete_phrase_at(phrase_index) end)
        break
      end
    end
  end
  local survivors = {}
  for _, phrase in ipairs(created) do
    for _, existing in ipairs(instrument.phrases) do
      if rawequal(existing, phrase) then survivors[#survivors + 1] = phrase.name end
    end
  end
  if #survivors == 0 then
    error("Probe setup failed; all phrases created by this run were removed: " .. tostring(err))
  end
  error("Probe setup failed; surviving created phrases need manual cleanup (" ..
    table.concat(survivors, ", ") .. "): " .. tostring(err))
end

print("Created four disposable ACID loop probe phrases on ACID LOOP PROBE.")
print("Set the instrument to selective phrase playback and trigger each phrase once.")
print("Endpoint phrases use LPB 8; 8 lines should repeat every one beat.")
print("The NOTE TIE NOTE REST phrase has NOTE at line 1, a TIE gap, NOTE at line 5, and OFF at line 7.")
