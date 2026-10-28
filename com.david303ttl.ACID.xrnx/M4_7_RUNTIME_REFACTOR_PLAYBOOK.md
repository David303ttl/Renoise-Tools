# M4.7 — ACID Runtime Architecture Refactor & Integration Hardening

**Branch:** `feature/hardening4`  
**Execution:** Strictly sequential. Complete each gate before starting the next.  
**Final status:** M4 remains OPEN until real Renoise acceptance succeeds.  
**Scope:** Runtime state, writer contracts, destination identity, copied-phrase ownership forking, Renoise synchronization, Live Edit lifecycle, drafts, targeted regression tests. Preserve the existing 303 sequencer, compiler, musical behavior, and M5 GUI scope.

## Non-negotiable contract

> ACID may create or change a phrase only when a current, explicit user action authorizes that exact operation against a uniquely validated live destination.

1. Renoise's current song and object graph are authoritative for existence, structure, and native selection. ACID may maintain an **explicit local target** (including `New Phrase`) but may never mistake that target for a Renoise selection or a persisted index.
2. Browsing an instrument or phrase, selecting `New Phrase`, opening/reopening the dialog, receiving an observable notification, and arming Live Edit are **never musical write triggers**. A verified Renoise copy operation may permit only the guarded, metadata-only ownership fork specified below; a notifier alone is never authorization.
3. Create and regenerate are separate writer operations; regeneration cannot append, redirect, or silently convert into creation.
4. Writer destinations carry Renoise object references. Indices are resolved from the live object graph immediately before mutation and discarded afterward.
5. An operation invalidated by a changed song, dialog session, destination, draft revision, or newer operation cannot mutate the song or alter a newer GUI session.
6. Ambiguous or detached ownership blocks writing, not draft recovery. Existing foreign phrase content is never overwritten.
7. Manual Generate and Live Edit use one validation/commit pipeline. They differ only in their explicit trigger.
8. Use documented Renoise API methods and observables. Do not write to selection properties as a workaround for synchronization. Do not synthesize a `selected_phrase_index_observable` that is not documented.
9. A Renoise copy/duplicate of an ACID-owned phrase is a **new object**, not the same owner. When exact copy provenance is demonstrable, fork its ownership ID **without regenerating musical content**. Otherwise retain the phrase, block ambiguous writes, and offer a deliberate identity-resolution action. Never infer provenance from matching notes alone.

## Target behavior: the binding and write matrix

| Current ACID target | Navigation / selection | Generate click | Live Edit parameter edit (Live Edit already armed) |
|---|---|---|---|
| **New Phrase** | Rebind ACID only; no write | **CREATE** in explicitly chosen live instrument | **CREATE** on the first real edit, then bind the returned phrase; subsequent edits **REGENERATE** it |
| **Owned Phrase** | Load its persisted ACID source; no write | **REGENERATE** that exact phrase | **REGENERATE** that exact phrase |
| **Foreign Phrase** | Show it as foreign; preserve prior draft; no write | Block with actionable reason | Update recoverable draft locally if appropriate, but **never write** |
| **Unavailable** (removed, detached, unresolved copied ID, corrupted, stale) | Keep draft and explain reason; no write | Block | Block |

**Terms:** `Owned` means a uniquely verifiable ACID source record, including an independently re-keyed copy. `Foreign` means no verifiable ACID ownership, not simply "in another instrument." `Copied / ID conflict` is **Unavailable pending resolution**, not Foreign. **Make Independent** is a separate, explicit metadata-only action for a selected, verifiable copy; it is neither Generate nor Live Edit. Add the smallest functional UI affordance required to invoke it (for example, a context action or small button) without changing the M5 GUI layout.

If Live Edit is OFF, parameter edits change only the current draft. A no-op edit never generates. Once a New Phrase create succeeds, the returned phrase object—not the earlier insertion index—is the sole subsequent target. If the user changes instrument or destination before a pending create commits, the operation must be canceled and cannot create in either instrument.

