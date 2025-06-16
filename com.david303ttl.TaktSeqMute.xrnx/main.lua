-- File: main.lua
-- Entry point: sets up preferences, modules, MIDI handler, and menu.
local renoise, TOOL = renoise, renoise.tool()

-- Preferences document for MIDI device selection
local prefs = renoise.Document.create("TaktSeqMutePreferences") {
    midi_input_device  = "",
    midi_output_device = ""
}
TOOL.preferences = prefs

local Config
local MidiIO
local StateManager
local UI

local function load_modules()
    local success, err

    local function log_status(msg)
        if renoise and type(renoise) == "table" and renoise.app and type(renoise.app) == "table" and type(renoise.app.show_status) == "function" then
            renoise.app:show_status(msg, 3000)
        else
            print("TaktSeqMute: Could not display status - renoise.app not fully initialized. Message: " .. msg)
        end
    end

    success, Config = pcall(require, "Config")
    if not success or type(Config) ~= "table" then
        print("TaktSeqMute ERROR: Config module did not load as a table. Error: " .. tostring(err))
        log_status("TaktSeqMute: Critical Error - Config module not loaded correctly.")
        return false
    end

    success, MidiIO = pcall(require, "MidiIO")
    if not success or type(MidiIO) ~= "table" then
        print("TaktSeqMute ERROR: MidiIO module did not load as a table. Type is: " .. type(MidiIO) .. ". Error: " .. tostring(err))
        log_status("TaktSeqMute: Critical Error - MidiIO module not loaded correctly.")
        return false
    end

    success, StateManager = pcall(require, "StateManager")
    if not success or type(StateManager) ~= "table" then
        print("TaktSeqMute ERROR: StateManager module did not load as a table. Error: " .. tostring(err))
        log_status("TaktSeqMute: Critical Error - StateManager module not loaded correctly.")
        return false
    end

    success, UI = pcall(require, "UI")
    if not success or type(UI) ~= "table" then
        print("TaktSeqMute ERROR: UI module did not load as a table. Error: " .. tostring(err))
        log_status("TaktSeqMute: Critical Error - UI module not loaded correctly.")
        return false
    end
    return true
end

-- Load modules immediately
if not load_modules() then
    print("TaktSeqMute: Failed to load all essential modules. Tool may not function correctly.")
end

-- MIDI callback function
local function on_midi(msg)
    if type(MidiIO) ~= "table" then
        print("TaktSeqMute: on_midi received, but MidiIO is not a table. Cannot process MIDI message.")
        return false
    end
    if type(Config) ~= "table" then
        print("TaktSeqMute: on_midi received, but Config is not a table. Cannot process MIDI message.")
        return false
    end

    if msg.type ~= "controller" then return false end
    local ch  = msg.channel + 1
    local cfg = Config.per_channel[ch] or Config.default

    -- Mute handling
    if cfg.mute.type == "cc" then
        if msg.controller_number == cfg.mute.cc_number then
            -- Toggle mute state regardless of CC value (assuming button acts as a toggle)
--            print("CC " .. cfg.mute.cc_number .. " received for channel: " .. ch .. " with value: " .. msg.value) -- Debugging output
            StateManager.toggle(ch)
            return true
        end
    end

    -- Level handling
    if cfg.level.type == "cc" then
        if msg.controller_number == cfg.level.cc_number then
            StateManager.update_level(ch, msg.value)
            StateManager.send_level(ch, msg.value) -- Send level to Renoise
            return true
        end
    end

    return false
end

