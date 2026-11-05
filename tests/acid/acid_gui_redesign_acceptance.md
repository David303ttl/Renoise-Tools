# ACID GUI redesign acceptance

## Current checkout follow-up (2026-11-05)

The Task 12 acceptance below records revision
`fb747b93b47ba18e063890b25f297dca33f8ab07`. Later commits added linked
TIME/PITCH selection, slide references and primary/related cell outlines. This
follow-up records the current checkout at `ef3bdce416c6870c567d6f13af1b9404f94d3c99`
plus the native lifecycle probe update in this worktree.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 79 specs passed; Lua 5.1 |
| Native `gui-redesign` | PASS on Renoise 3.5.4 / API 6.2; `tmp/interactive-31c5d360015e4e0cabc7cb8b39332ad2/report.json` |
| Native `gui-layout` | PASS on Renoise 3.5.4 / API 6.2; `tmp/interactive-4780a43db878463eb77d9b1c2a209f42/report.json` |
| Native `gui-lifecycle` | PASS on Renoise 3.5.4 / API 6.2; `tmp/interactive-091538e5091d4d328e2e139684b89c00/report.json` |
| Package/source comparison | 32 files; all archive bytes match source; root entry points and private modules verified |

The lifecycle probe now checks the current selection-outline canvas, page
indicators and inactive-cell presentation. The final run restored the existing
Renoise installation and session.

The current archive is `dist/com.david303ttl.ACID_0.1.xrnx`, SHA-256
`5b29d790b851e33464cd5a6f0b147caa205c549d74914d565d41ad258beeab12`.
Packaged `gui.lua` SHA-256 is
`a6d1b518f3d43e7531b994214252d22d38471878b9d4cc793c75ae1b48a03b67`.
It includes the later `views/memory_cells.lua` module.

Current source contains 30 Lua files and 13,326 Lua lines; `gui.lua` has 2,394
lines and `views/memory_cells.lua` has 46. The Task 12 size table below remains
the measurement for its accepted revision, before these later editor additions.

## Task 12 verification (2026-11-04)

Base revision: `fb747b93b47ba18e063890b25f297dca33f8ab07`, plus its
verification changes. Task 12 acceptance is **COMPLETE** as of
2026-11-05. Native functional, layout and persistence checks pass; audio was
tested and accepted by the user separately from automated callback assertions.
Task 1–11 sections below preserve their checkpoint results. Any open or
unverified status in those sections was superseded by this final Task 12 run.

### Automated checks and deletion inventory

`./scripts/run_tests.ps1 -Tool ACID` passed all 77 Lua 5.1 specs after the
final unused eligibility module was removed. The four focused dependency,
identity, live-identity and output-compatibility specs also passed.

Fresh-process `tests/renoise/runner_spec.ps1` and
`tests/renoise/test_package_dev.ps1` pass. The native transport and acceptance
driver Lua regression specs pass. `git diff --check` is clean.

| Inventory | Final disposition |
| --- | --- |
| Inspector, sampler audit and Make Independent modules | Deleted; no production imports or lazy loads |
| Recovery, revalidation, identity-only eligibility and report interfaces | Deleted; retained draft restoration, ownership classification, evidence recording and write admission remain active |
| `runtime/eligibility.lua` | Deleted after reachability tracing found no production consumer |
| Validator `compatibility` and `preflight` exports | Deleted; compatibility remains private to the active classifier, destination preflight remains used by the writer; regression assertions use retained APIs |
| Workspace tabs, decoded/report views, permanent Live Edit Retry and alternative GUI paths | Absent from production constructors, update paths and runtime exports |
| Tests and native probes | Retained workflows use the production GUI/runtime |
| Historical/planning mentions | Kept in the redesign/editor/runtime playbooks and earlier acceptance receipts; these describe deletion requirements or superseded results |
| Persisted identity and source markers | Kept where required by active ownership, drafts and schema contracts |

Manifest/API/tool versions, persisted schemas, ARP and DigitaktSampleChain are
unchanged.

| Size | Task 1 baseline | Current |
| --- | ---: | ---: |
| `gui.lua` | 2,276 lines | 2,271 lines |
| Runtime Lua files | 33 | 29 |
| Runtime Lua lines | 14,849 | 13,026 |
| Release archive entries | 35 | 31 |

No presentation helper was extracted. Production reachability starts at
`main.lua` and `gui.lua`; the remaining private modules have live consumers.

### Release package

