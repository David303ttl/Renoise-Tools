# M4.7 — ACID runtime refactor and integration hardening

**Branch:** `feature/hardening4`

**Execution:** Steps 0–9 are dependency-ordered. Finish each gate before starting the next; failed evidence sends work back to the responsible contract, then through affected gates again. Tests are added with the behavior they verify, not deferred to Step 7. Step 0 includes a small native feasibility gate before runtime changes; Step 8 remains full native acceptance.

**Final status:** M4 stays OPEN until native Renoise acceptance passes.

**Scope:** Runtime binding, writer safety, native synchronization, Live Edit, explicit copied-ID resolution, and source/draft recovery. Preserve sequencer/compiler semantics, timing, articulation, current persistence formats, manifest versions, and M5 layout.

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

Implement these small helpers in existing ownership/store modules before callers depend on them:

1. Normal owned-source load still rejects duplicate IDs across the **entire live song**. Read names for the global ID inventory; do not repeatedly hash every phrase during GUI refresh.
2. Add a narrow source-entry read for Make Independent: decode/validate the entry for a specified old ID without declaring any colliding phrase uniquely owned. Do not weaken normal `store.load`.
3. Preserve the current persisted seal format. Add one deterministic, session-only content snapshot/comparison used for target checks, metadata-only verification, and rollback. Compare actual values, not only the existing short hash.
   Before classifying an existing destination as writable, independently verify that its musical output matches its saved canonical source and output settings using the deterministic compiler/layout/articulation validators plus complete field preflight. Prove the validator's coverage; do not assume the current validator already establishes this association. A source record whose expected output differs from the unchanged sealed phrase must fail, including after undo, save and reload. This establishes output compatibility, not historical provenance: distinct sources producing identical verified output are indistinguishable. Reconstruct receiver/PB-dependent expectations only when their inputs are known; otherwise block. If the association cannot be verified without rendering or changing native state, block regeneration and preserve source for explicit recovery to New. A session baseline may retain a previously verified exact source/output pair, but a fresh session must not seed trust from seal and source validity alone. No schema or seal-format migration is authorized.
4. Cover the values the transaction can overwrite: all note/effect fields in every available column, including hidden columns, through the API's full phrase line range; line count, LPB, shuffle, loop/key/playback/autoseek settings, visibility, and column mute/name values. Check mapping/script preservation by the existing copy/rollback mechanism; add comparison only where that mechanism can alter them. Inspect each relevant definition before reading it. Preserve the mapping through its documented fields rather than assigning a mapping object; the pinned reference does not explicitly document whether that reference is writable. Do not toggle playback mode merely to inspect a script.
5. The old persisted seal does not protect hidden cells. For previously generated owned phrases, reject nonempty hidden note/effect cells or retained cells beyond the active line count before destructive regeneration; generated output must leave those cells empty. If inactive script/mapping data cannot be preserved and verified using the existing transaction, block that target rather than erase it. Do not extend the persisted schema to disguise an unverifiable baseline.
6. Store candidates preserve unrelated committed entries and **current** durable drafts. A successful musical commit removes only its own committed target draft in the same guarded store candidate; the draft rebase must not reintroduce that entry. Failed commits restore it. A create clears its own New scratch record only if it is still the captured draft/destination; otherwise preserve it. Compare source/draft preconditions before commit. Restore prior raw `tool_data` only if current data still equals this transaction's written candidate; otherwise retain newer data and report an integrity blocker.
7. Define draft precedence now for later integration: validate committed ownership/source first; restore a matching dirty draft for the same object/ID ahead of committed source; if none, use committed source. Session drafts retain the source/content baseline captured when first edited; if that baseline changes, detach the draft instead of rebasing silently. Existing durable drafts have no historical baseline field: after reload, restore them only against a uniquely owned, valid current target with the matching ID, and describe them as recovered edits. Do not claim historical-baseline verification across restart or add a schema migration. New Phrase restores that instrument's scratch draft.
8. Collision drafts are object-keyed and recoverable in-session only. Existing durable draft records cannot safely distinguish two copies sharing one ID. Never overwrite/reassign such a record merely because a colliding phrase was selected.

