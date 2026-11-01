# ACID — host lifecycle smoke

**M4 requirement:** one short in-Renoise playback smoke; no mandatory loopback recording.

Use a disposable song and a generated ACID Repeat phrase.

1. Start playback, stop, restart and seek to another line. Confirm the phrase responds without unintended stuck notes or duplicate triggering.
2. Change song BPM and LPB while playing. Confirm Straight and Triplet phrase durations remain musically correct without regenerating.
3. Change the selected instrument and owned phrase while ACID is open. Regenerate in place and confirm Live Edit never redirects to another destination.
4. Save/reopen, check per-phrase source and selection.

Record pass/fail, Renoise version and concise observed failure if any. `renoise_host_lifecycle_probe.lua` and `renoise_host_transport_record.lua` remain **optional diagnostics** if a specific stop/start/seek failure needs isolation. New WASAPI loopback captures and soundcard calibration are not M4 gates.

See [M4.7](../../com.david303ttl.ACID.xrnx/ROADMAP.md#m47--instrumentphrase-synchronization-and-regeneration-safety-p0).
