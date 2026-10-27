-- Bypass only the diagnostic volume envelope for pitch and level controls.
local song = renoise.song()
assert(song, "Open the disposable ACID song copy first")

local probe
for _, instrument in ipairs(song.instruments) do
  if instrument.name == "ACID ARTICULATION PROBE" then
    assert(not probe, "Multiple articulation probes exist; inspect the disposable song")
    probe = instrument
  end
end
assert(probe and #probe.samples == 1, "Create the articulation probe instrument first")
assert(#probe.sample_modulation_sets >= 1
  and probe.sample_modulation_sets[1].name == "ACID diagnostic volume envelope",
  "Probe diagnostic envelope is missing")

probe.samples[1].sample_mapping.map_velocity_to_volume = false
probe.samples[1].modulation_set_index = 0
assert(probe.samples[1].modulation_set_index == 0, "Could not bypass the diagnostic envelope")
print("Flat control enabled: the probe sample has no modulation set attached.")
