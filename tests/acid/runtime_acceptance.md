# Runtime integration acceptance map

## Gate 7 integration closeout (2026-10-31)

| Check | Evidence | Result |
| --- | --- | --- |
| Notifier removal | `acid_script_runner_spec.lua`, `acid_writer_safety_spec.lua`: only an exact `false` probe retires callback references; invalid or unavailable probes retain cleanup. | PASS |
| Writer admission | One pending cleanup job blocks subsequent writes until removal is verified; persistent failure cannot accumulate writer listeners. | PASS |
| Mandatory subscriptions | Idle, render-commit and clear-commit attachment require an exact `true` probe; failed attachment settles once without publishing. Registration reentry cannot substitute for commitment. | PASS |
| Diagnostic ownership | Captured retired callbacks preserve a newer job's diagnostic and terminal result. | PASS |
| Independent review | Writer/runner lifecycle, attachment reentry, admission and diagnostic ownership. | PASS |
| Architecture | Existing writer/runner owners; no new module, scheduler, persisted format or manifest version. | PASS |
| Native writer recovery | Renoise 3.5.4 / API 6.2: `tmp/interactive-80d34dedc91e4d9994c6d67a328c3c13/report.json`. | PASS |
| Native integrity observers | Renoise 3.5.4 / API 6.2: `tmp/interactive-018f100b82ed4d5ab090d02547a9ac41/report.json`. | PASS |
| Lua 5.1 suites | ACID 65/65 (`tmp/acid-notifier-final-tests.log`); repository 68/68 (`tmp/repository-notifier-final-tests.log`). | PASS |
| Release package | 34 source-identical entries; root manifest/main/license, private directories preserved, development inputs excluded. | PASS |

**Gate 7 CLOSED; Gate 8 remains OPEN.**

Notifier failure injection uses mocks; native runs do not force host add/remove
failures. Playback, broader musical-writer undo grouping, actual field
preservation and full Step 8 A–E acceptance remain OPEN.

## Gate 8 acceptance plan (2026-10-31)

Gate 8 remains OPEN. The native diagnostic below reproduces a phrase-selection
jump; its correction remains unresolved. Removal of an existing last phrase
would also block acceptance but was not observed in this run. API 6.2 was checked directly in both
`sdk/renoise-api-6.2/definitions/library/renoise/song.lua` and
`sdk/renoise-api-6.2/docs/API/renoise/renoise.Song.html`: `selected_phrase_index`
is explicitly READ-ONLY, as is `selected_phrase`. There is no selected-phrase
index observable. Do not document or test assignment as a supported restoration
mechanism. Selection stability must be assessed from independently read native
state while respecting actual user navigation.

The required sequence is T8.0 reproduce/classify, T8.1 correct ownership and
temporary lifecycle, T8.2 single-target regression, T8.3 bounded multi-instrument
session, T8.4 recovery/persistence, and T8.5 gate closure. A–E and cold
reopen/regenerate remain required within that sequence. The T8.3 fixture is
bounded to four concurrently playing tracks, three instruments (sampler, VST,
and another supported instrument), and at least 12 owned and foreign phrases.
Its workflow switches A / phrase 2 to B / phrase 4 during rendering, returns to
A, exercises C and explicit New, edits with Live Edit during playback, performs
manual Generate, then saves, fully restarts Renoise, reloads and regenerates.
The production writer remains serialized; exact object identity, native
selection, phrase count/order, playback and persisted source/settings are the
acceptance oracle.

| Substep | Evidence / boundary | Status |
| --- | --- | --- |
| T8.0 | Native diagnostic `tmp/interactive-be7913f6df0a4f44862856e9d4a4cc87/report.json` reproduced a selection jump on the first regeneration: initial no-phrase selection index 0 → staging/backup `Phrase 05` index 5 → existing foreign phrase `Workflow foreign 1 2` index 4 after temporary deletion. The run completed six creates, then stopped on regeneration 1 of 6 (seven transactions total). It used three instruments with four phrases each (six owned, six foreign); the affected instrument settled at four phrases after cleanup. No existing-phrase deletion was observed in this run. | FAIL: selection P0 reproduced |
| T8.1 | Native proof of no unintended selection switch, no deletion of existing phrases, and cleanup limited to exact ACID-owned temporary objects. Visible staging/backup entries during rendering must be measured separately; correct settled state does not establish invisibility. The selection invariant failed in T8.0, so correction and same-case proof are blocked. | BLOCKED |
| T8.2 | First, middle and last phrase create/regenerate/Live Edit; New tested separately; exact destination identity and count/order assertions. Sequential gate: not run after T8.0 failed. | DEFERRED |
| T8.3 | Implemented native driver case `multi-instrument-workflow` in `tests/renoise/driver/acceptance_cases.lua`, invoked with `-AcceptanceCase multi-instrument-workflow`. The diagnostic run above covers three instruments, six creates, and begins six regenerations with native selection/list snapshots; it fails at the first regeneration. It does not pass the multi-instrument acceptance. Four-track concurrent playback, GUI navigation, Live Edit, save/restart workflow and full phrase-order/isolation postconditions remain untested. | DEFERRED; diagnostic FAIL |
| T8.4 | Interruptions, failures, duplicate ownership, save/reopen and undo/redo. Complete logical musical-writer undo grouping remains an explicit open obligation; safe partial undo states do not satisfy it. | DEFERRED |
| T8.5 | Remaining A–E checks, cold reopen/regenerate, local suites, package checks and independent review; close only against actual native evidence. | DEFERRED |

Supporting local checks for the related hardening changes passed: Lua 5.1
repository suite 68/68, offline checks 18/18 groups (`tmp/acid-workflow-offline.log`),
and the ACID release package with 34 runtime files. These checks do not close any
native T8 substep. The diagnostic runner restored the original Renoise
installation and force-stopped its runner-owned process after graceful closure
did not complete; the unrelated existing Renoise process was left open. It did not verify the full
12-phrase final ordering/isolation postconditions because it stopped at the
first failed selection invariant.

For the journey, assert these separately: (1) selection stays stable except for
real user navigation; (2) A edits do not change B, C, another phrase, or a
foreign holder; (3) regeneration changes the same destination object and leaves
settled count/order unchanged; (4) explicit Create adds one durable phrase and
removes none; (5) cleanup removes only verified temporaries and leaves none
after settlement; (6) any visible temporary list churn is recorded and remains
an open UX issue if unacceptable; (7) A drafts survive switching through B and
C, including superseded queued generation; (8) other tracks retain their
phrase-program selections and supported playback; and (9) fresh-process
reopen preserves phrase/source/settings/instrument associations and targets
the intended phrase on explicit regeneration. ACID's success response is not
evidence for these native facts.

## Gate 6 observer contracts (2026-10-31)

