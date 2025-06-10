-- main.lua
-- This script provides the Graphical User Interface (GUI) and integrates the
-- Digitakt Sample Chain tool into Renoise.

local chain_exporter = require("chain_exporter")

--- Displays the main export dialog to the user.
local function show_export_dialog()
  local vb = renoise.ViewBuilder()

  -- Local variables to store current UI selections.
  local export_mode = "spaced"
  local slot_count = nil
  local apply_fade = false
  local apply_dither = false
  local pad_with_zero = false
  local mono_selection = "average"

  -- UI element: Popup for selecting export mode (Spaced or Chain).
  local mode_selector = vb:popup {
    id = "mode_selector",
    items = {"Spaced (Digitakt Grid)", "Chain (Direct Concatenation)"},
    value = 1,
    width = 250,
    notifier = function(index)
      export_mode = (index == 1) and "spaced" or "chain"
    end
  }

  -- UI element: Popup for selecting fixed slot count or "Auto".
  local slot_selector = vb:popup {
    id = "slot_selector",
    items = {"Auto", "4", "8", "16", "32", "64"},
    value = 1,
    width = 100,
    notifier = function(index)
      local values = {nil, 4, 8, 16, 32, 64}
      slot_count = values[index]
    end
  }

  -- UI element: Checkbox for applying short fade-out.
  local fade_checkbox = vb:checkbox {
    id = "fade_checkbox",
    value = false,
    notifier = function(value)
      apply_fade = value
    end
  }

  -- UI element: Checkbox for applying Dither.
  local dither_checkbox = vb:checkbox {
    id = "dither_checkbox",
    value = false,
    notifier = function(value)
      apply_dither = value
    end
  }

  -- UI element: Checkbox for padding each slot with zeros.
  local pad_zero_checkbox = vb:checkbox {
    id = "pad_zero_checkbox",
    value = false,
    notifier = function(value)
      pad_with_zero = value
    end
  }

  -- UI element: Popup for selecting mono conversion method.
  local mono_selector = vb:popup {
    id = "mono_selector",
    items = {"Average (Sum)", "Left Channel", "Right Channel"},
    value = 1,
    width = 200,
    notifier = function(index)
      local values = {"average", "left", "right"}
      mono_selection = values[index]
    end
  }

  -- Define the layout of the dialog content using column and horizontal aligners.
  local content = vb:column {
    margin = 10,
    spacing = 8,

    vb:text { text = "Export Digitakt Sample Chain" },

    -- Row for Export Mode selection.
    vb:horizontal_aligner {
      mode = "justify",
      vb:text { text = "Export Mode:" },
      mode_selector
    },

    -- Row for Slot Count selection.
    vb:horizontal_aligner {
      mode = "justify",
      vb:text { text = "Slot Count (Optional):" },
      slot_selector
    },

    -- Row for Fade-out checkbox.
    vb:horizontal_aligner {
      mode = "justify",
      vb:text { text = "Apply short fade-out to each slice" },
      fade_checkbox
    },

    -- Row for Dither checkbox.
    vb:horizontal_aligner {
      mode = "justify",
      vb:text { text = "Apply Dither (TPDF):" },
      dither_checkbox
    },

    -- Row for Zero Padding checkbox.
    vb:horizontal_aligner {
      mode = "justify",
      vb:text { text = "Pad each slot with 64 samples of zero" },
      pad_zero_checkbox
    },

    -- Row for Mono Conversion selection.
    vb:horizontal_aligner {
      mode = "justify",
      vb:text { text = "Mono Conversion:" },
      mono_selector
    },

    -- Row for displaying export duration info.
    vb:horizontal_aligner {
      mode = "center",
      vb:text { id = "duration_info", text = "" }
    },

    -- Row for the Export button.
    vb:horizontal_aligner {
      mode = "center",
      vb:button {
        text = "Export Chain",
        width = 120,
        notifier = function()
          chain_exporter.export(
            "digitakt_chain.wav",
            export_mode,
            slot_count,
            apply_fade,
            apply_dither,
            pad_with_zero,
            mono_selection 
          )
          -- Retrieve and display the last export duration info.
          local info = chain_exporter.get_last_export_info()
          local msg = string.format("Slot: %.3f sec  |  Total: %.3f sec", info.slot_sec, info.total_sec)
          vb.views.duration_info.text = msg
        end
      }
    }
  }

  renoise.app():show_custom_dialog("Digitakt Sample Chain", content)
end

-- Add menu entries in Renoise to access the tool.
renoise.tool():add_menu_entry {
  name = "Sample Editor:Export Digitakt Sample Chain",
  invoke = function()
    show_export_dialog()
  end
}