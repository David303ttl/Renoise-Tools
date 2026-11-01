# Runtime integration acceptance map

Recorded reports below describe the implementation present at each dated
checkpoint. Results involving staged rendering, render callbacks or two free
regeneration slots are historical evidence for the former writer. They do not
establish acceptance of the current direct writer; its native workflow checks
remain under Gate 8 until explicitly recorded as passing.

## T8.0 native baseline (2026-11-01)

**Status: baseline and scope recorded; all-green condition NOT met; Gate 8 OPEN.** Original baseline: `e2ca527a65efe21d03c34438e0b6813d04676630`, Windows / PowerShell 7.5.4, Renoise 3.5.4 / API 6.2, ACID 0.1. Verified runtime checkout: `b93becf8a739cdbc77e42aec5ac89ffb5d750c50` (clean before the reruns below). Earlier reports identify their particular packaged working tree; the fresh Warm and Detailed reports below cover this commit.

| Check | Latest recorded evidence | Result / limit |
| --- | --- | --- |
| `editor-responsiveness`, Warm | `tmp/interactive-c0214383b9e04fcf9a265b6394150cf7/report.json` | **FAIL: 55.87 ms** synchronous Live Edit callback against 30 ms. All 30 GUI actions exercised; committed source, exact target and fixture selection/inventory checks pass. Diagnostic uses 32 steps / 128 lines. |
| `multi-instrument-workflow`, Warm | `tmp/interactive-fe9aa02398ef47ce9dfd2727823b998f/report.json` | **FAIL: 104.96 ms** against 30 ms. Three instruments / 12 phrases, 12 transactions, source/persistence and selection checks pass; the overall Live Edit acceptance assertion remains false because of timing. Not 8x8 evidence. |
| `integrity-observers` | `tmp/interactive-d0203b9d67934b6cacfa17bc91231328/report.json` | **PASS.** Visible/hidden names and mutes exercised idle and reentrantly during mutation; four actual cancellations preserve destination/store and reconcile on idle. Close/reopen and document release/new-song attachment pass between settled operations. Reentrant dialog close/document release are explicitly not claimed. |
| `writer-recovery` | `tmp/interactive-0335af106dc0490f839844c211180ef7/report.json` | **PASS.** Contradictory success preserves committed source and recoverable draft, and remains blocked without complete proof. A separate guarded pre-write failure supplies verified unchanged-preimage proof and exercises clear false/throw/success retry. It does not prove recovery of the contradictory-success case via native Undo. |
| `direct-output-feasibility` | `tmp/interactive-63606e6dd1f445e5ad8d0e15f476bf26/report.json` | **PASS, final runtime:** nine materializations match the independent oracle; representative rollback/source checks pass. Audible playback remains unverified. |
| `revision-undo`, `revision-live-undo` | `tmp/interactive-13eb8d845aba45a6ac0cbf72df0aab01/report.json`; `tmp/interactive-b325b96f724b413fb44ff1aa2d2610c3/report.json` | **PASS, final runtime:** manual and Live Edit Undo/Redo. Guarded native callbacks use configured AutoHotkey v2 and `Alt+Control+B`. |
| `make-independent -ColdProcessRoundTrip` | `tmp/interactive-14c34b14af0c492b8700e3fc9d1706a3/report.json` | **PASS, earlier overlay:** two fresh-process reopen transitions. Narrow Make Independent path, not production-session cold GUI acceptance. |
| Combined Lua suites | `tmp/t80-final-offline-summary.json` | **PASS: repository 73/73**, including all 70 ACID specs and the latest identity, store and snapshot-reader changes. |
| Offline / packages | `tmp/t80-final-offline-summary.json`; archives under `tmp/t80-package-check/` | **PASS: 18/18 offline groups** and all three release archives. ACID contains 31 entries; manifest/main/license are at archive root, module directories are preserved and SDK/development inputs are excluded. |

