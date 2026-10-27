local function make_song()
  local lines_by_pattern = {}
  local song = {
    instruments = {{
      name = "ACID ARTICULATION PROBE",
      phrase_playback_mode = 1,
      phrase_program = 1,
      phrases = {{}}
    }},
    tracks = {
      {name = "Instrument", max_note_columns = 12, visible_note_columns = 1},
      {name = "Master", max_note_columns = 0}
    },
    patterns = {{name = "Existing", number_of_lines = 64}},
    transport = {
      playing = false,
      bpm = 120,
      lpb = 4,
      tpl = 6,
      groove_enabled = true,
      loop_block_enabled = true,
      loop_pattern = true,
      loop_sequence_range = {1, 1}
    }
  }
  local sequence = {1}
  song.sequencer = {pattern_sequence = sequence}
  function song.sequencer:insert_new_pattern_at(sequence_index)
    assert(sequence_index == #self.pattern_sequence + 1)
    local pattern_index = #song.patterns + 1
    local pattern = {name = "", number_of_lines = 64}
    function pattern:track(track_index)
      if not lines_by_pattern[pattern_index] then lines_by_pattern[pattern_index] = {} end
      if not lines_by_pattern[pattern_index][track_index] then
        local track_lines = {}
        for line_index = 1, 512 do
          track_lines[line_index] = {
            note_columns = {{is_empty = true, volume_value = 255, panning_value = 255,
              delay_value = 0, effect_number_value = 0, effect_amount_value = 0}},
            effect_columns = {{is_empty = true}}
          }
        end
        lines_by_pattern[pattern_index][track_index] = track_lines
      end
      return {line = function(_, line_index)
        return lines_by_pattern[pattern_index][track_index][line_index]
      end}
    end
    song.patterns[pattern_index] = pattern
    self.pattern_sequence[sequence_index] = pattern_index
    return pattern_index
  end
  function song:insert_track_at(index)
    local track = {name = "", max_note_columns = 12, visible_note_columns = 1}
    table.insert(self.tracks, index, track)
    return track
  end
  function song:describe_undo(label) self.undo_label = label end
  return song, lines_by_pattern
end

local function configure(song, steps)
  _G.ACID_LONG_CAPTURE_STEPS = steps
  _G.ACID_LONG_CAPTURE_TAIL_SECONDS = 3
  _G.ACID_LONG_CAPTURE_PREROLL_SECONDS = 2
  _G.ACID_ARTICULATION_BPM = 120
  _G.ACID_ARTICULATION_PROBE_NAME = "ACID ARTICULATION PROBE"
  _G.renoise = {
    song = function() return song end,
    Pattern = {MAX_NUMBER_OF_LINES = 512},
    PatternLine = {NOTE_OFF = 120},
    Instrument = {PHRASES_PLAY_SELECTIVE = 1},
    SongPos = function(sequence, line) return {sequence = sequence, line = line} end
  }
end

local function build(steps)
  local song, lines = make_song()
  configure(song, steps)
  dofile("tests/acid/renoise_long_repeat_trigger.lua")
  return song, lines
end

local song, lines = build(256)
assert(song.undo_label == "Create disposable long articulation capture trigger")
assert(#song.sequencer.pattern_sequence == 4, "Expected original, pre-roll, and two trigger parts")
assert(song.patterns[2].name == "ACID LONG CAPTURE PREROLL")
assert(song.patterns[2].number_of_lines == 32)
assert(song.patterns[3].name == "ACID LONG CAPTURE 01")
assert(song.patterns[3].number_of_lines == 512)
assert(song.patterns[4].name == "ACID LONG CAPTURE 02")
assert(song.patterns[4].number_of_lines == 48)
assert(song.transport.playback_pos.sequence == 2 and song.transport.playback_pos.line == 1)
assert(song.selected_sequence_index == 2)
assert(ACID_RENDER_START_SEQUENCE == 2 and ACID_RENDER_START_LINE == 1)
assert(ACID_RENDER_END_SEQUENCE == 4 and ACID_RENDER_END_LINE == 48)
assert(ACID_RENDER_CONTEXT == "long_repeat_trigger;steps=256;phrase_program=1")
assert(song.transport.bpm == 120 and song.transport.lpb == 8 and song.transport.tpl == 12)
assert(not song.transport.groove_enabled and not song.transport.loop_block_enabled
  and not song.transport.loop_pattern and #song.transport.loop_sequence_range == 0)

local trigger_track_index
for index, track in ipairs(song.tracks) do
  if track.name == "ACID LONG CAPTURE" then trigger_track_index = index end
end
assert(trigger_track_index)
local note_cell = lines[3][trigger_track_index][1].note_columns[1]
assert(note_cell.note_value == 48 and note_cell.instrument_value == 0)
local off_cell = lines[4][trigger_track_index][1].note_columns[1]
assert(off_cell.note_value == 120)
local trigger_notes, trigger_offs = 0, 0
for pattern_index = 3, 4 do
  for line_index = 1, song.patterns[pattern_index].number_of_lines do
    local cell = lines[pattern_index][trigger_track_index][line_index].note_columns[1]
    if cell.note_value == 48 then trigger_notes = trigger_notes + 1 end
    if cell.note_value == 120 then trigger_offs = trigger_offs + 1 end
  end
end
assert(trigger_notes == 1 and trigger_offs == 1, "Long trigger must contain one NOTE and one OFF")

local short_song = build(68)
assert(short_song.patterns[3].number_of_lines == 184)
local collision_song = make_song()
collision_song.patterns[2] = {name = "ACID LONG CAPTURE PREROLL", number_of_lines = 64}
local old_pattern_count, old_track_count = #collision_song.patterns, #collision_song.tracks
configure(collision_song, 256)
assert(not pcall(function() dofile("tests/acid/renoise_long_repeat_trigger.lua") end))
assert(#collision_song.patterns == old_pattern_count and #collision_song.tracks == old_track_count,
  "Name collision must refuse before mutation")

local large_song = make_song()
configure(large_song, 26000)
old_pattern_count, old_track_count = #large_song.patterns, #large_song.tracks
assert(not pcall(function() dofile("tests/acid/renoise_long_repeat_trigger.lua") end))
assert(#large_song.patterns == old_pattern_count and #large_song.tracks == old_track_count,
  "Unsupported capture size must refuse before mutation")

print("ACID long Repeat trigger boundary checks passed")
