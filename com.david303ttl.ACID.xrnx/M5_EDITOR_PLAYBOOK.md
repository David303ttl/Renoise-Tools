# M5 Editor: End-to-End Execution Manual

**Authority:** This is the sole normative M5 implementation and acceptance
contract. `ROADMAP.md` records milestone scope/status and links here. M4.7
closeout evidence and limits remain historical and unchanged.

**Status:** Gates 0–12 PASS; M5 closed.

**Execution rule:** Follow the gates in order; Gates 1+2 are one atomic gate.
Stop at the first failed exit criterion. Do not implement later consumers against incomplete
source, schema, compiler, or runtime contracts. This is a documentation-only
rewrite; no runtime change is authorized by the act of updating this playbook.

## Reader Map

1. Read sections 1–4 for protected owners, audited current behavior, resolved
   decisions, and canonical data-flow contracts.
2. Read sections 5–9 for the UI, staging, audition, clipboard, duplicate, labels,
   transforms, and randomization contracts.
3. Execute section 11 in numeric order. Each gate owns a bounded change and a
   pass/fail decision; section 12 defines the final independent review.
4. Use section 10 for exact deterministic test owners, assertions, fixtures,
   and failure injection. Use section 13 only for host-side Renoise checks.
5. Put results in existing acceptance/test records. Record unexecuted checks as
   unverified; never convert a planned check into a pass claim.

## 1. Scope, Constraints, and Protected Owners

### 1.1 In scope

1. Replace the current coupled Program/Grid editor with the accepted shared
   shell, independent PITCH and TIME navigation, direct Grid editing, and staged
   Program sequential entry.
2. Add a non-destructive 12-bit pitch-class mask, strict source persistence,
   song-local friendly labels, session clipboard operations, exact duplicate,
   scoped transforms, and deterministic randomization.
3. Thread source/settings/label values through existing editor history, draft
   cache, request authorization, source association, planner, compiler, store,
   and phrase writer owners.
4. Keep Renoise phrase generation inside `writers.phrase_writer` and its existing
   transaction/materializer path. Keep semantic cycle interpretation in the
   existing model.
5. Add behavior-named tests only for previously unowned behavior. Update source
   factories and existing tests wherever the source contract changes.
6. Update affected documentation and existing manual procedures only after the
   implementation gates pass. Record actual native results and uncertainty.

### 1.2 Explicitly out of scope

1. TAP/time recording, playback-cursor recording, phrase queues, arrangement
   playback, global instrument/routing configuration, a second playback engine,
   a second source model, a second phrase writer, or a second source store.
2. Changes to M4.7 claims/limits, phrase seal grammar, manifest/API versions,
   frozen `DigitaktSampleChain`, or unrelated ARP behavior.
3. Broad GUI redesign, generic scrolling widgets, HTML mockups as runtime
   contracts, persistent clipboard, auto-migration, source recovery by guessing,
   and legacy UI fallback aliases.
4. Claims of actual sound, 120 ms guaranteed audition duration, or universal
   native playback correctness from Lua mocks.

### 1.3 Existing owner map

Extend these production owners. Add a private helper only when an existing
owner cannot reasonably host a cohesive pure operation; do not add a parallel
architecture or public compatibility facade.

| Responsibility | Existing owner | Required M5 extension |
| --- | --- | --- |
| Canonical source, fixed memories, validation, TIME normalization | `model.sequencer` | Add required mask fields, source operations, shared pitch resolution, validation/copy/equality. |
| NOTE/TIE/REST traversal and voice/event semantics | `model.cycle_interpreter` | Accept the resolved pitch values without independently quantizing or changing consumption semantics. |
| Physical gate timeline and successor association | `model.control_signals` | Pass the same resolved records through fallback compilation and successor verification; retain association checks. |
| Projection and decoded text | `model.editor_state.project`, `step_text` | Project exactly the source/resolution used by compilation and planning. |
| Output layout and capabilities | `model.output_planner`, `renoise.target_capabilities`, `writers.phrase_validator` | Consume the shared resolved event plan and preserve compatibility checks. |
| Source/output/label history | `model.editor_state` | One linear history, difference classification, label/custom snapshot, undo/redo/reset. |
| Widgets, navigation, edit admission | `gui.lua` | Shared shell, views, staged transaction controller, guards, clipboard and labels. |
| Song source/settings/label/draft serialization | `renoise.pattern_store` | Strict schema-2 codec, atomic candidate writes, new metadata fields. |
| Draft restore and revision tokens | `runtime.draft_cache` | Carry label/custom values and exact revision identity; preserve last-good source. |
| Request capture and stale checks | `runtime.requests`, `runtime.context` | Freeze all relevant values; include label metadata tokens where commit/clear depends on it. |
| Target observation/eligibility/integrity | `runtime.observers`, `runtime.transitions`, `runtime.integrity`, `runtime.eligibility`, `runtime.inventory` | Compare source association including mask; preserve blocked and recovery behavior. |
| ID ownership and phrase names | `renoise.phrase_ownership` | Preserve stable IDs and sealed names; display labels are never seals. |
| Phrase generation and transaction | `writers.phrase_writer`, `writers.phrase_materializer` | Remain sole production phrase writer; preserve preflight, verified postimage, rollback and ownership. |

## 2. Current-Code Audit Receipts

This is a starting inventory, not an exhaustive substitute for the Step 0
call-site search. Names below describe the current checkout at the time of this
rewrite. Re-read each owner before implementation because the code may change.

### 2.1 Canonical source facts

1. `model/sequencer.lua` currently declares `SOURCE_FIELDS` at line 9 with only
   `length`, `pitch_length`, `timing_mode`, `pitch_events`, and `time_events`.
2. `sequencer.new_pattern(length, ...)` currently creates 32 C/NORMAL pitches,
   32 NOTE commands, `pitch_length=16`, and straight timing. Add mask defaults in
   this factory; do not let callers patch missing fields after creation.
3. `sequencer.pitch_controls(p)` currently checks `note` against host range
   0..119, then validates key 0..12, octave -1..1, and the equation
   `note = 36 + key + 12*octave`. The source domain is therefore 24..60, not
   the host's wider scalar guard. Change the source guard to 24..60 and retain
   the equation. Do not mistake note 60 for unsupported merely because a
   12-key display has no thirteenth pitch-class button.
4. `sequencer.validate`, `copy_source`, and `same_source` are central contracts.
   Every new source field must be validated, detached, compared, and carried by
   all factories. No valid source may omit mask fields, even when masking is off.
5. `sequencer.set_time` enforces the active TIME bound and uses the shared
   `normalize_time_entry` leading-TIE normalizer. Keep `set_time` for direct UI
   edits; bulk All-32 operations use the same normalizer under section 8.4.12.

### 2.2 Compiler and resolved-pitch hazard

1. `model/cycle_interpreter.lua:run_cycle(pattern, state)` currently gets
   `pitch = pattern.pitch_events[cursor]`, and copies `pitch.note`, `pitch.key`,
   and `pitch.octave` into both the event and voice. This is internally
   consistent for raw source and must remain so for masked output.
2. Passing only a resolved MIDI integer vector to `event.note` while retaining
   raw `event.key` and `event.octave` creates an impossible event record. The
   resolved pitch representation must include canonical controls, or the shared
   resolution owner must produce canonical resolved pitch records.
3. The selected contract is: `sequencer.resolve_pitches(source)` returns a
   detached vector of 32 canonical resolved pitch records, each containing
   `note`, `key`, and `octave` consistent under the source equation, alongside
   the original raw source. A small source-local helper may canonicalize a MIDI
   value to controls. The resolution result is ephemeral and is not persisted.
4. `cycle_interpreter.compile_cycle(pattern, state, prepared)` and
   `compile_cycles(pattern, count, state, prepared)` take the prepared bundle
   defined in section 4.4 at internal call sites. Their contract is
   to validate raw source, validate exactly 32 dense resolved records against
   bounds and canonical controls (covering every active PITCH index), and read
   the vector only for NOTE pitch values. TIME command consumption,
   `pitch_index`, ACCENT/SLIDE ownership,
   transition state, voice lifecycle, and raw source remain unchanged.
5. One call chain resolves once per source snapshot and passes that same vector
   to decoded projection, cycle events, planning, materialization and source
   compatibility. No caller may call a second resolver on the result or
   independently quantize notes.
6. Keep raw key/octave and raw note available separately for display and source
   identity. An event/voice exposed as rendered output must have note/key/octave
   that all describe the same resolved pitch. Preserve raw index and flags.
7. The disabled-mask path must produce canonical resolved records for the
   original notes too; that avoids different compiler contracts depending on
   toggle state. It must not rewrite source controls when raw values use an
   equivalent boundary encoding.

Suggested internal contract, not a requirement to expose a new public module:

```lua
local prepared, err = sequencer.prepare_resolution(source)
-- prepared binds a frozen source to its resolved records and private provenance.
local plan, err = interpreter.compile_cycle(source, state, prepared)
local output, err = output_planner.plan(source, policy, pb_range, limits,
  capabilities, options, prepared)
```

Inspect actual planner entry points before wiring. The signature above is a
contract sketch, not permission to create duplicate planner APIs. Prefer one
cohesive internal call shape over optional positional arguments if that avoids
ambiguity; update all callers at the same atomic gate.

### 2.3 Existing UI and request evidence

1. `gui.lua:488–515` has `choose_pitch` and `choose_time`; both currently move
   the other memory's selection by interpreting the projection. Remove this
   coupling. `navigate_diagnostic` at lines 517–529 is the exception: it may
   intentionally move both coordinates only when one diagnostic names both.
2. Current widget IDs include
   `acid_program_pitch_position`, `acid_program_time_position`,
   `acid_program_key_popup`, `acid_program_octave_popup`, and
   `acid_grid_time_XX`. Remove those value-choice widgets/IDs when replaced.
   The literal `acid_grid_time_` ID is currently the per-cell TIME popup.
3. `gui.lua` constructs a separate `preview_grid` and adds one row per memory
   page in the current view. Remove permanently stacked per-cell preview; keep
   only bounded Decoded tab content.
4. Existing PITCH grid buttons use `acid_grid_pitch_XX`; retain the prefix only
   if it still names the same user-action role. Do not retain old dropdown IDs
   as hidden aliases or install duplicate notifiers for migration.
5. `runtime/requests.lua` currently freezes `VALUE_FIELDS` at lines 12–14.
   Current values include source/settings/baseline/planning inputs, not the
   future label/custom metadata token or duplicate intent. Extend detached
   snapshots and comparison only for explicit request kinds that require them.
6. `pattern_store.lua` currently has magic `ACID-PITCH-TIME-1`, SOURCE-style
   records, and DRAFT records without mask or labels. Its `decode`, `encode`,
   candidate preparation, commit and restore functions are the only store path.
7. `phrase_writer` already has create/regenerate transaction logic, ID allocation,
   candidate preparation, guarded commit, materializer, and rollback. Duplicate
   must be an explicit authorized create intent through this path, not a new
   writer or GUI phrase API call.

### 2.4 Baseline and receipts

1. The supplied audit reports that the current full ACID baseline had 70 passing
   specs. Treat this as an inherited audit receipt only; rerun tests at the
   implementation baseline and record actual count/output. Do not claim a new
   run from this document.
2. Existing focused owners include `acid_source_values_spec.lua`,
   `acid_editor_spec.lua`, `acid_pattern_store_codec_spec.lua`,
   `acid_store_candidate_spec.lua`, `acid_draft_cache_spec.lua`,
   `acid_draft_recovery_spec.lua`, `acid_runtime_request_spec.lua`,
   `acid_cycle_interpreter_spec.lua`, `acid_gui_views_spec.lua`,
   `acid_gui_independence_spec.lua`, `acid_gui_admission_spec.lua`,
   `acid_output_planner_spec.lua`, `acid_planner_association_spec.lua`,
   `acid_phrase_validator_spec.lua`, `acid_phrase_materializer_spec.lua`,
   `acid_phrase_persistence_spec.lua`, `acid_id_allocation_spec.lua`, and
   `acid_writer_transaction_identity_spec.lua`.
3. Search the repository for all factories, fixtures, generated source literals,
   and test builders before changing source. The above list is not exhaustive.
4. SDK references cited by the accepted design were pinned API 6.2 definitions:
   `definitions/library/renoise/song.lua` note on/off APIs and
   `definitions/library/renoise/tool.lua` timer APIs; corresponding offline
   docs are under `sdk/renoise-api-6.2/docs/API/`. The audited commit reference
   for official sources when local SDK docs are unavailable is
   `08faaea744156f2f7eddc898eb46fd972453a1af` in the API-6.2 repository.
   Verify signatures and restrictions at execution time. Do not infer timer
   precision or object lifetimes from API declarations.

## 3. Resolved Decision Registry

These are decisions, not questions for implementation to reopen. The only
unresolved evidence is host behavior explicitly assigned to native acceptance.

| ID | Fixed decision | Consequence |
| --- | --- | --- |
| D01 | Source mask fields are required in every source, enabled or disabled. | One strict source shape, no defaults during decode. |
| D02 | Source notes and resolved notes are limited to MIDI 24..60. | Host's 0..119 note guard cannot define source legality. |
| D03 | A resolved event's note/key/octave must agree. | Compiler takes canonical resolved pitch records, not a scalar vector combined with raw controls. |
| D04 | Mask and schema/history/render source flow cut over atomically. | No passing intermediate where old compiler sees mask source but no shared resolved plan. |
| D05 | LAST STEP shrink preserves TIME cursor/page and inactive data. | Inactive TIME selection remains inspectable; editing is unavailable. |
| D06 | Keyboard has twelve pitch-class keys and exactly three octave buttons. | MIDI 60 is explicitly reachable with a labeled C endpoint control/readout action, not an undocumented thirteenth class. |
| D07 | Stage is detached until one Finish edit. | No partial source writes, draft writes, history entries, or Live Edit while entering. |
| D08 | An incomplete stage cannot offer Finish. | Guard offers Discard / Stay only; neither Finish nor Discard automatically resumes the guarded action. |
| D09 | Clipboard carries only selected memory payload and its bound(s). | It never carries mask, timing, labels, output, IDs, ownership or target. |
| D10 | Duplicate intent is explicit and authorized through current runtime/writer. | It creates from verified committed source, not the editor's dirty draft. |
| D11 | Labels are song metadata, not source, output, or phrase seal. | Metadata-only edit does not increment revision or request generation. |
| D12 | Store accepts empty data as new store and only schema 2 as nonempty. | No schema-1 migration, fallback, reset offer, or destructive rewrite. |
| D13 | A candidate source-store commit fails closed on any changed raw store. | No invented merge of concurrent label/source changes; retain editor state/draft and report conflict. |
| D14 | Rename validates ownership and source association before metadata write. | Cannot use a label change to make a foreign or stale phrase appear owned. |
| D15 | UI dimensions are accepted by hierarchy and bounded controls, not by a promised exact pixel fit. | If 820 px native layout cannot fit, adjust widget widths while preserving hierarchy; no unapproved vertical accordion. |
| D16 | Native audition release is best effort when captured host objects disappear. | Never guess former indices or send note-off to replacement objects; report uncertainty. |
| D17 | Disabled all-false masks are valid; malformed masks never are. | Validation, codec, history and UI share the same distinction. |
| D18 | Completion means every staged target is entered. | Final-position Enter alone cannot enable Finish; equal-source Finish has no edit effects. |
| D19 | Reset preserves LAST STEP and label/custom, resetting other fields as section 8.1.13 specifies. | No conditional label policy or history reset. |
| D20 | All-32 TIME operations explicitly edit inactive storage through shared normalization. | Direct `set_time` keeps its active-bound restriction. |
| D21 | Duplicate derives its label before insertion and sets custom true. | No unreachable label fallback or post-capture relabeling. |

## 4. Canonical Source, Resolution, History, and Persistence

### 4.1 Source value

Canonical source has exactly these top-level fields:

| Field | Contract |
| --- | --- |
| `length` | LAST STEP integer 1..32. |
| `pitch_length` | Active PITCH span integer 1..32; all 32 entries remain stored. |
| `timing_mode` | `straight` or `triplet`. |
| `pitch_events` | Dense 32-element array. Each record has exactly `note`, `key`, `octave`, `accent`, `slide`. |
| `time_events` | Dense 32-element array of `N`, `T`, `R`; element 1 cannot be raw `T`. |
| `scale_mask_enabled` | Required boolean. |
| `scale_mask` | Required dense 12-element boolean array indexed C=1 through B=12. |

1. Default mask is twelve `true` values and disabled. The all-true default is
   explicit, deterministic, and harmless while disabled.
2. `sequencer.validate` rejects absent/unknown top-level keys, missing mask,
   sparse/extra mask slots, non-booleans, and invalid pitch records. A
   structurally malformed mask is invalid regardless of enable state. A dense
   twelve-element all-false mask is valid shape: accept it while disabled and
   reject it while enabled. Use these distinct terms in tests and diagnostics.
3. `copy_source`, equality, every editor history state, draft/cache record,
   request snapshot, store candidate, ownership source association and test
   fixture must include all mask fields.
4. Mask bits and enable state participate in raw source equality and ownership
   compatibility even when disabled. Labels do not participate in source
   equality.
5. `sequencer.new_pattern` owns required defaults. Do not add factory wrappers
   that repair incomplete values after construction.

### 4.2 Pitch control encoding and endpoint

1. Valid raw pitches satisfy `note = 36 + key + 12*octave` with note 24..60,
   key 0..12, and octave -1, 0, or +1.
