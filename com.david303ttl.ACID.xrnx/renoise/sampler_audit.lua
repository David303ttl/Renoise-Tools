-- Inspect sampler configuration without changing instruments or effect chains.
local M={}
function M.describe(instrument)
  if not instrument then return nil,"No instrument selected" end
  local count=#instrument.samples
  local playable=0
  for _,s in ipairs(instrument.samples) do
    if s.sample_buffer and s.sample_buffer.has_sample_data then
      playable=playable+1
    end
  end
  local modsets=instrument.sample_modulation_sets
  local fxchains=instrument.sample_device_chains
  return string.format(
    "Sampler: %d samples (%d loaded), %d modulation sets, %d FX chains. No instrument changes.",
    count,playable,modsets and #modsets or 0,
    fxchains and #fxchains or 0)
end
return M
