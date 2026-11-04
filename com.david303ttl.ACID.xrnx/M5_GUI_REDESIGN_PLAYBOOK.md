# M5 Followup GUI Redesign Playbook

**Status:** Tasks 1–3 are verified within the recorded native and automated
scope. Tasks 4–5 header, sequence settings and toolbar are implemented; native
checks remain open. Results and remaining limits are recorded in
[the acceptance record](../tests/acid/acid_gui_redesign_acceptance.md).
Final redesign acceptance remains open.

**Dependency:** Closed M5 editor implementation. This follow-up replaces the
presentation requirements of [M5_EDITOR_PLAYBOOK.md](M5_EDITOR_PLAYBOOK.md)
and retires the action-only runtime contracts explicitly identified below.
Its retained source, persistence, history, destination, staging, audition and
generation contracts remain authoritative. Old API/export inventories and
action-only tests do not override this document's deletion contract.
M5's recorded closeout and M4 acceptance evidence remain unchanged.

**Execution:** Complete Tasks 1–12 in numeric order. Each task depends on the
previous task's exit criteria. Do not begin a later task with an unresolved
regression. Updating this document does not implement the redesign or establish
new test results. Milestone labels belong in documentation only.

Each numbered item within a task is also sequential. Update affected tests in
the same task as the behavior they observe. After each Lua-changing task run
`./scripts/run_tests.ps1 -Tool ACID`; record the result before advancing. Task 11
completes coverage rather than repairing tests deliberately left broken earlier.
If an unexpected issue prevents an exit criterion, fix it in that task and rerun
its checks before advancing. Never bypass a safety check to unblock GUI work.

## Scope and protected behavior

Replace the workspace collection with one compact native Renoise interface:
choose a phrase, edit its sequence, apply musical operations, generate output.
Most implementation changes belong in `gui.lua` and GUI tests. Removal of
production code exclusively supporting deleted workflows also belongs in this
scope, including runtime entry points and their private dependencies. Do not
introduce a general GUI framework, broadly split modules, or redesign the source
model.

Preserve automatic draft saving, generation algorithms, output defaults and
ranges, source interpretation, independent TIME length and PITCH span, target
checks, write protections, undo/redo and request admission. Preserve observer
registration and cleanup, document lifetime checks, destination binding,
audition release and asynchronous/stale-result safeguards.

Remove recovery from the GUI completely, including actions, dialogs, banners,
notifications and contextual alternatives. Preserve automatic draft restoration,
integrity blockers and the internal records required by retained production
behavior. Internal recovery is not a blanket retention exception: delete APIs,
records, helpers and tests exclusively supporting removed user workflows after
the dependency audit below. Removing the
interface must never clear a blocker, adopt an unsafe phrase, discard a draft,
or turn an unavailable destination into New Phrase automatically.

Do not change manifests, API compatibility, persisted schema identifiers, ARP,
DigitaktSampleChain, musical algorithms or writer transaction behavior. Narrow
deletion of unreachable runtime APIs is authorized; rewriting active engine or
safety behavior to make those deletions easier is not. Retain Renoise 3.5,
API 6.2 and Lua 5.1 compatibility. A protected-owner defect that prevents a
required exit criterion blocks that task: isolate it, document the failing
fixture and resolve its scope before continuing. Unrelated engine improvements
do not belong in this redesign.

## Clean cutover and deletion contract

The shipped result has one GUI implementation and one supported set of musical
workflows. No old-layout fallback, feature flag, compatibility alias, transitional
wrapper, no-op facade, migration adapter or alternate menu may preserve deleted
functionality. Temporary construction scaffolding used between tasks must be
gone before final acceptance. Do not ship an intermediate task as the redesign.
The production path must not branch on old versus new UI state or preserve old
function signatures solely for removed callers. Update all retained consumers
together rather than adding argument adapters or accepting obsolete options.

This cutover needs no GUI migration. Do not create one, change saved-song formats,
or remove existing format readers merely because they support older saved data.
Renoise/API compatibility and persisted schema contracts remain protected. Stable
IDs for unchanged controls are ordinary identifiers, not legacy compatibility.
Deleting obsolete accessors does not authorize deleting saved drafts, rewriting
song metadata, repurposing schema fields or adding startup cleanup/migration.

For each removed feature, follow the full deletion chain:

```text
feature -> constructors -> callbacks -> state -> helpers -> runtime APIs
        -> modules/assets -> tests/mocks/probes -> documentation -> package
```

Every node must be deleted or assigned an explicit retained production consumer.
A passing test, exported function, historical contract, defensive naming or
possible future reuse is not evidence of a production consumer. Test-only calls
must not keep a retired production API alive. Do not move obsolete runtime code
into a test helper to avoid removing its obsolete tests.

### Deletion inventory and reachability evidence

Task 1 creates a deletion inventory in the acceptance record. Task 3 resolves
runtime ownership; subsequent tasks maintain it. Each row records:

| Field | Required evidence |
| --- | --- |
| Removed feature | Current control IDs, anonymous constructors and entry points |
| Dependency chain | Owning functions, state, modules, callbacks and assets |
| Production consumers | Exact retained callers and supported scenario; distinguish direct calls, callbacks, injected owners and dynamic loads |
| Disposition | Delete, or retain with the specific production responsibility |
| Safety boundary | Automatic save/restore, target protection, rollback or lifecycle behavior that must remain |
| Coverage | Tests/probes removed, retained or moved, and behavioral assertions preserved |
| Final evidence | Remaining reference disposition and archive inclusion/exclusion |

Start production reachability at `main.lua`, its registered callbacks, `gui.lua`
and actual runtime dispatch/observer paths. Trace functions as well as modules:
a loaded module may contain dead exported APIs. Inspect tables of methods,
closures, dependency injection, lazy `require()` calls and lifecycle callbacks;
simple text search alone is not proof of reachability or deadness. Recheck the
graph after deletion because private dependencies can become orphaned in stages.

The starting deletion candidates include:

| Candidate | Required disposition |
| --- | --- |
| `renoise/selection_context.lua`, `renoise/sampler_audit.lua` | Delete files and obsolete mocks/tests if inspection confirms their only production consumers are removed buttons; removing imports alone is insufficient |
| `context:recovery_entries()`, `:copy_recovery_to_new()`, `:discard_recovery()` | Remove chooser/action-only APIs and exclusive dependencies; retain only independently reachable save/restore or protection behavior |
| `context:independence_projection()`, `:make_independent()` | Audit private identity-operation helpers, cached projections and associated state; remove the retired action path without weakening active duplicate/ownership detection |
| `context:revalidation_status()`, `:revalidate()` | Remove retired action entry points if no retained production caller exists; preserve integrity detection, write rejection and active transaction cleanup |
| Draft-cache list/copy/discard helpers and detached records | Trace automatic save/restore, volatile-draft detection, release and transaction consumers before deciding; do not delete an entire cache based on its recovery terminology |
| GUI report helpers, test stubs and native probes | Remove retired presentation behavior and support; preserve independently useful musical assertions through retained workflows |