2. New transformed notes use canonical encoding: for 24..59,
   `key = note % 12` and `octave = floor((note - 36) / 12)`; for note 60,
   `key=12`, `octave=1`.
3. There are twelve pitch-class buttons C through B. They never claim a thirteenth
   pitch class. Keep DOWN, NORMAL, UP as separate controls.
4. Add one visibly distinct `C+` endpoint action beside the selected-note
   readout, active when UP is the selected octave, which writes exactly note 60,
   key 12, octave +1 while preserving current ACCENT/SLIDE. The action must
   visibly identify C+ / MIDI 60. It is a value endpoint, not an extra key.
5. Grid PITCH cells show exact note, key and octave for note 60. Program's
   readout and the `C+` action make that value reachable and reversible without
   claiming it can be selected by one of the twelve ordinary pitch-class
   buttons. Selecting another key or octave after C+ performs the ordinary
   canonical button edit. Do not constrain randomization to 59 or silently
   change the accepted 24..60 range.

### 4.3 Pure shared scale resolution

1. Implement resolution under `model.sequencer` as one pure operation. Suggested
   contract: `resolve_pitches(source) -> resolved_records | nil, error`.
2. Validate source first. When mask is disabled, return canonical records for
   each unchanged raw note. Preserve raw source controls in source; the resolved
   record may use canonical equivalent controls for a boundary note.
3. When enabled, independently choose the allowed pitch in 24..60 having the
   smallest absolute distance from each raw note. At equal distance choose the
   lower MIDI note. Do not shift neighboring notes as a group.
4. Preserve source `accent` and `slide` by reading them from raw source when
   constructing cycle events; resolution owns only pitch value/controls.
5. All twelve pitch classes have candidates in 24..60. Enabled all-false mask
   is invalid and returns before preview, output plan, write, or destination
   mutation. Attempting to deselect the final class while enabled is rejected
   atomically; the prior mask remains visible and source unchanged.
6. Mask resolution, mask edits and mask enable/disable never rewrite raw pitch
   values. Save/load and Copy preserve them exactly. Explicit pitch edits,
   Clear, Randomize, Paste, Reset and undo/redo may change raw values according
   to their own contracts. Randomization generates raw notes without applying
   the mask; resolution is applied only to the resulting output view.
7. Required nearest-note vector for C-only mask, lower-tie rule:
   input `[30,35,37,42,59,60]` resolves to `[24,36,36,36,60,60]`.
   This includes ties 30 -> 24 and 42 -> 36.
8. Add per-pitch-class fixtures only if they are machine-readable and consumed
   by tests; preferred fixture names are `scale_mask_cases.json` and
   `randomization_vectors.json`. Do not create fixture files merely to duplicate
   inline cases.

### 4.4 Compiler and render thread

**Prepared resolution contract:** `sequencer.prepare_resolution(source)` owns
validation, source detachment and one call to the pure resolver. It returns a
bundle containing the frozen source and all 32 canonical resolved records,
plus factory-issued provenance retaining private copies of both. Consumers
receive the bundle, not an independently supplied vector. Before use, compare
both exposed values exactly to their private originals and compare any separately
supplied source by `same_source`; reject mismatch without quantizing again.
A caller-constructed bundle or replaced provenance rejects. Keep provenance
within the existing sequencer helper's private closure and bundle lifetime;
this is no global source cache, second model or persistent format.

Thread this bundle through projection, interpreter/loop calls, both planners,
control-signal successor verification and writer preparation. Retain the same
private provenance when request values are detached: plain source/records are
frozen value fields, provenance is a private identity field whose association
is checked at checkpoints. Never serialize it or accept provenance supplied by
the GUI. Release it with its request/projection lifetime. Public pure entry
points may prepare once when no bundle is supplied; nested consumers must pass
the prepared bundle onward. The vector wording below refers to its records.
The plain resolver remains a pure implementation helper, not a way to authorize
an arbitrary caller vector. Test source-only, vector-only, paired tampering,
forged provenance and stale bundle reuse after source or mask changes.

1. Keep `cycle_interpreter` as the only semantic NOTE/TIE/REST consumer. Its
   explicit resolved input must contain exactly 32 dense canonical records,
   covering every active PITCH index, and remain immutable for that compile.
2. On NOTE, event `note`, `key`, and `octave` all describe the resolved value.
   Event `pitch_index`, `accent`, and `slide` come from the unchanged raw source.
3. On TIE, the held voice copies its prior resolved note and matching controls;
   a TIE never resolves or consumes another PITCH. REST releases that same voice.
4. Start and Repeating projection both use the same `resolved_records` used by
   output planning. Preview must not resolve separately or mutate source.
5. Pass the exact vector into `output_planner` and downstream materialization.
   If planner calls the interpreter internally, pass it through there; do not
   regenerate a semantically different vector at a deeper layer.
6. Keep phrase ownership comparison on raw source + output policy + PB range,
   including both mask fields. Render output may differ due to mask but must
   correspond to that exact raw source and settings tuple.
7. No mask-specific branch may alter NOTE count, pitch cursor wrap, TIE/REST
   semantics, cycle state, articulation transition, or event order.
8. Thread this vector through `compile_cycle`, `compile_cycles`, `plan_loop`,
   `output_planner.plan_output`, both public/private planner entry points, and
   `control_signals.compile`. The latter recompiles a successor to validate
   association even when a plan is supplied; that validation must use the same
   resolved values. Its fallback cold/successor compiles follow the same rule.
   Never remove successor validation to make masked output pass.
9. A top-level pure call without a prepared bundle may prepare once and pass
   it through every nested call. A prepared call must not resolve again. The
   source snapshot owner shares the prepared bundle with projection and render request
   preparation; frozen request copies preserve exact values, not Lua table
   identity across detachment. Define this owner during Gate 0 and implement
   it in Gates 1+2. No global cache or permissive raw-output fallback is allowed.
10. Reject malformed supplied vectors before planning. Internal callers may
    supply only vectors prepared for their exact immutable source snapshot;
    accepting any structurally valid vector as authorization is forbidden.
    Test source/vector association after mask and raw-note changes, and caller
    mutation after capture. Do not add a second quantizer for validation.

### 4.5 One linear history and difference classes

**Transactional history:** `new_history` must support inspecting a proposed
Undo/Redo state without moving its cursor. Capture the current cursor/history
revision and detached destination state, classify the difference, then admit
the action. For label-only transitions, persist and verify metadata first;
commit the proposed cursor only if its captured history revision still matches.
Failure leaves both accepted state and cursor unchanged. Retry an Undo/Redo
proposal as that same cursor transition after fresh validation, never as a new
rename history entry. Discard removes the proposal only. Musical/mixed actions
retain the ordinary accepted-local-edit behavior on draft persistence failure.
Do not implement temporary cursor movement followed by compensating undo.

`runtime.context` owns an explicit metadata-only transition: validate current
binding, publish the metadata candidate, then update editor metadata/history
and a separate metadata revision. It does not advance musical edit revision,
invalidate a musical projection, schedule Live Edit or call `changed()`.
Requests which publish/clear metadata capture that metadata revision as well
as existing musical/target/session revisions. A stale metadata revision rejects
their publication; it never authorizes clearing a newer draft.

1. Extend `model.editor_state.new_history` snapshots with canonical source,
   output policy, PB range, `label`, and `label_custom`. Keep a single history
   list and one cursor.
2. `same_state` compares source, output settings and label metadata. A transition
   is classified as `musical_or_output`, `label_only`, or `mixed` by exact
   comparisons; classification is not a second history.
3. Source, timing, mask, output policy, PB, paste, duplicate-loaded state,
   transforms and completed staging are ordinary edits. One logical operation
   creates no more than one state and calls existing `changed()` once.
4. Label-only undo/redo persists metadata but does not set musical source dirty,
   call `changed()`, request Live Edit, increment phrase revision, or regenerate.
5. Mixed label+source transition uses one normal edit request and attempts to
   persist both atomically. If persistence fails, retain the accepted local
   source+label edit as one history state and preserve it in the session draft;
   show an unsaved-draft warning and block target switch. Do not claim durability.
   Undo/redo continues over this accepted local state. Label-only failure follows
   its separate attempted-field rule in section 8.1 and does not advance history.
6. View, tab, page, selection, preview cycle, cursor, stage cursor, and diagnostic
   navigation are not history. Undo/redo returns deep copies of every field.
7. Reset is explicit: musical defaults plus mask defaults and label behavior
   are defined in section 8. A changed Reset is one undoable action. Do not conflate
   Reset Pattern, Clear Memory, New Phrase, and metadata rename.

### 4.6 Schema 2 and strict store behavior

1. Replace magic with `ACID-PITCH-TIME-2`. Empty/absent `tool_data` constructs an
   empty schema-2 store. Every nonempty other magic is a read-only failure.
2. No schema-1 decoder, migration, default mask, legacy alias, repair, reset,
   import, or partial rewrite exists. Preserve unrelated bytes on every reject.
3. Store SOURCE and LABEL records are one-to-one by stable positive ACID ID.
   Equal label text across different IDs is valid. Duplicate ID, orphan label,
   missing label, malformed order, or duplicate label for an ID rejects.
4. Store source record contains output policy, PB range, timing, pitch span,
   LAST STEP, mask enable, exactly 12 mask bits, 32 pitch records and 32 TIME
   commands. Store DRAFT contains instrument/phrase target, encoded instrument
   name, pending label, `label_custom`, output policy, PB, all source fields.
5. New target has phrase ID zero and no SOURCE ID; its pending label lives in
   its DRAFT only. A committed source has exactly one LABEL record.
6. Keep deterministic strict ASCII encoding, newline terminator, numeric SOURCE
   and LABEL ID sorting, deterministic DRAFT sorting by instrument and stable
   phrase ID, record-class ordering SOURCE then LABEL then DRAFT, uppercase hex,
   exact field counts, no blanks/CRLF/trailing bytes. Preserve current stable
   IDs and seal grammar.
7. LABEL wire format must store label and custom bit so committed restore
   recovers `label_custom` exactly. Use a stable explicit format, for example
   `LABEL|ID|LABELCUSTOM|HEXLABEL`; update the grammar and tests as one codec
   change. Do not retain a format that cannot restore this bit.
8. Candidate updates compare exact raw storage captured at preparation with the
   current raw value before assignment. Any intervening source, label, or draft
   change invalidates the candidate; do not merge by guessing which record was
   concurrently edited. Preserve current store bytes and editor/draft values.
9. If a setter may mutate then throw, inspect raw value and verify whether
   candidate bytes were applied. Roll back only if current bytes equal the exact
   candidate written by this transaction. If current bytes differ from both
   captured old bytes and candidate bytes, preserve them and block rather than
   overwriting newer data.
10. Source/label candidate, commit, status, and restore remain in
    `renoise.pattern_store`. Draft candidate comparisons include exact draft
    value plus session token/revision so an A -> B -> A value cannot clear a
    newer draft.

Canonical record grammar to implement (the field layout is normative; exact
helper names may follow existing codec conventions):

```text
STORE       = "ACID-PITCH-TIME-2" LF *SOURCE *LABEL *DRAFT
SOURCE      = ID "|" POLICY "|" PB "|" TIMING "|" PITCHLEN "|" LAST
              "|" MASKON "|" MASK "|" PITCHES "|" TIMES LF
LABEL       = "LABEL|" ID "|" LABELCUSTOM "|" HEXLABEL LF
DRAFT       = "DRAFT|" INSTRUMENT "|" PHRASE_ID "|" HEXNAME "|" HEXLABEL
              "|" LABELCUSTOM "|" POLICY "|" PB "|" TIMING "|" PITCHLEN
              "|" LAST "|" MASKON "|" MASK "|" PITCHES "|" TIMES LF
MASK        = 12 * ("0" / "1")
MASKON      = "0" / "1"
PITCH       = NOTE ":" KEY ":" OCTAVE ":" ACCENT SLIDE
ACCENT      = "0" / "1"
SLIDE       = "0" / "1"
PITCHES     = PITCH *("," PITCH)                 ; exactly 32
TIMES       = 32 * ("N" / "T" / "R")
LABELCUSTOM = "0" / "1"
```

`HEXLABEL` decodes to 1–32 ASCII bytes matching
`^[A-Za-z0-9][A-Za-z0-9 _.-]{0,31}$`. No trim, substitution or partial save.
`HEXNAME` keeps existing draft-name encoding. Keep integer grammar and existing
policy/PB/ID bounds strict. Preserve exact source invariant `note=36+key+12*octave`.
ACCENT and SLIDE are adjacent single digits: `(36,0,0,false,true)` encodes as
`36:0:0:01`, with no separator between flags. The label grammar above is
descriptive regex notation, not a Lua pattern: implement an explicit byte-length
check and Lua-5.1-compatible ASCII character checks; do not use `{0,31}` as a
Lua repetition operator. Test every punctuation byte and reject control bytes.

## 5. Shared Editor Shell and View Contracts

### 5.1 Hierarchy and bounded native layout

Keep this order in both Program and Grid:

1. Target instrument and destination phrase.
2. LAST STEP, Timing, active PITCH span.
3. Program/Grid selector, Undo and Redo.
4. Selected editor view.
5. One fixed-height lower workspace with tabs: Decoded, Pattern / Copy,
   Extended / Clear, Output, Recovery.
6. Live Edit, Generate/Regenerate, persistent source/result status outside tabs.

1. Existing GUI has 820-wide lower controls. Preserve a comparable native
   window baseline and the accepted hierarchy; the exact prior widths do not
   prove all controls fit. Fit two rows of eight cells per memory by reducing
   cell widths as needed, keeping labels readable and controls usable.
2. If normal native resolution cannot fit the agreed fixed workspace, fail the
   GUI gate and adjust widths/spacing while preserving hierarchy. Do not solve
   it with a generic scroll view, a vertical accordion, permanently stacked
   previews, or hidden controls.
3. Use fixed-size controls. API 6.2 does not define a generic scrolling
   container. `MultiLineText` has its own scrollbar when text exceeds the view;
   use it for bounded textual detail, not structured cell grids.
4. Decoded shows at most four TIME rows at once with explicit previous/next
   page controls. Recovery text shows at most 16 visible lines with explicit
   paging. Randomization parameters remain inline in Extended / Clear.
5. Release any active audition before opening a focused dialog, confirmation,
   navigation that changes audition context, or closing the editor.

### 5.2 Independent navigation and LAST STEP

1. Both views share the same canonical source. PITCH and TIME have independent
   selected positions and independent 01–16 / 17–32 pages.
2. `choose_pitch(index)` updates only PITCH selection/page and view state.
   `choose_time(index)` updates only TIME selection/page and view state. Neither
   infers the other cursor from projection.
3. Diagnostic jump may select PITCH and TIME together only when the diagnostic
   explicitly includes both coordinates. Otherwise it moves only the named
   coordinate.
4. Selecting page/cell/cursor, switching tab/view, or changing preview cycle
   never mutates source, adds history, saves a musical edit, or asks Live Edit
   to render.
5. LAST STEP shrink does not clamp TIME cursor or page. If selected TIME is now
   greater than `length`, keep it visible and labeled `OUTSIDE LAST STEP`; allow
   read-only inspection of its retained command; disable its edit control.
6. PITCH all 32 stored values remain editable regardless of active PITCH span.
   Span changes consumption only, not storage availability.
7. Time cell selection is read-only. Shared NOTE/TIE/REST assignment controls
   perform the one edit at the selected TIME coordinate and stay there.

### 5.3 Grid

1. Render two rows of eight PITCH cells and two rows of eight TIME cells for
   the selected memory page. Each memory has independent page controls.
2. PITCH cells display position, raw key/octave and flags, selected state,
   active-span dimming, and enough note text to distinguish endpoint MIDI 60.
   Span dimming is descriptive only; it is not a statement that a value is
   absent or cannot be edited.
3. TIME cells display position and N/T/R. Selecting a TIME cell does not edit.
   Shared assignment buttons set it via `sequencer.set_time`.
4. Remove per-cell TIME popups and every `acid_grid_time_XX` ID. Their former
   assignment action differs from the new selection-only buttons. Give those
   buttons behavior-specific IDs such as `acid_grid_select_time_XX`, update
   tests, and retain no invisible compatibility widgets or duplicate notifiers.
5. While Program staging is active, Grid may be selected without losing stage.
   Grid displays canonical committed/draft source values only, shows a clear
   “Program entry staged; return to Program to finish or discard” banner, and
   disables source-edit controls. Never render staged PITCH values as if they
   were raw Grid source.

### 5.4 Program

**Edit One means direct editing, not a second buffer or commit button.** It is
the ordinary Program mode outside sequential entry; show it as a mode/readout.
Selecting it during a stage invokes the stage guard. The candidate exists only
for explicit Re-enter. Selecting a PITCH/TIME position establishes that memory's
independent coordinate; pitch controls always address PITCH and N/T/R always
address TIME, regardless of the last control focused.

| Action | Ordinary Edit One | PITCH stage | TIME stage |
| --- | --- | --- | --- |
| Position/page selection | Navigation only | Navigate candidate targets; no marker change | Navigate candidate targets; no marker change |
| Key/octave/flags/C+ | One immediate canonical edit if changed | Change current PITCH candidate; clear its marker if changed | Disabled |
| N/T/R | One immediate canonical TIME edit if active | Disabled | Change current TIME candidate; clear its marker if changed |
| Enter and Advance | Disabled | Mark/advance only | Mark/advance only |
| Finish | Unavailable | One changed edit or equal-source no-op | One changed edit or equal-source no-op |