**Historical failures remain unchanged:** 107.72/118.00 ms direct-writer reports below; original baseline 99.07/192.24 ms; intermediate corrected Warm 64.29/131.27 ms. Earlier Warm values of 51.88/79.49 ms remain historical failures. Final-commit Warm reruns are 55.87/104.96 ms, still failures; they include single-scan identity validation, the exact-raw store commit fast path and shared snapshot property reader. No latency acceptance is claimed. `os.clock()` semantics were not independently established; nested Detailed timings overlap and are not additive CPU/wall-time proof. Detailed profile passes claim functional coverage only, not latency acceptance.

**Budget decision:** deferred until native production-scale measurements, as requested. The current 30 ms gate remains active; these failures are not relabeled.

**Final-commit diagnostic follow-up:** one Detailed run per failed Warm case passes functional assertions only: editor `tmp/interactive-f28436eaaa8e4b15b7b8affd6505dd3e/report.json` (60.36 ms) and workflow `tmp/interactive-1294df70f449442890a0f93582e23d5a/report.json` (86.26 ms). Both explicitly report `FUNCTIONAL_ONLY` and `performance_acceptance: NOT_CLAIMED`. All four fresh runs record `process.shutdown: PASS` and `install.restore: PASS`.

The editor Detailed profile records materialization at 21.47 ms, including 14.46 ms writing output (12.44 ms in 92 changed-cell calls), five snapshot matches totaling 15.86 ms, final classification at 7.56 ms and planning at 6.11 ms. Nested timings overlap. Unchanged cells are already skipped; the profiler recorded 0 ms for 644 field checks inside the changed-cell calls. Independent code review found no narrow redundant write-path work with a demonstrated payoff sufficient to meet 30 ms. No speculative runtime change or weakened authorization/postimage check follows from this evidence. Production-scale cases and receiver/playback evidence remain pending.

**Populated-song diagnostic follow-up (runtime `b93becf8`, development-harness changes):** both new latency diagnostics pass functional and cleanup assertions, with `performance_acceptance: NOT_CLAIMED`. Each uses the configured sample/Surge XT startup-patch/MIDI mix, standalone writer setup and history growth outside the timer, then one real GUI sample-target Live Edit callback. The RME physical loopback probe also passes (`tmp/t80-midi-loopback.json`); Renoise event delivery and audible playback are not inferred from that probe.

| Diagnostic | Loaded receivers / owned + foreign phrases | Added history revisions | Measured callback | Evidence |
| --- | --- | --- | --- | --- |
| `production-latency-8x8` | 3 sample / 3 VST / 2 MIDI; 64 + 8 | 128 | **669.33 ms** | `tmp/interactive-af69a137fdd4496bbdb44e8bf499aba8/report.json` |
| `production-latency-16x8` | 6 sample / 6 VST / 4 MIDI; 128 + 16 | 256 | **1,422.42 ms** | `tmp/interactive-45cf8ab65e8949aa88a83c59b30a9095/report.json` |

Final harness verification passes: repository Lua 73/73 (`tmp/production-latency-lua.log`), runner lifecycle checks (`tmp/production-latency-runner-tests.log`), development packaging (`tmp/production-latency-package-dev.log`) and a fresh 31-file ACID release package (`tmp/production-latency-package.log`). The earlier complete 18-group offline run is recorded above; unaffected audio groups were not repeated after these test-driver changes.

The callback runs with one extra temporary phrase (73/145 total). The 8x8 song retains two extra empty default instruments (10 native instruments); the 16x8 song has 16. Both reports pass `process.shutdown` and `install.restore`. Their per-instrument `owned_phrases_on_instrument` field included the foreign sentinel and was corrected from 9 to 8 after measurement; the verified top-level owned/foreign counts above are unchanged. These are single-callback diagnostics, not the full 128/512-edit production journeys, heterogeneous musical coverage, continuous playback or receiver-event acceptance. The current 30 ms gate remains unmet; no replacement ceiling is selected from these limited measurements.

