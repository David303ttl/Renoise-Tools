# Moving Repeat glide checks

Run `renoise_moving_repeat_glide_probe.lua` and
`renoise_moving_repeat_glide_controls.lua` in a disposable song with the
`ACID ARTICULATION PROBE` instrument. The native phrases use Straight LPB 16,
four lines per step, and an eight-step loop of 32 phrase lines.

The moving cases connect pitches 48→52→48 and 48→60→48 with fixed `0G20` and
continuation commands. Compare them with held NOTE controls at pitches 48, 52,
and 60. Check intermediate pitch motion, attacks, releases, and the Repeat seam.

The ACID writer variant uses the current source model and phrase writer. In
ACID's scripting context set `ACID_ARTICULATION_ORACLE_PATH`,
`ACID_ARTICULATION_CASE_ID`, and `ACID_ARTICULATION_OUTPUT_POLICY="repeat"`,
then run `renoise_articulation_writer.lua`. Inspect its generated phrase before
capturing.

Use three unchanged captures for each case. Record Renoise version, BPM, phrase
LPB, sample profile, phrase cells, render metadata, and WAV hashes. Current-layout
Renoise playback checks have not been performed in this work session. Synthetic
analyzer checks do not establish playback behavior.