Always display exact raw `note`, `key`, and `octave`, including alternate
encodings such as `(48,12,0)` and `(36,12,-1)`. A twelve-key highlight represents
the resolved pitch class only and is labeled as such; it must not imply that
raw key 12 is key 0 at the displayed raw octave. Navigation preserves all raw
controls. A key edit combines the chosen class with the displayed raw octave;
an octave edit combines the selected note's pitch class with the chosen octave.
Encode the resulting edited note canonically, preserving flags. C+ explicitly
selects 60. Test alternate encodings before navigation and after genuine edits.

1. Provide independent numbered PITCH and TIME selectors/readouts, two pages,
   Edit One, Re-enter PITCH, Re-enter TIME, Check, Audition, Back and
   Enter and Advance. Use these exact action names; there is no Next alias.
2. Replace PITCH/TIME position dropdowns with numbered position buttons or
   readouts plus explicit navigation. Replace key/octave dropdowns with a
   twelve-key chromatic keyboard, separate DOWN/NORMAL/UP controls, ACCENT and
   SLIDE controls. Keep sharps legible and selected state unmistakable.
3. Expose TIME command editing through NOTE/TIE/REST buttons; do not use a
   selected cell as an implicit edit.
4. Edit One changes exactly the selected raw pitch or TIME command. PITCH edit
   preserves TIME, unrelated PITCH entries, both bounds, timing, mask, output,
   label and unrelated flags. TIME edit preserves PITCH flags and all unrelated
   source fields. TIME step outside LAST STEP has no edit path.
5. Ordinary key/octave/flag change clears the entered marker for that position
   only if a stage is active and that position changed. Outside staging it is a
   regular one-edit operation.
6. Check is a read-only diagnostic action owned by `gui.lua` using
   `editor_state.project` and its shared resolved snapshot. Outside staging it
   checks canonical source. During staging it checks the detached candidate,
   reports missing entered positions separately, and cannot mark, finish,
   persist or generate a phrase from it. It shows the projection's diagnostic;
   missing entered positions are listed in ascending target order. A diagnostic
   without coordinates remains a message.
   Coordinate navigation uses the existing diagnostic-jump rule, restricted
   to the staged memory's target positions while staging. Check success reports
   source validity, never native playback validity or stage completion.
7. Back and Enter and Advance are stage-only and disabled outside staging.
   Ordinary navigation uses the independent numbered selectors and page
   controls. During staging only the staged memory's in-scope value controls
   edit the candidate; other memory and out-of-scope values are read-only.
   Re-enter either memory while a stage exists uses the stage guard and requires
   a fresh invocation after Finish/Discard. Rename is also a guarded action.

## 6. Sequential Entry as a Detached Transaction

### 6.1 Stage state and initialization

Represent staging as a private GUI/session value. It is not canonical source,
history state, draft-cache state, or a runtime request.

```text
stage = {
  memory = "pitch" | "time",
  candidate = detached full canonical source,
  target_positions = ordered in-scope integer list,
  entered = boolean array keyed by source position,
  cursor = current target position,
  complete = boolean,
  captured_editor_revision = current revision token
}
```

Also capture `song`, document epoch, session, target revision, operation serial,
exact instrument/phrase objects, target kind and owned ID (or explicit New
binding). These are stage-origin identities, not cached numeric indices. Every
candidate action and Finish revalidates that origin and edit revision before
using it; a stale stage has no commit authority.

1. Re-enter first releases audition. Then show confirmation with memory name,
   exact positions, initialization values, flags and out-of-scope preservation.
2. Confirmation cancel leaves stage/source/history/draft/target unchanged.
   Confirmation proceed deep-copies the complete source and captures current
   editor revision. A stale editor revision aborts Finish rather than overwrites
   newer state.
3. Re-enter PITCH targets exactly 1..`pitch_length`. Initialize each candidate
   target to canonical C/NORMAL, ACCENT=false, SLIDE=false. Positions beyond
   active span remain byte-equivalent.
4. Re-enter TIME targets exactly 1..`length`. Initialize candidates to NOTE.
   Stored TIME entries beyond LAST STEP remain byte-equivalent.
5. Initialize all target `entered` markers false, cursor to 1, complete false.
   The stage UI visibly distinguishes candidate from canonical source.

### 6.2 Transition rules

1. Editing a staged pitch/command modifies only that position in the detached
   candidate. It does not call `changed`, history, draft save, runtime request,
   writer, or persistence.
2. Any actual value/flag change at a staged position sets only that position's
   `entered` marker false and stage `complete=false`. A no-change control event
   does not clear the marker.
3. Enter and Advance marks current position entered. It advances to the next
   target unless current position is final. At final position it marks entered
   and leaves cursor there. After any marker change, derive `complete` as the
   conjunction of all target markers. Visiting the final position and entering
   it cannot complete a stage with missing earlier positions. Never maintain
   an independently authoritative completion flag.
4. Back moves one target position, stopping at first. It never edits values,
   markers, or completion.
5. Restart Cursor sets cursor to first target. It preserves candidate values
   and every entered marker; it does not restart initialization.
6. Position selector can visit any in-scope position. It never commits, resets,
   reinitializes, or clears markers.
7. Finish is disabled unless every in-scope marker is true. On Finish, revalidate
   captured editor revision, target/source validity and candidate via shared
   validator. If changed, apply the entire canonical source as one edit, one history entry,
   one ordinary `changed()` call and one draft/Live Edit path. Clear stage only
   after that action is accepted. If persistence fails, follow the existing
   source-draft failure contract and retain recoverable editor state.
8. Cancel/Discard destroys only the stage. Canonical source and history remain
   unchanged. Clear stage state only after user confirms discard where dialog
   semantics require confirmation.
9. Switching Program/Grid preserves stage, cursor, candidate and markers.
   Grid's disabled stage banner and canonical values are mandatory.
10. Page/cursor/view navigation is read-only and cannot prompt to finish or
    discard. Do not overload navigation as a mutation boundary.
11. If a fully entered candidate equals canonical source, Finish closes the
    stage with no history, draft save, revision or Live Edit request. A changed
    candidate follows item 7. Failed revision/validation checks retain the stage
    and report the reason; they never overwrite newer canonical state.

### 6.3 Stage guard matrix

Before any guarded command, release audition and show the pending-stage decision.
When every stage position is entered, the available decisions are **Finish**,
**Discard**, and **Stay**. If any position is incomplete, Finish is disabled or
absent and the guard offers **Discard** and **Stay** only, with the missing
positions identified. Stay changes nothing, including the pending action, stage
state, selection, source, history, target, and focus as far as native focus
permits. The guarded action is never queued or retained: Finish commits only the
stage and Discard drops only the stage. Either choice abandons the guarded action;
the user must invoke it again after the guard returns.

Here, guarded source/settings edits mean changes to canonical editor state.
Editing the current stage's in-scope candidate through section 6.2 does not
invoke this guard. Check and permitted PITCH-stage Audition are read-only
stage actions; they do not Finish or Discard. Canonical edits must not be
misrouted into the candidate to bypass a guard.

| Guarded action | Finish path | Discard path | Stay path |
| --- | --- | --- | --- |
| Undo / Redo | If complete, commit stage only; abandon Undo/Redo. If incomplete, unavailable. | Drop stage only; abandon Undo/Redo. | No-op. |
| Reset / source or output setting edit | If complete, commit stage only; abandon the requested edit. If incomplete, unavailable. | Drop stage only; abandon the requested edit. | No-op. |
| Rename / Re-enter either memory | If complete, commit stage only; abandon the requested action. If incomplete, unavailable. | Drop stage only; abandon the requested action. | No-op. |
| Copy / Paste / Duplicate | If complete, commit stage only; abandon the operation. If incomplete, unavailable. | Drop stage only; abandon the operation. | No-op. |
| Extended operation / mask edit | If complete, commit stage only; abandon the operation. If incomplete, unavailable. | Drop stage only; abandon the operation. | No-op. |
| Generate / Regenerate / Live Edit toggle | If complete, commit stage only; abandon request/toggle. If incomplete, unavailable. | Drop stage only; abandon request/toggle. | No-op. |
| Target switch / phrase selection | If complete, commit and save under current target only; abandon switch. If incomplete, unavailable. | Drop stage only; abandon switch. | No-op. |
| Dialog close / tool unload | Do not silently commit. Drop transient stage; preserve prior canonical source/draft best effort. | Same discard behavior. | Not applicable after teardown begins. |
| View/tab/page/cursor navigation | Not guarded; preserve stage. | Not guarded; preserve stage. | Navigation executes read-only. |

1. Guards must be centralized around the action admission path, not duplicated
   ad hoc in every widget. Ensure programmatic state refresh does not trigger a
   second guard or edit.
2. An incomplete stage has no Finish action. Return an actionable reason naming
   missing positions. Do not allow a programmatic guard answer to bypass the
   disabled/absent Finish choice.
3. Finish and Discard both abandon the guarded command. Neither queues, retains,
   or automatically dispatches it. Finish applies only the stage; Discard drops
   only the stage. The user invokes the original command again, at which point
   the ordinary admission check runs on the resulting canonical source.
4. Generate and Live Edit must not consume a staged candidate implicitly. The
   only candidate-to-source transition is explicit Finish.
5. External song/document teardown discards the transient candidate without a
   modal prompt. Preserve canonical draft best effort under existing release
   rules; report volatile loss only if canonical draft persistence fails.
6. A view switch while staging never shows staged values in Grid and never
   commits or cancels.

### 6.4 R02 flag rule and TIME normalization

**External host changes are not interceptable GUI commands.** ACID selectors
use the pre-action guard. Native selection notifications, deletion/ownership
loss and document events are observed after the host has changed; never offer
Finish against their new target or try to reverse native selection implicitly.
On an external target/binding change, invalidate and discard the transient stage,
release audition, preserve the origin's canonical draft through the existing
draft lifecycle, then reconcile the host target. Report that uncommitted entry
was discarded. If origin draft persistence fails, retain it in the existing
session recovery state and report the failure; do not claim the native switch
was prevented. Target invalidation also disables edits until ordinary runtime
eligibility succeeds. Document/session teardown discards without a modal and
uses existing best-effort canonical draft preservation. Reorder/rename which
preserves origin identity follows runtime revision validity; never infer
identity from an index. Test complete and incomplete stages for all these paths.

1. PITCH re-entry clears ACCENT and SLIDE only in its explicit target span.
2. TIME re-entry never changes PITCH values or flags.
3. Edit One and every ordinary source edit preserve unrelated flags.
4. TIME 01 TIE is normalized to NOTE through `sequencer.set_time` and the UI
   reports the normalization. Raw source and schema reject leading TIE.

## 7. Audition Lifecycle and Native API Contract

### 7.1 Request and identity

1. Audition is a separate explicit action and does not change editor selection,
   source, phrase, settings, routing, or history.
2. Use API-6.2 GUI-thread calls only. Do not call note APIs from asynchronous
   workers. Preview resolved note, not raw note, when mask is active.
   Outside staging audition the selected canonical PITCH position. During a
   PITCH stage audition its current candidate position without marking it;
   during a TIME stage audition is disabled. Resolve the detached candidate
   through the same resolver without publishing it to canonical projection,
   draft or request state. The resolved vector is shared within this audition
   snapshot only; it cannot authorize phrase generation.
3. Before onset, capture current song, instrument object and selected track
   object. Verify instrument membership in that song and verify the track is a
   valid non-send track in the same song.
4. Immediately before each indexed host API call, resolve fresh instrument and
   track indices from the captured objects and confirm object membership again.
   Never retain an index as identity or use a stale index after a list change.
5. Use the same object tuple for onset and release. Preview volume is 0.8.
6. Verify pinned API-6.2 signatures in local definitions/docs before edits. If
   unavailable, use the pinned official API-6.2 source commit cited in section
   2. Do not substitute current online docs for versioned definitions.

### 7.2 Timer, release, and failure behavior

1. Request a nominal 120 ms one-shot timer with `renoise.tool():add_timer`.
   Timer callback runs from tool idle, interval varies with workload, and modal
   dialogs suppress callbacks. 120 ms is not a guaranteed duration.
2. Timer callback removes its timer identity before completing, and attempts
   release exactly once. Keep a lifecycle object with captured song/instrument/
   track objects, fresh resolved indices only for the immediate API call, timer
   identity and onset/release outcome.
3. Release before every modal/focused dialog, target/page or audition-context
   navigation, second audition, dialog close, song change, captured instrument
   or track removal, and tool unload.
4. For note-off, require captured song still current and exact captured
   instrument/track objects still members. Resolve fresh indices. Never call
   note-off on a different object occupying the old numeric index.
5. If captured object was removed, do not guess or send note-off elsewhere.
   Record a release failure and state that cleanup is best effort; no stuck-note
   guarantee is possible after host object removal.
6. If onset raises after invocation, attempt note-off only if the exact captured
   tuple can still be resolved. Preserve both onset and cleanup outcomes.
7. Observer registration and timer cleanup must be detached on every terminal
   path. Track identity must be revalidated; a track rename is not identity
   replacement. Avoid callbacks retaining stale document references after
   teardown.
8. Mock tests prove control flow and call tuples only. Native sound, duration,
   instrument response, modal suppression and removal behavior remain host
   acceptance items.

## 8. Labels, Clipboard, Duplicate, Clear, and Randomize

### 8.1 Labels and metadata writes

1. Label grammar is 1–32 ASCII bytes matching
   `^[A-Za-z0-9][A-Za-z0-9 _.-]{0,31}$`. Reject invalid input exactly; no trim,
   replacement, truncation or partial write.
2. New Phrase draft starts with label `Untitled`, `label_custom=false`. User
   typing any valid label, including literal `Untitled`, sets custom true.
3. On first successful commit, use `Pattern <ID>` only if custom=false. Otherwise
   preserve the explicit custom label. Existing committed source gets default
   `Pattern <ID>` when created.
4. Labels are not unique. Stable source ID is unique and one-to-one with SOURCE
   and LABEL records. Never put label text into phrase seal/name.
5. Rename follows this exact order: (a) validate label grammar; (b) validate
    current song/instrument/phrase identity and source/output compatibility;
    (c) capture current raw tool data and exact matching draft token/revision;
   (d) construct one store candidate updating committed LABEL and the matching
   target draft's pending label/custom bit, or only the New Phrase draft when
   stable ID is absent; (e) compare exact captured raw bytes; (f) assign and
    verify once; (g) only then accept metadata history state. Keep the accepted
    editor label/history cursor separate from the editable text field until this
    transaction succeeds.
6. Label-only rename on a dirty musical draft preserves the committed SOURCE
   and output fields, and updates the pending draft label without replacing its
   dirty source/settings. Do not persist the editor draft's musical values as
   committed merely because label changed.
7. Label-only undo/redo changes only label metadata and the same history cursor;
   no `changed()`, no Live Edit, no source dirtying, no phrase revision. A
   successful mixed source+label transition persists atomically and calls the
   normal edit path once.
8. On a label-only persistence failure, do not accept the attempted label into
   canonical editor state or history. Leave the previous accepted label and
   history cursor unchanged. The attempted text may remain visible in the focused
   label field with an explicit save error, but it is not canonical, is not a
   draft value, and must not be reported as persisted. Provide explicit Retry
   and Discard Attempt controls. Retry revalidates ownership, source association,
   exact raw store bytes, and current draft token/revision from the beginning.
   If a setter may have partially applied the candidate, inspect exact raw bytes.
   Restore the captured bytes only when current bytes equal this label attempt's
   exact candidate; verify the restore. If readback/restore is uncertain or
   current bytes contain a third value, preserve those bytes, mark metadata
   persistence outcome unknown, set the existing integrity blocker, and block
   further writes. Do not overwrite newer data or silently accept the attempted
   label.
9. While an attempted label is unresolved, block Undo/Redo, target switch,
   phrase selection, and other action that would replace the field's target or
   make its intent ambiguous. Discard Attempt restores the previously accepted
   label and removes this editor-field block; the user invokes the previously
   blocked action again. It does not clear a separate store-integrity blocker.
   If persistence outcome is unknown, Retry and writes remain blocked until the
   existing integrity/revalidation path proves safe storage state. Successful
   Retry of a rename accepts one label-only history state; Retry of Undo/Redo
   commits its proposed cursor as specified in section 4.5. Neither auto-runs a blocked
   action. Undo always applies to the previous accepted history state, never to
   the failed attempted text.
10. On a mixed musical+label persistence failure, retain the real musical edit
    and label together in canonical editor state/history as one normal edit;
    retain the dirty source/label in the session draft and show the existing
    unsaved-draft warning. Do not claim the label or source was durably saved.
    Block target switching under existing dirty-draft protection. This is not a
    failed label-only attempt: the musical edit remains accepted and undoable.
11. A failed metadata publication never discards an unrelated dirty musical
    draft. Label-only failure does not overwrite its source/output; mixed failure
    preserves both edited source and label locally for recovery.
12. New Phrase with no stable ID stores pending label in DRAFT only. It must not
    fabricate a SOURCE ID before writer succeeds.
13. Reset Pattern preserves current LAST STEP, label and `label_custom`. It
    resets all 32 PITCH records to C/NORMAL with both flags false, all 32 TIME
    commands to NOTE, PITCH span to 16, timing to straight, mask to disabled
    with twelve true bits, and output policy/PB range to existing defaults from
    `model.policies`. This preserves the current reset bound/settings behavior
    while fixing the new metadata policy. It is one ordinary undoable edit,
    or a no-op if every resulting value already matches. Apply immediately in
    Program and Grid without confirmation. Reset does not rename or reset history.
    Clear PITCH/TIME uses section 8.4 and never resets label or output settings.