Do not retain a dead wrapper around an active primitive. Delete the wrapper and
keep the primitive with its actual callers. Do not delete a safety check because
its old manual repair action has disappeared. If a candidate requires active
engine changes beyond deletion, record the exact dependency and resolve that
scope before proceeding; do not quietly leave a dead compatibility path.

### Blocked-state behavior after removal of repair actions

Before deleting Make Independent or Revalidate, record a fixture for every
blocker producer in the current inventory/runtime/writer, its scope, lifetime,
permitted actions and actual clearing condition. Include observer failure,
mutation-recording failure, adoption failure and writer-integrity failures where
present. Classify a target restriction separately from a song/session blocker.

| State | Required user outcome and safety evidence |
| --- | --- |
| Foreign, colliding or unavailable phrase | No adoption or overwrite. Show a concise editing-unavailable message. Selecting another valid destination or New is permitted only through existing explicit selection/admission and only if actually allowed |
| Target deleted/reordered during request or entry | Preserve exact identity checks; do not reroute or create a phrase. Retained selection controls reflect actual availability; stale completion cannot alter current feedback/source |
| Song/session integrity blocker | Preserve rejection across Generate, Live Edit, Duplicate and other affected mutations. State that ACID cannot safely update this song; do not advertise Generate as a repair or claim that changing targets fixes it |
| Failed save or unreadable draft | Distinguish unavailable saved edits from failed output. Preserve the supported automatic save/restore path and honest unsaved warning; offer no detached-draft recovery action |
| Ordinary failed generation without a persistent blocker | Generate may retry only through full existing admission, with no implicit revalidation, adoption or blocker clearing |

Test dialog close/reopen, target switching, document release and song reload
against each applicable blocker lifetime. Never clear a blocker just to make the
interface usable, and never recommend restart/reopen as a remedy unless the
fixture establishes that it is supported and safe. Preserve blocker-free state
transitions already owned by active production code.

A state that can no longer be repaired in ACID must be documented explicitly as
unavailable, with its data consequences and any verified external action. Do not
hide this limitation in a generic retry message. An unresolved or unknown
blocker outcome fails Task 3 and final acceptance; no replacement repair UI is
authorized. Resolution may be an accurate supported unavailable outcome rather
than automatic recovery, but must not be an undocumented permanent dead end.

## Final interface contract

```text
ACID
Instrument [........................................]
Phrase     [........................] [Rename] [Duplicate]
[Accepted phrase name, only if the chooser does not expose it clearly]

Length [...]   Timing [...]   [Reset pattern]   Pitch span [...]
[Program | Grid]   [Undo] [Redo]   [Copy scope...] [Copy] [Paste]

PITCH
[Positions and page navigation]
[Note keys] [Octave] [Accent] [Slide] [Audition]
TIME
[Positions and page navigation]
[Note] [Tie] [Rest]
[Enter pitches] [Enter timing]
[During entry: progress, Back, Enter and advance, Restart, Finish, Cancel]

SCALE
Root [...]   Scale [...]   [Follow]
Category [...]   Search [...]   [Import]
[Mask enablement and pitch classes]

OPERATIONS
Operation [...]   Scope [...]   [Apply]
[Only the selected operation's parameters; Repeat last where applicable]

OUTPUT
Mode [...]   Bend range [...]
[Live Edit]                                      [Generate]
[Shared feedback, only when needed]
```

This is a structural contract, not a pixel specification. Use native ViewBuilder
rows/columns and content sizing. Keep Program and Grid mutually exclusive.
Controls duplicated between those exclusive views may remain; duplicate controls
visible at the same time must not remain. Do not reduce available musical input
values, including the existing upper-bound C+ assignment, to make the layout fit.

## Resolved implementation decisions

These decisions are part of the contract, not options for the implementer.

| Collision or gap in the starting code | Required resolution |
| --- | --- |
| Reports are removed before replacement feedback exists | Install the local feedback owner first; then delete report surfaces and route their meaningful failures to it |
| `show_diagnostic()` reads `step_division.text` | Remove the report formatter and its callers before deleting `step_division`; keep projection error validation and internal navigation |
| `update_actions()` only populates recovery controls | Delete the whole function, forward declaration and callers with those controls; do not retain an empty facade |
| `update_live_state()` formats deleted reports and calls `update_actions()` | Remove it and its callers; any retained checkbox/eligibility rendering belongs in existing `update()`/`refresh_stage()` paths |
| `refresh_stage()` disables Finish until all positions are entered | Preserve that eligibility; show the first missing position after a blocked Generate/entry-resolution attempt, including when Finish cannot be clicked |
| `changed()` saves, then flushes Live Edit synchronously | Publish save outcome before flush; completion may not overwrite an unresolved save failure |
| Startup scale-load failure is written before `load_target()` replaces status | Store it as a dialog-scoped issue and render after initial target load; target changes must not erase it |
| Native selection discards invalid entry and appends recovery prose | Preserve invalidation and draft effects; present one destination/entry message, with an unsaved-edits warning only when supported by the result |
| Rename Retry is necessary; recovery actions are forbidden | Keep rename dialog Save/Retry/Discard Attempt semantics. These resolve a label edit, not detached recovery. Main-editor recovery actions remain absent |
| A generic live failure has no certified retryability flag | Do not construct contextual Retry in this follow-up. Existing Generate remains the explicit retry path and runs full admission |
| Existing GUI tests invoke Check to release audition | Replace that trigger with retained page/view navigation; retain the injected note-off failure assertion through shared feedback |
| Existing views can occupy one parent only | Move construction/attachment, not just variable references. Never attach a child to both old and new panels |

### Construction and Lua scope rules

Keep control creation, callback assignment and parent assembly distinct within
`M.show()` without extracting a framework. Forward-declare callback variables
before their closures capture them; assign callbacks before the dialog is shown
or any initial update can invoke them. In particular retain the order that
installs `ui.admit_operation` before Reset can run, and `random_state.run` before
Repeat last can run. Moving a `local function` below a closure can accidentally
turn its reference into a global in Lua 5.1; check every moved callback capture.

