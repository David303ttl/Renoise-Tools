# ARP (experimental)

ARP generates arpeggios in a Renoise pattern from notes on a source track.
Choose the source track, destination track and destination instrument, then set
the direction, range, rate and gate.

## Rates and gates

Rates 1/4, 1/8, 1/16 and 1/32 use Renoise's 256 note-delay positions per line,
independent of song LPB. When a rate places multiple notes on one line, ARP
uses multiple destination note columns in time order. Expand the destination
track's visible note columns as needed; Renoise supports at most twelve.

Whole-line rates support 25%, 50%, 75% and 100% gates. Fractional-line rates
support 25%, 50% and 75% when Note-Off events fit in the same voice column.
Generation refuses when an ON and OFF collide or a release crosses the pattern
end. A 100% gate has no explicit release and may overlap voices. Verify the
chosen instrument's release behavior in Renoise.

## Source playback and regeneration

The source track supplies pitches and chord boundaries. Generated notes use the
selected destination instrument, independently of the source note instruments.
**Disable source note playback (OFF)** is enabled by default. After successful
generation, ARP sets the source track to OFF; this suppresses new note and
command triggers, but does not stop voices already sounding. Disabling the
option leaves the current source playback state unchanged.

ARP records generated events in per-song tool data. Regeneration verifies saved
events and a structural fingerprint of track and pattern names, types and
lengths before replacing output. Edited or foreign events block regeneration.
Track names must be unique. Legacy ARP04 data is read; ARP05 data includes the
fingerprint required for safe regeneration. Output without ownership data is not
overwritten. Use a disposable song when experimenting; structural edits after
generation can invalidate ownership. Structurally indistinguishable patterns
may evade the fingerprint, and Renoise Undo is not atomic with ownership metadata.

Run the [ARP test suite](../tests/arp/) from the repository root with
`./scripts/run_tests.ps1 -Tool ARP`. See the [Renoise manual checks](../tests/arp/arp_manual.md)
for rate, gate, routing and ownership behavior.

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](../LICENSE).