Notifier postcondition follow-up: observer and mandatory GUI lifecycle adds now
verify registration where a notifier probe is available. Detachment and partial
registration rollback retain cleanup records until removal is confirmed.
Fault-injection regressions cover ineffective add/remove, inert retained
callbacks, blocked reattachment, cleanup retry and lifecycle initialization
unwind. These are mocked API checks; the final postcondition follow-up and silent
idle-add correction now have the native rerun recorded under T7.0 above.

Follow-up verification: focused observer/GUI specs PASS; ACID 65/65 and
repository 68/68 Lua specs PASS under Lua 5.1; offline checks 18/18 groups PASS,
including development/release package validation; `git diff --check` PASS.

Baseline: `feature/hardening4` at `5cd1d7c`; the staged playbook edit is preserved.
The reviewed `7d8fb918` baseline differs by the closed-dialog completion fix.
Pinned API 6.2 definitions and offline docs confirm the following subscriptions.

| Owner | Required protection |
| --- | --- |
| `runtime.observers` / song | Instrument inventory; native instrument and phrase selection. |
| `runtime.observers` / instrument | Name, phrase/mapping inventories, phrase playback mode and program. |
| `runtime.observers` / phrase | Name, content properties, line changes, all twelve column names/mutes; mapping and script properties when those objects exist. |
| `gui` | Release, new document, unload; existing dialog idle reconciliation and visibility cleanup. |
| `runtime.context` | Prompt invalidation, exact mutation membership, target/revision authority, draft retention and reconciliation. |
| `writers.phrase_writer` | Scoped insert/copy/name/cleanup, render occupancy and terminal settlement. |

Mapping absence is valid; its property listeners are mandatory when present.
Observable lists do not replace per-object property listeners. API delivery order
and undo atomicity are unspecified; uncertain external changes invalidate.
Callbacks never render, re-key, select native objects or adopt copied ownership.

Baseline: all 68 existing specs passed, including the original observer spec;
the new attachment-failure regression reproduced the missing protection.

| Subgate | Regression evidence | Result |
| --- | --- | --- |
| T6.1 | `acid_runtime_observers_spec.lua`: required API/getter/add failures, partial attachment, observable/line add-then-throw, removal/probe/readiness reentry, inert delayed callbacks and safe same/cross-song cleanup retries. `acid_runtime_context_spec.lua`: observer failures block musical/identity admission and Revalidate until full attachment succeeds. | PASS. |
| T6.2 | `acid_runtime_mutation_spec.lua`: nesting, neutrality and recovery. `acid_runtime_writer_integration_spec.lua`: actual stage/backup insert, destination copy/name/line and cleanup callbacks; exact delayed inventory proof; external membership rejection and exact destination preservation. | Focused PASS. |
| T6.3 | `acid_runtime_observers_spec.lua`, `acid_runtime_context_spec.lua`, writer integration and GUI views/admission/timing specs: prompt external invalidation, A→B→A, scoped/temporary exemptions, New preservation and deferred GUI reconciliation. | PASS. |
| T6.4 | `acid_runtime_inventory_spec.lua`: undo restores old phrase/seal with newer committed source; association remains unavailable, detached draft remains recoverable and Revalidate performs no repair. | PASS. |
| T6.5 | GUI views and runtime lifetime specs: required lifecycle registration/unwind, ineffective silent idle add, idle add-before/after-registration failures, remove-then-throw, stale idle delivery after release/reopen and unload cleanup retries. Observer specs distinguish destroyed phrase/mapping sources from live/uncertain removal failures using explicit live-song membership and notifier probes. | PASS. |
| T6.6 | Production GUI/runtime native matrix: visible column 1 and hidden column 12, names and mutes, idle and busy; four synchronous writer cancellations, preserved external snapshots/store, four idle and four busy reconciliations, fresh commit, close/reopen, saved fixture/new song/reload and zero detached native/idle listeners. | PASS: final rerun `interactive-9f85a96f54cc4e97999c5beaf599664e/report.json`, Renoise 3.5.4 / API 6.2. |

Native busy-state evidence establishes accepted writer work, not a particular
native render phase. Musical playback and broader Step 8 acceptance remain open.

Gate 6 CLOSED: required observer, reconciliation, lifecycle and targeted native
assertions pass. Persistence formats and manifest versions are unchanged.

| Verification | Result |
| --- | --- |
| ACID / repository suites | 65/65 and 68/68 PASS, Lua 5.1. Final repository rerun: 68/68 PASS. |
| Offline checks | 18/18 groups PASS; runner and development-package checks rerun after transport changes. |
| Release package | PASS: 34 runtime files, root entry points, private modules, no SDK/tests/docs. |
| Independent second pass | Observer/context, lifecycle, native assertions, dependency/callback inventory and destroyed-source lifetime reviews; findings resolved, focused reruns PASS. |
| Native / Keyboard catalog | PASS: final rerun `interactive-1b8af5002519441382a08b6c947b1315/report.json`. |
| Native draft recovery | PASS: `interactive-4394ad15f56d4c3abc875d564115cf43/report.json`. |
| Native writer recovery | PASS: `interactive-6e4cf6651e9a48edb426f15bdf059777/report.json`. |
| Native editor responsiveness | PASS: `interactive-c30fdbe86e51483c958744f08f9fcd51/report.json`; existing GUI instance, one lifecycle registration set. |
| Native Make Independent | PASS: `interactive-03db37e4c78a4f47adbf702f49daf9f5/report.json`. |

## Gate 5 acceptance (2026-10-31)

Baseline `e469f032a7cf4a2d9f51e242e8dddaab2c76958e`; audited commit `7d8fb918f0dfab6106d265ceb482d7426200e633`.
Committed changes include runtime completion handling, editor/draft specs and
acceptance docs. The follow-up correction reconciles verified committed baselines
after dialog close without promoting the bound target or changing the editor.
Persistence formats, manifest versions and runtime module boundaries are unchanged.

New Phrase draft transfer intentionally retains the durable New scratch as a
recovery copy, including when destination persistence fails. The session draft
transfers to the created phrase; reopening New can independently restore the
durable copy. `acid_runtime_editor_spec.lua` checks both destinations and reopen
restoration, plus verified create completion after close without reopen. That
completion retires the request and retains committed source and the exact newer
New draft without binding the created phrase or updating editor revisions.

Follow-up native check remains unverified: start New Phrase generation, edit
again while busy, close the dialog before terminal delivery, then let it settle
without reopening. Reopen and verify the committed phrase contains the captured
source, New restores the newer draft, and no second generation occurred. Prior
native reports below predate this correction and do not validate this ordering.
Follow-up verification: `./scripts/run_tests.ps1` passes 68/68 specs under Lua
5.1, including the editor regression and runtime lifetime/writer integration
suites; `git diff --check` passes. No native rerun was performed for this correction.