### 8.2 Session clipboard

1. Clipboard is in-memory, session-lifetime only, detached and deep-copied. It
   survives phrase selection while editor session lives; it is not song data or
   OS clipboard. Drop it when editor session terminates.
2. PITCH payload is exactly 32 complete pitch records plus `pitch_length`.
   TIME payload is exactly 32 TIME commands plus `length`. Both is exactly both
   payloads. No extra keys.
3. Exclude timing mode, mask enable/bits, label/custom, output policy, PB range,
   source ID, phrase/target identity, ownership/seal, draft revision and runtime
   references.
4. Pure seams: `make_clipboard(source, scope) -> detached_payload` and
   `paste_candidate(source, payload, scope) -> detached_candidate | error`.
   `paste_candidate` validates exact payload key set, dense lengths, nested
   fields, booleans, pitch equations, bounds and leading-TIE rules before
   returning any candidate. Reject malformed/extra/corrupted payload atomically.
5. Copy performs no history, store, draft, writer, request, or phrase creation.
   Empty/mismatched scope disables Paste and reports exact captured scope/bounds.
6. Paste preserves excluded current target fields and changes only matching
   payload fields. It is one ordinary undoable source edit and one normal
   `changed()`/draft/Live Edit admission. No-change paste is a no-op.
7. Paste to an explicitly armed New Phrase may use the existing real-edit
   create path if policy admits it. Do not state that Paste can never create a
   phrase; the invariant is that clipboard copy/selection alone cannot create,
   and Paste cannot bypass ordinary authorized target/request/writer checks.
8. Stage guard runs before Copy/Paste. Copy after Finish captures canonical
   post-Finish source. Discard uses canonical pre-stage source.

### 8.3 Duplicate committed phrase

1. Duplicate action requires a committed ACID-owned source. First complete the
   dirty-draft durability precondition in item 5; only after exact readback
    succeeds capture authorization. Retain the exact original song, instrument
    and phrase objects, stable source ID, exact phrase seal/name, detached
    committed source, output policy/PB range, complete verified phrase baseline,
    and committed label plus `label_custom`. Capture exact raw source-store bytes
    and its source/label record values. These values authorize a new create; the
    New destination alone does not prove the original source.
2. Validate captured authorization at four boundaries: request capture;
   immediately before the first native phrase mutation/insertion; immediately
   before source-store candidate commit; and final postimage/source association
   verification before reporting success or changing UI selection. At request
   capture, pre-native mutation and pre-store commit, require current song and
   exact original instrument/phrase object identity, stable ID, exact seal/name,
   committed source/settings, label/custom snapshot, unique ID ownership, phrase
   baseline/output compatibility, and exact captured raw store bytes/source/
   label records. At final verification, require the original live identities,
   ID/seal, committed phrase/source/settings, original label/custom and ownership
   still match; require store bytes to equal this transaction's exact verified
   candidate, with original source and label records unchanged, the previously
   saved draft unchanged, and only the authorized new source/label records added.
   Never compare final bytes to pre-commit raw bytes after this transaction has
   intentionally committed its candidate.
3. A missing, duplicate, renamed/resealed, manually modified or no-longer-owned
   original, a changed committed source/settings/label, or changed captured
   store bytes aborts before native mutation when detected at preflight. If a
   change is detected after native mutation, cancel commit and use the existing
   writer transaction to roll back only its own new phrase and exact store
   candidate. If exact rollback cannot be verified, retain recovery evidence and
   block; never overwrite the changed source/store or guess the original target.
4. A committed label/custom change between capture and any boundary invalidates
   this duplicate authorization even though labels do not affect musical source
   equality. Do not silently recompute the duplicate label from newer metadata;
   cancel and require a fresh explicit Duplicate action.
5. If editor has a dirty musical draft, perform the existing durable draft save
   and verify exact stored bytes/value and current token/revision before creating
   any duplicate request or capturing authorization. Session-only retention is
   insufficient because successful duplicate may navigate away. If save or
   readback fails, abort before request/native mutation; retain original editor,
   selection, history, dirty source and label. Do not continue with a warning.
   Capture the duplicate's raw tool-data baseline after this successful draft
   write so the unchanged-store comparisons do not conflict with its own
   precondition write.
6. Duplicate source is always the verified committed baseline, never the dirty
   editor source. Once durable save succeeds, preserve that exact original draft
   on duplicate success and failure. Duplicate request must not capture an
   original draft descriptor for writer cleanup, compare-and-clear it, relocate
   it, or clear it on success. A New Phrase target with no dirty draft has no
   draft-save prerequisite.
7. Request intent is explicit (for example `operation="duplicate"`) within
   existing runtime authorization. It carries the authorization snapshot from
   item 1 and current request token; GUI cannot forge or refresh captured values.
   Do not add deprecated audio modes.
8. Existing `phrase_writer` create operation allocates fresh ID and seals the
   new phrase through existing materializer/transaction. No separate writer,
   direct GUI phrase insertion, or new transaction path. Revalidate original
   authorization at the writer boundaries in item 2, not only when creating a
   New-target request.
9. Copy all 32 PITCH and TIME entries, both bounds, timing, mask state/bits,
   output policy and PB range. Preserve original source and committed phrase.
10. New label: reserve suffix ` copy` (five bytes), take first 27 bytes of the
    valid captured label, trim trailing spaces/dots/hyphens from that prefix,
    then append suffix. The result is necessarily valid: its first byte remains
    alphanumeric and its length is at most 32. Validate it as an invariant;
    failure aborts before mutation, with no fallback or repair. Set the new
    `label_custom=true` so the derived label survives commit and reload.
    Different IDs may have the same resulting label; uniqueness is by ID, not
    display text. This derived label
    uses the captured label snapshot and is covered by authorization checks.
11. Success selects new phrase only after final authorization and postimage
    verification, and only if originating session/binding/target remains current.
    A stale UI binding leaves active selection/history untouched; do not jump to
    new phrase. A verified duplicate may remain committed in its instrument.
12. On preflight/allocation/create/materialization/verification/store failure,
    preserve original last-good phrase, original source/settings/label, original
    selection/history and original dirty draft. Writer rollback evidence and
    integrity blocker rules remain authoritative. Do not claim rollback without
    checking phrase inventory/preimage, exact tool-data bytes and draft token.
13. Duplicate is not undoable as an editor source edit. Deleting a created
    phrase is not an implicit undo path.

### 8.4 Scoped clear and targeted transforms

Clear and transform operations apply immediately in Program and Grid using
the selected scope, without confirmation.
Each changed operation is one history item and one normal edit request. Equality
no-op means no history, draft write, or Live Edit request.

1. Scope choices are Active memory and All 32 stored. Active PITCH is 1..`pitch_length`;
   Active TIME is 1..`length`. Preserve each selected bound.
2. Clear PITCH sets note/key/octave to canonical C/NORMAL `(36,0,0)` and both
   flags false in scope only. Preserve mask and enable state.
3. Clear TIME sets commands to NOTE in scope only. Preserve PITCH and mask.
4. Clear TIE replaces only T with N in selected TIME scope.
5. Clear REST replaces only R with N in selected TIME scope.
6. Clear SLIDE sets only `slide=false` in PITCH scope.
7. Clear ACCENT sets only `accent=false` in PITCH scope.
8. REST to NOTE replaces only R with N in selected TIME scope.
9. TIE to REST replaces only T with R in selected TIME scope; TIME 01 is never
   T in valid source and remains protected by shared normalizer/validator.
10. All transforms preserve every out-of-scope slot, unrelated memory, bounds,
    timing, mask, output, PB, label and custom bit.
11. Mask editor provides one enable toggle and twelve class toggles. Editing mask
    while disabled is allowed and undoable. Enabling an all-false mask is rejected.
    Clearing PITCH does not change mask.
12. Direct TIME editing remains limited to 1..`length` through `set_time`.
    Bulk All-32 operations explicitly may change inactive stored TIME slots.
    Build a detached full-source candidate, normalize each generated command
    with the existing `normalize_time_entry(index, command)` for indices 1..32,
    assign only in-scope slots, then validate the complete candidate before one
    edit. Keep `set_time` bounds unchanged; never enlarge LAST STEP temporarily
    or bypass shared normalization. This also applies to TIME Randomize.

### 8.5 Deterministic randomization

1. Use Park–Miller with modulus `2147483647`, multiplier `16807`, zero
   increment, seed integer 1..2147483646. Do not use global RNG, time seeds,
   floating nondeterminism, or extra draws.
2. For each choice, first update
   `state = (state * 16807) mod 2147483647`; choose
   `bucket = floor((state - 1) * N / 2147483646)` in 0..N-1.
3. Draw once for every generated position, even if a pitch range yields one
   possible value. This keeps the state progression independent of range size.
4. Seed 1 first states are exactly `16807, 282475249, 1622650073,
   984943658, 1144108930`. Pitch draws over 24..60 yield notes
   `[24,28,51,40,43]`.
5. TIME weights NOTE/TIE/REST `[2,1,1]` with seed 1 yield
   `[N,N,R,N,T]`. At TIME 01, generated TIE becomes NOTE without another draw.
6. PITCH Randomize selects inclusive min/max within 24..60, seed and scope.
   It preserves each position's ACCENT/SLIDE, every TIME value, both bounds,
   timing, mask, settings, label/custom and data outside scope. Encode each
   sampled raw note canonically, including note 60 as key12/octave+1.
7. TIME Randomize takes integer weights 0..1000, sum > 0, explicit seed and
   scope. Per position one bucket in `[0,sum-1]`; NOTE interval `[0,N)`, TIE
   `[N,N+T)`, REST remainder. Preserve all non-TIME data and normalize T01
   without additional draw.
8. Show seed, range or weights inline in Extended / Clear with the scope
   selector. Validate all fields
   before Apply. Apply edits directly in Program and Grid without a modal.
9. Apply uses the current inline parameters and selected scope through ordinary
   synchronous edit admission. Parameter changes alone never edit source.
   One result is one history/edit.
10. If resulting source equals current source, no-op has no history, draft write,
    or Live Edit request. Raw random notes are not quantized by mask.

## 9. Request, Draft, and Transaction Threading

### 9.1 Immutable request values

1. `runtime.requests.VALUE_FIELDS` currently captures request value data. Add
   every value needed by source resolution and authorization to that exact
   detached snapshot and `request_values_match`; do not capture GUI widget
   references or mutable source tables.
2. A render request includes raw canonical source (including mask), output
   policy, PB range, identity/baseline, target kind, capabilities/planning
   inputs, timing context and the prepared bundle's frozen source/records with
   private provenance from section 4.4.
3. Reuse the source snapshot's prepared bundle when capturing a request; prepare
   once if that snapshot has none. Revalidate bundle provenance, exact values
   and source/mask association at checkpoints without quantizing again.
   Never resolve from a later mutated GUI source or accept detached records
   without their checked source association.
4. Draft candidate capture includes label, `label_custom`, token/revision and
   exact pending metadata. Compare token/revision as well as bytes/values before
   clear. A newer label edit cannot be removed by an older render completion.
5. Label-only request should not be a generation request. It uses narrow store
   metadata candidate with current target identity and exact raw bytes. Label
   token is compared at write time; source fields are preserved from current
   committed store, not copied from dirty editor draft.
6. Mixed source+label edit is an accepted local musical edit: update canonical
   editor state/history once and attempt one atomic pending-draft write carrying
   source, settings and label/custom. For an existing ID, include the changed
   LABEL/custom metadata in the same candidate while preserving committed
   SOURCE/settings. For a New target there is no LABEL record yet.
   Never publish edited SOURCE/settings as committed before verified phrase
   materialization: only the existing writer transaction can do that. With Live
   Edit off, committed SOURCE/output remains the previous phrase baseline.
   New targets persist only DRAFT until an authorized create succeeds.
   If durable publication fails, retain the source and label together in
   dirty session state, show the unsaved-draft warning, and block target switch;
   do not claim durable success. This differs from a label-only operation, whose
   attempted label is not accepted into canonical state/history on write failure.
7. Any changed raw `tool_data` since candidate capture invalidates candidate.
   Do not merge unrelated-looking changes unless existing store's reviewed
   exact-candidate contract explicitly supports it. M5 decision D13 is fail
   closed on any changed raw store.

### 9.2 Source association

1. Source/output association compares all raw source fields including mask
   enabled/bits, output policy, PB range and verified phrase output under current
   capability inputs.
2. Friendly label and custom bit are metadata and never enter source equality,
   expected phrase plan, output seal, or source ownership identity.
3. Dirty draft restore includes mask and pending label/custom. Committed baseline
   remains the expectation for existing phrase compatibility; dirty draft never
   replaces committed source in writer classification.
4. Store invalid/corrupt/unsupported data is read-only failure. It cannot fall
   through to New Phrase and cannot authorize writer or clear a draft.

### 9.3 Duplicate request admission

**Two identities, one transaction.** Extend the existing request capture with
explicit `operation="duplicate"`, `kind="create"`, and logical destination
`target_kind="new"`, destination instrument equal to the origin instrument,
destination phrase nil and destination ID unallocated. Separately capture an
`origin` owned-target authorization: song/epoch/session, instrument/phrase
objects, ID/seal, retained baseline proof, committed source/settings/metadata,
raw store and target/edit/operation/metadata revisions. Keep live object
identities in the private raw-identity record and detached values in the frozen
value record. Never rebind GUI/runtime selection to New to obtain admission.

For ordinary create/regenerate, existing selected-target rules remain unchanged.
For Duplicate, request `verify` compares current runtime binding/revisions to
the captured owned **origin**, while writer create preflight checks the logical
**destination** and its explicit duplicate authority. An owned request with
`kind="create"` alone must still reject. The writer uses its existing create
job, allocation, materializer, store candidate and rollback; origin proof is an
additional precondition, not a second transaction implementation. Original ID
is never reused as the destination ID, and original draft capture never becomes
a cleanup descriptor.

At capture and immediately before insertion, validate both origin authority
and destination instrument membership/capacity. Before store commit, validate
origin again, the exact newly allocated phrase/ID/seal, and unchanged captured
store bytes. At final verification require the exact candidate store, unchanged
origin records/draft and verified new output. Every existing request/writer
checkpoint must dispatch by operation without dropping lifetime, occupancy,
transport, capabilities, baseline or revision checks. A changed binding before
commit revokes authorization and rolls back this transaction. A change after
verified commit but before UI completion suppresses selection only; it cannot
retroactively authorize a failed commit. Completion selects the new phrase only
while the captured origin binding remains current.

Required tests capture from an owned target with a dirty draft while never
installing a New target; inspect both authorization records at each checkpoint,
reject forged create/duplicate intents, and change each origin/destination
identity independently. Assert ordinary create/regenerate admission unchanged.

1. Before request creation, if the originating owned target has a dirty draft,
   save it through `runtime.draft_cache` / `renoise.pattern_store`, then read back
   and compare exact persisted draft values and token/revision. Session-only
   retention or an unchecked save return is insufficient. If save, assignment,
   or readback fails, abort before creating a duplicate request or native phrase;
   keep original editor values, selection, history and dirty draft unchanged.
2. For a clean owned target, no draft write is required. New Phrase duplicate is
   not offered; this command duplicates an existing committed owned phrase.
3. Capture original song/instrument/phrase object identities, stable ID, exact
   seal/name, committed raw source/settings, verified phrase baseline, committed
   label/custom metadata, exact source/label record values and raw `tool_data`.
   The target-kind `new` create request does not replace this authorization.
4. Revalidate that same immutable authorization at request capture, immediately
   before native mutation/insertion, immediately before source-store commit, and
   at final postimage/source-association verification. Require original live
   objects, stable ID, seal, source/settings, label/custom metadata, and phrase
   compatibility to remain equal at every checkpoint. Before store commit,
   require exact captured raw bytes and original source/label values; at final
   verification, require the exact transaction candidate bytes and confirm the
   original source/label values remain unchanged within those bytes.
5. Missing/duplicate/modified original, changed source/settings/label, or any
   captured raw store change before native mutation aborts with no phrase/store
   mutation. If discovered later, cancel the transaction and roll back only
   this operation's exact phrase/store candidate; if exact rollback is
   uncertain, retain evidence and integrity-block further writes.
6. Do not include the original dirty draft as a writer cleanup descriptor.
   Preserve the successfully verified durable draft on both duplicate success
   and failure; never compare-and-clear, relocate, or consume it. Its exact token
   and revision remain intact unless the user independently edits it later.
7. Existing writer create transaction remains sole native mutation path. Final
   selection occurs only after revalidation and final verification, and only if
   originating session/binding still points to the captured operation. Stale
   UI leaves current selection/history untouched while the verified duplicate
   remains in inventory.

## 10. Deterministic Test Plan and Exact Assertions

Tests run in repository per-spec process isolation using the prescribed runner.
No test count is a fixed acceptance criterion: all relevant specs must pass and
new behavior suites must be included by the runner.

### 10.1 Existing owner specs to update

1. Source values/factories: `tests/acid/acid_source_values_spec.lua` and every
   test-local source builder found by repository search. Assert required mask
   fields are always present; no silent factory patching.
2. Compiler semantics: `tests/acid/acid_cycle_interpreter_spec.lua` plus any
   compiler spec. Assert raw-source behavior unchanged when disabled and
   resolved event/control consistency when enabled.
3. Editor/history: `tests/acid/acid_editor_spec.lua`. Assert source, output, PB,
   mask, label and custom bit snapshot/undo/redo/reset; classification and no-op.
