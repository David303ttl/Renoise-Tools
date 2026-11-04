# ACID GUI redesign acceptance

## Task 1 status

Baseline, API constraints, control ownership and production reachability are
recorded below. Task 1 exit remains open until the native sizing probe runs.
Paths under `gui.lua`, `runtime/`, `renoise/` and `writers/` refer to
`com.david303ttl.ACID.xrnx/`; test and manual paths refer to `tests/acid/`.

## Task 2 feedback contract

One GUI-local owner renders save, destination, scale, audition, input and
generation issues in that order. Confirmations appear only without unresolved
issues. Empty feedback reserves one pixel; message height follows the number of
lines. Sizes use named constants.

| Producer evidence | Presentation and lifetime |
| --- | --- |
| Editor transition failure or `draft_warning` | Save failure is published before Live Edit flush; output success cannot clear it. Target switching retains a previous-phrase warning; only matching verified save evidence clears it. Multiple unidentified previous failures retain a conservative warning for the dialog lifetime. |
| Restore `draft_error` / `source_available` | Load failure is distinct from failed saving. Generation cannot claim that saved edits loaded successfully. A successful load or actual target change clears the load issue. Current integrity blockers take precedence. |
| Writer `kind`, `verified`, `status`, `code`, `stale`, `destination_current` | Current verified completion synchronizes accepted state. Approximation remains visible; stale success/failure cannot replace current feedback. Generate success cannot clear Duplicate failure. |
| Rejected request plus current lifetime, integrity and target eligibility | Unavailable song/phrase outcomes have no unsupported retry advice. Runtime error strings are not parsed or displayed. |
| Projection coordinates and entry markers | Missing-position feedback follows Enter and Advance and clears on completion. Unrelated edits/navigation do not clear unresolved source errors. Successful same-result operations clear only their matching operation failure. |
| Label validator and rename result | Format guidance, Retry and Discard Attempt preserve proposals, accepted history and destination identity. |
| Scale read, parse, merge and preference-save branches | Read/format/name/size/save guidance follows the failing branch. Uncertain storage disables Import and directs reopening to reload preferences. |
| Audition onset/release/cleanup outcome | A failed release remains visible across later auditions and target changes for the dialog lifetime; another note cannot establish that the original note was released. |

Required failure fixtures and source/history/write/save assertions are in
`acid_gui_admission_spec.lua`, `acid_gui_views_spec.lua` and
`acid_program_staging_spec.lua`. Separate diagnostic/recovery controls remain
within Task 3's deletion scope.

## Task 2 verification

Implementation and automated/native functional checks pass on the working tree
based on `e6e9af4a26f855016a0b3588b34b1176a897cf93`.

| Check | Result |
| --- | --- |
| `./scripts/setup_sdk.ps1` | Pinned API 6.2 SDK verified; view sizing definitions and offline docs inspected |
| `./scripts/run_tests.ps1 -Tool ACID` | 79 specs passed, 0 failed; Lua 5.1; 66.20 s |
| `git diff --check` | Passed |
| Native `editor-responsiveness` | PASS; Renoise 3.5.4 / API 6.2; 35 GUI actions, shared feedback ownership/order, 1-pixel empty holder and 48-pixel two-issue view; source metadata, phrase inventory, native selection and original tool installation restored |
| Native report | `tmp/interactive-1bf129d27860488d8fa4e996f0769033/report.json` |
| Native command | `./scripts/run_interactive_tests.ps1 -Tool ACID -Suite Native -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -RenoiseExe <renoise-executable>` |
| Native-tested `gui.lua` SHA-256 | `46bce18db9101f335f19e6f0dd16c87b7d8d9c2f09ead5ebd0e7a6a64f9cb548`; matches current source |
| `./scripts/package.ps1 -Tool ACID` | 35 runtime files; archive inventory and every file's bytes match source; entry points at root; no SDK, Markdown, tests or development driver |
| Archive | `dist/com.david303ttl.ACID_0.1.xrnx`; SHA-256 `c00ef8be060120f894c30350e0b9383344cfd9010ce366bd1b4840ce563b2775` |

Native feedback failures use injected Duplicate rejection and an empty clipboard.
Save/load, stale completion, uncertain scale storage and failed audition cleanup
remain injected Lua fixtures. Audible output, timer duration, native metadata
Undo and visual screen-fit/scaling checks are unverified; this is functional
acceptance, not full visual/audio acceptance.

