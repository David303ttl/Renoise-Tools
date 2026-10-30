# M4.7 — ACID runtime refactor and integration hardening

**Branch:** `feature/hardening4`

**Execution:** Steps 0, 1, 1A, then 2–9 are dependency-ordered. Finish each gate before starting the next; failed evidence sends work back to the responsible contract, then through affected gates again. Tests are added with the behavior they verify, not deferred to Step 7. Step 0 includes a small native feasibility gate before runtime changes; Step 8 remains full native acceptance.

**Final status:** M4 stays OPEN until native Renoise acceptance passes.

**Scope:** Post-Gate-1 dependency/policy/duplication cleanup plus runtime binding, writer safety, native synchronization, Live Edit, explicit copied-ID resolution, and source/draft recovery. Preserve sequencer/compiler semantics, timing, articulation, current persistence formats, manifest versions, and M5 layout.

## Fixed decisions and responsibility boundaries

### Current implementation gaps

Earlier audit on 2026-10-29 recorded a clean working tree. The Step 0 rerun on
the same date inspected `feature/hardening4` at `a2c25d4` (two commits ahead
of its upstream), with three preexisting staged documentation changes preserved.
Pinned SDK setup succeeded and all 34 ACID specs passed again.
**Step 0 complete (2026-10-29):** inventory, pinned API review, storage review,
34-spec baseline and native feasibility observations are recorded in the
[prerequisite feasibility record](../tests/acid/acid_m35_s_manual.md#prerequisite-feasibility-record).
The preservation and source/output association contracts below incorporate
the observed failures. Step 1 may proceed under those revised contracts;
runtime safety and M4 acceptance remain unverified.

Native follow-up on 2026-10-29 reached Renoise 3.5.4 Demo / API 6.2 through
the installed development tool. Undo of a synchronous phrase/content/source
change restored the old notes and valid seal but retained the newer valid
`song.tool_data` source. The existing loader accepted that mismatched pair
after undo and idle settlement. This is a failed foundational assumption,
not a preservation pass: seal validity, source validity and unique ID alone
do not establish a safe source/output association. The revised contract
requires independent compatibility validation or blocked regeneration, with
implementation and regression coverage assigned to Steps 1, 3 and 6 and
native acceptance assigned to Step 8.

| Current gap | Responsible gate / existing code |
| --- | --- |
| Arming already makes no render request and GUI tests assert it; preserve this through runtime cutover and prevent generation on guarded source/draft recovery | Steps 2/5: `gui.lua`, `tests/acid/acid_gui_views_spec.lua` |
| Durable draft reads/writes/clears use a sealed ID without requiring a unique live holder; Make Independent is absent | Steps 1/4/5: `model/draft_cache.lua`, `model/pattern_store.lua` |
| The persisted seal omits hidden/tail cells and some metadata; complete snapshot, preflight and destination preservation remain missing | Steps 1/3: `writers/phrase_ownership.lua`, `writers/phrase_writer.lua` |
| Retained recovery material does not establish a persistent song integrity blocker or read-only Revalidate workflow; cleanup failures need checked outcomes | Steps 3/5: `writers/phrase_writer.lua`, `model/live_regen.lua` |
| Writer accepts an omitted destination and selects phrase 1/append; staging insertion precedes busy/current registration | Step 3: `writers/phrase_writer.lua` |
| Native instrument/phrase inventory and rename reconciliation are incomplete | Steps 2/6: `gui.lua` |
| Source commit preserves current durable drafts, while GUI completion clears the target draft separately | Steps 1/3/5: `model/pattern_store.lua`, `gui.lua` |
| Undo descriptions and native undo/redo consistency acceptance remain open | Steps 3/6/8: writer and native manual checks |

Adjacent cleanup: source copying is duplicated in `model/editor_state.lua` and
`model/draft_cache.lua`. `model/memory_status.lua` has no runtime caller found;
its only code consumer is `tests/acid/acid_regeneration_spec.lua`. Treat it as
a candidate for test-helper relocation or removal after checking its assertions,
rather than assuming a runtime responsibility. Neither cleanup satisfies a
write-safety gate.

This plan retains the existing asynchronous phrase-script renderer, staging/backup transaction, and song-local source/draft store. It does not require a new renderer, persistence layer, event bus, general transaction framework, or controller hierarchy.

| Responsibility | Single owner / existing home |
|---|---|
| Active target, session/revision checks, native reconciliation | One runtime context used by `gui.lua`; consolidate existing state, adding a small private module only if needed |
| User controls and presentation | `gui.lua`; widgets dispatch user actions and render state |
| Serialized generation and cancellation | Existing `model.live_regen` and writer job lifecycle; reuse them behind one request entry point |
| Phrase mutation, staging, backup, verification, cleanup | `writers.phrase_writer`; two explicit musical operations sharing private helpers |
| Ownership parsing, seal, complete phrase comparison | `renoise.phrase_ownership`; no second ownership implementation |
| Canonical source/settings and durable draft serialization | `renoise.pattern_store`; preserve its format and guarded commit/restore helpers |
| Object-keyed session drafts and restoration precedence | `runtime.draft_cache`; preserve existing durable drafts where unambiguous |

Validation at the request boundary and writer boundary is intentional. Share pure validation helpers; the writer still checks live membership and ownership independently. Ownership inventory has no exclusions: writer-private temporary objects must be neutral before validation or asynchronous waits; their registry filters UI choices and identifies cleanup/recovery objects only.

**Ownership is two coordinated pieces:** the current ID/seal in `phrase.name`, and canonical source plus output policy/PB range under that ID in `song.tool_data`. A phrase does not carry its own complete source record. Same-song copies may retain a name referencing the shared song record; cross-song or imported instrument copies may have no such record. Never infer source from matching notes.

The current-song ID record and valid seal identify a candidate source association. Musical writes and Make Independent additionally require independent source/output compatibility validation; validity of each piece alone is insufficient after the observed undo mismatch. This does not prove physical provenance. An imported phrase with a unique valid ID and compatible output matching an existing local record is indistinguishable from an existing owner under this format. Do not promise detection of that case without new provenance data, which is outside scope. Missing records always block; duplicate groups use the stricter resolution checks below.

**Copy policy:** native list notifications do not prove copy provenance. This work adds **no automatic re-keying**. Duplicate IDs block musical writes for all holders until the user selects a particular phrase and invokes **Make Independent**. That action changes its ownership name and clones its committed source/settings under a fresh ID; it never renders. Source-less imports remain Foreign; importing/adopting them is outside scope. Do not add provenance snapshots or heuristic copy detection.

**Live Edit policy:** retain immediate, serialized edits with one latest pending request; do not introduce a debounce timer. The roadmap uses this same policy.

## Invariants and target behavior

1. Browsing, opening/reopening, arming Live Edit, list changes, renames, and native selection notifications never authorize musical writes or identity repair.
2. Only Generate or an actual source/settings edit while Live Edit is armed requests create/regenerate. A no-op edit does not. Make Independent is its own explicit action.
3. Targets carry live song/instrument/phrase objects. Use `rawequal` for host-object identity, including membership, selection pairs, returned destinations, and cleanup; phrase `==` compares line content, not identity. Preserve existing raw-identity checks and object-keyed tables. Resolve indices immediately before documented indexed API calls; never persist an index as object identity.
4. Regenerate changes only the exact validated owned destination. It never falls back to create, another object, or another instrument.
5. Temporary staging/backup insertions are permitted inside an authorized writer job for both modes. They are not new owned destinations. Successful create leaves exactly one extra phrase; successful regenerate leaves phrase count and destination object unchanged.
6. A stale operation cannot commit destination/source changes or update a newer GUI session. Cancellation may perform narrowly scoped rollback/cleanup of that job's own objects while its song is still current.
7. No native selection property is assigned. Structural operations may change Renoise selection; reconcile that fact without treating ACID's own changes as user navigation.
8. Ambiguity, external modification, removal, invalid source, or failed rollback blocks writing and preserves recoverable drafts.
9. One musical request pipeline and one writer transaction serve manual Generate and Live Edit. Observers only invalidate/reconcile; they never render or re-key.

| ACID target | Navigation / arming | Generate | Real edit with Live Edit armed |
|---|---|---|---|
| New Phrase | Restore instrument scratch draft; no write | Create in that explicit instrument | Create; bind returned phrase after success |
| Owned | Validate committed source; restore matching dirty draft first | Regenerate exact phrase | Regenerate exact phrase |
| Foreign | Show reason; retain outgoing editor draft | Block | Keep edits recoverable; no musical write |
| Unavailable | Preserve detached draft and explain reason | Block | Keep edits recoverable; no musical write |

Owned requires a valid current seal, valid song source/settings, independently verified source/output compatibility, song-wide unique ID, and the content checks below. A recognized ID with a collision, corrupt/missing record, incompatible or unverifiable source/output association, or changed content is Unavailable; content with no recognized ACID identity is Foreign. A copied/imported phrase with no local source is never adopted, regardless of which blocked label applies.

## Step 0 — Inventory, verify API constraints, and fix the plan inputs

1. Inspect `git status --short --branch`, `git diff --stat`, `git diff`, and latest commit on `feature/hardening4`. Preserve all user work; do not reset, stash, or overwrite it.
2. Run `./scripts/setup_sdk.ps1`. Read the pinned definitions **and offline docs** listed below. ACID stays on Renoise 3.5 / API 6.2 and Lua 5.1-compatible syntax.
3. Map current writer callers, insert/delete/copy operations, script compile/render callbacks, native selection accesses, source/draft writes, notifiers, idle handlers, close/reopen, and undo. Assign each to the responsibility table. Mark existing behavior verify/correct/complete rather than adding parallel paths.
4. Confirm current storage directly in `phrase_ownership.lua`, `pattern_store.lua`, and `draft_cache.lua`. Preserve format identifiers and existing strict parsing. Native copy behavior is not an automatic-adoption prerequisite: every observed collision uses deliberate resolution, and missing source always blocks. Run the feasibility checks below now; full copy/save/undo acceptance remains in Step 8.
5. Run `./scripts/run_tests.ps1 -Tool ACID` and record the baseline. Resolve relevant baseline failures before proceeding; distinguish unrelated existing failures explicitly.
6. Update the existing M4.7 roadmap section with this sequence and fixed policies, removing conflicting debounce/automatic-copy claims in scope. Do not create a second task section. Keep a compact gate checklist, not an experiment history.

**Pinned API constraints to carry into implementation:**

| API 6.2 reference under `sdk/renoise-api-6.2/` | Required constraint |
|---|---|
| `definitions/library/renoise/song.lua`; offline `docs/API/renoise/renoise.Song.html` | Selected instrument/phrase objects and indices are read-only. Use `selected_instrument_observable` and `selected_phrase_observable`; there is no documented selected-phrase-index observable. `song.tool_data` is bundle-specific song data, accessed from the installed tool, not an arbitrary terminal script. |
| `definitions/library/renoise/song/instrument.lua`; offline `docs/API/renoise/renoise.Instrument.html` | Phrase capacity is `renoise.Instrument.MAX_NUMBER_OF_PHRASES` (126 in this SDK). `insert_phrase_at(index)` returns the inserted phrase; `delete_phrase_at(index)` deletes by current index. |
| `definitions/library/renoise/song/instrument/phrase_script.lua`; offline `docs/API/renoise/renoise.InstrumentPhraseScript.html` | Set script paragraphs, call `commit()`, observe committed notification before `render_to_pattern(options, callback)`. Compile errors update **after** committed notification; no separate compile-complete event or fixed latency is documented. Render callback results and output validation determine success; observed native settlement is recorded below without a latency guarantee. Clipboard rendering is not a synchronous payload API. |
| `definitions/library/renoise/song/instrument/phrase.lua`; offline `docs/API/renoise/renoise.InstrumentPhrase.html` | Use documented property observables and `add_line_notifier` / `remove_line_notifier`. Keyboard-only line-edited callbacks do not cover all mutations. Phrase equality compares line content and ignores other properties; use `rawequal` for identity. `copy_from` is not a promise of native copy provenance, complete metadata coverage, or source-data transfer. |
| `definitions/library/renoise/tool.lua`; offline `docs/API/renoise/renoise.ScriptingTool.html` | Release runs while old song is current; new-document attaches to the new song. Idle interval is unspecified. Keep stable notifier identities and detach at lifecycle boundaries. |
| Song definitions/docs; `definitions/library/renoise/document/observable.lua`; `docs/API/renoise/renoise.Document.ObservableList.html`; `docs/guide/observables.html` | List changes do not observe item renames. `is_undo_redoing()` identifies undo/redo processing. `describe_undo` / `describe_batch_undo` describe/batch changes; they do not guarantee cross-callback atomicity. |

**SDK verification (2026-10-29):** `setup_sdk.ps1` succeeded against the installed pinned starter pack. The definitions and offline pages above were read together. Phrase equality is specified in `phrase.lua` under operators (line content only), but omitted from the generated phrase HTML. `copy_from` documents only copying contents, without field-by-field guarantees. The mapping reference has no explicit read-only annotation in either pinned reference; avoiding reference assignment is a preservation policy, not a verified access restriction. The observable guide demonstrates song-specific reattachment and name observation; the explicit layout-only list contract is in the ObservableList references. These sources establish signatures and restrictions, but do not establish native copy coverage, notification ordering, compile settlement latency, or cross-callback undo consistency. Native observations are recorded separately below.

**Native qualifications (2026-10-29, Renoise 3.5.4 Demo / API 6.2):** The
[feasibility record](../tests/acid/acid_m35_s_manual.md#prerequisite-feasibility-record)
records the observed exceptions. `copy_from` did not create a backup mapping;
destination mappings survived copying, so snapshot and independently verify
their fields rather than treating the backup as complete. Inactive script
copying lost the committed/editor distinction and parameter override after
settlement. Reject nonempty inactive scripts, parameters or pending changes
unless their complete preservation is independently demonstrated; this may
block existing generated targets and must remain visible. Native assignment
to `script.editor_visible` was rejected as read-only despite the SDK annotation;
do not assign it. Commit/error/render timing varied across runs; callback
results remain authoritative and ambiguous notification origin requires
cancellation. Undo exposed the source/output mismatch described above.

**Native feasibility before Step 1:** Use an installed development tool and disposable XRNS, with temporary probes kept outside runtime/package inputs. Record host/API version, fixture, observed values, pass/fail, and chosen fallback in the existing manual-test guidance. These are prerequisite observations, not acceptance of unimplemented operations.

- Put distinguishable sentinel values in every Step 1 field category. Exercise destination-to-backup, stage-to-destination, and backup-to-destination copies; compare complete values after each operation, including hidden/tail cells, mapping presence/fields, column metadata, and inactive script state. Check object identity separately with `rawequal`. Never change playback mode merely to inspect a script. If data cannot be safely inspected/preserved, establish a detectable preflight rejection before implementing regeneration for that target.
- Observe insert/copy/name/delete notification order and native selection effects, including delayed delivery outside a synchronous mutation scope. Observe committed notification, compile/runtime error updates, and render callback settlement. If origin cannot be distinguished, cancellation is the fallback; do not infer an API timing guarantee from one run.
- Exercise phrase/name and `song.tool_data` mutations together and across idle callbacks, then undo/redo every intermediate state, including an intervening native action. Establish whether inconsistent states are detectable by the planned ownership/source validation. If a partial state can silently authorize writes, revise the transaction contract before proceeding. Do not assume a valid seal proves that a different but valid source record produced the phrase.

**Gate 0:** Call sites, baseline, storage, API signatures, fixed policies, and native feasibility outcomes are known. Any missing SDK/API evidence is resolved from the official API-6.2 sources before runtime changes; do not substitute newer online docs or guessed members. If native access is unavailable, record the gate as pending and stop dependent runtime implementation; documentation and pure feasibility preparation do not count as a native pass. Unsupported fields may be blocked only through an explicit, tested preflight predicate; failure of a foundational undo/lifecycle assumption requires revising this plan, not silently weakening acceptance.

**Gate 0 disposition: complete.** Native feasibility has been performed;
completion records the following decisions, not a pass for the current runtime.

| Finding | Required contract / implementation gate | Acceptance gate |
| --- | --- | --- |
| Backup omits mapping; destination mapping survives copying | Steps 1/3: snapshot and independently verify mapping presence/fields before mutation and rollback; reject unpreservable targets | Steps 3/8: exact mapping preservation and rollback |
| Inactive script copy loses committed/editor state and parameter overrides | Steps 1/3: use the natively tested rejection predicate for nonempty paragraphs, parameters, pending changes or failed access; do not promise regeneration for rejected targets | Steps 1/3/8: mutation-free rejection, or separately proven complete preservation |
| Selection/notification origin and render latency are not guaranteed | Steps 2/3/6: reconcile object identity, cancel ambiguous work, use authoritative render results and output validation | Steps 6/8: internal/external notifications and native lifecycle |
| Undo can leave an old valid seal with a newer valid source; async grouping was not established | Steps 1/3/4/6: independent read-only source/output compatibility validation before regeneration or Make Independent, block unknown/mismatching associations, and retain meaningful undo requirements | Steps 1/6/8: incompatible pairs rejected after undo and reload; real transaction undo/redo and intervening actions |

No schema/version change, automatic repair, source inference from notes, or
relaxed native acceptance follows from this disposition. The next gate must
implement these contracts before its consumers can authorize writes.

## Step 1 — Establish shared validation and storage contracts

**Clean cutover:** replace competing runtime paths; do not add legacy readers,
migrations, automatic adoption, or compatibility fallbacks. Keep the current
persisted format identifiers and strict decoder. An unsupported existing target
is blocked, with its valid source available for explicit recovery to New; it is
never rewritten to make it acceptable. Keep the existing transaction, compiler
and module owners. The only additional module justified here is a small pure
output planner extracted from duplicated writer/validation responsibilities.

**Execution order:** complete 1.1–1.8 in order. Add and run focused tests with
the owning substep; do not defer them to 1.8. Each completion check is required
before advancing. This sequence changes contracts/helpers only; runtime context,
writer integration, Make Independent and GUI wiring remain Steps 2–6.

**Responsibility reference:** use these owners throughout the sequence.

| Owner | Contract consumed by later steps |
| --- | --- |
| `phrase_ownership` | Parse names; build the song-wide ID inventory from names; capture detached value snapshots; compare snapshots; check supported fields and hidden/tail emptiness. Keep persisted seal calculation unchanged. |
| `pattern_store` | Strict source/draft decoding, narrow validated entry read, unique-live-target load, candidate preparation/commit/restore, and guarded durable draft access. No dependency on the writer or GUI. |
| Pure output planner | Extract the existing physical layout, articulation/gate fallback, native legato and volume planning once; return expected final output without host writes or rendering. Generation and compatibility use this same implementation. |
| `phrase_validator` | Compare a live phrase against complete planner expectations and preservation policy; return success or a concrete rejection reason. No source-store writes or baseline adoption. |
| `draft_cache` | Object-keyed session drafts, captured baseline/revision, durable-store delegation, detached recovery list/copy/discard. No second serializer or ownership implementation. |

Keep source loading and compatibility validation separate to avoid a store/writer
dependency cycle. `store.load` returns a candidate source association, not write
authorization. The shared classification path combines it with the validator;
the writer independently repeats those checks immediately before mutation.

### 1.1 — Prove script-free staging feasibility

**Status:** passed; see the [script-free staging feasibility record](../tests/acid/acid_m35_s_manual.md#script-free-staging-feasibility).

**Depends on:** completed Step 0 and its pinned API/native feasibility record.
Use disposable native probes outside runtime/package inputs, not a partial writer
implementation. The field matrix in 1.5 defines the values to compare.

**Action:** use a disposable probe to exercise the proposed sequence below,
including equivalent create/regenerate copies; production writer integration is
not required to run it. Keep the single staging phrase and existing slot budgets.
After its render callback has completed and
output is validated, clear only this job's generated script via documented
`paragraphs` assignment and `commit()`, with existing lifecycle guards and
commit-wait handling. Never clear a user destination's script. Before any
promotion/copy, require the empty-script predicate and verify that all rendered
cells/settings are unchanged. The committed notification alone does not prove
settlement. A disposable native probe must establish the exact empty assignment,
notification/settlement sequence, preservation of pattern data and readable editor
state, and absence of later script/parameter reappearance through idle and
save/reload. Establish the canonical empty snapshot and prove stage-to-destination,
destination-to-backup and backup-to-destination preserve it exactly, including
readable editor state. Then prove create → regenerate twice uses the same
destination and passes preflight. Record the exact sequence in the existing feasibility record.
No fixed delay, guessed setter, second publication phrase or extra slot is
authorized. If this path fails or cannot establish stable empty state, stop and
revise the renderer/publication contract before dependent writer implementation;
do not accept a workflow that blocks its own next regeneration. Gate 0's earlier
completion does not supply this newly required evidence.

**Complete when:** the existing feasibility record contains host/API version,
fixture, exact API sequence, canonical empty-script snapshot, copy/rollback and
save/reload observations, with all required checks passing. A failed or unavailable native check
blocks this substep and dependent implementation; pure tests cannot replace it.

### 1.2 — Implement immutable source values and content snapshots

**Depends on:** 1.1's proven canonical script state. Work in existing model and
ownership owners; use the exact field matrix in 1.5 as the shared reference.

Consolidate canonical source copying/equality in an existing model module and
reuse it in editor history, drafts, candidate inputs and recovery. Freeze candidate
inputs at preparation; later caller mutation must not alter a prepared write.

Snapshots contain copied scalar values/arrays, no live line, cell, mapping or
script references. Read failures reject safely. Use one exact value comparator
with explicit allowed differences: none for target/rollback; ownership name
only for Make Independent; generated fields only for successful regeneration.
Do not use a hash, host equality, or mutable snapshot as a substitute.

**Complete when:** focused tests prove deep-copy isolation, deterministic exact
comparison, detection of every captured field change, allowed-difference policies,
and rejection on required read failure. No host references remain in value snapshots.

### 1.3 — Implement live identity and guarded source/draft access

**Depends on:** 1.2's copying/comparison helpers.

1. Require raw-identity membership of the supplied instrument and phrase in the
   current song and exactly one live holder of the ID, which must be that phrase.
   Normal load rejects zero/multiple holders across the **entire song**, including
   other instruments. Step 2 removes legacy exclusion parameters: every live phrase counts; writer temporaries must have neutral non-owner names before validation. Cache
   the name inventory only until invalidated; do not hash every phrase during
   ordinary list refresh. Rebuild/recheck at transaction boundaries.
2. Provide a narrow entry read by explicit ID for Make Independent. It validates
   and copies the saved source/settings but makes no ownership claim. Every
   collision holder still undergoes Step 4's group checks. Missing/corrupt data
   rejects without mutation; never guess an original holder.

Put raw membership and uniqueness checks inside durable draft get/put/clear too;
never let an invalid existing phrase become the New scratch ID. Keep New scratch
within the current format's live-instrument/index/name and unique-name restrictions.
The candidate commit/removal rules are implemented in 1.6.

**Complete when:** tests cover detached objects, same-index replacements,
song-wide collisions, legacy temporary-exclusion behavior (removed by Step 2), missing/corrupt entries,
narrow collision reads without ownership, and blocked durable get/put/clear.

### 1.4 — Extract the shared pure output planner

**Depends on:** 1.2's immutable source inputs and 1.3's validated source reads.

The planner takes copied canonical source, output policy, PB range, documented
native capacities, and an explicit read-only receiver capability profile. Reuse
the existing instrument inspection; do not infer receiver type from notes. Its
result includes semantic plan, layout, complete final note/effect expectations,
volume expectations, and required column/subcolumn visibility. Include the
existing glide/gate collision fallback and native overlapping-note/PB path.
Expected values must be derived from those inputs, never from destination values
being checked. Unknown or failed receiver reads block when they affect output;
receiver-independent plans need no irrelevant receiver assumptions.

Extract the existing writer planning once and redirect its planning call to that
helper; preserve its public runtime behavior until Step 3. Do not add a second
planner or begin transaction/GUI integration here.

**Complete when:** planner tests preserve repeat/play-once, supported timing modes,
notes/rests/ties/accent, glide/gate fallback, native overlap and PB expectations.
Unknown required receiver inputs reject. Planning performs no render or host write.

### 1.5 — Implement complete compatibility and field preflight

**Depends on:** 1.1's native script evidence, 1.2's snapshots, 1.3's source/identity
checks and 1.4's shared expected output. This field matrix is also the reference
for 1.1 probes and 1.2 snapshot coverage; it is not a second execution sequence.

Validate the **saved committed** source/settings against the existing phrase
before planning a proposed edit. A dirty draft is never the expected source for
this check. Preserve existing timing, articulation and fallback semantics when
extracting the planner; do not invent a second compiler.

The unchanged store has no historical receiver profile. Use current explicit
inputs and require exact output equality; changed receivers that produce a
different plan block. This proves current output compatibility, not provenance
or audible receiver behavior. Different sources with identical expected output
remain indistinguishable. On undo, reopen and reload, re-run this check; never
seed trust from a valid seal plus valid source. A session cache is usable only
while the exact source/settings, complete content and planning inputs still
match its previously verified values.

Strengthen the existing validator rather than treating its current visible-only
and partly optional checks as proof. Require every expected cell field, generated
property, sentinel and unused cell to match. No render, playback-mode probe,
native setter or store mutation is permitted during classification. Unsupported
or unprovable cases block and preserve recoverable source.

Inspect the pinned definitions **and offline docs** for each member before use.
Read `phrase:line(1..MAX_NUMBER_OF_LINES)` and every available note/effect column,
not only visible columns or active lines. API 6.2 documents those full bounds.
Use documented cell `is_empty` for emptiness and exact numeric fields for value
comparison; a cell with only ancillary data is not safe merely because its note
is empty. Before regeneration reject nonempty hidden cells or cells beyond active
length. Successful output must also leave all unused/hidden/tail cells empty.

| Category / exact values captured | Successful regeneration / comparison |
| --- | --- |
| All note cells: `note_value`, `instrument_value`, `volume_value`, `panning_value`, `delay_value`, `effect_number_value`, `effect_amount_value`; effect cells: `number_value`, `amount_value` | Compare every value to final planner expectations, including emptiness outside generated output. Preserve existing musical semantics. |
| `number_of_lines`, `lpb`, `shuffle`, `looping`, `loop_start`, `loop_end`, `playback_mode`, `key_tracking` | Replace with validated layout/writer values; final playback is `PLAY_PATTERN` and phrase tracking is `KEY_TRACKING_NONE`. Check loop/layout invariants explicitly. |
| `base_note`, `autoseek`; all note-column names/mutes through `column_name` / `column_is_muted` and documented setters | Preserve exact destination values. Create uses existing writer defaults, captured and verified explicitly. |
| `visible_note_columns`, `visible_effect_columns`, `instrument_column_visible`, `volume_column_visible`, `panning_column_visible`, `delay_column_visible`, `sample_effects_column_visible` | Preserve destination visibility only if it exposes every column and nonempty subfield required by planned output. Reject insufficient visibility before mutation; do not silently expand it. Create exposes required output. |
| Mapping presence and `key_tracking`, `base_note`, `note_range`, `looping`, `loop_start`, `loop_end` | Preserve the same destination mapping and exact values. Initially support mapped regeneration only when planned line count is unchanged, matching the native preservation evidence. Reject mapped length changes. Verify after copy and rollback independently of backup, which lacks the mapping. Never assign the mapping object or invent undocumented endpoint ranges. |
| Inactive script paragraphs, parameter list/values, pending changes, readable editor state | Existing targets pass only the tested empty-script predicate below. Do not modify a target script, assign `editor_visible`, or toggle playback to inspect it. A script-bearing stage cannot be copied/promoted as successful output. |
| Ownership name; committed source/settings | Replace under the guarded transaction; verify seal, ID, exact saved source/settings and independent output association. Preserve unrelated entries. |
| Session/durable drafts | Remove only the captured committed draft under the preconditions below. |

Visibility requirements are minimums: extra visible columns are allowed only
when their cells are empty. Replace the current validator's exact native-column
count restrictions accordingly. Derive subcolumn requirements from meaningful
nonempty values using documented defaults (instrument/volume/panning 255,
delay 0, effect number/amount 0); expose the instrument/panning carrier and
effect command fields where the PB plan uses them.

Rollback compares every captured category including the original ownership name;
Make Independent compares every category except that name. Backup validation
must account for the deliberately neutral backup name and absent mapping, while
the original mapping is checked on the destination. Do not weaken destination
rollback comparison to match backup omissions.

**Script predicate:** reject any paragraph containing non-whitespace text, any
parameter, nonzero `pending_changes`, or failed required access. Nonempty inactive
scripts are unsupported even if generated by the current implementation; no
legacy exception, script recognition heuristic or automatic target cleanup.
This tested predicate is necessary, not sufficient for exact preservation:
accepted targets must also match the native-proven canonical empty script
snapshot, including paragraph representation and readable editor state. Reject
other whitespace/editor variants rather than normalizing a user destination.

**Complete when:** tests reject valid-seal/valid-source mismatches after simulated
undo and fresh-session load, use committed source despite a dirty draft, detect
each changed output/preserved field, and reject hidden/tail data, insufficient
visibility, mapped length changes and unsupported script variants. Classification
performs no host mutation; complete expected output is shared with generation.

### 1.6 — Implement guarded store candidates and atomic draft removal

**Depends on:** 1.2's immutable values, 1.3's access guards and 1.5's validation
contract. Accept a request guard as an argument; use a stub in focused tests.
The runtime supplies it in Step 2, without a store dependency on the GUI/cache.

1. Keep a simple candidate: captured source-map values, proposed source-map
   values, and optional captured draft removal. Metadata-only Make Independent
   has no draft removal. Use the existing decoder/encoder for canonical value
   comparison; no generic merge engine, persistent revisions or new schema.
2. A removal captures destination objects/kind, old ID or New scratch key,
   instrument index/name at capture, exact durable draft value or absence, and
   session draft token/edit revision. The request guard supplies the current-token
   check; the store must not import `draft_cache` or inspect GUI state. Distinguish
   a missing draft from an empty source. Revisions are session-only and prevent A → B → A value equality from
   clearing a newer edit. No invalid existing phrase may fall through to ID zero
   (New scratch).
3. At commit, require the request guard and unchanged captured source map. Rebase
   **current** durable drafts, then remove only the captured record when its exact
   value and session revision still match and its live destination is unambiguous.
   A changed draft or changed scratch slot/name is preserved, never relocated by
   name/index guessing. A newer editor revision invalidates the musical request
   through Step 2's guard; the store also preserves mismatching records defensively.
   An absent captured record cannot authorize deletion of a subsequently added one.
4. Re-read raw `tool_data` immediately before assignment and require it still
   equals the raw value used to build this rebased candidate. Perform no yield or
   user callback inside compare/write/verify. Record the exact previous and
   intended write raw values **before calling the setter**, so a setter that
   mutates then throws still leaves guarded rollback evidence. Verify persistence
   after assignment; failed/uncertain readback retains an integrity blocker.
5. Restore only when current raw equals the transaction's written candidate;
   already equal to previous raw is a successful no-op. Otherwise preserve newer
   data and return an integrity-blocking failure. Failed writes may have changed
   host data: inspect/verify rather than assuming an exception means no mutation.
6. Every durable draft get/put/clear enforces the same raw membership and unique
   live-holder predicate in the store boundary. Duplicate IDs never read, replace,
   move or clear the ambiguous durable record, including during Make Independent.
   New scratch requires the captured live instrument, unchanged index/name and
   existing unique-name checks. Session drafts remain available when durable
   access is rejected; report the existing persistence/loss warning.

**Complete when:** tests prove current-draft rebasing without target resurrection,
exact captured removal, preservation of unrelated/newer/equal-valued newer drafts
and captured absence, safe New scratch handling, frozen candidate inputs,
Make Independent without draft removal, and guarded rollback after partial writes.

### 1.7 — Implement session draft baselines and recovery operations

**Depends on:** 1.2's copied values, 1.5's verified baselines and 1.6's store
preconditions. Use stub validation/guard inputs in focused tests; do not wire widgets.

Validate committed ownership/source/output first; only then restore a dirty
object-local draft whose captured ID, source/settings and complete content
baseline still match. Otherwise detach it; do not silently rebase it. With no
matching draft, use committed source. New restores only that instrument's scratch.
The unchanged durable format has no historical baseline/revision: after reload
read only against a uniquely owned, currently verified matching ID and label the
result recovered edits. This is the sole current-format path, not a migration or
a claim of historical verification.
On first restore, copy a durable draft into an object-local session record with
a fresh token and the currently verified baseline. This captures current state
only and supplies exact-revision bookkeeping; it invents no historical baseline.

`draft_cache` provides narrow detach/list/copy/discard and compare-and-clear
operations. Detached entries use session-local tokens and copied source/settings,
value baselines, scalar display labels and reason; no retained host references
inside recovery payloads. Labels never identify a destination. Collision drafts
are object-local/session-only; never import their ambiguous durable record.
Copy to New returns a copy and recovery token, keeps the original, and preserves
an occupied outgoing scratch as another entry. Only successful create of that
exact copied revision or explicit discard removes the original. Dialog close
retains session drafts; document release drops old-song associations/recovery
with the volatile-loss warning. Reload restores only safe durable records.
GUI actions and widgets remain Step 5's responsibility.

**Complete when:** tests prove precedence, current-baseline hydration of durable
recovery, detachment on baseline changes, collision isolation, copy/discard
isolation, occupied-scratch preservation, exact-revision clearing, and the stated
close/release lifetimes. No ambiguous durable record enters recovery.

### 1.8 — Close Gate 1 and hand contracts to runtime integration

**Status:** complete. Steps 1.1–1.7 and the independent second-pass review pass.
The ACID suite contains 41 passing specs; the full repository suite contains 44.
Runtime integration and native playback/lifecycle/undo acceptance remain in
Steps 2–8; M4 remains open.

| Contract / focused cases | Verification | Result |
| --- | --- | --- |
| Canonical empty script, complete native copy/rollback, same-object repeated regeneration and save/reload | [Native feasibility record](../tests/acid/acid_m35_s_manual.md#script-free-staging-feasibility) | Pass: Renoise 3.5.4 Demo / API 6.2 |
| Detached canonical source values, exact comparison and frozen candidate inputs | `tests/acid/acid_source_values_spec.lua` | Pass |
| Raw/current membership, replacements, song-wide collisions, narrow entry reads and durable draft guards | `tests/acid/acid_live_identity_spec.lua`, `acid_phrase_persistence_spec.lua` | Pass; Step 2 must remove legacy exclusion arguments/tests; Step 3 verifies neutral temporary identities without inventory exceptions |
| Shared repeat/play-once and straight/triplet planning, notes/rests/ties/accent, glide/gate fallback, overlap/PB and unknown receiver rejection | `tests/acid/acid_output_planner_spec.lua`, existing articulation/legato/timing specs | Pass |
| Complete cell/property/mapping/script snapshots, allowed differences, read failures, committed-source mismatch after undo/reload, visibility and hidden/tail preflight | `tests/acid/acid_phrase_snapshot_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_legato_writer_spec.lua` | Pass |
| Atomic captured draft removal, current-draft rebasing, absence/newer/equal-valued revisions, New slot preservation, metadata-only writes, partial setters and guarded restore | `tests/acid/acid_store_candidate_spec.lua`; native store helper smoke in the feasibility record | Pass |
| Direct durable draft writes classify verified success, unchanged storage, partial mutation and unreadable readback | `tests/acid/acid_live_identity_spec.lua` | Pass |
| Verified draft precedence, current-format hydration, baseline detachment, collision isolation, recovery copy/discard, occupied scratch, exact-revision clearing, captured New binding/unique-ID guards, authorized content regeneration and close/release | `tests/acid/acid_draft_recovery_spec.lua`, `acid_draft_cache_spec.lua`, existing GUI/repeat specs | Pass |
| Packaging and clean cutover | One private planner; unchanged manifest/seal/store identifiers; archive roots and development-file exclusions checked | Pass |

**Depends on:** completed 1.1–1.7. Review the one shared planner and existing module
owners for competing paths or circular dependencies. Run
`./scripts/run_tests.ps1 -Tool ACID` in PowerShell 7 after Lua changes.

**Gate 1:** Map focused cases to existing specs, adding behavior-named specs only
where needed. Pure helpers use value fixtures; host access uses API-shaped mocks.
All of the following must pass before dependent runtime integration:

- Normal load and durable get/put/clear reject detached objects, same-index
  replacements, duplicates in other instruments, missing/corrupt records and
  invalid-existing-phrase-to-New fallback; narrow collision read grants no ownership.
- A valid seal plus valid incompatible source rejects, including simulated undo
  and fresh-session/reload. Dirty draft does not replace committed expectations.
- Shared planning preserves repeat/play-once, supported timing modes,
  notes/rests/ties/accent, glide/gate fallback, native overlap and PB behavior;
  unknown required receiver inputs reject. No render or host mutation occurs.
- Mutating each cell field, generated property, sentinel, hidden/tail cell,
  mapping field or preserved metadata is detected by the appropriate comparator.
  Insufficient visibility, mapped length changes and unsupported scripts reject
  before mutation. Read failures do not seed a baseline.
- Candidates preserve unrelated sources/current drafts, remove the matching
  committed draft atomically without reintroduction, preserve newer/equal-valued
  newer drafts and newly added records, and preserve relocated New scratch.
  Make Independent never removes an old-ID draft. Guarded restore refuses newer
  store data; injected partial writes produce checked outcomes.
- Draft baselines detach on source/content changes; recovery copy/discard and
  exact-revision clear preserve other entries and occupied scratch; close/release
  follow the stated lifetimes. Current-format recovered drafts have no invented
  historical baseline.

**Complete when:** every focused case is mapped to a test/result, the ACID suite
passes, the 1.1 native evidence passes, and the diff preserves the clean-cutover
constraints. Only then mark Gate 1 complete and start Step 2. Mocked verification
is not native playback, lifecycle or undo acceptance; those remain later gates.


## Step 1A — Post-Gate-1 architecture and technical-debt cutover

**Status:** complete. Gate 1A passed before Step 2; native lifecycle, undo and musical acceptance remain Step 8.

**Goal:** eliminate inverted dependencies, the lazy module cycle, divergent musical policies, duplicated core operations and confirmed obsolete code while retaining exact musical output, accepted Step 1 data protections, current wire formats, and existing Renoise API 6.2 behavior. Refactor existing owners rather than introduce a service layer, migration, alternate serializer, new scheduler or another writer. No M5 GUI/layout work and no additional audio-capture matrix.

**Target dependency rule:** `model` (pure musical data/policies) is independent of `renoise`, `writers`, `runtime` and `gui`. `renoise` supplies host inspection/identity/storage adapters and may depend on `model`. `writers` depends on `model` and `renoise` but never on `runtime` or `gui`. `runtime` coordinates writers, drafts and host lifecycle; `gui` consumes runtime/model state. There must be **no require cycles**, including function-local/lazy requires. A pure function inside a host adapter does not justify duplicating the adapter in the model.

### 1A.1 — Freeze the post-Gate-1 baseline and dependency graph

1. Recheck `git status --short --branch` and current head; preserve unrelated work. Run `pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID` and record the actual outcome, not the historic 41-spec Gate 1 result as a new run.
2. Enumerate all static and function-local `require` edges across the 24 runtime modules, GUI and relevant test mocks. Record actual runtime callers and test-only callers for `articulation.apply`, `gate_writer.apply`, `pattrns_writer.generate`, `memory_status`, `sequencer.describe`, `draft_cache.close`, `draft_cache.capture/is_current/compare_and_clear`, `draft_cache.list/discard/copy_to_new/restore`, and `live_regen.armed`. Mark **remove now / needed by Steps 2–6 / keep because it enforces a boundary**. Test-only callers do not establish runtime use: move valid assertions to the canonical path or remove stale assertions, then remove obsolete APIs.
3. Establish byte/field-equivalence fixtures using existing `acid_output_planner_spec.lua`, `acid_pattrns_spec.lua`, `acid_legato_spec.lua`, `acid_pitch_bend_spec.lua`, `acid_phrase_persistence_spec.lua` and `acid_store_candidate_spec.lua`. Cover default/accent/unity velocity, Off and all supported PB ranges, straight/triplet and repeat/play-once, source/draft wire bytes, strict invalid input and unchanged output snapshots. Reuse the existing fixtures rather than create a second conformance matrix.

**Check:** call-site inventory has no inferred "unused" API, and baseline behavior is executable. Failed baseline tests are resolved or explicitly isolated before changing dependencies.

**1A.1 record:** baseline at `5c12c85`; initial worktree clean; baseline ACID run passed 41 specs. After adding the byte fixtures, both focused specs and the full ACID suite passed again (41 specs). Fixed byte assertions cover the complete committed source record in `tests/acid/acid_phrase_persistence_spec.lua` and the complete source-plus-draft store payload in `tests/acid/acid_store_candidate_spec.lua`.

| Module group | `require` edges |
| --- | --- |
| Model | `cycle_interpreter → sequencer`; `control_signals → cycle_interpreter`; `legato → control_signals`; `timing → sequencer`; `editor_state → sequencer, cycle_interpreter`; `output_planner → cycle_interpreter, timing, sequencer, control_signals, articulation, legato`; `pattern_store → sequencer, cycle_interpreter, writers.phrase_ownership`; `draft_cache → sequencer, pattern_store, writers.phrase_ownership, writers.phrase_validator, target_capabilities, writers.phrase_pitch_bend`. |
| Function-local model edges | `articulation → control_signals, writers.gate_writer`; the latter closes the cycle `articulation → gate_writer → output_planner → articulation`. |
| Writers | `gate_writer → output_planner`; `pattrns_writer → cycle_interpreter, timing, sequencer, output_planner`; `phrase_validator → writers.phrase_ownership, output_planner, pattern_store`; `phrase_writer → pattrns_writer, phrase_validator, gate_writer, phrase_ownership, pattern_store, target_capabilities, sequencer, legato_writer, phrase_pitch_bend, script_runner, output_planner`. |
| Entry points | `main → gui`; `gui → sequencer, editor_state, cycle_interpreter, live_regen, draft_cache, pattern_store, phrase_ownership, phrase_writer, selection_context, sampler_audit`. |

`renoise/*`, `target_capabilities`, `sequencer`, `memory_status`, `live_regen`, `legato_writer`, `phrase_ownership`, `phrase_pitch_bend` and `script_runner` have no module imports. `acid_gui_views_spec.lua`, `acid_gui_recovery_spec.lua`, `acid_gui_timing_race_spec.lua` and `acid_writer_capture_spec.lua` replace modules through `package.loaded`; these mocks do not validate the production graph. Model-to-writer imports remain in `pattern_store`, `draft_cache` and the lazy articulation path. `target_capabilities`, `draft_cache` and `pattern_store` also access Renoise host data from `model`; relocate the host owners in 1A.2.

| API | Production callers | Test callers and disposition |
| --- | --- | --- |
| `articulation.apply` | None; production uses `articulation.plan`. | `acid_articulation_spec`, `acid_articulation_resolution_spec`, `acid_glide_overlap_spec`; remove in 1A.3 after moving behavior checks to the planner and canonical writer path. |
| `gate_writer.apply` | None; `phrase_writer` uses `apply_plan`. | `acid_control_signals_spec`; remove in 1A.3 after redirecting checks to `apply_plan`. |
| `pattrns_writer.generate` | None; `phrase_writer` uses `emit`. | `acid_pattrns_spec`; remove in 1A.8 and exercise compile plus `emit`. |
| `memory_status` | None. | `acid_regeneration_spec`; remove in 1A.8 while retaining ownership checks. |
| `sequencer.describe` | None. | `acid_sequencer_spec`; remove in 1A.8; the only assertion is display formatting. |
| `draft_cache.close` | None; GUI releases drafts with `drafts.release(song)`. | `acid_draft_recovery_spec`; remove in 1A.8; it is a no-op. |
| `draft_cache.capture/is_current/compare_and_clear` | None yet. | `acid_draft_recovery_spec`; retain for Step 5's exact-revision completion guard or a proven equivalent. |
| `draft_cache.list/discard/copy_to_new/restore` | None yet. | `acid_draft_recovery_spec`; `list` is also used by `acid_repeat_integration_spec`; retain until Step 5 wires and verifies Recover Draft, Copy to New and discard. |
| `live_regen.armed` | Set and returned internally; GUI reads `state().enabled`. | `acid_live_regen_spec`; consolidate with the single arming state in Step 5. |

`gate_writer.plan` is used only by `acid_articulation_resolution_spec.lua`, `acid_gate_operations_spec.lua` and an alias assertion in `acid_output_planner_spec.lua`; redirect these checks to `output_planner.plan_gates` and remove the alias in 1A.3. `gate_writer.location` has no callers; remove its export in 1A.3. Keep the function-local `location` helper used for writer diagnostics.

### 1A.2 — Restore dependency direction without compatibility shims

1. Perform one mechanical owner relocation: `writers/phrase_ownership.lua` → `renoise/phrase_ownership.lua` (host identity, snapshots and seal); `model/pattern_store.lua` → `renoise/pattern_store.lua` (song `tool_data`); `model/target_capabilities.lua` → `renoise/target_capabilities.lua` (instrument introspection); `model/draft_cache.lua` → `runtime/draft_cache.lua` (session orchestration and recovery). Preserve the actual public functions and implementation behavior while moving them; do not split snapshot, store or draft ownership among multiple new helpers.
2. Update **all** production imports, tests, mocks and packaging inputs in the same change. `renoise/pattern_store` imports `renoise/phrase_ownership`; `writers/phrase_validator` imports the store/ownership adapters; `runtime/draft_cache` may consume the validator, store and writer policy. No adapter imports its writer/controller consumer. Do not leave forwarding modules under old internal names; fail loudly on stale imports.
3. Keep `model/output_planner`, `sequencer`, `cycle_interpreter`, `articulation` and `legato` Renoise-free. Verify current source/seal format, read-only inspection, object identity and host snapshot semantics did not change. Keep the verified candidate/commit/restore and captured draft guards; moving files does not confer write authorization.

**Check:** every old import has a single new owner; modules load in Lua 5.1 tests without a runtime cycle; Step 1 identity/store/draft/compatibility cases pass. Include the moved files in an XRNX packaging check. Only move other modules if the graph shows a concrete forbidden dependency; avoid a cosmetic directory reorganization.

### 1A.3 — Remove the articulation ↔ writer cycle and obsolete mutation entry points

1. Remove test-only `model.articulation.apply` after moving its behavioral assertions to `articulation.plan` + the canonical writer application path. Remove `writers.gate_writer.apply` if its only callers are legacy tests, retaining `apply_plan` only where production rendering uses it. Remove unused `gate_writer.plan`/`location` re-export aliases **only if** no real consumer remains. `output_planner` owns gate planning; `gate_writer` applies planned operations, never the reverse.
2. Keep `articulation.plan`, `control_signals.compile` and `output_planner.plan_gates` pure. No model `require("writers.*")`, including lazy requires; no test should need an obsolete writer API to validate musical semantics.
3. Rewrite affected tests to exercise planner output and actual emitted/applied operations, including gate/slide collisions, rather than deleting their negative cases.

**Check:** static dependency test detects forbidden edges and cycles (including lazy requires), all existing gate/articulation and planner expectations pass, and no second writer path remains.

### 1A.4 — Centralize musical policies and validation rules

**Status:** implemented. Shared policy owner: `model/policies.lua`; canonical source/defaults and leading-TIE rule: `model/sequencer.lua`. Focused policy, paging, source, persistence, draft, GUI and musical regression checks pass; ACID suite: 43 specs; full repository suite: 46 specs. Package root/private-module/exclusion checks and independent second-pass review pass. Native Renoise checks remain Step 8.

1. Introduce **one small pure** `model/policies.lua` for the actual shared policy: supported PB choices `0, 2, 12, 24, 48`, PB validation/default, volume input validation, the precise default/accent/unity velocity policy and quantization, and default output policy. Replace policy tables/literals in `output_planner`, `phrase_writer`, `pattern_store`, `draft_cache`, `editor_state`, `gui`, `pattrns_writer` and `legato` with that policy. Preserve default 0.7, the existing `floor(v * 128)`/unity-255 behavior, and `%.6f` pattrns emission; verify that emission, planning and note-column verification agree on quantized results, especially 0.7 → 89 and 1 → 255.
2. Use `sequencer.PAGE_SIZE` everywhere for page math; derive maximum pages from `sequencer.MAX_STEPS`. Make `sequencer` the owner of default source construction and of the Step-1-TIE rule. Setters, interpreter and validation may **check** the invariant at different boundaries, but reuse the same predicate/normalization policy rather than reimplement its meaning.
3. Share only truly identical numeric predicates (integer/range/volume); retain different rejection wording and validation at each trust boundary. Replace copied PB/velocity/page literals, not every integer in the program. Keep the persisted ownership hash algorithm, `v3:` identifiers, current source grammar and all current default values unchanged.

**Check:** policy tests exercise every PB value and rejection, fractional/NaN/edge velocity, both volume output paths and all gate/legato expectations. Formatting/normalization remains byte-compatible; Step-1-TIE and page navigation behave identically.

### 1A.5 — Make planner and capability contracts explicit

**Status:** implemented. `control_signals` validates semantic/successor association and captures detached semantic, successor and event values; `legato` checks the contract before overlap or PB planning. `target_capabilities.same` owns captured capability comparison. `articulation` owns shared glide conversion/bounds; cycle and seal constants preserve existing limits and bytes. Association, per-field capability invalidation, glide, cycle-boundary and exact-seal regressions pass. ACID suite: 44 specs; full repository suite: 47 specs. Second-pass review, 480-case baseline output equivalence and package checks pass. Native Renoise acceptance remains Step 8.

1. Replace the hidden object-identity assumption between `output_planner.plan` → `control_signals.compile` and `legato.plan` with one explicit semantic successor/steady-plan input or a single validated plan bundle. Its producer and consumers must check shape/association; never infer "same plan" from a coincidentally reused Lua table. Retain exact seam/legato/gate results.
2. Make `target_capabilities` the sole producer of the capability comparison contract; `phrase_writer.context_valid` calls that comparison or compares a canonical immutable snapshot. Do not manually concatenate or parse `|` signatures in consumers. Keep previously accepted capability-change invalidation and avoid a new persistent format.
3. Name and reuse rate/interval conversion and glide byte bounds where the same semantics appear in `articulation` and `output_planner`. Give loop-safety sentinels descriptive local constants, preserving termination behavior. Name the existing ownership-hash constants without changing the seal output. Do not alter Renoise-visible effect bytes.

**Check:** tests mutate successor identity/semantics and one capability field at a time, rejecting stale/mismatched requests; same-source output remains identical for loop seams, legato, bend endpoints and effect clamping. A regression must fail if either contract silently decouples.

### 1A.6 — Remove duplicate model-to-GUI transformations

**Status:** implemented. Canonical request snapshots use `sequencer.copy_source`; GUI initialization, New, reset and unavailable-source defaults share `reset_source` and `sequencer.new_pattern`. Editor projections expose their compiled plan and are reused by revision and raw target identity, with host invalidation. Navigation, arming and reset do not request rendering; reset invalidates queued work. Focused editor, defaults, GUI views/recovery/timing and repeat checks pass; ACID suite: 44 specs; full repository suite: 47 specs. Second-pass review and package root/private-module/exclusion checks pass. Native Renoise checks remain Step 8.

1. Replace `gui.lua`'s hand-copied pattern freeze with `sequencer.copy_source`, preserving complete canonical source and rejecting invalid partial drafts at the **same** request boundary as before; never silently normalize a dirty entry into a different source.
2. Route every default/new/reset/source fallback through one `sequencer`-owned default-pattern factory and a single initialized settings policy. Remove four copied GUI `new_pattern(16)`/fill/reset implementations. Replace GUI page arithmetic with `PAGE_SIZE`, without changing two-page/32-step behavior.
3. Project/compile once per actual editor-state revision and reuse that validated projection within the refresh and input handler. Do not cache across a real edit, instrument/phrase binding change, timing/PB/output-policy change, or host invalidation. Keep refresh and navigation read-only, and preserve existing error presentation.

**Check:** editor/GUI timing-race, views, recovery and repeat tests demonstrate identical projection/serialization, no stale preview after edits or rebinding, and zero Generate/Live Edit writes on navigation/reset/arming. This does not yet unify runtime callbacks; that belongs to Step 5.

### 1A.7 — Deduplicate the store codec without changing its contract

**Status:** implemented. `renoise/pattern_store` shares entry/header parsing and source token encoding/decoding for snapshots and drafts. Strict grammar, error categories, stored bytes and transaction guards are preserved. Codec fixtures, malformed-record checks, persistence, ownership, source-value, candidate and draft-recovery tests pass; ACID suite: 45 specs; full repository suite: 48 specs. Second-pass differential verification matches decoded values, exact errors and encoded bytes across 21,591 records; package root/private-module/exclusion checks pass. Native Renoise checks remain Step 8.

1. In `renoise/pattern_store` extract one shared header/entry parser and one shared source token encoder/decoder for snapshot and DRAFT forms. Keep existing strict grammar, token ordering, field validation, maximum steps, `v3:`/magic markers and visible error categories. Do not invent a new blob protocol or silently accept malformed prior data.
2. Remove repeated pitch/TIME serialization and redundant recompilation **inside parsing** only when the resulting validation path is identical. Preserve candidate staging, captured/proposed source checks, verified write/readback, guarded restore, and atomic exact-draft removal. Raw-string equality alone is **not** transaction or destination authorization.
3. Compare pre/post refactor encoded bytes using saved fixtures, parse valid legacy/current records, reject malformed records, and replay uncertain/partial `tool_data` writes and late-draft scenarios with existing tests.

**Check:** all persistence, ownership, source-value, candidate and draft-recovery tests pass with byte-identical encoding and the same mutation/no-mutation outcomes. A simpler codec may not loosen any collision, binding or rollback safeguard.

### 1A.8 — Prune confirmed dead APIs, not future safety functionality

**Status:** implemented. Removed `pattrns_writer.generate/expected_volumes`, `memory_status`, `sequencer.describe`, `draft_cache.close` and `phrase_writer.plan_output`; planner cell constructors and command encoding are private. Tests exercise canonical planning/emission and ownership state. Protected draft APIs and `live_regen.armed` remain. Direct affected specs, 45 ACID specs and all 48 repository specs pass; second-pass caller/diff review and package root/module/exclusion checks pass. Native Renoise checks remain unverified.

1. Delete `pattrns_writer.generate` if the 1A.1 caller audit confirms no production use; retain `emit`. Remove `memory_status`, `sequencer.describe`, `draft_cache.close` and unused exports only where test assertions can be redirected to the canonical state/behavior. Do not delete legitimate regression coverage merely to remove a module.
2. **Do not remove** `draft_cache.capture/is_current/compare_and_clear`: Step 1 hardened exact-revision clearing, and Step 5 must use or deliberately subsume it in the one completion path. **Do not remove** `list/discard/copy_to_new/restore` before Step 5 wires Recover Draft and proves occupied-scratch and persistence guards. The absence of a current GUI caller is not proof these contracts are obsolete.
3. Defer `live_regen.armed` to Step 5's single-flight controller cutover. Keep one public arming state or remove redundant fields **then**, with appropriate tests. Inventory remaining test-only helpers and delete only proven dead paths; no compatibility stubs for internal APIs.

**Check:** source searches find no orphan imports, function references or fake obsolete test paths. Replaced tests still prove the original safety and musical behavior.

### 1A.9 — Gate 1A: complete the cutover before runtime integration

| Substep | Changed owners | Verification |
| --- | --- | --- |
| 1A.1 | Persistence byte fixtures | Covered by the passing ACID and repository suites |
| 1A.2 | `renoise` and `runtime` module owners | ACID suite; package module layout and exclusions — pass |
| 1A.3 | `model.articulation`, `writers.gate_writer` | Dependency graph and ACID suite — pass |
| 1A.4 | `model.policies`, `model.sequencer`, consumers | ACID and repository suites — pass |
| 1A.5 | `renoise.target_capabilities`, planner contracts, `writers.phrase_writer` | `acid_target_capabilities_spec`, `acid_phrase_spec`, `acid_gate_transaction_spec`; ACID and repository suites — pass |
| 1A.6 | `model.editor_state`, GUI projection | ACID and repository suites — pass |
| 1A.7 | `renoise.pattern_store` codec | ACID and repository suites — pass |
| 1A.8 | `renoise.phrase_ownership`, confirmed dead APIs | `acid_phrase_persistence_spec`; ACID and repository suites — pass |
| 1A.9 | Dependency graph and final verification | `acid_dependency_graph_spec`; ACID: 45 specs; repository: 48 specs; ACID package: 27 runtime files; archive inspection; `git diff --check` — pass |

Blockers: none. Native lifecycle, undo and musical acceptance remain Step 8.

**Gate 1A: complete.** The dependency graph and shared policy checks pass; obsolete imports and APIs are absent; GUI source projection and store codec have single owners; recovery protections remain. Focused, ACID, repository and packaging checks pass. Step 2 may begin. Native lifecycle, undo and musical acceptance remain Step 8.

**Carry forward without premature rewriting:** Step 2 owns the operation token and runtime blocker state; Step 3 must decompose `phrase_writer.finalize` into explicit prepare/stage/render/precommit/commit/rollback/cleanup/terminal helpers around **one** job, replace `500` idle diagnostics, `+8` event slack and `126/512` fallback literals with named API-derived or justified bounds, and use passed capacities in validator/snapshot loops without weakening preflight. Step 5 must replace the duplicated GUI late-create draft-movement blocks with one successful-commit handler, consume exact-revision capture guards, remove redundant arming state, and route both manual and Live Edit through one scheduler. Step 6 owns watcher/lifecycle deduplication. Step 7 removes leftovers and enforces the final graph; do not migrate these flows into parallel Step 1A implementations.


## Step 2 — Centralize runtime state, transitions, and operation guards

**Status:** 2.1 complete; 2.2–2.9 remain pending. Native tests develop alongside runtime changes. Gate 1A is complete. This sequence hardens runtime contracts and cuts over existing state authority; it does not claim writer/native acceptance.

**Execution order:** 2.1 (complete) -> 2.2–2.9 in order. Develop and run focused tests alongside each change. Test-harness completion is not a prerequisite for runtime implementation or using released tools. Each **Complete when** check is a prerequisite for the next substep. Add focused tests with the owning behavior; failures return to that substep and invalidate affected downstream evidence. Do not begin Step 3 before Gate 2 passes. Use behavior-based module/test names, never these planning labels.

### 2.1 — Freeze ownership, interfaces, and the cutover boundary

**Status:** complete (2026-10-29). Interface conformance, production read-only
writer inspection, mocked boundary integration and independent second-pass
correction verification pass. This is not Gate 2 or native writer acceptance.

**Baseline (2026-10-29):** `55f3414`, clean working tree; a fresh
`pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID` run passed all 45 specs.
Implementation is limited to the interface boundary below; real context lifetime,
authorization capture, GUI cutover and native writer reservation remain later gates.

**Boundary audit:** existing manual and Live Edit token construction and the
index-based New/append fallback remain the 2.8 cutover, not alternate interfaces
to preserve. The legacy writer may complete synchronously before returning a
failure value, clears its slot before terminal delivery finishes, and has
boolean-returning cancellation without a consistent terminal channel. The strict
sink must not call that API directly; 2.8 must normalize it through the specified adapter, with its installed delivery
record preventing synchronous reentrant dispatch. Step 3 still owns slot acquisition
before insertion, cleanup/terminal ordering and cancellation retirement.

**Adapter and lifetime obligations:** a strict sink calls `done` only after its
terminal cleanup/evidence work and as its final host/GUI-observable side effect;
the acceptance return may follow synchronous `done`. It cannot continue mutating
the destination or source after retirement. The legacy
writer's idle status inside notification delivery is not sufficient admission
evidence. The 2.8 adapter must guard the entire legacy delivery callback and
normalize cancellation to one terminal result only when settlement and cleanup
are verified; a boolean acknowledgement alone cannot retire the request. If it
cannot establish that proof, retain nonterminal pending/tombstoned bookkeeping
rather than fabricate success or retirement. Only the matching terminal path
retires occupancy; an integrity-blocked terminal is allowed only after rendering
has finished or never started, as required by Step 3. Step 2.2 must scrub pending runtime records reachable through tokens;
Step 3 must also scrub/tombstone writer temporary-registry references on document
release. Read-only temporary lookup does not establish reference-release safety.

Keep one small private `runtime.context` module outside the dialog lifetime. It owns song epoch, dialog session, target objects/classification, edit/target/operation revisions, arming intent and song blocker state. GUI widgets, mutable editor source/history and presentation remain in `gui.lua`; they dispatch transitions and read a projection, never maintain another authoritative target/revision/token. Reuse `sequencer.copy_source`, Step 1 validators and `runtime.draft_cache`; do not duplicate their rules.

| Responsibility | Sole authority and dependency-safe interface |
| --- | --- |
| Accepted writer job and global occupancy | `writers.phrase_writer` owns its existing job/slot; Step 3 must acquire it before insertion (the legacy writer currently acquires it later). Runtime reads `writer.state()` returning detached scalar status and opaque operation token; it never copies a writable `busy` flag. Scheduler busy means waiting for its matching result, not permission to start another writer. |
| Runtime authorization | Runtime issues one opaque token and a revocable request record. Writer stores and returns that exact token identity in `state()`; its private job identity is separate. Admission requires no occupied slot; checkpoints allow only the same token; terminal retirement matches that token. `token:is_current()` returns boolean only and fails closed on inspection failure. Neither writer nor store imports runtime. Runtime may import writer/validator under Gate 1A's existing dependency rules. |
| Synchronous mutation scope | Request hook `mutate(token, action)` verifies the active operation, runs one non-yielding writer-owned action, and unwinds scope depth on success or exception. Return all action result values on success. Nesting is depth-counted and allowed only for the same token. On exception unwind depth, revoke the token, mark dirty and rethrow the original failure to writer cleanup; normal reconciliation waits for a safe cleanup/blocked state. Notifications only mark dirty inside it. No public/user callback, idle wait or render wait may execute inside the scope. |
| Temporary object bookkeeping | Writer privately records only objects returned by its own insertion calls, with role/song/instrument/token. Expose a read-only `writer.is_temporary(song, instrument, phrase)` query for UI filtering, verified by raw membership. No public register-existing-object action. This registry never changes ownership inventory. |
| Integrity evidence | Inject `record_blocker(token, evidence)` into the writer request. It verifies the matching live epoch/job, copies scalar/value evidence and retains exact recovery refs only while that song is current. Writer records evidence before its terminal result; stale GUI delivery cannot suppress it. |
| Admission and completion | Runtime's single `request_generation(trigger)` performs eligibility/capture then passes the request to a replaceable sink. Sink rejection is `false, reason` with no completion; acceptance is `true` with exactly one terminal `done(result)`, possibly before return. Install the delivery record before invoking the sink. A thrown call after possible acceptance is not proof of rejection: consult occupancy and fail closed. |

`create(request, done)` and `regenerate(request, done)` remain Step 3's production facades. A test sink implements their handshake here. Implement and test the minimal production read-only `writer.state()` / `writer.is_temporary(...)` queries over existing private job refs in this substep, before 2.3 consumes them; they expose no host refs or registry mutators. The interface-conformance harness uses fake tokens/records until 2.2/2.7 supply real context requests. In 2.8, a temporary adapter translates the existing writer API/results, reads its occupancy, and delegates its existing cancellation; it cannot invent cleanup, claim acceptance on rejection, or release a render slot. While the legacy slot is acquired after insertion, prevent synchronous reentrant dispatch with the already installed delivery record; this is an admission guard, not a second native occupancy owner. Do not claim before-insertion native reservation at Gate 2. Step 3 fixes acquisition ordering, replaces that adapter and removes the boolean-cancel shortcut. Step 5 replaces the two existing dispatch/scheduling paths with one queue; no new scheduler is introduced here.

Make Independent has a separate explicit action entry point and eligibility result; it never enters the musical sink. Its metadata transaction remains Step 4. Recovery chooser and Revalidate UI remain Step 5. Step 2 implements their required state/predicate seams, not placeholder actions that mutate data.

**Complete when:** dependency tests cover the chosen imports; interface-conformance tests prove rejection, synchronous completion, duplicate completion and thrown/uncertain start handling. A sink that completes then returns rejection is a protocol violation: deliver at most once, diagnose and block further dispatch until read-only state inspection establishes safety; do not settle twice. Interface signatures/results are documented beside the implementation. No writer/store/model imports runtime or GUI.

**Implemented interfaces:** `runtime.context.new{writer, capture, sink, issue_token?}`
returns only `request_generation(trigger)`, `revoke(token, reason)` and `state()`.
Mutable delivery state and fixed dependencies are closure-private. `capture(trigger,
token)` must return a request carrying that exact token; context never writes the
request. Optional `issue_token()` is a conformance seam and receives no record.
`writer.state()` returns exactly `"idle", nil` or `"busy", token`; legacy tokenless
busy jobs remain occupied. `writer.is_temporary(song, instrument, phrase)` returns
only a boolean, backed by private insertion records and current raw membership.
No create/regenerate facade, GUI adapter, metadata action or new scheduler was added.

| Completion evidence | Focused verification | Result |
| --- | --- | --- |
| Rejection without completion; synchronous/asynchronous completion; duplicate, stale and rejected callbacks; completion followed by rejection; reentrant capture/delivery | `tests/acid/acid_runtime_context_spec.lua` | Pass |
| Thrown/nonboolean starts retain matching accepted occupancy while revoking commit authorization; writer idle cannot retire a pending record; malformed/unreadable inspection blocks | `acid_runtime_context_spec.lua` | Pass; only a matching completion retires bookkeeping |
| Private authority, detached projections, raw-token revocation, immutable/proxy capture, hostile diagnostic errors and request-reference release on retirement | `acid_runtime_context_spec.lua` | Pass; pending document-release scrubbing remains 2.2 |
| Exact idle/busy token tuple, tokenless occupancy, repeated release, post-release cancellation and shared-`__eq` impostor rejection | `tests/acid/acid_writer_inspection_spec.lua` | Pass; legacy cancellation booleans do not retire native occupancy |
| Stage/backup/recovery records, create promotion, external removal, cross-song/instrument lookup, raw phrase identity and stale-record shadowing | `acid_writer_inspection_spec.lua` | Pass; shared equality handler proves content equality differs from raw identity |
| Real writer queries consumed by context; occupied/tokenless jobs deny capture and sink; status notifications do not settle; mocked terminal result retires matching context record | `acid_writer_inspection_spec.lua` | Pass; test-only sink/adapter, not production GUI or native reservation |
| Dependency direction, no cycles, no model/store/writer import of runtime or GUI | `tests/acid/acid_dependency_graph_spec.lua` | Pass |
| Regression and packaging | PowerShell 7 runners; Lua 5.1.5; archive inspection and source-byte comparison | ACID: 47 specs; repository: 50 specs; package: 28 entries; roots/private modules/development exclusions pass |
| Independent second-pass closure | Runtime/writer adversarial review and separate documentation review, followed by correction verification | Within-scope findings fixed and covered; later adapter/lifetime obligations recorded above |

Stored identifiers, seal/source formats, manifest/API versions and musical
planning remain unchanged. The context is not wired into the GUI yet: 2.2–2.8
must replace its real lifetime, capture and state authorities in order. Temporary
registry release scrubbing, legacy delivery/cancel normalization and native slot
reservation remain the owning later gates, not passes inferred from these mocks.
No new native Renoise playback, undo or lifecycle acceptance was performed;
M4 remains open and Step 8 remains required.


### Real-Renoise tests

**Purpose:** run a small test suite from a normal developer checkout. Keep offline
Lua tests fast and use native Renoise tests for behavior mocks cannot establish.
The Windows runner is a development convenience; released XRNX tools must work
through ordinary Renoise installation without it or its dependencies.

**Current implementation:** development packaging, authenticated loopback driver,
PowerShell runner, native document-reset and inventory smoke, and offline runner
regressions. T0.4 runner acceptance passes for fresh launches, loaded selected
instances, concurrent instances and timeout/disconnection recovery. T0.5 native
fixture/isolation acceptance passes. T0.6 keyboard automation and offline guard
coverage are implemented and Renoise-host acceptance passes. T0.7 harness
integration and failure classification pass; T0.8 coverage handoff is complete.
Boundary checks, the Native catalog/order rerun and remaining acceptance owners
are recorded in the [T0.8 verification record](../tests/renoise/host_verification.md#t08-coverage-handoff-and-closeout-2026-10-30).
Keyboard acceptance does not block Native runs, runtime implementation or normal
tool use.

#### Developer workflow

1. Run `./scripts/run_tests.ps1 -Tool ACID` for offline tests (PowerShell 7 and Lua 5.1).
2. Run `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong` for
   the Native smoke in a fresh Renoise process. Add `-RenoiseProcessId <pid>` to
   use an existing instance with a disposable song. Other Renoise instances and
   virtual desktops may remain in use. Use `-RenoiseExe` or `-ToolsDirectory`
   when automatic discovery does not match the developer's installation.
3. Preflight checks the executable/version, selected PID and writable temporary
   directory. Native runs do not require an active desktop. Keyboard runs need
   an interactive Renoise window; the helper activates the selected process and
   verifies focus automatically. Do not require a dedicated account, VM,
   registry profile equality, manual spike, screenshots or environment-bound
   trace evidence.
4. Temporarily replace ACID only with `-Install`, preserving a verified backup.
   Reset only the disposable test song authorized by `-ApproveDisposableSong`.
   Check listener ownership against the target PID before commands. Do not change
   another instance's song or terminate a preexisting process.
5. Stop the test driver through its explicit shutdown command, then restore
   unchanged installation files. Do not require closing a developer-owned Renoise
   instance. Preserve changed files/backups when automatic restoration cannot
   finish. Reload ACID afterward to use the restored release code.
6. Keep failures actionable: unavailable executable, missing supported scenario,
   failed assertion, timeout, wrong target or failed backup/restore. No process
   count, desktop, profile-attestation or historical-evidence gate.

#### T0.1 — API contract and basic preflight

- [x] Inspect pinned API 6.2 definitions and offline docs for sockets, document
  lifecycle, undo and keybindings; keep API constraints in `tests/renoise/README.md`.
- [x] Check executable/version, selected PID and writable temporary paths without
  changing tools or songs. Other instances and desktops remain usable.
- [x] Keep manual prompt/lifecycle diagnostics separate from automated assertions.

#### T0.2 — Development-only package

- [x] Build disposable bundles under ignored `tmp/`, with loopback configuration
  and per-run credentials outside the tool bundle.
- [x] Verify release exclusion, source payload hashes, unchanged manifests,
  bootstrap isolation, archive paths and repeated builds.
- [x] Keep the driver, configuration, fixtures and keyboard helpers out of releases.

#### T0.3 — Asynchronous Renoise transport

- [x] Authenticate and validate bounded JSON frames; dispatch fixed operations
  through idle callbacks without arbitrary Lua/module execution.
- [x] Observe release/new-document barriers, epochs, timeouts and cancellation;
  reject late or incomplete transitions.
- [x] Cover framing, malformed requests, token/ID errors, limits, reconnects and
  cleanup offline. Confirm native shutdown through the per-run completion file.

#### T0.4 — PowerShell runner

- [x] Discover/configure Renoise, build/install with consent, verify backups,
  check target/listener identity, reset disposable songs and report results.
- [x] Verify transport and installation failure cleanup without Renoise.
- [x] Pass fresh-launch and controlled selected-PID Native smoke with a concurrent
  instance; restore files and leave developer-owned processes open.
- [x] Verify reloading ACID already loaded in a selected instance, then running
  the smoke and restoring/reloading the original installation.
- [x] Exercise controlled host timeout/disconnection and verify nonzero results,
  cleanup or retained recovery files, and preservation of unrelated instances.

Second-pass runner review corrected reset/snapshot epoch validation and strict
JSON success-envelope validation, with focused offline regressions. Fresh-launch
Native smoke was rerun with successful driver shutdown and installation
restoration; see the dated commands and report identifiers in
[host verification](../tests/renoise/host_verification.md#runner-verification-rerun-2026-10-29).
Earlier selected-instance/concurrency/interruption observations remain identified
separately from this rerun. This closes runner review only; targeted keyboard
coverage is completed below under T0.6.

#### T0.5 — Independent native fixtures and scenario isolation

- [x] Read native inventory and selection positions; compare stable value snapshots.
- [x] Add a small scenario definition under `tests/renoise/acid/scenarios/` with
  fixture/preconditions, actions, observed waits, expected changes and unchanged data.
- [x] Extend read-only snapshots for relevant phrase properties, used/hidden/tail
  note/effect fields, mappings and `tool_data` bytes/digests. Keep diagnostics
  separate from independent host assertions.
- [x] Use canonical values with stable ordering and explicit empty/nil handling;
  assert foreign content, counts, IDs, source, settings and unaffected columns.
  For identity-sensitive cases, establish a native-proven identity check; neither
  Lua wrapper identity nor an unchanged index proves persistent host identity.
- [x] Share deterministic inputs and independent golden expectations with existing
  Lua tests; never derive expected output from the production writer under test.
- [x] Verify fixture load/reset, notifier cleanup and test-order independence;
  preserve deliberate cross-document interruption cases.
- [x] Run two successive scenarios and a deliberate assertion failure. Verify
  exact diffs, no read-only undo/selection/musical changes and no state leakage.

Native acceptance on 2026-10-30 passed the full catalog, a separate unexpected
assertion failure with exact diff and exit 1, and a clean catalog rerun afterward.
The independent fixture covers foreign phrase content, hidden/tail note/effect
fields, column metadata, mappings and exact source/settings/draft bytes. It
makes no owned-association or persistent host-identity claim; identity-sensitive
writer cases remain with their owning steps. Fixture construction and snapshots
do not use the production writer to derive expected output. Second-pass review
and corrected boundary regressions passed; see the
[fixture verification record](../tests/renoise/host_verification.md#native-fixture-and-isolation-verification-2026-10-30).

#### T0.6 — Targeted keyboard E2E

- [x] Add an AutoHotkey v2 helper under `tests/renoise/keyboard/`. Before each
  input sequence, verify the explicitly selected Renoise PID and foreground ownership before
  sending. Never activate a window on a shared desktop; require explicit
  consent for activation in a dedicated interactive Windows session. Abort
  rather than redirect input when foreground does not match. Native API tests
  must never require keyboard focus.
- [x] Read the shortcut from developer configuration and fail with a clear
  diagnostic when it is missing. Do not rewrite the developer's keymap. If a
  binding is needed, register the genuine `Global:ACID:Show` action through the
  existing `show_tool` handler; do not add a test-only production action.
- [x] Open ACID through that mapped shortcut. Wait for API-visible dialog state,
  then exercise one native instrument selection/navigation path and confirm it
  through readback. Use API inspection for structural assertions; do not call
  `gui.show()` directly or use fixed delays or screen coordinates as assertions.
- [x] Cover a missing mapping, wrong PID, stolen focus and GUI timeout. Each case
  must return a failure without sending keys to another window. Keep Native and
  Keyboard independently selectable, and add editing/regeneration journeys only
  with their owning interface work; route them through real GUI handlers.

The automated path and offline guard checks are implemented. In nonintrusive mode, an existing selected Renoise process must already own the foreground; no window is activated. Explicit activation is allowed only through `-AllowKeyboardFocusActivation` in a dedicated interactive session. The focus guard is exercised through the actual send dispatcher with an injected mismatch. The current
developer keymap assigns Ctrl+Alt+B (`^!b`) to `Global:ACID:Show`. Renoise-host
acceptance passed on 2026-10-30: the shortcut opened and closed ACID, the real
handler invocation was observed, and native instrument navigation changed the
selected index from 1 to 2. See the
[keyboard verification record](../tests/renoise/host_verification.md#keyboard-e2e-host-acceptance-2026-10-30).

**Complete when:** the configured shortcut opens ACID in the intended Renoise
window, dialog and selection behavior are confirmed through observable state, and
the four negative cases fail safely. Native tests remain runnable without a
keyboard mapping or AutoHotkey.

#### T0.7 — Verification integration and failure classification

- [x] Pass offline preflight, transport, runner, Lua and package-exclusion checks.
- [x] Document portable commands and separate offline, Native, Keyboard and manual
  checks in the existing test/development guides.
- [x] Put relevant Lua harness specs in the existing test discovery and runner
  safety/package specs in the existing PowerShell checks. Keep offline checks
  runnable without Renoise; do not add a second mock framework or make keyboard
  tooling a prerequisite for Native tests.
- [x] Run the Native host smoke through authenticated ping/capabilities, observed
  new-document completion, read-only inventory snapshot, fixture load and reset.
  Repeat a scenario and run a deliberate assertion failure or timeout to verify
  isolation and nonzero failure reporting. Run keyboard shortcut/focus checks
  when the Keyboard suite is selected; preserve independent suite selection.
- [x] Record exact commands, host/API and tool versions, scenario results and
  relevant report paths in the existing Renoise test guides. Keep environment
  details portable and distinguish automated results from manual observations.
- [x] Apply these result classes consistently: PASS means every requested
  postcondition was independently asserted; FAIL means an assertion found a
  contract violation; ERROR means runner, host or transport failure; SKIP means
  optional coverage was unavailable; MANUAL means the check was not automated.
  A requested suite with missing assertions or skipped required coverage cannot
  report green.

**Complete when:** applicable offline specs and package/runner checks are in
normal discovery and pass; the Native smoke, repeat and deliberate failure produce
the expected readback and exit status; and reports distinguish automated,
skipped and manual coverage. This verifies the harness, not unimplemented ACID
behavior.

#### T0.8 — Coverage handoff and closeout

- [x] Review dependency and package boundaries. Test infrastructure must stay out
  of ACID runtime imports and release bundles. Remove unused test hooks and
  duplicate fixtures; preserve production interfaces, manifest/API versions and
  wire formats. Keep repository documentation free of machine-specific paths.
- [x] Maintain a compact case-to-test table in the existing Renoise test guide.
  For each case, record the owning M4.7 step, relevant Step 8 A–E acceptance
  contract, Native/Keyboard/Manual method, independent assertion and current
  status. Add cases with the behavior that owns them; do not duplicate future
  feature tests in the harness foundation.
- [x] Hand off coverage to its owning step: document/session lifetime, selection,
  inventory and release/reload to Steps 2.2–2.9; create/regenerate/rollback and
  occupancy to Step 3; explicit copy resolution to Step 4; drafts, scheduling and
  persistence to Step 5; notifications and late callbacks to Step 6. No mock or
  harness result substitutes for a native assertion of host behavior.
- [x] Run only Step 8 cases whose owning behavior is implemented. Record native
  undo/redo and save/reload results, plus visual/audible checks as Manual where
  automation cannot establish them. Keep unimplemented cases assigned to their
  owning steps with status pending; do not report them as passed or block
  unrelated runtime development on their absence.
- [x] Close the harness handoff when its applicable checks pass and every
  unexecuted behavior has an explicit owner and status. Keep Step 8 open until its
  applicable native, keyboard and manual acceptance checks pass; T0 completion
  does not certify unimplemented writer behavior.

**Status: complete (2026-10-30).** The [coverage handoff](../tests/renoise/README.md#coverage-handoff)
assigns each remaining behavior to its runtime gate and Step 8 contract.
All six offline groups (53 Lua specs on Lua 5.1), release/development packaging
and the Native catalog with reverse-order isolation pass. The optional Keyboard
rerun stopped at preflight without input; its post-policy host acceptance stays
pending. Actual writer undo/redo, source/draft save/reload and visual/audible
acceptance remain explicitly pending under Steps 3–6 and 8. No new runtime
behavior or full Step 8 acceptance is inferred from harness completion.

**Complete when:** package/dependency review passes, current coverage has an
independent assertion and owner, applicable harness and host checks have recorded
results, and remaining behavior acceptance is explicitly tracked under Steps 2–8.

T0 tracks test implementation and coverage. Its unfinished items do not block
running available suites, normal tool use or runtime development. Requested
coverage must pass before that coverage is reported complete.

### 2.2 — Implement context lifetime and revocable delivery records

1. Attach a fresh epoch to each current document, even when a song is reloaded. Opening/reopening creates a fresh dialog session; closing invalidates that session and its requests, preserving object-local drafts and a live song's blockers. Repeated close/release calls are idempotent.
2. Keep request data behind a mutable delivery/job record. Guard and completion closures capture that record/token, not song, instrument, phrase, widgets or a GUI closure directly. `record.gui_delivery` is the sole GUI callback slot and is nilled on close/release; writer callbacks likewise capture only their scrub-able job record. Freeze copied request values separately from revocation bookkeeping; never overwrite an expected baseline with current host values.
3. On release, invalidate first; request writer cancellation and safe same-song cleanup while the old song is current, without releasing occupancy except through its matching terminal transition; detach existing listeners and GUI delivery; release drafts with the existing volatile-loss warning; scrub host refs, frozen request payloads, candidate refs and nested closures from runtime records. Step 3 must do the same for its job/callback closure. Retain only an opaque token, epoch, terminal flags and captured diagnostic strings for an unresolved global render. Late callbacks cannot inspect old host objects, deliver GUI results or start a request.
4. A new song does not clear writer occupancy. An old callback may retire only its own slot/tombstone. Reload reconstructs safety from current ownership/source/output validation, not a previous blocker, baseline or recovery phrase name. Neutral recovery phrases are Foreign; never delete/adopt them by name. Restart/reload persistence of session blockers is not promised by the unchanged format.

**Complete when:** close/reopen, repeated release, new epoch, occupied song switch and late/duplicate callback tests prove session isolation. After release, inspect retained records/closures in the mocks for old host/UI references; checking only that callbacks return early is insufficient. Step 3 still owns native in-flight stage disposal/retention.

### 2.3 — Implement object inventory, classification, and baseline projection

1. Bind exact live instrument/phrase objects with `rawequal`; indices are display/API coordinates resolved immediately before indexed calls. New is a private synthetic sentinel with an explicit instrument, never `#phrases + 1`, missing phrase or a failed lookup.
2. Use `phrase_validator.classify` with freshly inspected capabilities, documented capacities and planner options for Owned/Foreign/Unavailable. `ownership.status` or `store.load` alone cannot authorize Owned. New requires live instrument membership. Preserve the classifier's concrete reason; inaccessible/removed objects are Unavailable, not New.
3. Retained objects survive reorder. A removed object or same-index replacement stays detached and cannot bind its replacement. Rebuild choices for the exact instrument. Rename/refresh does not follow native selection or replace a locally selected New target; actual native object-pair changes follow the explicit transition in 2.6. Temporary objects are filtered from choices only via the writer's private read-only query.
4. Preserve each verified baseline as copied values: committed source/settings, ID, complete content and `planning_inputs`. External changes never establish a new overwrite baseline automatically. Draft restoration consumes the same proof through existing cache APIs; detached/collision drafts never acquire a guessed owner.

**Complete when:** tests cover all four classes, cross-instrument duplicates, missing/corrupt/incompatible source, inaccessible fields, reorder, removal/replacement, explicit New and two distinct identical-content phrase mocks with content-based `__eq`. Object-keyed draft and temporary lookup tests use raw identity.

### 2.4 — Remove ownership exclusions and define synchronous temporary neutrality

Ownership inventory always counts **every live phrase**. Remove `excluded` arguments/options from `phrase_ownership`, `pattern_store`, `phrase_validator` and their production/test callers; reject an attempted exclusion argument/option with a concrete error rather than silently ignoring it. Lua 5.1 ignores surplus fixed arguments, so use explicit argument-count validation on affected public entry points and test positional as well as `options.excluded` attempts. Ordinary classification/durable draft access has no transaction exception. Keep strict stored bytes, parsing and existing collision guards unchanged.

The writer must record each returned inserted object before further fallible work. During backup `copy_from`, a copied ownership name may exist transiently; give the backup its neutral non-owner name within the same synchronous mutation scope, before any classification/store validation or scope-exit reconciliation. Staging is neutral before script/render waits. No async interval may contain an intentionally copied temporary owner ID. If neutralization fails, invalidate authorization and retain occupancy through verified cleanup or an integrity-blocked terminal outcome; do not omit that object to make uniqueness pass. Failure paths must not run normal reconciliation against an unfinished mutation as if it were safe.

Implement the scope helper and dirty/reconcile entry points now using a fake writer. Scope exit records the resulting native instrument/phrase pair as internally observed and schedules one existing idle reconciliation. Scope state is unwound even when the action throws; failure also revokes authorization. Do not treat delayed/uncertain callbacks outside the scope as internal by default. Step 3 wires real insert/copy/delete; Step 6 attaches the full watcher graph. No circular prerequisite is allowed: Step 5 can call/test these reconciliation functions without waiting for Step 6's subscriptions.

**Complete when:** all lower-boundary tests reject caller exclusions, including an ordinary colliding holder and forged/stale/cross-operation values. Fake insert/copy/rename tests show temporary neutrality at every scope exit, no exclusions in ID inventory, exception-safe scope unwinding, no classification during scope, and external invalidation outside it. Actual writer neutralization is an explicit Gate 3 requirement, not claimed by this fake.

### 2.5 — Implement blocker state and the occupancy view

1. A song/epoch blocker stores reason, affected destination/source pre-transaction evidence, exact recovery records and captured scalar labels. Ordinary Foreign/Unavailable/collision is target-local, not a song blocker. Dialog reopen, navigation, arming, successful unrelated refresh and stale results cannot clear a blocker.
2. Any song blocker denies Generate, Live Edit and Make Independent throughout that live song. Global writer occupancy independently denies starting any other writer transaction in any song, including identity-only actions. Cancel acknowledgement, timeout diagnostics, disabling Live Edit, close and release do not retire accepted occupancy; only the matching terminal path may do so after native rendering finishes or never started. Missing callback remains occupied indefinitely.
3. Provide a read-only revalidation predicate returning verified/blocked plus reasons/evidence. Require no active render, absence of recorded recovery objects, and exact destination/source consistency against the recorded pre-transaction or fully verified committed state, plus current ownership/output and draft checks. No render, rename, store write, baseline adoption or recovery deletion. Only an explicit Revalidate action may apply a successful proof to clear the same unchanged blocker record; a stale proof cannot clear newer evidence. Clearing never drains an old request. Step 5 supplies the UI.
4. Release drops exact old-song blocker refs; global occupancy keeps only its host-free tombstone. New/reloaded documents must pass fresh compatibility checks; clearing a session blocker is not evidence that persisted inconsistent states are safe.

**Complete when:** stub-writer tests cover blocker persistence, scoped versus global denial, missing callback, cancel acknowledgement, old terminal versus newer job, read-only revalidation, stale revalidation proof, recovery-object absence and unrelated song usability only after global retirement. No writable runtime occupancy copy is introduced.

### 2.6 — Implement the transition and revision table

Use only epoch, dialog session, target revision, edit revision and operation serial/token needed by guards. Target revision tracks semantic destination/eligibility changes; edit revision tracks changed editor source/settings, including equal-valued later revisions after A → B → A. Operation serial changes on each explicit request/supersession and explicit invalidation; it is not incremented by display refresh. Mark individual requests revoked so disarming Live Edit need not cancel an unrelated manual request.

| Input | State/guard effect | Request permission |
| --- | --- | --- |
| Local target/instrument change or actual external native object-pair change | Preserve outgoing draft; revoke affected work, increment target revision, bind/classify exact objects. Temporary internal selection is reconciled without adopting it. | None |
| Rename, reorder or identical inventory refresh | Refresh labels/coordinates; retain raw target and revisions if eligibility/planning inputs did not change. Record actual native pair independently of popup state. | None |
| Real source/settings edit, including source undo/redo | Increment edit revision; revoke older captured edits even if later values match. Preserve invalid edits as recoverable drafts; invalid source cannot authorize a musical request. | One Live Edit intent only when armed, valid and eligible; otherwise none |
| No-op edit or cursor/page/view change | No edit/target revision change and no invalidation merely for repaint. | None |
| Guarded load/restore/recovery copy or existing explicit Reset Source command | Revoke obsolete requests; if editor values change, advance edit revision; preserve Reset Source's current no-render behavior. Do not disguise this as a user edit notifier. | None, even while armed |
| Arm Live Edit | Change arming intent only; do not load/rebind a different target. | None |
| Disarm Live Edit | Revoke pending/in-flight Live Edit authorization and request cancellation; retain occupancy/drafts. Explicit manual authorization remains independently guarded. | None |
| Generate, including explicit retry | Capture a fresh operation through the same generation entry; supersede older pending intent. Manual action does not require armed state. | New/create or Owned/regenerate only |
| Make Independent | Revoke pending musical intent and cancel active work; require settled occupancy and fresh separate group proof. Never queue an automatic retry on settlement. | Metadata-only sink in Step 4; never musical sink |
| External content/source/capability/planner-option change, removal or new collision | Revoke affected requests; advance target revision on eligibility/baseline change; detach mismatching drafts. Never refresh expected values into authorization. | None |
| Undo/redo processing | Revoke work and reconcile read-only; after processing stops, require independent compatibility proof, not just a valid seal/source. | None |
| Close/release/new document or integrity blocker | Revoke relevant delivery/requests as in 2.2/2.5; discard pending authorization, retain recoverable drafts under their documented lifetime. | None |
| Completion | Retire only matching bookkeeping; apply GUI/baseline/draft effects only after verified success and current delivery/target/edit checks. Duplicate/stale completion cannot clear newer work. A stale but verified commit retires only its own bookkeeping and marks inventory dirty; it cannot rebind the current target or clear a newer draft. | Never by itself |

Separate `musical_eligibility` from `independence_eligibility`. A matching collision is always musically blocked but may qualify for Step 4's explicit group-wide resolution. Missing source, incompatible/unverifiable holder, changed seal/content, song blocker, active undo/redo or unresolved occupancy blocks resolution. With more than two holders, resolve only the selected object; never infer an original.

**Complete when:** table-driven tests exercise every row, A → B → A revisions, blocked edits staying recoverable, arming independence from manual requests, no implicit New fallback, collision-resolution eligibility and zero requests from observer/reconciliation/programmatic paths.

### 2.7 — Implement frozen requests and checkpoint guards

Capture operation kind/trigger/token; current song/epoch/dialog session; exact instrument; explicit destination kind/object/ID; target/edit/operation revisions; copied source/output policy/PB range; committed source/settings baseline; complete phrase snapshot; and copied `planning_inputs` returned by Step 1. Include capabilities, API capacities and pitch-bend delivery option; capture any additional host value actually read by planning. Preserve the existing LPB transport-timing eligibility check: capture timing model and recheck at admission/callback/precommit; a change invalidates authorization. Capture `groove_enabled` for the existing approximation warning and compare it before commit so status cannot silently describe a different condition. Do not add BPM/position/playback-state dependencies that current planning does not use. For New, record explicit scratch/draft capture and instrument planning inputs; absence of phrase baseline is valid only for explicit New.

Use existing `draft_cache.capture/is_current` for the exact session draft token/revision and durable-removal preconditions. Do not create another draft counter/serializer. Invalid source/settings rejects before sink invocation while preserving the editable buffer/draft. Request values are detached copies, never mutable GUI/history or store-entry references.

`is_current()` checks revocation, epoch/session/revisions and current context cheaply; a separate fail-closed `validate_checkpoint(request)` performs fresh raw membership, classifier/compatibility, source/settings/content/planning-input comparisons, global ID uniqueness, undo/redo and blocker checks. Neither adopts a new baseline. Writer performs its own live validation in Step 3 at admission and precommit, plus callback checkpoints appropriate to its state. Occupancy checks allow the same accepted job's own token but reject other jobs; do not make a running job fail its guard merely because it owns the slot. Cleanup authorization is separate from commit authorization and permits only that job's exact objects while its song is current.

Capacity availability is rechecked against current membership before each insertion; it is not frozen free-slot count and does not turn reorder into target change. Persisted source-map concurrency and draft removal use the existing guarded store candidate rather than a second runtime transaction implementation.

**Complete when:** mutation-after-capture, changed capability/PB option, changed source/hidden fields, same-index replacement, collisions, undo state, blocker, stale session/edit/operation, own-slot versus other-slot and draft-revision tests fail closed. New has no implicit existing-phrase baseline; invalid requests invoke the sink zero times.

### 2.8 — Cut over current GUI state authority without adding a second pipeline

Move authoritative `generation/opened`, bound instrument/phrase, target choice mapping, edit/target revisions, arming intent, native-pair tracking, mutation state and request tokens to the runtime context. Legacy scheduler `enabled/armed` flags are derived mirrors commanded by runtime, never independent authorization; Step 5 removes redundant arming storage. GUI may keep transient popup indices and source/history/projection caches only as derived/editor state. Replace `live_target` fallback-to-append with explicit eligibility rejection. Both current manual and Live Edit dispatch sites call the same runtime admission/capture entry and temporary adapter from 2.1; they cannot construct independent guard tokens. Immediately before the legacy call, resolve raw instrument/phrase objects to current indices and recheck membership; map the synthetic New sentinel to append only for an explicitly authorized create. A failed existing-object lookup rejects and never maps to append. Keep existing scheduler/writer behavior behind that adapter until Steps 3/5 replace it; do not claim those later safety gates pass. Normalize legacy status notifications separately from terminal results. Legacy completion followed by a false return is normalized to accepted/one completion; only the strict sink protocol after normalization is tested as a violation.

Route existing lifecycle/selection/idle callbacks to the context's transitions and scope handling; remove the corresponding competing counters/authorization, not merely shadow them. Stable existing notifier identities remain attached once. Full instrument/name/content subscriptions and delayed notification acceptance remain Step 6. Programmatic widgets use the existing update/load guards. Draft movement/completion UI duplication remains scheduled for Step 5, but every existing branch must use current delivery/target/edit predicates and cannot independently authorize clearing or rebinding.

Use result-returned object identity where available; any legacy result index is resolved once and accepted only if raw membership and the captured job evidence prove the exact object. Otherwise block the binding rather than infer it. Final create/regenerate object guarantees and native safe cancellation remain Gate 3; exact durable/session clearing and single scheduler remain Gate 5.

**Complete when:** GUI tests prove navigation, reopen, arming, Reset Source, restoration and no-op edits make zero requests; blocked/removed/foreign targets never append; old sessions cannot update current widgets; both callers use the same tokens/eligibility. A source/import search finds no competing target/revision/manual-token authority. Existing editor/musical regression expectations remain unchanged except explicitly unsafe fallback expectations.

### 2.9 — Close Gate 2 and hand contracts to writer integration

Run focused runtime/GUI/ownership/store/dependency tests, then `./scripts/run_tests.ps1 -Tool ACID` and `./scripts/run_tests.ps1` in PowerShell 7. If adding `runtime.context` changes runtime layout, run `./scripts/package.ps1 -Tool ACID` and inspect root entries, private modules and development exclusions. Run `git diff --check`; preserve unrelated work and manifest/storage versions.

Record each 2.1–2.8 completion check with its test file/case/result in the existing checklist, plus the actual temporary adapter/interface names and removed authorities. Explicitly map fake evidence versus production behavior: Step 3 integrates native job occupancy/mutation/terminal guarantees; Step 4 implements metadata resolution; Step 5 unifies scheduling and draft/completion UI; Step 6 completes native subscriptions; Step 8 validates native ordering, playback, undo/reload and preservation. Steps 5/6 consume reconciliation functions already implemented here; full end-to-end observer behavior is not a prerequisite claimed by their earlier local mocks.

**Gate 2:** all substep checks pass in order; one authoritative context is used by the current GUI; no ownership exclusion channel remains; dependency direction and stored formats are unchanged; writer hooks, revocable request records and lifecycle seams are implemented/tested, not deferred. Step 2 is not complete with only an unused runtime module or passing fake sink. No native/in-flight writer safety is claimed until its owning later gate passes.

## Step 3 — Harden the existing asynchronous musical writer

**Architectural dependency:** reuse Gate 1A policy/identity/planner owners. Refactor the existing `phrase_writer.finalize` into named prepare, stage, render, precommit, commit, rollback, cleanup and terminal phases around **one** job and one callback. Make job state explicit, eliminate duplicate phrase-layout assignment and unnecessary repeated validation **only where the same precommit/postcommit invariants remain proved**. Replace undocumented literals (`500` diagnostics, `+8` slack, `126/512` capacity fallbacks and `512/12/8` field loops) with named, API-derived or validated bounds while preserving fail-closed behavior; the pending-render diagnostic cannot become a timeout that releases occupancy. Test each extracted phase's abort/rollback conditions using the Gate 3 cases. No new writer or transaction authority.

Expose explicit `create(request, done)` and `regenerate(request, done)` facades around the existing writer job. Both share preparation/render/commit/cleanup helpers. Request fields are those from Step 2; regenerate additionally requires exact phrase object, ID, source baseline, and content baseline. Missing arguments reject; no default indices or mode inference. Return `false, rejection` only before accepting a job, with no mutation, occupied slot, or completion callback. Once accepted, return `true`; all later failures, including synchronous insertion/render-start failures, use `done(result)` after rollback/cleanup or recorded recovery. Completion may occur before the start call returns, so install the scheduler job first. It is **not** a synchronous rendered result.

**One completion channel:** An idempotent writer terminal transition calls `done` once when an accepted job retires. Results distinguish committed, canceled-cleaned, failed-cleaned, and integrity-blocked outcomes and carry job token, epoch, reason, committed baselines when applicable, and retained recovery facts. Adapt existing result/status handling centrally; do not create a second scheduler. Duplicate callbacks are ignored. A still-running native render is nonterminal even after cancellation; lack of a callback is not completion.

An integrity-blocked terminal result retires occupancy only after native rendering has finished (or never started); its song blocker remains. A missing render callback produces nonterminal diagnostics, never this terminal result. Keep writer retirement separate from GUI delivery so release can detach GUI callbacks without losing the one terminal bookkeeping transition.

`cancel(token, reason)` invalidates commit authorization and returns only whether that token matched a known job. Its return value never releases a scheduler or writer slot. Compile-wait cancellation can clean up and call `done` synchronously. Render-in-flight cancellation waits for the native callback. Change the current `live_regen` boolean-cancel shortcut accordingly: only the matching `done` transition retires its active job, and a blocked result prevents draining pending work. Stale completion retires its own bookkeeping without updating the GUI. Rejection handling and accepted-job completion must never both settle the same request.

Execute each job in this order:

1. Pure Lua validation/planning: validate frozen source/settings and existing compiler output, source-store candidate, guard, current song, instrument membership, and target classification. Regenerate requires exact phrase membership and globally unique ID; create requires explicit New intent and a fresh ID unique across live phrases **and stored entries**.
2. Preflight capacity using the documented limit. Retain current mechanism: create needs one free staging slot; regenerate needs two free slots for staging plus backup. Reject before insertion when insufficient. Recheck before each insertion because capacity may change during async work.
3. Describe the undo action before the first host mutation. Under the internal-mutation scope, insert/register the returned staging object with a neutral recovery/staging name that contains no ACID ownership ID. Never expose staging/backup objects as owned UI destinations or copy candidates.
4. Commit generated source and render to staging from `committed_observable`. The notification does not establish compilation success; the render callback/error and output validation determine the outcome. Bound commitment waiting to 500 idle callbacks. During rendering, 500 subsequent idle callbacks only report a pending-render diagnostic; retain staging and writer occupancy until native completion. Every idle/render callback checks job identity, terminal state, guard, current song, and staging membership before advancing; a canceled callback may perform safe cleanup only. No overlapping jobs or new timer scheduler. Verify native sequencing in Step 8.
5. Immediately before destination mutation, re-resolve live membership and recheck source/content/planning-input baselines, uniqueness, capacity, and guard. For regenerate, insert and privately record backup, copy the exact destination and give the backup a neutral non-owner name within one synchronous mutation scope, before any ownership/store validation or reconciliation. Verify backup coverage before touching the destination; retain the original destination name separately. Count every live phrase in ownership inventory; no temporary/caller exclusion exists. If neutralization fails, invalidate and clean up or block rather than bypass uniqueness. Preserve destination mapping/column metadata where copying would otherwise alter it.
6. Run a short synchronous commit section: copy verified stage into the same destination for regenerate, or promote the rendered stage itself for create with **no second insertion**; write the current ownership name/seal and commit source/settings plus removal of only the committed durable draft. No yield, idle wait, or user callback inside this section. Validate final identity, contents, source association, and membership.
7. If destination/store mutation fails, restore the exact destination from the verified backup and restore the guarded store candidate. Cleanup temporary objects only after rechecking their live identity. A failed create removes only its own inserted object. A failed regenerate must never leave a newly owned appended destination.
8. Cleanup stage/backup by current membership; never delete a guessed last index. If cleanup or restoration cannot be verified, retain the identifiable recovery object, surface a blocking integrity error, and stop later generation for the affected context until explicit revalidation. Do not report clean success while hiding a leaked recovery phrase.
9. Complete exactly once, returning the real committed destination object and new baselines. Successful regenerate returns the requested object. Update GUI only through the controller, after transaction completion.

Cancellation invalidates commit authorization first. The API has no render-cancel method: while a render is in flight, do not delete/change its stage, release the writer slot, or start a replacement job. On its callback, clear in-flight state and, if the song is still current, clean up by object identity without committing. Closing/reopening the dialog does not prevent that writer-only cleanup or allow stale GUI updates. If a callback never arrives, retain the neutral stage, report an integrity blocker, and do not guess that native rendering stopped.

On document release, clean up only objects not in use by native rendering while the old song is current. An in-flight stage must remain as explicitly reported recovery material with its preassigned non-owner name and no committed source association. Detach old-song observers and release host-object references from the job; retain only its Lua token/epoch and captured diagnostic text for the pending callback. The global native-render slot remains occupied across document changes until that callback arrives. A late callback retires only that exact job, reports its retained-stage outcome, and never accesses released host objects. It may unblock the new song's writer occupancy, but does not enqueue a write or clear a current-song integrity blocker; the user must make a fresh request. This exceptional retained stage is not a successful create or a silently accepted leak. Do not promise its deletion or rely on undocumented native render/delete ordering.

Before release returns, the callback closure/token registry must retain only a host-free job tombstone: remove song/instrument/phrase/stage/store references and detach closures that capture the old GUI/session. Late completion performs terminal bookkeeping and records diagnostic text only; it cannot deliver a stale GUI update.

Show pending cancellation immediately. Reuse the existing idle handler to report a prolonged missing callback after 500 subsequent idle notifications; this is diagnostic only, not proof rendering stopped and not permission to release the slot. Keep drafts recoverable and reject new writes while occupied. If the callback never arrives, no in-session action can safely force-release the native render; report that host restart is required to reset it, with the existing volatile-draft loss warning. Unload detaches handlers and preserves the stage; it is not proof that a native render stopped, and tool reload is not a supported force-cancel path.

Temporary objects may exist visibly during rendering, so “no write” tests distinguish pure preflight from async staging. Compile/render failures may have temporary host mutations; after verified cleanup, destination contents, committed sources, and phrase count remain unchanged.

**Gate 3:** Direct writer tests cover explicit modes, the create/regenerate free-slot boundaries, no retargeting, async compile/render failures, target edits/removal while waiting, exact-object rollback, store/draft failures, cleanup failure, single completion, cancel during in-flight render, and release/late callbacks with the documented recovery stage. Successful create adds one destination; regenerate retains the same destination and final count. Reuse these tests in Step 7; mocks do not establish native undo, compile timing, or playback.

## Step 4 — Implement explicit Make Independent

This is one metadata/source transaction in the writer, sharing Step 1 store/ownership helpers; it is not another render path.

1. Accept the instrument/phrase objects from the currently bound **ACID destination dropdown**, expected old name/ID/content/source baseline, and current session guard. Native selection may differ; do not read it as this action's target or write it. The writer uses the existing store allocator immediately before the transaction; never trust a GUI-allocated fresh ID.
2. Require exact live membership, a current valid seal, an existing old-ID collision, valid committed source/settings under that old ID, and Step 1's independent source/output compatibility check. Every live holder of that ID must have the same exact ownership name/seal and protected content snapshot as the selected phrase (compare values, not enclosing object references). Different valid seals, changed content, incompatible or unverifiable output, or a modified holder block resolution for the group: the shared record's intended association cannot be chosen safely. Use the narrow Step 1 reader, not a guessed original phrase. For 3+ matching holders, resolve only the selected holder and re-evaluate the remaining group.
3. Invalidate/cancel pending generation before this action and wait for verified cleanup. Revalidate selection, content, old record, and allocated fresh-ID uniqueness across live phrase names and stored entries after cancellation and immediately before commit. A missing source, modified content, active undo/redo, or integrity blocker rejects.
4. Prepare a clone of the old **committed** source/settings under the new ID, preserving the old entry, other entries, and durable drafts. Do not clone another holder's dirty draft. Keep per-object session drafts detached until matching baselines are checked.
5. Describe undo; in a short synchronous internal-mutation scope, commit the new source entry and change only the selected phrase's ownership name using the current name/seal format. The visible ID changes because the ID is stored in the name. Do not promise byte-identical names. Do not insert/delete, compile/render, change notes/effects or another holder.
6. Verify the new ID is unique, cloned committed source/settings match, selected content is unchanged, and old entry/other holders remain unchanged. On failure, restore both previous name and guarded song store; refuse to overwrite intervening changes and raise an integrity blocker if restoration cannot be verified.
7. Reclassify all holders through the shared reconciliation path and return selected object/new ID. Keep the same ACID-bound object selected. Initialize it from its cloned committed source; restore only an independently matching object-local draft. Do not delete or claim ownership of an ambiguous old-ID durable draft. Further holders remain blocked until unique.

**Gate 4:** Tests cover two/three matching holders, same-ID holders with different valid seals/content (reject without mutation), explicit selection without original inference, missing/corrupt records, changed hidden content, new-ID collision with orphaned stored entries, stale guards, failure after either mutation, unchanged musical content/other holders, and preservation of unrelated source/draft records. No observer can call this operation.

## Step 5 — Integrate drafts and the single generation request pipeline

**Architectural dependency:** collapse both GUI late-create draft-transfer blocks into one controller post-commit handler and use `runtime/draft_cache`'s exact capture/revision compare-and-clear protection, or replace it only with a proven equivalent single owner. Wire the already tested recovery APIs before considering any dead-code deletion. Consume Step 2 runtime arming authority; remove legacy scheduler arming mirrors once the unified queue uses that authority directly. Reuse Gate 1A's canonical editor projection and source freeze; do not add a second compilation or completion path.

1. Implement Step 1 draft precedence in existing `draft_cache`. Key session drafts by song/instrument/phrase objects; New Phrase has a per-instrument scratch entry. Do not use phrase position as identity.
2. On navigation, preserve outgoing edits before binding, then validate incoming ownership/source and restore its matching dirty draft before committed source. Programmatic widget updates are guarded and never counted as edits. Foreign/unavailable selection retains the outgoing buffer as a detached recovery entry; it does not reset it to defaults or associate it with foreign content.
3. Before every durable draft get/put/clear for an existing phrase, require exactly one live holder of its ID across the song. For collisions, use object-keyed session drafts only: never read one old-ID durable draft into multiple holders, overwrite/reassign it, or clear it. Preserve safe New Phrase persistence where existing name/index checks are unambiguous; otherwise retain a session draft and show the existing persistence/loss warning. Revalidate rather than adopting a reused instrument slot. No schema migration or new identity format.
4. On external modification/removal/collision, detach affected drafts. When detached entries exist, expose a small **Recover Draft** chooser with captured instrument/phrase labels, reason, and session-only status. With an explicit instrument and New Phrase selected, **Copy to New** copies the chosen source/settings into that scratch editor through a guarded programmatic update; it never requests generation, even while Live Edit is armed. Preserve any outgoing scratch draft as a separate recovery entry first. Keep the original recovered entry until that exact copied revision successfully creates a phrase or the user explicitly discards that entry. Failed or superseded generation preserves it. Selecting New alone never transfers content. Never recover by overwriting an unsafe phrase; never read an ambiguous durable collision record into this flow.
5. Wire Step 4 to the smallest Make Independent button/context action for the ACID-bound colliding phrase. Enable only when the whole collision group passes Step 4's unchanged seal/content/source checks; otherwise disable with the actual reason. Keep the same bound object after resolution; no M5 layout redesign. Route manual Generate and armed real edits into one `request_generation(trigger)`. Freeze source/settings and capture Step 2 token; call only the appropriate Step 3 facade. Arming, loading source/drafts, cursor/view changes, and no-op edits enqueue nothing.
6. Retain immediate single-flight scheduling. A newer edit invalidates the older uncommitted job and replaces one pending snapshot. Request cancellation, retain/coalesce the latest snapshot, and dispatch it only after that exact prior job's terminal callback retires writer occupancy and confirms no blocker; in-flight cancellation can remain pending indefinitely. Manual Generate supersedes pending Live Edit through the same lifecycle. A blocked result or document/session change discards pending authorization while preserving its draft. No retry spin or concurrent writer.
7. On a successful New create, bind the returned phrase object before any later request can start. On regenerate, require the same returned object. Apply completion/status/session-draft clearing only when that request's session, target, and revision remain current. Clear only the captured session draft through compare-and-clear; durable draft removal already occurred in the guarded store commit, never in a second GUI write. Never clear newer edits.
8. Preserve recoverable errors and armed status. A stale completion cannot select a target, replace a draft, erase an error, or release a newer job. Closing dialog invalidates/cancels work but preserves session drafts. Song reload reconstructs only successfully persisted, unambiguous records; do not promise durable collision drafts.
9. Provide **Revalidate** for an integrity blocker. It performs read-only checks: no render, ownership repair, store write, recovery deletion, or baseline adoption. Require no in-flight native render, verify recorded recovery/temporary objects are absent, and verify the affected destination/source against the recorded pre-transaction state or a completely verified committed state. Validate current live ownership/source associations and draft preconditions. Clear the blocker only if all relevant checks pass; require a fresh Generate/edit afterward, never drain an old pending request. If exact recovery objects remain after completed rendering, explain that the user must inspect/preserve them and remove them natively before revalidation; never suggest deletion while rendering may still use them. If destination/source consistency cannot be verified, keep the blocker and direct the user to native undo or a known-good saved song. Detached drafts remain available for recovery. Status includes the reason, blocker scope, captured recovery labels, and safe next action. Changing songs clears neither an unresolved global render slot nor evidence in a still-live blocked song.

**Gate 5:** Integration tests cover edit A → B → A with Live Edit off, multiple instruments/New scratches, foreign/detached recovery, dirty save/reopen under the stated durable-format limits, persistence failure warnings, no-op edits, rapid superseding edits, manual/Live Edit overlap, create-then-edit, stale completions, close/reopen, and source/settings isolation. Include one durable draft with two ID holders: neither holder may read/overwrite/clear it. Verify musical success removes only its committed draft atomically and failure retains it. Exercise recovery chooser/copy/discard, occupied scratch preservation, no generation on recovery while armed, and exact-revision clearing. Verify Revalidate is read-only, refuses active renders or remaining recovery objects, preserves detached drafts, and never clears a blocker merely on reopen or navigation.

## Step 6 — Attach native observers and reconcile internal changes

1. Attach stable functions to tool release/new/unload; song instruments/native selected instrument/native selected phrase; live instrument names/phrase lists; phrase names and needed content properties/line notifications. Use the exact pinned API. Reuse existing idle refresh for coalescing and detecting dialog visibility; do not add a second polling system.
2. List callbacks mark inventory dirty and invalidate external structural changes; rename/content callbacks mark the relevant views/target dirty. No observer invokes generation or Make Independent. New objects are classified from live membership and song records, never inferred as copies.
3. During a synchronous writer mutation scope, callbacks only mark dirty. At scope exit, require temporary identities to be neutral, record the resulting native selection pair as internally observed and schedule one reconciliation through Step 2 functions. Filter writer-private temporary objects from target choices only; ownership inventory always counts every live phrase. If scope completion fails, invalidate before reconciliation and retain recovery evidence.
4. Do not mask the entire async wait: native selection/content/list changes outside internal scopes invalidate pending work as appropriate. Compare object pairs, not selected indices. Native target changes after an internal scope are followed normally; unrelated refresh/rename keeps explicit New/local targets. If origin/order is uncertain, cancel the job and preserve the draft rather than guess.
5. Reconcile after internal changes without adopting a stage/backup or detaching an unchanged destination solely because temporary membership changed. Own final content/name changes update baselines only after verified commit. External edits never refresh the expected baseline into permission to overwrite them.
6. On release: invalidate, cancel with Step 3's in-flight-render recovery rule, detach nested listeners, clear old-song refs. On new document: fresh epoch, attach once, reconstruct live choices. On dialog close: invalidate/cancel and detach dialog-scoped listeners; retain writer completion handling until safe same-song cleanup and keep draft storage. On unload: invalidate jobs, detach all listeners/idle handlers, and preserve/report any stage still in use; do not assume native render cancellation.
7. Undo/redo notifications invalidate generation and request reconciliation only. Use documented `is_undo_redoing()` when needed; it is not copy authorization. Re-read persisted source/ownership after native undo, detaching incompatible drafts.
   Native undo was observed to leave `tool_data` at its newer value while restoring old phrase content/seal. Keep the affected association blocked after `is_undo_redoing()` becomes false until Step 1's independent source/output validation succeeds. Re-reading a valid record or adopting the restored seal as a new baseline cannot clear that block. Revalidation remains read-only and never rewrites source to match an inferred undo state.

**Gate 6:** Meaningful notifier mocks cover internal insert/copy/name/cleanup notifications without self-cancellation, external changes during async waits, native selection changes, New preservation on refresh, blocked duplicates, undo/redo invalidation, repeated opens/song changes, and zero old-song callbacks/leaked temporary records.

## Step 7 — Remove competing paths and run local/package checks

**Architecture closeout:** rerun Gate 1A's dependency/policy/codec equivalence checks against the integrated runtime. Delete internal compatibility shims, remaining duplicate callback/draft-movement logic and dead exports only after Steps 2–6 have replacement coverage. Keep one write authority and one terminal path; do not introduce a new architectural cleanup milestone.

1. Remove/redirect old musical writer callers, implicit append fallback, stale index caches, selection assignments, duplicate notifications, and abandoned delayed handlers. Internal stage/backup insertion remains legal only inside the guarded writer.
2. Keep one runtime target, one musical request entry point, explicit create/regenerate sharing one job implementation, one identity-only action, one ownership implementation, and existing draft/store owners. Avoid new abstractions without a concrete duplicate responsibility.
3. Update obsolete expectations; preserve compiler/sequencer regression coverage. Review the focused cases below against tests already added at earlier gates.
4. Run `./scripts/run_tests.ps1 -Tool ACID`, then `./scripts/run_tests.ps1` in PowerShell 7. No CI workflows or broad audio/timing matrix.
5. If runtime layout/package inputs change, run `./scripts/package.ps1 -Tool ACID`; inspect root `manifest.xml`/`main.lua`, private module paths, and absence of SDK/tests/docs. Do not change manifest/tool versions incidentally.
6. Review `git diff --check` and changed paths. Remove only this work's unrelated changes; preserve user work. Record local results without claiming playback or native undo acceptance.

| Case | Required regression |
|---|---|
| R01 | Navigation, opening and arming: no musical or identity write |
| R02 | Explicit New/create adds one phrase; bind actual returned object |
| R03 | Later Live Edit regenerates same object; final count stable |
| R04 | Owned edit touches only exact intended phrase |
| R05 | Foreign/unavailable edit or Generate never overwrites/appends |
| R06 | Insert/delete/reorder or same-index replacement cannot retarget |
| R07 | Instrument add/rename/remove/reorder updates choices without writes |
| R08 | External native selection during async work cancels stale commit |
| R09 | Dialog close/reopen and late completion cannot affect new session |
| R10 | Release/new song: safe cleanup or explicit in-flight recovery stage, no late object accesses |
| R11 | Duplicate IDs block every holder until explicit resolution |
| R12 | External visible/hidden/property/source changes fail validation |
| R13 | Pure preflight failure mutates nothing |
| R14 | Async compile/render failure cleans temporary objects; destination/source unchanged |
| R15 | Destination/store/cleanup failures: verified rollback or visible integrity blocker |
| R16 | Dirty A → B → A, collision draft isolation, unambiguous save/reopen, atomic committed-draft clearing |
| R17 | Repeated opens/documents: no notifier/job/idle leaks |
| R18 | Existing supported timing/articulation output remains unchanged |
| R19 | Same-instrument native duplicate: blocked, explicit independent ID/source, notes unchanged |
| R20 | Same-song cross-instrument copy: same explicit resolution and isolation |
| R21 | Whole-instrument duplicate: resolve valid owned holders individually; foreign untouched |
| R22 | Original/copy independent edits and save/reopen; no count growth |
| R23 | Preexisting 2/3+ matching collisions: selected holder only re-keyed; different valid seals/content reject |
| R24 | Missing-source cross-song/imported copy and invalid-source copy: no adoption |
| R25 | Capacity: create one slot, regenerate two; no insertion when insufficient |
| R26 | Own stage/backup/metadata notifications do not authorize or cancel unrelated work |
| R27 | Newer edit/manual request supersedes safely; no overlapping jobs |
| R28 | Re-key store/name failure preserves old association and unrelated/current drafts |
| R29 | Undo/redo invalidates work and reconstructs source/ownership without repair writes |
| R30 | Distinct phrases with identical lines and content-based equality remain separate targets; raw-identity cleanup cannot delete the other phrase |
| R31 | Start rejection has no callback; accepted synchronous failure, cancellation, and duplicate callback settle at most once through the terminal path |
| R32 | Canceled render retains global occupancy across close/song release; missing callback never permits another job; late callback touches no released host objects |
| R33 | Field-policy preservation and rollback cover metadata/mapping/script; unsupported preservation rejects before mutation |
| R34 | Explicit recovery chooser/copy/discard preserves source/settings and outgoing scratch; armed recovery never renders; failed create retains recovery |
| R35 | Song integrity blocker survives dialog reopen in the same live song; release drops exact recovery refs; reload reclassifies persisted state; read-only revalidation never auto-retries; unrelated song usable once global render settles |

**Gate 7:** All 35 focused regressions and existing local suites pass; package checks pass when required. R29 uses lifecycle mocks here; actual native undo behavior and the other native checks remain explicitly pending Step 8. Map every case to its test file/case and result in the existing checklist; a case label alone is not evidence.

## Step 8 — Native Renoise acceptance

Run focused Native scenarios or documented manual checks for each applicable behavior; use keyboard tests where UI routing matters. The test adapter must assert Renoise state independently of ACID's internal success result. An unexecuted check does not close native acceptance; track true visual/audio-only checks explicitly as manual. Test with the release-equivalent dev bundle in a verified Renoise GUI session on a disposable song, including a separate clean-release packaging check.

Use one disposable multi-instrument XRNS with owned and foreign phrases, from the installed tool bundle. Record case/pass/fail and reproducible defects. Do not start another capture/measurement project.

**A — Inventory and selection:** add/rename/delete/reorder sampler/VST instruments and phrases, rapidly switch native selection, keep New selected through unrelated refresh. Observe internal staging/backup additions without binding to them. No navigation/arming writes, callbacks into released songs, or duplicate listeners.

**B — Editing and drafts:** Generate once from New, edit repeatedly with Live Edit, navigate owned/foreign targets across instruments. Edit A with Live Edit off, visit B, return to A; dirty A wins. Close/reopen, save/reload dirty/committed source, and verify timing/PB/output policy stay with the correct target. Exercise Recover Draft → Copy to New with an occupied scratch and Live Edit armed: neither navigation nor recovery renders, both drafts remain recoverable, and only explicit Generate creates the destination. Check failure retention, exact-revision clearing, and selected-entry discard.

**C — Interruptions and copies:** interrupt both compile-wait and in-flight-render stages: switch target, remove/reorder target, close/reopen, and change songs. Check no stale destination/source commit, no deletion of an in-use render target, and verified cleanup after same-song completion. On document release during rendering, the Step 3 explicitly reported neutral recovery stage is the allowed safe fallback; verify late callbacks never touch released objects or newer jobs. Duplicate within an instrument, copy across instruments in the same song, and duplicate a mixed owned/foreign instrument. Each copied ID collision blocks both holders until Make Independent is invoked for an explicitly selected holder. Verify only that name/ID and cloned source entry change, notes/effects remain identical, original retains old ID/source, and both regenerate independently after resolution. Repeat with a preexisting 3-holder collision, save/reopen, and a source-less imported/cross-song copy. Source-less content stays blocked; no automatic adoption.

**D — Failure, capacity, and undo:** verify the bounded post-commit idle-settle behavior under normal/busy host operation and authoritative render/output error handling. Check capacity rejection with insufficient staging/backup slots and no leftovers after a completed recoverable compile/render failure. For create, regenerate, and Make Independent, undo/redo must leave phrase content/ownership and committed source/settings consistent, no orphaned owned destination or repair writes, and unrelated user actions intact. Use `describe_undo` / `describe_batch_undo` only as documented; asynchronous batching may split when other actions intervene. Verify actual grouping, not a mocked promise. If grouping splits, every reachable undo state must remain safe and clearly blocked where inconsistent; partial states may never silently authorize generation. A clean uninterrupted operation should present one meaningful undo action; fix the existing batching if it does not.

**E — Musical smoke:** use the established supported sampler/VST paths and a small existing timing set to check pitch/gate/accent/slide. No new audio metrics, WAV loopback capture, or broad transport matrix.

Across A–D, repeat the Step 0 sentinel-field round trip against the final writer, include distinct identical-content phrases, and exercise read-only Revalidate after a completed recovery failure. Confirm a pending native render blocks writes even after switching songs, then its late callback releases only its occupancy without touching old host objects or auto-starting a request. Missing/duplicate callbacks are injected in local mocks; do not claim native reproduction unless actually observed. Record unsupported-field preflight rejections explicitly rather than treating them as preservation passes.

**Gate 8:** A–E pass. If an API/lifecycle or rollback assumption fails, fix the responsible earlier step, rerun affected local checks and failed native cases. M4 remains open until acceptance succeeds; never relabel an unverified native check as passed.

## Step 9 — Final documentation and review

1. Update the existing roadmap/checklist and relevant README/manual guidance with final responsibilities, explicit copy resolution, capacity/staging limits, draft recovery guarantees, and actual acceptance outcomes. Remove superseded statements.
2. Review diff, file list, local/package results, and native A–E results. Keep diagnostics only when they have continuing regression value. No machine-specific paths or implementation-history prose in code.
3. Commit only the verified in-scope changes on `feature/hardening4` using Conventional Commits. Do not merge into `develop` or close M4 before acceptance.
4. Report touched areas, verification results, remaining blockers, and commit ID if created. A blocked/native-unverified implementation is not a completed M4.

## Stop conditions

At every step, stop and correct the responsible contract before advancing if: the dependency graph regains a require cycle or model-to-writer edge; a PB, velocity, planner or capability contract diverges across emitters and validators; a codec refactor changes persisted bytes or weakens guards; a writer can choose an implicit destination; an index becomes identity; regeneration falls back to create; a notifier renders/re-keys; a copy is adopted heuristically; an unchecked hidden/inactive field can be erased; a stale job can commit; a rollback overwrites newer data or deletes an unidentified object; a read-only/native selection property is assigned; an API member or timing guarantee is guessed; dirty drafts are silently discarded/rebound; or work expands into sequencer semantics/M5 redesign.

Use the pinned SDK references above as authoritative. Official fallback: [API-6.2 source tree](https://github.com/renoise/xrnx/tree/API-6.2). Do not ship or require SDK files from the tool.
