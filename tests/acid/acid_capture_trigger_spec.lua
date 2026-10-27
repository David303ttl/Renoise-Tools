-- Host trigger duration and validation without Renoise playback.
local function check(condition, message)
  assert(condition, message)
end

local function cell()
  local result = { note_value = 121, instrument_value = 255,
    volume_value = 255, panning_value = 255, delay_value = 0,
    effect_number_value = 0, effect_amount_value = 0 }
  function result:clear()
    self.note_value = 121
    self.instrument_value = 255
  end
  return setmetatable(result, { __index = function(self, key)
    if key == "is_empty" then return self.note_value == 121 end
  end })
end

local lines = {}
local pattern_track = {}
function pattern_track:line(index)
  if not lines[index] then
    lines[index] = { note_columns = { cell() }, effect_columns = {} }
  end
  return lines[index]
end
local pattern = { name = "ACID ARTICULATION TRIGGER", number_of_lines = 64 }
function pattern:track() return pattern_track end
local track = { name = "ACID ARTICULATION TRIGGER", max_note_columns = 12 }
local song = {
  instruments = { {
    name = "ACID ARTICULATION PROBE", phrases = { {}, {}, {}, {}, {}, {}, {} },
    phrase_playback_mode = 1, phrase_program = 1,
  } },
  tracks = { track }, patterns = { pattern },
  sequencer = { pattern_sequence = { 1 } }, transport = {},
}
function song.sequencer:pattern(index) return self.pattern_sequence[index] end
function song:describe_undo() end
function song.transport:stop() self.stop_count = (self.stop_count or 0) + 1 end
function song.transport:start_at(position) self.started_at = position end
renoise = {
  song = function() return song end,
  Instrument = { PHRASES_PLAY_SELECTIVE = 1 }, Pattern = { MAX_NUMBER_OF_LINES = 512 },
  PatternLine = { NOTE_OFF = 120 },
  SongPos = function(sequence, line) return { sequence = sequence, line = line } end,
}

local function configure(steps, tail)
  ACID_ARTICULATION_CAPTURE_STEPS = steps
  ACID_ARTICULATION_TAIL_SECONDS = tail
  dofile("tests/acid/renoise_articulation_trigger.lua")
end
setmetatable(_G, { __index = function(_, name) error("Undeclared global: " .. name) end })
configure(nil, nil)
setmetatable(_G, nil)
check(pattern.number_of_lines == 224 and lines[137].note_columns[1].note_value == 120,
  "Default calibration timing changed")
configure(160, 3)
check(pattern.number_of_lines == 368 and lines[321].note_columns[1].note_value == 120,
  "Long capture did not move OFF and extend the pattern")
check(lines[137].note_columns[1].is_empty, "Reconfiguration left the previous OFF")
setmetatable(_G, { __index = function(_, name) error("Undeclared global: " .. name) end })
dofile("tests/acid/renoise_articulation_start.lua")
setmetatable(_G, nil)
check(song.transport.started_at.sequence == 1 and song.transport.started_at.line == 1,
  "Playback did not start at the configured trigger")
check(song.transport.stop_count == 2, "Cold start did not silence existing voices")
check(song.transport.groove_enabled == false and song.transport.metronome_enabled == false
  and song.transport.loop_block_enabled == false and song.transport.loop_pattern == false
  and #song.transport.loop_sequence_range == 0,
  "Playback retained timing or loop contamination")
local ok = pcall(configure, 300, 3)
check(not ok and pattern.number_of_lines == 368, "Oversized capture mutated the pattern")
ok = pcall(configure, 68, 1)
check(not ok, "Insufficient capture tail was accepted")
for _, bpm in ipairs({ 90, 150 }) do
  ACID_ARTICULATION_BPM = bpm
  configure(68, 3)
  check(pattern.number_of_lines == 136 + math.ceil(3 * bpm * 8 / 60),
    "Tempo sweep did not preserve the requested tail in seconds")
  check(lines[137].note_columns[1].note_value == 120,
    "Tempo sweep changed the capture length in steps")
  dofile("tests/acid/renoise_articulation_start.lua")
  check(song.transport.bpm == bpm, "Start lost the explicit capture BPM")
