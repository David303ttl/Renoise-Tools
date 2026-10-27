-- Host trigger duration and validation without Renoise playback.
local function check(condition, message)
  assert(condition, message)
end

local function cell()
  local result = { note_value = 121, instrument_value = 255 }
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
  if not lines[index] then lines[index] = { note_columns = { cell() } } end
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
function song.transport:stop() self.stopped = true end
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
configure(nil, nil)
check(pattern.number_of_lines == 224 and lines[137].note_columns[1].note_value == 120,
  "Default calibration timing changed")
configure(160, 3)
check(pattern.number_of_lines == 368 and lines[321].note_columns[1].note_value == 120,
  "Long capture did not move OFF and extend the pattern")
check(lines[137].note_columns[1].is_empty, "Reconfiguration left the previous OFF")
dofile("tests/acid/renoise_articulation_start.lua")
check(song.transport.started_at.sequence == 1 and song.transport.started_at.line == 1,
  "Playback did not start at the configured trigger")
local ok = pcall(configure, 300, 3)
check(not ok and pattern.number_of_lines == 368, "Oversized capture mutated the pattern")
ok = pcall(configure, 68, 1)
check(not ok, "Insufficient capture tail was accepted")
configure(nil, nil)
check(lines[321].note_columns[1].is_empty, "Shortening left a hidden OFF beyond the new length")
pattern.number_of_lines = 140
ok = pcall(dofile, "tests/acid/renoise_articulation_start.lua")
check(not ok, "Start accepted a trigger with insufficient tail")
ACID_ARTICULATION_CAPTURE_STEPS = nil
ACID_ARTICULATION_TAIL_SECONDS = nil
print("ACID capture trigger duration checks passed (playback checked separately in Renoise)")
