-- File: StateManager.lua
-- Manages mute state per channel and sends corresponding MIDI CCs.
local Config = require("Config")
local MidiIO = require("MidiIO")
local StateManager = { state = {} }

-- Initializes state for all 16 MIDI channels
function StateManager.init()
    for ch=1,16 do
        StateManager.state[ch] = { last_level=100, is_muted=false }
    end
end

-- Toggles the mute state for a given channel
function StateManager.toggle(ch)
    local st  = StateManager.state[ch]
    local cfg = Config.per_channel[ch] or Config.default

    if cfg.mute.type == "cc" then -- Ensure configuration is for CC
        if not st.is_muted then
            -- If currently unmuted, mute the track
            MidiIO.send_cc(ch-1, cfg.mute.cc_number, cfg.mute.off_value) -- Send mute CC (e.g., CC 94, Value 0)
            MidiIO.send_cc(ch-1, cfg.level.cc_number, 0) -- Send level CC to 0 (e.g., CC 7, Value 0)
        else
            -- If currently muted, unmute the track
            MidiIO.send_cc(ch-1, cfg.mute.cc_number, cfg.mute.on_value) -- Send unmute CC (e.g., CC 94, Value 1)
            MidiIO.send_cc(ch-1, cfg.level.cc_number, st.last_level) -- Restore last saved level (e.g., CC 7, Value 100)
        end
        st.is_muted = not st.is_muted -- Toggle internal mute state
    end
end

-- Updates the last known level for a channel (used to restore level after unmute)
function StateManager.update_level(ch, val)
    StateManager.state[ch].last_level = val
end

-- Sends the current level for a channel (e.g., to update Renoise track volume)
function StateManager.send_level(ch, val)
    local cfg = Config.per_channel[ch] or Config.default
    if cfg.level.type == "cc" then
        MidiIO.send_cc(ch-1, cfg.level.cc_number, val)
    end
end

return StateManager
