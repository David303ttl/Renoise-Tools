# ARP.xrnx v0.4 (experimental)

Native Renoise 3.5+ pattern-to-pattern arpeggiator with gate and
ownership-verified regeneration.

## Usage

1. Use a disposable song and open Tools > ARP.
2. Select different source and destination sequencer tracks.
3. Enter a chord on the source (simultaneous notes in visible columns).
4. Choose Rate, Order, Octaves and Gate.
5. Generate. Notes and supported note-offs are written to note column 1.
6. Change settings or source notes and Generate again to regenerate **only**
   if all previously generated destination events remain unchanged.

## Gate

- 100%: original note-on-only behavior; no explicit note-offs.
- 25%, 50%, 75%: insert a note-off using the same note column and, if
  required, the delay subcolumn (256 subdivisions per line).
- Renoise cannot represent two note events in the same note column and
  same line. The tool rejects unrepresentable short gates instead of
  approximating them. At LPB 4, rate 1/16 + gate 50% is unsupported,
  while rate 1/4 + gate 50% is supported.
- Overlap with another note-on or gate ending outside the pattern
  produces an explicit refusal. No partial writes.

## Safe regeneration

- Per-song ownership metadata is stored via Renoise tool_data and saved
  in XRNS; a different tool's metadata is not affected.
- Every previously written event must precisely match its recorded note,
  instrument, volume, panning, delay, local effect fields. Every other
  row of destination note column 1 must remain empty.
- Other destination note columns and track effect columns stay untouched.
- Generation refuses after edits to owned events, added notes in the same
  column, altered pattern length, changed route or track names, and
  destination aliasing.
- Legacy v0.3 output has no ownership metadata; it will not be replaced.
  Use a new, completely empty destination first note column.
- Undo/redo may leave the tool metadata out of sync. In that case,
  verification fails closed rather than overwriting data.
- Track/pattern reordering and reused pattern references still need
  further work. Avoid structural changes during this prototype test.

## Known limitations

No sample-accurate audio verification, no real-time MIDI processing,
automatic regeneration, cross-pattern gate, sub-line note-ons, swing,
or legato slide. Note-off audibility depends on the Renoise instrument.

See ../../tests/arp_v04_manual.md for a manual Renoise test sequence.
