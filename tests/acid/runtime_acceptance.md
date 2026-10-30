# Runtime integration acceptance map

This map links the Step 7 regressions R01–R36 to local assertions. Focused specs
have been run during implementation; the full repository rerun passes 67 specs
with no timeout. Native checks completed in Renoise 3.5.4 cover queued Live Edit,
editor history, draft recovery, Make Independent, song reload and column observers.
Playback, native song undo grouping and cold-process reopen remain manual checks.

Gate 3 direct writer acceptance is closed on 2026-10-31. The requirement-to-spec
matrix and command results are in the playbook's Gate 3 direct acceptance table.
The final ACID selection passes 64/64 specs (62.70s), and the repository passes
67/67 (50.39s), with no timeout. Host preflight, runner lifecycle, development
packaging, release packaging and archive identity checks pass. No new native
manual checks were performed; Gates 4–8 remain independent acceptance.

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
| R23 | `acid_runtime_independence_spec.lua`: two- and three-holder resolution and a re-sealed holder with changed hidden content are rejected. | Native collision revalidation beyond the completed Make Independent check remains pending. |
| R24 | `acid_runtime_inventory_spec.lua`, `acid_output_compatibility_spec.lua`, `acid_runtime_independence_spec.lua`: missing/corrupt sources do not authorize adoption or resolution. | Cross-song/imported copy transaction cases need focused coverage; native source-less copy remains Step 8. |
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