-- Initializes MIDI devices based on preferences
local function init_midi()
    if type(MidiIO) ~= "table" then
        if renoise and type(renoise) == "table" and renoise.app and type(renoise.app) == "table" and type(renoise.app.show_status) == "function" then
            renoise.app:show_status("TaktSeqMute: Critical Error - MidiIO module not loaded correctly. Cannot initialize MIDI.", 3000)
        end
        print("TaktSeqMute: Critical Error - MidiIO module not loaded correctly. Cannot initialize MIDI.")
        return
    end

    MidiIO.shutdown()
    local in_dev_name_pref = prefs.midi_input_device.value
    local out_dev_name_pref = prefs.midi_output_device.value

    local available_inputs = {}
    local success, res = pcall(function() return renoise.Midi.available_input_devices() end) 
    if success and res then
        for _,d in ipairs(res) do table.insert(available_inputs, d) end
    else
        print("TaktSeqMute ERROR: Could not retrieve available MIDI input devices: " .. tostring(res))
        if renoise and type(renoise) == "table" and renoise.app and type(renoise.app) == "table" and type(renoise.app.show_status) == "function" then
            renoise.app:show_status("TaktSeqMute: Error retrieving MIDI input devices.", 3000)
        end
    end

    local available_outputs = {}
    success, res = pcall(function() return renoise.Midi.available_output_devices() end)
    if success and res then
        for _,d in ipairs(res) do table.insert(available_outputs, d) end
    else
        print("TaktSeqMute ERROR: Could not retrieve available MIDI output devices: " .. tostring(res))
        if renoise and type(renoise) == "table" and renoise.app and type(renoise.app) == "table" and type(renoise.app.show_status) == "function" then
            renoise.app:show_status("TaktSeqMute: Error retrieving MIDI output devices.", 3000)
        end
    end

    local final_in_dev = ""
    if in_dev_name_pref ~= "" and table.find(available_inputs, in_dev_name_pref) then
        final_in_dev = in_dev_name_pref
    else
        if in_dev_name_pref ~= "" then
            if renoise and type(renoise) == "table" and renoise.app and type(renoise.app) == "table" and type(renoise.app.show_status) == "function" then
                renoise.app:show_status("TaktSeqMute: MIDI Input Device '" .. in_dev_name_pref .. "' not found. Setting to 'None'.", 1500)
            end
            print("TaktSeqMute: MIDI Input Device '" .. in_dev_name_pref .. "' not found. Setting input preference to 'None'.")
        end
        prefs.midi_input_device.value = "" -- Set to empty string, corresponds to "None"
        final_in_dev = ""
    end

    local final_out_dev = ""
    if out_dev_name_pref ~= "" and table.find(available_outputs, out_dev_name_pref) then
        final_out_dev = out_dev_name_pref
    else
        if out_dev_name_pref ~= "" then
            if renoise and type(renoise) == "table" and renoise.app and type(renoise.app) == "table" and type(renoise.app.show_status) == "function" then
                renoise.app:show_status("TaktSeqMute: MIDI Output Device '" .. out_dev_name_pref .. "' not found. Setting to 'None'.", 1500)
            end
            print("TaktSeqMute: MIDI Output Device '" .. out_dev_name_pref .. "' not found. Setting output preference to 'None'.")
        end
        prefs.midi_output_device.value = "" -- Set to empty string
        final_out_dev = ""
    end

    if final_in_dev ~= "" or final_out_dev ~= "" then
        MidiIO.init(final_in_dev, final_out_dev, on_midi)
    else
        print("TaktSeqMute: No valid MIDI input or output devices selected/found.")
    end
end

-- Setup: Initialize StateManager and MIDI when a new document is opened
TOOL.app_new_document_observable:add_notifier (function()
    if type(StateManager) == "table" and type(StateManager.init) == "function" then
        StateManager.init()
    end
    init_midi()
end)

-- Add menu entries to Renoise
TOOL:add_menu_entry{
    name   = "Instrument Box:TaktSeqMute Exit",
    invoke = function()
        if MidiIO and type(MidiIO) == "table" and MidiIO.shutdown then
            MidiIO.shutdown()
        else
            print("TaktSeqMute: Error - MidiIO module not properly loaded or shutdown function missing.")
        end
    end
}

TOOL:add_menu_entry{
    name   = "Instrument Box:TaktSeqMute Settings...",
    invoke = function() UI.build(prefs, init_midi) end
}

TOOL:add_menu_entry{
    name   = "Instrument Box:TaktSeqMute ↻ Reinit MIDI",
    invoke = init_midi
}