## Step 0 — Freeze and inventory the current worktree

**Purpose:** Work from the actual implementation, including any uncommitted M4.7 work, rather than layering a second controller over it.

**Do in this order:**

1. Stay on `feature/hardening4`. Inspect `git status --short --branch`, `git diff --stat`, `git diff`, and the latest commit. **Do not reset, stash, discard, or overwrite uncommitted work.**
2. Inventory the active ACID entry point, GUI, source serialization, `renoise/destination_context.lua` (if present), writer, generation orchestration, Live Edit debounce/timer code, and `tests/acid/*`.
3. Search all call sites of phrase insertion/deletion, rendering, selected instrument/phrase reads or writes, ownership ID parsing, phrase index retention, phrase and instrument copy/duplication handling, dialog close/reopen, timers, and notifiers. Record the **single intended owner** for each action.
4. Read the project's declared Renoise API version. Cross-check its exact API against the installed Renoise documentation; do not assume a newer API member exists. Verify where ACID's owner ID and 303 source record are actually persisted and whether Renoise's **phrase Duplicate**, phrase copy/paste between instruments, and **instrument Duplicate / copy** preserve that record. Do not infer this from `copy_from` documentation alone; observe actual Renoise behavior on a disposable song. If only song-indexed metadata is stored and copied phrases carry no durable source record, mark automatic adoption across copied instruments as unsupported until a safe persistence or explicit import path exists. Do **not** pretend identical notes prove an ACID source.
5. Run the existing **local** ACID regressions once and record the baseline. Existing passing tests are not acceptance evidence for untested runtime transitions.
6. Create one compact M4.7 task section in the roadmap, using the step numbers below; do not add an experiment log or historical narrative.

**Gate 0:** The worktree is safe, actual entry points/call sites are mapped, metadata copy behavior is known (or explicitly unresolved pending Renoise verification), and the baseline is recorded. If M4.7 code is already present, mark each later step as **verify / correct / complete** rather than automatically rewriting it.

## Step 1 — Centralize runtime state and specify transitions

**Purpose:** There must be one explanation for where ACID is pointed and why a write is allowed.

**Implement or consolidate** the existing runtime/destination context. It should own a minimal state like:

```lua
runtime = {
  song_ref = nil,
  song_epoch = 0,                 -- invalidated at document release/load
  dialog_session = 0,            -- invalidated at dialog close/reopen
  destination_revision = 0,     -- changes when the explicit target changes
  edit_revision = 0,            -- changes when an actual draft edit occurs
  operation_revision = 0,       -- newer write request supersedes older one
  inventory_revision = 0,       -- live object graph changes, including copies
  instrument_ref = nil,
  destination = {
    kind = "unavailable",      -- new | owned | foreign | unavailable
    phrase_ref = nil,
    ownership_id = nil,
    baseline_fingerprint = nil,
    reason = "no_song"
  }
}
```

These are logical fields, not a requirement for a new class or five new modules. Use the existing controller if it already does this. Object refs are session-scoped and are never treated as persisted identifiers across song reloads.

**Provide explicit events/entry points:** `on_song_changed`, `on_native_instrument_changed`, `on_native_phrase_changed`, `on_inventory_changed` (copy/add/remove detection only), `on_acid_instrument_selected`, `on_acid_phrase_selected`, `on_draft_edited`, `on_live_edit_toggled`, `on_generate_requested`, `on_dialog_closed`, and `on_operation_finished`. Only `on_generate_requested` and an actual draft edit with Live Edit armed may enqueue a **musical** write; `on_inventory_changed` can request **only** the proven metadata-only ownership fork.

**Define precedence:** ACID's dropdown may choose a local target independently of the Renoise phrase editor. A genuine subsequent native Renoise instrument/phrase selection changes the active target; an unrelated refresh, rename, or list notification must **not** silently replace the explicitly selected `New Phrase`. Distinguish actual native selection changes from a routine inventory refresh by comparing the current selected object with the last observed selected object.

