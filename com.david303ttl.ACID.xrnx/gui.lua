-- ACID 0.1: native phrase integration test UI.
local M = {}
local sequencer = require("sequencer")
local writer = require("pattern_writer")
local phrase_writer = require("phrase_writer")
local dialog
local document_generation = 0
local dialog_generation = -1

renoise.tool().app_new_document_observable:add_notifier(function()
  document_generation = document_generation + 1
  phrase_writer.cancel()
end)

function M.show()
  if dialog and dialog.visible then
    if dialog_generation == document_generation then
      dialog:show()
      return
    end
    dialog:close()
    dialog = nil
  end
  local song = renoise.song()
  if not song then
    renoise.app():show_warning("Open a song first.")
    return
  end
  local opened_generation = document_generation
  local vb = renoise.ViewBuilder()
  local state = sequencer.new_pattern(16)
  local summary = vb:text {
    width = 465, text = assert(sequencer.describe(state))
  }
  local status = vb:text {
    width = 465, text = "Use a sample instrument with no existing phrases."
  }
  local labels = {}
  for i, instrument in ipairs(song.instruments) do
    local name = instrument.name ~= "" and instrument.name or "(unnamed)"
    labels[i] = string.format("%02X: %s", i-1, name)
  end
  if #labels == 0 then
    renoise.app():show_warning("The song has no instruments.")
    return
  end
  local selected = math.min(song.selected_instrument_index, #labels)
  local lengths = {8, 12, 16}
  local content = vb:column {
    margin = 12, spacing = 8,
    vb:text {text = "ACID.xrnx 0.1 - first phrase playback test"},
    vb:text {text = "Fixed 8-step NOTE / TIE / REST fixture. No slide yet."},
    vb:row {
      vb:text {text="Target sample instrument"},
      vb:popup {
        width=270, items=labels, value=selected,
        notifier=function(index) selected=index end
      }
    },
    vb:button {
      text = "Generate Test Phrase (new phrase only)",
      notifier = function()
        if opened_generation ~= document_generation then
          status.text = "Song changed. Close and reopen ACID."
          return
        end
        local ok, generated, err = pcall(
          phrase_writer.generate, selected, function(message)
            if opened_generation == document_generation then
              status.text = message
            end
          end
        )
        if not ok then status.text = "ACID error: " .. tostring(generated)
        elseif not generated then status.text = err or "Generation refused" end
      end
    },
    vb:text {text = "Draft model inspection (does not write patterns):"},
    vb:row {
      vb:text {text = "Timing steps"},
      vb:popup {
        width = 100,
        items = {"8", "12", "16"},
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
        local message, err = writer.inspect_selection()
        status.text = message or err
      end
    },
    status
  }
  dialog = renoise.app():show_custom_dialog("ACID", content)
  dialog_generation = opened_generation
end
return M
