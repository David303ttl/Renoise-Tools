# ACID 0.1 — control signal and Sampler verification

Status: experimental. Version remains 0.1, branch targets develop.
Do not use a valuable song. The new editor and control renderer have NOT
yet been manually verified inside Renoise.

## What is generated

The ACID sequence keeps PITCH and TIME memories separate. The
control-signal compiler returns timestamped `gate_on`, `gate_off`,
`pitch_target`, `tie`, and `rest` events with 256 units per
sixteenth step. A 50% interim gate is used for the single test renderer.
This is **not** a calibrated representation of the original circuitry.

Pattrns generates the phrase notes and REST offs; control signals schedule
additional native Note-Offs before unconnected retriggers. A separate
experimental local `0Gxx` phrase articulation path handles slides.
Cross-pattern slides and loop continuity are still not solved.

## Sampler architecture

- **Phrases:** note timing, releases, accent-velocity and selective glide.
- **Modulation:** amplitude envelope, filter envelope, velocity/accent
  response. Need a dedicated test instrument profile, not automated edits
  to a user's existing instrument.
- **Effects:** optional filters, saturation or coloration. Not necessary
  for the initial sequencer conformance checks.
- **Mono/Glide:** a second Renoise playback strategy, to be A/B tested
  against local `Gxx` commands. This version does not automatically set
  Mono or Glide because we need to verify and safely restore settings.

The GUI's `Inspect Sampler / Modulation / Effects` command is read only.

## Testing inside Renoise

1. Load ACID from the latest development branch; use a disposable song.
2. Create a native instrument containing a looping single-cycle sawtooth.
3. Open Tools > ACID and press the Sampler inspection button; confirm its
   sample count and any existing modulation/FX chain counts.
4. In PITCH memory choose an entry, modify its note (C-3..C-4), ACCENT,
   and SLIDE. In TIME memory choose a step and set NOTE, TIE or REST.
   Start with the eight-step fixture: N T N R N N T R.
5. On a fresh sample instrument with no phrases, choose Baseline and
   Generate Test Phrase. Confirm 16 lines with the edited note values.
6. On another fresh instrument, select Retrigger + Gate. Confirm the
   added OFF halfway through the preceding active step, with no accidental
   OFF on TIE.
7. On a third instrument, select Selective Slide + Gate. Flag slide on
   source pitch entry 1. Inspect 0Gxx on the target note and 0G00 on its
   following line, listen for a connected pitch move.
8. Compare attack envelope shape with identical sample/envelope settings,
   especially whether Gxx retriggers a modulation envelope.
9. Test a 12-step user sequence (12-step phrase should be 24 lines).
10. Report ACID status text, screenshot of edited phrase, and any Lua error.

Do not infer envelope continuity from the fact that pitch glides.
For objective comparisons, record each test as WAV, match BPM/LPB/sample
settings, inspect attack transients and note-off positions.

## Local tests

From the repository root, in VS Code with Lua 5.4:

```sh
lua tests/acid/acid_control_signals_spec.lua
lua tests/acid/acid_articulation_modes_spec.lua
lua tests/acid/acid_phrase_validator_spec.lua
lua tests/acid/acid_phrase_spec.lua
```

Run all existing `tests/arp/*_spec.lua and tests/acid/*_spec.lua` scripts as regressions.
No GitHub Actions. Don't merge until Renoise manual verification passes.

## Known unresolved items

- Historical gate timing and pitch-memory wrap semantics.
- Selective glide without envelope retrigger in actual audio.
- Programmatic Mono/Glide comparison while preserving user settings.
- Key tracking and pitch-range mapping beyond editor's first octave.
- Editable pattern bank, persistence and safe phrase regeneration.
- Acid accent's filter-envelope and loudness behavior.
- Proper phrase-loop and cross-pattern legato.
