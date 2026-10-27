# ACID design contract (0.1 development)

ACID is a Renoise phrase-based sequencer with independent PITCH and TIME
memories. It does not include a synthesizer. The runtime targets Renoise 3.5,
scripting API 6.2 and Lua 5.1; its modules and dependencies remain inside the
ACID tool directory. The manifest remains version 0.1.

## Source and interpretation

The M3.5 canonical source contract holds 64 valid PITCH entries, a TIME length
1–64 and complete TIME commands, an independently selected active PITCH span
1–64, articulation flags and musical timing mode. It contains **no editor
view, one-shot/repeat switch, renderer mode or instrument-profile whitelist**.
Inactive stored pitches remain part of the source. Entry of TIE at TIME 01
stores NOTE; a noncanonical stored leading TIE is refused.

**Editor:** Program (Roland-style PITCH/TIME) and Grid are two views of the
same source. View changes never reset, reinterpret or validate musical length.
New patterns are editable immediately with C pitch defaults. Destructive Reset
is explicit and undoable. Roland hardware conformance is a separate diagnostic,
not an Original-versus-Extended admission rule.

**Semantic interpreter:** cold and repeated cycles are derived for any valid
source. Output policy does not change NOTE/TIE/REST consumption or SLIDE/ACCENT
intent. Repeat is the default owned-phrase output policy; Play Once is an
optional phrase-specific rendering setting, never a canonical source field.
Both leave instrument-wide phrase triggering, transport and routing unchanged.

**Articulation:** delete `baseline`, `retrigger`, `slide`, `mono` **audio
modes entirely**, not only their visible selector. They must not survive as
internal algorithms, aliases, branch conditions, stored values, test fixtures,
compatibility options or default modes. A single semantic articulation pipeline
handles NOTE/REST/TIE and PITCH-owned SLIDE/ACCENT; per-target sample/plugin/MIDI
operators are capability-based, not renamed copies of old modes. The musical
SLIDE flag and fresh-NOTE retrigger intent are retained as source semantics,
not as selectable playback strategies. Missing continuous legato or dynamic
control is a visible nonfatal approximation, not a source rejection. Empty
instrument slots may own silent, inspectable phrases.

**WIP cutover:** replace source/seal serialization and APIs directly. Reject
old development snapshots; no migration, compatibility reader, mode adapter,
import, alias or adoption. Remove mode-specific tests and obsolete fixtures;
replace them with behavior-based semantic and renderer tests. Preserve
transaction, ownership and rollback safety for unrelated user content.
See ROADMAP.md M3.5.0.1 and M3.5.1–M3.5.6 for implementation gates.

`model/cycle_interpreter.lua` resolves NOTE, TIE and REST for cold and repeated
cycles. Only NOTE consumes pitch. The next-consumed PITCH cursor resets to P01
at every complete TIME traversal and wraps within the active span. The current
semantic voice remains independent of that cursor: TIE holds it, REST clears
it, and its outgoing SLIDE connects to a subsequent NOTE unless a REST
intervenes. Equal-pitch SLIDE is a connected transition. Events preserve accent,
octave and hold intent; they do not assert a particular numerical gate or
sample-envelope behavior. No 16-step editor page is a playback boundary.

These decisions and their evidence are recorded in [M2_SEMANTICS.md](M2_SEMANTICS.md).
The original TB-303's CPU cursor behavior has not been measured. Roland-style
Program view does not certify hardware fidelity; deviations are reported by a
separate conformance diagnostic.

## Editor, phrase output and protection

`gui.lua` and `model/editor_state.lua` edit and project the canonical source.
The preview uses the same interpreter for initial and repeated cycles. Manual
generation and Live Edit freeze the complete source, including inactive pitches.
Live Edit debounces edits, allows one render in flight and invalidates stale
jobs when the editing context changes.

`writers/pattrns_writer.lua` emits finite staging data, and
`writers/phrase_writer.lua` validates and commits a regular native phrase.
The current M3 writer uses a cold intro and steady loop with an exclusive-end
sentinel. The M3 sample-only playback-mode and exact-profile admission gates
are **implementation limitations to remove in M3.5**, not future design rules.
The replacement writer always accepts valid semantic input, uses an instrument-
capability-aware strategy, and commits a native phrase for samples, plugins,
MIDI or silent empty targets. Repeat and optional Play Once control the owned
phrase output layout only. Source edits never require choosing a separate
renderer or switching an Entry mode. See ROADMAP.md M3.5.0.1.

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
runtime keymapped triggering and rapid UI races remain unverified. M3 currently refuses accents on connected slide chains; M3.5 must remove this source-level prohibition, render the best target-compatible articulation, and mark fidelity separately.
An earlier Renoise Demo session inspected writer-generated NOTE/TIE/REST cells
and ownership but could not render audio; its limitations are historical and
are superseded only for the named offline-render cases above. Undo, broad
field/mode roundtrips and failure-injection behavior remain unverified. The
pinned SDK under
`sdk/renoise-api-6.2` is a development reference and is not a runtime
dependency. Remaining gates and unresolved playback/hardware questions are in
[ROADMAP.md](ROADMAP.md) and [M2_BLUEPRINT.md](M2_BLUEPRINT.md).