**Field policy for successful regeneration:** Snapshot all categories below before mutation and restore all of them on rollback. Make Independent changes only the ownership name and cloned source entry; every other category stays unchanged.

| Category | Successful regeneration policy |
|---|---|
| Note/effect cells, line count, LPB, shuffle, phrase loop settings, playback mode, key tracking | Replace with the existing compiler/writer's validated output and layout; retain existing musical semantics. Hidden and inactive tail cells must be empty before destructive regeneration and after generation. |
| Note-column names/mutes, phrase `base_note`, `autoseek`, visibility settings | Read note-column metadata through phrase `column_name(column)` / `column_is_muted(column)` and restore through their documented setters, across all note columns. Preserve destination values; visibility must still expose every column/subcolumn required by generated output. Reject incompatible visibility before mutation rather than hide output or silently change user metadata. Create uses existing validated writer defaults. |
| Mapping presence, `key_tracking`, `base_note`, `note_range`, `looping`, `loop_start`, `loop_end` | Preserve on the same destination through the proven native path. Mapping fields are separate from similarly named phrase fields. Reject if the generated layout conflicts with mapping constraints or preservation cannot be verified. Never assign the mapping object. |
| Inactive script paragraphs, pending/committed state, parameter values, editor state | Preserve only where the native feasibility check establishes a readable and restorable path. The generated stage's script must not silently replace the destination's inactive script. Reject unverifiable targets; do not toggle playback mode to probe them or invent setters for read-only state. |
| Ownership name and committed source/settings | Replace together under the guarded transaction and verify the new association. Preserve every unrelated source entry. |
| Session/durable drafts | Clear only the exact committed draft under its captured preconditions; preserve newer, unrelated, detached, and ambiguous records. |

Represent detached recovery entries in `draft_cache` with session-local keys, captured source/settings/baselines, display labels, and detachment reason. Provide narrow list/copy/discard operations for Step 5; no new persisted format. Display labels are presentation only, never lookup identity.

**Gate 1:** Focused tests cover strict normal load, validated collision-source read, missing/corrupt source, hidden-cell protection, complete value comparison, preservation of unrelated entries/current drafts, and refusal to roll back over newer store data. No Renoise mutation is needed to test these pure contracts.

## Step 2 — Centralize runtime state, transitions, and operation guards

1. Consolidate one runtime context with song object/epoch, dialog session, explicit instrument/destination objects, target revision, edit revision, and operation revision. Keep only counters used to invalidate work. Store New Phrase as a synthetic option, never `#phrases + 1`.
2. A target is New, Owned, Foreign, or Unavailable using Step 1 validators. Removed/same-index replacement objects remain detached; never adopt the replacement. Changing instrument rebuilds choices from that exact instrument.
3. Define entry points for native/local selection, inventory invalidation, draft edits, Live Edit toggle, Generate, Make Independent, document lifecycle, dialog close, and completion. They may be local functions, not a new event framework.
4. Snapshot each request's song/epoch, dialog session, instrument, destination kind/object/ID, target/edit/operation revisions, frozen source/settings, committed source baseline, and complete target content baseline. Guards compare current state and live membership. Newer source edits, target/session/song changes, collisions, undo/redo processing, and superseding requests invalidate pending work.
5. Revisions change on real state changes, not on every refresh. A retained object keeps identity across reorder. Last-observed native object pairs distinguish selection changes from renames/refreshes; internal structural selection effects are handled in Step 6.
6. Provide a minimal internal-mutation scope and registered transaction-object set for the writer. Observer callbacks within a synchronous mutation scope only mark dirty. Never keep that scope active across the asynchronous render wait; external edits must remain detectable.
7. Represent integrity blockers in this runtime context, keyed by song object/epoch, with reason and exact retained-object records. They block Generate, Live Edit writes, and Make Independent throughout that song; ordinary Foreign/Unavailable classification blocks only that target. Reopening the dialog does not clear a blocker. A separate global writer occupancy protects an unresolved native render even after document release; it is not cleared by changing songs. Step 5 defines the explicit revalidation action.

