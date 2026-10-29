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
| Arming Live Edit and loading New/recovered drafts while armed request rendering; the GUI test expects the arming write | Steps 2/5: `gui.lua`, `tests/acid/acid_gui_views_spec.lua` |
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
| Ownership parsing, seal, complete phrase comparison | `writers.phrase_ownership`; no second ownership implementation |
| Canonical source/settings and durable draft serialization | `model.pattern_store`; preserve its format and guarded commit/restore helpers |
| Object-keyed session drafts and restoration precedence | `model.draft_cache`; preserve existing durable drafts where unambiguous |

Validation at the request boundary and writer boundary is intentional. Share pure validation helpers; the writer still checks live membership and ownership independently.

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
   other instruments. Registered temporary objects never count as owners. Cache
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
song-wide collisions, temporary-object exclusion, missing/corrupt entries,
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
| Raw/current membership, replacements, song-wide collisions, narrow entry reads and durable draft guards; temporary exclusions are authorized only by the Step 2/3 writer registration contract | `tests/acid/acid_live_identity_spec.lua`, `acid_phrase_persistence_spec.lua` | Pass; runtime integration remains in Steps 2/3 |
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

**Status:** pending. **Execution:** immediately after completed Gate 1 and **before Step 2**. Gate 1 stays recorded as complete; this is a new blocking Gate 1A, not a retroactive change to its evidence. Work 1A.1–1A.9 strictly in order. Each substep includes its own focused tests and a passing ACID suite before the next substep. Do not begin runtime integration until Gate 1A is complete.

**Goal:** eliminate inverted dependencies, the lazy module cycle, divergent musical policies, duplicated core operations and confirmed obsolete code while retaining exact musical output, accepted Step 1 data protections, current wire formats, and existing Renoise API 6.2 behavior. Refactor existing owners rather than introduce a service layer, migration, alternate serializer, new scheduler or another writer. No M5 GUI/layout work and no additional audio-capture matrix.

**Target dependency rule:** `model` (pure musical data/policies) is independent of `renoise`, `writers`, `runtime` and `gui`. `renoise` supplies host inspection/identity/storage adapters and may depend on `model`. `writers` depends on `model` and `renoise` but never on `runtime` or `gui`. `runtime` coordinates writers, drafts and host lifecycle; `gui` consumes runtime/model state. There must be **no require cycles**, including function-local/lazy requires. A pure function inside a host adapter does not justify duplicating the adapter in the model.

### 1A.1 — Freeze the post-Gate-1 baseline and dependency graph

