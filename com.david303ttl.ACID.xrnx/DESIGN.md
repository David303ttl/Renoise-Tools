# ACID architecture and contracts

ACID targets Renoise 3.5, scripting API 6.2 and Lua 5.1. Each runtime module
is private to this tool. The pinned SDK is a development reference, never a
runtime dependency. See [README.md](README.md) for controls and usage.

## Source and interpretation

Canonical source contains 32 PITCH entries, 32 TIME commands, an active TIME
length of 1–32, an independent PITCH span of 1–32, timing mode and a twelve-class
pitch mask with an enable flag. Inactive entries remain stored. ACCENT and
outgoing SLIDE belong to PITCH entries. Output settings, labels, target
capabilities and editor navigation are separate from the musical source hash.

Raw and resolved notes stay within MIDI 24–60. An enabled mask must contain at
least one class; a disabled empty mask is valid. Resolution selects the nearest
allowed note, breaking ties downward, without rewriting raw notes. One prepared
source snapshot supplies resolved notes to projection, interpretation and planning.

NOTE consumes the next active PITCH entry; TIE holds the voice without consuming
pitch; REST releases it. Pitch consumption restarts at P01 on each TIME traversal
and wraps within PITCH span. Outgoing SLIDE connects to the next NOTE unless REST
intervenes, including equal-pitch connections. Editor pages are not playback
boundaries. TIME 01 must be NOTE or REST; entering TIE there normalizes to NOTE.

`model/cycle_interpreter.lua` derives cold and steady cycles independently of
sound generation. Repeat renders a cold introduction, a steady loop and an empty
exclusive-end sentinel. Play Once renders one cold traversal and final release.

## Editor state and operations

Program and Grid share canonical source with independent PITCH/TIME selections
and pages. Navigation and draft restoration never schedule generation. Sequential
entry holds a detached candidate until every active position is entered and
Finish admits one edit. Resolving an entry guard never resumes the blocked action.
Audition uses resolved notes without source, draft or history writes; captured
host objects govern release and cleanup is best effort if they disappear.

Source, output settings and label/custom metadata share one linear Undo/Redo
history. Changed operations enter through ordinary history/draft admission;
identical results are no-ops. Active scope respects the relevant memory bound;
All 32 includes inactive entries without changing bounds. TIME operations retain
the leading-NOTE invariant. Reset preserves TIME length and label/custom metadata.

Randomization is deterministic for a seed, parameters, mask and scope. PITCH
randomization retains flags and samples uniformly from permitted notes in range;
an empty intersection rejects the operation. The Park–Miller state advances once
before the first draw to diversify adjacent seeds. Entered and remembered seeds
are independent for PITCH/TIME and remain session state outside Undo.

Scale presets deduplicate root-relative membership and retain aliases. Only the
absolute mask persists with source. Root, browsing and Follow are session state;
Follow constrains new notes without rewriting existing raw notes or flags.
Imported libraries persist in tool preferences; conflicting names reject import.

## Rendering

`model/timing.lua` supplies four phrase lines per step at LPB 16 for straight
or LPB 12 for triplet timing. A 32-step Repeat uses 257 lines, including the
sentinel; Play Once uses 128. Generation requires LPB transport timing and
rejects unsupported speed timing before phrase insertion or store mutation.

`model/control_signals.lua` expresses gate edges in 256 units per TIME step,
including the Repeat successor. A fresh NOTE successor or Play Once tail releases
at the last held-step midpoint; REST releases at its boundary. Connected slides
hold into their target. Articulation resolution comes from the timing layout.

`model/output_planner.lua` combines gate and articulation plans. Sample glide is
budgeted against available lines and releases. Plugin/MIDI overlap starts the
target at delay 0 before the predecessor OFF at delay 1, using up to three note
columns across cold/steady seams. Equal-pitch connections hold the existing voice.
The 1/256-line ordering is per event and host-tick quantized, not sample-accurate.
Receiver mono/legato portamento supplies the glide.

