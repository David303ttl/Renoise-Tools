# ACID design contract

ACID edits independent PITCH and TIME memories and generates native Renoise
instrument phrases. The runtime targets Renoise 3.5, scripting API 6.2 and Lua
5.1. All runtime modules remain inside the tool directory. Manifest version: 0.1.

## Source and interpretation

Canonical source contains 64 valid PITCH entries, 64 stored TIME commands, an
active TIME length of 1–64 and an independent active PITCH span of 1–64.
ACCENT and outgoing SLIDE belong to PITCH entries. Inactive stored entries are
preserved. Editor view, output policy and target capabilities are separate from
musical source and its ownership hash.

NOTE consumes the next active PITCH entry. TIE holds the semantic voice without
consuming pitch. REST releases it. PITCH consumption restarts at P01 on each
TIME traversal and wraps within the active span. Outgoing SLIDE connects to the
next NOTE unless REST intervenes; equal-pitch SLIDE remains connected. No
16-step editor page is a playback boundary. Entering TIE at TIME 01 stores NOTE;
a raw leading TIE is invalid canonical source.

`model/cycle_interpreter.lua` derives cold and steady cycles independently of
phrase output policy and sound generator. These rules specify ACID behavior;
original TB-303 CPU cursor behavior and analog fidelity are not established.

## Editor and output

Program and Grid edit the same source. Both reach all 64 positions. Selection,
view changes and Start/Repeating preview never edit source or queue regeneration.
Fresh drafts have C pitches, NOTE commands, TIME length 16 and PITCH span 16.
Reducing active length preserves hidden entries. Reset is explicit and undoable.
Source edits and phrase output policy support editor Undo and Redo.

Repeat is the default phrase-specific output policy. It renders a cold
introduction followed by a steady body and an exclusive-end sentinel. Play Once
renders one cold traversal and a final release. Neither policy changes source,
instrument-wide phrase triggering, plugin state, MIDI routing or sample setup.

## Rendering and protection

`writers/phrase_writer.lua` accepts any valid instrument slot, including
sample, plugin, MIDI, hybrid, alias and empty targets. Capabilities are inspected
read-only on regeneration. An empty target receives a phrase with a silent-target
warning. Sound generation and routing remain the user's instrument configuration.

The semantic timeline feeds gate scheduling and capability-aware native
articulation. `model/control_signals.lua` expresses gate edges in 256 units per
TIME step and includes the Repeat successor cycle. A fresh NOTE successor or
Play Once tail releases at the final held-step midpoint. A REST successor
releases at the REST boundary. A connected slide holds into its target.

Sample glide commands are budgeted against available lines and releases.
Plugin and MIDI routes receive ordered notes, velocity and OFF events; sample
0G commands do not establish plugin or MIDI legato. Unrepresentable continuity,
connected dynamics and target envelope limitations produce explicit sonic
approximations. They never invalidate a legal musical source.

`writers/gate_writer.lua` merges gates and glide operations before mutation.
`writers/phrase_validator.lua` checks the final note, OFF, effect and metadata
layout. Rendering uses a temporary phrase, identity and ownership checks, then
a guarded phrase/source commit. Failed writes preserve the last-good destination
or retain identified recovery material if rollback cannot finish. Foreign,
manually modified and duplicate-ID destinations cannot be overwritten.

`model/pattern_store.lua` stores the current v3 canonical source and separate
phrase output policy in song-scoped tool data. `writers/phrase_ownership.lua`
seals generated contents and loop properties. Only the current source and seal
contracts are accepted.

## Live Edit and drafts

Live Edit debounces source changes, serializes rendering and coalesces pending
edits. Jobs validate their token and song/target identity before mutation and
commit. Manual generation and Live Edit use structured render outcomes.

CLEAN, DIRTY, QUEUED, RENDERING, COMMITTED, APPROXIMATE, SUSPENDED and ERROR
separate pending edits, successful output, sonic limitations and write safety.
Recoverable failures keep Live Edit armed and preserve the draft. Retry or a
relevant edit schedules another attempt without an automatic retry loop.
Destination safety loss suspends writes until the user resolves the target.
Dialog close and song changes invalidate outstanding work.

Uncommitted drafts are stored separately from committed source in song tool
data. Owned phrase drafts resolve by ownership ID. New phrase drafts require an
unambiguous instrument destination. Persistence failures preserve the session
draft and produce an unsaved warning. Save the XRNS to retain stored drafts.

## Verification

Lua specs validate deterministic semantics, current-format persistence and
mocked API integration. They do not establish actual playback, plugin velocity,
MIDI delivery, sample continuity or GUI scaling. The manual checklist in
[tests/acid/acid_m35_s_manual.md](../tests/acid/acid_m35_s_manual.md) records the
required host checks and their results. Unrun checks remain unverified.

The pinned API SDK is a development reference, never a runtime dependency.
[ROADMAP.md](ROADMAP.md) tracks implementation and acceptance gates. Triplet
timing and the full sequential Program workflow are separate planned work.
