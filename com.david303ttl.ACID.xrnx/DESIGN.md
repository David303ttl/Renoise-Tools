# ACID design contract (0.1 development)

ACID is a Renoise phrase-based sequencer with independent PITCH and TIME
memories. It does not include a synthesizer. The runtime targets Renoise 3.5,
scripting API 6.2 and Lua 5.1; its modules and dependencies remain inside the
ACID tool directory. The manifest remains version 0.1.

## Source and interpretation

The canonical source holds 64 valid PITCH entries, a TIME length and complete
TIME commands, an explicit active PITCH span, entry mode and playback setting.
Original entry permits 1–16 straight TIME steps with a 16-entry active span;
Extended permits 1–64 steps and an independently selected span of 1–64.
Inactive stored pitches remain part of the source. Entry of TIE at TIME 01
stores NOTE; a noncanonical stored leading TIE is refused.

`model/cycle_interpreter.lua` resolves NOTE, TIE and REST for cold and repeated
cycles. Only NOTE consumes pitch. The next-consumed PITCH cursor resets to P01
at every complete TIME traversal and wraps within the active span. The current
semantic voice remains independent of that cursor: TIE holds it, REST clears
it, and its outgoing SLIDE connects to a subsequent NOTE unless a REST
intervenes. Equal-pitch SLIDE is a connected transition. Events preserve accent,
octave and hold intent; they do not assert a particular numerical gate or
sample-envelope behavior. No 16-step editor page is a playback boundary.

These decisions and their evidence are recorded in [M2_SEMANTICS.md](M2_SEMANTICS.md).
The original TB-303's CPU cursor behavior has not been measured. Original entry
is a supported programming subset, not a hardware-fidelity certification.

## Editor, phrase output and protection

`gui.lua` and `model/editor_state.lua` edit and project the canonical source.
The preview uses the same interpreter for initial and repeated cycles. Manual
generation and Live Edit freeze the complete source, including inactive pitches.
Live Edit debounces edits, allows one render in flight and invalidates stale
jobs when the editing context changes.

`writers/pattrns_writer.lua` emits finite staging data, and
`writers/phrase_writer.lua` validates and commits a regular native phrase.
Baseline Repeat now emits a cold intro followed by a steady loop using the
exclusive-end sentinel layout. New drafts default to Repeat. Renoise 3.5.4 WAV
checks of ACID-generated output passed sampled pitch/silence and metadata checks
for lengths 1, 16, 17, 32, 33, 48, 49 and 64. Repeat accepts baseline
NOTE/TIE/REST only; slide transitions and non-baseline audio modes are refused.
One-shot remains available as an explicit choice. Sample release/cut tail,
voice continuity and transport behavior remain unverified. See [the Renoise
loop protocol](../tests/acid/acid_loop_manual.md).

`model/control_signals.lua` derives physical gate edges separately from
semantic voice intent, in 256 units per TIME step. It uses an explicit successor
cycle for Repeat boundaries. A fresh NOTE successor or one-shot tail releases
at the final held-step midpoint; a REST successor releases at the REST boundary;
a connected slide holds through its target. Outgoing SLIDE without a target
does not suppress a one-shot tail release. These are ACID rendering rules,
not measured hardware timings.

`writers/gate_writer.lua` merges gate and glide operations before any cell
mutation. The shared plan rejects collisions, occupied fields and writes beyond
the musical region, including the exclusive-end sentinel. The final phrase
validator checks merged note/OFF/effect expectations and rejects unexpected
delay, instrument, panning and cut-command data before committing the phrase
and source. Required glide cancellation is never silently discarded for OFF.
Repeat NOTE/REST gate seams pass offline renders on the checked profile, but
the full successor and tempo matrix is still open; the pure cyclic scheduler
does not confer broader acoustic support. See the
[gate verification procedure](../tests/acid/acid_gate_manual.md).

`model/pattern_store.lua` persists only the current song-scoped source format.
`writers/phrase_ownership.lua` seals generated content and loop properties.
Generation preflights the destination and source, stages rendering, checks
object identity and ownership again, and retains a backup while committing the
phrase and source. Failures attempt to restore both and report recovery material
when restoration or cleanup cannot be verified. Earlier development formats and
seals are unsupported; they are not imported or adopted.

## Verification boundaries

Pure Lua checks cover cycle semantics, source roundtrips and mocked integration.
Renoise 3.5.4 offline renders pass the authored gate matrix, bounded Repeat
glide classes, and mapped NOTE/TIE accent cases listed in the articulation
evidence. Identical exports establish deterministic offline output, not
independent soundcard captures. A fresh packaged-tool GUI check covered
Generate, Live Edit 8→9→8 resizing, ownership and save/reopen for one moving
Repeat case. Manual transport stop/start and seek, Live Edit during playback,
runtime keymapped triggering and rapid UI races remain unverified. Accent changes on connected slide chains
are explicitly refused before phrase mutation.
An earlier Renoise Demo session inspected writer-generated NOTE/TIE/REST cells
and ownership but could not render audio; its limitations are historical and
are superseded only for the named offline-render cases above. Undo, broad
field/mode roundtrips and failure-injection behavior remain unverified. The
pinned SDK under
`sdk/renoise-api-6.2` is a development reference and is not a runtime
dependency. Remaining gates and unresolved playback/hardware questions are in
[ROADMAP.md](ROADMAP.md) and [M2_BLUEPRINT.md](M2_BLUEPRINT.md).