## Baseline

| Item | Evidence |
| --- | --- |
| Revision | `e6e9af4a26f855016a0b3588b34b1176a897cf93` |
| Initial worktree before this record | Clean |
| SDK setup | `./scripts/setup_sdk.ps1` confirmed pinned API 6.2 SDK already installed |
| ACID tests | `./scripts/run_tests.ps1 -Tool ACID`: 79 specs passed, 0 failed, 66.32 s; Lua 5.1 |
| Second-pass test recheck | Same revision: 79 specs passed, 0 failed, 67.31 s |
| `gui.lua` | 2,276 lines |
| Static production closure from `main.lua` and `gui.lua` | 33 Lua files, 14,849 lines; all Lua files in the current ACID package |
| Current archive | `dist/com.david303ttl.ACID_0.1.xrnx`, SHA-256 `695427a16038ff2bd5a455c34381d47b61e690f412b3e38f88755181e6fe806c` |

Baseline archive contents (35 files):

```text
gui.lua
LICENSE
main.lua
manifest.xml
model/articulation.lua
model/control_signals.lua
model/cycle_interpreter.lua
model/editor_state.lua
model/legato.lua
model/output_planner.lua
model/policies.lua
model/scale_data.lua
model/scales.lua
model/sequencer.lua
model/timing.lua
renoise/pattern_store.lua
renoise/phrase_ownership.lua
renoise/sampler_audit.lua
renoise/selection_context.lua
renoise/target_capabilities.lua
runtime/audition.lua
runtime/context.lua
runtime/draft_cache.lua
runtime/eligibility.lua
runtime/independence.lua
runtime/integrity.lua
runtime/inventory.lua
runtime/observers.lua
runtime/requests.lua
runtime/scale_preferences.lua
runtime/transitions.lua
writers/phrase_materializer.lua
writers/phrase_pitch_bend.lua
writers/phrase_validator.lua
writers/phrase_writer.lua
```

No runtime source or package input changed in Task 1; the archive was not rebuilt.

## API 6.2 constraints

Inspected definitions and offline docs: `view.lua`, `rack.lua`,
`Application:show_custom_dialog`, and `Dialog` under
`sdk/renoise-api-6.2/definitions/` and `sdk/renoise-api-6.2/docs/API/renoise/`.

- `View.visible = false` hides a view without removing it. `visible` can also be
  false because a parent is hidden. The docs do not state whether hidden views
  collapse from layout.
- `View:add_view()` and `remove_view()` manage membership; `views` is read-only
  and ordered. `add_child()` and `remove_child()` are deprecated aliases.
- `Rack.uniform` resizes child dimensions when a child size changes or a child
  is added; rack membership also supports `add_view()` and `remove_view()`. The
  docs do not state whether removal shrinks an already open native dialog.
- Dialog exposes visibility, focus, `show()` and `close()`; no content-size
  property or open-dialog resize guarantee is documented.

## Control ownership and relocation map