For intermediate tasks, assemble moved controls only in their new parent.
Delete their old parent entries in the same edit. After removing a workspace
panel, rebuild the temporary panel/tab arrays together, reset the temporary tab
index to a valid entry, and never keep sparse arrays. This applies after each
panel removal, not only after deleting Decoded and Recovery.

Retain control IDs for unchanged roles. Do not add hidden compatibility aliases.
Keep `acid_program_discard` as the existing entry-cancel ID unless all consumers
are intentionally updated together; its visible label becomes Cancel. Keep
`acid_audition` for Program; use `acid_grid_audition` for Grid, both invoking one
local audition callback. Both must share eligibility and release behavior.

### Pinned layout constraints

The pinned definitions are `definitions/library/renoise/views/view.lua` and
`views/rack.lua`; accompanying docs are `docs/API/renoise/renoise.Views.View.html`
and `renoise.Views.Rack.html`. `visible=false` hides without removing a view;
it does not establish that a rack releases the reserved space. `add_view()` and
`remove_view()` are the current methods; `add_child()`/`remove_child()` are
deprecated aliases. Rack documentation describes automatic resizing when child
sizes or membership change. Native dialog shrink/fit still needs host evidence.

Use dedicated content-sized holder columns for the active editor, entry row,
operation parameters and feedback. Change membership only when the selected
child changes, using `remove_view()` followed by `add_view()` on the same holder.
Never rebuild widgets or register notifiers on each `update()`. Track attached
children explicitly rather than inspecting inherited `visible` values. Attach
no feedback child when empty. Extend each affected mock builder to implement
these methods with membership/order checks before introducing the calls.

Do not close/reopen the dialog to resize it: that changes lifecycle and audition
behavior. Task 1 must probe host sizing with a disposable ViewBuilder dialog
before the production layout is implemented. If content removal does not resize
the host as needed, resolve a supported content-sizing approach in Task 1;
later tasks must not discover this as an unplanned layout fallback.

## Task 1 — Establish the baseline and API constraints

**Files:** `gui.lua`, `model/sequencer.lua`, `model/editor_state.lua`,
`runtime/context.lua`, existing GUI specs and manual guides under `../tests/acid/`.

1. Record the current revision and worktree changes. Read repository instructions
   and the current M5 protected contracts; use actual code as the relocation map.
2. Run from the repository root in PowerShell 7:

   ```powershell
   ./scripts/setup_sdk.ps1
   ./scripts/run_tests.ps1 -Tool ACID
   ```

3. Inspect the API 6.2 ViewBuilder definitions and corresponding offline docs in
   `sdk/renoise-api-6.2/` before changing construction, visibility, sizing,
   child attachment, dialog or notifier calls. Establish whether hidden children
   collapse and how an open dialog responds to content-size changes. Do not
   assume the host behaves like the GUI stub. If SDK acquisition fails, use the
   official versioned API-6.2 sources and record unresolved host questions.
4. Inventory every control being retained or deleted, its constructor, notifier,
   update path, presentation state and tests. Search references before deleting
   helpers. Build the deletion inventory and production reachability evidence
   specified above, including runtime method consumers and packaged modules.
   Enumerate blocker producers, scopes and clearing conditions before approving
   deletion of repair APIs. In particular, `project()` and projection invalidation also support
   editing, audition and validation; they are not disposable preview code.
5. Record baseline `gui.lua` line count, runtime GUI dependency set and ACID
   archive file list. Also record total lines/files across the affected runtime
   dependency set, so moving code out of `gui.lua` cannot conceal retained code.
   Establish
   behavioral fixtures with unequal TIME/PITCH lengths, both pages, masked notes,
   saved drafts, New Phrase and existing owned/foreign/unavailable destinations.
6. Record actual baseline test results in the implementation acceptance record.
   Do not copy old spec totals as current evidence.
7. Create the evidence destination `../tests/acid/acid_gui_redesign_acceptance.md`
   with revision, baseline, per-task results, native checks and open issues.
   Mark each unexecuted check unverified. Use behavior-based test names, not M5
   labels. Do not modify old closeout receipts.
8. Run the small native sizing probe described above for empty/full holders and
   the tallest planned editor. Record screen work area, scaling and dimensions.
   Native access is a prerequisite for resolving this layout risk; if unavailable,
   finish the audit but leave this task's layout exit open rather than guessing.

**Exit:** Baseline failures are resolved or identified as pre-existing with a
bounded disposition; API constraints and retained callback owners are known.
The deletion inventory covers all removed features, runtime candidates and
blocker producers. Native sizing is resolved before advancing; an unexecuted
probe does not satisfy the exit.

## Task 2 — Install feedback ownership before deleting reports

1. Use one shared feedback area for actionable outcomes. Normal ready state is
   empty and consumes minimal space. Create its holder now; the next task removes
   separate diagnostic/live/save surfaces. A rename dialog may retain its local input validation; it must not
   create another permanent main-editor report.
2. Replace `describe_result()`/`result_status()` diagnostic concatenation with a
   small presentation mapping. Prefer local functions in `gui.lua`; extract a
   private helper only if it clearly simplifies the result. Do not forward raw
   `reason`, `diagnostics` arrays or arbitrary runtime table values to the user.
3. Inventory actual outcomes from the current runtime/writer/store before
   mapping them. Use existing structured discriminants and explicit call-site
   context. Do not invent result fields, change runtime contracts, or depend on
   brittle substring matching of diagnostic prose. Unknown outcomes get a safe
   generic failure message without an unsupported save claim. Apply the
   blocked-state contract above: persistent blockers receive an unavailable
   outcome, never an instruction to retry a request that admission rejects.

   | Established outcome | Presentation |
   | --- | --- |
   | Missing pitch at a known position | `Cannot generate: choose a pitch for step 5.` using the actual position |
   | Incomplete sequential entry | Name the missing pitch/timing position and reveal it where supported |
   | Destination unavailable or unsafe | `This phrase is no longer available. Select another phrase.` or a truthful unavailable-for-editing variant |
   | Current generation failed | `Couldn't update the phrase. Try again.` only when retrying is meaningful |
   | Document changed | `The song changed. Reopen ACID.` |
   | Draft/save failed | `Your latest edits could not be saved with the song.` |
   | Import failed | Identify read/format/save problem and an available corrective action |
   | Verified explicit operation completed | Short confirmation when useful, such as `Phrase duplicated.` |
   | Routine edit, view change or successful undo/redo | No persistent success paragraph |