| Subgate | Assertions and owners | Evidence |
| --- | --- | --- |
| T5.0 | Requirement mapping in this table and R01–R36 below; runtime target/revisions/arming in `runtime.context`, capture/checkpoints in `runtime.requests`, explicit `create`/`regenerate` in `writers.phrase_writer`. | Independent source/test review. |
| T5.1 | `acid_runtime_context_spec.lua`, `acid_runtime_request_spec.lua`, `acid_runtime_editor_spec.lua`, `acid_runtime_transitions_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_runtime_writer_integration_spec.lua`: single occupancy, latest pending edit, manual/live overlap, A→B→A, compile/render cancellation, missing/duplicate/late terminals, stale completion, close/reopen and song release. | PASS: focused specs and full suites. |
| T5.1 | `acid_runtime_editor_spec.lua`: changed committed baseline retains newer persisted/session-only draft, source/settings, exact token/revision and persistence warning; navigation restores it. Late create with Live Edit off transfers the newer draft to the exact returned phrase without a second request. | PASS: focused/full specs and fresh second-pass review. |
| T5.2 | `acid_draft_recovery_spec.lua`, `acid_gui_recovery_spec.lua`, `acid_runtime_editor_spec.lua`, `acid_runtime_writer_integration_spec.lua`: outgoing drafts, instrument scratches, cold-context restoration, occupied scratch, recovery/copy/discard, exact-revision clearing, settings isolation and persistence failure. | PASS: focused specs and full suites. |
| T5.2 | `acid_draft_recovery_spec.lua`: neither holder reads, overwrites, clears or rebinds one ambiguous durable draft; raw store bytes stay unchanged. `acid_runtime_independence_spec.lua` and GUI independence specs: identity-only action remains outside musical dispatch. | Focused specs pass. |
| T5.3 | GUI admission/views/recovery/timing specs plus real-writer integration: no-op/arming/navigation/recovery enqueue nothing; create→edit, stale/blocked delivery and foreign/detached refusal use the single production path. | PASS: focused/full specs and targeted native reruns. |
| T5.3 | `acid_runtime_integrity_spec.lua`, writer integration and GUI recovery: read-only Revalidate refuses active renders/recovery objects; blockers survive navigation/reopen, drafts survive and old intent never retries. | Focused specs pass. |
| T5.4 | Production caller/dependency search and `acid_dependency_graph_spec.lua`: one target authority, request, pending trigger, writer transaction and terminal channel; no legacy scheduler/writer/status path, adapter, feature flag or mirror. | Independent review and focused specs pass. |
| T5.4 | `acid_pattern_store_codec_spec.lua`, `acid_phrase_persistence_spec.lua`, `acid_store_candidate_spec.lua`, inventory/output-compatibility/writer integration specs: strict saved-song decoding, source/draft/seal bytes and fresh-context ownership. | PASS: focused/full specs and package checks. |

Gate 5 CLOSED: T5.0–T5.4 pass; no unresolved local assertion or review finding.
Native playback, full undo grouping and the cold-process GUI journey remain Step 8.

| Final verification | Result |
| --- | --- |
| `./scripts/run_tests.ps1 -Tool ACID` | PASS: 65/65, Lua 5.1. |
| `./scripts/run_offline_tests.ps1` | PASS: 18/18 groups, including 68/68 repository Lua specs, runner and development/release package checks. |
| Fresh second pass | Independent scheduler, draft, production-path and final-diff reviews; focused reruns and `git diff --check` pass. |
| Native draft recovery | PASS: `interactive-cfd7f0bf7db946f1b2293633b1f9a2d9/report.json`. |
| Native integrity observers | PASS: `interactive-7fafb625fdb74d97b1175dd8ddef1867/report.json`. |
| Native writer recovery | PASS: `interactive-7b72de1be62d42598724628308676662/report.json`. |
| Native editor responsiveness | PASS: `interactive-224457298744455897b70d5da80950f2/report.json`. |
| Native/Keyboard catalog | PASS: `interactive-845e6da11f584abbbc6b45cb1b94f051/report.json`. |
| Native scenario order | PASS: `interactive-c31967fcce394b50995516cfae5abb9b/report.json`; `-VerifyScenarioOrder`. |

Native commands use `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong`
with `-AcceptanceCase draft-recovery`, `integrity-observers`, `writer-recovery` or
`editor-responsiveness`. The catalog uses `-Suite All -TestEnvironment <local-config>`
and `-AllowKeyboardFocusActivation`. Reports are under ignored `tmp/`; Renoise 3.5.4 /
API 6.2. All six runs restored the installation. Package checks require 34
source-identical runtime entries, root `manifest.xml`/`main.lua`, private modules
and no SDK/tests/docs. Source/draft/seal codecs and manifest versions are unchanged.

This map links the Step 7 regressions R01–R36 to local assertions. Focused specs
have been run during implementation; the full repository rerun passes 68 specs
with no timeout. Native checks completed in Renoise 3.5.4 cover queued Live Edit,
editor history, draft recovery, Make Independent, song reload and column observers.
Acoustic playback and the broader Step 8 A–E acceptance remain open. T4.8 now has targeted native evidence for undo/redo, source-less ownership negatives and cold-process reopen.

