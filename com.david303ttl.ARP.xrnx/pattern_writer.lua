-- ARP v0.4 pattern writer with provenance-verified regeneration.
local M = {}
local engine = require("arp_engine")
local owned = require("ownership")

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

local function read_chords(song, source_index, pattern)
  local chords, source_track = {}, song.tracks[source_index]
  for line_number=1,pattern.number_of_lines do
    local notes, instrument = {}, nil
    local line = pattern.tracks[source_index]:line(line_number)
    for i=1,source_track.visible_note_columns do
      local col = line.note_columns[i]
      if col and col.note_value <= 119 then
        notes[#notes+1] = col.note_value
        if not instrument and col.instrument_value < 255 then
          instrument = col.instrument_value
        end
      end
    end
    if #notes > 0 then
      chords[#chords+1] = {
        line=line_number, notes=notes,
        instrument=instrument or song.selected_instrument_index - 1
      }
    end
  end
  return chords
end

local function destination_cell(track, line)
  return track:line(line).note_columns[1]
end

-- Owns only the first note column of the chosen destination. It never
-- touches other note columns or effect columns.
function M.generate(source_index, dest_index, division, mode, octaves, gate)
  local song = renoise.song()
  if not song then return nil, "Open a song first" end
  if source_index == dest_index then
    return nil, "Source and destination must be different"
  end
  if not valid_track(song, source_index) or not valid_track(song, dest_index) then
    return nil, "Both tracks must be sequencer tracks"
  end
  local rate, rate_error = engine.rate_lines(song.transport.lpb, division)
  if not rate then return nil, rate_error end
  local pattern = song.selected_pattern
  local length = pattern.number_of_lines
  local destination = pattern.tracks[dest_index]
  if destination.is_alias then
    return nil, "Destination is an aliased pattern track"
  end
  if song.tracks[dest_index].visible_note_columns < 1 then
    return nil, "Destination needs a visible note column"
  end
  local data_before = song.tool_data
  local records, load_error = owned.load(data_before)
  if not records then return nil, load_error end
  local previous, old_index = owned.find(
    records, song.selected_pattern_index, dest_index)

  if previous then
    if previous.source ~= source_index
      or previous.length ~= length
      or previous.pattern_name ~= owned.encode_name(pattern.name or "")
      or previous.dest_name ~= owned.encode_name(song.tracks[dest_index].name)
      or previous.source_name ~= owned.encode_name(song.tracks[source_index].name) then
      return nil, "ARP ownership differs (track, name or pattern length); no changes"
    end
  end

  for line=1,length do
    local cell = destination:line(line).note_columns[1]
    local expected = previous and previous.events[line] or nil
    if not owned.matches(cell,expected) then
      return nil, string.format(
        "Destination column changed at line %02d; refusing overwrite",line-1)
    end
  end

  local chords = read_chords(song,source_index,pattern)
  if #chords == 0 then return nil, "No source notes in selected pattern" end
  local plan, plan_error, note_count, off_count =
    engine.plan(chords,length,rate,mode,octaves,gate)
  if not plan then return nil, plan_error end
  if #plan == 0 then return nil, "No events to generate" end
  local new_by_line = {}
  for _,event in ipairs(plan) do
    if new_by_line[event.line] then
      return nil, "Two planned events share one note column line"
    end
    new_by_line[event.line] = event
  end

  local backup = {}
  for line=1,length do
    local cell = destination:line(line).note_columns[1]
    if not cell.is_empty or new_by_line[line] then
      backup[line]=owned.capture(cell)
    end
  end

  local next_record = {
    pattern=song.selected_pattern_index, destination=dest_index,
    source=source_index, length=length,
    pattern_name=owned.encode_name(pattern.name or ""),
    dest_name=owned.encode_name(song.tracks[dest_index].name),
    source_name=owned.encode_name(song.tracks[source_index].name),
    events={}
  }
  song:describe_undo(previous and "ARP: regenerate" or "ARP: generate")
  local ok, write_error = pcall(function()
    if previous then
      for line in pairs(previous.events) do
        destination:line(line).note_columns[1]:clear()
      end
    end
    for _, event in ipairs(plan) do
      local cell = destination:line(event.line).note_columns[1]
      cell.note_value = event.note
      if event.kind == "on" then cell.instrument_value = event.instrument end
      if event.delay > 0 then cell.delay_value = event.delay end
      next_record.events[event.line] = owned.capture(cell)
    end
    if old_index then records[old_index] = next_record
    else records[#records+1] = next_record end
    song.tool_data = owned.save(records)
  end)

  if not ok then
    local rollback_ok, rollback_error = pcall(function()
      for line=1,length do
        if backup[line] then
          owned.restore(destination:line(line).note_columns[1],backup[line])
        elseif previous and previous.events[line] then
          destination:line(line).note_columns[1]:clear()
        end
      end
      song.tool_data = data_before
    end)
    if not rollback_ok then
      return nil, "Write failed; rollback also failed: "..tostring(rollback_error)
    end
    return nil, "Write failed, restored previous output: "..tostring(write_error)
  end
  return {
    action=previous and "Regenerated" or "Generated",
    notes=note_count, offs=off_count
  }
end

return M
