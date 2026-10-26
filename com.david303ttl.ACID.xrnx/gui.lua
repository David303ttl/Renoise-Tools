-- Read-only ACID tool scaffold with independent pitch/timing state.
local M = {}
local sequencer = require("model.sequencer")
local pattern_writer = require("renoise.selection_context")
local dialog

function M.show()
  if dialog and dialog.visible then
    dialog:show()
    return
  end

  local vb = renoise.ViewBuilder()
  local state = sequencer.new_pattern(16)
  local summary = vb:text { width = 350, text = assert(sequencer.describe(state)) }
  local status = vb:text {
    width = 350,
    text = "Read-only scaffold: no Renoise notes will be written."
  }
  local lengths = {8, 12, 16}

  local content = vb:column {
    margin = 12,
    spacing = 8,
    vb:text { text = "ACID.xrnx 0.1 - development scaffold" },
    vb:text { text = "Pitch/time editing, accent and slide: pending." },
    vb:row {
      spacing = 8,
      vb:text { text = "Timing steps" },
      vb:popup {
        width = 100,
        items = { "8", "12", "16" },
        value = 3,
        notifier = function(index)
          state = sequencer.new_pattern(lengths[index])
          summary.text = assert(sequencer.describe(state))
        end
      }
    },
    summary,
    vb:button {
      text = "Inspect selected pattern (read only)",
      notifier = function()
        local message, err = pattern_writer.inspect_selection()
        status.text = message or err
      end
    },
    status
  }

  dialog = renoise.app():show_custom_dialog("ACID", content)
end

return M
