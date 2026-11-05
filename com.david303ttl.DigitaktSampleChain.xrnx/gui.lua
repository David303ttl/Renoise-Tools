-- SPDX-License-Identifier: GPL-3.0-only
local chain_options = require("chain_options")
local runner = require("export_runner")

local M = {}

local dialog = nil
local current_job = nil

local DIALOG_TITLE = "Digitakt Sample Chain"
local PROMPT_TITLE = "Export Digitakt Chain"
local PROMPT_EXTENSION = "wav"
local LOG_PREFIX = "[DigitaktSampleChain] "
local WIDTH = { INFO = 540, MODE = 250, SLOTS = 100, MONO = 200, BUTTON = 120 }
local MARGIN, SPACING = 10, 8

function M.show()
  if dialog and dialog.visible then
    dialog:show()
    return
  end
  if current_job then current_job:cancel() end

  local options = chain_options.defaults()
  local vb = renoise.ViewBuilder()

  local status = vb:text { text = "", width = WIDTH.INFO }
  local duration = vb:text { text = "", width = WIDTH.INFO }
  local slot_selector, pad_checkbox
  local export_button, cancel_button
  local opened_dialog
  local controls = {}
  local function is_open() return opened_dialog and opened_dialog.visible end
  local function set_text(view, text)
    if is_open() then view.text = text end
  end
  local function apply_mode_dependencies()
    local spaced = options.mode == "spaced" and not current_job
    slot_selector.active = spaced
    pad_checkbox.active = spaced
  end

  local function set_running(running, message)
    if not running then current_job = nil end
    if not is_open() then return end
    for _, control in ipairs(controls) do control.active = not running end
    export_button.active = not running
    cancel_button.active = running
    apply_mode_dependencies()
    if message then set_text(status, message) end
  end

  local callbacks = {
    on_progress = function(message)
      if not is_open() then
        if current_job then current_job:cancel() end
        return
      end
      set_text(status, message)
    end,
    on_finish = function(result)
      set_running(false, string.format("Exported %d slots (%d frames @ %d Hz).",
        result.slot_count, result.frames, result.sample_rate))
      local label = result.mode == "chain" and "Mean Sample" or "Slot"
      set_text(duration, string.format("%s: %.3f sec  |  Total: %.3f sec",
        label, result.slot_sec, result.total_sec))
      if result.warning then
        print(LOG_PREFIX .. result.warning)
        if is_open() then renoise.app():show_warning(result.warning) end
      end
    end,
    on_error = function(err)
      set_running(false, "Export failed.")
      print(LOG_PREFIX .. tostring(err))
      if is_open() then renoise.app():show_error(tostring(err)) end
    end,
    on_cancel = function(message)
      message = message or "Export canceled."
      print(LOG_PREFIX .. message)
      set_running(false, message)
    end,
  }

  local function start_export()
    if current_job then return end
    set_text(duration, "")
    set_text(status, "")
    local song = renoise.song()
    if not song then
      renoise.app():show_warning("Open a Renoise song first.")
      return
    end
    local path = renoise.app():prompt_for_filename_to_write(
      PROMPT_EXTENSION, PROMPT_TITLE)
    if path == "" then return end
    local job, err = runner.start(song.selected_instrument, options, path, callbacks)
    if not job then
      set_text(status, "Export failed.")
      renoise.app():show_error(tostring(err))
      return
    end
    current_job = job
    set_running(true, "Exporting...")
  end

  local mode_selector = vb:popup {
    items = chain_options.export_mode_labels(),
    value = chain_options.DEFAULT_CHOICE,
    width = WIDTH.MODE,
    notifier = function(index)
      options.mode = chain_options.export_mode(index)
      apply_mode_dependencies()
    end,
  }

  slot_selector = vb:popup {
    items = chain_options.slot_count_labels(),
    value = chain_options.DEFAULT_CHOICE,
    width = WIDTH.SLOTS,
    notifier = function(index)
      options.slot_count = chain_options.slot_count(index)
    end,
  }

  local fade_checkbox = vb:checkbox {
    value = options.fade,
    notifier = function(value) options.fade = value end,
  }

  local dither_checkbox = vb:checkbox {
    value = options.dither,
    notifier = function(value) options.dither = value end,
  }

  pad_checkbox = vb:checkbox {
    value = options.zero_pad,
    notifier = function(value) options.zero_pad = value end,
  }

  local mono_selector = vb:popup {
    items = chain_options.mono_mode_labels(),
    value = chain_options.DEFAULT_CHOICE,
    width = WIDTH.MONO,
    notifier = function(index)
      options.mono = chain_options.mono_mode(index)
    end,
  }
  controls = { mode_selector, slot_selector, fade_checkbox, dither_checkbox,
    pad_checkbox, mono_selector }

  export_button = vb:button {
    text = "Export Chain",
    width = WIDTH.BUTTON,
    notifier = start_export,
  }

  cancel_button = vb:button {
    text = "Cancel Export",
    width = WIDTH.BUTTON,
    active = false,
    notifier = function()
      if current_job then current_job:cancel() end
    end,
  }

  local function row(label, control)
    return vb:horizontal_aligner {
      mode = "justify",
      vb:text { text = label },
      control,
    }
  end

  local content = vb:column {
    margin = MARGIN,
    spacing = SPACING,

    vb:text { text = "Export Digitakt Sample Chain" },
    row("Export Mode:", mode_selector),
    row("Slot Count (Optional):", slot_selector),
    row(string.format("Apply %d ms fade-out to each sample", chain_options.FADE_OUT_MS), fade_checkbox),
    row("Apply Dither (TPDF):", dither_checkbox),
    row(string.format("Pad both slot edges with %d silent frames", chain_options.EDGE_SILENCE_FRAMES), pad_checkbox),
    row("Mono Conversion:", mono_selector),
    vb:text { text = string.format("%d Hz sources required. Mono sources use their only channel.",
      chain_options.SAMPLE_RATE) },

    vb:horizontal_aligner {
      mode = "center",
      export_button,
      vb:space { width = SPACING },
      cancel_button,
    },
    vb:horizontal_aligner { mode = "center", status },
    vb:horizontal_aligner { mode = "center", duration },
  }

  opened_dialog = renoise.app():show_custom_dialog(DIALOG_TITLE, content)
  dialog = opened_dialog
end

return M
