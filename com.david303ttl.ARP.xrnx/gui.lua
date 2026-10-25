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
    text="Gate 100% keeps v0.3 note-on-only behavior; shorter gates add OFFs."
  }
  local content = vb:column {
    margin=12, spacing=8,
    vb:text { text="ARP.xrnx v0.4 - gate + safe regeneration" },
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
      vb:text {text="Short gates need a separate OFF line."}
    },
    vb:button {
      text="Generate / Regenerate (verified destination only)",
      notifier=function()
        if renoise.song() ~= song then
          status.text="Song changed. Close and reopen ARP."
          return
        end
        local result, err = writer.generate(
          indices[source_choice],indices[dest_choice],
          divisions[rate_choice],modes[mode_choice],
          octave_choice,gate_values[gate_choice])
        status.text = err or string.format(
          "%s %d notes, %d note-offs.",
          result.action,result.notes,result.offs)
      end
    },
    status,
    vb:text {text="Ownership is saved with XRNS; edits prevent regeneration."}
  }
  dialog=renoise.app():show_custom_dialog("ARP",content)
end
return M
