-- SPDX-License-Identifier: GPL-3.0-only
-- Renoise GUI. Song objects do not support Lua's __eq operator.
local M = {}
local writer = require("pattern_writer")
local dialog
local document_generation = 0
local dialog_generation = nil

local function on_new_document()
  document_generation = document_generation + 1
end
renoise.tool().app_new_document_observable:add_notifier(on_new_document)

function M.show()
  if dialog and dialog.visible then
    if dialog_generation == document_generation then
      dialog:show()
      return
    end
    -- After loading a different song, rebuild track selectors from scratch.
    dialog:close()
    dialog = nil
  end

  local song = renoise.song()
  if not song then
    renoise.app():show_warning("Open a Renoise song first.")
    return
  end
  local opened_generation = document_generation
  local labels, indices = writer.track_choices()
  if #indices < 2 then
    renoise.app():show_warning("ARP needs at least two sequencer tracks.")
    return
  end
  local vb = renoise.ViewBuilder()
  local source_choice, dest_choice = 1, 2
  for i, index in ipairs(indices) do
    if index == song.selected_track_index then source_choice = i end
  end
  dest_choice = source_choice == 1 and 2 or 1
  local divisions = {"1/4","1/8","1/16","1/32"}
  local modes = {"up","down","up_down"}
  local gate_values = {25,50,75,100}
  local instrument_labels = {}
  for i, instrument in ipairs(song.instruments) do
    local name = instrument.name
    if name == "" then name = "(unnamed)" end
    instrument_labels[i] = string.format("%02X: %s", i-1, name)
  end
  if #instrument_labels == 0 then
    renoise.app():show_warning("Song has no instruments.")
    return
  end
  local instrument_choice = math.min(song.selected_instrument_index, #instrument_labels)
  local mute_source = true
  local rate_choice, mode_choice, octave_choice, gate_choice = 3,1,1,4
  local status = vb:text {
    width=455,
    text="Sub-line short gates use exact OFFs when representable."
  }
  local content = vb:column {
    margin=12, spacing=8,
    vb:text { text="ARP - guarded release timing" },
    vb:row {
      vb:text {text="Source"},
      vb:popup {width=290,items=labels,value=source_choice,
        notifier=function(v) source_choice=v end}
    },
    vb:row {
      vb:text {text="Destination"},
      vb:popup {width=290,items=labels,value=dest_choice,
        notifier=function(v) dest_choice=v end}
    },
    vb:row {
      vb:text {text="Destination instrument"},
      vb:popup {width=285,items=instrument_labels,value=instrument_choice,
        notifier=function(v) instrument_choice=v end}
    },
    vb:row {
      vb:text {text="Disable source note playback (OFF)"},
      vb:checkbox {value=true,notifier=function(v) mute_source=v end}
    },
    vb:row {
      vb:text {text="Rate"},
      vb:popup {width=90,items=divisions,value=rate_choice,
        notifier=function(v) rate_choice=v end},
      vb:text {text="Order"},
      vb:popup {width=105,items={"Up","Down","Up-Down"},value=mode_choice,
        notifier=function(v) mode_choice=v end},
      vb:text {text="Octaves"},
      vb:popup {width=65,items={"1","2","3","4"},value=octave_choice,
        notifier=function(v) octave_choice=v end}
    },
    vb:row {
      vb:text {text="Gate"},
      vb:popup {width=110,items={"25%","50%","75%","100%"},value=gate_choice,
        notifier=function(v) gate_choice=v end},
      vb:text {text="Unsupported short gates are refused safely."}
    },
    vb:button {
      text="Generate / Regenerate (verified destination only)",
      notifier=function()
        if opened_generation ~= document_generation then
          status.text="Song changed. Close and reopen ARP."
          return
        end
        local ok, result, err = pcall(
          writer.generate,
          indices[source_choice], indices[dest_choice],
          divisions[rate_choice], modes[mode_choice],
          octave_choice, gate_values[gate_choice],
          instrument_choice, mute_source
        )
        if not ok then
          status.text="ARP error: " .. tostring(result)
          print("[ARP] " .. tostring(result))
        elseif not result then
          status.text=err or "Generation was refused."
        else
          local column_word = result.columns == 1 and "column" or "columns"
          status.text=string.format("%s %d notes, %d note-offs in %d %s.",
            result.action,result.notes,result.offs,result.columns,column_word)
        end
      end
    },
    status,
    vb:text {text="Short gates preserve note release; no automatic tick-cuts."}
  }
  dialog=renoise.app():show_custom_dialog("ARP",content)
  dialog_generation = opened_generation
end
return M