`./scripts/package.ps1 -Tool ACID` rebuilt
`dist/com.david303ttl.ACID_0.1.xrnx`. SHA-256:
`ff37b964288384bff410fe4fbd24f3dceab3f657720d9891e34db33dbacf32da`.
All 31 entries match source bytes; entry points are at archive root, module
directories are preserved, and SDK, tests, Markdown, development drivers and
retired modules are excluded.

Packaged `gui.lua` SHA-256:
`eafb522e2578d22890b4f51636ce2be70ff69306265f209f2b2175363eb3ff72`.

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
renoise/target_capabilities.lua
runtime/audition.lua
runtime/context.lua
runtime/draft_cache.lua
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

### Native acceptance

Runs use Renoise 3.5.4 / API 6.2 and runner-owned disposable processes. The
existing user-owned Renoise process is not the test target. Injected failures
and simulated prompt responses are identified separately from native control,
phrase and storage observations.

The production layout probe replaces the synthetic planned-layout prototype;
the retired `layout-sizing` case is rejected. `gui-redesign` exercises retained
functional callbacks, while `gui-layout` measures six idle-separated production
states and verifies holder dimensions, document neutrality and observer cleanup.

The native run exposed a screen-fit defect: expanding Grid placed the bottom
at y=1,149 on a work area ending at y=1,080. The dialog now opens with space
reserved from the largest real child dimensions and the seven-slot feedback
limit, then immediately restores its current size. Root spacing reuses
`SECTION_SPACING`. No source, history or output state is changed by reservation.

At 96 DPI (100% scaling), the 1,920 × 1,080 screen has usable work area
x=0..1,920, y=40..1,080. The reserved opening window is 846 × 999 at
x=537, y=60, bottom y=1,059. All measured states fit; the top remains at y=60.
PrintWindow captures were inspected for Program, Grid, staging, random controls
and three simultaneous feedback messages. Controls and feedback are visible;
collapsed rows do not retain the reserved opening area.

| Production state | Content size | Outer window |
| --- | ---: | ---: |
| Program compact | 844 × 670 | 846 × 696 |
| Grid compact | 844 × 775 | 846 × 801 |
| Program, random parameters and three feedback messages | 844 × 749 | 846 × 775 |
| Program, staged entry plus parameters and feedback | 844 × 771 | 846 × 797 |
| Grid, staged entry plus parameters and feedback | 844 × 893 | 846 × 919 |
| Program after cancellation and parameter collapse, retaining feedback | 844 × 710 | 846 × 736 |

Final layout receipt: `tmp/interactive-5bec0603a43941f99cf0de98b284360f/report.json`.
The visual capture run precedes the permanent width anchor; the final native
measurements confirm the same opening and expanded dimensions.
OS bounds: `tmp/gui-final-window-samples.json`; inspected captures include
`tmp/gui-final-window-08.png` and `tmp/gui-final-window-12.png`. These establish
screen fit at the recorded scaling, not audible playback or other DPI settings.

The user confirmed audio was working and tested on 2026-11-04 and accepted that
check without further loopback capture. This is user-observed audio acceptance;
the driver does not claim acoustic measurements. Display acceptance covers the
recorded normal 100% scaling required by the native matrix.

The native `gui-redesign` journey passes, including staging and stale-entry
guards, clipboard scopes and history, every operation in both scopes, inactive
memory preservation, masks and scale application, labels, Duplicate, Reset,
accepted/staged audition source selection and Live Edit controls. The driver
yields between bounded operation groups to permit native idle processing.
Preference-document initialization runs on the normal callback before the
test coroutine. Receipt:
`tmp/interactive-b8f015014a7b49cdacf974b22dace7ed/report.json`.
The overall run and installation restoration both pass. Simulated prompt
responses exercise production callbacks; audio acceptance remains the separate
user observation above.

The clean dialog previously shrank from width 844 to 797 after instrument
selection, then widened when optional rows appeared. The existing title and
staging status now reserve the shared content width. All 593 native callback
measurements remain at width 844, including feedback, entry, operation and
view changes. Vertical holder collapse remains unchanged.

Both editor panels also reserve the same `CONTENT_WIDTH`. The final layout
run measures both panels at 820 in every state and confirms constant root
width through Program → Grid → Program. A final Program window capture in
`tmp/gui-shared-width-window-samples.json` measures outer width 846.

Protected native cases also pass on the final checkout:
`integrity-observers` in
`tmp/interactive-482d7500c04540f9a499e13a793ee72c/report.json`, and
`writer-recovery` in
`tmp/interactive-f37e842f4ada432ea93af718f74efb47/report.json`.
Both overall runs and installation restoration pass. These use controlled
failure injection against real native objects; they do not claim naturally
occurring host faults or audible playback measurements.

