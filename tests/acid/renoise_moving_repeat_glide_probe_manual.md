# Native bidirectional Repeat glide probe

This development probe uses the diagnostic ACID sample and writes two disposable Selective phrases. It does not change ACID runtime behavior. Run it in a fresh disposable song after the diagnostic profile has passed the current grid calibration.

## Current verified scope

At the checked diagnostic profile (selective, LPB8/TPL12, no groove), native
and writer renders pass for four-semitone and octave movement at90/120/150BPM
in both the 8-step and 9-step layouts. The 8-step source is `N T T T N T T T`;
the 9-step source adds a trailing TIE. Pitch-matched holds at48/52/60 pass at
all three tempos. Same-pitch Repeat length16 passes at90/120/150BPM; other
measured lengths pass at120BPM. Repeated exports in each triplet are byte-
identical deterministic offline renders, not independent soundcard captures.
The fresh packaged ACID tool also passed normal Generate, Live Edit8→9→8,
ownership and save/reopen on phrase30. The exact records are in
[audio_capture_evidence.md](audio_capture_evidence.md).

The builder below creates only the 8-step native-control phrases. The 9-step
actual-writer cases are authored in `fixtures/moving_repeat_glide_cases.json`
and rendered by the writer/lifecycle workflow; they are not produced by this
native probe. Neither layout qualifies other moving lengths, pitches or
profiles. REST cancellation and explicit OFF before a fresh NOTE are verified;
an ungated NOTE after glide fails its attack check. Device playback, Live Edit
while playing, and manual transport stop/start and seek remain unverified.

Run `renoise_moving_repeat_glide_probe.lua` from the Renoise scripting terminal. It appends `ACID MOVING SLIDE FOUR SEMITONE` and `ACID MOVING SLIDE OCTAVE` to the existing `ACID ARTICULATION PROBE` instrument. Each phrase has an eight-step loop, alternating pitches 48→52→48 or 48→60→48, with outgoing slide flags, fixed `0G20`, and `0G00` continuation lines through held TIEs. The first note of each loop tests the downward seam. The target NOTE transitions test upward and downward movement. Use the exact phrase names when selecting playback; program numbers depend on the other phrases already in the instrument.

Run `renoise_moving_repeat_glide_controls.lua` to add held NOTE controls for pitches 48, 52, and 60. They trigger once, then loop over TIE lines until the host OFF. The helper prints each assigned program number; the exact names are also recorded by the readback helper. Capture each moving phrase and each pitch-matched hold at 32 host steps with 5.5 seconds of tail. This provides one cold pass plus three steady cycles, then host OFF. Preserve the standard two-second silent pre-roll pattern before the trigger sequence. Render that entire section using `renoise_render_capture.lua`, 48 kHz/24-bit/precise, with the qualified calibration master gain. Run `renoise_moving_repeat_glide_readback.lua` to record phrase names, program numbers, loop boundaries and all non-empty note/effect cells under ignored `tmp/acid-articulation/`. Keep render metadata and WAV SHA-256 beside each take. The probe builder refuses duplicate phrase names; use a fresh disposable song if the moving phrases have already been added.

Create the independent windows with `create_moving_repeat_glide_protocols.ps1`. Analyze each WAV with the matching case and custom oracle path, for example:

```powershell
./tests/acid/analyze_articulation_audio.ps1 `
  -CaseId native_repeat_glide_four_semitones `
  -OraclePath tests/acid/fixtures/moving_repeat_glide_cases.json `
  -WavPath tmp/acid-articulation/<capture>.wav `
  -OutputPath tmp/acid-articulation/<capture>.analysis.json
```

The custom oracle also includes actual-writer cases `writer_repeat_glide_four_semitones` and `writer_repeat_glide_octave`. Set `ACID_ARTICULATION_ORACLE_PATH="tests/acid/fixtures/moving_repeat_glide_cases.json"`, the selected case ID, and writer mode `slide` before running `renoise_articulation_writer.lua` in ACID's Scripting Terminal. Capture its generated phrase through the same trigger/render path; the writer record contains the emitted cells.

The authored windows require an intermediate upward pitch trajectory, a 40 ms settled target, stable pitch in all four loops, no attack and no audible continuity break at any connected transition, and release within the declared deadline. Compare each glide with its pitch-matched held NOTE control. Three unchanged valid captures per case are required before that case passes. Native phrase controls and analyzer readiness do not establish actual ACID writer behavior or expand runtime support by themselves.

Run ./tests/acid/test_moving_repeat_glide_protocols.ps1 to check the custom analysis windows against two valid synthetic sweeps and deliberate instantaneous-jump, retrigger, gap, and pitch-shift failures. These synthetic checks validate analyzer discrimination; they do not establish native playback.