4. A generation result and a save result are distinct. Preserve evidence of a
   save failure even if another operation succeeds. Say edits are saved or a
   phrase is unchanged only when the runtime establishes that fact. If musical
   output has a meaningful approximation warning, keep a concise musical warning
   without dumping internal planning diagnostics.
5. Define feedback replacement explicitly: navigation and routine `update()` do
   not erase unresolved failures; a successful retry of the same operation may
   clear its failure; target change clears target-specific feedback; a new
   explicit outcome may replace transient confirmation. Stale callbacks must
   neither publish success nor clear current-context errors.
6. Audit retained-action `status.text`, status render, prompt, dialog and notification paths.
   Preserve rename retry/discard-attempt safety while simplifying vocabulary.
   Preserve audition-cleanup failures as honest actionable feedback. Recovery
   callbacks are deleted in Task 3, not renamed or reimplemented here.

### Local feedback state and adapters

Implement one small GUI-local owner, not an event bus or a second runtime model.
Use fixed issue slots for save, destination, scale-load/import, audition cleanup,
input and generation, plus one transient confirmation. A slot holds a message
key, safe musical arguments and its relevant existing context identity. It must
not store the raw runtime report for rendering. Render unresolved issues in
fixed order (save, destination, scale, audition, input, generation), deduplicate
identical messages, and suppress confirmations while any issue is unresolved.
One area may contain multiple short lines; one success must not conceal another
operation's failure. Do not truncate away an unsaved-edits warning to fit height.

Use local operations equivalent to `set_issue(slot, key, args, context)`,
`clear_issue(slot, context)` and `render_feedback()`. These are implementation
contracts, not required public APIs. Message keys stay behavior-named. The owner
must exist before startup scale-load and audition callbacks can publish to it;
widget rendering may wait until the holder exists. Do not reset it in `update()`.

| Producer and available evidence | Exact adapter responsibility |
| --- | --- |
| `save_draft()` caller receives `saved, save_error, effects` | On false, set save issue before `flush_pending()`; on true, clear only the matching target's save issue. Never derive a save success from later generation success |
| `load_target()` receives draft/source availability | Successful restore is quiet; draft error publishes load failure, unavailable source publishes destination issue. Neither means an older failed save succeeded |
| `deliver(request, result)` | Retain all accepted-source/history/choice synchronization. Publish success only for verified success with current destination; never print raw diagnostic arrays |
| `request_generation()`/`request_duplicate()` returns false and a string | Map from known call-site context and current eligibility to generic actionable failure; never parse the string to fabricate an error code |
| `finish_stage()`/`guard_stage()` | Use known memory and first missing numeric position. Task 7 adds selection behavior; this task installs message ownership only |
| `label_ui.apply()` | Keep attempt and history proposal intact on failure; preserve local dialog error plus concise main feedback. Use the existing label validator to provide accepted-format guidance without parsing runtime errors |
| Scale file read/parse/merge/save branches | Branch identity determines message: cannot read, invalid/empty definitions, library too large, cannot save. Only advertise a corrective action available in that branch |
| `preview` cleanup callback and audition start outcome | Publish concise note-release failure; keep technical detail in existing internal outcome only |

For stale completion presentation, use existing `result.stale` and
`result.destination_current` evidence; do not compare phrase indices. The runtime
sets these terminal fields in `runtime/context.lua`. Suppress target-specific
feedback when stale or not current, including failures; preserve any required
runtime completion processing. A current integrity blocker must still surface
through current eligibility even if its originating request became stale. Do
not add an early return that skips accepted-state housekeeping merely to suppress
text. Add both stale-success and stale-failure fixtures.

Dialog-scoped scale-load and unresolved audition-cleanup issues survive target
switching. Target-specific validation and generation issues clear on an actual
binding change, not on a rename or index reorder. An unresolved save issue on
the previous target becomes `Edits to the previous phrase could not be saved with
the song.`; it is not erased by selecting another phrase or saving that other
phrase. Keep a bounded unsaved-warning flag for previous targets, clear it only
with matching verified save evidence or when the dialog lifetime ends, and do
not claim that closing the dialog resolves the failed save. No recovery action
is attached. Ordinary navigation does not clear any failure slot.

**Required fixtures before advancing:** failed draft save followed by synchronous
successful Live Edit; startup scale-load failure followed by successful target
load; target A failure followed by target B success; stale A completion after B
selection; failed rename and retry; audition release failure during navigation.
Assert outcome and write/save counts, not just text. No false saved/preserved
claim or recovery offer may appear.

**Exit:** Retained actions use the shared owner, failure ordering and stale-result
fixtures pass, and no retained-action diagnostic concatenation remains.
Old report views/recovery callbacks still exist solely until Task 3 removes them.

## Task 3 — Remove development and recovery presentation

**Primary owner:** `gui.lua`; adapt directly affected GUI assertions in this task.

Delete constructors and their exclusively owned support together:

| Remove | Associated code to inspect and delete when exclusively owned |
| --- | --- |
| Details toggle and panel | Visibility state, `acid_details_toggle`, `acid_details_panel`, child reports |
| Source/preview summaries and source-state report | `summary`, `map_text`, `source_state`, formatting, dirty/committed rendering |
| Live-state/last-commit reports | `live_state_view` and report formatting in `update_live_state()` |
| Decoded view | `DECODED_ROWS`, `DECODED_PAGES`, `decoded_page`, selector, rows, pagination, `ui.decoded` |
| Pattern inspector and sampler audit | Buttons, callbacks, GUI imports of `renoise.selection_context` and `renoise.sampler_audit` |
| Manual Check | `acid_program_check`, callback and report-only formatting |
| Recovery workspace | `recovery_entries`, picker, detail, pagination, `ui.recovery`, `selected_recovery()`, `render_recovery_page()` |
| Recovery actions | Copy to New, Discard recovery entry, Make Independent, Revalidate and their GUI callbacks |

1. Remove references to deleted panels from the temporary workspace list so
   construction stays valid until Task 10 removes that list entirely.
2. Inspect `project_runtime_editor()` and `wrap_lines()` callers before deleting
   either helper. Delete only if no retained responsibility remains.
3. Delete `update_actions()`, its declaration and all callers: its current body
   exclusively populates recovery controls. Preserve the separate eligibility
   queries that gate musical actions.
4. Delete `update_live_state()`, its declaration and all callers with its report
   views. Remove report-only branches from `update()` rather than adding nil
   guards. Retain generation-state reads in `changed()` and checkbox handlers
   where required for arming/flush behavior; these are separate responsibilities.