The final `gui-lifecycle` run passes all 12 checks in
`tmp/interactive-528bd3f0d29143d5925d4b451222ce00/report.json`, including
installation restoration. It verifies unequal 1/16/17/32 boundaries, independent
pages and highlights, inactive memory, native instrument changes, exact phrase
binding after reorder, and rejection of Finish after target deletion. It saves
a real XRNS with ungenerated edits, releases and reloads that document, verifies
GUI/notifier teardown and automatic draft restoration, then generates from the
restored source. Import uses temporary valid/invalid files through the production
parser and preferences; only the file chooser response is supplied by the probe.

| Required journey | Evidence |
| --- | --- |
| Normal-scale Program/Grid fit, expanded rows, readable feedback, stable width | `gui-layout`, inspected window captures, 593 `gui-redesign` width samples |
| Unequal boundaries, pages, highlights, inactive memory and pitch/time entry | `gui-lifecycle` and `gui-redesign` |
| Clipboard scopes, history, every operation/scope, seeded repeat, labels, Duplicate and Reset | `gui-redesign` |
| Scale browsing, root/category/search, Follow, masks and import | `gui-redesign` and `gui-lifecycle` |
| New/existing Generate, Live Edit arm/edit/failure and explicit retry | `gui-redesign` |
| Native target changes/deletion/reorder, dialog/song lifetime and XRNS restoration | `gui-lifecycle`, `gui-layout` and `gui-redesign` |
| Unavailable targets and persistent blockers | `integrity-observers`, `writer-recovery` and stale-target rejection |
| Audition | Native accepted/staged-source callbacks; user-tested audio acceptance |

There are no outstanding required checks. Detailed manual steps remain in
[acid_editor_presentation_manual.md](acid_editor_presentation_manual.md).

## Task 1 status

Baseline, API constraints, control ownership and production reachability are
recorded below. The disposable native sizing gate passed at 100% display
scaling, including holder membership, Program/Grid sizing and open-dialog
resizing. Final screen-fit acceptance remains required in Task 12.
Paths under `gui.lua`, `runtime/`, `renoise/` and `writers/` refer to
`com.david303ttl.ACID.xrnx/`; test and manual paths refer to `tests/acid/`.

## Task 2 feedback contract

One GUI-local owner renders save, destination, scale, audition, input,
generation and approximation issues in that order. Confirmations appear only
without unresolved issues. Empty feedback has no attached child; populated
feedback attaches the status view with ViewBuilder `add_view()` and removes it
with `remove_view()` when empty. Message height follows the number of lines.
Sizes use named constants. Routine successful Live Edit updates do not publish
confirmations; new edits clear obsolete confirmations while unresolved failures
and useful approximation warnings remain visible.
Successful source Undo/Redo also clears obsolete confirmations without clearing
unresolved failures or approximation warnings.

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
`acid_program_staging_spec.lua`. Diagnostic/recovery controls and their
exclusive action dependencies are removed.

## Historical Task 2 verification

These receipts describe the earlier implementation based on
`e6e9af4a26f855016a0b3588b34b1176a897cf93`, before the corrections and deletions
below. Their hashes and counts do not identify the current package.

| Check | Result |
| --- | --- |
| `./scripts/setup_sdk.ps1` | Pinned API 6.2 SDK verified; view sizing definitions and offline docs inspected |
| `./scripts/run_tests.ps1 -Tool ACID` | 79 specs passed, 0 failed; Lua 5.1; 66.20 s |
| `git diff --check` | Passed |
| Native `editor-responsiveness` | PASS; Renoise 3.5.4 / API 6.2; 35 GUI actions, shared feedback ownership/order, 1-pixel empty holder and 48-pixel two-issue view; source metadata, phrase inventory, native selection and original tool installation restored |
| Historical native report | `tmp/interactive-1bf129d27860488d8fa4e996f0769033/report.json` |
| Historical native command | `./scripts/run_interactive_tests.ps1 -Tool ACID -Suite Native -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -RenoiseExe <renoise-executable>` |
| `./scripts/package.ps1 -Tool ACID` | 35 runtime files; archive inventory and every file's bytes match source; entry points at root; no SDK, Markdown, tests or development driver |
| Archive | `dist/com.david303ttl.ACID_0.1.xrnx`; SHA-256 `c00ef8be060120f894c30350e0b9383344cfd9010ce366bd1b4840ce563b2775` |