4. Codec: `tests/acid/acid_pattern_store_codec_spec.lua`. Replace successful
   schema-1 expectations with exact schema-2; retain schema-1 rejection-only
   case. Include storage byte identity on all decoder/write rejects.
5. Drafts: `acid_draft_cache_spec.lua`, `acid_draft_recovery_spec.lua`, and
   affected persistence specs. Assert mask/label/custom restore, pending New
   label, exact token/revision clear, stale candidate preservation.
6. Request/runtime: `acid_runtime_request_spec.lua`, `acid_store_candidate_spec.lua`,
   `acid_gui_admission_spec.lua`, `acid_gui_recovery_spec.lua`, and identity /
   transaction specs. Assert values freeze and stale metadata cannot be cleared.
7. Planner/writer ownership: `acid_output_planner_spec.lua`,
   `acid_output_compatibility_spec.lua`, `acid_planner_association_spec.lua`,
   `acid_phrase_validator_spec.lua`, `acid_phrase_materializer_spec.lua`,
   `acid_phrase_persistence_spec.lua`, `acid_writer_transaction_identity_spec.lua`,
   `acid_id_allocation_spec.lua`. Assert same resolved vector, mask-sensitive
   association, writer rollback, no second writer.
8. Views/admission: `acid_gui_views_spec.lua`, `acid_gui_independence_spec.lua`,
   `acid_gui_admission_spec.lua`, `acid_gui_timing_race_spec.lua`. Assert
   independent selection, retained inactive TIME, stage guards and no source
   mutation on navigation.
9. Other ACID specs may need factory updates even if behavior is unrelated.
   Change only what the required source shape necessitates; preserve unrelated
   assertions and do not edit ARP or frozen Digitakt tests.

### 10.2 New behavior specs

Use these responsibility names only where existing suites do not own the
behavior. Names are approved; do not label them by phase/roadmap step.

1. `tests/acid/acid_scale_mask_spec.lua` owns pure resolution, nearest/tie,
   domain, source immutability, compiler event records and shared-vector
   projection/planner assertion.
2. `tests/acid/acid_program_staging_spec.lua` owns the complete stage state
   machine and stage-to-one-edit integration.
3. `tests/acid/acid_audition_lifecycle_spec.lua` owns host-shaped mocks for
   object identity, fresh indices, timer and release control flow.
4. `tests/acid/acid_clipboard_spec.lua` owns payload exact fields, detachment,
   corruption rejection and paste candidate preservation.
5. `tests/acid/acid_source_operations_spec.lua` owns clear, transforms and
   Park–Miller behavior where no current source-model suite fits.
6. `tests/acid/acid_duplicate_label_spec.lua` owns duplicate request integration,
   label persistence/history and rename/duplicate failure cases if current
   store/writer specs do not have a clear owner.
7. Do not add all six if existing specs can own cohesive tests; new test files
   are for unowned behavior, not for mirrored coverage.

### 10.3 Source and resolution assertions

1. Construct canonical source and assert exactly seven source fields; unknown
   field fails. PITCH records have exactly five fields. Mask is dense 12 booleans.
2. Reject each missing mask field, sparse slot, extra numeric slot, nonboolean,
   enabled all-false mask, pitch 23/61, source pitch/key/octave inconsistency,
   invalid timing and malformed 32-element arrays.
3. Accept endpoints 24 and 60 with valid control encodings. Assert
   `pitch_controls({note=60,key=12,octave=1})` returns 12,1 and 61 rejects.
4. For disabled mask, resolved note values equal raw values and raw source deep
   compares unchanged. For C-only mask assert `[30,35,37,42,59,60]` becomes
   `[24,36,36,36,60,60]` with canonical controls and raw source unchanged.
5. Test each pitch class and domain edges. Equal-distance tie always selects
   lower note. Enabled-empty rejection happens before planner/writer calls.
6. Compile fixture containing NOTE/TIE/REST and flags. Assert NOTE event and
   voice resolved note/key/octave form a consistent record; pitch index,
   ACCENT/SLIDE and transition equal raw semantic intent. TIE preserves held
   resolved voice without pitch consumption. REST releases same note.
7. Spy on resolver invocation and capture reference/value: Decoded and output
   plan consume one prepared vector per snapshot, with exact-value copies only
   at immutable request boundaries; no second quantizer.
   Mutating original source or a caller vector after request capture cannot
   change frozen request plan.
8. Assert mask bit or enabled-state change makes `same_source` false even while
   disabled; label change does not.
9. Accept and roundtrip a disabled all-false mask, including history, draft,
   clipboard exclusions and request capture. Enabling it fails atomically.
   Reject `{}`, holes, nonboolean entries, extra keys and extra slots even when
   disabled. Assert resolver identity for valid disabled all-false source.
10. Exercise Repeat and Play Once through both planner entry points, loop
    planning and `control_signals.compile` with and without prepared plans.
    Use notes actually changed by the mask, with NOTE/TIE/REST and SLIDE across
    a cycle boundary. Spy on all nested interpreter calls and verify successor
    validation consumes the prepared vector without resolving again. A genuine
    mismatched successor must still reject. Test invalid length, extra fields,
    inconsistent controls, source/vector mismatch and post-capture mutation.

### 10.4 Codec, history, and candidate assertions

Foundational Gates 1+2 assertions include ordinary create/regenerate with
default/custom labels, DRAFT restore, writer failure/rollback, and cold reload.
Assert SOURCE/LABEL pairs are complete before any rename UI exists. For
metadata-only Undo/Redo, inject persistence failure before/after setter and at
readback: accepted editor values, cursor and musical revision stay unchanged.
Retry commits only the proposed cursor, adds no history entry and emits no Live
Edit request. Test stale history and metadata revisions without cursor movement
or clearing a newer draft. A successful rename/undo/redo advances metadata
revision only; a mixed edit retains its specified local failure semantics.

1. Canonical roundtrip bytes exactly equal expected schema-2 bytes and encode
   deterministically after decode/encode. Assert SOURCE/LABEL numeric ID order,
   DRAFT key order, class ordering, final LF and every required field.
2. Test equal labels across IDs pass; duplicate source/label ID, missing label,
   orphan label, duplicate record, duplicate DRAFT key reject.
3. Reject malformed schema: old magic, unsupported magic, missing/extra fields,
   malformed mask or enabled all-false mask, unknown records, reordered classes,
   bad integer leading
   zeros/signs, odd/lowercase/invalid hex, invalid label bytes, invalid custom
   bit, delimiter, blank line, CRLF, no final LF and trailing data.
4. Before each invalid-store operation capture raw `tool_data`; after reject
   assert byte-identical, no draft cleanup, no writer call, no phrase inventory
   change. Empty store is the only uninitialized accepted state.
5. Include draft `phrase_id=0`, pending `Untitled`, `label_custom=false`; edit
   label to literal Untitled and assert custom=true roundtrip. New draft must
   not create a SOURCE record.
6. History transitions: source-only, mask-only, output-only, label-only and
   mixed. Assert one cursor move each, undo/redo exact values, label-only has
   no `changed()`/Live Edit/revision call, mixed uses one history state and one
   atomic persistence attempt.
7. Inject label-only store failure before mutation, after mutation, and at
   readback. Previous accepted editor label and history cursor remain unchanged;
   attempted text may remain in the focused field only, with an error and Retry /
   Discard Attempt. Assert it is absent from canonical source/history/draft and
   not accepted as editor state. If exact candidate bytes were partially written,
   verify guarded restore to captured bytes; inject third-value and unreadable
   restore conflicts and assert bytes are preserved, integrity is blocked, and
   persistence is reported unknown rather than successful or silently rolled
   back. Retry starts validation from the beginning;
   Discard restores accepted text and removes the unresolved-field block; the
   user invokes the previously blocked navigation again. A separate integrity
   blocker, if raised by uncertain storage rollback, remains active until the
   existing revalidation path resolves it. Undo applies to the previous accepted
   history state.
8. Inject mixed source+label durable write failure. Assert the real source edit
   and label remain together in canonical editor/history and session draft, one
   dirty revision is retained, warning is shown, no durable-success claim is
   emitted, and target switch is blocked. Undo restores the prior accepted pair.
9. Candidate tests capture raw bytes and draft token/revision. Inject source raw
   change, label raw change, unrelated draft change, same-value new revision,
   draft absence/addition, setter-before-mutate throw, setter-after-mutate throw,
   unreadable readback, and restore conflict. Assert no candidate overwrites
   bytes other than its exact captured candidate; uncertain state blocks.
10. With Live Edit off, a mixed edit changes pending draft source/metadata
    atomically but leaves committed SOURCE/output and phrase preimage intact.
    With Live Edit on, only a verified writer transaction publishes committed
    source. Inject writer failure and prove the draft remains recoverable and
    old committed source still describes the restored last-good phrase.

### 10.5 Program, Grid, stage, and audition assertions

Test every row of the section 5.4 action matrix in ordinary, PITCH-stage and
TIME-stage contexts. Include raw `(48,12,0)`, `(36,12,-1)` and `(60,12,1)`:
navigation/readout never rewrites them; genuine key/octave edits follow the
specified mapping and preserve flags. Test stored/referenced/modified indicators
against procedure 13.8's baseline semantics, including reload and undo/redo.
For complete and incomplete stages, inject native selection, deletion, ownership
loss, session close/reopen, song change and origin revision drift. Assert no
candidate is committed under a replacement binding, no host selection is
silently reversed, and failed origin draft save retains recovery evidence.

1. Exercise PITCH then TIME navigation in both orders. Assert other cursor/page
   does not move. Only diagnostic with both coordinates may move both.
2. LAST STEP 17 -> 7 retains selected TIME 17, page 2, stored command and
   readout; edit disabled. PITCH positions 17–32 remain editable on page 2.
3. Program and Grid edit same fixture and yield exact same source. Tab/view/page/
   selection/preview cycle adds no history, save, or request.
4. Stage confirmation lists exact in-scope positions and defaults. Cancel is
   inert. Stage PITCH changes flags only in target initialization; stage TIME
   preserves every pitch and every inactive TIME slot.
5. Assert Edit/Enter marker behavior: stage edit clears only selected marker;
   no-change does not; Enter marks/advances; last Enter leaves cursor final and
   completion equals all target markers; Back retains values/markers;
   Restart Cursor retains markers; direct
   selector visit does not clear state.
6. Finish disabled until every marker is true. An incomplete-stage guard offers
   Discard and Stay only; Finish is absent/disabled and explains missing
   positions. Direct programmatic Finish rejects without source/history/draft/
   request mutation. Successful Finish creates exactly one source history
   transition and one `changed()` when source differs; equal-source Finish
   closes stage with zero edit side effects. No intermediate writes occurred.
7. For a complete stage, test both Finish and Discard. Finish commits only the
   stage; Discard drops only the stage. In both cases the guarded command is
   abandoned, not queued or automatically executed. Verify Undo/Generate/Live
   Edit/target switch remains unexecuted, then invoke it again explicitly.
   For an incomplete stage test only Discard and Stay. Stay has zero side effects.
   View switch preserves stage but Grid shows canonical values and disables edits.
8. External teardown discards stage without modal and does not corrupt saved
   canonical draft. Simulate stale editor revision between stage and Finish;
   Finish rejects and retains newer source.
9. Audit widget inventory: no old position/key/octave dropdown, no TIME cell
   popup, no stacked preview. Test exact old IDs are absent; retained unrelated
   selectors are not mistaken for prohibited memory selectors.
10. C+ endpoint writes note60/key12/octave1 and preserves flags. Normal twelve
    key tests remain exactly twelve key classes.
11. Audition mocks: valid selected objects; non-send track; wrong song, removed
    objects, same-index replacement and stale index. Assert API receives exact
    fresh indices from captured objects and resolved note, volume .8.
12. Assert cleanup before each modal/navigation, second audition, song change,
    instrument/track removal, close, unload, timer callback and onset exception.
    Removed identity means no guessed note-off. Timer removed once. Preserve
    both onset/cleanup failures.
13. Select the final staged position before entering earlier positions; Enter
    must leave completion false and Finish unavailable. Complete every marker,
    edit an earlier position, revisit the final position and Enter: completion
    remains false until that earlier position is explicitly entered again.
14. Check canonical source and staged candidate independently; assert no marker,
    history, draft or generation side effects. Test coordinate-free diagnostics,
    missing-marker reporting and stage navigation bounds. Back/Enter are disabled
    without a stage. Re-enter and Rename obey the guard; no automatic replay.
15. Audition uses candidate pitch during PITCH staging, is disabled during TIME
    staging, and never publishes candidate source or marks a position entered.

### 10.6 Clipboard, labels, duplicate, transforms, RNG assertions

Duplicate integration must start from a still-selected owned origin, including
a dirty editor draft. Spy on request capture and every writer checkpoint:
origin authorization remains owned, logical destination remains New until
allocation, and GUI is never rebound to New for admission. Mutate raw identities
and frozen values independently; forged intent or lost origin proof rejects.
Assert ordinary create/regenerate behavior unchanged, original draft never
enters cleanup, pre-commit binding drift rolls back, and post-verified-commit
binding drift suppresses only UI selection.

1. For each clipboard scope assert exact key set and values for all 32 positions
   plus the correct bound(s). Assert deep copy by mutating source and payload.
2. Corrupt every boundary: missing/extra top key, sparse array, wrong length,
   extra pitch field, invalid note/control, invalid boolean, invalid command,
   leading TIE, invalid scope. `paste_candidate` returns error and no partial
   candidate. Excluded mask/timing/output/label/ID values remain byte-equal.
3. Copy counters prove zero store/draft/history/request/writer calls. Paste
   existing-owned performs exactly one edit path; no-op paste performs zero.
   New target create only occurs through normal authorized paste edit path.
4. Label tests: 1 and 32 byte boundary valid; 33 invalid; spaces/punctuation
   interior valid; invalid first char, non-ASCII and forbidden punctuation
   reject unchanged. Duplicate label text across IDs passes.
5. Rename call-order spy: source/ownership compatibility before candidate
   construction; candidate captures raw bytes; one assignment/readback. Dirty
   source remains exact while only draft label/custom changes. Metadata rename
   must not invoke generation or phrase revision.
6. Duplicate precondition: before request creation, if editor has dirty changes,
   durably save and verify exact draft bytes/value plus token/revision. Inject
   save and readback failure; assert duplicate is never queued/requested and no
   native phrase mutation occurs. Original editor, selection, history and dirty
   draft remain unchanged. Successful duplicate preserves the exact durable
   draft and token/revision; writer cleanup must not include it. Clean editor
   requires no draft write.
7. Duplicate authorization captures original song/instrument/phrase identities,
   stable ID, exact seal, committed source/settings, label/custom and raw store.
   Mutate each independently before request, before native insertion, before
   store commit and before final verification. Pre-mutation changes abort with
   no native/store mutation; later changes roll back only the duplicate or block
   with evidence if exact rollback is unprovable. Label change cancels; never
   recalculate from newer metadata. Stale origin cannot change selection.
8. Duplicate label exact examples: `Acid Pattern` -> `Acid Pattern copy`;
   `Acid.- ` -> `Acid copy`; 26 `A` bytes followed by `.` and `B` truncates to
   26 `A` bytes plus `.`, trims that `.`, then appends ` copy` (31 bytes).
   Assert prefix truncation, then prefix trim, then suffix append in that order;
   assert `label_custom=true` and exact reload. No invalid-label fallback exists.
9. Inject failure at eligibility, ID allocation, capacity, phrase insertion,
   materializer write, postimage verify, store setter before and after mutation,
   persistence readback, and stale UI binding. For each assert exact original
   phrase snapshot, inventory, source bytes, original selection/history/draft,
   cleanup status and integrity blocker. If exact rollback cannot be proven,
   preserve evidence and block; never blindly overwrite.
10. Every clear/transform × Active/All scope asserts precisely the changed
   coordinates and untouched fields, bound retention, one history item, undo /
   redo, no-op and T01 invariant. Assert immediate application without a modal
   in Program and Grid; Reset has the same immediate, single-undo behavior.
11. Park–Miller seed 1 state vector and note/command vectors in section 8.5 are
    exact assertions. Test seed min/max, invalid 0/max+1, same seed reproducible,
    inclusive note limits, note 60 encoding, every octave boundary, flags
    retained, one draw even singleton, zero-weight boundaries, weight maximum,
    invalid zero sum, T01 normalize without extra draw, and out-of-scope values.
    Assert inline parameters and the scope selector in both views: parameter
    edits are inert, invalid inputs reject, and Apply creates one edit without
    a modal.
12. With LAST STEP 7 and distinctive TIME values at 8..32, compare Active and
    All-32 Clear/transform/Randomize. Only All-32 can change inactive storage;
    neither changes the bound. Direct TIME 17 editing still rejects. Verify
    shared T01 normalization and exact undo/redo/save/load of inactive values.
13. Reset from nondefaults asserts every result in section 8.1.13, including
    retained LAST STEP and label/custom, reset output defaults, one history
    transition, exact undo/redo and an identical-reset no-op. Test New and owned
    targets with Live Edit off/on through ordinary authorization.

### 10.7 Test execution and reporting

1. During development run focused affected specs once per meaningful change.
   Exhaustively test guard/transaction matrices deterministically. Required full
   regression checkpoints are Gate 0 baseline, combined Gates 1+2 and Gate 9
   final build. Between them use affected-owner suites and broaden when failure,
   shared-contract changes or uncertainty justify it. Do not rerun an unchanged
   full suite solely to populate another ledger row.
