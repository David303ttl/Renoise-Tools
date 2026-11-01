dofile("tests/bootstrap.lua")("acid")
local columns = dofile("tests/acid/phrase_columns.lua")
local pitch = dofile("tests/acid/pitch_fixture.lua")
local sequencer = require("model.sequencer")
local capacities = { lines = 32, notes = 4, effects = 2 }

local function make_phrase()
  local phrase = { name = "", number_of_lines = 16, lpb = 16, shuffle = 0,
    looping = false, loop_start = 1, loop_end = 16, playback_mode = 1,
    key_tracking = 1, base_note = 48, autoseek = false, visible_note_columns = 1,
    visible_effect_columns = 0, instrument_column_visible = false,
    volume_column_visible = true, panning_column_visible = false,
    delay_column_visible = false, sample_effects_column_visible = false,
    mapping = { key_tracking = 1, base_note = 48, loop_start = 1, loop_end = 16,
      looping = false, note_range = { 0, 119 } },
    script = { paragraphs = {}, parameters = {}, pending_changes = 0, editor_visible = true },
    cells = {}, column_names = {}, column_mutes = {} }
  for column = 1, 12 do
    phrase.column_names[column] = "column " .. tostring(column)
    phrase.column_mutes[column] = false
  end
  for line = 1, capacities.lines do
    phrase.cells[line] = { note_value = 121, instrument_value = 255, volume_value = 255,
      panning_value = 255, delay_value = 0, effect_number_value = 0, effect_amount_value = 0 }
  end
  function phrase:line(index) return columns.line(self, index) end
  function phrase:column_name(index) return self.column_names[index] end
  function phrase:column_is_muted(index) return self.column_mutes[index] end
  function phrase:set_column_name(index, value) self.column_names[index] = value end
  function phrase:set_column_is_muted(index, value) self.column_mutes[index] = value end
  return phrase
end