Native feedback failures use injected Duplicate rejection and an empty clipboard.
Save/load, stale completion, uncertain scale storage and failed audition cleanup
remain injected Lua fixtures. Audible output, timer duration, native metadata
Undo and visual screen-fit/scaling checks are unverified; this is functional
acceptance, not full visual/audio acceptance.

## Feedback follow-up before report removal

| Check | Result |
| --- | --- |
| `./scripts/run_interactive_tests.ps1 -Tool ACID -Suite Native -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -RenoiseExe <renoise-executable>` | PASS on Renoise 3.5.4 / API 6.2; 35 GUI actions; feedback failures retained and holder emptied; disposable phrase inventory, metadata and native selection restored |
| Feedback native report | `tmp/interactive-cd9d82aa224c4a33acc47d552f895f2f/report.json` |
| `layout-sizing` | PASS on the disposable full-interface prototype after the maximum-first open sequence; exact empty/full cycles passed for both editors and dynamic holders |
| Sizing report | `tmp/interactive-323105d1a1324a08a52b86e54cef93c4/report.json` |
| OS window capture | `tmp/layout-window-samples.json`; stable screenshots are `tmp/layout-window-02.png` through `tmp/layout-window-04.png` |

## Native sizing probe

The test-only prototype represents the planned full editor at maximum musical
length 32, with all 16 PITCH/TIME positions, the full 12-key range and C+, full
scale mask, maximum Randomize parameter rows, active entry controls and the
maximum eight-line feedback holder. The native API reported these content sizes:

| State | Root | Editor | Feedback | Entry | Operation parameters |
| --- | ---: | ---: | ---: | ---: | ---: |
| Program empty | 741 × 562 | 589 × 267 | 1 × 1, no child | 1 × 1, no child | 1 × 1, no children |
| Program maximum | 741 × 837 | 589 × 267 | 640 × 176, one child | 474 × 24, one child | 444 × 78, three rows |
| Grid empty | 741 × 478 | 589 × 183 | 1 × 1, no child | 1 × 1, no child | 1 × 1, no children |
| Grid maximum | 741 × 753 | 589 × 183 | 640 × 176, one child | 474 × 24, one child | 444 × 78, three rows |

The first experiment opened the dialog empty and then expanded it. Renoise kept
the original top at y=266, placing maximum Program content below the usable
work area. The accepted prototype opens at maximum Program size, then removes
inactive entry/parameter/feedback views and resets their empty holder sizes to
1 × 1 before the first idle update. Later empty/full and Program/Grid changes
shrink and expand the same open dialog without changing its top position. Exact
root dimensions returned after each cycle.

The host was Renoise 3.5.4 / API 6.2 at 96 DPI (100% scaling), on a 1920 × 1080
screen with usable work area x=0..1920, y=40..1080. The maximum Program dialog
measured 743 × 863 at x=588, y=128, bottom y=991, leaving 89 pixels of usable
height. Empty Program measured 743 × 588, empty Grid 743 × 504, and maximum Grid
743 × 779. The window stayed at y=128 while content expanded and collapsed; all
measured states fit the work area. The full prototype was visually inspected at
this scale. This is a 100% scaling prototype result, not final production GUI
acceptance; Task 12 must check the completed production layout on the host.

The native case command is:

```powershell
./scripts/run_interactive_tests.ps1 -Tool ACID -Suite Native -Install -ApproveDisposableSong -AcceptanceCase layout-sizing -RenoiseExe <renoise-executable>
```

## Task 3 implementation disposition

The GUI has no Details, source/preview/live-state report, decoded view,
inspector, Sampler Audit, Check or recovery actions. Only the shared renderer
writes feedback text. Workspace navigation and Live Edit Retry
remain for their later scheduled tasks; this is not the completed redesign.

| Removed dependency | Disposition and retained responsibility |
| --- | --- |
| Inspector and sampler audit | Constructors, callbacks, imports, mocks and both `renoise/selection_context.lua` and `renoise/sampler_audit.lua` deleted |
| Make Independent | Context eligibility/projection/action, identity-only mutation authorization, eligibility helpers, transition and `runtime/independence.lua` deleted; ownership/collision checks and musical Duplicate remain |
| Detached-draft actions | Context list/copy/discard wrappers, draft-cache list/copy/discard and private copy-origin metadata deleted; automatic saving/restoration, capture, detached session records, volatile warnings and revision-specific commit cleanup remain |
| Invalid-editor recovery accessor | Public accessor and accessor-only coverage deleted; private invalid-buffer records retain document-release loss detection |
| Revalidate | Context status/action, integrity proof/clear, committed-capture and ownership recovery-comparison helpers, and writer blocker-clear API deleted; evidence producers, mutation/metadata capture, write rejection and same-song evidence suspension/resumption remain |
| Recovery snapshot registry | Unread private snapshot retention deleted; complete phrase-read validation still rejects unreadable mutation preconditions |
| Report support | Exclusive formatters, report-only refresh functions/state, decoded pagination and recovery workspace removed; projection validation, error-position navigation, history, staged entry, audition cleanup and observer lifetimes remain |
| Obsolete test/native workflows | Action-only GUI/runtime independence specs and native recovery-action cases removed; retained coverage uses live editor/runtime workflows. Current owners include `acid_gui_live_edit_lifecycle_spec.lua` and `acid_draft_baseline_spec.lua` |