5. Audit `load_target()`, `save_draft()`, `changed()`, history and completion
   handlers for recovery wording. Replace it with ordinary save/destination
   failure feedback through the Task 2 owner. Do not suppress a
   draft-load failure just because its old recovery banner is removed.
6. Keep validation and missing-position detection used by Finish/Generate.
   Diagnostic navigation may survive as internal error navigation; diagnostic
   reports and dedicated development controls may not.
7. Keep engine tests for retained save/restore, integrity, persistence and
   lifecycle responsibilities. Remove tests whose sole subject is a deleted
   runtime action, not just GUI action-invocation tests. Extract independently
   useful destination, blocker, saving and lifecycle assertions before deleting
   a mixed spec; exercise them through retained production workflows. Update
   mocked API tables and inventory/export assertions to the actual reduced API.
8. Remove `acid_audition_status` and its dedicated view; route its cleanup callback
   to the shared feedback owner installed in the preceding task. Preserve the
   callback even after its old view disappears. Remove `diagnostic` and
   `diagnostic_jump`, their construction and `show_diagnostic()` together.
   Keep only an internal error-position helper used by explicit failed actions.
9. Retain `project()`, `stage_resolution()`, prepared resolution invalidation,
   `projection.used` where still needed for musical selection, and model
   `editor.step_text()` for non-GUI callers. Delete preview-only `preview_cycle`
   and selectors only after removing every associated GUI use.
10. Resolve every starting runtime candidate in the deletion inventory. Remove
    dead action APIs, exclusive helpers/state and orphaned modules in the same
    task as their last production caller. Include obsolete `package.loaded`
    stubs, dependency-graph expectations and native probe invocations. Repeat
    reference tracing until no exclusive dependency remains. Retained helpers
    require exact current production callers and a supported scenario.
11. Execute the blocker fixtures before and after removal. Compare write,
    save, history, binding and integrity outcomes through retained workflows.
    Record the resulting supported unavailable states and verify their feedback
    does not offer impossible retry, automatic New or a removed repair action.
12. Audit top-level `release_context()`, document/unload callbacks and writer
    release notifications as well as `M.show()`. Remove recovery presentation
    there without suppressing truthful ordinary save/loss or failed-cleanup
    warnings. No technical recovery report may survive outside the dialog.

**Exit:** No removed control is constructed, no GUI callback offers recovery,
blocked destinations remain blocked, and applicable tests pass. Retired runtime
APIs and exclusively owned modules/state are absent, retained internals have
production-consumer evidence, and all blocker outcomes are resolved. No test
calls a removed API or keeps a production API alive solely for testing.

## Task 4 — Build the phrase header and sequence settings

**Owners:** Target/phrase construction, `label_ui`, `load_target()`,
`select_instrument()`, `refresh_phrase_choices()`, reset and duplicate callbacks.

1. Put Instrument first, then Phrase with Rename and Duplicate. Move the
   existing widgets/callbacks; do not create a second binding or notifier path.
2. Preserve New Phrase selection and native instrument/phrase synchronization.
   Preserve pending-entry and pending-rename guards before destination changes.
3. Expose the accepted phrase name through the chooser or one adjacent display.
   Keep Rename as a secondary dialog with the existing accepted label grammar,
   save/retry guarantees and failure handling. Simplify its technical wording
   without changing confirmation or validation policy.
4. Move Duplicate out of Pattern / Copy, preserving `request_duplicate()`, stale
   completion checks, accepted-source/history synchronization and save failures.
5. Place Reset pattern between Timing and Pitch span on the settings row. Keep `guard_stage()`,
   `ui.admit_operation`, `reset_source()` and `changed()` behavior. Add no prompt.
6. Place Length, Timing, Reset pattern and Pitch span immediately above the editor. Rename
   LAST STEP and Active PITCH span. Make Timing choices communicate their
   divisions, then delete `step_division` and its update computations.

**Exit:** Header actions still use existing guarded owners. Changing TIME length
does not change PITCH span or erase inactive stored positions. Rename failure
does not falsely report a save or lose an outstanding attempt.

## Task 5 — Consolidate the editor toolbar and history

1. Place the existing Program/Grid selector, Undo, Redo, clipboard scope, Copy
   and Paste in one toolbar. Preserve the existing PITCH/TIME/Both scopes.
2. Remove `clipboard.status`, contents descriptions and empty-state rendering.
   Preserve payload/scope state. Paste is inactive for an absent or incompatible
   payload and whenever existing admission rules prohibit it; keep callback
   guards even when a button is inactive.
3. Preserve scope matching, source candidate validation, pending-entry guards,
   no-op behavior and one accepted history/save/live path for paste.
4. Keep `move_history()` proposal/commit semantics and label-only handling.
   Remove persistent successful-save paragraphs; retain truthful save failures.
5. Delete Pattern / Copy after its last retained child has been relocated.

**Exit:** Copy does not edit or generate; paste/history retain their exact edit
and saving behavior. Navigation and view switching create no history entries.

## Task 6 — Simplify Program and Grid without changing interpretation

1. Retain independent PITCH/TIME selections, pages, highlighting, inactive-step
   treatment, keys, octave, C+, accent, slide and NOTE/TIE/REST assignment.
2. Remove `view_heading`, repeated Program/Grid headings, selected-pitch/time
   summary rows, explanatory paragraphs and source-interpretation diagnostics.
   Preserve useful musical note identification in controls/tooltips.
3. Put shared TIME assignment under the active editor's TIME positions. Create
   Program and Grid audition buttons with distinct IDs as specified above and
   one shared callback. Each belongs to its view's PITCH controls. Update both
   active states in `refresh_stage()`; never attach a child to two parents.
4. Preserve source projection/resolution caching needed for musical behavior.
   Remove only formatting and caches that exclusively supported deleted text.
5. Keep audition release on selection/page/view changes, editing, destination
   changes, close, song release and unload. Keep actual resolved-pitch audition.

**Exit:** Both views edit the same source without altering pitch/time traversal.
Positions 16/17/32, unequal lengths, inactive positions and masked audition retain
their existing behavior; view changes do not write or save musical edits.

## Task 7 — Make sequential entry contextual

**Owners:** `begin_stage()`, `valid_stage()`, `candidate_edit()`,
`missing_positions()`, `finish_stage()`, `guard_stage()`, `stage_navigation()`.

1. Expose Enter pitches and Enter timing in normal editing where currently
   supported. Preserve the existing Program entry workflow and Grid switching
   restrictions; do not invent editable staging in Grid.
2. During entry, show Back, Enter and advance, Restart, Finish and Cancel plus
   a short progress label such as `Pitch 5 of 16` or `Timing 5 of 16`.
   Hide redundant entry launch/Edit One controls while entry is active.
