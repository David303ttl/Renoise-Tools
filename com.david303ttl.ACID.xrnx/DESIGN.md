# ACID design contract

ACID edits independent PITCH and TIME memories and generates native Renoise
instrument phrases. The runtime targets Renoise 3.5, scripting API 6.2 and Lua
5.1. All runtime modules remain inside the tool directory. Manifest version: 0.1.

## Source and interpretation

Canonical source contains 32 valid PITCH entries, 32 stored TIME commands, an
active TIME length of 1–32 and an independent active PITCH span of 1–32.
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

Program and Grid edit the same source. Both reach all 32 positions. Selection,
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
Articulation resolution is a timing-layout property threaded through gate,
glide, legato, pitch-bend and validation planning, not a fixed module
assumption.

Sample glide commands are budgeted against available lines and releases.
Plugin/MIDI routes use a periodic multi-column legato plan. A connected target
NOTE at delay 0 precedes the delayed predecessor OFF by the explicit minimum
positive note-column delay constant (1/256 phrase line). This is a per-event
offset, bounded and quantized to host ticks, not sample-accurate and never
cumulative step rounding. Same-pitch connections hold the existing voice.
Source-step coloring preserves cold and steady Repeat seams with up to three
note columns. Receiver mono/legato portamento supplies glide; sample 0G commands
are not sent to these routes.
The final validator checks every planned column and delayed OFF. Unrepresentable continuity,
connected dynamics and target envelope limitations produce explicit sonic
approximations. They never invalidate a legal musical source.

PB Range is a phrase render setting, independent of canonical source and its
hash. Off preserves the overlap route. An assumed ±2/±12/±24/±48 range requests
channel-wide native M1 bends for a single held plugin/MIDI note. Connected
transitions use a linear series at the timing layout's phrase resolution and
accumulate relative to that note anchor. Straight and triplet use four phrase
lines per step at LPB 16 and 12. A 32-step Repeat phrase has 257 lines,
including its empty exclusive-end sentinel, within the 512-line phrase limit.
Same-pitch connections hold without a retrigger; range overflow uses ordered
notes with a nonfatal approximation. A fresh NOTE uses delay 1 with a center
reset only when the bend channel is not known centered; otherwise both attack
and reset delay are 0. The 1/256-line ordering is per event and host-tick
quantized, bounded, and not sample-accurate. The receiver range and isolated
monophonic routing remain user configuration. Samples retain their automatic
glide path; hybrid sample layers need separate playback observation.

M1 uses `panning_string = "M1"` in the rightmost note column and a target
instrument value. The first effect column carries two hexadecimal MIDI data
bytes: its `number_string` is the main/MSB byte and `amount_value` the fine/LSB
byte. A 14-bit value `v` maps to `floor(v / 128)` and `v % 128`: center 8192
is displayed as `4000`, maximum 16383 as `7F7F`. Numeric effect-number properties
encode character bytes; they are not raw hexadecimal MIDI values.

The pinned API 6.2 PatternLine definitions and offline PatternLine documentation
establish cell access. The [official effect-command manual](https://tutorials.renoise.com/wiki/Effect_Commands#midi-commands)
establishes M1 placement and main/fine ordering. InstrumentPhrase documentation
also says phrase instrument columns normally address samples; these references
alone do not establish phrase-contained M1 routing to the intended plugin.
The bounded reference-VST bend/reset check remains unrun and is required before
claiming playback support. No routing devices or automation are inserted.

`writers/gate_writer.lua` merges gates and glide operations before mutation.
`writers/phrase_validator.lua` checks the final note, OFF, effect and metadata
layout. Rendering uses a temporary phrase, identity and ownership checks, then
a guarded phrase/source commit. Failed writes preserve the last-good destination
or retain identified recovery material if rollback cannot finish. Foreign,
manually modified and duplicate-ID destinations cannot be overwritten.

Generation requires LPB transport timing. Legacy speed timing is rejected before
phrase insertion or source-store mutation. The script runner starts native
rendering from `committed_observable`, after the new source is committed. This
notification does not establish compilation success; the native render callback
and phrase validation determine the outcome. A 500-idle-callback limit bounds
waiting for commitment. During rendering it only reports a pending-render
diagnostic and keeps the writer occupied.

Renoise exposes no render-cancel operation. Cancellation invalidates commit
authorization; an in-flight render retains the writer slot until its callback
arrives. A missing callback therefore blocks new writes and requires restarting
Renoise. Document release and tool unload detach observers and host references
without treating an unfinished render as complete.

`renoise/pattern_store.lua` stores the current WIP `ACID-PITCH-TIME-1` source
records and separate phrase output policy and PB Range in song-scoped tool data.
`renoise/phrase_ownership.lua` seals generated contents and loop properties.

## Live Edit and drafts

Live Edit starts rendering immediately for each source change and coalesces pending
edits. Jobs validate their token and song/target identity before mutation and
commit. Manual generation and Live Edit use structured render outcomes.

CLEAN, RENDERING, COMMITTED, APPROXIMATE and ERROR
separate pending edits, successful output, sonic limitations and write safety.
Recoverable failures keep Live Edit armed and preserve the draft. Retry or a
relevant edit schedules another attempt without an automatic retry loop.
Live Edit creates and binds its own phrase automatically for new, foreign,
modified or deleted phrase targets, preserving unrelated content. A hard API or
persistence failure reports an error while keeping the editor armed.
Dialog close and song changes invalidate outstanding work.

For the selected Renoise instrument, native selection of an owned phrase loads
its ACID source; foreign selections do not redirect the destination. Choosing
an ACID destination leaves Renoise's Phrase Editor selection unchanged.
Selecting a saved phrase alone does not schedule regeneration, while recovered
drafts do. Synchronous temporary phrase insertions and removals suppress their
own selection notifications; user selections between those operations remain
observable. Structural operations may change native selection. ACID never
assigns native selection properties or restores selection after generation.
The playback program is independent of the editor selection.

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