2. Use `./scripts/run_tests.ps1 -Tool ACID` from PowerShell 7 for full regression
   after Lua changes at those checkpoints. Run focused specs from repository
   root in separate Lua processes; preserve mock/module isolation.
   Do not cite only a focused test result as full-suite pass.
3. Record command, exit code, actual pass/fail count, and any host/environment
   limitation in the gate evidence. A changed spec count is normal; do not use
   the supplied 70-spec baseline as a future expected count.
4. The project root runner runs specs in separate processes. New specs must be
   discovered by the existing runner without weakening isolation.

## 11. Linear Implementation Gates

Every gate has scope, numbered action order, owner-specific changes, required
assertions and an exit test. Gates 1+2 are the sole atomic pair; otherwise do not
batch future gates. If a test fails, fix and rerun the entire current gate before
proceeding. Preserve unrelated worktree
changes. No runtime implementation is authorized until Gate 0 audit is complete.

**Foundational atomicity rule:** Gates 1 and 2 form one indivisible source-to-
render cutover. They are split only to make owner responsibilities reviewable.
Implement both gates before running their combined acceptance or declaring any
intermediate exit. Do not commit, merge, package, or expose a Gate 1-only state
where schema-2 mask values can be loaded or edited but `cycle_interpreter`,
Decoded, output planning, writer requests, ownership association, or rollback
does not consume the same resolved pitch records. Run the Gate 1 and Gate 2
tests together against the complete cutover; if either fails, the foundational
gate remains failed and no consumer gate may begin.

### Execution and evidence rules

1. Gate 0 produces a call-site inventory, not permission to improvise semantic
   behavior. A discovered conflict with code must be resolved in the relevant
   normative section and its assertions before runtime changes begin. Use
   existing test/acceptance records for the inventory; do not add another plan.
2. Each exit records the implementation revision, commands, actual results,
   tests covering each required assertion, and outstanding native evidence.
   A test name or green suite alone is not evidence for an unasserted behavior.
   Missing required deterministic coverage means the gate remains pending.
3. After a later change to an earlier contract, invalidate its prior acceptance.
   Rerun the affected gate and every downstream gate whose assertions depend on
   that change, then full regression and second-pass review. A source/schema/
   resolution change reopens the entire Gates 1+2 unit. Repeat affected native
   checks against the final build; observations from older builds are historical.
4. Gates 0–9 have deterministic exits, with an early native layout feasibility
   dependency after Gate 3 before GUI-heavy Gates 4–7. Gates 10–11 own final
   integrated host evidence. Native unavailability permits foundational and
   deterministic shell work, but pauses later GUI-heavy work at that dependency
   and prevents full completion. API uncertainty
   affecting an implementation blocks that implementation until resolved; it
   cannot be waived merely because host execution is deferred.
5. Clean cutover requires deletion of superseded runtime paths in the same
   change that installs their replacements. No feature flag for the old editor,
   dual schema reader/writer, migration helper, repair default, duplicate owner,
   compatibility wrapper or hidden widget alias is acceptable. Existing stable
   IDs/seals, negative schema-1 fixtures and explicitly historical documentation
   remain intentionally; they are not executable legacy support.
6. Before declaring closeout, search the complete diff and runtime tree, not
   only added files. Every former control notifier and store success path must
   have a recorded replacement or removal. Do not weaken existing rollback,
   ownership, association or stale-request tests to accommodate the new design.

| Contract | Implementation gate | Required evidence |
| --- | --- | --- |
| Strict source/schema and metadata carriers | 1+2 | Sections 10.3–10.4; unsupported bytes/inventory unchanged |
| One resolved snapshot through successor validation and writer | 1+2 | Section 10.3.7/10; both policies and planner entry points |
| Independent navigation and retired controls | 3 | Section 10.5; early native fit via 13.1.6, repeated on final build |
| Stage admission, completion and no-op Finish | 4 | Section 10.5.4–8/13–14; native procedure 13.2 |
| Audition object identity and teardown | 5 | Section 10.5.11–12/15; native procedure 13.6 |
| Labels, clipboard and authorized duplicate | 6 | Sections 10.4/10.6; native procedure 13.4 |
| Reset, mask, scoped storage operations and RNG | 7 | Section 10.6.10–13; native procedures 13.3/13.5 |
| Documentation, regression and package boundaries | 8–9 | Actual commands and archive inspection when applicable |
| Host preparation and final-build observations | 10–11 | Section 13 and complete evidence ledger |
| Independent review and deletion audit | 12 | Section 12; findings fixed and affected gates rerun |

### Gate 0 — Baseline, SDK, and complete call-site inventory

**Depends on:** accepted design and this manual. **Runtime edits:** none.

1. Record `git status --short`, staged/unstaged diff, current branch and
   `git log -10 --oneline`. Preserve every unrelated staged/unstaged change.
2. Rerun `./scripts/run_tests.ps1 -Tool ACID`; record current actual baseline.
   If unrelated failures exist, isolate and document them before M5 changes.
3. Run `./scripts/setup_sdk.ps1` if pinned SDK is missing. Read API-6.2 note-on,
   note-off, timer, track and tool lifecycle definitions plus offline docs.
   Record exact paths/signatures and any access/lifetime restrictions. If SDK
   unavailable, verify official versioned source at cited commit and record
   unresolved API uncertainty; no guessing.
4. Inventory source construction with `rg` for `new_pattern`, source table
   literals, pitch/time fixtures, source copies, equality, history, persistence,
   request values, baseline snapshots and store candidate functions.
5. Inventory GUI IDs and notifiers for the exact current controls in section
   2.3, coupled selection, reset/clear, destination switching, clipboard-like
   operations, dialogs, preview layout and Generate/Live Edit admission.
6. Inventory every phrase create route and `phrase_writer` caller. Confirm
   duplicate can be represented as explicit authorized create in existing
   architecture without GUI phrase APIs or a second writer.
7. Inventory document/tool close, new-song, observer and timer cleanup sites
   relevant to stage and audition lifecycle. Identify current callbacks and
   stable identities before adding new observers.
8. Map each existing spec to sections 10.1–10.6. Record gaps, exact owners and
   runner discovery requirements.
   Include `control_signals.compile` fallback/successor validation, interpreter
   `plan_loop`, both planner entry points, projection cache invalidation and all
   request/association rebuilds. Record one source-snapshot resolution owner
   and every vector consumer; leave no implicit raw-source compiler path.
9. Confirm any downloaded SDK/build output remains untracked and no manifest or
   unrelated file is in M5 scope.

**Exit:** audit inventory complete, source contracts understood, SDK facts
verified for implementation, baseline result recorded. Unresolved API facts may
be recorded, but block the dependent implementation until resolved. Stop on a conflict
between owner behavior and this contract; update the design before code rather
than guessing.

### Gate 1 — Atomic source/schema/history cutover

**Metadata is operational here, not deferred to Gate 6.** Before the combined
exit, ordinary New/create, regenerate, draft save/restore, rollback, reopen and
history carry label/custom end to end. `pattern_store` source candidates and
writer jobs explicitly carry pending label/custom; allocation derives
`Pattern <ID>` only for noncustom New labels. Regenerate preserves current
accepted metadata. Capture metadata revision and reject stale metadata commits
or draft cleanup. Implement section 4.5's proposed-cursor history and metadata
transition now, testing them without rename widgets. Gate 6 adds UI/admission
for Rename and Duplicate on this already functioning contract; it must not
repair missing schema-2 carriers or introduce a different history path.

**Part of the indivisible Gate 1+2 cutover described above.** Source factories,
validation/copy/equality, history, schema codec, draft and request/source value
carriers, compiler, planner, writer and all dependent fixtures change together.
No intermediate implementation state may be treated as accepted.

1. In `model/sequencer.lua`, add required mask fields to `SOURCE_FIELDS`,
   `new_pattern`, `validate`, `copy_source`, and `same_source`. Tighten raw note
   bound to 24..60; keep key/octave equation and canonical constructor.
2. Update all source factories and literals to include twelve true bits and
   disabled state. Do not add decoder defaults or permissive compatibility.
3. In `model/editor_state.lua`, extend the one history snapshot with mask,
   label/custom and difference classification. Define label-only versus musical/
   output transitions without a second history.
4. In `renoise.pattern_store`, implement schema-2 source fields, SOURCE/LABEL
   association, explicit custom bit, pending draft labels, deterministic strict
   encode/decode, and candidate compare/write/verify/restore. Remove successful
   schema-1 paths; retain only a negative fixture/assertion.
5. Update `runtime.draft_cache`, source metadata copies, store candidate payloads,
   `runtime.requests.VALUE_FIELDS`, checkpoints and every source snapshot owner
   so mask/label token cannot be dropped or mutated after capture.
6. Make all invalid nonempty store reads read-only. Check raw `tool_data` byte
   identity and phrase inventory in test doubles for every failure class.
7. Update existing codec, source, editor, draft and request tests, plus all
   affected factories. Do not change phrase seal grammar or add a manifest bump.
8. Prepare exact Gate 1 test plan: source validation/endpoints, history classes,
   strict schema-2 roundtrip, schema-1 rejection, labels/custom roundtrip,
   New draft ID zero, raw bytes unchanged on reject, and candidate failure
   injection. Execute it and the full ACID suite after Gate 2 implementation,
   at the combined exit. Focused development runs are not a Gate 1 acceptance.

**Subgate review:** source and codec shape are complete together; exact
canonical bytes roundtrip; unsupported/corrupt store produces no write, cleanup
or phrase mutation; drafts preserve all fields and exact revision. This is not
an independent ship/pass point; continue directly to Gate 2.

### Gate 2 — Shared pitch resolution through compiler and render plan

**Depends on:** Gate 1 source/schema work in the same atomic cutover. This gate
must finish before any UI or consumer presents masked output.

1. Add one pure `model.sequencer` resolver for notes 24..60 and canonical
   resolved pitch records. Test disabled identity, every class, lower ties,
   empty-enabled failure, source immutability and endpoint controls.
2. Change `cycle_interpreter.run_cycle` to accept/use the resolved vector while
   preserving raw source, index/flags/semantics and consistent event/voice
   note/key/octave. Validate vector coverage and canonical record equation.
3. Thread the exact same vector through `editor_state.project`, output planning,
   phrase validation/materialization and writer request preparation. Inspect
   planner signatures; update current owners rather than adding another planner.
   Include `plan_loop`, `plan_output`, `plan_for_materialization`, and every
   `control_signals.compile` compile/association branch from section 4.4.
4. Update `runtime.requests`, ownership/source baselines, draft candidates,
   materializer plans, equality and rollback snapshots so mask bits survive all
   detached copies and invalidate source association.
5. Add a spy-based test that proves one resolution result is used by preview,
   compiler, planner and writer. Assert no double quantization and raw source
   remains unchanged.
6. Assert NOTE/TIE/REST count and cursor behavior are unchanged under masks,
   and output event voice has coherent resolved controls.
7. Run source/compiler/planner/association/writer specs and full ACID suite.

**Combined Gate 1+2 exit:** source/schema/history, request/draft threading,
association, compiler, projection, planner and writer all use one canonical
resolved-record contract; exact codec and mask-sensitive association tests
pass; all ACID specs pass; no second resolver or compiler path exists. Only
after this combined exit may Gate 3 begin.

### Gate 3 — Shared shell, navigation, and Grid cutover

**Depends on:** Gates 1–2.

1. Refactor `gui.lua` selection functions so PITCH and TIME update only their
   own coordinate/page. Keep explicit diagnostic jump as the only paired move.
2. Replace position dropdowns, key/octave dropdowns and per-cell TIME popups
   with accepted selectors/buttons. Add explicit C+ endpoint for note 60.
3. Replace stacked preview with fixed-height tab workspace. Implement two-row,
   eight-cell memory grids, independent pages and shared TIME assignment controls.
   Establish Decoded's four-row paging here; Gate 7 adds the complete decoded
   field presentation and operation integration without replacing the shell.
4. Keep selection/page/view/tab/preview navigation out of history and requests.
   Update UI state without notifier feedback loops.
5. Implement LAST STEP shrink behavior retaining TIME cursor/page and inactive
   stored value; disable edits beyond LAST STEP, keep all PITCH memory editable.
6. Implement mask display/control shell if needed for source-state visibility,
   but do not duplicate resolution. Grid never shows transient staged values.
7. Delete obsolete widgets and notifier paths. Search exact IDs and ensure no
   hidden alias or fallback control remains.
8. Add assertions for view equivalence, no-op navigation, independent selection,
   P17/time17 pages, time17 retained while inactive, and normal-resolution
   control hierarchy. Run affected GUI suites under section 10.7.

**Deterministic exit:** both views edit one source with independent cursors;
all navigation is source/history/request neutral; removed UI inventory is clean;
mock widget structure satisfies bounded layout and paging. Immediately perform
a small native feasibility check using procedure 13.1.6: open both views and
pages and the lower workspace at the intended display scale; record clipping,
legibility and controls reachable. Fix fit failures before GUI-heavy Gates 4–7.
If Renoise is unavailable, record this dependency pending and pause GUI-heavy
implementation; do not substitute widths/mocks for fit evidence. Gate 11 still
checks the final integrated layout; an earlier feasibility pass is not final
native acceptance.

### Gate 4 — Program Edit One, staging, and stage guards

**Depends on:** Gate 3.

1. Implement Edit One using existing source mutation and one `changed()` path.
   Use `sequencer.set_time` for TIME; preserve unrelated state.
2. Implement detached stage candidate, exact target list, entered markers,
   cursor and captured editor revision. Add Re-enter confirmations and defaults.
3. Implement per-position staged editing, marker invalidation only on changed
   value, Enter/Advance, final-position completion, Back, Restart Cursor and
   arbitrary position selection exactly as section 6 specifies.
4. Implement disabled Finish until all markers are entered and one atomic source
   edit/history/`changed()` on changed Finish; equal-source Finish closes without
   an edit. Test revision staleness, jump-to-final and marker invalidation.
5. Implement Finish/Discard/Stay admission for all guarded actions. Stay is
   inert. Finish or Discard resolves only the stage and abandons the guarded
   action; require a new user invocation to perform that action. Do not enqueue
   or replay it. Navigation remains unguarded/read-only. Centralize guard to
   prevent widgets from bypassing it.
6. Implement Program/Grid switching while stage active: preserve stage and show
   canonical Grid source with banner and blocked edit controls.
7. Implement teardown discard without prompt and canonical draft preservation
   best effort. Do not commit stage on close/unload.
8. Test R02 PITCH flag reset, TIME preservation, leading TIE normalization,
   complete-stage Finish/Discard/Stay and incomplete-stage Discard/Stay only,
   disabled Finish reason, no automatic continuation after either Finish or
   Discard, dialog
   cancellation, external teardown, stale revision and no pre-Finish
   source/draft/request calls.
9. Run affected stage/GUI/editor/draft/request suites under section 10.7.

**Exit:** stage never leaks into canonical source before Finish; changed Finish
is one edit and equal-source Finish is a no-op; guards and navigation follow
the exact matrix; no partial request or save.

### Gate 5 — Audition lifecycle

**Depends on:** Gate 4 for Program action lifecycle and guard entry points.

1. Verify API-6.2 signatures and exact object/track requirements immediately
   before implementation. Record references in test/manual evidence.
2. Implement a single private audition lifecycle owner in `gui.lua` or one
   narrowly scoped helper if GUI closure complexity requires it. It captures
   song/instrument/track object identities, resolved note, timer and outcomes.
3. Re-resolve live indices immediately before note-on/off and validate exact
   captured tuple. Never use cached indices after list changes.
4. Register timer with tool API for nominal 120 ms. Remove callback timer once.
   Clean observers and callback references on all paths.
5. Wire release before dialogs/navigation/target change/second audition/close,
   song change and captured object removal. Report best-effort failure without
   guessing a replacement index.
6. Test mock success, onset exception, timer, all release paths, track/instrument
   same-index replacement, removed object, modal suppression as modelled, and
   tool teardown. Mark native sound/timing unverified until section 13.
7. Run affected audition/GUI tests under section 10.7.

**Exit:** deterministic lifecycle mocks pass, API evidence is recorded, and no
mock result is described as native playback acceptance.

### Gate 6 — Clipboard, labels, and duplicate

The foundational metadata persistence/history transition already passes Gates
1+2. This gate wires rename UI to it and extends existing request authorization
with section 9.3's owned origin plus logical New destination. It does not change
ordinary create/regenerate eligibility to accept arbitrary owned creates.

**Depends on:** Gates 1–5. Duplicate and label metadata share store/request
contracts, but implement this gate in suborder 6.1 then 6.2 then 6.3.

1. **6.1 Clipboard.** Add pure exact payload builders/candidate paste seam.
   Wire session-only deep copy and ordinary authorized paste edit. Verify all
   32 slots, bound(s), exclusions, invalid payload atomicity, no-op and New
   target authorization. Stage guards apply first.
2. **6.2 Labels.** Add focused label editor and validation. Implement exact
   metadata candidate, one SOURCE-ID/LABEL association, draft pending update,
   custom-bit handling, history classification, separate attempted field state,
   Retry/Discard Attempt, and distinct label-only versus mixed-edit failure
   behavior. Do not make metadata-only edit a generation request.
   Capture only exact `song.tool_data` preimages for label recovery, using the
   existing integrity blocker and explicit revalidation. Unrelated phrase
   snapshots are not a metadata transaction precondition.
   ACID's transactional label Undo/Redo is the acceptance contract here.
   The recorded Renoise 3.5.4 metadata-only rename persists but exposes no native
   undo entry (`song:can_undo() == false`); native metadata Undo/Redo remains a
   host limitation, not a passing native check. Do not add dummy musical edits
   to manufacture native undo entries.