3. Rename Restart Cursor to Restart but preserve cursor-only behavior; it must
   not erase entered positions. Rename the entry Discard action to Cancel while
   preserving existing confirmation semantics and accepted-source isolation.
4. Keep candidate edits separate from accepted source/history/saving until
   Finish. Preserve Enter-and-advance marking and the existing last-position
   behavior. Cancel restores accepted editing without a musical commit.
5. Finish validates origin, eligibility, entered positions and candidate source.
   Missing-entry feedback names the first missing pitch/time position. Use the
   existing selection helpers to reveal it on its page where supported, without
   marking it entered or changing accepted source.
6. Generate retains `guard_stage()` and its existing resolve-then-invoke-again
   contract. It must not silently finish a candidate or bypass validation.
7. Keep destination/document/revision identity checks internally. Present stale
   entry as `The destination changed. Start entry again.` or the corresponding
   song-change message. Remove origin/candidate/revision/transaction vocabulary
   from ordinary entry messages and prompt text.
8. Keep Finish disabled for incomplete entry. On blocked Generate or another
   guarded action, compute the first `entered[index]==false` in target-position
   order; use its numeric index, not parsing `Pxx`/`Txx` display text. In Program,
   call the matching selection helper so page and `stage.cursor` agree. In Grid,
   preserve read-only staged viewing and direct the user back to Program; do not
   silently switch view or mark a position entered. Progress uses `stage.cursor`
   and target count, not the number of entered positions.
9. Keep Back/Enter/Restart semantics and currently supported Finish/Cancel access
   when switching views; do not reinterpret hiding the editor as cancelling the
   stage. The progress row must remain reachable outside the active editor holder.

**Exit:** Incomplete/stale entry never writes, saves a partial candidate or
generates. Finish/Generate validate automatically without a Check control.

## Task 8 — Separate Scale and Operations

1. Move scale widgets into SCALE below the editor. First row: Root, Scale,
   Follow. Second row: Category, Search, Import. Follow with mask enablement and
   pitch-class controls. Reuse callbacks and existing category/filter state.
2. Preserve root browsing versus applying a selected scale, Follow behavior for
   newly entered notes, mask semantics, history and save behavior. Browsing or
   filtering alone must not accidentally become an edit.
3. Delete `scale_detail`, counts, Mask/Follow reports and permanent instructions.
   Retain useful aliases/categories in the scale selector tooltip.
4. Preserve custom-scale load/parse/read/merge/save error handling, including
   uncertain saves and `scale_state.load_error`. Surface errors in shared
   feedback; never silently skip a failed load. Successful import may report
   `Scales imported.` without library statistics or parser internals.
5. Replace Extended / Clear with OPERATIONS. Keep one selector, scope and Apply.
   The current operation inventory is:

   | Operation IDs | Parameters |
   | --- | --- |
   | `clear_pitch`, `clear_time`, `clear_tie`, `clear_rest`, `clear_slide`, `clear_accent` | Scope only |
   | `rest_to_note`, `tie_to_rest` | Scope only |
   | `randomize_pitch` | Scope, seed, minimum and maximum note |
   | `randomize_time` | Scope, seed, NOTE/TIE/REST weights |

6. Preserve Active memory and All 32 stored scopes, seed range/defaults, note
   bounds, weights, distributions and normalization through
   `sequencer.operation_candidate()`. Preserve admission and no-op checks.
7. Show only parameters required by the selected operation. Keep Repeat last:
   the existing per-operation remembered seed is distinct from the editable seed.
   Delete `random_state.display` and redundant deterministic-behavior prose.
8. Preserve any additional existing operation found in Task 1. The brief's
   reference to arpeggio does not authorize a new algorithm; the inspected GUI
   exposes the ten operations listed above.

**Exit:** Parameter visibility follows selection without mutating source. Exact
seed/source/parameters/scope produce unchanged results. No scale or operation
control requires a workspace tab.

## Task 9 — Place output and generation together

1. Put Mode and Bend range in OUTPUT, followed by Live Edit and Generate.
   Preserve output policy and bend-range values, persistence and edit admission.
2. Use Generate for both create and regenerate. Keep internal request intents,
   exact-destination checks and the explicit New Phrase binding unchanged.
3. Move the receiver bend-range assumption, channel-wide bend warning and
   isolated monophonic routing requirement into the bend-range tooltip. Preserve
   the existing Off behavior and tooltip information needed for correct output.
4. Remove the permanent Retry Live Edit button and success paragraphs explaining
   that manual generation remains available. Arming alone must still not write.
5. Do not add contextual Retry: `generation_state()` exposes the last result and
   occupancy, not a retryability guarantee. Preserve Generate as the explicit
   retry through `request_generation("manual")`, with pending-entry, current-song,
   target synchronization and projection validation before admission. Do not add
   a runtime API to support a redundant button or call revalidation implicitly.

**Exit:** Manual/Live Edit generate through the same protected owners; New Phrase
creates once and an existing owned phrase updates in place. Stale targets and
blocked requests do not append, reroute or clear safeguards.

## Task 10 — Remove workspace navigation and content-size the dialog

1. Delete `workspace_tab`, `ui.workspace`, tab names/buttons, panel switching,
   `WORKSPACE_HEIGHT`, fixed panel origins/sizes and the fixed-height stack.
2. Assemble the final root column in the order shown above. Keep only the
   Program/Grid editor selection. No alternate diagnostic or recovery menu.
3. Remove now-empty wrappers. Ensure each retained widget is attached once and
   each notifier registered once. Visibility updates must not generate edits.
4. Use named layout constants where sizes are necessary. Let the root and
   functional sections size to actual content; no blank reserved workspace area.
   Collapse inactive entry and parameter rows using verified API behavior.
5. Inspect all remaining update paths and delete calculations/references for
   removed views. Confirm `update_live_state()` and `update_actions()` have not
   been reintroduced; their report responsibilities ended in Task 3.
6. Remove every intermediate panel list, temporary tab index, compatibility
   wrapper and layout fallback introduced while relocating controls. Inspect
   registered menu/keybinding callbacks too; none may open an old or alternate
   implementation. The entry points in `main.lua` all reach the single final GUI.

**Exit:** All retained controls are reachable without workspace navigation, the
root has no fixed-height workspace reservation, and mocked construction succeeds
for Program/Grid, active entry, random parameters and feedback states. Actual
screen fit remains a required Task 12 host check.

## Task 11 — Complete behavioral regression coverage and documentation

