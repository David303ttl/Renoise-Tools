-- Restore the diagnostic volume envelope after flat pitch and level controls.
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

probe.samples[1].modulation_set_index = 1
assert(probe.samples[1].modulation_set_index == 1, "Could not restore the diagnostic envelope")
print("Probe envelope restored: the diagnostic volume modulation set is attached.")