3. **6.3 Duplicate.** Add explicit duplicate operation to current runtime
   request authorization, sourced from committed verified baseline. Durably
   save and verify an original dirty draft before request creation; abort fully
   on failure and preserve it without writer cleanup on success/failure. Capture
   original objects, ID, seal, committed source/settings, label/custom and raw
   store; revalidate before native mutation, before store commit and final
   verification. Reuse existing writer create transaction and ID allocation.
   Add exact suffix derivation, custom-bit policy and stale-origin selection
   behavior. No label repair/fallback path exists.
4. Add failure injection at every store/writer phase. Verify phrase preimage,
   tool-data bytes, inventory, original source/label/draft/selection and recovery
   blocker on uncertainty. No blind overwrite.
5. Search all create callers and confirm duplicate is the only new operation
   intent; ordinary New/create remains unchanged and protected.
6. Run affected clipboard, label, writer, request, store candidate and draft
   suites under section 10.7.

**Exit:** copy alone never writes/creates; paste is one normal edit; label-only
failure leaves prior accepted history/state unchanged with an unresolved field
attempt, while mixed edit failure retains a dirty local edit without claiming
durable save; duplicate authorization is rechecked through final verification,
and duplicate never proceeds if original dirty draft cannot be durably saved.

### Gate 7 — Extended operations and bounded Decoded

**Depends on:** Gates 1–6.

1. Implement scoped Clear/transform operations in `model.sequencer` or existing
   cohesive source-operation owner. Keep one validator/equality and avoid a
   broad command framework. Implement the exact Reset contract and the All-32
   TIME candidate path without changing direct `set_time` bounds.
2. Implement Park–Miller with exact integer state transitions, one draw per
   position, explicit seed/range/weights and TIME 01 normalization.
3. Apply Clear, transforms and Reset immediately in both views. Keep randomization
   parameters inline with the scope selector. Apply the detached candidate
   through ordinary synchronous edit admission without a modal.
4. Wire mask enable/class controls through source operations. Reject empty
   enabled mask atomically. Do not make raw randomization mask-aware.
5. Bound Decoded to four rows with paging; display TIME command, consumed PITCH
   index, raw and resolved note, flags and transition. Use the same projection
   as compiler/planner. Error stays outside tabs; Jump moves only named coords.
6. Add fixtures only when shared data is consumed by tests. Include fixed random
   vectors and C-only scale cases as section 4.3/8.5 requires.
7. Run exact scope matrix, seed vectors, output policy invariance, undo/redo,
   bounded UI suites under section 10.7.

**Exit:** deterministic source operations pass all scopes and preserve unrelated
fields; preview and output share resolution; bounded view has no 32-row stack.

### Gate 8 — User documentation and native procedure readiness

**Depends on:** Gates 1–7 passing locally.

1. Inspect `README.md`, `DESIGN.md`, `ROADMAP.md`, `tests/README.md` and current
   ACID manual/acceptance records. Edit only descriptions contradicted by
   delivered implementation. The playbook remains the sole normative M5 detail.
2. Remove active schema-1 wording that would imply supported old store behavior;
   historical baseline references may remain explicitly marked historical.
3. Update existing manual procedure(s) with executable click paths and evidence
   fields from section 13. Do not create redundant new manual files.
4. Link only the canonical playbook from ROADMAP. Do not duplicate its full
   design in roadmap tables or paragraphs.
5. Run `git diff --check` and package check if runtime module
   layout/package inputs changed. Do not package merely because docs changed.
6. Report native checks not available as unverified. No implementation or native
   pass claim is inferred from procedure readiness.

**Exit:** docs describe actual implementation state; commands/checks are
recorded; no stale active schema claim or unsupported guarantee remains.

### Gate 9 — Full regression, packaging, and final evidence ledger

**Depends on:** Gates 0–8.

1. Run `./scripts/run_tests.ps1 -Tool ACID` after final runtime/docs changes.
   Record actual output and count.
2. Run `git diff --check`. Inspect full diff for unrequested runtime/layout,
   API/manifest, frozen-tool or M4.7 claim changes.
3. If runtime layout or package inputs changed, run `./scripts/package.ps1` and
   verify archive root has `manifest.xml` and `main.lua`, includes private
   modules, excludes SDK/development files. Keep output untracked.
4. Confirm all test specs are discovered, new files are behavior-named, no
   schema-1 successful fixture remains, and no obsolete UI fallback is present.
5. Complete evidence ledger with test command, pass/fail, native environment,
   exact fixture/result, and unverified checks. Never claim all bugs found or
   guaranteed behavior.

**Exit:** deterministic suite and diff checks pass; packaging passes if required;
evidence ledger is honest and complete. Native completion still depends on Gate
11 and second pass.

### Gate 10 — No code changes: acceptance preparation

**Depends on:** Gate 9. **Purpose:** prepare a clean, disposable native test
song and procedure without changing runtime code.

1. Confirm Renoise 3.5 / API 6.2 version and installed ACID build identity.
2. Create/copy a disposable XRNS with a known selected instrument, track,
   phrases and no unrelated live content at risk. Record original phrase/store
   preimages before failure injection.
3. Ensure a recovery copy exists. Do not use an unsupported/corrupt real song
   as a destructive test target.
4. Use numbered click paths in section 13. Capture screenshots/output where
   useful, but exact native observations and byte/inventory comparisons are
   primary evidence.
5. If Renoise unavailable, report Gate 10/11 pending; do not block or misreport
   deterministic implementation gates as native acceptance.

### Gate 11 — Native Renoise acceptance

**Depends on:** Gates 0–10. Execute section 13 in listed order. Each scenario
records pass/fail/unverified, host version, song fixture, exact action and
observed result. Any unsafe or uncertain rollback stops destructive testing.

### Gate 12 — Independent second-pass review and closeout

**Depends on:** all applicable deterministic/native gates.

1. Reviewer other than implementer inspects complete diff against sections 1–13.
2. Search for duplicate resolver, second writer/store/model, schema-1 successful
   decoder, old controls, stage leakage, unguarded phrase creation, direct GUI
   phrase API mutations, label in seal, stale-index audition release, and global
   RNG use.
3. Walk every test case and failure injection; map each assertion to actual
   test output. Review every `pcall`/setter uncertainty and rollback outcome.
4. Verify Gate 9 full-suite evidence applies to the reviewed runtime/test tree.
   Rerun affected checks after fixes and final full regression if code changed;
   do not repeat unchanged results. Run `git diff --check` and package check
   when inputs changed.
5. Any finding returns to the earliest affected gate. Fix and rerun that full
   gate and the entire second pass. No partial completion claim.
6. Close M5 only when deterministic gates, second pass and applicable native
   acceptance are recorded. Any host check not executed remains explicitly
   unverified and blocks claims that depend on it.

## 12. Second-Pass Search and Invariant Checklist

The reviewer checks these exact invariants; this list supplements, not replaces,
the per-gate tests.

1. Source has exactly required fields; all factories and codecs agree; raw note
   source bounds are 24..60 and key/octave controls agree.
2. One resolver returns canonical coherent resolved records; every output event
   note/key/octave agrees; source flags/index remain raw; no second quantization.
3. Disabled mask identity and enabled lower-tie behavior are tested; raw notes
   never change during resolution; mask included in source association.
4. Source/schema/history/render change was atomic; no unsupported intermediate
   states or hidden defaults remain.
   Include `control_signals` successor verification and both planner entry
   points in the call graph; retained association checks must still reject drift.
5. History is one linear log; metadata-only classification suppresses musical
   dirty/live behavior; mixed state commits atomically.
6. Schema 1 only rejects. Empty store starts new schema; malformed data cannot
   write, clear drafts, mutate phrase or fall through to New.
7. Stage is detached; changed Finish is one edit; every canonical source/settings/output/target
   mutation is guarded; cursor/view/page navigation never commits or discards.
   Completion is derived from every target marker. Equal-source Finish closes
   with no edit. Re-enter/Rename are guarded; Check cannot mark or persist.
8. Grid stage banner shows canonical values and disables editing; LAST STEP
   inactive cursor/page is retained; all PITCH positions remain editable.
9. Twelve class controls plus separate octave buttons remain; note 60 reachable
   through explicit C+ endpoint and stored/decoded coherently.
10. Audition captures host objects, resolves fresh indices, is GUI-thread only,
    releases before modal/navigation, and never guesses a removed object's index.
11. Clipboard exact payload excludes all forbidden metadata; clipboard never
    persists; paste/duplicate rely on ordinary authorization.
12. Duplicate source is committed snapshot, original draft survives, new ID is
    authorized, stale origin cannot force selection, failures retain evidence.
13. Labels are strict ASCII metadata, source ID unique, label text nonunique,
    label/custom bit roundtrips committed and pending draft states.
14. Clear/randomize parameters validate before apply; RNG vectors exact; every
    operation preserves unrelated fields and is one history/edit.
    All-32 TIME operations preserve LAST STEP while direct inactive editing
    remains blocked. Reset and duplicate custom-bit policies are exact; no
    label fallback or source-store publication before verified output remains.
15. Only `phrase_writer` writes phrases; source store remains existing owner;
    no direct UI mutation path or second transaction implementation.
16. UI is bounded native layout with accepted hierarchy, no generic scroll or
    unapproved vertical accordion. Docs separate implemented tests from actual
    host evidence.

## 13. Native Renoise Click Procedures and Evidence Ledger

These procedures are mandatory for claims about GUI, audition, persistence,
phrase contents, undo, Live Edit and host lifecycle. Lua mocks cannot pass them.
Use a disposable supported song. Stop immediately if phrase/store preimage or
rollback result is uncertain; do not overwrite evidence to continue.

### 13.1 Fresh source and shared views

1. Launch the installed ACID tool in Renoise 3.5 / API 6.2 and open the
   disposable song. Record host version, ACID build, instrument/track and song
   fixture name.
2. Select New Phrase. Confirm default source is immediately editable: 32 stored
   PITCH and TIME positions, LAST STEP 16, PITCH span 16, straight timing,
   disabled all-true mask, C/NORMAL/no flags, Untitled/noncustom label.
3. In Program set PITCH 1 to a distinctive note/flags and TIME 1..7 to
   `N,T,N,R,N,T,N`. Set LAST STEP 7, PITCH span 4. Record source values.
4. Switch Grid. Confirm same values, no prompt, no history step, no draft/write
   or Generate status. Select PITCH 17 and TIME 17 independently; verify moving
   one does not move the other.
5. Set TIME 17 to REST while LAST STEP 32, then shrink LAST STEP to 7. Confirm
   TIME selection/page remains at 17/page 2, REST is still inspectable and
   disabled for editing. Restore LAST STEP 32 and confirm value remains.
6. Inspect both pages for two rows of eight cells per memory. Resize/normal
   resolution. Confirm fixed lower workspace, readable controls/status, four-row
   Decoded paging and Recovery bounded paging. Record any fit failure; do not
   silently accept clipped controls.
7. Exercise C+ endpoint. Confirm note 60/key12/octave+1 appears in Program and
   Grid, flags persist, ordinary twelve key classes remain exactly twelve.
8. Switch Program/Grid repeatedly and compare all source values. Confirm no
   implicit source reset, history entry or Live Edit request.

### 13.2 Sequential entry

1. Begin PITCH re-entry and inspect confirmation: exact target P01..P04,
   defaults C/NORMAL, both flags off, P05..P32 preserved. Cancel once and
   compare canonical source/history/draft unchanged.
2. Confirm re-entry. Change P01, press Enter and Advance, change P02, press
   Back, modify P01, and verify only P01 marker clears. Re-enter P01 then mark
   it. Use selector to inspect P04; verify values/markers retained.
3. Restart Cursor. Verify cursor P01 and all values/markers preserved. Enter
   through P04. Verify last Enter leaves cursor P04 and completes stage.
4. Before all markers are entered, invoke a guarded action. Verify guard offers
   Discard and Stay only, Finish is disabled/absent with missing positions
   identified, and Stay is the inert default. Direct Finish activation is
   impossible. After all are entered, invoke the guard and select Finish. Verify
   Finish applies only the stage as one undo entry/draft edit; the original
   guarded command did not run. Invoke that command again explicitly and verify
   its ordinary admission path now runs on canonical source.
5. Undo then redo and inspect exact flags. Confirm R02 flags cleared only for
   positions in Re-enter PITCH span.
6. Repeat TIME stage for TIME 1..7, including NOTE/TIE/REST choices. Verify
   original PITCH flags and TIME beyond 7 survive. Confirm TIME 01 TIE becomes
   NOTE with visible normalization feedback.
7. Start a stage, switch to Grid. Verify banner, canonical values, disabled
   source edits. Return to Program and verify staged values/markers remain.
8. Native representative guards: use Undo for a local action, Generate for a
   writer action and ACID target selection for a controlled binding change.
   Across these cases exercise Finish, Discard and Stay, plus incomplete-stage
   Finish exclusion. Verify no guarded command auto-runs and navigation preserves
   stage. The complete action/decision cross-product belongs to deterministic
   tests. Separately change native Renoise selection and delete/invalidate a
   target during complete and incomplete stages: no Finish under the new target,
   no implicit reversal of host selection, and canonical draft recovery retained.
9. Close dialog or switch document while stage is pending. Confirm no modal
   commit; canonical draft persists best effort and transient candidate is gone.
10. Start another stage, select its final position immediately, and Enter.
    Confirm missing earlier markers keep Finish disabled. Fill all positions,
    edit an earlier entered position, then Enter at the final position again;
    Finish stays disabled until the changed position is explicitly entered.
11. Exercise Check before and during staging: source diagnostics and missing
    markers are distinct, and Check never marks or saves. Confirm Back/Enter
    are disabled without a stage. Test Rename and a second Re-enter through the
    guard, including explicit reinvocation after Finish/Discard.
12. Re-enter an already default span, mark every position without changing the
    candidate, and Finish. Compare history, draft and phrase revisions: unchanged.

### 13.3 Scale mask and decoded/render agreement

1. Use raw PITCH notes 30,35,37,42,59,60 at identifiable positions. Confirm raw
   values and controls before mask change.
2. In Extended / Clear enable only C. Verify expected resolved vector is
   24,36,36,36,60,60. Specifically check lower tie 30 -> 24 and 42 -> 36.
3. Inspect Decoded Start and Repeating pages. Each NOTE shows TIME command,
   consumed PITCH index, raw note, resolved note and articulation/transition.
4. Generate to disposable owned phrase. Inspect actual phrase cells against
   planned resolved notes and confirm preview and writer used same result.
5. Save/reopen. Confirm source raw notes/mask roundtrip and resolved display is
   recomputed without rewriting raw source. Disable mask and confirm original
   notes return exactly.
6. Attempt to turn off final enabled class. Confirm action rejected atomically,
   mask/source/history/store/output unchanged. Disable mask, clear all classes,
   save/reopen and confirm the disabled all-false source roundtrips exactly.
   Enabling it rejects before any output call and retains the disabled state.

### 13.4 Clipboard, labels, duplicate and failures

1. On owned phrase copy PITCH, TIME, then Both. Compare every one of 32 values
   and appropriate bounds. Change target timing/mask/output/label; paste and
   confirm excluded fields stay target values.
2. Copy only, switch target, inspect song data and phrase inventory: unchanged.
   Paste once and verify one normal edit/undo. Paste identical payload again;
   confirm no-op has no history or generation.
3. Select New Phrase but do not paste/edit. Confirm phrase count/store SOURCE
   unchanged. Paste then verify only existing authorized normal create route
   can make phrase; clipboard selection itself did not.
4. Rename committed label within and outside bounds. Confirm invalid labels are
   rejected without trimming or partial save. Rename while musical draft is
   dirty; verify committed source unchanged and pending draft source retained.
5. Inject a label-only persistence failure. Verify previous accepted label and
   history cursor remain unchanged while attempted text stays only in the
   focused field with an error. Confirm Retry revalidates and Discard restores
   accepted text; undo applies to prior accepted history. Attempt target switch
   and undo while failed text is unresolved; verify both are blocked until Retry
   succeeds or the attempted value is discarded. After discard, explicitly
   invoke the previously blocked action again; it must not run automatically.
   If failure injection leaves storage integrity blocked, verify that Discard
   Attempt does not clear that independent blocker or authorize a write.
6. Inject mixed source+label persistence failure. Verify source and label remain
   together as one local dirty edit/history state, session draft is retained,
   unsaved warning is visible, no durable-success status appears, and target
   switch is blocked. Undo restores the prior accepted pair.
7. Use ACID Undo/Redo for successful label-only rename. Confirm no phrase revision, render,
   Live Edit or musical dirty transition. Inject metadata persistence failure
   during label-only undo/redo as well: accepted label and history cursor remain
   unchanged and failed metadata is not accepted. Save/reopen after a successful
   operation; label and custom bit remain exact.
8. Duplicate a committed source while original editor has a dirty draft. Verify
   durable draft save and exact readback happen before a duplicate request. Inject
   draft save/readback failure and confirm no request, phrase insertion or store
   mutation; original editor/selection/history/draft remain unchanged. On
   successful pre-save, confirm duplicate uses committed source/settings/mask,
   gets fresh ID/seal and derived captured label, and preserves exact draft
   value/token/revision on both duplicate success and failure.
9. Change original label/source/phrase name or invalidate original phrase
   identity at each duplicate boundary if safely reproducible: before request,
   before native insertion, before store commit and before final verification.
   Verify changes before mutation abort without side effects; later changes
   trigger exact duplicate rollback or integrity block. Never silently refresh
   captured authorization. Change target during duplicate; stale UI binding must
   not select the new phrase, though verified inventory remains.