Gate 3 direct writer acceptance is closed on 2026-10-31. The requirement-to-spec
matrix and command results are in the playbook's Gate 3 direct acceptance table.
The exceptional recovery follow-up passes all 18 offline groups, including 67/67
repository Lua specs (54.35s), plus a final 67/67 rerun (58.02s). The ACID
selection independently passes 64/64 (61.46s). Final runner, development package,
release package and source/archive identity checks pass. Native exceptional
writer recovery exercises all four fault paths on real phrases; integrity
observers/order, Make Independent save/reload, Draft Recovery, editor and
Native/Keyboard checks also pass. See the [dated host evidence](../renoise/host_verification.md#exceptional-writer-recovery-verification-2026-10-31)
for passing report IDs and intermediate failures. Acoustic playback and musical-writer native
song undo/redo grouping remain manual Step 8 acceptance; Gates 5-8 retain their
independent acceptance requirements.

## Task 4 acceptance (2026-10-31)

Gate 4 CLOSED: T4.0–T4.8 local and targeted native assertions pass. Broader Step 8 A–E acceptance and M4 remain open.

### T4.0 baseline execution (2026-10-31)

| Check | Evidence | Result |
| --- | --- | --- |
| Revision and checkout | HEAD `6cf32aaa9cb7ef3261f12dce0ed87dfd690b996d`; branch `feature/hardening4`, tracking origin | Recorded. Two documentation files had pre-existing staged edits; preserved. No runtime/spec edits were made for T4.0. |
| ACID baseline | PowerShell 7: `./scripts/run_tests.ps1 -Tool ACID`; runner used Lua 5.1 | 64 specs passed, 0 failed, 54.72s. `acid_runtime_independence_spec.lua` and `acid_gui_independence_spec.lua` passed in this run. |
| Second-pass verification | Same ACID command; independent read-only review; staged and unstaged `git diff --check` | 64 specs passed again, 0 failed, 54.52s. No material review findings; scope remained the two allowed docs and pre-existing staged changes were unchanged. |
| Runtime and mutation ownership | GUI button → `runtime.context:make_independent()` → `runtime.independence.run()`; read-only proof in `runtime.eligibility`; identity/store authorities in `renoise.phrase_ownership` and `renoise.pattern_store`; musical writes in `writers.phrase_writer` | Single identity transaction owner confirmed. Make Independent does not invoke the musical writer. |
| Writer exclusion | Context admission checks active/unsettled writer state, global occupancy, mutation guard and undo state; the Step 4 rule rejects without cancelling or queuing identity work. A later explicit action rechecks after matching terminal settlement. | Contract recorded; detailed races remain T4.2. |
| Verified commit versus presentation | Runtime identity transaction verifies before returning success. If subsequent inventory adoption or editor restoration fails, current context returns a plain failure and does not first record the required integrity blocker. | Known T4.5–T4.6 correctness gap; no post-commit reconciliation pass is claimed. |
| Remaining cases | R24 imported/source-less copy negatives; R28 dirty source/settings and recovery-origin failure preservation; R29 native undo/redo states and grouping; R36 cold-process reopen/reclassification/regeneration and negative associations | Open. Existing successful dirty-draft rebinding does not close R28. |
| Native evidence boundary | `interactive-ce843446f483440ea1d3f121667c45cd` covers Make Independent and same-process saved-song reload/regeneration. | Does not establish cold-process R36 or native undo/redo R29. The prior undo mismatch (restored phrase seal/content with newer `song.tool_data`) remains a negative probe. |

T4.0 records the baseline. Completed outcome, draft and native assertions are mapped under T4.3–T4.8 below.

| Requirement / owning subgate | Current evidence / limit |
| --- | --- |
| Outcome reconciliation / T4.5–T4.6 | PASS: injected adoption, reconciliation, editor and draft failures preserve verified commits and recoverable drafts; uncertainty blocks writes. See the focused assertions below. |
| Writer exclusion / T4.2 | Local admission, canceled-render occupancy and fresh explicit retry are verified below. Native interruption acceptance remains Step 8. |
| R24 / T4.8 | Local imported-copy rejection and native source-less foreign-copy rejection pass; `interactive-715d1ec981e3445a878c399fb4da1b27`. |
| R28 / T4.5–T4.6 | PASS: failure-path assertions preserve dirty source/settings and exact revision/recovery origin; ambiguous old-ID durable drafts remain unclaimed. Native draft recovery also passes. |
| R29 / T4.8 | Native undo blocks both holders and regeneration without repair; redo restores the exact committed association; `interactive-2da536d79a394909a2bd7ef8fca15349`. |
| R36 / T4.8 | Three-process save/reopen, read-only classification, exact-target regeneration and persisted duplicate/missing/modified rejection; `interactive-8d48c04d9b894b8a8cd84e0263a40a58`. |
| Architectural debt / T4.7–T4.8 | Integrated review confirms shared compatibility-proof construction, one mutation guard, musical pipeline, queue and ownership/store/draft authorities. No production state, format, version or runtime path change. |

The [native host record](../renoise/host_verification.md#t48-ownership-end-to-end-2026-10-31)
records source-less ownership rejection, native undo/redo and cold-process regeneration.
The earlier undo probe remains a regression reference; the T4.8 report verifies that
the reachable undo state blocks both holders without store repair and redo restores
the committed association. Gate 4 is CLOSED; these targeted results do not close Gate 8.

### T4.1 collision eligibility (2026-10-31)

| Check | Evidence | Result |
| --- | --- | --- |
| Matching groups and read-only rejection | `acid_runtime_independence_spec.lua`: two/three holders; different valid seals, hidden/tail cells, metadata, incompatible output, corrupt/missing source, getter failures and source drift; complete phrase snapshots and store/draft bytes checked | PASS |
| Live identity and transaction boundary | Same spec: distinct content-equal objects; changed holder after proof/preparation; receiver drift during undo description; direct imported collision with no local source retains unrelated committed source and draft | PASS |
| Compatibility policy | `runtime.eligibility.compatibility` supplies admission and committed-baseline proof construction; executor independently checks live holder objects, content, source/settings and retained receiver profiles | Single policy; no adapter or format change |
| ACID suite | PowerShell 7: `./scripts/run_tests.ps1 -Tool ACID`, Lua 5.1 | 64 specs passed, 0 failed |
| Repository suite | PowerShell 7: `./scripts/run_tests.ps1`, Lua 5.1; isolated independence rerun after tightening getter-state equality | 67 specs passed, 0 failed; isolated rerun passed |
| Native E2E | `./scripts/run_interactive_tests.ps1 -Suite Native -AcceptanceCase make-independent -Install -ApproveDisposableSong`; `interactive-cd87dee421e748ed8e2776833167005b/report.json`, Renoise 3.5.4 / API 6.2 | PASS: exact selected content/source/settings preserved, other holder unchanged, same-object regeneration, saved-song reload and regeneration; installation restored |
| Package | `./scripts/package.ps1 -Tool ACID`; archive root and entry inspection | PASS: 34 runtime files, root manifest/main, private modules retained; no SDK/tests/docs |
| Fresh second pass | Independent final diff review, isolated independence spec, `git diff --check` | PASS; no remaining T4.1 finding |

**Proof-cost checks:** each action builds one context proof and one independent
executor proof. Source/content/receiver drift between them rejects; subsequent
guards compare live holders with trusted indexed snapshots and retained profiles
without rebuilding output plans or seals. Two/three-holder specs cap full proofs
at two. Context authorization retains the original proof and checks epoch,
session, revisions, bound objects, undo state and occupancy.

Native CPU measurements (`make-independent`, Renoise 3.5.4 / API 6.2):

| Holders | Baseline full proofs / CPU ms | Optimized full proofs / CPU ms | Native snapshots |
| --- | --- | --- | --- |
| Two | 10 / 1705.65 | 2 / 611.37 | 54 → 16 |
| Three | 10 / 2249.67 | 2 / 735.45 | 80 → 23 |

Reports: baseline `interactive-8ce100fbf7264c3d8efb2edb2c329632`, optimized
`interactive-8567183247bb48428912e2ed5bd18db2`. The bounded disposable probe
verifies both unaffected holders and restores exact phrase/store state before
the existing two-holder save/reload scenario. Timings are diagnostic CPU samples,
not latency guarantees. The proof-count cap is deterministic.

Verification: ACID/all suites passed 64/67 specs in Lua 5.1; package/root/exclusion
checks and fresh independent review passed. Native rerun
`interactive-8567183247bb48428912e2ed5bd18db2` passed the two-proof cap,
two/three-holder preservation and same-process save/reload/regeneration;
installation restoration passed.

T4.1 is locally verified. Native source-less import, native undo/redo and
cold-process reopen remain T4.8 obligations; Gate 4 remains open. The native
round trip reloads within one process and reports undo unavailable.
Post-commit reconciliation failures remain T4.5–T4.6 blockers.

### T4.2 authorization and writer exclusion (2026-10-31)

| Check | Evidence | Result |
| --- | --- | --- |
| Pinned admission | `acid_runtime_independence_spec.lua`: initial-proof reentrancy, native current-song switch, same-song dialog reopen/document reattach, A → B → A, edit revision drift, same-index replacement, undo unavailable/processing/throwing, proof exception followed by explicit retry | PASS: no stale identity/store commit or old-song undo read; admission lock releases on errors |
| Occupancy races | Same spec: writer becomes busy after initial proof, during undo description, or during the candidate guard's final allocation inspection; source/name setters count attempted writes | PASS: zero write attempts, no writer cancellation or queued identity retry; explicit idle retry captures fresh authorization |
| Canceled writer settlement | `acid_runtime_lifetime_spec.lua`, `acid_runtime_writer_integration_spec.lua`: accepted request, retained in-flight slot after revocation, matching render callback, explicit fresh retry | PASS: real writer integration uses the existing API-shaped host; settlement never executes rejected identity work |
| Cached GUI projection | `acid_gui_independence_spec.lua`: eligibility shown while idle, writer occupied before click | PASS: cached UI state cannot authorize mutation or dispatch musical work |
| Native regression | `interactive-b6c31116cb9841b3bdf86cb5357d2024/report.json`, Renoise 3.5.4 / API 6.2 | PASS: two/three-holder resolution, two-proof cap, same-object regeneration, same-process save/reload; installation restored |
| Fresh second pass | Independent admission/guard/test audit and four focused specs | PASS; no T4.2 correctness finding |
| Local/package checks | PowerShell 7: `./scripts/run_tests.ps1 -Tool ACID`, `./scripts/run_tests.ps1`, `./scripts/package.ps1 -Tool ACID`; final guard-focused reruns and `git diff --check` | PASS: 64/67 specs, Lua 5.1; 34 runtime archive entries with root manifest/main and no development files |
| Late-guard verification | Final-allocation fault injection, fresh independent review, `./scripts/run_tests.ps1`, `git diff --check` | PASS: 67 specs; zero source/name write attempts, no cancellation or implicit retry; explicit retry succeeds. Fault injection is local, not native evidence. |

The real writer integration spec is included to verify retained global render
occupancy on its existing host fixture. Runtime interruption and error cases above
are local/mocked evidence; native undo/redo, copy/import and cold-process acceptance
remain T4.8/Step 8. Gate 4 remains open; post-commit reconciliation remains blocked
under T4.5–T4.6.

Authorization revisions record invalidation rather than every runtime transition.
An arm/disarm round trip without an active Live Edit trigger can leave the tuple
unchanged; target, source/settings and writer occupancy are checked independently.

### T4.3–T4.6 local acceptance (2026-10-31)

| Subgate | Assertions | Result |
| --- | --- | --- |
| T4.3 | `acid_id_allocation_spec.lua`: orphaned source/draft and live-name IDs are reserved; candidate preparation and corrupt-store rejection preserve bytes. `acid_runtime_independence_spec.lua`: allocation and guard drift reject before name/source mutation. | PASS |
| T4.4 | `acid_runtime_independence_spec.lua`: selected name and cloned source alone change; unrelated phrase and New drafts survive; unexpected source entry rejects; no musical sink call. | PASS |
| T4.5 | `acid_runtime_independence_spec.lua`: unreadable name and reentrant store change retain a blocker without overwriting newer data. `acid_runtime_integrity_spec.lua`: revalidation is read-only. | PASS |
| T4.6 | `acid_runtime_independence_spec.lua`: adoption, reconciliation and editor restoration failures remain committed and blocked; dirty source/settings and exact draft token/revision survive rollback, adoption failure and editor-restoration failure. `acid_gui_independence_spec.lua`: committed outcome and recovery warning are visible; blocked generation reaches no writer. | PASS |

PowerShell 7: `./scripts/run_tests.ps1 -Tool ACID` passed 64/64; `./scripts/run_tests.ps1` passed 67/67. `./scripts/package.ps1 -Tool ACID` built 34 runtime files; archive root has `manifest.xml` and `main.lua`, with no development files. Native source-less import, undo/redo and cold-process reopen checks remain open.

Editor responsiveness is measured by native `editor-responsiveness` acceptance:
unchanged display/idle reads perform no phrase snapshots; clean source edits perform
no native cell scans or seal hashes. Five edits average 1.09 ms, maximum 1.17 ms,
on a 32-step/128-line phrase. Thirty GUI actions meet a 30 ms callback budget;
queued edits commit the latest source. Hidden/inactive cells and external-change
rejection remain verified.

### T4.7 GUI, observers and lifecycle (2026-10-31)

| Contract | Assertions | Result |
| --- | --- | --- |
| Bound target and authorization | `acid_gui_independence_spec.lua`: content-equal objects remain distinct; armed resolution makes no writer/selection call; the next source edit regenerates the exact object after idle dispatch; removed targets stay unavailable. | PASS |
| Dialog lifetime | Same spec: reentrant close runs once; callbacks from a closed session cannot affect a reopened dialog. | PASS |
| Real writer lifecycle | `acid_runtime_writer_integration_spec.lua`: armed resolution retains exact target/native selection without writer dispatch; post-commit reentrant close blocks writes until read-only revalidation; later explicit regeneration preserves every unrelated holder and committed source/settings. | PASS |
| Native notifications | `acid_runtime_observers_spec.lua`: receiver playback/program and protected script changes notify during idle/busy operation; private render-script events remain filtered; structural undo rebinds listeners. | PASS |
| Listener lifetime and cost | Same spec: unchanged refresh adds/removes no listeners; reentrant detach/replacement preserves attachment boundaries and queued notifications; removed objects lose listeners. Existing lifetime/writer integration specs cover released callbacks and retained render occupancy. | PASS |
| Native identity and refresh | `interactive-e899e49142234933b54ebca8f21e1ef0/report.json`: armed resolution preserves native selection, bound objects, notes/source/settings and other holders; zero generation, two eligibility proofs, zero snapshots on unchanged display/reconcile; explicit regeneration and same-process reload retain the exact destination. | PASS |
| Native integrity, writer recovery, drafts | `interactive-ad29c337adf14dc991feb85b4660b3f7`, `interactive-97ba7979ca034312889db2f0aafb92a0`, `interactive-aafdf385ce754feb901aaa58ee0d76c8`. | PASS |
| Native/keyboard catalog | `interactive-dab152679f3b4ca491ec693d3526848b`: native inventory scenarios, real shortcut, dialog close and native navigation; installation restored. | PASS |
| Native responsiveness | `interactive-71179c34baad454eab94941a7ab2c54c`: zero GUI actions exceed 30 ms; busy edit 18.63 ms; unchanged reads perform zero native snapshots. | PASS |
| Local suites and second pass | `./scripts/run_tests.ps1 -Tool ACID`: 64/64; `./scripts/run_tests.ps1`: 67/67, Lua 5.1. Fresh GUI/runtime/observer reviews, independent assertion review and focused reruns; `git diff --check`. | PASS |
| Offline and package checks | `./scripts/run_offline_tests.ps1`: 18/18 groups; `./scripts/package.ps1 -Tool ACID`: 34 entries match source bytes, root manifest/main and private modules present, SDK/development files excluded. | PASS |

Reports are under ignored `tmp/`; commands use PowerShell 7 and Renoise 3.5.4 /
API 6.2 at runtime revision `7964da5`. The native Make Independent command is
`./scripts/run_interactive_tests.ps1 -Suite Native -AcceptanceCase make-independent -Install -ApproveDisposableSong`;
the catalog uses `-Suite All -TestEnvironment <local-config> -AllowKeyboardFocusActivation`.
The 34-entry ACID release archive passes root/module/exclusion checks.
Stable bindings remove idle listener churn; draft callbacks reuse the returned
editor state and avoid a duplicate copy. The existing runtime, dirty-notification
path, queue and writer remain the sole owners. Formats and versions are unchanged.
Separate user-action undo, source-less rejection and cold-process evidence are recorded under T4.8.

| Case | Local evidence | Acceptance limit |
| --- | --- | --- |
| R01 | `acid_gui_views_spec.lua`, `acid_gui_admission_spec.lua`, `acid_runtime_editor_spec.lua`: opening, arming, navigation and programmatic restoration leave the request count unchanged. Assertion locators: acid_gui_admission_spec.lua:229–241. Result: PASS in final ACID 65/65 and repository 68/68 suites. | GUI mocks only. |
| R02 | `acid_runtime_writer_integration_spec.lua`, `acid_gui_recovery_spec.lua`: create promotion binds the exact returned phrase object and adds one destination. Assertion locators: acid_runtime_writer_integration_spec.lua:261–283. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native ordering and undo remain Step 8. |
| R03 | `acid_runtime_writer_integration_spec.lua`, `acid_gui_views_spec.lua`, `acid_phrase_spec.lua`: repeated Live Edit regenerates the same phrase and keeps the count stable. Assertion locators: acid_runtime_writer_integration_spec.lua:288–312; acid_gui_views_spec.lua:547–553. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Playback remains Step 8. |
| R04 | `acid_runtime_request_spec.lua`, `acid_runtime_writer_integration_spec.lua`: frozen object membership and exact-target mutation are checked before commit. Assertion locators: acid_runtime_writer_integration_spec.lua:540–545; acid_runtime_request_spec.lua:26–35. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Mocked objects. |
| R05 | `acid_gui_admission_spec.lua`, `acid_gui_recovery_spec.lua`, `acid_runtime_inventory_spec.lua`: foreign/unavailable writes reject without append or overwrite. Assertion locators: acid_gui_admission_spec.lua:286–299. Result: PASS in final ACID 65/65 and repository 68/68 suites. | GUI and host behavior mocked. |
| R06 | `acid_runtime_inventory_spec.lua`, `acid_runtime_request_spec.lua`, `acid_phrase_spec.lua`: reorder, replacement, and removed-object cases do not retarget by index. Assertion locators: acid_runtime_inventory_spec.lua:30–42; acid_runtime_request_spec.lua:73–111. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Mocked membership changes. |
| R07 | `acid_runtime_inventory_spec.lua`: current objects, names and positions after inventory add/rename/reorder/removal (lines 356–391). `acid_gui_views_spec.lua`: notifier→idle refresh checks instrument popup labels/index and bound phrase options after add/rename/reorder/removal, with unchanged writer-call count (lines 654–703). Result: PASS in final ACID 65/65 and repository 68/68 suites. | GUI and notifier delivery are mocked; native notifier ordering remains Step 8. |
| R08 | `acid_gui_timing_race_spec.lua`, `acid_phrase_spec.lua`: native-selection changes and destination replacement during render invalidate stale commits. Assertion locators: acid_runtime_context_spec.lua:935–968; acid_runtime_request_spec.lua:73–111. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Async ordering is mocked. |
| R09 | `acid_runtime_lifetime_spec.lua`, `acid_gui_timing_race_spec.lua`: close/reopen and late completion cannot update a new dialog session. Assertion locators: acid_runtime_lifetime_spec.lua:84–113; acid_runtime_request_spec.lua:73–111. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Mocked session lifetime. |
| R10 | `acid_writer_safety_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_runtime_writer_integration_spec.lua`, `acid_script_runner_spec.lua`: release drops the old song/job graph while preserving native render occupancy and the script wrapper required for callback; wrapper becomes collectible after settlement. On failed or ineffective notifier removal, the exact subscription cleanup refs remain until verified removal, while stale callbacks stay inert. Assertion locators: acid_writer_safety_spec.lua:1208–1262,1434–1451; acid_script_runner_spec.lua:121–138,155–173; runtime lifetime release assertions at 168–211. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Healthy removal releases old host refs; faulted removal intentionally retains only the cleanup records needed to retry. A missing native callback cannot be forced in Renoise and requires restart guidance. |
| R11 | `acid_live_identity_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_runtime_independence_spec.lua`, `acid_gui_independence_spec.lua`: duplicate holders remain blocked; Make Independent resolves only the selected holder, including same-instrument duplicates, while preserving remaining/foreign holders. GUI asserts zero writer calls and unavailable bound phrase/instrument after removal. Assertion locators: acid_runtime_independence_spec.lua:148–186,209–230; acid_gui_independence_spec.lua. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native Make Independent, draft-recovery, undo/redo and cold-process checks passed; see T4.8 reports. |
| R12 | `acid_phrase_validator_spec.lua`, `acid_writer_inspection_spec.lua`, `acid_writer_safety_spec.lua`: hidden/content/output changes and temporary-object identity are revalidated before mutation. Assertion locators: acid_runtime_request_spec.lua:73–111,263–274; acid_phrase_snapshot_spec.lua:20–59. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Actual host field behavior remains Step 8. |
| R13 | `acid_writer_safety_spec.lua`, `acid_gate_transaction_spec.lua`: invalid requests and insufficient capacity reject before insertion or source mutation. Assertion locators: acid_writer_safety_spec.lua:488–506,554–592. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Mocked host. |
| R14 | `acid_writer_safety_spec.lua`, `acid_phrase_spec.lua`: render callback failures clean staging and retain the prior destination/source. Assertion locators: acid_writer_safety_spec.lua:1091–1118,1163–1185; acid_phrase_spec.lua:239–275. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Renoise render failures are not induced locally. |
| R15 | `acid_writer_safety_spec.lua`, `acid_runtime_writer_integration_spec.lua`, `acid_runtime_integrity_spec.lua`: failures restore exact state or record recovery/blocking evidence; committed cleanup failure blocks later requests and survives dialog reopen; post-commit adoption failure blocks generation across navigation/reopen; uncertain backup insertion verifies exact inventory or retains recovery evidence; explicit revalidation requires removal of recovery material and the exact committed baseline. Assertion locators: acid_writer_safety_spec.lua:925–1037,1041–1125; acid_runtime_writer_integration_spec.lua:608–657. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Fault injection only. |
| R16 | `acid_draft_recovery_spec.lua`, `acid_store_candidate_spec.lua`, `acid_gui_timing_race_spec.lua`: A→B→A drafts, collision isolation, exact revision clearing, occupied scratch, and guarded store writes are covered. Assertion locators: acid_gui_timing_race_spec.lua:264–299; acid_runtime_writer_integration_spec.lua:279–283,308–312. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Persistence reload remains partly native. |
| R17 | `acid_gui_views_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_runtime_observers_spec.lua`: release/reopen keeps replacement dialog observers intact after a queued stale idle callback; lifecycle cleanup retries failed idle/root removals; release drops stale request host and GUI references; observer removal failures retain inert cleanup records and block reattachment until cleanup succeeds. Assertion locators: acid_gui_views_spec.lua:778–838; acid_runtime_lifetime_spec.lua:168–211; acid_runtime_observers_spec.lua:757–811,1026–1061. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Notifier delivery and lifecycle are mocked; native notifier lifetime/order remains Step 8. |
| R18 | `acid_compiler_spec.lua`, `acid_output_planner_spec.lua`, `acid_sequencer_spec.lua`, articulation, timing, pitch-bend, and repeat specs: existing musical output contracts remain covered. Assertion locators: acid_compiler_spec.lua:18–23; acid_output_planner_spec.lua (sampled/overlap/bent expected cells); existing timing/articulation/repeat specs. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Audible smoke remains Step 8. |
| R19 | `acid_runtime_independence_spec.lua`, `acid_live_identity_spec.lua`, `acid_gui_independence_spec.lua`: collision eligibility, selected-object re-keying, same-instrument resolution, and the no-render UI path are covered. Assertion locators: acid_runtime_independence_spec.lua:79–127; acid_runtime_writer_integration_spec.lua:832–855. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native Make Independent, undo/redo and cold-process checks passed; see T4.8 reports. |
| R20 | `acid_runtime_independence_spec.lua`: two holders in different instruments resolve by explicit selected object; only the selected phrase ID changes. Assertion locators: acid_runtime_independence_spec.lua:79–127,148–162. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Save/reopen and independent regeneration remain Step 8. |
| R21 | `acid_runtime_independence_spec.lua`: three matching holders are resolved one at a time; a selected holder can resolve in an instrument containing a foreign phrase while other matching holders remain intact and blocked. Assertion locators: acid_runtime_independence_spec.lua:164–186. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native Make Independent, undo/redo and cold-process checks passed; see T4.8 reports. |
| R22 | `acid_runtime_independence_spec.lua`, `acid_runtime_writer_integration_spec.lua`: source cloning and selected object binding are checked; a three-holder same-instrument collision is resolved, the unique selected phrase regenerates while the remaining collision stays blocked, and regeneration is repeated after runtime release/reopen. Focused specs pass. Assertion locators: acid_runtime_writer_integration_spec.lua:848–880. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Cold-process Renoise save/reopen/regenerate passed; see T4.8 report. |
| R23 | `acid_runtime_independence_spec.lua`: matching two/three-holder groups qualify; different valid seals, hidden/tail content, metadata, incompatible output and inspection/transaction drift reject without changing phrase/store/draft data. Assertion locators: acid_runtime_independence_spec.lua:209–301,323–364. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native matching/mismatching ownership negatives and persisted bad-association checks passed; broader Step 8 acceptance remains open. |
| R24 | `acid_runtime_inventory_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_runtime_independence_spec.lua`: missing/corrupt sources reject; a direct imported collision with no local source cannot enter mutation and preserves unrelated committed source and durable draft bytes. Assertion locators: acid_runtime_independence_spec.lua:795–848. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native source-less foreign-copy rejection passed; see T4.8 report. |
| R25 | `acid_writer_safety_spec.lua`: create requires one free phrase slot; regenerate requires two and rejects before insertion when short. Assertion locators: acid_writer_safety_spec.lua:554–592. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Capacity boundary is mocked. |
| R26 | `acid_runtime_mutation_spec.lua`, `acid_runtime_observers_spec.lua`, `acid_writer_inspection_spec.lua`: scoped mutations, temporary neutrality, observer re-entry, and column-name/mute notifications during editing and generation are exercised. Assertion locators: acid_runtime_writer_integration_spec.lua:447–495,540–561; acid_runtime_mutation_spec.lua:34–69. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Renoise notifier ordering remains Step 8. |
| R27 | `acid_runtime_context_spec.lua`, `acid_runtime_writer_integration_spec.lua`, `acid_gui_timing_race_spec.lua`: newest intent supersedes safely and no second writer starts before terminal retirement. Assertion locators: acid_runtime_writer_integration_spec.lua:367–405; acid_runtime_context_spec.lua:440–466. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Async callback ordering is mocked. |
| R28 | `acid_runtime_independence_spec.lua`: store setter write-then-throw, adoption failure and editor-restoration failure preserve dirty source/settings and exact draft token/revision/recovery association; committed failures remain blocked. Assertion locators: acid_runtime_independence_spec.lua:878–913,1126–1165,1301–1335,1445–1467. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Local failure-preservation assertions pass. Native draft recovery copy/discard also passed; the failure injections remain local. |
| R29 | `acid_runtime_integrity_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_output_compatibility_spec.lua`: undo/redo invalidation, blocker persistence, and read-only revalidation are mocked. Assertion locators: acid_runtime_inventory_spec.lua:55–90; acid_runtime_request_spec.lua:73–111. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native Make Independent undo/redo state behavior and exact committed association passed; complete logical grouping was not established and remains Gate 8. See T4.8/T4.8a evidence. |
| R30 | `acid_runtime_inventory_spec.lua`, `acid_writer_inspection_spec.lua`, `acid_live_identity_spec.lua`: raw object identity remains distinct from value/content equality during inventory and cleanup. Assertion locators: acid_runtime_inventory_spec.lua:30–42; acid_writer_inspection_spec.lua:200–214. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Mocked object identity. |
| R31 | `acid_writer_safety_spec.lua`, `acid_runtime_context_spec.lua`: start rejection produces no callback or host mutation; accepted sync/async failures and duplicate native completion settle once. Assertion locators: acid_writer_safety_spec.lua:488–505,1148–1185. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Mocked callback behavior. |
| R32 | `acid_writer_safety_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_script_runner_spec.lua`: cancellation/release retain global occupancy until native completion; old song/UI references are dropped; wrapper lifetime is bounded by callback. Ineffective/throwing/reentrant removal retains exact cleanup refs, callbacks remain inert, and retry completes detachment. Assertion locators: acid_writer_safety_spec.lua:1188–1262,1413–1451; acid_runtime_lifetime_spec.lua:168–211; acid_script_runner_spec.lua:121–138,155–173. Result: PASS in final ACID 65/65 and repository 68/68 suites. | A callback that never arrives cannot be exercised in Renoise; restart guidance remains. |
| R33 | `acid_phrase_snapshot_spec.lua`, `acid_target_capabilities_spec.lua`, `acid_writer_safety_spec.lua`: mapping, column metadata, script and supported fields survive mock regeneration/rollback; unreadable capabilities reject. Assertion locators: acid_writer_safety_spec.lua:827–875,880–951; acid_phrase_snapshot_spec.lua:20–59. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Actual preservation and unsupported-field behavior remain Step 8. |
| R34 | `acid_draft_recovery_spec.lua`, `acid_runtime_independence_spec.lua`, `acid_gui_recovery_spec.lua`: chooser rows carry exact revisions; stale copy/discard reject; occupied scratch stays recoverable; forced unchanged preservation retains the copied revision; armed GUI recovery/discard do not invoke the writer; failed create retains the exact selected origin; successful verified create clears only that origin and preserves unrelated entries. Assertion locators: acid_gui_recovery_spec.lua:563–601; acid_runtime_independence_spec.lua:36–57. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Native draft recovery passed in Renoise 3.5.4; undo/redo and cold-process checks passed in T4.8. |
| R35 | `acid_runtime_integrity_spec.lua`, `acid_runtime_context_spec.lua`, `acid_runtime_lifetime_spec.lua`: blockers survive dialog reopen, release drops recovery refs, revalidation is read-only, and no automatic retry occurs. Assertion locators: acid_runtime_writer_integration_spec.lua:608–657; acid_runtime_integrity_spec.lua:336–346. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Live-song/native release remains Step 8. |
| R36 | `acid_runtime_inventory_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_runtime_writer_integration_spec.lua`: fresh-context reconstruction uses current object identity and persisted source/output compatibility without saved epochs or automatic writes. Assertion locators: acid_runtime_writer_integration_spec.lua:323–348; acid_runtime_lifetime_spec.lua:213–236. Result: PASS in final ACID 65/65 and repository 68/68 suites. | Cold-process save/reopen/regenerate and negative persisted-association checks passed in T4.8. |

All 36 rows above pass in the final T7.4 suites. Assertion locators refer to
`tests/acid/` and identify actual blocks or labeled assertions, rather than
inferring coverage from filenames. R07 verifies both instrument-choice projection
and notifier-to-idle GUI refresh after add, rename, reorder and removal, with
zero writer requests. Removal-fault regressions verify inert stale delivery and
exact cleanup retries, including release during native rendering. Mocked API
failures do not establish native playback or host failure behavior; the
acceptance-limit column and targeted T4.8/T4.8a evidence retain that boundary.

## T4.8 ownership end-to-end (2026-10-31)

Source revision `60fe5a8bca3730c4c1a415116047feac7f81b773` plus the recorded
working tree; Renoise 3.5.4 / API 6.2, PowerShell 7, Lua 5.1.

| Check | Evidence | Result |
| --- | --- | --- |
| Cold-process round trip | `interactive-8d48c04d9b894b8a8cd84e0263a40a58/report.json`; PIDs 12588 → 14756 → 18728 | PASS: fresh-process read-only classification, exact-target regeneration, second reopen, stable phrase count and foreign sentinel; duplicate, missing-source and modified associations reject without load/inspection writes. |
| Native undo/redo | `interactive-2da536d79a394909a2bd7ef8fca15349/report.json` | PASS: one native undo restores prior phrase state while `song.tool_data` retains exact post-Make-Independent bytes; both duplicate holders block and regeneration rejects without repair. Redo restores the exact new identity/source association. |
| Ownership negatives | `interactive-715d1ec981e3445a878c399fb4da1b27/report.json` | PASS: source-less foreign, missing-source, mismatching and two/three-holder collisions remain blocked. |
| Draft recovery | `interactive-1ce5271935564fa2ae996fcd10ae3949/report.json` | PASS: recovery remains until explicit discard; Copy to New preserves source/output policy and discard clears the selected recovery. |
| Integrity observers | `interactive-4b2a150014864a7e8a44ba9d8cc1d638/report.json` | PASS: native integrity and column observers. |
| Writer recovery | `interactive-9dad16b556ef4d5fae182cb64bcc60af/report.json` | PASS: native exceptional writer-recovery assertions. |
| Responsiveness | `interactive-a3f03bf3576d4c4b88b2a36e658252e9`, `interactive-d3a9fdcb06e14324a81d6b3eebb949de` | PASS: all 30 GUI actions meet the unchanged 30 ms budget; busy edits 4.18 / 5.07 ms. Projection refresh performs no discarded baseline clone. |
| Native and Keyboard | `interactive-8bc1ad14982a40a0891e73462d5c26a9/report.json` | PASS: native inventory, production shortcut, dialog close and native navigation; installation restored. |
| Scenario order | `interactive-c4dbcf0027594961bf433c03d16f80ae/report.json` | PASS: independent/reversed catalog snapshots and idle settlement. |
| Projection ownership | `acid_runtime_inventory_spec.lua`; fresh independent review | PASS: projection refresh omits baseline detachment; full target reads remain isolated and hidden phrase changes block ownership. |
| Offline and package | `tmp/t48-offline-verified.log` | PASS: 18/18 offline groups, 67 Lua specs; ACID selection 64/64 in the recorded focused run; release package has 34 source-identical entries with root manifest/main and no development files. |
| Architecture and scope | Dependency/ownership review against the integrated tree | PASS: shared compatibility-proof construction; one runtime mutation guard, musical writer, queue and ownership/store/draft authorities. No added production state or entry point; persistence formats and versions unchanged. |
| Process and test cleanup | Native reports; runner specs | PASS: runner-owned Renoise processes shut down and installation restored; shared test-session rejection, PID ownership, bounded connection and transport diagnostics passed. |

These reports close the recorded T4.8 R24, R29 and R36 native assertions and
support R28/R34 draft evidence. Gate 4 is CLOSED. Acoustic playback and broader
Step 8 A–E acceptance remain open.