The dependency-graph spec asserts that all three retired module files and the
retired draft, eligibility, integrity and writer methods are absent. The
context surface allowlist and GUI constructor checks reject retained facades or
hidden controls. The release archive excludes all three modules. Retained
`context:restore_editor_target()` uses draft restoration, requests use draft
capture/currentness guards, and committed delivery uses revision-specific
compare-and-clear. `context:record_blocker()` and mutation scopes retain
integrity evidence; context/request admission reads its blocking state.

### Supported unavailable outcomes

| State | Lifetime and supported behavior |
| --- | --- |
| Foreign/colliding/deleted/modified destination | Remains non-owned and cannot reach the writer. Explicit valid target or New selection is allowed only through normal admission and cannot bypass a song blocker |
| Recorded mutation, metadata or writer-integrity evidence | Remains blocked across target changes, dialog reopen and same-song reattachment; Generate, Live Edit and Duplicate reject without capture/dispatch or source/phrase changes. No ACID repair action remains |
| Writer-only integrity rejection | Synchronous structured rejection records a song blocker; subsequent requests reject without dispatch and feedback states that ACID cannot safely update the song |
| Mutation evidence recording/finalization failure | Remains blocked through same-song dialog/document lifetimes. The existing context resets its fallback on attachment of a different song; no same-song reopen or retry remedy is offered |
| Verified commit followed by failed adoption and failed evidence recording | Dialog reopen remains blocked. Same-song document reattachment uses fresh full membership, identity, stored-source/settings and native-output classification. The intact committed target can pass subsequent explicit admission; a corrupted postimage remains unavailable and never reaches the writer. This is not a general blocker-clear or user repair procedure |
| Observer failure or dispatch uncertainty | Existing successful observer reattachment and verified writer-occupancy admission remain the only applicable clearing evidence; no removed repair action is invoked |
| Unsaved/unreadable drafts | Ordinary save/load feedback remains separate from output results. Removal does not discard drafts, adopt foreign music, automatically select New or claim unsaved edits were saved |

These failure lifetimes are covered by deterministic injected fixtures. They do
not establish disk-failure, acoustic or exhaustive native fault acceptance.
Persisted schemas, manifests, musical algorithms and active writer transaction
behavior are unchanged.

### Verification

Native and harness receipts below were not rerun. Native writer-blocker and
Undo/Redo feedback checks remain unverified for the current source changes.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 passed; Lua 5.1; 66.26 s |
| Focused regressions | Real writer-only blocker persists across Generate, Live Edit, Duplicate, target changes, dialog reopen and same-song reattachment without phrase/store mutation. Undo/Redo clears confirmations and retains unresolved issues. Both regressions fail against the unfixed runtime/GUI |
| Second-pass review | Independent runtime and GUI review completed; retired accessor and snapshot registry absent; complete phrase-read rejection and invalid-buffer release warning retained |
| `./tests/renoise/runner_spec.ps1` | Passed transport, ownership, keyboard configuration, reporting and installation lifecycle checks |
| `./tests/renoise/test_package_dev.ps1` | Passed payload, fixture, session ACL, syntax, bootstrap, Unicode path and packaging checks |
| `./scripts/package.ps1 -Tool ACID` | 32 runtime files; all archive bytes match source; `main.lua` and `manifest.xml` at root; no retired modules, SDK or development files |
| Archive | `dist/com.david303ttl.ACID_0.1.xrnx`; SHA-256 `fc665f8eda0c8ca90ae005ecff60030e215237126eb2a7938584ffa09c654186` |
| GUI SHA-256 | `b4fff3481e5b00fd0e34a9efdef6a923d3d00ce539494c8731f1281804052d52` |
| Source inventory | `gui.lua`: 2,267 lines; 30 Lua runtime files, 13,637 lines. Baseline: 2,276 GUI lines and 33 Lua files, 14,849 lines; no presentation helper extraction |
| Native `editor-responsiveness` | PASS; 32 retained GUI actions, source/draft/phrase checks, Live Edit and feedback ownership, audition functional checks; report `tmp/interactive-c6ecb42d77244b569e1b7a1d1af153ec/report.json` |
| Native `integrity-observers` | PASS; blocker survives dialog reopen and target change, Generate/Duplicate reject, committed phrase/store preserved; report `tmp/interactive-d197a6eaaead46768bf6d82443650db4/report.json` |
| Native `writer-recovery` | Recorded PASS at `66885a7`; blocked dirty-editor rebind remains unavailable, Generate/Duplicate reject, exact native snapshot/tool bytes/inventory and both immutable source rows preserved; report `tmp/interactive-aa44479fad094a909acb998e4b13fe15/report.json` |
| Final harness checks | Focused acceptance driver regression spec and `git diff --check` passed after obsolete test-only helper removal and diagnostic formatting cleanup |
| Host cleanup | Runner-owned Renoise closed; original 36-file installed ACID tool restored and verified |