Update affected assertions alongside each preceding change; this task completes
the cross-feature matrix. Do not defer a knowingly broken suite until this task.

| Existing test owner under `../tests/acid/` | Required retained or revised evidence |
| --- | --- |
| `acid_gui_views_spec.lua` | Both editors, selection/pages/inactive positions, toolbar, entry, operations, scale controls, generation and construction absence |
| `acid_gui_admission_spec.lua` | Stage/label guards, operation admission, invalid destination rejection |
| `acid_gui_timing_race_spec.lua` | Timing and target races retain stale-write protection |
| `acid_program_staging_spec.lua` | Entry completeness, candidate isolation, view switching, guards, audition and cleanup; replace removed Check/text probes |
| `acid_gui_live_edit_lifecycle_spec.lua` | Retained safety/lifecycle cases; no recovery actions or replacement recovery UI |
| `acid_editor_spec.lua`, `acid_clipboard_spec.lua` | History, payload scopes, candidate/no-op behavior remain intact |
| `acid_duplicate_label_spec.lua` | Rename validation, retry failures, duplicate identity and saving |
| `acid_scales_spec.lua`, `acid_scale_preferences_spec.lua`, `acid_scale_mask_spec.lua` | Scale semantics and load/save failures preserved |
| `acid_audition_lifecycle_spec.lua` | Audition release and document/dialog cleanup |
| Runtime, store, recovery and writer specs | Active save/restore, integrity, drafts and transaction behavior; delete retired action-only coverage after preserving independent safety assertions |

1. Replace summary-text-based assertions with source snapshots, selected control
   state, request records, history/save counts and destination identity checks.
   Do not delete behavioral coverage just because its old text probe disappeared.
2. Add a focused construction-absence assertion over registered views and
   constructor records, including anonymous buttons. Cover Details, decoded,
   audit/inspection, Check, recovery actions, workspace tabs and permanent retry.
   Hidden forbidden controls also fail. Avoid a snapshot of every row or label.
3. Exercise all ten operations and both scopes against existing deterministic
   model expectations. Check parameter visibility and Repeat last separately.
4. Inject generation, draft save, custom-scale load/import/save, rename save,
   audition cleanup and destination-change failures. Assert actionable feedback,
   no false save claims and no unsafe request; include stale completion feedback.
5. Update all affected builders, not just `gui_host_stub.lua`. Current GUI specs
   also embed their own ViewBuilder implementations. Search `view_builder`,
   `ViewBuilder` and `add_child` in the affected specs listed below; introduce
   `add_view`/`remove_view` membership support before the first production use.
   A removed child must disappear from its parent's children while remaining
   addressable by ID. Reject duplicate parenting. Do not make mocks claim native
   sizing or audio correctness.
6. Update `acid_editor_presentation_manual.md`: remove Details/workspace/decoded
   expectations and use the Task 12 journey. Update user-facing ACID README and
   current design references that still direct users to removed controls.
   Preserve historical acceptance records; link the follow-up rather than
   rewriting old pass claims. Update roadmap status only from actual evidence.
7. Reconcile tests, embedded builders, injected API tables, fixtures and native
   drivers against the deletion inventory. Remove obsolete action-only assets
   and mocks rather than maintaining dummy methods for compatibility. Rename a
   mixed spec by its retained responsibility if its old name no longer describes
   it; do not cosmetically rename historical receipts or persisted identifiers.
8. Add absence assertions for removed runtime methods and deleted module files
   as well as views, using the finalized inventory. Exercise production
   startup/retained workflows without preloading deleted modules into mocks.
   Absence assertions supplement the manual reachability review; they do not
   prove that every remaining function is live.

**Exit:** Every retained behavior has an assertion or explicit native check;
obsolete presentation assertions are gone; current user documentation agrees
with the redesigned interface. No compatibility test fixture, dummy method or
executable probe depends on the retired workflows. Blocker lifetime and
unavailable-outcome fixtures cover the final supported behavior.

### Required cross-feature fixtures

Use the existing in-memory song/runtime fixtures and builders. Extend existing
specs where the behavior already has an owner; add a behavior-named feedback spec
only if isolation makes the failure cases materially clearer.

| Setup and action | Assertions required beyond the visible message | Owning task |
| --- | --- | --- |
| Inject failed draft save, then allow synchronous Live Edit success | Save failure remains, only expected write occurs, accepted source/history agree, no claim that edits were saved | 2 |
| Load custom scales fails; initial phrase loads successfully | Scale issue survives startup and target switches; Import stays disabled according to existing load-error policy | 2 |
| Start a request for A, switch to B, deliver A success and failure separately | No B source/history mutation, no stale success or error replaces B feedback; current integrity block still gates writing | 2 |
| Open and refresh after deleting diagnostic/recovery controls | No removed constructor calls, no nil reads, no runtime recovery action invoked; internal draft restore still runs | 3 |
| Rename invalid label, inject save failure, retry, then label-only Undo | Attempt and proposal survive failure; one accepted save/history transition; destination identity remains stable | 4 |
| Copy PITCH, select TIME scope, invoke Paste directly despite inactive control | No edit/save/write; matching scope can paste; no-op paste does not create history | 5 |
| Edit P17 with TIME 01 selected and unequal lengths; switch both views | Independent selections and active bounds retained; changing view adds no history/save/write | 6 |
| Begin entry, enter positions except 5, attempt Generate | No generation/partial save, missing position shown; Program selection/page/cursor move to 5 without marking it entered | 7 |
| Repeat preceding case in Grid, then return to Program | No implicit view switch or Grid candidate edit; stage remains available for existing completion/cancel flow | 7 |
| Randomize with seed A, edit seed to B, Repeat last | Uses A with current other parameters/scope, matching current implementation; Apply uses B; no distribution/default change | 8 |
| Arm Live Edit, navigate, then edit; fail a write and invoke Generate | Arming/navigation write nothing, edits use one pipeline, Generate retries only through admission; no Retry button | 9 |
| Switch editor/entry/parameter/feedback holders repeatedly | Stable widget/notifier counts, one parent per child, no detached active duplicate controls or growth of child arrays | 10 |
| Trigger audition cleanup failure using retained navigation | Release attempted exactly as before; failure remains in shared feedback; no dependency on Check or `acid_audition_status` | 6 |
| Create each persistent blocker, then Generate/Live Edit/Duplicate and change targets or reopen | Existing mutation gates and blocker lifetimes preserved; no false retry remedy, implicit clearing, adoption or automatic New | 3 |
| Instantiate the reduced runtime and load retained entry points without retired module stubs | Retired methods absent; retained workflows run through real active dependencies; no compatibility facade or lazy load of removed modules | 3, 11 |

