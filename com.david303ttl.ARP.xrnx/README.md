# ARP.xrnx v0.7 (experimental)

Pattern-based Renoise 3.5+ arpeggiator with LPB-independent rates, explicit
destination instruments, and guarded regeneration. Version 0.7 adds experimental
delayed Note-Off handling and structural ownership checks; see below.

## LPB-independent note divisions (introduced in v0.5)

Every musical rate (1/4, 1/8, 1/16, 1/32) is now scheduled using
Renoise's 256 note-delay subdivisions per pattern line, rather than
rounding fractional rates to whole lines. For rates that put multiple
notes on a single pattern line, the generator uses multiple destination
note columns in left-to-right time order.

Examples:
- LPB 4 + 1/32: two notes per line, delays 00 and 80 hex. Requires
  **2 visible destination note columns**.
- LPB 1 + 1/32: eight notes per line; requires 8 visible note columns.
- LPB 3 + 1/8: fractional 1.5-line spacing handled by delay positions.

Renoise supports up to twelve note columns; the tool refuses anything
requiring more. If you need more destination note columns, expand them
in Renoise's pattern track header (plus button); you do not need to
change the song LPB. The tool reveals the delay subcolumn automatically
after successful generation with delayed notes.

## Gate limitations

Rates expressible as *whole lines* retain v0.4's 25/50/75/100% gate
settings and same-column OFF scheduling.

Fractional-line rates support experimental 25/50/75% gates in v0.7 when
normal Note-Off events fit in the same voice's note column. Generation refuses
if ON and OFF would occupy the same line/column or a release crosses the pattern
end. Gate 100% writes no explicit release and can allow overlapping voices when
multiple columns are used. Verify the chosen instrument's release behavior in
Renoise; see the v0.7 checks below.

## Safe regeneration and migration

ARP stores event snapshots by **line and note column** in
tool-scoped per-song metadata. It recognizes legacy ARP04 metadata and writes ARP05 snapshots;
v0.7 additionally requires a structural fingerprint for safe regeneration. Generation and regeneration preflight the
entire area they would modify, reject edited/foreign notes, and
preserve unrelated columns. Legacy snapshots without the structural fingerprint are refused unless the
previously generated destination has been completely cleared.

If the previous run used extra columns and the new settings need fewer,
only verified, tool-owned output is removed from those columns.

Legacy pre-v0.4 output has no ownership metadata and is never silently
overwritten. Other existing limitations remain: one selected pattern,
no automated source tracking, structural editing after generation is
not fully supported. Work on an experimental song.

## Test instructions

Run `./scripts/run_tests.ps1 -Tool ARP` from the repository root.
See the [LPB/rate manual checks](../tests/arp/arp_v05_manual.md) and
[gate/edit-protection checks](../tests/arp/arp_v04_manual.md). The guides
describe their original milestones; the v0.7 behavior below takes precedence.

## Instrument routing and silent control track

The source note track provides pitches and chord boundaries only. ARP no
longer inherits an instrument number from those notes. Select a
**Destination instrument** in the dialog (00, 01, etc.). Generated note
columns will explicitly contain that instrument number, independently of
source chord instrument numbers.

The **Mute source track after generation** checkbox is enabled by default.
After a successful Generate/Regenerate, ARP sets the source track to OFF to avoid
hearing the original chord. Its notes remain intact and available for later
generations. This is a **whole-track OFF state**; use a dedicated source control
track if other musical content on that track must remain audible. A failed
generation does not change source playback state. Uncheck the box to leave that
state unchanged (it does not reactivate an already OFF track). To hear output, the
chosen destination instrument must contain a playable sample or plugin.

## Instrument routing test

1. Put an instrument 00 chord on source Track 01 and a playable instrument
   01 on destination Track 02.
2. Select instrument 01 in ARP, leave source mute enabled, Generate.
3. Confirm generated note instrument fields show 01, while source still
   displays 00 and the source track is OFF.
4. Regenerate using instrument 00. Destination note instrument fields
   should change to 00, source notes unchanged.
5. Disable automatic source mute, manually reactivate Track 01, and regenerate.
   The tool should leave its playback state unchanged, so source chords
   become audible again.

## Source OFF state

When the source-playback option is enabled, ARP sets the source track to Renoise's explicit OFF state after successful generation. Unlike a mixer MUTE, OFF prevents new note and command triggers even when the instrument is routed to another track. The source chord data remains editable and readable. Disabling the option does not automatically reactivate an OFF track. Previously sounding voices may still need to be stopped.

## v0.7 experimental hardening

Fractional rates now attempt normal **Note-Off** events at 25/50/75%
gates. They use a fixed note column per voice and precise note delays.
If the OFF and ON would occupy the same pattern line/column, or the
release crosses the pattern end, generation refuses without altering
the destination. Tick-based Cx **cuts are not enabled**; cuts and normal
Note-Offs have different articulation semantics.

For regeneration, saved ownership now includes a fingerprint of all
track names/types and pattern names/lengths in song order. Renaming,
inserting or reordering these invalidates prior ownership instead of
allowing unsafe index reuse. **Track names must be unique.** Legacy
ownership snapshots lacking this fingerprint will refuse regeneration
unless the previous generated destination has been completely cleared.

This is a conservative guard, NOT a permanent Renoise pattern GUID:
two indistinguishable same-name/same-length patterns can still be
reordered without being detected. Do not restructure songs with owned
ARP output. Undo/redo is protected by event-snapshot comparison but
the ownership metadata and Renoise undo are not yet one atomic state.

Manual test: LPB 3, Rate 1/8, Gate 75%, use an 18-line pattern and enough
destination note columns for the planned releases. Confirm delayed OFF
events and the instrument's release response. Also verify an LPB 4,
Rate 1/32, Gate 50% combination is refused without pattern changes.
Rename a source track after successful generation and verify a later
regeneration refuses to overwrite output.

Run the regression spec directly: `lua tests/arp/arp_writer_spec.lua`.

### End-of-pattern release check

At LPB 3, Rate 1/8 and Gate 75%, the last note in a 16-line pattern starts at zero-based line 15 and its OFF would fall at line 16 + 20 hex (past the boundary). Use an 18-line test pattern to fit that final release. The tool refuses any OFF outside the current pattern rather than clipping or silently truncating it.

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