Editor/integrity native checks preceded deletion of unreachable proof-comparison
helpers; the final writer check and complete Lua suite include that deletion.
These are functional receipts, not acoustic or latency acceptance. Final
production-layout fit and other display scaling settings remain Task 12 checks.

## Task 4 header and sequence settings

Instrument precedes Phrase with Rename and Duplicate. One adjacent Name display
shows the accepted name, including ungenerated label edits. Length, Timing,
Reset pattern and Pitch span appear above the editor. Timing choices include
their divisions; the separate division/cycle display is removed.

The existing target, rename, duplicate and reset owners retain admission,
pending-entry guards, save/retry handling and history. GUI fixtures check row
membership/order, unequal TIME length and PITCH span, preservation of all stored
pitch events and inactive TIME entries, unresolved rename action guards, failed
Save/Retry and label-only Undo without source saving or generation.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1; 61.36 s |
| Second-pass review | Independent contract review and final callback/test diff review completed; redundant guards removed, row order and rename failure cases covered; no remaining `step_division` reference |
| `git diff --check` | Passed |

Native header fit, selection synchronization and rename/reset interaction checks
in `acid_editor_presentation_manual.md` remain unverified for this change.
Runtime file layout and package inputs are unchanged; no package rebuild is
required.

## Task 5 toolbar and history

Program/Grid, Undo, Redo, clipboard scope, Copy and Paste share one toolbar.
Clipboard contents/status rendering and the Pattern / Copy panel and tab are
removed. The payload and PITCH/TIME/Both scopes remain session state. Paste
requires a matching payload, musical eligibility and no pending entry or rename;
its callback retains independent guards, candidate validation and no-op handling.
Accepted paste uses the existing history/save/Live Edit path. History retains
proposal/commit and label-only persistence; successful history moves stay quiet
while save failures remain visible.

| Check | Result |
| --- | --- |
| `./scripts/setup_sdk.ps1` | Pinned API 6.2 SDK confirmed; view membership and stack definitions/docs inspected |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1; 72.47 s |
| `lua tests/acid/acid_gui_views_spec.lua` | Final pending-generation eligibility and removed-panel assertions passed |
| Second-pass review | Independent callback/history review, request and label-dialog availability checks, strict boolean state and obsolete-reference audit completed |
| `git diff --check` | Passed |

Native toolbar fit and clipboard/history checks in
`acid_editor_presentation_manual.md` remain unverified. Runtime file layout and
package inputs are unchanged; no package rebuild is required.

## Task 6 Program and Grid

Program and Grid retain independent PITCH/TIME selections and pages. Selected
position summaries, repeated editor headings and source-interpretation tooltips
are removed with their presentation-only baseline state. Musical pitch tooltips,
resolved-pitch audition, referenced-position highlighting and projection caches
remain. Each editor owns its audition button; both use one callback and share
eligibility. One shared Note/Tie/Rest row follows the active editor's TIME positions.

Native Program/Grid probes use retained selection controls and source values
instead of removed readouts. Current user documentation and the presentation
manual describe the retained controls.

GUI fixtures cover unequal PITCH/TIME lengths with P17 edited while TIME01
remains selected, navigation without saves/writes/history, inactive positions,
C+, canonical Grid display during Program entry, masked audition from both
views, shared audition eligibility and release-failure feedback.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1; 99.65 s |
| Second-pass review | Source, selection, parenting, audition lifecycle and native probes reviewed; fixtures assert exact accepted/candidate notes and reject missing color observations; existing length constants reused |
| `git diff --check` | Passed |