**Changes covered by local tests:** private planner output drops unused intermediate trees; immutable empty rows/cells are shared only inside private snapshots, with public detachment and extra-field preservation retained; materializer comparisons reuse exact table identities within a call; loop geometry avoids redundant setters while respecting endpoint constraints; store preparation reuses serialized source bytes and retains fresh raw-store/concurrent-draft guards; identity validation derives membership and selected holders in one fresh full inventory scan. Complete native pre/post images, hidden/tail checks, fail-closed rollback and synchronous revision commitment remain required. No new scheduler, persistence format, manifest version or runtime module was added. Source marker, v3 ownership seal and `ACID-PITCH-TIME-1` remain unchanged.

The observer harness now injects edits through the production mutation wrapper rather than expecting an asynchronous busy state after Generate returns. Recovery assertions distinguish incomplete contradictory-success evidence from a verified unchanged preimage and observe writer completion independently of revoked GUI delivery. The mocked source-setter rollback reentry regression is covered by the writer's post-restoration guard; native reachability of that specific mock interleaving remains unverified.

**Phase budgets and remaining owners:**

| Phase / finding | Required evidence | Owner / current limit |
| --- | --- | --- |
| P0 seed and routing | 64 owned + 8 foreign phrases, eight assigned active tracks, real receiver preflight | T8.1 fixture/receiver work; not run at scale. |
| P1 8x8 / latency | At least 128 GUI regenerations; every edit callback ≤30 ms | T8.3 runtime/writer/materializer/planner/store owners; smaller Warm cases remain over budget. Retain authorization and full image verification. |
| P2 16x8 | At least 512 regenerations, 128 cross-instrument switches; every edit callback ≤30 ms | T8.4 production-session driver; not implemented/run. |
| P3 undo/recovery | Coherent native Undo/Redo, exact source/phrase/editor state, negative/recovery paths | Existing driver/runtime owners: scoped cases above pass; final combined native verification and broader production lifecycle coverage remain. |
| P4 cold reopen | Two true fresh-process reopen stages with source, phrase, identity and foreign-state checks | T8.4 driver; only narrow Make Independent path passed. |
| P5 receiver playback | Independent sample/VST observation and captured MIDI events | T8.5 receiver acceptance; not run. Structural parity is insufficient. |

The six fresh observer/recovery/Warm/Detailed reports above all record `process.shutdown: PASS` and `install.restore: PASS`; shutdown force-stopped only the runner-owned process and restored the original installation. T8.0 records scope, reproduction, phase budgets and owners; it does not close later acceptance. Gate 8 remains open until T8.1–T8.5 pass, including both project scales and the unchanged 30 ms maximum.

## Gate 8 expanded production-session acceptance (specified 2026-11-01)

**NOT IMPLEMENTED / NOT RUN / Gate 8 OPEN.** The real-user acceptance target now includes a single ACID production GUI controlling **8 instruments × 8 owned phrases (64) + 8 foreign sentinels** and **16 instruments × 8 owned phrases (128) + 16 foreign sentinels**, with actual sample/VST/MIDI receivers, 8/16 playing tracks, heterogeneous LAST STEP/PITCH spans, NOTE/TIE/REST, accents/slides, Straight/Triplet, Repeat/Play Once, PB, drafts, real native Undo/Redo and two cold reopen stages. The existing 3-instrument diagnostic is retained as narrower historical evidence, not an expanded-case PASS.