Keep this context outside the dialog's lifetime. Exact recovery-object records live only while their song is current and are dropped on document release along with all nested listeners and old-song references. XRNS reload creates a new epoch: reconstruct safety from current ownership/source validation, not the previous session's blocker or baseline. Neutral recovery phrases reload as Foreign and are never automatically deleted or adopted by their names. Session blocker persistence across host restart/song reload is not promised by the unchanged storage format; Steps 1/6 must implement and test independent source/output compatibility validation after reload, and Step 8 must verify that persisted inconsistent states cannot silently regain authorization. Step 0 observed the undo failure; it did not establish reload safety.

**Gate 2:** State/guard tests use a stub request sink/authorization predicate; the writer facade is integrated in Step 3. Prove navigation and arming make zero generation requests, blocked targets cannot authorize a request, and stale targets/sessions/edits fail guards. Include two distinct phrase mocks sharing a content-based `__eq`: identical lines must not merge targets, draft keys, or temporary-object membership. The state contracts needed by the writer are implemented, not deferred to GUI integration.

## Step 3 — Harden the existing asynchronous musical writer

Expose explicit `create(request, done)` and `regenerate(request, done)` facades around the existing writer job. Both share preparation/render/commit/cleanup helpers. Request fields are those from Step 2; regenerate additionally requires exact phrase object, ID, source baseline, and content baseline. Missing arguments reject; no default indices or mode inference. Return `false, rejection` only before accepting a job, with no mutation, occupied slot, or completion callback. Once accepted, return `true`; all later failures, including synchronous insertion/render-start failures, use `done(result)` after rollback/cleanup or recorded recovery. Completion may occur before the start call returns, so install the scheduler job first. It is **not** a synchronous rendered result.

**One completion channel:** An idempotent writer terminal transition calls `done` once when an accepted job retires. Results distinguish committed, canceled-cleaned, failed-cleaned, and integrity-blocked outcomes and carry job token, epoch, reason, committed baselines when applicable, and retained recovery facts. Adapt existing result/status handling centrally; do not create a second scheduler. Duplicate callbacks are ignored. A still-running native render is nonterminal even after cancellation; lack of a callback is not completion.

An integrity-blocked terminal result retires occupancy only after native rendering has finished (or never started); its song blocker remains. A missing render callback produces nonterminal diagnostics, never this terminal result. Keep writer retirement separate from GUI delivery so release can detach GUI callbacks without losing the one terminal bookkeeping transition.

`cancel(token, reason)` invalidates commit authorization and returns only whether that token matched a known job. Its return value never releases a scheduler or writer slot. Compile-wait cancellation can clean up and call `done` synchronously. Render-in-flight cancellation waits for the native callback. Change the current `live_regen` boolean-cancel shortcut accordingly: only the matching `done` transition retires its active job, and a blocked result prevents draining pending work. Stale completion retires its own bookkeeping without updating the GUI. Rejection handling and accepted-job completion must never both settle the same request.

Execute each job in this order:

1. Pure Lua validation/planning: validate frozen source/settings and existing compiler output, source-store candidate, guard, current song, instrument membership, and target classification. Regenerate requires exact phrase membership and globally unique ID; create requires explicit New intent and a fresh ID unique across live phrases **and stored entries**.
2. Preflight capacity using the documented limit. Retain current mechanism: create needs one free staging slot; regenerate needs two free slots for staging plus backup. Reject before insertion when insufficient. Recheck before each insertion because capacity may change during async work.
3. Describe the undo action before the first host mutation. Under the internal-mutation scope, insert/register the returned staging object with a neutral recovery/staging name that contains no ACID ownership ID. Never expose staging/backup objects as owned UI destinations or copy candidates.
4. Commit generated source and render to staging from `committed_observable`. The notification does not establish compilation success; the render callback/error and output validation determine the outcome. Bound commitment waiting to 500 idle callbacks. During rendering, 500 subsequent idle callbacks only report a pending-render diagnostic; retain staging and writer occupancy until native completion. Every idle/render callback checks job identity, terminal state, guard, current song, and staging membership before advancing; a canceled callback may perform safe cleanup only. No overlapping jobs or new timer scheduler. Verify native sequencing in Step 8.
5. Immediately before destination mutation, re-resolve live membership and recheck source/content baselines, uniqueness, capacity, and guard. For regenerate, create/register backup, copy the exact destination, give the backup a neutral non-owner name, and verify backup coverage before touching the destination; retain the original destination name separately. Exclude registered temporary objects from every ownership-ID check. Preserve destination mapping/column metadata where copying would otherwise alter it.
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

