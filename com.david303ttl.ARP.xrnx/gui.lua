-- ARP v0.4 Renoise GUI. Never compare Renoise Song objects with == or ~=:
-- they do not implement Lua's __eq operator.
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
  local rate_choice, mode_choice, octave_choice, gate_choice = 3,1,1,4
  local status = vb:text {
    width=455,
    text="Sub-line rates work at 100% gate; add note columns if prompted."
  }
  local content = vb:column {
    margin=12, spacing=8,
    vb:text { text="ARP.xrnx v0.5 - sub-line timing" },
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
      vb:text {text="Sub-line rates currently require Gate 100%."}
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
          octave_choice, gate_values[gate_choice]
        )
        if not ok then
          status.text="ARP error: " .. tostring(result)
          print("[ARP v0.4] " .. tostring(result))
        elseif not result then
          status.text=err or "Generation was refused."
        else
          status.text=string.format("%s %d notes, %d note-offs in %d columns.",
            result.action,result.notes,result.offs,result.columns)
        end
      end
    },
    status,
    vb:text {text="Sub-line timing uses multiple note columns and delay values."}
  }
  dialog=renoise.app():show_custom_dialog("ARP",content)
  dialog_generation = opened_generation
end
return M