The full implementation-ready contract, deterministic profiles, real-GUI call path, 128/512 regeneration minimums, phase-specific independent oracles, 30 ms **per edit callback** maximum, source-history/heap/observer budgets, receiver event evidence, failure stop conditions and commands are in [production_session_acceptance.md](production_session_acceptance.md). Execute T8.0–T8.5 in order in the [playbook](../../com.david303ttl.ACID.xrnx/M4_7_RUNTIME_REFACTOR_PLAYBOOK.md#step-8--native-renoise-acceptance). The future case names are **not currently allowlisted**; no result is asserted here.

| Requirement | 8x8 | 16x8 |
| --- | --- | --- |
| Deterministic fixture and actual mixed receiver preflight | NOT IMPLEMENTED | NOT IMPLEMENTED |
| One real ACID GUI, full native peer/source/selection isolation | NOT RUN | NOT RUN |
| 128 / 512 regenerations, dirty drafts and no-op navigation | NOT RUN | NOT RUN |
| Real native Undo/Redo, failure/recovery and cold reopen twice | NOT RUN | NOT RUN |
| Actual phrase playback and MIDI route/event observation | NOT RUN | NOT RUN |
| Every Live Edit GUI callback ≤30 ms; history/memory/observer checks | FAIL at smaller historical scale; expanded run PENDING | PENDING |

Current smaller native evidence records 118.00 ms and 107.72 ms GUI Live Edit callbacks; functional checks **do not** satisfy this speed gate. No large-song results are claimed. Keep historic dated reports below unchanged.


## Direct-writer cleanup verification (2026-11-01)

The runtime has one synchronous materialization path. The former script writer
and unused backup comparison are removed; renderer references remain test-only
parity oracles. No migration, compatibility adapter, persisted-format change or
manifest version change is introduced. Authorization checkpoints and explicit
materializer outcomes are mandatory. Unknown write outcomes preserve native
state and record an integrity blocker; rollback never overwrites a later edit.

| Check | Evidence | Result |
| --- | --- | --- |
| Repository Lua suite | `tmp/acid-clean-cutover-final-repository.log` | PASS: 72 specs after admission capture reuse; focused materializer and seal parity also pass. |
| Manual native Undo/Redo | `tmp/interactive-fdf893b046cc4416b5b0b24f42ec63c4/report.json` | PASS: phrase, retained source/settings and GUI editor follow the native revision together. |
| Live Edit native Undo/Redo | `tmp/interactive-5f2a72ce62484a1d84c537ef672c22d7/report.json` | PASS: one native user action restores/reapplies the coherent revision without idle regeneration. |
| Three-process persistence | `tmp/interactive-48160072880d4aa7957434aa4ed04e69/report.json` | PASS: Make Independent, cold classification/regeneration, second cold reopen and negative source associations. |
| Direct output parity and rollback | `tmp/interactive-9a3b069ca54e45cb99ff1fee3103377a/report.json` | PASS: full native cell, hidden/tail and metadata checks against the test renderer. |
| Multi-instrument playback workflow | `tmp/interactive-37358246342d4d859b2397d007168cbd/report.json` | FAIL on timing only: 118.00 ms Live Edit callback. Twelve transactions across three instruments and twelve owned/foreign phrases preserve selection, source rows and persistence during four-track playback. |
| Responsiveness | `tmp/interactive-7af349689168455d979bf8dfd757b95a/report.json` | FAIL: final Live Edit callback 107.72 ms against the unchanged 30 ms budget. The preceding run was 64.94 ms; neither meets the limit. |
| Release package | `tmp/acid-clean-cutover-package.log` | PASS: 31 runtime files; root manifest/main and no test renderer dependencies. |

The earlier cold-process failure in `interactive-85b6b75ec10541cc832d21dc51a05c82`
was a harness precondition: invalid associations legitimately have no verified
baseline. The corrected helper still requires rejection with exact native and
persisted state preservation. Responsiveness remains open; functional passes do
not close the 30 ms requirement or Gate 8.

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
jump in the replaced script writer; direct-writer acceptance is in progress. Removal of an existing last phrase
would also block acceptance but was not observed in this run. API 6.2 was checked directly in both
`sdk/renoise-api-6.2/definitions/library/renoise/song.lua` and
`sdk/renoise-api-6.2/docs/API/renoise/renoise.Song.html`: `selected_phrase_index`
is explicitly READ-ONLY, as is `selected_phrase`. There is no selected-phrase
index observable. The disposable native probe below resolves the runtime
discrepancy: Renoise 3.5.4 accepted assignments to an existing phrase and to 0,
and retained each value through two subsequent idle callbacks. This contradicts
the pinned read-only annotation. No production selection restoration has been
introduced; the direct writer eliminates regeneration's structural phrase-list
edits. Selection stability must be assessed from independently read
native state while respecting actual user navigation.

The bounded investigations cover selection API behavior, direct planner output
parity against the former renderer, and detached rollback feasibility. See
[`renoise_selection_feasibility_probe_manual.md`](renoise_selection_feasibility_probe_manual.md)
and [`renoise_direct_output_feasibility_probe_manual.md`](renoise_direct_output_feasibility_probe_manual.md).
These are fixed development-driver cases, not a second production writer.
Production cutover requires
independent review of exact parity, restoration after partial failure, source
preservation, playback safety, responsiveness, and complete undo/redo behavior.
Regeneration must then preserve destination identity without phrase-list
insertion/deletion; explicit Create may add exactly one permanent destination.
The persisted formats and existing runtime/scheduler/request authority remain
unchanged. A failed or incomplete feasibility proof leaves Gate 8 open.

### Native feasibility follow-up (2026-10-31)

The final direct-writer manual Generate undo/redo check passes in
`tmp/interactive-015b4f2d22294e0b8f2836da54a5121d/report.json`: guarded Enter
invokes the real production GUI callbacks with its dialog kept open, commits
source revision 1 → 2, and one native Undo/Redo restores exact phrase cells,
source/settings and GUI editor state. The exact phrase object and one-entry
inventory are preserved; revision 1 remains available; no idle regeneration
occurs. GUI hydration settles in two idle callbacks. The persistent test
verifier preserves native notifier membership; earlier one-shot verification
loops starved the GUI callback and are not production-failure evidence. Live
Edit undo, multi-instrument playback and cold-process checks remain separate.

Live Edit native undo/redo also passes in
`tmp/interactive-926d5cddf7e0403dba0954cd0e0c9d27/report.json`. A real guarded
Enter arms the production Live Edit control and changes the actual key control;
its notifier commits synchronously without invoking manual Generate. The shared
native one-step Undo/Redo checks verify exact phrase/source/settings/editor
coherence, immutable source retention, stable phrase identity and no idle
regeneration.

Fresh native reruns after the request and draft-copy optimizations pass:
manual Generate `tmp/interactive-90912e7008d74df2a772004935073c58/report.json`
and Live Edit `tmp/interactive-6025a3ac5a274c0bafe0dd19d9d85a5e/report.json`.
Both exercise real GUI actions and native one-step Undo/Redo with exact
phrase/source/settings/editor coherence.

The fresh three-process persistence run passes in
`tmp/interactive-fba6e6180c0b4288886247b399468e7d/report.json`: Make Independent,
same-session reload, cold read-only classification, regeneration, and a second
cold reopen preserve the current revision/source/settings associations and the
foreign sentinel. The test schedules consecutive generations after completion
delivery returns and compares all phrase fields except the authorized revision
name change.

Current direct-writer local verification: `tmp/acid-direct-offline-final.log`
passes all 18 offline groups, including 71 repository Lua specs (68 selected by
the ACID suite), development/release package checks and audio analyzer fixtures.
`./scripts/package.ps1 -Tool ACID` builds 31 runtime files; the former script
renderer is test-only under `tests/acid/reference`. These checks do not close
the native GUI, Undo/Redo, playback or responsiveness requirements below.

The current responsiveness gate remains open:
`tmp/interactive-27c06d8532ea421ba573e6a7137e730c/report.json` proves a coherent
synchronous Live Edit commit but records 587 ms against the unchanged 30 ms
budget. It observes five planning calls, twenty snapshot copies and three full
classifications in that callback. The multi-instrument reproduction
`tmp/interactive-83f9f0badc4e4ef9a4258826e6094a8f/report.json` similarly passes
source/output, inventory and selection checks but fails timing at 761 ms. These
are failed responsiveness results, not acceptance passes.

The newer optimized run
`tmp/interactive-785fb926847240beb08ca230a9fcfe87/report.json` still fails:
Live Edit reports 140.64 ms against the unchanged 30 ms budget. Duplicate
planning and the redundant ownership hash are removed (one plan, zero status
calls). These are Renoise `os.clock()` measurements; the host timer's CPU versus
elapsed-time semantics have not been independently established.

| Check | Evidence | Result |
| --- | --- | --- |
| Host and API constants | `tmp/interactive-c4074ea1040a4ebe9d68abadd7779ec6/report.json`, fresh Renoise 3.5.4 / API 6.2 | PASS |
| Existing writer recovery | `tmp/interactive-2ef55d1e819a435783baa39a31dcbc3b/report.json` | PASS; existing writer only |
| Selection setter and structural effects | `tmp/interactive-4c9418ed5bf14dfcbb8f9b020703540a/report.json`: assignments to 1 and 0 succeeded immediately and through two idle callbacks. Insertion/deletion with phrase 1 selected retained selection; deleting the second probe phrase after setting 0 changed selection to 1. Exact probe cleanup and unchanged tool data were verified. | Runtime discrepancy resolved; structural selection effect reproduced |
| Direct output and detached rollback | `tmp/interactive-9d31097ae7234a289ae142007578ca19/report.json`: straight/triplet × sample capability false/true × play_once/repeat; all eight cases matched the existing script renderer plus gate writer across 10,240 native cell positions each. Visible/hidden/tail preimage sentinels restored exactly after faults following properties, early cells and late cells. | PASS for the recorded matrix; receiver/PB branches and acoustic behavior remain unverified |
| Source-store transaction | Same eight-case report: one representative actual store candidate committed and read back, then phrase and guarded source candidate restored after an injected post-commit failure. Exact raw source bytes restored; false request guard rejected without a write. | PASS for this representative transaction; actual host setter-failure and failed-rollback cases remain open |
| Native user-action undo | `tmp/interactive-14750c3d2b39487182340a6a291d8ff8/report.json`: real dialog action, one undo/redo state, prior phrase restored, newer tool data retained. Invalid regeneration was rejected without source repair; original fixture restored. | Safety PASS; `complete_logical_undo_grouped=false`, atomic undo remains FAIL |
| Direct Song API undo variants | `tmp/interactive-23ea6b6ed64e4d5484df7489ed0add9e/report.json`: five variants covered source-only, synchronous phrase/source, and split callbacks using describe_undo or describe_batch_undo. None exposed an undo state from these idle-driven actions; inventory and original tool data restored. | FAIL to establish grouping; real user-action follow-up required. This is not proof that a final synchronous writer cannot participate in native undo. |

The user-action undo row tests Make Independent, not a final direct writer.
It establishes a real retained-source mismatch in the existing persistence
mechanism. The idle-driven variants do not replace a final-writer GUI undo
test. Neither safe blocking nor a passing materialization probe resolves the
complete logical undo requirement. The user requires coherent native undo and
redo; a blocked source/phrase mismatch is not an acceptable final workflow.

The direct writer now assigns a fresh immutable source ID on every successful
Create or Regenerate. Existing source rows are retained, using the unchanged
source-store header and v3 phrase-name format. Native undo can therefore restore
the old phrase name and cells while retained tool data still contains the exact
old source and settings. Runtime reconciliation reloads the restored revision;
it must not regenerate it or silently attach a newer dirty draft. The song's
source data grows with committed revisions because the native undo stack does
not expose a safe pruning boundary. No history browser or additional user step
is introduced. Manual Generate and Live Edit production GUI undo/redo pass as
recorded above; broader workflow verification remains required.

Regenerate materializes the planner's expected image into the same phrase
without inserting or deleting a phrase. Create inserts one permanent phrase.
Both operations use the existing request and mutation authority, with full
preimage validation, post-write verification, and detached rollback on failure.
Live Edit flushes the existing scheduler from the user edit callback so the
native operation participates in that user action's undo history.

Harness development failures are retained locally as diagnostic evidence, not
native feasibility results: `interactive-650234c50432485f95b2d928b3823bb6`
(missing transport allowlist), `interactive-080352f9b8544f2a8ef3a7c5f809ffe0`
(stale probe guard), `interactive-ff881f225195432c8302feb3cdf05485`
(untagged JSON array), and `interactive-7f0ee17255f048be97939c25e04a0173`
(incomplete TIME fixture), and `interactive-e987f4412fd34c67a1e735ddc1b03c6f`
(invalid loop-end reset value). Those harness defects were corrected before reruns.

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
