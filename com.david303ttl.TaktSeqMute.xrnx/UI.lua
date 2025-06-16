-- File: UI.lua
-- Builds a custom dialog for selecting MIDI ports.
local renoise = renoise
local UI      = {}

local vb
local success_vb, result_vb = pcall(function() return renoise.ViewBuilder() end)
if not success_vb then
    print("TaktSeqMute ERROR: Failed to initialize renoise.ViewBuilder(). Error: " .. tostring(result_vb))
    return UI 
end
vb = result_vb


-- Builds and displays the MIDI settings dialog
function UI.build(prefs, reinit)
    print("UI.build: Start")
    print("UI.build: type(renoise) = " .. type(renoise))
    if renoise then
        print("UI.build: type(renoise.app) = " .. type(renoise.app))
    else
        print("UI.build: renoise is nil")
    end
    print("UI.build: type(renoise.Midi) = " .. type(renoise.Midi))

    local inputs  = {"None"}
    local success_inputs, available_inputs = pcall(renoise.Midi.available_input_devices)
    if success_inputs and available_inputs then
        for _,d in ipairs(available_inputs) do table.insert(inputs, d) end
    else
        print("TaktSeqMute ERROR: Could not retrieve available MIDI input devices. " .. (available_inputs or "Unknown error."))
    end

    local outputs = {"None"}
    local success_outputs, available_outputs = pcall(renoise.Midi.available_output_devices)
    if success_outputs and available_outputs then
        for _,d in ipairs(available_outputs) do table.insert(outputs, d) end
    else
        print("TaktSeqMute ERROR: Could not retrieve available MIDI output devices. " .. (available_outputs or "Unknown error."))
    end

    -- Find current device indices or default to "None"
    local in_idx  = table.find(inputs,  prefs.midi_input_device.value) or 1
    local out_idx = table.find(outputs, prefs.midi_output_device.value) or 1

    local content = vb:column{
        margin  = renoise.Views.DEFAULT_DIALOG_MARGIN,
        spacing = renoise.Views.DEFAULT_CONTROL_SPACING,
        vb:row{ vb:text{ text="MIDI In:" },  vb:popup{ items=inputs,  value=in_idx,  notifier=function(i) prefs.midi_input_device.value = inputs[i]  end } },
        vb:row{ vb:text{ text="MIDI Out:" }, vb:popup{ items=outputs, value=out_idx, notifier=function(i) prefs.midi_output_device.value = outputs[i] end } },
        vb:row{ vb:button{ text="Restart Listener", notifier=reinit } }
    }

    if UI.dialog and UI.dialog.visible then
        pcall(function() UI.dialog:close() end)
    end

    local success_show_dialog, result_show_dialog = pcall(function()
        UI.dialog = renoise.app():show_custom_dialog("TaktSeqMute Settings", content)
    end)
    if not success_show_dialog then
        print("TaktSeqMute ERROR: Failed to show custom dialog. Error: " .. tostring(result_show_dialog))
        if type(renoise.app) == "function" and type(renoise.app().show_status) == "function" then
            renoise.app():show_status("TaktSeqMute: Błąd podczas wyświetlania dialogu ustawień.", 3000)
        end
    end
end

return UI