1. Implement Step 1 draft precedence in existing `draft_cache`. Key session drafts by song/instrument/phrase objects; New Phrase has a per-instrument scratch entry. Do not use phrase position as identity.
2. On navigation, preserve outgoing edits before binding, then validate incoming ownership/source and restore its matching dirty draft before committed source. Programmatic widget updates are guarded and never counted as edits. Foreign/unavailable selection retains the outgoing buffer as a detached recovery entry; it does not reset it to defaults or associate it with foreign content.
3. Before every durable draft get/put/clear for an existing phrase, require exactly one live holder of its ID across the song. For collisions, use object-keyed session drafts only: never read one old-ID durable draft into multiple holders, overwrite/reassign it, or clear it. Preserve safe New Phrase persistence where existing name/index checks are unambiguous; otherwise retain a session draft and show the existing persistence/loss warning. Revalidate rather than adopting a reused instrument slot. No schema migration or new identity format.
4. On external modification/removal/collision, detach affected drafts. When detached entries exist, expose a small **Recover Draft** chooser with captured instrument/phrase labels, reason, and session-only status. With an explicit instrument and New Phrase selected, **Copy to New** copies the chosen source/settings into that scratch editor through a guarded programmatic update; it never requests generation, even while Live Edit is armed. Preserve any outgoing scratch draft as a separate recovery entry first. Keep the original recovered entry until that exact copied revision successfully creates a phrase or the user explicitly discards that entry. Failed or superseded generation preserves it. Selecting New alone never transfers content. Never recover by overwriting an unsafe phrase; never read an ambiguous durable collision record into this flow.
5. Wire Step 4 to the smallest Make Independent button/context action for the ACID-bound colliding phrase. Enable only when the whole collision group passes Step 4's unchanged seal/content/source checks; otherwise disable with the actual reason. Keep the same bound object after resolution; no M5 layout redesign. Route manual Generate and armed real edits into one `request_generation(trigger)`. Freeze source/settings and capture Step 2 token; call only the appropriate Step 3 facade. Arming, loading source/drafts, cursor/view changes, and no-op edits enqueue nothing.
6. Retain immediate single-flight scheduling. A newer edit invalidates the older uncommitted job and replaces one pending snapshot. Request cancellation, retain/coalesce the latest snapshot, and dispatch it only after that exact prior job's terminal callback retires writer occupancy and confirms no blocker; in-flight cancellation can remain pending indefinitely. Manual Generate supersedes pending Live Edit through the same lifecycle. A blocked result or document/session change discards pending authorization while preserving its draft. No retry spin or concurrent writer.
7. On a successful New create, bind the returned phrase object before any later request can start. On regenerate, require the same returned object. Apply completion/status/draft clearing only when that request's session, target, and revision remain current. Clear only the draft actually committed; never clear newer edits.
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

At every step, stop and correct the responsible contract before advancing if: a writer can choose an implicit destination; an index becomes identity; regeneration falls back to create; a notifier renders/re-keys; a copy is adopted heuristically; an unchecked hidden/inactive field can be erased; a stale job can commit; a rollback overwrites newer data or deletes an unidentified object; a read-only/native selection property is assigned; an API member or timing guarantee is guessed; dirty drafts are silently discarded/rebound; or work expands into sequencer semantics/M5 redesign.

Use the pinned SDK references above as authoritative. Official fallback: [API-6.2 source tree](https://github.com/renoise/xrnx/tree/API-6.2). Do not ship or require SDK files from the tool.