**Copy event distinction:** A confirmed Renoise copy/add operation can authorize a **metadata-only identity fork** through the dedicated writer method in Step 2, but ordinary navigation, selection, and inventory refresh cannot. Preserve a previous live-object snapshot for candidate provenance; never treat a numeric slot or an ownership ID alone as a copy source.

**Gate 1:** Unit tests show that every navigation-only event changes state/views but makes **zero** compiler/writer calls, even with Live Edit enabled. Revisions increment only on relevant changes. Unavailable and foreign states cannot authorize writes.

## Step 2 — Make the phrase writer fail closed independently of the GUI

**Purpose:** Fix the lowest-level data-loss hazard before adding observer-driven updates.

**Replace ambiguous implicit destination handling** with two explicit contracts. Keep existing file/module boundaries where possible:

```lua
writer.create({
  song_ref = song,
  instrument_ref = instrument,
  compiled = prepared_payload,
  source_record = serialized_source,
  guard = operation_guard
})
-- -> { phrase_ref = committed_phrase, ownership_id = id, fingerprint = fp }

writer.regenerate({
  song_ref = song,
  instrument_ref = instrument,
  phrase_ref = exact_owned_phrase,
  ownership_id = id,
  expected_fingerprint = fp,
  compiled = prepared_payload,
  source_record = serialized_source,
  guard = operation_guard
})
-- -> { phrase_ref = same_phrase, ownership_id = same_id, fingerprint = new_fp }
```

Add one **separate metadata-only contract** for safe duplicate ownership resolution (this is not another render pipeline):

```lua
writer.fork_copy_identity({
  song_ref = song,
  original_instrument_ref = source_instrument,
  original_phrase_ref = source_phrase,
  copied_instrument_ref = target_instrument,
  copied_phrase_ref = copied_phrase,
  expected_original_id = old_id,
  expected_copy_record = cloned_source_record,
  new_ownership_id = fresh_unique_id,
  guard = identity_guard
})
-- -> { phrase_ref = copied_phrase, ownership_id = fresh_unique_id,
--      fingerprint = copied_record_fingerprint }
```

For **Make Independent** after reopen, use the same metadata-only primitive with a distinct explicit-selection authorization and validated saved source record; `original_phrase_ref` may be absent only in this deliberate-resolution mode. Never use a guessed original object or claim to know which was copied. The selected phrase alone receives the new ID. This method must never insert/delete a phrase, compile a sequence, rewrite note/effect content, assign native selection, or change another phrase's metadata.

**Identity-fork transaction:** Verify current song, exact selected/copied phrase membership, valid ACID source payload, old-ID collision, expected record/content fingerprints, new-ID global uniqueness, and current guard. For automatic mode also verify a pre-event original **object** and exact provable copy lineage; reject missing, multiple, or changed candidates. Rewrite only the copied phrase's ownership metadata in the existing storage format; preserve its visible name and all musical data. Read back and validate the new unique ID, source record, and unchanged musical fingerprint. On failure restore only the selected copied object's previous metadata; if restoration is unsafe, raise an integrity blocker. Invalidate pending Generate/Live Edit tokens and refresh the identity inventory. The original retains its old ID.

The signatures are illustrative: adapt to existing Lua conventions, but **do not reintroduce default target indices or implicit mode inference**. Both APIs must reject missing or inconsistent required arguments. The writer cannot trust a GUI-provided index or a guard alone; it revalidates live objects itself.

**Writer sequence, without variation:**