end
ACID_ARTICULATION_BPM = 120
check(not pcall(dofile, "tests/acid/renoise_articulation_start.lua"),
  "Start accepted a BPM override changed after trigger configuration")
for _, bpm in ipairs({ 89, 91, 149, 151, math.huge, 0 / 0, "120" }) do
  ACID_ARTICULATION_BPM = bpm
  check(not pcall(configure, 68, 3), "Unsupported BPM was accepted by the trigger")
  check(not pcall(dofile, "tests/acid/renoise_articulation_start.lua"),
    "Unsupported BPM was accepted by start")
end
ACID_ARTICULATION_BPM = nil
configure(160, 3)
for _, bad_value in ipairs({ math.huge, -math.huge, 0 / 0 }) do
  check(not pcall(configure, bad_value, 3), "Nonfinite capture steps were accepted")
  check(not pcall(configure, 68, bad_value), "Nonfinite tail was accepted")
end
local function refuses_both(message)
  check(not pcall(configure, 68, 3), "Configure accepted " .. message)
  local stop_count = song.transport.stop_count
  check(not pcall(dofile, "tests/acid/renoise_articulation_start.lua"),
    "Start accepted " .. message)
  check(song.transport.stop_count == stop_count, "Rejected start changed playback")
end
song.instruments[2] = song.instruments[1]
refuses_both("duplicate probe instruments")
song.instruments[2] = nil
local first = lines[1].note_columns[1]
for _, property in ipairs({ "volume_value", "panning_value", "delay_value",
  "effect_number_value", "effect_amount_value" }) do
  local original = first[property]
  first[property] = 1
  refuses_both("modified " .. property)
  first[property] = original
end
lines[2].note_columns[2] = cell()
lines[2].note_columns[2].note_value = 55
refuses_both("a hidden note column")
lines[2].note_columns[2] = nil
lines[2].effect_columns[1] = { is_empty = false }
refuses_both("a host effect")
lines[2].effect_columns[1] = nil
configure(nil, nil)
check(lines[321].note_columns[1].is_empty, "Shortening left a hidden OFF beyond the new length")
pattern.number_of_lines = 140
ok = pcall(dofile, "tests/acid/renoise_articulation_start.lua")
check(not ok, "Start accepted a trigger with insufficient tail")
ACID_ARTICULATION_CAPTURE_STEPS = nil
ACID_ARTICULATION_TAIL_SECONDS = nil
ACID_ARTICULATION_BPM = nil
ACID_ARTICULATION_PROBE_NAME = "Unexpected instrument"
check(not pcall(configure, 8, 3), "Trigger accepted an arbitrary instrument name")
check(not pcall(dofile, "tests/acid/renoise_articulation_start.lua"),
  "Start accepted an arbitrary instrument name")
song.instruments[2] = { name = "ACID ARTICULATION MONO PROBE", phrases = { {}, {} },
  phrase_playback_mode = 1, phrase_program = 1 }
ACID_ARTICULATION_PROBE_NAME = "ACID ARTICULATION MONO PROBE"
configure(8, 3)
check(lines[1].note_columns[1].instrument_value == 1, "Trigger did not select native comparison")
dofile("tests/acid/renoise_articulation_start.lua")
ACID_ARTICULATION_PROBE_NAME = nil
check(not pcall(dofile, "tests/acid/renoise_articulation_start.lua"),
  "Start silently played the wrong comparison instrument")
configure(8, 3)
check(lines[1].note_columns[1].instrument_value == 0, "Trigger did not restore polyphonic reference")
print("ACID capture trigger duration checks passed (playback checked separately in Renoise)")
