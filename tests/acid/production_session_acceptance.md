# Gate 8 — production-session acceptance contract

**Status: PASS — CLOSED by user decision (2026-11-01).** No further Gate 8 runs are required.

**Release policy:** latency is recorded without an acceptance threshold. Preserve recovery snapshots unchanged. Further performance investigation and runtime optimization are out of scope.

**Accepted scope:** 8×8 functional checks, Undo/Redo, two cold reopens and MIDI note/OFF/pitch-bend receipts passed. 16×8 acceptance is **PASS by scope decision**. The retained run created 128 phrases plus one explicit Create and completed 112 regenerations before a native-selection interruption; remaining execution is waived; the native runner report is FAIL because it records a partial run rather than a completed 16×8 stress execution. Audio capture is waived and no audio pass is claimed. See the [native report identities](runtime_acceptance.md#production-session-native-evidence).

The remaining sections preserve the original test matrix and driver constraints
for historical reference. They are not outstanding release work under the
scoped decision above; the waived 16×8 remainder and audio capture are not
reported as passed checks.

## 1. Objective, scope and architecture boundary

Prove that **one production ACID GUI window**, one ACID runtime/serialized synchronous direct writer and one real Renoise song can reliably edit dozens of independent PITCH/TIME sources across mixed samples, loaded VSTs and MIDI-only instruments while multitrack playback continues.

This is concurrent *use* across many targets, **not** concurrent writers. Direct materialization takes place synchronously in a user-action callback. User GUI navigation cannot run concurrently inside that callback; instead test rapid target switches **between settled callbacks**, plus native notifier reentry, selection preservation and audio transport continuity *during* callbacks. Never describe an asynchronous staging/render phase as the current architecture.

Only existing production authorities may generate: `runtime.context`, `runtime.requests`, `runtime.inventory`, `writers.phrase_writer`, `writers.phrase_materializer`, `renoise.pattern_store` and the real `gui.lua`. Do not add a second scheduler/writer, event bus, feature flag, migration, compatibility path, persistent schema, manifest version or background mutation. The harness may extend the existing dev-only driver, runner and packaging allowlist; it must not introduce a new framework. One **parameterized** 8x8/16x8 implementation is required, not two copies. A single test-only helper under `tests/renoise/driver/` is permissible only if it *extracts existing reusable driver code* and reduces duplication in the already large `acceptance_cases.lua`; add explicit development allowlist and release-exclusion checks.

Fixture setup may create instruments, route tracks, load receivers and add foreign phrases natively. However **all 64/128 owned phrase creations and subsequent edits** must go through the *real production ACID GUI controls and runtime* with one dialog kept open. No direct `tests/acid/writer_request.lua` or `phrase_writer.create/regenerate` calls may count as this integrated journey. Reuse the existing `editor-responsiveness` ViewBuilder control capture and real callback dispatch. Production code must not expose special test-only controls.

## 2. Host preflight, supported devices, isolation

- Windows / PowerShell 7; Lua 5.1-compatible tool; Renoise 3.5.4 / pinned scripting API 6.2; verified release-equivalent development tool. Record source SHA, Renoise/API version, plugin names/paths, device routes, source seed, runner PID, input/fixture hash and report paths.
- The runner **owns a newly created disposable song and Renoise process**. Refuse reuse of a user song, unexpected existing phrase state, unrecoverable backups, unresolved blockers, another open ACID session, unsupported transport timing, missing capacity, unrecognized receiver capabilities or any uncontrolled keyboard/focus state.
- 8x8 requires 3 sample, 3 **actually loaded VST**, 2 **actual MIDI-only** instruments. 16x8 requires 6 sample, 6 loaded VST, 4 MIDI-only. Samplers get deterministically generated short waveforms. VSTs must load successfully from the host registry; prefer two supported plugin identities when installed, and report missing diversity rather than inventing it.
- MIDI-only targets must use a verified device or virtual loopback with an observable MIDI event trace. Declaring a mock `midi=true` is not receiver acceptance. If no route/capture is available, mark MIDI playback **BLOCKED**, not PASS. A receiver's exact portamento/timbre is external behavior; verify ACID's routed note/OFF/PB events and separately document any audible manual observations.
- Set up real Renoise pattern/track notes and phrase-program triggers, not merely a transport that plays an empty arrangement. Record instrument routing and phrase-trigger mode; do not change transport/phrase-program settings as an accidental ACID side effect.
- Use the existing identified-process, verified installation backup/restore and dev-bundle package checks. Cold acceptance requires completely stopping the runner-owned process, starting a fresh Renoise process and reopening the same saved XRNS. Existing `-ColdProcessRoundTrip` currently accepts only `make-independent`: extending it for these cases requires explicit argument validation and runner regression coverage. Do not use same-process reload as cold evidence.

## 3. Fixed heterogeneous fixtures (deterministic seed, no random timing)

| Mode | Instruments | 8 owned/instrument | 1 foreign/instrument | Total native phrase count | Playing tracks |
| --- | ---: | ---: | ---: | ---: | ---: |
| `production-session-8x8` | 8 | 64 | 8 | 72 | 8 |
| `production-stress-16x8` | 16 | 128 | 16 | 144 | 16 |

Include one foreign, named, non-ACID phrase per instrument with nonempty note/effect content and supported column/mapping/hidden-or-inactive metadata sentinels. Do not target it. Include two separate owned phrases with identical musical content but different native identities/source IDs. For every owned phrase retain immutable expected source values for **all 32 TIME and 32 PITCH entries**, including inactive memory, as well as output policy and PB Range. Derive different keys, octaves, accents, slides, timing and output policy from fixed seed + instrument/phrase indices; record the resolved inputs in the report. No source is built by copying the *actual generated native destination*.

| Phrase slot | LAST STEP | PITCH span | Mandatory content |
| --- | ---: | ---: | --- |
| 01 | 1 | 1 | Single NOTE, Play Once/final release |
| 02 | 2 | 3 | NOTE/REST, pitch span longer than notes consumed |
| 03 | 7 | 5 | NOTE/TIE/REST, independent pitch cycling |
| 04 | 15 | 4 | Accent, outgoing slide, adjacent notes |
| 05 | 16 | 16 | Mix of commands and a same-pitch legato/loop boundary |
| 06 | 17 | 8 | 16→17 page boundary, Triplet, inactive TIME retention |
| 07 | 31 | 13 | Long asymmetric span, consecutive rests and slides |
| 08 | 32 | 32 | Max length, mixed NOTE/TIE/REST, Repeat and Play Once |

Rotate Straight/Triplet and Repeat/Play Once across each receiver class so **all four combinations** occur in sampler, VST and MIDI. For eligible plugin/MIDI cases cover PB Range Off/2/12/24/48, already-centered vs center-reset fresh attacks and out-of-range fallback. Do not claim MIDI bends on sample-only instruments. Include explicit targeted cases for leading TIE normalized to NOTE, all REST, trailing TIE, trailing REST, multiple consecutive rests, a slide across the steady loop seam, and pitch span longer/shorter than NOTE consumption. Verify the source remains canonical. Contract boundaries: LAST STEP/PITCH span 1, 16, 17, 32; shrink and expand 32→16→17→32 with hidden TIME/PITCH values intact; 32-step Play Once 128 lines, Repeat 257 lines with loop start 129 and exclusive end 257; Straight LPB 16, Triplet LPB 12 and four phrase lines per source step.

Freeze independent expected output at fixture creation: canonical source, expected note/OFF/delay/effect fields, structural loop/LPB/visibility and preserved non-generated metadata. Compare native readback to this independently specified oracle and the existing test-only renderer where appropriate. **Writer result.status and ACID seal are insufficient.**

## 4. Full workflow — fixed phases and action counts

**P0 — Seed and prove routing.** With one real ACID window, create all 64/128 owned phrases using the production New/Generate GUI flow. Place/observe foreign sentinels in fixed positions. Verify each Create appends exactly one native object, changes one unique source revision, retains all peers and does not jump native selection. Start 8/16 track playback and prove transport progress, correct track assignments and actual phrase-trigger/event activity. One loaded plugin or MIDI route failure is a typed preflight failure, not a switch to a sample mock.

**P1 — 8x8 production use.** Execute **at least 128 successful regenerations**, two per owned phrase, half Live Edit and half explicit Generate. Switch nonlocally (for example A/P07 → B/P03 → H/P08 → A/P07 → MIDI/P06) and edit LAST STEP, pitch span, TIME N/T/R, pitch, octave, accent, slide, Straight/Triplet, Repeat/Play Once and eligible PB Range. At each hop confirm GUI rehydrates the selected target's *own* source and settings, and no navigation/arming/preview/no-op action renders. Dirty A with Live Edit off must survive A→B→C→A. Exercise occupied New scratch, recovery chooser/copy/discard without generation. Execute **one additional explicit New/Create** and record it separately from the 64 base phrases.

**P2 — 16x8 stress.** Same parameterized implementation, **at least 512 successful regenerations** (four per owned phrase), at least 128 cross-instrument switches, both manual and Live Edit, 8/16/17/32 boundaries, first/middle/last phrase selection and repeated source revisions per phrase. Keep the 16 tracks active during edit phases. Verify that only successful musical writes add immutable source rows; navigation, arming, preview, rejected actions and no-ops add none. P2 starts only after the complete P1 functional and integrity journey passes.

**P3 — Native Undo/Redo, negative actions, recoverability.** In a genuine native user-action context, Undo/Redo manual Generate and Live Edit, including an interleaved edit to another phrase. At each settled state, verify exact native phrase cells/name, the associated immutable source/settings, ACID GUI source, current draft and unrelated user edit. Undo must not render. Reject foreign phrase, manually modified owned phrase, duplicate ID, deleted/moved target, missing source, capability drift and unsupported output without changing unrelated native state or drafts. Safely inject setter failure, partial write, post-commit failure, source restore failure and recovery-detach failure in focused Lua tests; native failure cases are counted only when actually exercised in Renoise. No blind rollback over a later edit and no discarded unsaved draft. If a blocker is incomplete, record exact no-auto-retry/recovery state.

**P4 — True cold save/reopen twice.** Save the *full* 8x8/16x8 song, record XRNS hash, close Renoise, start a new verified runner-owned process, load the exact file, open one new ACID window, and classify every phrase using fresh wrappers. Assert no edit on load/navigation; validate exact source, all 32 PITCH/TIME memory entries, LAST STEP, span, timing, output policy, PB Range, phrase object position/ordering, ownership, foreign sentinels and musical cells. Regenerate first/middle/last target in different receiver classes, save, close and reopen in **another fresh process**. Reverify source/phrase associations and negative source-less/modified/duplicate cases. Historical IDs must survive; old runtime epochs, tokens and GUI pointers must not.

**P5 — Actual receiver event/playback evidence.** Programmatically trigger a bounded representative set *from all three receiver classes* while the multitrack transport plays: NOTE→TIE, NOTE→REST, same-pitch legato, sample/VST slide, MIDI note/OFF/PB, one-shot final release, Straight/Triplet, Repeat cold→steady/steady→steady, 16/17 and 32-step seams. Compare independent expected events and observed phrase-program position. Use output-meter/audio-path observation for sampler/VST and captured loopback events for MIDI; record separate short operator listening evidence for any receiver-dependent glide quality. **Transport moving and pattern note assignments intact are not proof that phrases sounded or that MIDI was delivered.** No new audio engine, general WAV export harness, VST farm or broad acoustic research.

Run P0→P1→P3→P4→P5 for 8x8 and P0→P2→P3→P4→P5 for 16x8; correctness, integrity, cleanup and recovery failures stop either mode and preserve diagnostics; latency is recorded without stopping acceptance. Do not claim later phases passed because a partial report was written. Keep both sessions and at least one full repeat with the same input seed/source SHA to establish reproducibility, not success by changing the fixture.

## 5. Independent oracles and fast instrumentation

For each action capture a compact trace: phase, ordinal, instrument and phrase *native object* identities/indices before/after, ACID target and selected native target, source revision IDs, source/settings change, trigger type, writer status, dirty/pending state, native selection/phrase-list notifications, and callback CPU timing. The actual **native state** is authoritative, not the ACID success result. Assertions:

1. Regenerate preserves the precise destination object, list count/order and all unrelated phrase objects. Create adds exactly one explicit destination. No foreign phrase is written or removed. Content-equal distinct owned phrases remain distinct; no stale cached numeric index retargets.
2. Selected Renoise instrument/phrase does not change except real user navigation. ACID's destination follows its explicit control or supported native navigation and never changes another track's phrase program as a side effect.
3. Native music, including hidden/tail cells, column metadata/mutes, script/mapping state and loop/LPB/delays, matches the immutable expected output. Source row and PB/output setting belong to the exact new revision; older rows remain available for Undo. Unsupported metadata that cannot be preserved is *rejected before mutation*.
4. Dirty drafts survive navigation and native revision changes; only the matching committed draft revision clears. Undo/Redo restores coherent music/source/settings/GUI and does not regenerate. Blocker, Revalidate, save/reopen and copy outcomes preserve safety without automatic repairs.
5. Real playback/midi event evidence is distinct from transport liveness. A missing MIDI capture is BLOCKED, never inferred from native cell parity.

**Performance of the verifier is not product performance.** Do **not** snapshot all 128 phrases × 512 lines × 20 columns after every edit. At each action inspect native membership/identity/order, source-row counts and a rotating pair of independent peers/foreign sentinels, with native selection/list observers watching mutation windows. At fixed checkpoints (after initial seeding, every 16 edits, before save and on every cold reopen), inspect all phrases **one by one**, computing compact full-field digests or golden comparisons without retaining many expanded snapshot trees. Deep-check the edited phrase at boundary mutations and every negative failure; report slow oracle cost separately *outside* timed GUI callbacks. A final whole-song digest cannot excuse transient wrong-target writes: inspect native notifications and sampled peers during mutation too.

## 6. Latency and resource evidence

Record callback CPU and wall times, action counts, maximum and adequate-sample quantiles, separately for Generate, Live Edit and navigation. Record source rows, tool-data bytes, memory after GC and observer counts outside measured callbacks. Unexplained listener or retained-reference growth remains a blocker. Preserve recovery snapshots unchanged. No performance investigation, caching experiments, snapshot refactors or runtime optimization.

## 7. Implementation sequence, run commands and evidence

1. Re-run the **currently supported** `multi-instrument-workflow`, `editor-responsiveness`, revision Undo/Redo and cold-process tests on the same current commit; record their limits. They are prerequisites, not proof of 8x8.
2. Add deterministic profile fixtures and focused Lua tests for coverage (receiver/timing/policy, N/T/R, slide/seam, LAST STEP 1/16/17/32, source memory and distinct equal-content targets). Verify exact golden outputs independent of writer success.
3. Generalize **one dev-only** GUI driver to create/edit multiple phrases within a single dialog. Register two new acceptance case names in the existing Lua/Pwsh allowlists; add runner/packaging tests for the new test-only source and rejected combinations. Do not extend the read-only scenario JSON catalog; it cannot express musical writes.
4. Implement and pass 8x8 P0/P1/P3/P4/P5, before 16x8, recording latency without a ceiling. Fix only established correctness defects in their existing production owner with a failing focused regression first.
5. Parameterize and pass 16x8 P0/P2/P3/P4/P5, adding bounded phase-specific timeouts and safe continuation across runner-owned fresh processes. Do not globally remove timeouts or allow indefinite idle polling.
6. Run all targeted Native cases, full ACID/repository Lua suites, all 18 offline groups, release-equivalent dev/release package identity/exclusion checks and independent assertion-level review. Check no new production entry points, dependency cycle, persisted format/version or adapters.

**Production GUI cases:**

~~~powershell
./scripts/run_interactive_tests.ps1 -Suite Native -Install -ApproveDisposableSong -AcceptanceCase production-session-8x8 -MidiOutputDevice '<MIDI output>' -AudioInputDevice '<loopback audio input>' -TestEnvironment '<keyboard configuration>' -AllowKeyboardFocusActivation
./scripts/run_interactive_tests.ps1 -Suite Native -Install -ApproveDisposableSong -AcceptanceCase production-stress-16x8 -MidiOutputDevice '<MIDI output>' -AudioInputDevice '<loopback audio input>' -TestEnvironment '<keyboard configuration>' -AllowKeyboardFocusActivation
~~~

**Existing runnable prerequisite commands:**

~~~powershell
./scripts/run_interactive_tests.ps1 -Suite Native -Install -ApproveDisposableSong -AcceptanceCase multi-instrument-workflow
./scripts/run_interactive_tests.ps1 -Suite Native -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness
./scripts/run_tests.ps1 -Tool ACID
./scripts/run_tests.ps1
./scripts/package.ps1 -Tool ACID
~~~

Production cases request two runner-owned process restarts after native Undo/Redo passes. Undo/Redo that requires real user input must reuse the existing focus/PID-guarded Keyboard helper in its supported test environment, never uncontrolled global keystrokes. Phase timeouts must be finite, distinctly reported and preserve the existing deployment/restoration safety behavior.

Report under ignored `tmp/interactive-<run-id>/report.json` with source commit, receiver identities, fixture seed/table, phase statuses, exact action/revision counts, source/phrase/selection trace artifacts, expected-vs-actual native diffs, musical and MIDI/audio evidence type, undo state chain, multi-process PID/XRNS hash chain, max/stage latency, memory/history/observer deltas, package verification, cleanup/restoration outcome and first error. Never check in session tokens, machine-local MIDI config or a user song.

**Stop immediately** on unintended selection; wrong-target write; lost draft; changed foreign/unrelated native state; unexpected phrase deletion/insertion; incorrect NOTE/OFF/loop/policy; incomplete rollback or blocker; invalid source association after restart; incoherent native Undo/Redo; missing mandatory receiver evidence; unexpected listener growth; or failed restoration.  Isolate a failing regression and fix the responsible contract, then rerun affected phases. Gate 8 closure follows the accepted scope above; incomplete checks are not recorded as passes.