1. Validate parameters, prepared output and serializable source **without** changing Renoise data.
2. Run the operation guard; assert `renoise.song() == song_ref` and that the instrument object exists exactly once in `song.instruments`.
3. For regenerate, find `phrase_ref` **inside that exact instrument** by live object membership. Require unique ownership ID, valid saved source, and exact expected content/record fingerprint. Reject foreign, externally changed, removed, or ambiguous phrases.
4. For create, assert the destination is explicitly `New Phrase`, available capacity, and an allocated unique ownership ID. Only a **create** request may call `insert_phrase_at`.
5. Check the guard once more immediately before the first mutation. Never use a stale precomputed phrase index for the actual operation.
6. Apply the prepared phrase contents and persisted ownership/source record as one protected logical operation. **Preserve existing semantic compiler output.**
7. If a write fails, restore the prior exact phrase content/metadata for regenerate; for create, remove **only the inserted object**, located again by identity, if it is still safe to do so. If rollback cannot be verified, report a blocking integrity error; never delete a guessed index or perform follow-up writes.
8. Verify the committed phrase object still belongs to the intended instrument, metadata agrees with contents, and identity is unique. Return the committed object, ownership ID, and current fingerprint. Do not assign Renoise native selection properties as part of the commit.

Avoid yield/timer work inside the mutation section. For Renoise Lua synchronous execution, validation directly before the mutation is the commit boundary; callbacks or timers must not bypass this writer method. If the existing writer has safe transactional helpers, reuse them.

**Gate 2:** Direct writer tests (without the GUI) prove: no default instrument/phrase; failed regenerate never inserts; foreign never overwrites; stale phrase index never retargets; duplicate IDs reject; injected write failure rolls back the *same* object; successful create returns the actual committed phrase and reuses it on regenerate; identity forking changes **only** the selected copy’s owner metadata, never phrase notes, and fails safely on ambiguous lineage, invalid records, stale token, or rollback error.

## Step 3 — Resolve destination identity from live Renoise objects

**Purpose:** Eliminate index-as-identity errors in dropdown binding and in saved state.

1. Resolve current song/instrument/phrase objects from the live Renoise graph on each synchronization and before every write. Numeric indices may be used only to display position or call a documented API after finding the object.
2. Represent `New Phrase` as a synthetic ACID UI option, **not** phrase index `#phrases + 1` and not a Renoise phrase object.
3. For an existing phrase, classify as `Owned` only if its saved ACID record is valid and its ownership ID is unambiguous; otherwise `Foreign` or `Unavailable(reason)`.
4. Treat removed, replaced, **unresolved duplicated**, or externally modified ownership as a write-blocking destination. Retain the draft; do not silently choose a different phrase that happens to occupy the same index.
5. Keep instrument selection and phrase selection coupled: changing instrument rebuilds the phrase choices from **that instrument**, and any local phrase reference not present in it is detached.
6. On successful create, bind to `writer.create`'s returned `phrase_ref`; ignore the pre-insertion index. On successful regenerate, require returned object identity to equal the requested phrase object.
7. Scan the **entire live song** for ownership-ID collisions before any write. Require uniqueness of global IDs across instruments. Never use `first match`, name, slot index, or matching musical content to choose an original.
8. On an **observed addition**, compare previous and current live-object inventories. Automatic copy forking is permitted **only if all** are true: (a) the added phrase is a distinct new object, (b) its valid carried ACID ID/source record and musical fingerprint match a **single, previously observed** owned source phrase, (c) all holders of that old ID are accounted for as the original plus this new copy, (d) the source object still exists unchanged, and (e) the origin/target match remains true at identity-writer commit. For a copied whole instrument, perform this check **per phrase**; do not assume all its phrases are owned or that names identify the source. Generate one fresh song-unique ID **per valid new copy**, preserve its serialized 303 source verbatim, and revalidate between commits. Partial/ambiguous matches stay blocked; never re-key the original.
9. **Reopen/unknown provenance:** if two existing objects already share an ID, ACID cannot know which was copied. Mark the collision unavailable and preserve both drafts; provide `Make Independent` on an explicitly selected phrase with validated ACID source metadata. After that metadata-only re-key, each uniqueness group is re-evaluated. For 3+ holders, further selected copies may need deliberate resolution until unique. Do not invent a persistent Renoise object GUID.
10. **Metadata-lost copies:** if native copying drops the ACID source record, classify the result as Foreign, not as an owned copy based on identical notes. It can only become owned via a separate explicit source-backed import/adoption operation with valid source, if already supported; otherwise it remains Foreign in M4.7. Do not silently replace its contents or create a new phrase.

