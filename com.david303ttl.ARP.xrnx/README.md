# ARP.xrnx v0.3 (experimental)

Up/Down/Up-Down pattern-to-pattern note generator for Renoise 3.5+.

## New in v0.3

- Musical rate choices: 1/4, 1/8, 1/16, 1/32, converted into pattern lines using song LPB.
- Octave expansion from 1 to 4 octaves; out-of-range notes (>119) are skipped.
- Rates needing a fractional pattern-line interval **fail safely with an explanation**. Example: LPB 4 allows 1/4 (4 lines), 1/8 (2 lines), 1/16 (1 line), but not 1/32. Increase LPB to enable finer rates.

## Usage and limitations

Choose source and different destination sequencer tracks, rate, direction and octave range. Enter simultaneous chord notes in visible note columns of the source track; each new chord onset restarts the arpeggio. Generate into destination column 1, which must be **entirely empty**.

The engine emits note-ons only; it does not yet create note-offs or gate lengths, process source releases, swing, delays, regenerate output, or continue over pattern boundaries. A short pluck/one-shot instrument is recommended. Use a disposable song for testing.

Source track and existing destination content are never intentionally overwritten; the destination is preflighted before writes. Code has not been executed in the user's Renoise installation yet.
