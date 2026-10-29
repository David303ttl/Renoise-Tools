# ACID — Renoise functional acceptance

**Current acceptance:** instrument/phrase synchronization, ownership, in-place regeneration, persistence, plus pending host validation of the max-32 timing/layout contract. See [M4](../../com.david303ttl.ACID.xrnx/ROADMAP.md#6-m4--exact-timing-modes-and-tempo-independent-phrase-output).

## Program/Grid and source

1. Open ACID on a fresh instrument slot. Confirm the draft is editable without
   a Create step, with C pitches, NOTE commands, LAST STEP 16 and PITCH span 16.
2. Change LAST STEP to 32 and PITCH span to 32. Confirm both independent
   capacities are 1–32. Edit TIME and PITCH positions 1, 16, 17 and 32.
   Switch Program → Grid → Program. Confirm the source values,
   decoded preview and generated phrase cells do not change from view switches.
   With Live Edit enabled, confirm switching views does not queue a render.
3. Edit TIME 17, reduce LAST STEP 16, then restore 17. Confirm TIME 17 remains
   unchanged. Save and reopen the XRNS and repeat the check.
4. Enter TIE at TIME 01. Confirm it is stored as NOTE. Click Reset Source once
   and confirm the source resets immediately. Use Undo and Redo and confirm
   the source and output policy follow each edit.

## Output policy and destination safety

1. Record the selected instrument's phrase trigger mode and phrase program.
   Generate an ACID-owned phrase with Repeat, then choose Play Once and
   regenerate it, then return to Repeat. Confirm only the owned phrase layout
   and saved output policy change; PITCH/TIME, trigger mode and phrase program
   remain unchanged.
2. With at least two owned phrases, select the second phrase and regenerate it.
   Confirm it is updated in place, the first phrase is unchanged, and the
   destination chooser remains on the selected phrase.
3. Verify Repeat contains a cold introduction and repeating body. Verify Play
   Once contains one traversal and a final release. Inspect NOTE/TIE/REST cells,
   the final release and the ownership seal.
4. Edit an owned phrase manually and confirm ACID refuses replacement while
   preserving it. Confirm a foreign phrase is also preserved.

## Pending current-layout Renoise acceptance

These checks have **not** been run. Record the Renoise build, source, output
policy, phrase LPB, line count, loop endpoints and observed playback for each.

1. Generate a max-length Straight source (N=32). Verify phrase LPB 16, four
   phrase lines per source step, and 128 Play Once lines with final release.
2. Generate a max-length Triplet source (N=32). Verify phrase LPB 12, four
   phrase lines per source step, and 128 Play Once lines with final release.
3. For both timing modes, generate Repeat at N=32. Verify 257 lines, an empty
   exclusive-end sentinel, `loop_start=129`, `loop_end=257`, and the repeating
   cycle period; listen across the cold-to-steady and steady-to-steady seams.
4. Repeat Straight/Triplet at short and boundary lengths; verify step durations
   remain 1/4 and 1/3 beat respectively and no drift appears across the seam.
5. Target PB fresh attacks both when the bend channel is known centered and when
   it is not. Verify delay 0 without reset and delay 1 plus center reset when
   required. Renoise tick quantization applies; this is not sample-accurate.

## Target sanity

- Generate and regenerate with one sample instrument, one available plugin instrument and an empty instrument. Empty instrument may be silent; the editor and writer must remain usable.
- MIDI-only, hybrid and alias fidelity are receiver-dependent release checks, not M4 blockers.
- Straight/Triplet playback and PB attack/reset alignment at LPB16/12 remain pending in the timing checklist.

## Native render lifecycle

1. Generate and regenerate under normal and busy host load. Confirm committed
   source renders correctly or reports an error without replacing last-good output.
2. Cancel during rendering. Confirm staging remains and new writes are blocked
   until the callback arrives; canceled output must not replace the destination.
3. Close the song or unload the tool during rendering. Confirm no stale GUI
   updates or invalid-object errors occur. Tool reload is not a render-cancel path.
4. In a speed-timing song, confirm generation is refused without changing phrase
   count, saved source or transport. Switch timing during rendering and confirm
   the last-good destination and source remain unchanged.

Renoise 3.5.4 LPB check: phrases 01 and 02 were created and 02 was regenerated
through the native callback; count stayed two. Phrase preview started and the
Renoise output meter showed signal; Stop halted preview. Missing callbacks,
cancellation during rendering, document release during rendering and speed
timing remain unverified. The open song uses LPB timing; the API exposes
`transport.timing_model` as read-only, so no live speed-timing song was tested.

## M3.6 Plugin/MIDI pitch bend

**Pending (NOT YET PERFORMED):** Using the existing disposable-song method,
verify conditional center-reset and fresh-attack alignment at LPB 16 and 12:
delay 1 plus reset only when the bend channel is not known centered; otherwise
delay 0. Check both Straight and Triplet and actual host-tick behavior.

PB Off/on safety, range overflow and receiver-independent structural behavior belong to Lua regression tests. Other receivers are not certified; no additional audio-capture gate.

## Save, reopen and Live Edit

1. Save and reopen the XRNS. Confirm current source and Repeat/Play Once policy
restore for each owned phrase.
2. Explicitly select New Phrase, then enable Live Edit and confirm no phrase is created. Make a source edit and confirm exactly one owned phrase is created and bound, with rendering starting
   immediately without Generate or a debounce wait. Make several edits during
   rendering and confirm the latest source applies automatically next.
   Disable Live Edit during an in-flight
   render and confirm the destination remains consistent.
3. Change songs while ACID is open, then close/reopen the tool. Confirm stale
   jobs are invalidated and no phrase in the new song is changed.
4. Edit without generating, switch destinations and return, then close and
   reopen ACID. Confirm the draft is restored. Save the XRNS with an ungenerated
   edit, reopen the song and confirm the draft restores separately from the
   last committed phrase. Generate and confirm the pending draft is cleared.
5. Use Undo and Redo during Live Edit. Confirm source and output policy follow
   the selected edit and the final generated phrase matches the source. Change
   BPM, LPB/TPL and groove during playback, then stop/start/seek. Confirm Live
   Edit remains armed and note/OFF order stays correct.
6. Cause a recoverable render failure and confirm Live Edit stays enabled.
   Correct the problem by editing the source; confirm it renders immediately
   and preserves the last-good phrase until success. Modify or delete the destination externally; confirm Live Edit suspends safely without appending, preserves the draft and last-good/unrelated phrases, and requires an explicit new destination.


## Async generation and draft safety

1. Generate a new phrase, edit its draft while rendering, then switch to a
   different phrase or instrument before completion. Return to the generated
   phrase and confirm the pending edit survives. Confirm the other destination
   and its draft remain unchanged.
2. Change plugin, MIDI route or sample availability while rendering. Confirm
   the commit suspends, preserves the last-good phrase and reports the change.
3. Reorder instruments and phrases, delete the selected target and duplicate an
   owned ID. Confirm writes never reach a different destination. Recovering a
   draft does not authorize overwriting a foreign or modified phrase.
4. Make song tool data unwritable or corrupt in a disposable test. Confirm the
   source remains recoverable in the editor, persistence failure is visible and
   closing the song warns about any draft that could not be stored.

## Diagnostics and Windows scaling

At 125% and 150% scaling, inspect dirty, queued, rendering, committed,
approximate and error states. Confirm target and cause are readable
and diagnostic text can be selected. Use Go to source error and confirm the
reported TIME/PITCH location is selected without modifying source.

## M4.7 acceptance record

### Prerequisite feasibility record

Native feasibility ran on 2026-10-29 in Renoise **3.5.4 Demo / API 6.2**
using the installed development ACID tool and a disposable XRNS. The probes
found inactive-script preservation and ownership/source undo failures.
**Step 0 is complete:** observed outcomes, the tested script-state rejection
predicate and revised safety contracts are recorded. Steps 1/3/4/6 implement
the fixes and Step 8 verifies native acceptance; neither the current runtime
nor those later gates are marked passed. The pinned SDK setup and all 34 ACID
specs passed.

#### Script-free staging feasibility

**Step 1.1: passed, 2026-10-29; Renoise 3.5.4 Demo / API 6.2.**
The disposable `acid-empty-feasibility.xrns` fixture used the installed ACID
tool and the actual `writers.pattrns_writer.emit` output for two C-4 notes.
Probe code, exact value snapshots and logs remain untracked under repository
`tmp/`, outside runtime and package inputs.

The verified sequence is: assign the generated paragraphs to the single
staging phrase in `PLAY_SCRIPT`; call `commit()`; request `render_to_pattern`
from its committed notification; require the successful callback (two rendered,
zero skipped) and the expected C-4 on line 1; assign `script.paragraphs = {}`
and call `commit()` while the generated stage remains in `PLAY_SCRIPT`.
The clear notification precedes compilation settlement. Inspect later native
state until the empty-content compilation diagnostic appears and the exact
empty predicate passes; no fixed delay authorizes publication. Verify all
rendered values unchanged, then change only that stage to `PLAY_PATTERN` and
verify that this is the sole changed field. Never clear a destination script.

| Check | Native result |
| --- | --- |
| Canonical empty script | Exactly zero paragraphs, zero parameters, `pending_changes = 0`, readable `editor_visible = true` |
| Derived diagnostics | `compile_error` is `compile error: no script content present.`; `runtime_error` is empty. Empty compilation is expected after clearing; it is distinct from the preceding successful render callback. |
| Clear preserves rendered output | Exact comparison passed for all 512 lines, 12 note columns, eight effect columns, all numeric cell fields and `is_empty`, phrase settings, visibility, column names/mutes and mapping state |
| Create and two regenerations | Same live destination by `rawequal`; one final phrase after each operation; each next preflight accepted the canonical empty state |
| Copies and rollback | Destination-to-backup, stage-to-destination, backup-to-destination and final publication preserved every compared value; backup neutral name and absent mapping were explicit exceptions only for backup/stage comparison |
| Mapping preservation | Original destination mapping remained unchanged and was independently compared through publication and exact rollback; mapped line count remained unchanged |
| Later native settlement | Five subsequent idle snapshots per operation matched the complete expected values; no script or parameters reappeared |
| Save/reload | `save_song_as`, then `load_song` of the saved disposable XRNS, followed by a fresh complete snapshot, matched every persisted field including exact empty paragraphs and readable editor state |
| Numeric command encoding | Native note/effect numbers: `00=0`, `0G=16`, `40=1024`, `7F=1807`, `0M=22`, `ZT=8989`; note panning `M1=5633`. Command digits use base-36 values packed into two bytes. |
| Guarded store helpers in the installed bundle | Existing and New draft removal, unrelated scratch preservation, captured absence with a later draft, exact raw/draft rollback and stale revision rejection passed. The probe restored original `tool_data` and deleted only its raw-identity instrument. This tests persistence helpers, not musical source/output compatibility or writer integration. |
| Fresh-bundle verification | Saved canonical script-free values passed the complete read-only comparison after refreshing the installed modules. |

Compilation/runtime diagnostics are logged separately as derived values and
excluded from preserved-value equality. Full source/output classification is
Step 1.5; these comparisons prove that clearing and copying preserve the
rendered values captured before clearing.

The generated fixture has no script parameters. A parameter-bearing probe
retained its parameter after empty commit and is unsupported; it does not
establish a parameter-clearing contract. Existing destinations with parameters
or nonempty scripts remain rejected. The supported publication sequence clears
only this job's parameter-free emitted script. Full writer, lifecycle, undo and
playback acceptance remain separate gates.

#### Native ownership/source undo probe (2026-10-29)

**Failed: association contract revised; runtime fix and final acceptance remain pending.**
The second-pass native run used Renoise **3.5.4 Demo / scripting API 6.2**, an
installed development ACID bundle and the disposable feasibility song. Probe
commands executed from the tool's idle callback, preserving the required
bundle-specific `song.tool_data` context. The temporary probe and raw logs are
untracked development artifacts; the observations below are the durable record.

The fixture was a newly inserted instrument with one 16-line phrase and a unique
ACID ID. Canonical valid source A was `new_pattern(4)` with first pitch C-3;
source B changed its first pitch to G-3. Native phrase sentinels A/B placed C-3
or G-3 on line 1 and recomputed the current-format ownership seal. This is an
association feasibility fixture, not a complete generated-output or playback
check. Every snapshot called the actual `phrase_ownership.status` and
`pattern_store.load`; source availability therefore reflects current runtime
validation rather than a custom imitation.

| Action | Native observation |
| --- | --- |
| Synchronous phrase content/name plus source A → B | Final B phrase had a valid seal and loaded B. During the name notification, B briefly loaded A; reconciliation must defer such internal notifications. |
| Native undo of that synchronous action | Both the return-time and subsequent idle snapshots showed **phrase A, valid A seal, loaded source B**. `is_undo_redoing()` was already false at these stable snapshots. The current loader silently accepted the inconsistent association. |
| Native redo | Restored phrase B, valid B seal and loaded B at return and idle. |
| Content/name and source across separate idle callbacks, `describe_batch_undo(...,5000)` | Content B initially loaded A; after source commit B loaded B. `can_undo()` and `can_redo()` were false after settlement and the attempted native undo changed nothing. Successful batching was not established. |
| Same split with an intervening native track rename | The rename remained visible; source commit ended at B/B. Later snapshots still reported no undo/redo availability, and native undo changed neither phrase nor track. This does not validate preservation or grouping of intervening user actions. The intervening action used the native track-name API with a separate undo description, not a physical keyboard edit. |
| Name-only rekey to an otherwise unused ID | Seal remained valid but source loading rejected the missing source record. |
| Source-only A → B while phrase A/name A remained unchanged | Phrase remained owned and source B loaded successfully, independently confirming that the seal does not bind the source record. |

The corrected run used a 5000 ms batch timeout. An earlier attempt used 20000 ms,
which Renoise rejected (native accepted range: 0–10000); subsequent snapshots in
that invalid attempt crossed fixture lifetime boundaries and are excluded from
the split/interruption evidence. The corrected probe checked raw object
membership and blocked undo beyond each fixture case. Its observers were removed
at completion. Native undo was invoked through the documented song API; keyboard
undo and a real generated ACID transaction remain later acceptance checks.

**Fallback:** an unchanged seal and valid persisted source cannot authorize a
write by themselves. The revised playbook requires independent, read-only
comparison of saved source/settings with expected musical output, including
known receiver/PB inputs and complete unsupported-field preflight. Unknown or
mismatching associations block writes and preserve detachable source drafts;
undo reconciliation must not repair phrase names, content or persisted source.
Identical-output source variants may be compatible without proving historical
provenance. Session-only verified tuples cannot establish safety after reload.
This native failure resolves the feasibility question but is not a passing undo
acceptance result; implement and verify the revised contract before relying on
source/ownership reconciliation.
#### Native copy, notification and script probes (2026-10-29)

The second-pass copy fixture used a fresh, unselected instrument with destination,
staging and backup phrases. Distinguishable values occupied all seven note-cell
fields and both effect-cell fields at lines 1, 16, 17 and 512 in all 12 note and
8 effect columns. Visibility and active length were then reduced to one column
and 16 lines; native reads confirmed retained hidden/tail sentinels. Comparison
read every available column through line 512, all documented phrase settings,
12 column names/mutes, mapping presence/fields, and inactive script editor state.

Destination → backup and stage → destination preserved the compared pattern,
column and phrase values with zero unsupported reads. Mapping was **not copied**:
the backup had no mapping and copying an unmapped stage retained the destination
mapping. The mapping sentinel used range 36–47, base note 43, key tracking 3,
loop enabled, endpoints 2–14. Backup → destination restored every compared value
with zero differences, including that existing mapping. Raw destination identity
was preserved. Therefore rollback must snapshot/compare the destination mapping
fields separately; a backup phrase alone does not contain its mapping.

A separate inactive-script fixture remained in pattern playback mode throughout.
Its committed integer parameter defaulted to 13, settled on idle 2, and was changed
to 23. Pending editor text then changed the default to 31 (`pending_changes=3`).
After `copy_from`, the backup contained that editor text with pending count zero;
on subsequent idles its parameter settled to **31**, losing the committed version
and value 23. Complete inactive-script preservation therefore **failed**.
The temporary preflight predicate accepted an empty script and rejected both
committed nonempty and pending script fixtures: reject if any paragraph contains
non-whitespace text, any parameter exists, pending changes are nonzero, or access
fails. This predicate was exercised natively; it is not yet a runtime guard.
Generated ACID phrases may retain scripts, so later implementation must establish
safe supported preservation or explicitly block such regeneration. Do not erase
scripts to make targets pass. Setting inactive `editor_visible` raised a native
read-only error despite the pinned writable-looking declaration; the final probe
only read it. No playback mode toggle was used to inspect inactive scripts.

Insert/delete list events, name changes and copy line changes were synchronous in
the observed calls. Copies emitted destination-name notification before changed
lines 1, 16, 17 and 512. Mutating the unselected fixture preserved native selection
through three later idles; an earlier selected-instrument probe changed selection
after structural mutations. Neither observation establishes mutation origin or
universal selection behavior; reconcile on idle and cancel ambiguous jobs.

A valid committed script rendered two events, zero skipped, with callback on the
next idle. The invalid script's render callback reported a syntax error while
`compile_error` was still empty; that property changed on the following idle.
The runtime-error script's committed notification still exposed the preceding
compile error; later compile/runtime observables and the callback settled.
Thus no fixed idle delay or committed-notification error snapshot authorizes a
write. Callback results and independently validated output remain authoritative.
Missing/duplicate callbacks, busy-host timing, lifecycle cancellation and actual
playback were not established by these feasibility probes. All final probe
observers were removed; temporary scripts and logs remain outside package inputs.

#### Runtime inventory

The 2026-10-29 source audit classifies existing paths as **verify** (retain and
exercise), **correct** (change an existing path), or **complete** (fill a missing
part in its existing owner). Paths below are relative to
`com.david303ttl.ACID.xrnx/`; these observations are not native passes.

| Responsibility / current entry points | Classification and required follow-up |
| --- | --- |
| Runtime target and presentation: `gui.lua` `show`, `load_target`, `select_instrument`, `live_target`, `refresh_phrase_choices` | **Correct:** consolidate captured song/instrument/phrase objects, revision and session checks. Local instrument/phrase positions remain in use; preserve existing `rawequal` membership checks. |
| Musical requests: `gui.lua` calls `phrase_writer.generate` from the `live_regen.new` renderer and the Generate button | **Correct:** route both callers through one request boundary. `changed` saves a draft and requests Live Edit; checkbox arming and `load_target` also request writes today. Arming, navigation and recovery must stop doing so. |
| Serialized scheduling: `model/live_regen.lua` `new`, `invalidate`, `run_one`, `settle`; writer `cancel`, `release`, `complete` | **Verify/correct:** retain immediate single-flight/latest-pending behavior and cancellation ownership; verify terminal settlement and global occupancy across release. No debounce or second scheduler is needed. |
| Native mutation: `writers/phrase_writer.lua` `generate_impl`, `finalize`, `remove_phrase`, `mutate_phrases` | **Correct/complete:** staging insertion, backup insertion, destination-to-backup, stage-to-destination and backup-to-destination copies, and deletion all live here. Remove omitted-target phrase-1/append fallback; register occupancy before insertion; add complete preflight, preservation and checked recovery. The exceptional insertion-failure path deletes only a tail phrase matching `job.phrase` by `rawequal`; retain and verify that guard. |
| Script execution: `writers/script_runner.lua` `new` / `start`; writer `begin_wait` | **Correct/verify:** paragraphs are assigned by the writer; the runner attaches `committed_observable`, calls `commit`, then calls `render_to_pattern` directly from that notification. Writer idle handling waits for output settlement. Compile settlement after notification needs the pinned-API contract and native probe; retain authoritative callback results. |
| Selection, listeners and lifecycle: `gui.lua` `bind_selected_phrase_watch`, `apply_pending_selected_phrase_selection`, `detach_dialog_watch`, `release_context` | **Complete:** selected phrase notifications are queued and applied on idle; native selected objects and initial instrument index are read, with no native selection assignments found. Add selected-instrument, inventory, rename/content and undo reconciliation. Existing release/new-document/unload listeners invalidate work; dialog idle detects closing and detaches its watch. Verify repeated open/release cleanup rather than adding another idle loop. |
| Persistence: `model/pattern_store.lua` `prepare`, `commit`, `restore`, draft helpers; `model/draft_cache.lua` `put`, `get`, `clear`; GUI completion handlers | **Correct/verify:** keep these owners. Store commit rebases current drafts; GUI clears the committed draft afterward in a separate write. Make target-draft clearing atomic with musical commit and require unique live ID holders before durable draft access. Preserve the guarded newer-data rollback check. |
| Undo: GUI editor history buttons versus native phrase/source mutations | **Complete:** editor `history:undo` / `redo` changes source/drafts only. No `describe_undo`, `describe_batch_undo` or `is_undo_redoing` call exists in the current runtime. Native consistency and meaningful grouping remain prerequisite observations and later implementation work. |

#### Current storage contract

`renoise/phrase_ownership.lua` recognizes the exact name shape
`ACID 0.1 #<id> [v3:<eight hex digits>]`, bounds IDs to 1–2147483647 and
compares the persisted seal against current content. The seal covers active
lines and visible note/effect columns plus selected phrase properties and note
column mutes. It omits hidden/tail cells, column names, mapping and script
state. Preserve the name/version format; complete session comparison and
unsupported-field preflight belong in the same ownership/writer modules.

`renoise/pattern_store.lua` stores newline-terminated text in bundle-specific
`song.tool_data`, headed `ACID-PITCH-TIME-1`. Committed rows contain ID, output
policy, PB range, timing mode, pitch span, length, all 32 pitch events and all
32 TIME commands. `DRAFT` rows additionally contain instrument index, phrase
ID (0 for New) and a hex-encoded instrument name. Preserve these identifiers
and strict parsing: unknown headers, incomplete final lines, blank rows,
duplicate record keys, invalid policies/PB ranges, malformed pitch separators,
wrong event counts and invalid compiled sources are rejected. Normal `load`
requires a valid seal, one ID holder across the entire song and a valid source
record; notes alone never supply source.

`runtime/draft_cache.lua` keeps session drafts keyed by song/instrument/phrase
objects and a private New sentinel, copying source/settings on put/get.
Durable positive-ID lookup follows the ID across instrument positions; New
scratch recovery checks the stored instrument name and unique current name.
Durable phrase draft access checks the seal but not song-wide live-holder
uniqueness; cached session reads return the object-keyed draft directly.
A durable write/clear removes matching-ID draft rows, so collisions
must be blocked before those calls. Current durable records contain no
historical content/source baseline; do not infer one or migrate the schema.

The baseline rerun passed **34/34 ACID specs**. Native observations and required
fallbacks are recorded above; final runtime acceptance remains open.

The installed-tool/disposable-XRNS observations above establish these Step 0
decisions. Repeat the relevant probes against the final writer at Step 8:

| Probe | Required evidence | Result |
| --- | --- | --- |
| Full phrase copy/restore | Sentinel values in visible/hidden/tail cells, column metadata, phrase properties, mapping and inactive script state; compare destination → backup, stage → destination and backup → destination, including raw object identity | Qualified field roundtrip; inactive committed/editor/parameter state lost. Native rejection predicate tested; runtime guard pending. |
| Notifications and render settlement | Insert/copy/name/delete order, immediate/delayed selection effects, committed/compile-error timing and render callback settlement; cancel when origin cannot be distinguished | Observed synchronous structural events and asynchronous error/callback settlement; no origin or latency guarantee. |
| Ownership/source undo consistency | Phrase name plus tool data across idle callbacks and an intervening native action; inspect every undo/redo state for an inconsistent association that could authorize writing | Failed natively; stable undo mismatch accepted by current loader. Contract revised; runtime fix pending. See native probe record above. |

Do not treat unsupported preservation as a pass: record a detectable preflight
rejection and test it. A foundational undo/lifecycle failure requires revising
the playbook contract before runtime implementation continues.

Step 0 closeout also verified that the installed development tool's `main.lua`
was restored byte-for-byte from its pre-probe backup, all temporary bridge and
probe observers were removed by tool reload, and the disposable fixture was
saved. Probe code/logs, fixture and SDK remain untracked and outside package
inputs. Independent second-pass review checked the native observations against
the recorded results; whitespace checks passed. No runtime layout, manifest,
tool version or persisted schema changed, so packaging was not required.

| Check | Result |
| --- | --- |
| Static Straight/Triplet timing and meter playback | Pending: LPB16/12, four lines per source step |
| Native sample glide and Surge XT PB | Pending current-layout alignment/playback checks |
| Add/rename/reorder/delete instrument while ACID remains open | Pending |
| Renoise instrument/phrase selection follows 1:1 without unintended writes | Partial; see [phrase destination check](acid_phrase_destination_manual.md) |
| Existing owned phrase regenerate in place; no added phrase | Passed in Renoise 3.5.4; phrase count stayed two |
| Target deleted, modified or foreign: no automatic append/overwrite | Pending |
| Explicit new phrase creates exactly one bound owned phrase | Passed in Renoise 3.5.4; created phrases 01 and 02 |
| Draft/source PB/timing/output settings survive switching and save/reopen | Pending |
| Live Edit context changes and stale asynchronous completion | Pending |
| One playback/transport smoke in Renoise | Passed; phrase preview produced output-meter activity |