**Gate 3:** Insertion/deletion/reordering, same-index replacement, instrument switch, and duplicate-ID fixtures never cause ACID to bind or write a different phrase. Proven live copies fork to independent song-unique IDs with unchanged notes/source; ambiguous existing collisions remain blocked and are resolvable only by deliberate selected-copy identity forking. `New Phrase` remains selected through unrelated refreshes.

## Step 4 — Connect the exact Renoise observable lifecycle

**Purpose:** Make ACID track real changes immediately without leaking listeners or generating as a side effect.

Attach/detach as appropriate to the installed SDK:

- Tool-level: `app_release_document_observable`, `app_new_document_observable`, and `tool_will_unload_observable`.
- Song-level: `song.instruments_observable`, `song.selected_instrument_observable` or `selected_instrument_index_observable`, and `song.selected_phrase_observable`.
- Per-instrument: `instrument.name_observable` and `instrument.phrases_observable`.
- Per-phrase: `phrase.name_observable` and **only** specific content observables already supported/needed by the existing ownership fingerprint implementation.

**Important SDK rule:** Observable lists report add/remove/swap of members; they do **not** report changes to member properties. Rename handling requires item observables. Do not invent a nonexistent `selected_phrase_index_observable` or rely on assignment to native selection to synchronize UI.

**Copy-aware reconciliation:** Snapshot object membership and validated ownership **before** applying structural changes; compare old/new live objects when a list observable fires. Never treat a notifier by itself as proof of a copy. If Step 3's exact provenance checks succeed, dispatch the guarded **identity-only** operation from Step 2; otherwise expose an unresolved collision. Suppress reentrant refresh from ACID's own metadata writes. **No observer may directly render, create/regenerate, or rewrite phrase notes.** Any automatic identity fork is strictly metadata-only and must complete validation before mutation.

**Implement callbacks as invalidation/reconciliation only:** detach obsolete nested listeners; attach to newly live objects; read the real selected objects; classify destination; rebuild dropdown labels/options; preserve draft; invalidate pending work when its target changed; render GUI only. Do not compile, create, regenerate, or trigger Live Edit from any reconciliation callback. Identity-only copy reconciliation is the sole guarded exception described above. Use one guarded UI refresh path to prevent notifier-triggered reentrancy.

**Lifetime order:** on document release, invalidate generation tokens **before** detaching old-song notifiers. On new document, increment song epoch, attach once, reconstruct inventory, and establish a fresh target. On dialog close, invalidate session tokens and cancel scheduled work. On tool unload, detach all notifiers and timers. Use stable notifier function identities so removal works.

**Gate 4:** Add/rename/delete/reorder instruments and phrases, duplicate/copy a phrase or whole instrument, change native selections, switch songs, and close/reopen dialog. The ACID UI updates as expected with **zero spontaneous musical writes** (only independently validated copy-ID metadata forking is permitted), no callbacks referencing old songs, and no duplicate notifiers after repeated openings.

## Step 5 — Unify Generate and Live Edit behind one operation lifecycle

**Purpose:** Every write trigger must pass the same preparation and validation logic.