The retained GUI specs requiring a direct obsolete-reference pass are
`acid_gui_views_spec.lua`, `acid_gui_admission_spec.lua`,
`acid_gui_timing_race_spec.lua`, `acid_gui_live_edit_lifecycle_spec.lua`
and `acid_program_staging_spec.lua`.
Search native probe code too: a probe that invokes a removed button must be
updated to the retained workflow before its acceptance run. Preserve historical
reports as evidence of the old interface, not executable current procedures.

For construction absence, assert only the subset already removed at each task.
Task 3 prohibits diagnostic/recovery constructors; Task 5 adds Pattern / Copy;
Task 9 adds permanent Live Edit Retry; Task 10 adds workspace navigation and
fixed-height containers. The final assertion covers their union. Do not demand
final layout absence in an earlier task that deliberately retains temporary tabs.

## Task 12 — Run final checks and native acceptance

1. Run in PowerShell 7 from the repository root:

   ```powershell
   ./scripts/run_tests.ps1 -Tool ACID
   git diff --check
   ```

2. Package ACID after this redesign because runtime modules/package inputs are
   deleted. Run `./scripts/package.ps1 -Tool ACID`. Verify `main.lua` and
   `manifest.xml` at archive root, private module directories preserved, and no
   SDK/development artifacts. Inspect the newly built archive's full file list
   against the deletion inventory: no retired modules, assets, old GUI variants
   or transitional files. Record archive name and hash to identify this result;
   an older archive in `dist/` is not evidence for the changed checkout.
   Run broader suites only if shared code changed or failures justify them.
3. Search the entire ACID runtime, tests, current docs and executable native
   probes for removed IDs, action names, APIs, module names, report formatters
   and orphaned branches. Include anonymous constructors, strings used for lazy
   loading and injected dispatch methods. Review every match by purpose against
   the deletion inventory. Historical receipts and protected persisted markers
   may remain; record these exceptions explicitly. A historical document may
   describe a removed API; executable code may not rely on it.
4. Compare GUI implementation size with Task 1. `gui.lua` must be smaller overall;
   include any new presentation helper in the comparison so extraction cannot
   conceal retained diagnostic code. Compare affected runtime totals and the
   module/archive inventory too. Re-run production reachability tracing after
   all deletions; confirm zero unresolved inventory rows and no test-only
   production exports for retired workflows. Verify no manifest/schema/unrelated-tool
   changes and no machine-specific paths in committed documentation.
5. In Renoise 3.5, use a disposable song and execute this matrix:

   | Journey | Required observation |
   | --- | --- |
   | Open Program and Grid at normal display scaling | Full dialog fits usable screen; no clipping or blank workspace; record actual size/scaling |
   | Expand entry, random parameters and multiline error | Controls remain reachable; hidden rows collapse; feedback remains readable |
   | Edit unequal lengths at 1/16/17/32 boundaries | Independent pages, highlights, inactive handling, keys/octaves/C+/accent/slide/time commands preserved |
   | Enter pitches and timing | Back/advance/restart/finish/cancel work; incomplete entry identifies its position; stale target attempt cannot commit |
   | Copy/paste all scopes, Undo/Redo | Correct memory changes and eligibility; no extra history or writes from navigation |
   | Root/category/search, select scale, Follow, mask and import | Browsing purity, application semantics and error visibility preserved |
   | Every operation in both scopes; seeded repeat | Musical results and preserved inactive memory agree with scope; correct parameters visible |
   | New Phrase and existing phrase Generate | Exactly one creation or exact in-place update; unavailable/foreign target remains protected |
   | Live Edit arm/edit/failure | Arming alone writes nothing; edits follow existing pipeline; explicit Generate retries through admission; no permanent/contextual retry button |
   | Rename, Duplicate and Reset | Existing validation, guards and history/save behavior retained |
   | Native instrument/phrase changes, deletion and reorder | Current choices and exact binding; no wrong-target writes |
   | Audition, close/reopen dialog, switch/release song | Note release and notifier cleanup; stale callbacks do not affect next session |
   | Save, close and reopen song with ungenerated edits | Automatically saved edits restore; no recovery UI; generation uses restored source |
   | Protected unavailable target and any safely reproducible persistent blocker | Accurate unavailable outcome, no repair UI or impossible retry guidance, no implicit adoption/clearing; verify target-switch and reopen behavior against documented lifetime |

6. Use existing destination, Live Edit and lifecycle manual guides for detailed
   protected behavior checks. Mark failures that require injection as mocked
   coverage unless actually reproduced in Renoise. Record audible observations
   separately from control/phrase inspection; mocks do not validate playback.
7. Record revision, automated commands/results, archive inventory/hash,
   GUI and affected runtime size comparison, completed deletion inventory,
   blocker outcomes, native scenarios actually performed and remaining gaps.
   If Renoise is unavailable, report native checks as unverified and keep native
   acceptance open. Do not equate a passing mocked suite with full completion.

**Exit:** Automated checks pass, retained behavior is covered, GUI code is smaller,
the packaged cutover contains no retired production path, all deletion inventory
rows are resolved, and native acceptance is recorded honestly. Close the follow-up only when required
host checks pass or the user explicitly accepts a documented outstanding limit.
Acceptance of an unperformed host check does not waive code-deletion, safety or
package requirements. Never label a result fully verified E2E when native checks
remain outstanding.

## Completion checklist

- No development or recovery interface, alternative recovery action, workspace
  navigation, fixed-height workspace stack or persistent diagnostic report.
- All essential musical controls accessible in the prescribed order.
- Program/Grid and sequential entry preserve existing source semantics and guards.
- Automatic saving, history, destination safety and generation behavior intact.
- Deleted controls have no leftover presentation state, formatter or update path.
- One GUI implementation; no legacy path, alias, feature flag, migration adapter,
  transitional wrapper or old-layout fallback.
- Retired action APIs, exclusive dependencies, modules, assets and test-only
  production exports deleted; every retained candidate has a live consumer.
- Blocker scopes/lifetimes and supported unavailable outcomes verified; no
  impossible retry advice or implicit repair/clearing behavior.
- Final ACID archive matches the resolved deletion inventory; no obsolete files
  remain packaged. Existing saved-data and Renoise compatibility are unchanged.
- Concise feedback states outcomes without unsupported save/preservation claims.
- GUI implementation smaller; tests and current documentation match the result.
- Automated and native evidence reported separately; unperformed checks explicit.