1. Recheck `git status --short --branch` and current head; preserve unrelated work. Run `pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID` and record the actual outcome, not the historic 41-spec Gate 1 result as a new run.
2. Enumerate all static and function-local `require` edges across the 24 runtime modules, GUI and relevant test mocks. Record actual runtime callers and test-only callers for ``articulation.apply`, `gate_writer.apply`, `pattrns_writer.generate`, `memory_status`, `sequencer.describe`, `draft_cache.close`, `draft_cache.capture/is_current/compare_and_clear`, `draft_cache.list/discard/copy_to_new/restore`, and `live_regen.armed`. Mark **remove now / needed by Steps 2–6 / keep because it enforces a boundary**.
3. Establish byte/field-equivalence fixtures using existing `acid_output_planner_spec.lua`, `acid_pattrns_spec.lua`, `acid_legato_spec.lua`, `acid_pitch_bend_spec.lua`, `acid_phrase_persistence_spec.lua` and `acid_store_candidate_spec.lua`. Cover default/accent/unity velocity, Off and all supported PB ranges, straight/triplet and repeat/play-once, source/draft wire bytes, strict invalid input and unchanged output snapshots. Reuse the existing fixtures rather than create a second conformance matrix.

**Check:** call-site inventory has no inferred "unused" API, and baseline behavior is executable. Failed baseline tests are resolved or explicitly isolated before changing dependencies.

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

1. Introduce **one small pure** `model/policies.lua` for the actual shared policy: supported PB choices `0, 2, 12, 24, 48`, PB validation/default, volume input validation, the precise default/accent/unity velocity policy and quantization, and default output policy. Replace policy tables/literals in `output_planner`, `phrase_writer`, `pattern_store`, `draft_cache`, `editor_state`, `gui`, `pattrns_writer` and `legato` with that policy. Preserve default 0.7, the existing `floor(v * 128)`/unity-255 behavior, and `%.6f` pattrns emission; verify that emission, planning and note-column verification agree on quantized results, especially 0.7 → 89 and 1 → 255.
2. Use `sequencer.PAGE_SIZE` everywhere for page math; derive maximum pages from `sequencer.MAX_STEPS`. Make `sequencer` the owner of default source construction and of the Step-1-TIE rule. Setters, interpreter and validation may **check** the invariant at different boundaries, but reuse the same predicate/normalization policy rather than reimplement its meaning.
3. Share only truly identical numeric predicates (integer/range/volume); retain different rejection wording and validation at each trust boundary. Replace copied PB/velocity/page literals, not every integer in the program. Keep the persisted ownership hash algorithm, `v3:` identifiers, current source grammar and all current default values unchanged.

**Check:** policy tests exercise every PB value and rejection, fractional/NaN/edge velocity, both volume output paths and all gate/legato expectations. Formatting/normalization remains byte-compatible; Step-1-TIE and page navigation behave identically.

### 1A.5 — Make planner and capability contracts explicit

1. Replace the hidden object-identity assumption between `output_planner.plan` → `control_signals.compile` and `legato.plan` with one explicit semantic successor/steady-plan input or a single validated plan bundle. Its producer and consumers must check shape/association; never infer "same plan" from a coincidentally reused Lua table. Retain exact seam/legato/gate results.
2. Make `target_capabilities` the sole producer of the capability comparison contract; `phrase_writer.context_valid` calls that comparison or compares a canonical immutable snapshot. Do not manually concatenate or parse `|` signatures in consumers. Keep previously accepted capability-change invalidation and avoid a new persistent format.
3. Name and reuse rate/interval conversion and glide byte bounds where the same semantics appear in `articulation` and `output_planner`. Give loop-safety sentinels descriptive local constants, preserving termination behavior. Name the existing ownership-hash constants without changing the seal output. Do not alter Renoise-visible effect bytes.

**Check:** tests mutate successor identity/semantics and one capability field at a time, rejecting stale/mismatched requests; same-source output remains identical for loop seams, legato, bend endpoints and effect clamping. A regression must fail if either contract silently decouples.

### 1A.6 — Remove duplicate model-to-GUI transformations

1. Replace `gui.lua`'s hand-copied pattern freeze with `sequencer.copy_source`, preserving complete canonical source and rejecting invalid partial drafts at the **same** request boundary as before; never silently normalize a dirty entry into a different source.
2. Route every default/new/reset/source fallback through one `sequencer`-owned default-pattern factory and a single initialized settings policy. Remove four copied GUI `new_pattern(16)`/fill/reset implementations. Replace GUI page arithmetic with `PAGE_SIZE`, without changing two-page/32-step behavior.
3. Project/compile once per actual editor-state revision and reuse that validated projection within the refresh and input handler. Do not cache across a real edit, instrument/phrase binding change, timing/PB/output-policy change, or host invalidation. Keep refresh and navigation read-only, and preserve existing error presentation.

**Check:** editor/GUI timing-race, views, recovery and repeat tests demonstrate identical projection/serialization, no stale preview after edits or rebinding, and zero Generate/Live Edit writes on navigation/reset/arming. This does not yet unify runtime callbacks; that belongs to Step 5.

### 1A.7 — Deduplicate the store codec without changing its contract

1. In `renoise/pattern_store` extract one shared header/entry parser and one shared source token encoder/decoder for snapshot and DRAFT forms. Keep existing strict grammar, token ordering, field validation, maximum steps, `v3:`/magic markers and visible error categories. Do not invent a new blob protocol or silently accept malformed prior data.
2. Remove repeated pitch/TIME serialization and redundant recompilation **inside parsing** only when the resulting validation path is identical. Preserve candidate staging, captured/proposed source checks, verified write/readback, guarded restore, and atomic exact-draft removal. Raw-string equality alone is **not** transaction or destination authorization.
3. Compare pre/post refactor encoded bytes using saved fixtures, parse valid legacy/current records, reject malformed records, and replay uncertain/partial `tool_data` writes and late-draft scenarios with existing tests.

**Check:** all persistence, ownership, source-value, candidate and draft-recovery tests pass with byte-identical encoding and the same mutation/no-mutation outcomes. A simpler codec may not loosen any collision, binding or rollback safeguard.

### 1A.8 — Prune confirmed dead APIs, not future safety functionality

1. Delete `pattrns_writer.generate` if the 1A.1 caller audit confirms no production use; retain `emit`. Remove `memory_status`, `sequencer.describe`, `draft_cache.close` and unused exports only where test assertions can be redirected to the canonical state/behavior. Do not delete legitimate regression coverage merely to remove a module.
2. **Do not remove** `draft_cache.capture/is_current/compare_and_clear`: Step 1 hardened exact-revision clearing, and Step 5 must use or deliberately subsume it in the one completion path. **Do not remove** `list/discard/copy_to_new/restore` before Step 5 wires Recover Draft and proves occupied-scratch and persistence guards. The absence of a current GUI caller is not proof these contracts are obsolete.
3. Defer `live_regen.armed` to Step 5's single-flight controller cutover. Keep one public arming state or remove redundant fields **then**, with appropriate tests. Inventory remaining test-only helpers and delete only proven dead paths; no compatibility stubs for internal APIs.

**Check:** source searches find no orphan imports, function references or fake obsolete test paths. Replaced tests still prove the original safety and musical behavior.

### 1A.9 — Gate 1A: complete the cutover before runtime integration

1. Run each affected direct spec after its substep, then `pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID` and `pwsh -NoProfile -File ./scripts/run_tests.ps1`. Use a small `tests/acid/acid_dependency_graph_spec.lua` (or an equivalent existing test) to fail on inverted `model` dependencies, cycles, stale module names and unexpected duplicate policy definitions. No CI service or new testing framework.
2. Run `pwsh -NoProfile -File ./scripts/package.ps1 -Tool ACID` and inspect archive roots/private runtime modules and absence of deprecated names, SDK and tests. Check `git diff --check` and changed paths. Preserve unrelated changes and do not change manifest versions.
3. Record one compact Gate 1A matrix: substep, changed owners, tests executed/results, and any blocker. Do **not** mark the gate complete by copying Step 1 results, and do not claim native behavior from mocks. If a pure refactor changes output, store bytes, ownership/source authorization, or draft survival, revert that change or repair it and rerun affected cases before advancing.

**Gate 1A:** dependency graph acyclic and downward-only; no competing/legacy writer entry points; PB/volume/default/TIE/capability/planner rules have single authorities; GUI source projection and store codec are nonduplicated; confirmed dead code is removed without deleting recovery protections; all targeted, ACID, full-suite and packaging checks pass. **Then** start Step 2. Native lifecycle/undo/musical smoke remains Step 8.

**Carry forward without premature rewriting:** Step 2 owns the operation token and runtime blocker state; Step 3 must decompose `phrase_writer.finalize` into explicit prepare/stage/render/precommit/commit/rollback/cleanup/terminal helpers around **one** job, replace `500` idle diagnostics, `+8` event slack and `126/512` fallback literals with named API-derived or justified bounds, and use passed capacities in validator/snapshot loops without weakening preflight. Step 5 must replace the duplicated GUI late-create draft-movement blocks with one successful-commit handler, consume exact-revision capture guards, remove redundant arming state, and route both manual and Live Edit through one scheduler. Step 6 owns watcher/lifecycle deduplication. Step 7 removes leftovers and enforces the final graph; do not migrate these flows into parallel Step 1A implementations.


## Step 2 — Centralize runtime state, transitions, and operation guards

**Prerequisite:** Gate 1A passes. Consume the new `renoise`/`runtime` ownership boundaries and shared policy contracts; do not restore old `model → writers` imports or duplicate state in the GUI.

1. Consolidate one runtime context with song object/epoch, dialog session, explicit instrument/destination objects, target revision, edit revision, and operation revision. Keep only counters used to invalidate work. Store New Phrase as a synthetic option, never `#phrases + 1`.
2. A target is New, Owned, Foreign, or Unavailable using Step 1 validators. Removed/same-index replacement objects remain detached; never adopt the replacement. Changing instrument rebuilds choices from that exact instrument.
3. Define entry points for native/local selection, inventory invalidation, draft edits, Live Edit toggle, Generate, Make Independent, document lifecycle, dialog close, and completion. They may be local functions, not a new event framework.
4. Snapshot each request's song/epoch, dialog session, instrument, destination kind/object/ID, target/edit/operation revisions, frozen source/settings, committed source baseline, and complete target content baseline. Guards compare current state and live membership. Newer source edits, target/session/song changes, collisions, undo/redo processing, and superseding requests invalidate pending work.
5. Revisions change on real state changes, not on every refresh. A retained object keeps identity across reorder. Last-observed native object pairs distinguish selection changes from renames/refreshes; internal structural selection effects are handled in Step 6.
6. Provide a minimal internal-mutation scope and registered transaction-object set for the writer. Registration is the sole authority for excluding a temporary object from ownership checks: only an object inserted and recorded by the active writer operation, still verified by raw-identity membership in that song, may be excluded. Do not accept caller-supplied exclusion sets or exclude an ordinary phrase to make an ID appear unique. Observer callbacks within a synchronous mutation scope only mark dirty. Never keep that scope active across the asynchronous render wait; external edits must remain detectable.
7. Represent integrity blockers in this runtime context, keyed by song object/epoch, with reason and exact retained-object records. They block Generate, Live Edit writes, and Make Independent throughout that song; ordinary Foreign/Unavailable classification blocks only that target. Reopening the dialog does not clear a blocker. A separate global writer occupancy protects an unresolved native render even after document release; it is not cleared by changing songs. Step 5 defines the explicit revalidation action.