1. Route both Generate and Live Edit through a single `request_generation(trigger)` entry point. Never call the writer from GUI widgets, selection callbacks, or timers directly.
2. On real draft edit, increment `edit_revision`; if Live Edit is armed, debounce the request. Opening the dialog, loading a draft, updating dropdowns or view model, and programmatic widget refresh must not count as user edits.
3. At request creation, capture an immutable token: `{song_ref, song_epoch, dialog_session, instrument_ref, destination_kind, phrase_ref, destination_revision, edit_revision, operation_revision}` plus a snapshot of the edited draft and expected ownership fingerprint.
4. Newer edits, destination changes, instrument changes, song changes, **ownership collisions or identity forks**, session close, and a superseding Generate request invalidate the previous token. Cancel pending timers where possible. Cancellation does **not** fall back to create.
5. Compile/prepare from the captured draft without writing to Renoise. Check token currency before calling the writer. Pass the token guard into the writer for the final pre-commit check.
6. Call only `create` for an explicitly New target, only `regenerate` for an owned target, and neither for foreign/unavailable. If a fresh validation now disagrees with the request, block and preserve the draft.
7. Handle completion in two tiers: writer commit success is the song fact; GUI binding/status is applied **only** if the session and target are still current. A stale callback cannot select a destination, change the active draft, clear an error, or overwrite a newer result.
8. After a successful New Phrase create, switch that session's target to the **returned phrase object** and its ownership/fingerprint. Later Live Edit changes regenerate it, never append another phrase.

**Gate 5:** Delayed callback tests, rapid edit bursts, duplicate/copy during queued work, close/reopen, switching instrument during queued work, switching songs, and cancellation produce at most the latest authorized write. Stale work cannot commit and stale callbacks cannot update a newer session.

## Step 6 — Isolate drafts and define recovery behavior

**Purpose:** Keep editing state independent of fragile selected indices.

1. Key in-session drafts by the containing song session, instrument **object**, and phrase **object** for owned targets; use a separate per-instrument `New Phrase` scratch draft. Do not key by phrase index or globally shared ownership ID alone.
2. Persist and restore owned phrase source using the project's existing ACID source-record format; do not invent another persistence layer or migrate the sequencer in M4.7.
3. When selecting an existing owned phrase, load its **validated saved source**. During normal navigation, save the outgoing in-memory draft without emitting a write. Prevent programmatic control updates from firing Live Edit.
4. If ownership is **unresolved and duplicated**, content was externally changed, or the phrase is removed, mark the old draft as **detached** and make it recoverable in the current session. Do not bind the detached draft to any other phrase or silently overwrite external changes.
5. Reopening ACID must reconstruct valid owned source from the saved record. If durable recovery of an unsaved draft across dialog close is required, reuse an already available session-local draft store; do not promise recovery across Renoise restart unless it is actually persisted.
6. For a safely forked copy, initialize its draft from the validated **copied source record** and key it to the copied **object + new ID**; it must diverge independently from the original. Reopening the song reconstructs both separately from their durable records. A copied instrument can contain a mixture of owned and foreign phrases; fork only the verifiable owned ones.
7. Define deterministic recovery: user can select an existing uniquely owned phrase, explicitly choose `New Phrase` and then Generate, or keep an unavailable draft until a valid destination is explicitly chosen. Provide `Make Independent` **only** for a selected copied/colliding phrase with valid source record; this changes metadata only and requires explicit authorization after ambiguous reopen. Do not silently repair ambiguous collisions or adopt source-less Foreign phrases.

**Gate 6:** Switch between multiple instruments, each with owned/new/foreign phrases; independently edit original and proven copied owned phrases; close/reopen ACID; rename/reorder; inject ambiguous duplicate IDs and external modification. Every selected owned phrase loads its own source, and blocked drafts remain available without cross-contamination.

## Step 7 — Remove conflicting paths and tighten the test suite

**Purpose:** There must be exactly one write pipeline and no tests asserting obsolete behavior.

