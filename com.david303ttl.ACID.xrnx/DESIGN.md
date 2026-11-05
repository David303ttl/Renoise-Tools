# ACID design contract

ACID edits independent PITCH and TIME memories and generates native Renoise
instrument phrases. The runtime targets Renoise 3.5, scripting API 6.2 and Lua
5.1. All runtime modules remain inside the tool directory. Manifest version: 0.1.

## Source and interpretation

Canonical source contains 32 valid PITCH entries, 32 stored TIME commands, an
active TIME length of 1–32 and an independent active PITCH span of 1–32.
ACCENT and outgoing SLIDE belong to PITCH entries. Inactive stored entries are
preserved. Editor view, output policy and target capabilities are separate from
musical source and its ownership hash. Source also requires timing mode, a
mask-enabled boolean and twelve pitch-class booleans. Notes and resolved notes
are limited to MIDI 24–60. An enabled mask requires at least one selected class;
a disabled all-false mask remains valid. Shared resolution chooses the nearest
allowed note, breaking ties downward, without rewriting raw controls. One
prepared source snapshot supplies canonical resolved note/key/octave records
to projection, interpretation, planning and writing.

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
Source, phrase output/PB settings and label/custom metadata share one linear
Undo/Redo history. Sequential entry holds a detached candidate and entered
markers until Finish applies one real edit. Every position must be entered;
navigation never marks or commits it. Incomplete entry can be cancelled, and
guard resolution never resumes the blocked action.

The compact editor places instrument and phrase selection, rename/duplicate,
sequence settings, Program/Grid editing, scale, operations and output in one
interface. PITCH and TIME cursors/pages are independent. Grid shows canonical
source; inactive TIME slots are inspectable but direct editing is blocked.
TIME labels show Note/Tie/Rest; assignment controls highlight the selected
command. Grid pitches show resolved Renoise note names and enabled ACC/SLD
flags. Tooltips describe raw and resolved pitches, octave, ACCENT and SLIDE.
Shared feedback shows unresolved issues. Entry navigation is shown only during
sequential entry. Audition uses
the resolved accepted note in Grid or the PITCH-stage note in Program without source/draft/history writes.
A captured song/instrument/track lifecycle releases before replacement onset
and context changes; removed objects make cleanup best effort.

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

`model/output_planner.lua` merges gates and glide operations; the gate writer
preflights the planned operations before applying them to phrase cells.
`writers/phrase_validator.lua` checks the final note, OFF, effect and metadata
layout. Creation inserts its final destination; regeneration updates the exact existing
phrase without a staging/backup phrase. Identity and ownership checks protect
the guarded phrase/source commit. Failed writes preserve the last-good destination
or retain identified recovery material if rollback cannot finish. Foreign,
manually modified and duplicate-ID destinations cannot be overwritten.

Generation requires LPB transport timing. Unsupported speed timing is rejected
before phrase insertion or source-store mutation. Production phrase writes are
synchronous and serialized through `writers/phrase_writer.lua`; no separate
render engine or asynchronous render callback owns commits.

`renoise/pattern_store.lua` accepts empty song tool data or strict
`ACID-PITCH-TIME-2` data only. It serializes committed sources, output settings,
labels/custom bits and separate drafts. Unsupported/corrupt data remains
unchanged and blocks writes; there is no migration or reset fallback.
Candidates compare exact captured store bytes and verify publication.
`renoise/phrase_ownership.lua` seals generated contents and loop properties;
friendly labels never participate in the seal.

## Metadata and source operations

Labels are song-local 1–32-byte ASCII metadata with an initial alphanumeric
and subsequent alphanumerics, spaces, underscores, periods or hyphens. A
label-only transition persists before history acceptance and never renders,
dirties source or increments phrase revision. Failure retains accepted history
and an explicit Retry/Discard Attempt field state. Mixed source/label failure
retains the pair as one dirty local edit. Storage uncertainty blocks writes.

Session clipboard payloads carry exactly 32 PITCH records and PITCH span,
32 TIME commands and LAST STEP, or both. Paste preserves all other source,
metadata, output and target fields; identical results are no-ops. Duplicate is
an explicit authorized create from verified committed source/settings/metadata,
with a fresh ID and seal through the existing writer. A dirty original draft
must first pass durable save/readback and remains unchanged by duplication.

Clear, transform and seeded randomization construct validated source candidates
in the sequencer owner. Active scope uses the relevant memory bound; All 32
includes inactive storage without changing bounds. Shared TIME normalization
retains the leading-NOTE invariant. Pitch randomization retains flags and
samples uniformly from notes allowed by the enabled mask within its MIDI range.
An empty intersection rejects the operation. Each random operation advances
the Park–Miller state once before the first draw to diversify adjacent seeds.
PITCH and TIME retain independent entered/last session seeds. Valid Apply
remembers the seed and retains the entered seed. Reapplying an earlier seed with unchanged
parameters, mask and scope reproduces its generated values. Repeat last reuses
its last seed with current parameters/mask without changing the seed field.
Undo affects source, not seeds. Reset preserves LAST STEP and label/custom
metadata while resetting the other documented editor fields.
All changed candidates use one ordinary editor history/draft admission.

The scale library deduplicates root-relative membership and retains aliases.
Root/category/search select a browser view without editing source; selecting
a scale applies its absolute mask at the chosen root. Source persistence stores
only the mask, not preset names. Root/browser/Follow are session UI state.
Follow constrains new Program/Grid notes with nearest-note resolution, preserving
flags and existing raw notes. Imported libraries persist in tool preferences.
Name collisions across distinct memberships reject import before saving.
See [the custom scale format](../docs/acid-scales.md).

## Live Edit and drafts

Live Edit writes synchronously for admitted source/settings changes and
coalesces pending edits. Jobs validate their token and song/target identity before mutation and
commit. Manual generation and Live Edit use structured render outcomes.

CLEAN, RENDERING, COMMITTED, APPROXIMATE and ERROR
separate pending edits, successful output, sonic limitations and write safety.
Recoverable failures keep Live Edit armed and preserve the draft. Generate or
a relevant edit can attempt another write through normal admission; there is
no automatic retry loop. Persistent integrity blockers continue to reject writes.
Normal generation requires an explicitly armed New Phrase destination for
creation; Duplicate uses its captured committed-source authorization. Foreign,
modified, deleted and colliding destinations block generation. A hard API or
persistence failure reports an error while keeping the editor armed.
Dialog close and song changes invalidate outstanding work.

For the selected Renoise instrument, native selection of an owned phrase loads
its ACID source; foreign selections do not redirect the destination. Choosing
an ACID destination leaves Renoise's Phrase Editor selection unchanged.
Selecting a saved phrase or restoring a draft never schedules regeneration.
Writer-owned structural notifications are suppressed during the transaction;
user selection changes remain observable. Structural operations may change native selection. ACID never
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
[tests/acid/acid_regeneration_manual.md](../tests/acid/acid_regeneration_manual.md) records the
required host checks and their results. Unrun checks remain unverified.

The pinned API SDK is a development reference, never a runtime dependency.
[ROADMAP.md](ROADMAP.md) tracks implementation and acceptance gates. The
[editor playbook](M5_EDITOR_PLAYBOOK.md) defines source and musical behavior;
the [GUI redesign playbook](M5_GUI_REDESIGN_PLAYBOOK.md) defines the current
interface and its acceptance procedure. Final integrated native acceptance
remains open until its required checks are recorded.