Keep this context outside the dialog's lifetime. Exact recovery-object records live only while their song is current and are dropped on document release along with all nested listeners and old-song references. XRNS reload creates a new epoch: reconstruct safety from current ownership/source validation, not the previous session's blocker or baseline. Neutral recovery phrases reload as Foreign and are never automatically deleted or adopted by their names. Session blocker persistence across host restart/song reload is not promised by the unchanged storage format; Steps 1/6 must implement and test independent source/output compatibility validation after reload, and Step 8 must verify that persisted inconsistent states cannot silently regain authorization. Step 0 observed the undo failure; it did not establish reload safety.

**Gate 2:** State/guard tests use a stub request sink/authorization predicate; the writer facade is integrated in Step 3. Prove navigation and arming make zero generation requests, blocked targets cannot authorize a request, and stale targets/sessions/edits fail guards. Include two distinct phrase mocks sharing a content-based `__eq`: identical lines must not merge targets, draft keys, or temporary-object membership. Prove an ordinary colliding phrase cannot be omitted from ownership checks through a caller-provided exclusion. The state contracts needed by the writer are implemented, not deferred to GUI integration.

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
5. Immediately before destination mutation, re-resolve live membership and recheck source/content baselines, uniqueness, capacity, and guard. For regenerate, create/register backup, copy the exact destination, give the backup a neutral non-owner name, and verify backup coverage before touching the destination; retain the original destination name separately. Exclude only temporary objects registered by this active writer operation and still verified by raw-identity membership from ownership-ID checks. Never pass an arbitrary caller exclusion or omit an ordinary phrase to make an ID appear unique. Preserve destination mapping/column metadata where copying would otherwise alter it.
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