1. Delete or redirect all alternative entry points that insert during regenerate, generate on selection/reconciliation, or use cached indexes as phrase IDs.
2. Remove stale native selection writes, duplicate observer registrations, abandoned delayed-callback handlers, and parallel destination caches.
3. Update obsolete tests that expect implicit append or selection-triggered rendering. Preserve working compiler/sequencer tests.
4. Add focused unit/fixture tests for runtime, destination, writer, generation lifecycle, and drafts. No broad matrix expansion.
5. Run the existing local command, e.g. `pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID`, then the repository's established full local test command. Use VS Code/Lua and PowerShell locally; **do not add GitHub workflows**.
6. Inspect the diff for changes outside ACID runtime/test/documentation scope. Revert unrelated musical or GUI redesign changes, preserving user work.

**Minimal targeted regression cases:**

| ID | Scenario | Required outcome |
|---|---|---|
| R01 | Select instrument; browse phrases; arm Live Edit | No writer call |
| R02 | Choose New; press Generate | Exactly one created phrase, bound by object |
| R03 | Edit immediately after R02 with Live Edit | Same phrase regenerated, phrase count unchanged |
| R04 | Select owned phrase and edit | Only that phrase changes |
| R05 | Select foreign phrase, edit, Generate | Never overwritten and no append |
| R06 | Insert/remove/reorder phrase before target | Object target unchanged or blocked if removed |
| R07 | Replace phrase at same index | Never binds replacement |
| R08 | Add, rename, delete, reorder instruments | Dropdown reflects song; no write |
| R09 | Switch instruments rapidly with pending Live Edit | No write into previous/new wrong instrument |
| R10 | Close dialog/reopen before callback | Old callback cannot mutate or rebind new session |
| R11 | Switch song with work pending | Old operation cannot write to either song |
| R12 | Duplicate ownership IDs with unknown origin (including after reopen) | Ambiguous; no Generate/Live Edit; draft recoverable |
| R13 | Externally modify owned phrase | Fingerprint mismatch blocks overwrite |
| R14 | Writer compile/preflight failure | No song mutation |
| R15 | Inject mutation error during create/regenerate | Exact-object rollback or explicit integrity failure |
| R16 | Multiple owned phrases; close/reopen | Correct persisted source restored, no draft mixing |
| R17 | Repeated dialog opens/song changes | No notifier/timer leaks |
| R18 | Change tempo, LPB, LPR or time signature in existing supported flows | Existing musical output and safety behavior unchanged |
| R19 | Duplicate owned phrase in same instrument while ACID observes | If unique provenance and carried record verified: new ID and independent editable source; original unchanged |
| R20 | Copy owned phrase to a different instrument while ACID observes | If provenance verified: new ID, same musical notes/source, independent regeneration in destination instrument |
| R21 | Duplicate instrument with multiple owned and foreign phrases | Per-phrase safe forks only; foreign untouched; all new IDs unique; no cross-instrument draft mixing |
| R22 | Edit original then copy, edit copy then original, save/reopen | Separate owner IDs, exact source restoration, no coupling, no phrase count growth |
| R23 | Reopen song containing preexisting duplicate ID; select Make Independent | No guessed original; selected valid-source phrase re-keyed metadata-only; unresolved holders stay blocked |
| R24 | Copy with dropped/invalid source, simultaneous ambiguous insertion, or copy during pending Live Edit | No automatic provenance guess, no musical mutation, stale operation canceled, explicit safe state |

**Gate 7:** All 24 targeted cases and preexisting local tests pass. There is one discoverable musical create/regenerate pipeline; the distinct identity-only writer path is reachable only by validated copy reconciliation or explicit Make Independent.

## Step 8 — Real Renoise acceptance (mandatory; last gate)

Run this **once as a concise interactive session**, not as a new audio-capture or measurement project. Use a copy of an XRNS song with multiple existing instruments and phrases, including foreign content. Record only case, pass/fail, and a reproducible defect if any.

**A — Live song inventory:** With ACID open, add instruments (including sampler/VST), rename, delete, and reorder them. Change Renoise's active instrument rapidly. ACID reflects the live instrument and phrase inventory and keeps the intended draft; nothing is rendered by navigation.

