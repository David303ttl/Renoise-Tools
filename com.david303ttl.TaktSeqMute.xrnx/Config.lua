-- File: Config.lua
-- Defines MIDI CC mappings for mute and amp volume..
local Config = {
    default = {
        mute = {
            type      = "cc",       -- Control type: "cc" for Control Change
            cc_number = 94,         -- MIDI CC number for mute
            on_value  = 0,          -- Value for 'mute ON' state 
            off_value = 1           -- Value for 'mute OFF' state 
        },
        level = {
            type      = "cc",       -- Control type: "cc" for Control Change
            cc_number = 7           -- MIDI CC number for track level (CC7 Amp volume, CC95 Track level for: DT, DN, ST, A4. M:C & M:S CC7 - Track volume + Dist, CC95 - Track level)
        }
    },
    per_channel = {
        -- Channel-specific overrides can be added here, e.g.:
        -- [1] = { level = { type="cc", cc_number=7 } }
    }
}
return Config