**Architectural dependency:** collapse both GUI late-create draft-transfer blocks into one controller post-commit handler and use `runtime/draft_cache`'s exact capture/revision compare-and-clear protection, or replace it only with a proven equivalent single owner. Wire the already tested recovery APIs before considering any dead-code deletion. Reconcile `live_regen.armed` with the one real arming state; do not maintain two ignored flags. Reuse Gate 1A's canonical editor projection and source freeze; do not add a second compilation or completion path.

1. Implement Step 1 draft precedence in existing `draft_cache`. Key session drafts by song/instrument/phrase objects; New Phrase has a per-instrument scratch entry. Do not use phrase position as identity.
2. On navigation, preserve outgoing edits before binding, then validate incoming ownership/source and restore its matching dirty draft before committed source. Programmatic widget updates are guarded and never counted as edits. Foreign/unavailable selection retains the outgoing buffer as a detached recovery entry; it does not reset it to defaults or associate it with foreign content.
3. Before every durable draft get/put/clear for an existing phrase, require exactly one live holder of its ID across the song. For collisions, use object-keyed session drafts only: never read one old-ID durable draft into multiple holders, overwrite/reassign it, or clear it. Preserve safe New Phrase persistence where existing name/index checks are unambiguous; otherwise retain a session draft and show the existing persistence/loss warning. Revalidate rather than adopting a reused instrument slot. No schema migration or new identity format.
4. On external modification/removal/collision, detach affected drafts. When detached entries exist, expose a small **Recover Draft** chooser with captured instrument/phrase labels, reason, and session-only status. With an explicit instrument and New Phrase selected, **Copy to New** copies the chosen source/settings into that scratch editor through a guarded programmatic update; it never requests generation, even while Live Edit is armed. Preserve any outgoing scratch draft as a separate recovery entry first. Keep the original recovered entry until that exact copied revision successfully creates a phrase or the user explicitly discards that entry. Failed or superseded generation preserves it. Selecting New alone never transfers content. Never recover by overwriting an unsafe phrase; never read an ambiguous durable collision record into this flow.
5. Wire Step 4 to the smallest Make Independent button/context action for the ACID-bound colliding phrase. Enable only when the whole collision group passes Step 4's unchanged seal/content/source checks; otherwise disable with the actual reason. Keep the same bound object after resolution; no M5 layout redesign. Route manual Generate and armed real edits into one `request_generation(trigger)`. Freeze source/settings and capture Step 2 token; call only the appropriate Step 3 facade. Arming, loading source/drafts, cursor/view changes, and no-op edits enqueue nothing.
6. Retain immediate single-flight scheduling. A newer edit invalidates the older uncommitted job and replaces one pending snapshot. Request cancellation, retain/coalesce the latest snapshot, and dispatch it only after that exact prior job's terminal callback retires writer occupancy and confirms no blocker; in-flight cancellation can remain pending indefinitely. Manual Generate supersedes pending Live Edit through the same lifecycle. A blocked result or document/session change discards pending authorization while preserving its draft. No retry spin or concurrent writer.
7. On a successful New create, bind the returned phrase object before any later request can start. On regenerate, require the same returned object. Apply completion/status/session-draft clearing only when that request's session, target, and revision remain current. Clear only the captured session draft through compare-and-clear; durable draft removal already occurred in the guarded store commit, never in a second GUI write. Never clear newer edits.
8. Preserve recoverable errors and armed status. A stale completion cannot select a target, replace a draft, erase an error, or release a newer job. Closing dialog invalidates/cancels work but preserves session drafts. Song reload reconstructs only successfully persisted, unambiguous records; do not promise durable collision drafts.
9. Provide **Revalidate** for an integrity blocker. It performs read-only checks: no render, ownership repair, store write, recovery deletion, or baseline adoption. Require no in-flight native render, verify registered temporary objects are absent, and verify the affected destination/source against the recorded pre-transaction state or a completely verified committed state. Validate current live ownership/source associations and draft preconditions. Clear the blocker only if all relevant checks pass; require a fresh Generate/edit afterward, never drain an old pending request. If exact recovery objects remain after completed rendering, explain that the user must inspect/preserve them and remove them natively before revalidation; never suggest deletion while rendering may still use them. If destination/source consistency cannot be verified, keep the blocker and direct the user to native undo or a known-good saved song. Detached drafts remain available for recovery. Status includes the reason, blocker scope, captured recovery labels, and safe next action. Changing songs clears neither an unresolved global render slot nor evidence in a still-live blocked song.

