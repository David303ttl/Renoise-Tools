-- Semantic ACID event compiler. Does not write Renoise notes/effects.
-- Events describe intended articulation, not assumptions about 0Gxx.
local sequencer = require("model.sequencer")
local M = {}

local function upcoming_loop_transition(end_pitch, has_rest)
  if not end_pitch or has_rest then return "attack" end
  return end_pitch.slide and "slide" or "retrigger"
end

function M.compile(pattern)
  local ok, err = sequencer.validate(pattern)
  if not ok then return nil, err end
  if #pattern.time_events ~= pattern.length then
    return nil, "time memory must have exactly one N/T/R value per step"
  end

  local pitch_count = #pattern.pitch_events
  local result = {
    length = pattern.length,
    steps = {},
    note_count = 0,
    pitch_count = pitch_count
  }
  local current, current_index = nil, nil
  local first_note_step, rest_before_first_note = nil, false

  for step = 1, pattern.length do
    local command = pattern.time_events[step]
    if command == "N" then
      if pitch_count == 0 then
        return nil, "NOTE requires at least one pitch entry"
      end
      local pitch_index = result.note_count % pitch_count + 1
      local pitch = pattern.pitch_events[pitch_index]
      local transition = "attack"
      if current then
        transition = current.slide and "slide" or "retrigger"
      end
      local event = {
        kind = "note", step = step, pitch_index = pitch_index,
        note = pitch.note, accent = pitch.accent == true,
        slide = pitch.slide == true, transition = transition,
        from_note = current and current.note or nil
      }
      result.steps[step] = event
      current, current_index = event, pitch_index
      result.note_count = result.note_count + 1
      if not first_note_step then first_note_step = step end
    elseif command == "T" then
      result.steps[step] = {
        kind = "tie", step = step, holds = current ~= nil,
        note = current and current.note or nil,
        pitch_index = current_index
      }
    else
      result.steps[step] = {
        kind = "rest", step = step, releases = current ~= nil,
        released_note = current and current.note or nil
      }
      current, current_index = nil, nil
      if not first_note_step then rest_before_first_note = true end
    end
  end

  result.boundary = {
    end_active = current ~= nil,
    end_note = current and current.note or nil,
    end_slide = current and current.slide or false,
    first_note_step = first_note_step,
    -- A normal first pass begins in silence. For a repeated pattern,
    -- a leading TIE may sustain the preceding iteration's last note.
    leading_tie_holds_on_loop =
      result.steps[1].kind == "tie" and current ~= nil,
    -- The native phrase renderer must resolve this across the loop point.
    loop_to_first_note = first_note_step and
      upcoming_loop_transition(current, rest_before_first_note) or nil
  }
  return result
end

return M