**B — Explicit destination workflow:** Choose New Phrase and Generate once; then repeatedly change sequencer controls with Live Edit on. The phrase count does not grow. Navigate to a different owned phrase: its own source loads and only it regenerates. Browse foreign phrases without modifying them. Switch between multiple instruments and repeat.

**C — Interrupted, copied, and structural work:** Queue Live Edit, immediately switch instrument/phrase, delete or reorder the intended phrase, close/reopen ACID, and change songs. No stale generation, wrong destination, unexpected append, draft loss, or callback rebinding. While ACID is observing, **duplicate an owned phrase in the same instrument**, **copy one into another instrument**, and **duplicate an entire instrument with owned and foreign phrases**. For each proven copy, verify a fresh ID, unchanged phrase content/source, independent ACID editing, and no writes to the original. Save/reopen and verify both original and copies remain independently owned. Separately open a song with **preexisting duplicate IDs**: do not guess the original; block regeneration and resolve the explicitly selected copy with `Make Independent`, without re-rendering. If Renoise dropped source metadata in a copy, confirm Foreign classification rather than guessing ownership.

**D — Musical non-regression:** Smoke-check existing 303 pitch/gate/accent/slide behavior using the established supported sampler/VST paths and a small set of existing timing cases. Do **not** add WAV loopback capture, new audio metrics, or a full time-signature/tempo matrix.

**Gate 8:** A/B/C pass in Renoise (including same-instrument copy, cross-instrument copy, full-instrument duplication, save/reopen, and deliberate ambiguous-ID recovery) and D has no regression. If any fail, M4 remains open; fix only the relevant runtime step and rerun affected local tests plus the failed acceptance case.

## Step 9 — Finalize documentation and the branch

1. Update roadmap M4.7 with implemented responsibilities, invariants, and acceptance result. Remove superseded statements. Keep it terse, forward-looking, and free of historical narratives.
2. Preserve only relevant diagnostic tools and reproducible tests. No additional capture scripts or fixtures without continuing regression value.
3. Review `git diff --check`, changed file list, local regression output, and Renoise acceptance outcomes.
4. Commit the verified changes on `feature/hardening4`; do not merge into `develop` or declare M4 closed before acceptance is confirmed.
5. Final report contains: commit ID, touched runtime/test/documentation areas, local regression result, Renoise A/B/C/D result, and any remaining blocker. Nothing more is required.

## Stop conditions (apply at **every** step)

Stop the current change rather than proceeding when: a write can choose an implicit destination; a phrase is recognized only by index; an ownership ID resolves to more than one phrase **without a validated identity-fork/resolution path**; a copy is adopted from matching notes alone; a fork edits note content or changes the original owner; a writer path bypasses current-token checks; a Renoise observer can trigger generation; draft recovery requires overwriting other content; rollback could delete an unidentified phrase; a new API member is assumed rather than verified; or a change crosses into M5 UI redesign or sequencer semantics. Correct that condition and rerun the preceding gate before advancing.

## API references

- [Renoise Song API](https://renoise.github.io/xrnx/API/renoise/renoise.Song.html) — song/instrument collections, selected instrument/phrase objects, native selection observables.
- [Renoise Instrument API](https://renoise.github.io/xrnx/API/renoise/renoise.Instrument.html) — `phrases_observable`, `name_observable`, `insert_phrase_at`, `delete_phrase_at`.
- [Renoise InstrumentPhrase API](https://renoise.github.io/xrnx/API/renoise/renoise.InstrumentPhrase.html) — phrase properties and observable source.
- [Renoise ScriptingTool API](https://renoise.github.io/xrnx/API/renoise/renoise.ScriptingTool.html) — document release/load and tool unload lifecycle.
- [Renoise Observables guide](https://renoise.github.io/xrnx/guide/observables.html) — notifier semantics and reattachment.

**Do not substitute this playbook for a review of the live working tree.** It is designed to be applied against either the pre-refactor runtime or the already reported uncommitted M4.7 refactor without destroying existing work.