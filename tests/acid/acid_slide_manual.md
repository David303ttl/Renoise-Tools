# ACID 0.1 — native sample articulation comparison

**Experimental; do not use a valuable song.** This tests native Renoise
phrase effects, not yet exact historical acid envelope/glide behavior.

**Current status:** this early procedure documents the initial experimental
workflow and is not the current Repeat support matrix. The fixed-rate 0G20
writer path now passes one-shot four-semitone renders, same-pitch Repeat length
16, and moving Repeat four-semitone/octave renders at the verified 8/9-step
layouts on the checked 120 BPM profile. A fresh packaged-tool GUI check passed
Generate, Live Edit 8→9→8, ownership and save/reopen for one moving case.
Other layouts, pitches, intervals, tempos and profiles remain refused; REST
interruption and effect-cancellation cases remain open. See the current
[articulation matrix](acid_articulation_manual.md),
[moving Repeat procedure](renoise_moving_repeat_glide_probe_manual.md), and
[evidence record](audio_capture_evidence.md). These are deterministic Renoise
offline renders, not independent soundcard captures.

## Preparation

1. Pull the latest `feature/acid-0.1-core` branch and reload tools.
2. Create a disposable song with a looping sawtooth sample instrument.
   Use sample pitch coverage for C-3, D#3, F-3 and G-3.
3. Each click creates a new phrase, so use a **fresh instrument with no
   existing phrases for each experiment** (or a fresh disposable song).
4. Enter one trigger note in a song pattern using that instrument.

## Three experiments

1. **Baseline**: select Baseline, generate, verify the same four note-ons
   and two OFFs as the already verified integration result.
2. **Retrigger + Gate**: generate on a fresh instrument. Expect an
   additional OFF one phrase line before the F-3 retrigger. There should
   be no 0Gxx effects. Listen for a fresh F-3 attack.
3. **Selective Slide + Gate**: generate on a fresh instrument. The
   transition from C-3 to D#3 is marked slide. Inspect the local effect
   commands 0G20 at phrase line 04 and 0G00 at line 05; a new OFF should
   appear on line 09 before F-3. Compare the audible transition with
   Baseline and Retrigger. Note whether envelopes retrigger or voices
   overlap. This effect placement is an experiment, not final calibration.

## Report

- ACID status line for each mode.
- Visible local effect command cells on lines 04 and 05 in Slide mode.
- The actual sound of the C-3 to D#3 transition: retrigger, smooth glide,
  silence, wrong direction, or no perceptible pitch movement.
- Any Renoise Lua errors.

Local checks (VS Code): `texlua tests/acid/acid_articulation_modes_spec.lua`.
No GitHub Actions. Keep ACID at 0.1. This test does not prove
phrase-loop boundary slides or authentic gate percentages.