**Gate 5:** Integration tests cover edit A → B → A with Live Edit off, multiple instruments/New scratches, foreign/detached recovery, dirty save/reopen under the stated durable-format limits, persistence failure warnings, no-op edits, rapid superseding edits, manual/Live Edit overlap, create-then-edit, stale completions, close/reopen, and source/settings isolation. Include one durable draft with two ID holders: neither holder may read/overwrite/clear it. Verify musical success removes only its committed draft atomically and failure retains it. Exercise recovery chooser/copy/discard, occupied scratch preservation, no generation on recovery while armed, and exact-revision clearing. Verify Revalidate is read-only, refuses active renders or remaining recovery objects, preserves detached drafts, and never clears a blocker merely on reopen or navigation.

## Step 6 — Attach native observers and reconcile internal changes

1. Attach stable functions to tool release/new/unload; song instruments/native selected instrument/native selected phrase; live instrument names/phrase lists; phrase names and needed content properties/line notifications. Use the exact pinned API. Reuse existing idle refresh for coalescing and detecting dialog visibility; do not add a second polling system.
2. List callbacks mark inventory dirty and invalidate external structural changes; rename/content callbacks mark the relevant views/target dirty. No observer invokes generation or Make Independent. New objects are classified from live membership and song records, never inferred as copies.
3. During a synchronous writer mutation scope, callbacks only mark dirty. At scope exit, record the resulting native selection pair as internally observed and schedule one reconciliation. Exclude registered temporary objects from target choices and ownership inventory.
4. Do not mask the entire async wait: native selection/content/list changes outside internal scopes invalidate pending work as appropriate. Compare object pairs, not selected indices. Native target changes after an internal scope are followed normally; unrelated refresh/rename keeps explicit New/local targets. If origin/order is uncertain, cancel the job and preserve the draft rather than guess.
5. Reconcile after internal changes without adopting a stage/backup or detaching an unchanged destination solely because temporary membership changed. Own final content/name changes update baselines only after verified commit. External edits never refresh the expected baseline into permission to overwrite them.
6. On release: invalidate, cancel with Step 3's in-flight-render recovery rule, detach nested listeners, clear old-song refs. On new document: fresh epoch, attach once, reconstruct live choices. On dialog close: invalidate/cancel and detach dialog-scoped listeners; retain writer completion handling until safe same-song cleanup and keep draft storage. On unload: invalidate jobs, detach all listeners/idle handlers, and preserve/report any stage still in use; do not assume native render cancellation.
7. Undo/redo notifications invalidate generation and request reconciliation only. Use documented `is_undo_redoing()` when needed; it is not copy authorization. Re-read persisted source/ownership after native undo, detaching incompatible drafts.
   Native undo was observed to leave `tool_data` at its newer value while restoring old phrase content/seal. Keep the affected association blocked after `is_undo_redoing()` becomes false until Step 1's independent source/output validation succeeds. Re-reading a valid record or adopting the restored seal as a new baseline cannot clear that block. Revalidation remains read-only and never rewrites source to match an inferred undo state.

**Gate 6:** Meaningful notifier mocks cover internal insert/copy/name/cleanup notifications without self-cancellation, external changes during async waits, native selection changes, New preservation on refresh, blocked duplicates, undo/redo invalidation, repeated opens/song changes, and zero old-song callbacks/leaked registrations.

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