local function make_instrument(name)
  local instrument = { name = name, phrases = {},
    samples = { { sample_buffer = { has_sample_data = true } } },
    plugin_properties = { plugin_loaded = false, alias_instrument_index = 0,
      alias_fx_track_index = 0, alias_fx_device_index = 0, midi_output_routing_index = 0 },
    midi_output_properties = { device_name = "", instrument_type = 1, channel = 1 } }
  function instrument:insert_phrase_at(index)
    assert(index == #self.phrases + 1)
    local phrase = make_phrase()
    self.phrases[index] = phrase
    return phrase
  end
  function instrument:delete_phrase_at(index) table.remove(self.phrases, index) end
  return instrument
end

local instrument = make_instrument("Original")
local song = { instruments = { instrument }, tool_data = "",
  transport = { timing_model = 2, lpb = 16, tpl = 12, groove_enabled = false } }
function song:is_undo_redoing() return false end
_G.renoise = { Transport = { TIMING_MODEL_LPB = 2, TIMING_MODEL_SPEED = 1 },
  InstrumentPhrase = { PLAY_SCRIPT = 2, PLAY_PATTERN = 1, KEY_TRACKING_NONE = 1,
    MAX_NUMBER_OF_LINES = capacities.lines, MAX_NUMBER_OF_NOTE_COLUMNS = capacities.notes,
    MAX_NUMBER_OF_EFFECT_COLUMNS = capacities.effects },
  Instrument = { PHRASES_PLAY_SELECTIVE = 2, MAX_NUMBER_OF_PHRASES = 126 },
  song = function() return song end }

local writer = require("writers.phrase_writer")
local request_factory = dofile("tests/acid/writer_request.lua")
local ownership = require("renoise.phrase_ownership")
local store = require("renoise.pattern_store")

local function source(note)
  local pattern = sequencer.new_pattern(3)
  pattern.pitch_length = 2
  pattern.pitch_events[1] = pitch(note)
  pattern.pitch_events[2] = pitch(note + 2, true)
  pattern.time_events[1], pattern.time_events[2], pattern.time_events[3] = "N", "T", "R"
  return pattern
end

local function request(pattern, target, options)
  local result, reason = request_factory.build(song, 1, pattern, target, options)
  assert(result, type(reason) == "table" and reason.message or tostring(reason))
  return result
end

local function run(candidate)
  local calls, result = 0, nil
  local operation = candidate.kind == "create" and writer.create or writer.regenerate
  local accepted, rejection = operation(candidate, function(value)
    calls = calls + 1
    result = value
  end)
  return accepted, rejection, calls, result
end

local created = request(source(48), 1)
local accepted, rejection, calls, result = run(created)
assert(accepted, rejection and rejection.message)
assert(calls == 1 and result.kind == "success")
local phrase = result.phrase
local initial_id = assert(ownership.id(phrase))
local initial_source = assert(store.load(song, instrument, phrase))
local initial_raw = song.tool_data

-- Instrument-slot drift aborts before materialization and preserves both objects.
local replacement_instrument = make_instrument("Replacement")
local drift = request(source(52), 1)
local mutate = drift.mutate
function drift:mutate(token, action)
  song.instruments[1] = replacement_instrument
  return mutate(self, token, action)
end
local drift_ok, drift_rejection, drift_calls, drift_result = run(drift)
assert(drift_ok and drift_calls == 1 and drift_result.kind == "failure")
assert(drift_result.status == "failed" and drift_result.committed == false)
assert(rawequal(song.instruments[1], replacement_instrument)
  and rawequal(instrument.phrases[1], phrase) and #instrument.phrases == 1
  and #replacement_instrument.phrases == 0,
  "instrument drift triggered guessed deletion or touched the replacement slot")
assert(song.tool_data == initial_raw and ownership.id(phrase) == initial_id
  and sequencer.same_source(assert(store.read_entry(song, initial_id)), initial_source),
  "instrument drift changed committed phrase or source")
song.instruments[1] = instrument

-- Phrase inventory drift is preserved and blocked rather than guessed at.
local second = instrument:insert_phrase_at(2)
local moved = request(source(52), 1)
local moved_mutate = moved.mutate
function moved:mutate(token, action)
  table.remove(instrument.phrases, 1)
  instrument.phrases[2] = phrase
  return moved_mutate(self, token, action)
end
local moved_ok, moved_rejection, moved_calls, moved_result = run(moved)
assert(moved_ok and moved_calls == 1 and moved_result.kind == "failure")
assert(moved_result.status == "integrity_blocked" and moved_result.committed == false)
assert(#instrument.phrases == 2 and rawequal(instrument.phrases[2], phrase)
  and rawequal(instrument.phrases[1], second),
  "phrase inventory drift caused guessed reinsertion, deletion, or replacement")
assert(song.tool_data == initial_raw and ownership.id(phrase) == initial_id
  and writer.is_temporary(song, instrument, phrase) == false,
  "phrase inventory drift changed source or marked the existing phrase temporary")
instrument.phrases[1] = phrase
table.remove(instrument.phrases, 2)
writer.clear_integrity_blocker(song)

-- If source restoration fails after a verified commit, report the live revision.
local commit = store.commit
local restore = store.restore
local committed_status
store.commit = function(target_song, candidate)
  assert(commit(target_song, candidate))
  error("injected post-write source exception", 0)
end
store.restore = function(_, candidate)
  committed_status = store.candidate_status(candidate)
  return nil, "injected source restore failure"
end
local failed = request(source(56), 1)
local failed_ok, failed_rejection, failed_calls, failed_result = run(failed)
store.commit, store.restore = commit, restore
assert(failed_ok and failed_calls == 1 and failed_result.kind == "failure")
assert(failed_result.status == "integrity_blocked" and failed_result.committed == true)
assert(failed_result.recovery and #failed_result.recovery == 1
  and rawequal(failed_result.recovery[1].phrase, phrase),
  "source restore failure did not report its surviving phrase")
local new_id = assert(ownership.id(phrase))
assert(new_id ~= initial_id and committed_status.written_verified
  and song.tool_data == committed_status.written_raw,
  "source restore failure concealed the actual verified source write")
assert(sequencer.same_source(assert(store.load(song, instrument, phrase)), source(56)),
  "phrase and surviving committed source revision are inconsistent")
assert(writer.is_temporary(song, instrument, phrase) == false)

print("ACID writer identity and source rollback checks passed (mocked Renoise)")
