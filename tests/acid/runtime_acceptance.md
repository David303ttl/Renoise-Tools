# Runtime integration acceptance map

This map links the Step 7 regressions R01–R36 to local assertions. Focused specs
have been run during implementation; the full repository rerun passes 67 specs
with no timeout. Native checks completed in Renoise 3.5.4 cover queued Live Edit,
editor history, draft recovery, Make Independent, song reload and column observers.
Playback, native song undo grouping and cold-process reopen remain manual checks.

Gate 3 direct writer acceptance is closed on 2026-10-31. The requirement-to-spec
matrix and command results are in the playbook's Gate 3 direct acceptance table.
The exceptional recovery follow-up passes all 18 offline groups, including 67/67
repository Lua specs (54.35s), plus a final 67/67 rerun (58.02s). The ACID
selection independently passes 64/64 (61.46s). Final runner, development package,
release package and source/archive identity checks pass. Native exceptional
writer recovery exercises all four fault paths on real phrases; integrity
observers/order, Make Independent save/reload, Draft Recovery, editor and
Native/Keyboard checks also pass. See the [dated host evidence](../renoise/host_verification.md#exceptional-writer-recovery-verification-2026-10-31)
for passing report IDs and intermediate failures. Acoustic playback and native
song undo/redo grouping remain manual Step 8 acceptance; Gates 4-8 retain their
independent acceptance requirements.

## Task 4 hardening readiness (2026-10-31)

Gate 4 remains OPEN. The playbook's Step 4 now defines ordered T4.0–T4.8
subgates for completing the existing implementation. This is a readiness audit,
not by itself implementation acceptance. Record revision, command or native
report, exact assertion, result and remaining blocker for each subgate as it
executes. Do not advance past an unresolved earlier correctness defect.

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

T4.0 baseline and contract recording is complete; Gate 4 remains open. The
post-commit reconciliation gap and all listed native/local obligations remain
unresolved.

| Requirement / owning subgate | Evidence still required |
| --- | --- |
| Outcome reconciliation / T4.5–T4.6 | Inject post-commit adoption, reconciliation, editor restoration and draft-rebinding failures. Distinguish verified commit from rejection; preserve committed identity and recoverable drafts, and block unsafe writes when reconciliation fails. |
| Writer exclusion / T4.2 | Local admission, canceled-render occupancy and fresh explicit retry are verified below. Native interruption acceptance remains Step 8. |
| R24 / T4.8 | Local imported-copy transaction rejection is verified in T4.1 below; native source-less imported-copy rejection without adoption or mutation remains required. |
| R28 / T4.5–T4.6 | Selected dirty source/settings and exact revision/recovery origin survive injected transaction rollback and post-commit failure; ambiguous old-ID durable drafts remain unclaimed. Existing successful dirty-draft rebinding does not prove this. |
| R29 / T4.8 | Actual native Make Independent undo/redo states and grouping, including partial phrase/store associations; every inconsistent state blocks regeneration after undo settles, with no repair writes. |
| R36 / T4.8 | Save, terminate Renoise, open the song in a fresh process, reclassify read-only and explicitly regenerate the exact independent target; repeat negative persisted-association checks. |
| Architectural debt / T4.7–T4.8 | T4.1 shares compatibility-proof construction while preserving independent live checks. Verify the integrated dependency graph, single mutation guard, musical pipeline, queue and ownership/store/draft authorities. No new compatibility path, persistence format or unrelated M5 change. |

The [native host record](../renoise/host_verification.md#exceptional-writer-recovery-verification-2026-10-31)
records a passing Make Independent and saved-song reload/regenerate scenario.
It does not establish cold-process acceptance or native undo/redo safety. The
[prerequisite undo probe](acid_m35_s_manual.md#prerequisite-feasibility-record)
observed restored phrase content/seal with newer `song.tool_data`; retain this
negative evidence when designing the native checks. Gate 4's targeted native
results contribute to Gate 8 without closing its broader acceptance.

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

Editor responsiveness is measured by native `editor-responsiveness` acceptance:
unchanged display/idle reads perform no phrase snapshots; clean source edits perform
no native cell scans or seal hashes. Five edits average 1.09 ms, maximum 1.17 ms,
on a 32-step/128-line phrase. Thirty GUI actions meet a 30 ms callback budget;
queued edits commit the latest source. Hidden/inactive cells and external-change
rejection remain verified.

| Case | Local evidence | Acceptance limit |
| --- | --- | --- |
| R01 | `acid_gui_views_spec.lua`, `acid_gui_admission_spec.lua`, `acid_runtime_editor_spec.lua`: opening, arming, navigation and programmatic restoration leave the request count unchanged. | GUI mocks only. |
| R02 | `acid_runtime_writer_integration_spec.lua`, `acid_gui_recovery_spec.lua`: create promotion binds the exact returned phrase object and adds one destination. | Native ordering and undo remain Step 8. |
| R03 | `acid_runtime_writer_integration_spec.lua`, `acid_gui_views_spec.lua`, `acid_phrase_spec.lua`: repeated Live Edit regenerates the same phrase and keeps the count stable. | Playback remains Step 8. |
| R04 | `acid_runtime_request_spec.lua`, `acid_runtime_writer_integration_spec.lua`: frozen object membership and exact-target mutation are checked before commit. | Mocked objects. |
| R05 | `acid_gui_admission_spec.lua`, `acid_gui_recovery_spec.lua`, `acid_runtime_inventory_spec.lua`: foreign/unavailable writes reject without append or overwrite. | GUI and host behavior mocked. |
| R06 | `acid_runtime_inventory_spec.lua`, `acid_runtime_request_spec.lua`, `acid_phrase_spec.lua`: reorder, replacement, and removed-object cases do not retarget by index. | Mocked membership changes. |
| R07 | `acid_runtime_inventory_spec.lua`, `acid_gui_views_spec.lua`: add, rename, remove, and reorder refresh instrument/phrase choices without a write request. | Real notifier behavior remains Step 8. |
| R08 | `acid_gui_timing_race_spec.lua`, `acid_phrase_spec.lua`: native-selection changes and destination replacement during render invalidate stale commits. | Async ordering is mocked. |
| R09 | `acid_runtime_lifetime_spec.lua`, `acid_gui_timing_race_spec.lua`: close/reopen and late completion cannot update a new dialog session. | Mocked session lifetime. |
| R10 | `acid_writer_safety_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_runtime_writer_integration_spec.lua`, `acid_script_runner_spec.lua`: release drops job host references, retains only the exact native script wrapper needed by the in-flight render, and keeps native occupancy until callback; the wrapper is collectible after late completion. | Wrapper lifetime and missing native callback cannot be forced in Renoise; a missing callback requires restart. |
| R11 | `acid_live_identity_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_runtime_independence_spec.lua`, `acid_gui_independence_spec.lua`: duplicate holders remain blocked; Make Independent resolves only the selected holder, including same-instrument duplicates, while preserving remaining/foreign holders. GUI asserts zero writer calls and unavailable bound phrase/instrument after removal. | Native Make Independent and draft-recovery checks passed in Renoise 3.5.4; undo/redo and cold-process checks remain pending. |
| R12 | `acid_phrase_validator_spec.lua`, `acid_writer_inspection_spec.lua`, `acid_writer_safety_spec.lua`: hidden/content/output changes and temporary-object identity are revalidated before mutation. | Actual host field behavior remains Step 8. |
| R13 | `acid_writer_safety_spec.lua`, `acid_gate_transaction_spec.lua`: invalid requests and insufficient capacity reject before insertion or source mutation. | Mocked host. |
| R14 | `acid_writer_safety_spec.lua`, `acid_phrase_spec.lua`: render callback failures clean staging and retain the prior destination/source. | Renoise render failures are not induced locally. |
| R15 | `acid_writer_safety_spec.lua`, `acid_runtime_writer_integration_spec.lua`, `acid_runtime_integrity_spec.lua`: failures restore exact state or record recovery/blocking evidence; committed cleanup failure blocks later requests and survives dialog reopen; post-commit adoption failure blocks generation across navigation/reopen; uncertain backup insertion verifies exact inventory or retains recovery evidence; explicit revalidation requires removal of recovery material and the exact committed baseline. | Fault injection only. |
| R16 | `acid_draft_recovery_spec.lua`, `acid_store_candidate_spec.lua`, `acid_gui_timing_race_spec.lua`: A→B→A drafts, collision isolation, exact revision clearing, occupied scratch, and guarded store writes are covered. | Persistence reload remains partly native. |
| R17 | `acid_runtime_lifetime_spec.lua`, `acid_runtime_context_spec.lua`, `acid_runtime_observers_spec.lua`: repeated session/document lifetimes detach mocked observers and invalidate stale jobs. | Native notifier lifetime remains Step 8. |
| R18 | `acid_compiler_spec.lua`, `acid_output_planner_spec.lua`, `acid_sequencer_spec.lua`, articulation, timing, pitch-bend, and repeat specs: existing musical output contracts remain covered. | Audible smoke remains Step 8. |
| R19 | `acid_runtime_independence_spec.lua`, `acid_live_identity_spec.lua`, `acid_gui_independence_spec.lua`: collision eligibility, selected-object re-keying, same-instrument resolution, and the no-render UI path are covered. | Native Make Independent passed in Renoise 3.5.4; undo/redo and cold-process checks remain pending. |
| R20 | `acid_runtime_independence_spec.lua`: two holders in different instruments resolve by explicit selected object; only the selected phrase ID changes. | Save/reopen and independent regeneration remain Step 8. |
| R21 | `acid_runtime_independence_spec.lua`: three matching holders are resolved one at a time; a selected holder can resolve in an instrument containing a foreign phrase while other matching holders remain intact and blocked. | Native Make Independent passed in Renoise 3.5.4; undo/redo and cold-process checks remain pending. |
| R22 | `acid_runtime_independence_spec.lua`, `acid_runtime_writer_integration_spec.lua`: source cloning and selected object binding are checked; a three-holder same-instrument collision is resolved, the unique selected phrase regenerates while the remaining collision stays blocked, and regeneration is repeated after runtime release/reopen. Focused specs pass. | Cold-process Renoise save/reopen/regenerate remains pending. |
| R23 | `acid_runtime_independence_spec.lua`: matching two/three-holder groups qualify; different valid seals, hidden/tail content, metadata, incompatible output and inspection/transaction drift reject without changing phrase/store/draft data. | Native collision revalidation beyond the completed Make Independent check remains pending. |
| R24 | `acid_runtime_inventory_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_runtime_independence_spec.lua`: missing/corrupt sources reject; a direct imported collision with no local source cannot enter mutation and preserves unrelated committed source and durable draft bytes. | Native source-less copy remains Step 8. |
| R25 | `acid_writer_safety_spec.lua`: create requires one free phrase slot; regenerate requires two and rejects before insertion when short. | Capacity boundary is mocked. |
| R26 | `acid_runtime_mutation_spec.lua`, `acid_runtime_observers_spec.lua`, `acid_writer_inspection_spec.lua`: scoped mutations, temporary neutrality, observer re-entry, and column-name/mute notifications during editing and generation are exercised. | Renoise notifier ordering remains Step 8. |
| R27 | `acid_runtime_context_spec.lua`, `acid_runtime_writer_integration_spec.lua`, `acid_gui_timing_race_spec.lua`: newest intent supersedes safely and no second writer starts before terminal retirement. | Async callback ordering is mocked. |
| R28 | `acid_runtime_independence_spec.lua`: store setter write-then-throw, phrase-name setter failure, post-rename clone-verification failure, and rollback failure are injected; tests assert restoration or retain a blocker when rollback cannot complete. | Selected dirty-draft rollback assertion and native undo/redo remain pending. |
| R29 | `acid_runtime_integrity_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_output_compatibility_spec.lua`: undo/redo invalidation, blocker persistence, and read-only revalidation are mocked. | Actual undo states/grouping remain Step 8. |
| R30 | `acid_runtime_inventory_spec.lua`, `acid_writer_inspection_spec.lua`, `acid_live_identity_spec.lua`: raw object identity remains distinct from value/content equality during inventory and cleanup. | Mocked object identity. |
| R31 | `acid_writer_safety_spec.lua`, `acid_runtime_context_spec.lua`: start rejection has no callback; accepted failures, cancellation, and duplicate completion settle once. | Mocked callback behavior. |
| R32 | `acid_writer_safety_spec.lua`, `acid_runtime_lifetime_spec.lua`, `acid_script_runner_spec.lua`: in-flight cancellation retains global occupancy across release; a missing callback does not free it, the exact script wrapper remains retained until callback, and late completion avoids other old host references. | A callback that never arrives cannot be exercised in Renoise; restart guidance remains. |
| R33 | `acid_phrase_snapshot_spec.lua`, `acid_target_capabilities_spec.lua`, `acid_writer_safety_spec.lua`: mapping, column metadata, script and supported fields survive mock regeneration/rollback; unreadable capabilities reject. | Actual preservation and unsupported-field behavior remain Step 8. |
| R34 | `acid_draft_recovery_spec.lua`, `acid_runtime_independence_spec.lua`, `acid_gui_recovery_spec.lua`: chooser rows carry exact revisions; stale copy/discard reject; occupied scratch stays recoverable; forced unchanged preservation retains the copied revision; armed GUI recovery/discard do not invoke the writer; failed create retains the exact selected origin; successful verified create clears only that origin and preserves unrelated entries. | Native draft recovery passed in Renoise 3.5.4; undo/redo and cold-process persistence checks remain pending. |
| R35 | `acid_runtime_integrity_spec.lua`, `acid_runtime_context_spec.lua`, `acid_runtime_lifetime_spec.lua`: blockers survive dialog reopen, release drops recovery refs, revalidation is read-only, and no automatic retry occurs. | Live-song/native release remains Step 8. |
| R36 | `acid_runtime_inventory_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_runtime_writer_integration_spec.lua`: fresh-context reconstruction uses current object identity and persisted source/output compatibility without saved epochs or automatic writes. | Cold Renoise process save/reopen/regenerate and negative native cases remain Step 8. |

The listed local cases are evidence for the specific assertions above, not a
claim that Gate 7 or native acceptance is closed. Remaining local gaps are
called out in the acceptance-limit column; update this map as those assertions
land and record each manual/native result separately.
