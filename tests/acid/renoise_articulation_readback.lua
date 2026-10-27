-- Inspect disposable profile settings from the standalone scripting terminal.
local song = assert(renoise.song(), "Open the disposable ACID song copy first")
local name = rawget(_G, "ACID_ARTICULATION_PROBE_NAME") or "ACID ARTICULATION PROBE"
assert(name == "ACID ARTICULATION PROBE" or name == "ACID ARTICULATION MONO PROBE",
  "Unsupported articulation probe name")
local probe
for _, instrument in ipairs(song.instruments) do
  if instrument.name == name then
    assert(not probe, "Multiple matching articulation probes exist")
    probe = instrument
  end
end
assert(probe and #probe.samples == 1, "Create the requested articulation probe first")
local sample = probe.samples[1]
local set = probe.sample_modulation_sets[sample.modulation_set_index]
assert(set, "Diagnostic modulation set is not attached")
print("Profile=" .. name .. ", monophonic=" .. tostring(probe.trigger_options.monophonic)
  .. ", native_glide=" .. tostring(probe.trigger_options.monophonic_glide)
  .. ", sample_gain=" .. tostring(sample.volume) .. ", autofade=" .. tostring(sample.autofade)
  .. ", loop_release=" .. tostring(sample.loop_release))
for index, device in ipairs(set.devices) do
  print("Modulation device " .. tostring(index) .. ": " .. tostring(device.name)
    .. ", fade_amount=" .. tostring(device.fade_amount)
    .. ", tempo_synced=" .. tostring(device.tempo_synced)
    .. ", sustain=" .. tostring(device.sustain_position))
  if device.points then
    for _, point in ipairs(device.points) do
      print("point=" .. tostring(point.time) .. "," .. tostring(point.value)
        .. "," .. tostring(point.scaling))
    end
  end
end
print("fade_amount units and release contribution are not specified by API 6.2; retain measured audio separately.")
