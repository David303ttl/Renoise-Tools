-- Configure only the disposable probe for native accent level comparisons.
local song=assert(renoise.song(),"Open the disposable ACID song first")
local probe
for _,instrument in ipairs(song.instruments) do
  if instrument.name=="ACID ARTICULATION PROBE" then
    assert(not probe,"Multiple articulation probes exist")
    probe=instrument
  end
end
assert(probe and #probe.samples==1,"Create the disposable articulation probe first")
local sample=probe.samples[1]
assert(sample.sample_buffer.has_sample_data and sample.sample_buffer.number_of_frames==168,
  "Reference probe sample is missing")
sample.modulation_set_index=0
sample.sample_mapping.map_velocity_to_volume=true
assert(sample.modulation_set_index==0 and sample.sample_mapping.map_velocity_to_volume,
  "Could not configure the flat accent control")
print("Flat accent control: no modulation; velocity-to-volume mapping enabled.")
