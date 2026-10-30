-- API-shaped host values shared by GUI integration fixtures.
dofile("tests/acid/draft_baseline_stub.lua")
local ownership=require("renoise.phrase_ownership")
local real=assert(loadfile("com.david303ttl.ACID.xrnx/renoise/phrase_ownership.lua"))()
ownership.is_current=real.is_current
function ownership.validate_identity(song,instrument,phrase)
  local member,reason=ownership.membership(song,instrument,phrase)
  if not member then return nil,reason end
  if not phrase or ownership.status(phrase)~="owned" then return nil,"Unverified target" end
  local id=ownership.id(phrase)
  local count=0
  for _,candidate in ipairs(song.instruments) do
    for _,holder in ipairs(candidate.phrases) do
      if ownership.id(holder)==id then count=count+1 end
    end
  end
  if count~=1 then return nil,"Ambiguous phrase identity" end
  return id
end
renoise.Transport={TIMING_MODEL_LPB=1}
local song=renoise.song()
song.transport={timing_model=1,groove_enabled=false}
function song:is_undo_redoing() return false end
for _,instrument in ipairs(song.instruments) do
  instrument.plugin_properties={plugin_loaded=false,alias_instrument_index=0,
    alias_fx_track_index=0,alias_fx_device_index=0,midi_output_routing_index=0}
  instrument.midi_output_properties={device_name="",instrument_type=0,channel=1}
  instrument.phrase_playback_mode=1
end
local writer=require("writers.phrase_writer")
if type(writer.state)~="function" then
  writer.state=function() return "idle",nil end
end
if type(writer.is_temporary)~="function" then
  writer.is_temporary=function() return false end
end

ownership.snapshot=function(phrase) return {content=phrase.baseline_revision or 0} end
function ownership.inventory(song)
  local groups={}
  for instrument_index,instrument in ipairs(song.instruments) do
    for phrase_index,phrase in ipairs(instrument.phrases) do
      local id=ownership.id(phrase)
      if id then
        groups[id]=groups[id] or {}
        groups[id][#groups[id]+1]={instrument=instrument,phrase=phrase,
          instrument_index=instrument_index,phrase_index=phrase_index}
      end
    end
  end
  return groups
end