10. Use one safely available native failure case to verify host rollback/readback
    behavior; exhaustive allocation/materialization/store fault injection belongs
    to deterministic tests. Record original `tool_data` bytes and complete phrase
    preimage/inventory before action and identify the exact injected failure.
    Compare exact bytes and phrase preimage after rollback. If uncertain, stop;
    preserve recovery evidence and do not retry over the same document.

### 13.5 Clear and randomization

1. For each Clear/Transform operation in Program and Grid, select Active and
   All scope separately. Record affected positions, apply once and verify no
   confirmation appears. Inspect every changed/out-of-scope field and verify
   one Undo restores the complete prior state.
2. Verify Clear PITCH retains mask and clears flags only in scope; Clear TIME
   retains PITCH; Clear TIE differs from TIE-to-REST; Clear REST and REST-to-NOTE
   affect only R; Clear ACCENT/SLIDE preserve other flag.
3. Select Randomize PITCH and inspect inline parameters and selected scope.
   Change parameters and verify source/history/draft remain unchanged until
   Apply. Apply directly without a prompt.
   Run fixed seed 1 over pitch range 24..60; verify notes 24,28,51,40,43 for
   first five generated positions and exact canonical controls. Confirm flags
   retained and raw mask not applied.
4. Repeat the inline parameter and direct Apply checks for Randomize TIME in
   both views. Run TIME weights 2/1/1 seed 1; verify N,N,R,N,T vector, with T at TIME 01
   normalized only if it lands there and no extra draw behavior via subsequent
   expected positions. Use a testable pattern/scope to expose TIME 01.
5. Undo/redo each operation and save/reopen source, mask, labels, settings and
   draft. Confirm repeat output policy does not change raw source or RNG vector.
6. Set distinctive commands at TIME 8..32, then LAST STEP 7. Run Active and
   All-32 operations separately with undo between them. Active leaves inactive
   storage untouched; All-32 changes it as specified without changing LAST STEP.
   Restore LAST STEP 32 to inspect retained values, then save/reopen and compare.
7. From nondefault source/settings with a custom label, Reset Pattern in both
   views. Verify immediate application without confirmation. Confirm
   LAST STEP and label/custom remain, every field listed in section 8.1.13 resets,
   and one undo restores everything. Repeat Reset on identical state and confirm
   no new edit or generation. With Live Edit off, committed phrase/source remains
   unchanged until Generate; inspect pending draft separately.

### 13.6 Audition and native lifecycle

1. With valid selected instrument and non-send track, audition raw note and
   masked note. Confirm sound and source/selection/routing/phrase unchanged.
2. Listen for release under idle load and while Renoise is busy. Record actual
   observed duration variation; never report nominal 120 ms as guaranteed.
3. Start audition then open each focused dialog and navigate target/page. Confirm
   note-off is requested before modal or context change.
4. Trigger second audition; confirm first lifecycle releases before second onset.
5. If safe in disposable project, remove/switch captured track or instrument
   while audition active. Verify no note-off goes to a replacement object at
   reused index; record any cleanup failure and host uncertainty.
6. Change song and unload/close tool with audition active. Confirm cleanup path
   attempts release only against still-live captured tuple and observers/timer
   detach. A removed object is documented as best-effort, not guaranteed.
7. During PITCH staging, audition a distinctive candidate note and verify the
   canonical source, entered markers, draft and phrase are unchanged. TIME-stage
   audition is disabled. Finish/Discard follows the normal stage contract.

### 13.7 Persistence, ownership, undo, and Live Edit

1. Save and cold-reopen supported schema-2 song. Confirm committed source,
   labels/custom bits, mask, output settings and drafts restore read-only without
   automatic generation or source rewrite.
2. Use a copy of an old schema-1 song. Open it and confirm actionable
   unsupported-store diagnostic, no tool-data replacement, no phrase/source
   mutation, no draft clear and no fallthrough to New. Do not offer destructive
   conversion/reset.
3. Edit owned phrase, Generate, then undo/redo with and without Live Edit.
   Verify source/output association checks block any mismatch and last-good
   phrase remains intact. Record actual native undo behavior.
4. Verify Live Edit off: source edit saves draft, no phrase write. Live Edit on:
   real source edit uses guarded existing request; navigation, view switch,
   label-only edit and mask inspection do not request render.
5. Modify a destination phrase manually and try Generate. Confirm foreign/changed
   ownership remains blocked and source draft recoverable. Never accept by
   weakening ownership or source-association validation.
6. Test unsupported/corrupt store on disposable copy. Verify raw bytes remain
   identical and no phrase/draft mutation occurs. If readback uncertain, stop.
7. Confirm no unrelated instrument, phrase, track, routing, plugin setting,
   sample, or song setting changed.

### 13.8 Retained Renoise workflow acceptance

These requirements remain in M5 after roadmap consolidation. Update existing
user documentation in Gate 8 and record final-build observations in Gate 11:

1. Document native phrase triggering and song arrangement, transposition and
   resizing using Renoise controls. Distinguish source LAST STEP/PITCH span
   edits from manual destination phrase changes, which may invalidate ownership.
   Do not add an ACID arrangement player or imply regenerated content preserves
   arbitrary manual phrase edits.
2. In a disposable song, generate a representative phrase, trigger it using
   the supported native workflow, stop/retrigger and inspect the single-sequence
   end-to-start slide boundary. Record sound/release and continuity limitations.
   Demonstrate native arrangement/transposition/resizing and verify ACID reports
   destination incompatibility where applicable. Independent phrase switches
   do not inherit a continuity guarantee from a single-sequence loop test.
3. Distinguish stored, referenced and user-modified PITCH indicators. Stored
   means a valid retained slot (all 32); referenced means actually consumed by
   the current canonical TIME traversal, not merely inside PITCH span. Modified
   means a record differs from its accepted editor baseline in this session,
   not merely that its value differs from C. Establish the baseline on load or
   verified commit; undo/redo recomputes comparison. Editing back to baseline
   clears modified. No new persisted source bit or schema field is introduced.
   Stage markers are separate, and Grid continues to show canonical values.
   Implement indicators at Gate 3; test default-but-referenced, nondefault-but-
   unreferenced, edited-back-to-baseline, undo/redo and reload. Verify legibility
   natively with a 32-slot fixture.
4. Check responsiveness with populated multi-instrument songs and max-32
   sources: selection/page/view changes must not persist or generate, and a
   source preparation must not repeat resolution. Record observable UI stalls
   and representative fixture size; do not invent a fixed millisecond threshold.

TAP remains explicitly deferred. These retained workflow/indicator checks are
not optional and cannot disappear from closeout by replacing roadmap text.

## 14. Evidence Ledger Template and Completion Language

Fill this table with actual evidence during execution. Empty cells mean pending,
not pass. Duplicate rows as needed; do not put planned outcomes in Result.

| Gate/check | Owner/test or native procedure | Command/host/fixture | Result observed | Failure evidence / uncertainty | Status |
| --- | --- | --- | --- | --- | --- |
| Gate 0 baseline | Full ACID suite at `9d23f31` | `pwsh -File ./scripts/run_tests.ps1 -Tool ACID` | 70 specs passed, 0 failed; Lua 5.1 | No native behavior inferred; [audit evidence](../tests/acid/runtime_acceptance.md#m5-gate-0-audit-2026-11-01) | PASS |
| Gate 0 SDK/inventory/review | Existing source/runtime/GUI/test owners and pinned SDK at `9d23f31` | See linked audit record | SDK verified, inventory/snapshot owner recorded, all 70 spec dispositions reconciled; independent findings resolved | No runtime changes; all new native acceptance unverified; later gates pending | PASS |
| Gate 1 source/schema/history | Source/codec/draft specs; combined foundational exit | `pwsh -File ./scripts/run_tests.ps1 -Tool ACID` | 71 passed, 0 failed; independent provenance correction reviewed and rerun | [Foundational evidence](../tests/acid/runtime_acceptance.md#m5-gates-12-deterministic-exit-2026-11-01); native acceptance unverified | PASS (deterministic, combined with Gate 2) |
| Gate 2 resolution/compiler | Mask/interpreter/planner specs; combined foundational exit | Same combined suite and independent follow-up | 71 passed, 0 failed | Same foundational evidence; no separate Gate 1-only acceptance | PASS (deterministic, combined with Gate 1) |
| Gate 3 shell/Grid | GUI view/admission/independence/recovery/timing specs and native harness selector cutover | `pwsh -File ./scripts/run_offline_tests.ps1` | 18 groups passed, including 74 Lua specs, 0 failed; independent findings corrected/rechecked | [Gate 3 evidence](../tests/acid/runtime_acceptance.md#m5-gate-3-shell-and-grid-verification-2026-11-01); native feasibility remains separate | PASS (implementation, deterministic verification, second pass) |
| Gate 3 native feasibility | Procedure 13.1.6 before GUI-heavy continuation | Operator visual recheck of corrected build, plus native 2026-11-02 editor exercise | Program/Grid and both pages; workspace, Decoded/Recovery paging; labels/readability/reachability accepted at normal display scale; corrected Grid width stable across pitch edits | Pattern/Copy and Extended/Clear are later-gate placeholders; Gate 11 must repeat on final integrated build | PASS |
| Gate 4 staged Program | Staging/GUI/editor/draft/request specs; independent second pass; native functional harness | Full ACID suite with explicit Lua 5.1; native `editor-responsiveness`; ACID package | 72 specs passed, 0 failed; native functional checks and package passed | [Evidence](../tests/acid/runtime_acceptance.md#m5-gate-4-program-staging-2026-11-02); modal answers scripted; manual/final integrated acceptance unverified | PASS (implementation, deterministic verification, second pass) |
| Gate 5 audition | Lifecycle/GUI specs; independent second pass; native functional harness | Full ACID suite with Lua 5.1; native `editor-responsiveness`; ACID package | 73 specs passed, 0 failed; native functional checks and package passed | [Evidence](../tests/acid/runtime_acceptance.md#m5-gate-5-audition-2026-11-02); native sound, timing and manual acceptance unverified | PASS (implementation, deterministic verification, second pass) |
| Gate 6 operations | Clipboard/label/duplicate specs; independent second pass; native functional harness | Full Lua 5.1 suite; native `editor-responsiveness`; ACID package | 79 specs passed, 0 failed; native functional checks and package passed | [Evidence](../tests/acid/runtime_acceptance.md#m5-gate-6-clipboard-labels-and-duplicate-2026-11-02); manual/final integrated acceptance unverified | PASS (implementation, deterministic verification, second pass) |
| Gate 7 transforms | Source/RNG, GUI admission, Decoded specs; rotated second pass; native functional harness | Full Lua 5.1 suite; native `editor-responsiveness`; ACID package | 80 repository specs passed, 0 failed; native functional checks and package passed | [Evidence](../tests/acid/runtime_acceptance.md#m5-gate-7-extended-operations-and-decoded-2026-11-02); operator reports manual visual, keyboard and acoustic acceptance passed; final integrated acceptance remains | PASS (implementation, deterministic verification, second pass) |
| Gate 8 documentation readiness | User docs/native procedures; independent second pass | `./scripts/run_tests.ps1 -Tool ACID -LuaCommand <lua-5.1-executable>`; `git diff --check` | 77 specs passed, 0 failed; docs and procedure readiness checked | [Evidence](../tests/acid/runtime_acceptance.md#m5-gate-8-documentation-readiness-2026-11-02); no native checks performed; packaging not required | PASS (documentation readiness) |
| Gate 9 final verification | Full ACID suite, archive/source comparison, rotated second pass and diff review | `./scripts/run_tests.ps1 -Tool ACID -LuaCommand <lua-5.1-executable>`; `./scripts/package.ps1 -Tool ACID`; `git diff --check` | 77 specs passed, 0 failed; 32 source-identical archive entries; second pass passed | [Evidence](../tests/acid/runtime_acceptance.md#m5-gate-9-regression-and-packaging-2026-11-02); final integrated native acceptance unverified | PASS (deterministic verification and packaging) |
| Gate 10 native preparation | Host/build identity; disposable fixture and recovery preimages | Renoise 3.5.4 Demo / API 6.2; `./scripts/run_interactive_tests.ps1 -Scenario transport -Install -ApproveDisposableSong`; `tmp/m5-gate10-acceptance-20261102/preimages.json` | ACID 0.1 package verified in installed Tools folder; 8-track schema-2 fixture, byte-identical recovery, exact `Song.xml`/store/two phrase preimages verified; no plugin devices or sample buffers | Runner-owned smoke process required identity-checked force-stop; install restoration passed. Procedures 13.1–13.8, keyboard, audition and playback acceptance not run | PASS (preparation only) |
| 13.1 fresh source/shared views | `editor-responsiveness` native functional callbacks | Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016`; runner-owned blank song; `tmp/interactive-2b6710ae798742d384befad308f6c2c1/report.json` | 35 GUI callbacks; 12 pitch classes; five workspace tabs; independent TIME selection; Grid width 812 px and stable | Physical clicks, display-scale readability and resizing were not captured | PASS (native functional subset) |
| 13.2 sequential entry | `editor-responsiveness` Program-entry callbacks | 13.1 report; Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016` | Program-entry callback checks passed; four prompt responses were simulated | Physical key entry, modal focus and native prompt decisions were not captured | PASS (native functional subset) |
| 13.3 scale mask/decoded agreement | `editor-responsiveness` mask/Decoded callbacks | 13.1 report; Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016` | Mask rejection and C-only raw/resolved Decoded checks passed | Generated phrase-cell comparison and mask save/reopen were not asserted by this report | PASS (native functional subset) |
| 13.4 clipboard/labels/duplicate/failures | `editor-responsiveness`; `persistence-failures` | Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016`; separate runner-owned blank documents; reports `tmp/interactive-2b6710ae798742d384befad308f6c2c1/report.json`, `tmp/interactive-2cd2a90f45424e87bccb1faeb5a91e60/report.json` | Clipboard, label and duplicate callbacks plus musical Undo/Redo passed; storage proxy passed before-write, mutate/throw and third-value fault cases | Prior [Renoise metadata Undo diagnostic](../tests/acid/runtime_acceptance.md#interactive-persistence-acceptance-2026-11-02) failed; current report does not retest it. Setter faults are synthetic; full Retry/Discard and duplicate-boundary failure procedures were not exercised | PASS (native functional subset) |
| 13.5 clear/randomization | `editor-responsiveness` operation callbacks | 13.1 report; Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016` | Ten operations across Program/Grid and Active/All scopes; Undo/Redo and inactive-memory checks passed | Seed vectors use the deterministic model oracle, not an independent native RNG oracle | PASS (native functional subset) |
| 13.6 audition/lifecycle | `editor-responsiveness` audition callbacks | 13.1 report; Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016` | Onset/release, second audition and view/modal release callbacks passed | Sound and timer duration are unverified; track/instrument removal and tool unload were not exercised | PASS (native functional subset) |
| 13.7 persistence/ownership/undo/Live Edit | `editor-responsiveness`; `persistence-failures`; `recovery-labels-prepare` | Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016`; separate runner-owned documents and cold-reopened XRNS; reports `tmp/interactive-2b6710ae798742d384befad308f6c2c1/report.json`, `tmp/interactive-2cd2a90f45424e87bccb1faeb5a91e60/report.json`, `tmp/interactive-d3b6b202746e4d68908d5cd4d4182cbd/report.json` | Schema-2 source/settings/mask/label and draft roundtrip passed; read-only cold restore and explicit recovery generation passed; Live Edit source matched | Schema-1/corrupt-store GUI behavior and full ownership negatives were not exercised; the prior [metadata Undo diagnostic](../tests/acid/runtime_acceptance.md#interactive-persistence-acceptance-2026-11-02) failed | PASS (native functional subset) |
| 13.8 retained Renoise workflow | `multi-instrument-workflow` | Renoise 3.5.4 Demo / API 6.2; ACID 0.1; source `dd8e016`; runner-owned blank song; `tmp/interactive-1bd0cca6818343a58728cd47633200a0/report.json` | Three instruments, 12 phrases, 12 transactions, stable selection and four-track transport progress passed | Listening, phrase-switch continuity, arrangement/transposition/resizing, stored/referenced/modified indicator semantics and indicator undo/reload readability were not captured; performance acceptance was not gated | PASS (native functional subset) |
| Gate 11 manual procedures 13.1–13.8 | Operator confirmation | Final integrated Renoise build; procedures 13.1–13.8 | Operator confirms all eight native procedures passed | — | PASS (operator-confirmed) |
| Gate 12 independent review and closeout | Rotated second-pass review; operator closeout decision | `git diff --check`; final Gate 11 ledger review | Independent review passed; M5 closeout accepted | — | PASS |

Use precise closeout language:

1. **Implemented and deterministic tests passed** means exactly the stated
   tests ran successfully; it does not claim native playback or GUI behavior.
2. **Native checked** requires host version, fixture, action and observed result.
3. **Unverified** means not executed or evidence insufficient. Do not substitute
   “expected,” “should,” mock calls, design acceptance or prior baseline for a
   native result.
4. **M5 complete** requires all deterministic gates, independent second pass,
   full ACID suite, packaging when applicable, and recorded native acceptance
   for every applicable GUI, audition, phrase, persistence, undo and Live Edit
   claim. Any waived or unexecuted required check remains explicitly unverified;
   report partial deterministic completion only, never full M5 completion.
5. No gate guarantees absence of all bugs. Report test coverage, actual results,
   failures, rollback evidence and residual uncertainty.