| Current controls or constructors | Callback, state and update owner | Tests and disposition |
| --- | --- | --- |
| Target, phrase, length, timing, Program/Grid and output controls; `acid_last_step`, `acid_timing`, `acid_output_policy`, `acid_pb_range`, `acid_editor_view` (`gui.lua:309-359`, `1114-1339`) | Target selection binds through `runtime.context`; edit callbacks save through `changed()`; `update()` renders current values (`gui.lua:550-739`) | Retain. `acid_gui_views_spec.lua`, `acid_gui_admission_spec.lua`, `acid_runtime_inventory_spec.lua`; destination and regeneration manuals |
| Program/Grid pitch keys, octaves, C+, accent, slide, PITCH/TIME positions, and pages; ID families `acid_program_*`, `acid_grid_*`, `acid_pitch_page_*`, `acid_time_page_*` (`gui.lua:944-1050`, `1695-1775`) | Selection/edit callbacks at `gui.lua:740-1059`; `update()` and `refresh_stage()` render selection, active bounds, pages and staged entry (`gui.lua:516-699`) | Retain. `acid_gui_views_spec.lua`, `acid_editor_spec.lua`, `acid_program_staging_spec.lua`; editor presentation manual |
| Entry actions `acid_program_back`, `acid_program_enter`, `acid_program_restart`, `acid_program_finish`, `acid_program_discard`, `acid_program_edit_one`, `acid_program_reenter_pitch`, `acid_program_reenter_time` | `stage_navigation`, `finish_stage`, `begin_stage`, `refresh_stage` (`gui.lua:516-534`, `1706-1741`) | Retain. `acid_program_discard` remains the cancel ID; visible label changes later. `acid_program_check` is removed with diagnostics. |
| Audition `acid_audition`, Live Edit `acid_live_edit`, and Generate / Regenerate (anonymous button) (`gui.lua:1422-1438`, `1742-1758`, `2170-2188`) | Shared audition release and lifecycle hooks (`gui.lua:94-170`, `2198-2268`); generation admission through runtime; result feedback in `acid_status` | Retain audition, Live Edit and Generate. Remove permanent anonymous `Retry Live Edit` in Task 9. `acid_audition_status` is a separate cleanup report slated to merge into shared feedback. Tests: audition lifecycle, GUI admission/views, runtime request/writer integration; Live Edit manual |
| Rename, Duplicate, Reset, Undo/Redo; `acid_label_*`, `acid_pattern_duplicate`, `acid_pattern_reset` (`gui.lua:1444-1542`, `1815-1827`, `2148-2155`) | Rename attempt/save lifecycle, duplicate admission and editor history | Retain. Rename dialog Save/Retry/Discard Attempt resolves label edits and stays; it is not recovery UI. `acid_duplicate_label_spec.lua`, `acid_editor_spec.lua` |
| Copy/Paste, operations, random parameters, scale browser/import and mask; `acid_clipboard_*`, `acid_operation_*`, `acid_random_*`, `acid_scale_*`, `acid_mask_*` (`gui.lua:1788-2092`) | Scoped source edits and operation/scale update callbacks; `update()` refreshes active state (`gui.lua:550-739`) | Retain. Clipboard, GUI views, sequencer and scale specs |
| Shared feedback `acid_status` (`gui.lua:279-281`) | User-visible action/result feedback | Retain as the common message owner. Replace report surfaces before removing them. |
| Diagnostics and Details: `acid_source_state`, `acid_source_diagnostic`, `acid_source_summary`, `acid_preview_summary`, `acid_details_panel`, `acid_details_toggle`; anonymous “Go to source error” and “Check” (`gui.lua:299-306`, `535-549`, `762-779`, `1731-1739`, `2133-2138`) | `show_diagnostic`, `navigate_diagnostic`, `show_diagnostic()` call in `update()` | Delete presentation and navigation. Keep `project()` and projection validation used by editing, audition, generation and staging. Move meaningful failures to shared feedback. Tests: GUI views, editor, staging; presentation manual currently expects these controls. |
| Read-only inspectors: anonymous “Inspect selected Renoise pattern” and “Sampler audit” (`gui.lua:1067-1071`, `2189-2191`) | Direct calls to `renoise.selection_context.inspect_selection()` and `renoise.sampler_audit.describe()` | Delete controls and modules if no other production consumer is found. Current production callers are these two GUI callbacks only. GUI views and inspector-related mock assertions require review. |
| Decoded view and preview-cycle chooser: `acid_decoded_previous`, `acid_decoded_next`, `acid_decoded_page_label`, `acid_decoded_rows`, `acid_decoded_panel`; anonymous `preview_popup` (`gui.lua:345-350`, `705-715`, `1776-1787`) | `ui.decoded`, `decoded_page`, and decoded rendering in `update()` | Delete the view-only state and controls; retain source semantics and generation behavior. GUI views spec has paging/text probes. |
| Recovery workspace: `acid_recovery_detail`, `acid_recovery_previous`, `acid_recovery_next`, `acid_recovery_page_label`, `acid_recovery_choice`, `acid_recovery_copy`, `acid_recovery_discard`, `acid_recovery_panel`, `acid_make_independent`, `acid_revalidate` (`gui.lua:1543-1675`, `2109-2113`) | Recovery entry paging/rendering, `update_actions()`, `update_live_state()`, and callbacks to runtime context | Delete recovery actions and their exclusive presentation path. Preserve automatic draft save/restore, internal integrity evidence, write rejection and release cleanup. Specs: GUI recovery/independence, draft recovery, runtime inventory/integrity and writer integration. |
| Workspace navigation: `ui.workspace`, `workspace_tab`; anonymous “Decoded”, “Pattern / Copy”, “Extended / Clear”, “Output”, “Recovery” buttons; fixed `vb:stack` (`gui.lua:331-333`, `701-703`, `2114-2132`) | Workspace panel/tab arrays and `update()` visibility loop | Delete as later layout tasks remove panels. GUI views spec and presentation manual currently depend on these controls. |

