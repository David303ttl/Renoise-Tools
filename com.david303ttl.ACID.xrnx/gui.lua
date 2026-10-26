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
  local state = phrase_writer.fixture()
  local cursor = 1
  local selected_pitch = 1
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
  local mode_names={"Baseline","Retrigger + Gate","Selective Slide + Gate"}
  local mode_values={"baseline","retrigger","slide"}
  local mode_choice=1
  local lengths = {8, 12, 16}
  local pitch_values = {36,37,38,39,40,41,42,43,44,45,46,47,48}
  local pitch_choices = {"C-3","C#3","D-3","D#3","E-3","F-3","F#3","G-3","G#3","A-3","A#3","B-3","C-4"}
  local pitch_entry = vb:valuebox {min=1,max=16,value=1,width=65}
  local pitch_note = vb:popup {items=pitch_choices,width=95,value=1}
  local accent = vb:checkbox {value=false}
  local slide = vb:checkbox {value=false}
  local time_step = vb:valuebox {min=1,max=16,value=1,width=65}
  local time_kind = vb:popup {items={"NOTE","TIE","REST"},width=90,value=1}
  local updating=false
  local function refresh()
    updating=true
    local p = state.pitch_events[selected_pitch] or {note=36,accent=false,slide=false}
    local idx=1
    for i,n in ipairs(pitch_values) do if n==p.note then idx=i end end
    pitch_note.value=idx
    accent.value=p.accent==true
    slide.value=p.slide==true
    local t=state.time_events[cursor] or "R"
    time_kind.value=t=="N" and 1 or t=="T" and 2 or 3
    summary.text=assert(sequencer.describe(state))
    updating=false
  end
  local function edit_pitch()
    if updating then return end
    local p=state.pitch_events[selected_pitch] or {note=36}
    p.note=pitch_values[pitch_note.value]
    p.accent=accent.value
    p.slide=slide.value
    for i=#state.pitch_events+1,selected_pitch do
      state.pitch_events[i]={note=36,accent=false,slide=false}
    end
    state.pitch_events[selected_pitch]=p
    refresh()
  end
  pitch_entry:add_notifier(function(v)if not updating then selected_pitch=v;refresh() end end)
  pitch_note:add_notifier(edit_pitch)
  accent:add_notifier(edit_pitch)
  slide:add_notifier(edit_pitch)
  time_step:add_notifier(function(v)if not updating then cursor=v;refresh()end end)
  time_kind:add_notifier(function(v)
    if updating then return end
    state.time_events[cursor]=({"N","T","R"})[v]
    refresh()
  end)
  refresh()
  local content = vb:column {
    margin = 12, spacing = 8,
    vb:text {text = "ACID.xrnx 0.1 - first phrase playback test"},
    vb:text {text = "Fixed 8-step fixture; selective native glide is experimental."},
    vb:row {
      vb:text {text="Target sample instrument"},
      vb:popup {
        width=270, items=labels, value=selected,
        notifier=function(index) selected=index end
      }
    },
    vb:row {
      vb:text {text="Audio experiment"},
      vb:popup {width=220,items=mode_names,value=1,
        notifier=function(index)mode_choice=index end}
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
          end, mode_values[mode_choice], state
        )
        if not ok then status.text = "ACID error: " .. tostring(generated)
        elseif not generated then status.text = err or "Generation refused" end
      end
    },
    vb:text {text = "PITCH memory (entry / note / accent / slide)"},
    vb:row {pitch_entry,pitch_note,accent,slide},
    vb:text {text = "TIME memory (step / instruction)"},
    vb:row {time_step,time_kind},
    vb:text {text = "Pattern inspection:"},
    vb:row {
      vb:text {text = "Timing steps"},
      vb:popup {
        width = 100,
        items = {"8", "12", "16"},
        value = 1,
        notifier = function(index)
          local n=lengths[index]
          state.length=n
          for i=1,n do
            if not state.time_events[i] then state.time_events[i]="R" end
          end
          for i=n+1,16 do state.time_events[i]=nil end
          time_step.max=n
          if cursor>n then cursor=n;time_step.value=n end
          refresh()
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
