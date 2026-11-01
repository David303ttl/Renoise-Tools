-- SPDX-License-Identifier: GPL-3.0-only
-- Read-only description of the current Renoise instrument output layers.
local M = {}
-- Keep comparison values private so mutable diagnostics cannot change a baseline.
local comparisons = setmetatable({}, {__mode="k"})
local COMPARISON_FIELDS = 13

local function has_sample(instrument)
  if instrument.samples==nil then error("sample inventory is unavailable") end
  for _, sample in ipairs(instrument.samples) do
    local buffer = sample.sample_buffer
    if not buffer or type(buffer.has_sample_data)~="boolean" then
      error("sample buffer state is unavailable")
    end
    if buffer.has_sample_data then return true end
  end
  return false
end

local function inspect(instrument)
  local plugin_properties = instrument.plugin_properties
  local midi_properties = instrument.midi_output_properties
  if not plugin_properties or not midi_properties or
      type(plugin_properties.plugin_loaded)~="boolean" or
      type(midi_properties.device_name)~="string" then
    error("receiver properties are unavailable")
  end
  for _,field in ipairs({"alias_instrument_index","alias_fx_track_index","alias_fx_device_index",
      "midi_output_routing_index"}) do
    local value=plugin_properties[field]
    if type(value)~="number" or value%1~=0 or value<0 then
      error("receiver property is unavailable: "..field)
    end
  end
  local plugin_loaded = plugin_properties and plugin_properties.plugin_loaded == true or false
  local alias_instrument = plugin_properties and plugin_properties.alias_instrument_index or 0
  local alias_fx_track = plugin_properties and plugin_properties.alias_fx_track_index or 0
  local alias_fx_device = plugin_properties and plugin_properties.alias_fx_device_index or 0
  local midi_device = midi_properties and midi_properties.device_name or ""
  local midi_routing = plugin_properties and plugin_properties.midi_output_routing_index or 0
  local sample = has_sample(instrument)
  local midi = midi_device ~= "" or midi_routing > 0
  local midi_available
  if midi_device ~= "" and _G.renoise and _G.renoise.Midi
      and type(_G.renoise.Midi.available_output_devices) == "function" then
    local ok, devices = pcall(_G.renoise.Midi.available_output_devices)
    if ok and type(devices) == "table" then
      midi_available = false
      for _, device in ipairs(devices) do
        if device == midi_device then midi_available = true; break end
      end
    end
  end
  local alias = alias_instrument > 0 or alias_fx_track > 0 or alias_fx_device > 0
  local kind
  local layers = (sample and 1 or 0) + (plugin_loaded and 1 or 0) + (midi and 1 or 0)
  if layers > 1 then kind = "hybrid"
  elseif sample then kind = "sample"
  elseif plugin_loaded then kind = alias and "plugin_alias" or "plugin"
  elseif midi then kind = "midi"
  elseif alias then kind = "alias_unavailable"
  else kind = "empty" end
  local result = {
    sample = sample,
    plugin = plugin_loaded,
    midi = midi,
    alias = alias,
    midi_device = midi_device,
    midi_routing = midi_routing,
    midi_available = midi_available,
    kind = kind,
    phrase_playback_mode = instrument.phrase_playback_mode,
    phrase_program = instrument.phrase_program,
  }
  comparisons[result] = {
    result.sample, result.plugin, result.midi,
    alias_instrument, alias_fx_track, alias_fx_device,
    midi_device, midi_routing, midi_available,
    midi_properties.instrument_type, midi_properties.channel,
    result.phrase_playback_mode, result.phrase_program,
  }
  result.diagnostics={}
  local function warn(message) result.diagnostics[#result.diagnostics+1]=message end
  if kind == "empty" then
    warn("No active sound source; phrase will be silent.")
  elseif kind == "alias_unavailable" then
    warn("Instrument alias is configured but no active plugin output is available.")
  end
  if midi_device ~= "" then
    warn(midi_available == false
      and "Configured MIDI output is unavailable; phrase generation remains available."
      or "External MIDI playback depends on the configured output device.")
  elseif midi_routing > 0 then
    warn("Plugin MIDI playback depends on the configured Renoise instrument route.")
  end
  local phrase_off=(_G.renoise and _G.renoise.Instrument
    and _G.renoise.Instrument.PHRASES_OFF) or 1
  if result.phrase_playback_mode==phrase_off then
    warn("Instrument phrase playback mode is OFF; verify the selected phrase trigger behavior in Renoise.")
  end
  if result.phrase_program==0 then
    warn("Phrase program is off; playback depends on an explicit phrase trigger.")
  end
  if #result.diagnostics>0 then result.diagnostic=table.concat(result.diagnostics," ") end
  return result
end

function M.inspect(instrument)
  local instrument_type=type(instrument)
  if instrument_type ~= "Instrument" and instrument_type ~= "table"
      and instrument_type ~= "userdata" then
    return nil, "invalid instrument target"
  end
  local ok,result=pcall(inspect,instrument)
  if ok then return result end
  local reason="Could not inspect receiver: "..tostring(result)
  local unknown={kind="unknown",read_error=reason,
    diagnostics={reason},diagnostic=reason}
  comparisons[unknown]={read_error=reason}
  return unknown
end

function M.same(left, right)
  local a,b=comparisons[left],comparisons[right]
  if not a or not b then return false end
  if a.read_error or b.read_error then return false end
  for index=1,COMPARISON_FIELDS do
    if a[index]~=b[index] then return false end
  end
  return true
end

return M
