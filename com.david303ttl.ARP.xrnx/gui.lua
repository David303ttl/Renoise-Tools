local M = {}
local writer = require("pattern_writer")
local dialog
function M.show()
  if dialog and dialog.visible then dialog:show(); return end
  local song = renoise.song()
  if not song then
    renoise.app():show_warning("Open a Renoise song first.")
    return
  end
  local labels, indices = writer.track_choices()
  if #indices < 2 then
    renoise.app():show_warning("ARP requires at least two sequencer tracks.")
    return
  end
  local vb = renoise.ViewBuilder()
  local source_choice, dest_choice = 1, 2
  for i, idx in ipairs(indices) do
    if idx == song.selected_track_index then source_choice = i end
  end
  dest_choice = source_choice == 1 and 2 or 1
  local divisions = {"1/4", "1/8", "1/16", "1/32"}
  local modes = {"up", "down", "up_down"}
  local rate_choice, mode_choice, octave_choice = 3, 1, 1
  local status = vb:text {
    width = 410, text = "Only note-ons. Destination column 1 must be empty."
  }
  local content = vb:column {
    margin = 12, spacing = 8,
    vb:text { text = "ARP.xrnx v0.3 - experimental generator" },
    vb:row {
      vb:text { text = "Source track" },
      vb:popup { width = 255, items = labels, value = source_choice,
        notifier = function(v) source_choice = v end }
    },
    vb:row {
      vb:text { text = "Destination track" },
      vb:popup { width = 255, items = labels, value = dest_choice,
        notifier = function(v) dest_choice = v end }
    },
    vb:row {
      vb:text { text = "Rate" },
      vb:popup { width = 90, items = divisions, value = rate_choice,
        notifier = function(v) rate_choice = v end },
      vb:text { text = "Order" },
      vb:popup { width = 110, items = {"Up", "Down", "Up-Down"},
        value = mode_choice, notifier = function(v) mode_choice = v end },
      vb:text { text = "Octaves" },
      vb:popup { width = 60, items = {"1", "2", "3", "4"},
        value = octave_choice, notifier = function(v) octave_choice = v end }
    },
    vb:button {
      text = "Generate into empty destination",
      notifier = function()
        local count, err = writer.generate(indices[source_choice],
          indices[dest_choice], divisions[rate_choice],
          modes[mode_choice], octave_choice)
        status.text = err or ("Generated " .. tostring(count) .. " note events.")
      end
    },
    status,
    vb:text { text = "Sub-line rates are refused. Gate and regeneration: pending." }
  }
  dialog = renoise.app():show_custom_dialog("ARP", content)
end
return M