Native presentation, playback and lifecycle checks remain unverified for this
change. Runtime file layout and package inputs are unchanged; no package rebuild
is required.

## Task 7 sequential entry

Program exposes Enter pitches and Enter timing during normal editing. Entry
shows cursor progress with Back, Enter and advance, Restart, Finish and Cancel
outside the editor panels. Grid retains accepted-source viewing; returning to
Program restores the entry cursor. Restart preserves entered positions and
Cancel retains confirmation without committing pending edits.

Finish remains disabled until every position is entered. A guarded action
identifies the first missing numeric position and reveals it in Program without
marking it entered. Grid stays selected and directs completion in Program.
Finish retains destination, song, revision, eligibility and source validation;
resolving entry does not resume the requested action automatically.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1; 59.23 s |
| Focused entry fixtures | Missing position 5, cross-page PITCH navigation, TIME selection, cursor progress, Restart markers, Cancel isolation and Grid Finish/Cancel passed |
| Second-pass review | Independent safety, callback, parenting and helper-order review completed; obsolete prompt references removed from current specs and native probes |
| `git diff --check` | Passed |

Native entry, layout and lifecycle checks in
`acid_editor_presentation_manual.md` remain unverified for this change.
Runtime file layout and package inputs are unchanged; no package rebuild is
required.

## Task 8 Scale and Operations

SCALE and OPERATIONS follow the editor without workspace navigation. SCALE
contains Root/Scale/Follow, Category/Search/Import and the mask controls.
The scale detail report, seed report and permanent instructions are removed.
Aliases/categories remain in the scale selector tooltip; import errors retain
shared feedback and uncertain-save import blocking.

Only the selected random operation's parameter row is attached. Nonrandom
operations detach parameter content; empty holders reset to 1 × 1. Repeat last
retains independent remembered PITCH/TIME seeds and uses current parameters,
mask and scope without changing editable seeds. All ten operations retain
`sequencer.operation_candidate()` and existing admission/no-op behavior.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1; 61.59 s |
| Focused GUI fixtures | Both scopes for all ten operations, selected parameter membership, remembered versus editable seeds, scale browsing and import feedback passed |
| Second-pass review | Callback scope, panel ownership, native view identity, empty-holder sizing, scale failures and executable probe references checked |
| Lua 5.1 compilation and `git diff --check` | Passed |

Native Scale/Operations layout, import and musical checks in
`acid_editor_presentation_manual.md` and `acid_regeneration_manual.md` remain
unverified for this change. Runtime file layout and package inputs are unchanged;
no package rebuild is required.

## Task 9 Output and generation

OUTPUT contains Mode, Bend range, Live Edit and one Generate action. Receiver
range matching, channel-wide bend, isolated monophonic routing and Off guidance
are in the bend-range tooltip. Permanent Live Edit Retry is removed. Generate
retains manual admission, entry resolution, current-song and exact-target checks,
and projection validation. Arming Live Edit does not write.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1 |
| Failed Live Edit then Generate | Manual request admitted through the retained owner; unresolved save feedback preserved |
| Destination and lifecycle fixtures | New binding, stale targets, foreign targets and persistent blockers remain protected |

Native output, receiver and Live Edit checks remain unverified for this change.

## Task 10 Content-sized layout

The root contains the header, sequence settings, toolbar, selected editor,
TIME assignment, entry, SCALE, OPERATIONS, OUTPUT and shared feedback.
Workspace navigation, panel arrays, fixed origins and the fixed-height stack
are removed. Editor and entry membership changes reuse existing widgets;
inactive entry, parameter and feedback holders use the named empty sizes.
All menu and keybinding callbacks in `main.lua` reach the same `gui.show()`.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1 |
| Construction and membership | Program/Grid, active entry, random parameters and feedback fixtures passed; repeated editor cycles preserve widget, child and notifier counts |
| Independent second-pass review | Generation guards, root order, single parenting, holder reset behavior, callbacks and native probe consumers checked; no unresolved defects |
| Lua 5.1 syntax and `git diff --check` | Passed |
| Removed references | No workspace state, tab constructors, fixed stack, retired report refreshers or Live Edit Retry in GUI; executable native probes use current controls |

At the Task 10 checkpoint, native screen fit, scaling, expanded-row resizing and
playback checks remained unverified. Task 12 completed those checks. Runtime
file layout was unchanged, and `gui.lua` was 13 lines smaller than before Tasks
9–10.

