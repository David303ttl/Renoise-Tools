-- Simple functional ViewBuilder scaffold: read-only inspection and
-- an illustrative, deterministic note-ordering preview.
local M = {}
local engine = require("arp_engine")
local pattern_writer = require("pattern_writer")
local dialog

function M.show()
  if dialog and dialog.visible then
    dialog:show()
    return
  end

  local vb = renoise.ViewBuilder()
  local preview = vb:text { width = 350, text = "" }
  local status = vb:text {
    width = 350,
    text = "Read-only scaffold: no pattern events will be written."
  }
  local modes = { "up", "down", "up_down" }

  local function update_preview(mode)
    local notes = engine.order_notes({60, 64, 67}, mode)
    preview.text = "Example MIDI notes: " .. table.concat(notes, ", ")
  end

  local content = vb:column {
    margin = 12,
    spacing = 8,
    vb:text { text = "ARP.xrnx 0.1 - development scaffold" },
    vb:text { text = "Source routing, pattern rendering and regeneration: pending." },
    vb:row {
      spacing = 8,
      vb:text { text = "Order" },
      vb:popup {
        width = 120,
        items = { "Up", "Down", "Up-Down" },
        value = 1,
        notifier = function(index)
          update_preview(modes[index])
        end
      }
    },
    preview,
    vb:button {
      text = "Inspect selected pattern (read only)",
      notifier = function()
        local message, err = pattern_writer.inspect_selection()
        status.text = message or err
      end
    },
    status
  }

  update_preview(modes[1])
  dialog = renoise.app():show_custom_dialog("ARP", content)
end

return M
