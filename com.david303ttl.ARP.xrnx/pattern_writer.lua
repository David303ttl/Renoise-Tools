-- Read-only song context helper for scaffold.
-- TODO: transactional destination-track note/event writer with undo support.
local M = {}

function M.inspect_selection()
  local song = renoise.song()
  if not song then
    return nil, "No song is loaded."
  end

  local pattern = song.selected_pattern
  local track = song.selected_track
  if not pattern or not track then
    return nil, "Select a pattern and track first."
  end

  return string.format(
    "Pattern %02d: %d lines | Track %02d: %s",
    song.selected_pattern_index,
    pattern.number_of_lines,
    song.selected_track_index,
    track.name
  )
end

return M