## Task 11 Regression coverage

| Behavior | Current evidence |
| --- | --- |
| Editors, toolbar, entry, scales and operations | `acid_gui_views_spec.lua` covers independent selection/pages, inactive positions, membership cycles, all ten operations in both scopes, parameter visibility, seeded Repeat last and no generation from operations |
| Removed construction | Registered IDs and constructor records reject diagnostic, decoded, inspection, recovery, workspace, Pattern / Copy and permanent retry controls, including anonymous and hidden buttons; lazy Rename retains only its supported Retry |
| Failure feedback and admission | GUI views/admission/staging fixtures inject generation, draft save, custom-scale load/import/save, Rename save, audition cleanup and destination failures; source, history, saves, requests and identity assertions accompany feedback checks |
| Stale results and lifecycle | GUI admission, timing-race, Live Edit lifecycle and audition fixtures preserve stale-result rejection, cleanup and exact destinations; timing/lifecycle specs use the real editor model without unused diagnostic injection |
| Retained runtime | Dependency-graph and runtime-integrity specs assert retired modules/methods are absent; integrity fixtures preserve blocker outcomes across targets, dialog reopen and document lifetimes |
| Startup | `acid_identity_spec.lua` loads real `main.lua`/GUI/runtime dependencies without retired-module stubs and checks both menu callbacks and the keybinding reach the same GUI |
| History and musical semantics | Editor, clipboard, duplicate-label, sequencer, scale, draft, store and writer specs retain deterministic source, no-op, persistence and transaction assertions |
| Native procedures | `acid_editor_presentation_manual.md` follows the final acceptance journey; README and DESIGN describe the current interface. Historical receipts remain unchanged |

All five retained GUI builders support membership removal and reject duplicate
parenting. Removed views retain ID lookup in mocks. Executable native probes
have no retired action dependencies; active ownership snapshot/capture helpers
remain used by integrity and writer paths. Native layout, sizing and audio
correctness remain outside mocked coverage.

At the Task 11 checkpoint, only tests and documentation had changed, so no
package rebuild was required then. Task 12 subsequently rebuilt and verified
the release archive; final native acceptance is recorded above.

| Check | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | 77/77 specs passed; Lua 5.1; 63.91 s |
| `git diff --check` | Passed |
| Second-pass verification | Builder membership, constructor records, startup dependencies, failure fixtures, runtime absence and current documentation reviewed |
| Native checks | Not performed; final production layout, playback and host acceptance remain unverified |

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
| Entry actions `acid_program_back`, `acid_program_enter`, `acid_program_restart`, `acid_program_finish`, `acid_program_discard`, `acid_program_reenter_pitch`, `acid_program_reenter_time` | `stage_navigation`, `finish_stage`, `begin_stage`, `refresh_stage` in `gui.lua` | Retain. `acid_program_discard` remains the Cancel ID. Redundant `acid_program_edit_one` is deleted; `acid_program_check` is removed with diagnostics. |
| Audition `acid_audition`, Live Edit `acid_live_edit`, and Generate / Regenerate (anonymous button) (`gui.lua:1422-1438`, `1742-1758`, `2170-2188`) | Shared audition release and lifecycle hooks (`gui.lua:94-170`, `2198-2268`); generation admission through runtime; result feedback in `acid_status` | Retain audition, Live Edit and Generate. Remove permanent anonymous `Retry Live Edit` in Task 9. `acid_audition_status` is a separate cleanup report slated to merge into shared feedback. Tests: audition lifecycle, GUI admission/views, runtime request/writer integration; Live Edit manual |
| Rename, Duplicate, Reset, Undo/Redo; `acid_label_*`, `acid_pattern_duplicate`, `acid_pattern_reset` (`gui.lua:1444-1542`, `1815-1827`, `2148-2155`) | Rename attempt/save lifecycle, duplicate admission and editor history | Retain. Rename dialog Save/Retry/Discard Attempt resolves label edits and stays; it is not recovery UI. `acid_editor_spec.lua` |
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

## Baseline runtime deletion inventory

The following dependency map records the pre-deletion implementation. Current
dispositions and supported blocker outcomes are recorded above.

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

## Baseline blocker producers and lifetimes

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
| Observer, mutation, adoption and writer blocker fixtures | `acid_runtime_observers_spec.lua`, `acid_runtime_integrity_spec.lua`, `acid_runtime_writer_integration_spec.lua` |

The current presentation and Live Edit manuals use retained workflows.
Workspace navigation remains until its later layout task; destination,
regeneration and lifecycle guides remain protected behavior references.
