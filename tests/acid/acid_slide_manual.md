# ACID 0.1 — native sample articulation comparison

**Experimental; do not use a valuable song.** This tests native Renoise
phrase effects, not yet exact historical acid envelope/glide behavior.

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
