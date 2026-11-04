-- SPDX-License-Identifier: GPL-3.0-only
-- Read-only compatibility checks for retained phrase operations.
local validator=require("writers.phrase_validator")
local pitch_bend=require("writers.phrase_pitch_bend")
local M={}

local MINIMUM_PHRASE_CAPACITY=1
local MINIMUM_EFFECT_COLUMNS=0

local function phrase_limits()
  local ok,api=pcall(function()
    local host=rawget(_G,"renoise")
    return host and host.InstrumentPhrase
  end)
  if not ok or api==nil then return nil,"Phrase API is unavailable" end
  local function read(key)
    local readable,value=pcall(function() return api[key] end)
    if not readable or value==nil then return nil,false end
    return value,true
  end
  local max_lines,lines_ok=read("MAX_NUMBER_OF_LINES")
  local max_notes,notes_ok=read("MAX_NUMBER_OF_NOTE_COLUMNS")
  local max_effects,effects_ok=read("MAX_NUMBER_OF_EFFECT_COLUMNS")
  local play_pattern,play_ok=read("PLAY_PATTERN")
  local key_tracking_none,key_ok=read("KEY_TRACKING_NONE")
  if not lines_ok or not notes_ok or not effects_ok or not play_ok or not key_ok then
    return nil,"Cannot inspect phrase API limits"
  end
  if type(max_lines)~="number" or max_lines%1~=0 or max_lines<MINIMUM_PHRASE_CAPACITY or
      type(max_notes)~="number" or max_notes%1~=0 or max_notes<MINIMUM_PHRASE_CAPACITY or
      type(max_effects)~="number" or max_effects%1~=0 or max_effects<MINIMUM_EFFECT_COLUMNS then
    return nil,"Phrase API limits are invalid"
  end
  return {max_lines=max_lines,max_note_columns=max_notes,max_effect_columns=max_effects,
    play_pattern=play_pattern,key_tracking_none=key_tracking_none}
end

function M.compatibility(phrase,source,policy,pb_range,profile)
  local limits,limits_error=phrase_limits()
  if not limits then return nil,limits_error end
  local proof,proof_error=validator.compatibility(phrase,
    {pattern=source,output_policy=policy,pb_range=pb_range},profile,limits,
    {pitch_bend_delivery=pitch_bend.delivery_enabled})
  if not proof then return nil,proof_error end
  return proof
end


return M