Additional callback/update owners: `changed()` saves before the synchronous Live
Edit flush (`gui.lua:785-796`); destination feedback and selection handling are
in `gui.lua:1114-1438`; recovery rendering is in `gui.lua:1543-1675`.
The generic Retry Live Edit button is an anonymous constructor at
`gui.lua:2162-2169`; it is separate from the retained rename dialog retry.

## Runtime deletion inventory

| Candidate and current direct callers | Dependency chain and disposition | Protected behavior and coverage |
| --- | --- | --- |
| `renoise/selection_context.lua`: `gui.lua:1069`; `renoise/sampler_audit.lua`: `gui.lua:2190` | One export each; only production callers are the removable inspector buttons. Delete module, import, mocks and exclusive tests after rechecking references. Both files are in the baseline archive. | No target or writer safety dependency found. Review GUI views spec and native probes for read-only inspection assertions. |
| `context:recovery_entries()`, `copy_recovery_to_new()`, `discard_recovery()` (`runtime/context.lua:1507-1567`); GUI calls at `gui.lua:1594`, `1611`, `1647` | Wrappers call `draft_cache.list`, `copy_to_new`, `discard`. Remove the wrappers and helpers only after tracing fields used by retained draft validation. | Keep `put`, `capture`, `get`/restore, `detach`, `release`, revision guards and volatile-draft warnings. Consumers include runtime context, requests, integrity and GUI autosave/restore. Coverage: draft recovery, runtime inventory/integrity, GUI recovery and writer integration specs. |
| `context:independence_projection()` / `make_independent()` (`runtime/context.lua:1229-1504`); GUI calls at `gui.lua:1615-1618` | Action path reaches `runtime.independence`, independence eligibility/proof, cached projection, identity transition and recovery evidence. Remove action-only chain after auditing its private helpers and tests. | Preserve ownership inventory, duplicate-ID/collision detection, writer validation and shared mutation tracking. Coverage: GUI/runtime independence and phrase writer specs. `project()` remains active elsewhere. |
| `context:revalidation_status()` / `revalidate()` (`runtime/context.lua:2379-2412`); GUI calls at `gui.lua:1634-1640` | Only current production consumer is the recovery panel. Methods expose `integrity:status/clear` and `writer.clear_integrity_blocker`. Retire UI entry points and exclusive proof-clear route after blocker outcomes are documented. | Keep integrity producers, evidence, request/writer gates, same-song suspend/resume and active transaction cleanup. Coverage: runtime integrity, mutation, writer integration, context and GUI recovery specs. |
| `draft_cache.list`, `copy_to_new`, `discard` and detached recovery rows | Only GUI recovery wrappers currently consume list/copy/discard. Audit their exclusive helper and record dependencies before deletion. | Detached drafts also preserve newer revisions and native undo; automatic restore/save, volatile warnings, capture and document release have production consumers. Do not delete the cache or detached records wholesale. Coverage: draft recovery and runtime inventory/integrity specs. |

Packaged modules are listed in the baseline archive above. Final module, test,
probe, documentation and archive dispositions remain pending deletion and the
final package inspection.

## Blocker producers and current lifetimes

