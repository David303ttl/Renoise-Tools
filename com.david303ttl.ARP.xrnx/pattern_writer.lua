-- Pattern I/O for the first experimental ARP generator.
-- Safety rule: never overwrite occupied destination note column 1.
-- Current limitation: produces note-ons only (no note-offs or gate).
local M = {}
local engine = require("arp_engine")

local function valid_track(song, index)
  local track = song.tracks[index]
  return track and track.type == renoise.Track.TRACK_TYPE_SEQUENCER
end

function M.track_choices()
  local song = renoise.song()
  local labels, indices = {}, {}
  for i, track in ipairs(song.tracks) do
    if valid_track(song, i) then
      labels[#labels+1] = string.format("%02d: %s", i, track.name)
      indices[#indices+1] = i
    end
  end
  return labels, indices
end

function M.generate(source_index, dest_index, rate, mode)
  local song = renoise.song()
  if not song then return nil, "No song loaded" end
  if source_index == dest_index then
    return nil, "Choose different source and destination tracks"
  end
  if not valid_track(song, source_index) or not valid_track(song, dest_index) then
    return nil, "Both tracks must be sequencer tracks"
  end
  local pattern = song.selected_pattern
  local source = pattern.tracks[source_index]
  local dest = pattern.tracks[dest_index]
  local lines = pattern.number_of_lines
  local chords = {}

  for line_index = 1, lines do
    local line = source:line(line_index)
    local notes = {}
    local instrument = nil
    for col = 1, song.tracks[source_index].visible_note_columns do
      local cell = line.note_columns[col]
      if cell and cell.note_value <= 119 then
        notes[#notes+1] = cell.note_value
        if not instrument and cell.instrument_value < 255 then
          instrument = cell.instrument_value
        end
      end
    end
    if #notes > 0 then
      chords[#chords+1] = {
        line = line_index,
        notes = notes,
        instrument = instrument or (song.selected_instrument_index - 1)
      }
    end
  end

  if #chords == 0 then return nil, "No source notes found in the selected pattern" end
  local events = engine.generate(chords, lines, rate, mode)
  if #events == 0 then return nil, "No notes to generate" end
  if song.tracks[dest_index].visible_note_columns < 1 then
    return nil, "Destination needs at least one visible note column"
  end

  -- Preflight every cell before changing anything. This deliberately
  -- rejects an occupied first note column anywhere in the pattern.
  for line_index = 1, lines do
    local col = dest:line(line_index).note_columns[1]
    if not col or not col.is_empty then
      return nil, "Destination note column 1 is not empty; no changes made"
    end
  end

  -- Single undo boundary; all potentially failing validations above.
  for _, ev in ipairs(events) do
    local col = dest:line(ev.line).note_columns[1]
    col.note_value = ev.note
    col.instrument_value = ev.instrument
  end
  song:describe_undo("ARP: generate pattern arpeggio")
  return #events, nil
end

return M