PB Range is a separate phrase setting. Off uses overlap; ±2/±12/±24/±48 requests
channel-wide M1 bends relative to a held note anchor. Range overflow falls back
to ordered notes with an approximation. A fresh NOTE uses delay 1 with a center
reset only when the bend channel is not known centered; otherwise attack/reset
use delay 0. Receiver range and isolated monophonic routing are user configuration.
Samples retain their glide path; hybrid sample layers need separate observation.

`writers/phrase_pitch_bend.lua` encodes M1 in the rightmost note column with a
target instrument. The first effect column stores main/MSB in `number_string`
and fine/LSB in `amount_value`. A 14-bit value maps to `floor(v / 128)` and
`v % 128`; center 8192 displays as `4000`, maximum 16383 as `7F7F`. Numeric
effect-number properties encode character bytes, not raw hexadecimal MIDI values.

All valid instrument slots are accepted, including empty targets with a warning.
Capabilities are inspected read-only. Unsupported continuity or connected dynamics
produce explicit sonic approximations without invalidating legal source. ACID
does not configure generators, routing, receiver presets or phrase triggering.

## Transactions, ownership and persistence

`writers/phrase_writer.lua` serializes synchronous writes and guards target,
source and store identity. `writers/phrase_validator.lua` preflights destinations
and validates output; `writers/phrase_materializer.lua` applies and verifies
phrase content. Creation inserts the final destination. Regeneration updates the
exact existing phrase without staging, backup, deletion or reordering.

`renoise/phrase_ownership.lua` seals generated contents and loop properties;
friendly labels are excluded. Foreign, modified and duplicate-ID destinations
cannot be overwritten. Failed writes restore the last-good destination or retain
recovery evidence and block mutations when rollback cannot be verified. Persistent
song-integrity blockers have no repair action in ACID and survive same-song
reattachment. An ordinary recoverable failure can be retried through Generate.

`renoise/pattern_store.lua` accepts empty tool data or strict `ACID-PITCH-TIME-2`
only. Unsupported/corrupt bytes remain unchanged and block writes. Publication
compares exact captured bytes and verifies readback. Committed revisions retain
source/settings for native Undo/Redo; uncommitted drafts are stored separately.
Owned drafts resolve by ownership ID; New drafts need an unambiguous instrument.
Persistence failure retains the session draft with an unsaved warning. Saving
the XRNS is required for durable recovery.

Label-only changes persist before history acceptance and never render, dirty
source or increment phrase revision. Failure retains accepted history and an
explicit Retry/Discard Attempt state. Mixed source/label failure retains both
as one dirty edit. Duplicate uses verified committed source/settings/metadata
with a fresh ID; a dirty original must first pass durable save and exact readback.
Clipboard payloads contain all 32 records and bounds for their selected memory,
excluding timing, mask, metadata, output settings and target identity.

Live Edit writes admitted edits synchronously and retains the latest pending
trigger if the writer is occupied. Recoverable failures preserve drafts and keep
Live Edit armed without automatic retries. New creation requires explicit New
Phrase selection; Duplicate has separate committed-source authorization.
Dialog close and song changes invalidate outstanding work. Native owned-phrase
selection loads source; foreign selection does not redirect the destination.
Writer-owned structural notifications are suppressed during transactions; user
selection remains observable. ACID never assigns native selection properties.

## Verification boundaries

[Runtime acceptance](../tests/acid/runtime_acceptance.md) records scoped native,
deterministic and operator results, including waivers and limitations.
[GUI acceptance](../tests/acid/acid_gui_redesign_acceptance.md) records native
redesign, layout and lifecycle checks. Dated evidence applies to its tested build;
older pending statements are not a current implementation checklist.

Mocked tests do not establish audible playback. Recorded MIDI delivery does not
establish receiver audio or sample continuity; sample/VST audio capture was
waived and remains unverified. Use the
[regeneration guide](../tests/acid/acid_regeneration_manual.md) and
[timing guide](../tests/acid/acid_timing_manual.md) for host procedures and
receiver-specific checks. Waived investigations are not implementation blockers.