| Scope | Producer and current clearing condition | Permitted behavior and evidence |
| --- | --- | --- |
| Target only | `runtime.inventory` classifies foreign, colliding, missing, corrupt, incompatible or inaccessible phrases as foreign/unavailable. This is not a song/session integrity blocker. | Do not adopt or overwrite. An explicit choice of another valid destination or New is allowed only when current admission permits it. Coverage: `acid_runtime_inventory_spec.lua`, `acid_gui_views_spec.lua`, phrase destination manual. |
| Request dispatch | `runtime.context:301-306` blocks uncertain sink starts, invalid acceptance, completion-after-rejection, duplicate completion and unverifiable writer occupancy. The request-level block clears only during a full generation request after it verifies no unsettled request and an idle writer (`context.lua:708-723`), or on document release (`2190-2191`). | Keep full admission and writer checks. Ordinary nonpersistent generation failures can use explicit Generate. Coverage: runtime context/request specs and GUI admission. |
| Native observer / document | Registration, callback invalidation, detach or nested-listener rebind failure sets `observer_error` (`observers.lua:169-170, 368-411`). A successful observer attach clears it (`432-433`). | Reject affected writes; preserve notifier cleanup and exact document lifetime. Coverage: `acid_runtime_observers_spec.lua`, `acid_runtime_lifetime_spec.lua`, GUI lifecycle tests. |
| Mutation integrity, same song | A failed synchronous mutation or failed temporary-neutrality check records integrity evidence (`context.lua:1944-1945, 1961-2025`). It persists across dialog close/reopen and same-song detach/reattach (`2116-2228`); verified `revalidate()` is the current clearing path and checks current source, metadata, draft and writer state (`integrity.lua:217-325`). | Keep write rejection and evidence. Do not clear on target change. Coverage: runtime mutation/integrity and writer integration specs. This UI repair path is slated for removal and requires a supported unavailable outcome before Task 3 exit. |
| Mutation evidence could not be recorded | Failed evidence recording/finalization sets `mutation_recording_failed_reason` (`context.lua:2014-2031`); `revalidate()` refuses while set (`2394-2397`). `attach_document()` clears it only when the new song differs from `mutation_recording_failed_song` (`2200-2203`). | Current error text says “release and reattach the document,” but same-song reattach does not clear this field. Existing specs cover capture validation and integrity proofs, but no focused fixture covers this failed-recording lifetime. Record as an unresolved protected-owner outcome for Task 3; do not promise same-song reopen or retry as a remedy. |
| Writer integrity / committed-baseline adoption | Phrase-writer rollback or integrity failure reports blocker evidence through request/context (`context.lua:879-918`; `phrase_writer.lua:516-523, 726-755`). If recording fails, `phrase_writer.integrity_errors` is weak-keyed by song (`phrase_writer.lua:19`), checked on write (`811-813`), and cleared by `clear_integrity_blocker(song)` (`141-143`) only from current `context:revalidate()` (`context.lua:2394-2408`). It survives context release and same-song reattach while the song object remains live. Post-commit baseline-adoption failure records an integrity blocker or sets `adoption_blocked_reason` (`context.lua:879-918, 1371-1388`). | Preserve exact destination/source checks and reject Generate, Live Edit, Duplicate and other mutations while blocked. After removal of the only clearing path, Task 3 must define the supported unavailable/persistence outcome; Task 1 did not verify an external repair. Coverage: `acid_runtime_integrity_spec.lua`, `acid_runtime_writer_integration_spec.lua`, writer safety/identity specs. Native rollback/recovery outcomes are not established by mocks. |

Mutation evidence is captured before synchronous mutation; a capture failure
aborts before the action. Evidence-recording failure after mutation is the
separate fail-closed state above. Target restriction and session integrity must
remain distinct in feedback.

## Existing behavioral fixtures

| Required baseline case | Existing coverage |
| --- | --- |
| Unequal PITCH span and TIME length; both pages; inactive positions | `acid_gui_views_spec.lua`, `acid_sequencer_spec.lua`, `acid_program_staging_spec.lua` |
| Masked notes and scale browsing/application | `acid_gui_views_spec.lua`, `acid_scale_mask_spec.lua`, `acid_scales_spec.lua` |
| Saved drafts, restore, detach and release | `acid_draft_recovery_spec.lua`, `acid_runtime_inventory_spec.lua`, `acid_phrase_persistence_spec.lua`, `acid_live_identity_spec.lua` |
| New Phrase; owned, foreign, colliding and unavailable destinations | `acid_gui_views_spec.lua`, `acid_runtime_inventory_spec.lua`, `acid_runtime_writer_integration_spec.lua` |
| Observer, mutation, adoption and writer blocker fixtures | `acid_runtime_observers_spec.lua`, `acid_runtime_mutation_spec.lua`, `acid_runtime_integrity_spec.lua`, `acid_runtime_writer_integration_spec.lua` |

The presentation manual `acid_editor_presentation_manual.md` currently expects
Details, diagnostics, decoded output and workspace tabs. The Live Edit manual
also uses workspace navigation. These are old-interface procedures for the
later documentation task; destination, Live Edit, regeneration and lifecycle
guides remain protected behavior references.

## Native sizing probe

Native feedback sizing is covered by Task 2. Full planned holders and the tallest
planned editor, screen work area/scaling, complete dialog dimensions and
open-dialog resizing remain unverified. Task 1's complete layout-sizing exit
remains open; feedback measurements do not establish final screen fit.
