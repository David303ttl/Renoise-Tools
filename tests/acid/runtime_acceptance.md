# Runtime integration acceptance map

M5 sections below are dated checkpoint records. Earlier statements that later
gates were pending describe those checkpoints, not the current implementation.
See [Gate 8 verification](#m5-gate-8-documentation-readiness-2026-11-02)
for current documentation readiness and remaining native acceptance.

## Integrated editor and Live Edit verification (2026-11-02)

| Check | Command / evidence | Result |
| --- | --- | --- |
| Host/build | Renoise 3.5.4 Demo / API 6.2; `3062241` plus working-tree changes | Disposable runner-owned processes; tested GUI SHA-256 `a90b9aca372ba9be029b351e4ff4b1736e0c25e7fbfe2f892ae821135669d333` matches working tree |
| Editor/Live Edit | `./scripts/run_interactive_tests.ps1 -Suite Native -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -RenoiseExe <renoise-executable>`; `tmp/interactive-41232a9c5dee44c78f63a2a355befa9b/report.json` | PASS; arming and armed navigation without writes, individual PITCH/octave/ACCENT/SLIDE/TIME/output commits, peer preservation, ACID musical Undo/Redo, label-only history without rendering, disarmed edit/manual regeneration |
| Musical history regression | `acid_gui_views_spec.lua`; native editor report above; failing diagnostic `tmp/interactive-6d3c7f8ffc1e48ceb6962224aa5105bc/report.json` | PASS after correction; musical Undo/Redo flushes its pending Live Edit request synchronously; each action dispatches once. Label-only path remains separate |
| Inactive scope storage | Same editor report; TIME 7 / PITCH 5; all ten operations in both scopes | PASS; Apply/Undo/Redo compare editor and durable drafts; independent bounds, unrelated-memory and inactive-slot checks; fixture restored |
| Cold owned/New drafts | `-AcceptanceCase recovery-labels-prepare`; `tmp/interactive-f558a46093e242b7a6fbd887583a6798/report.json` | PASS; fresh-process exact committed source/settings, owned and New dirty PITCH/TIME/mask/settings/labels; restore without generation; explicit New recovery generation preserves owned draft |
| Multi-instrument workflow | `-AcceptanceCase multi-instrument-workflow`; `tmp/interactive-99cd9e22422b40e4b28cfd110b2dc058/report.json` | PASS; scoped native multi-target workflow and fixture preservation |
| Persistence faults | `-AcceptanceCase persistence-failures`; `tmp/interactive-a67b2a9819334e4c91121103b3292311/report.json` | PASS; synthetic setter failures over native storage, exact bytes/cache/phrase preimages, independent integrity blocker and explicit revalidation |
| Writer recovery | `-AcceptanceCase writer-recovery`; `tmp/interactive-4948ba5e59dc43c78a11c69e84679e95/report.json` | PASS; native transactional recovery assertions |
| Ownership rejection | `-AcceptanceCase ownership-negatives`; `tmp/interactive-8b03ebea50b544308051aca46afb9c5b/report.json` | PASS; scoped incompatible/foreign/colliding/source-less target protection |
| Independent identity/cold reopen | `-AcceptanceCase make-independent -ColdProcessRoundTrip`; `tmp/interactive-2d454e2e152c4ccc9a6e02f42a0bd04d/report.json` | PASS; fresh-process identity/source/output checks |
| Lifecycle/observers | `-AcceptanceCase integrity-observers`; `tmp/interactive-22390fd846c14025b8357edd7438d813/report.json` | PASS; scoped native close/reopen/document and observer cleanup checks |
| Native musical Undo/Redo | `-AcceptanceCase revision-undo` and `revision-live-undo` with keyboard environment/focus activation; `tmp/interactive-6c3b085e4cbd4eae928a795c6626d29c/report.json`, `tmp/interactive-d3df2950dc404938ac91b9fe0aada384/report.json` | PASS on final GUI; real user-action callbacks and native Undo/Redo with Live Edit off/on |
| Native + Keyboard suite | `./scripts/run_interactive_tests.ps1 -Suite All -Install -ApproveDisposableSong -TestEnvironment <keyboard-environment.json> -AllowKeyboardFocusActivation`; `tmp/interactive-710cb720a48c493abd6aa262d4c10e23/report.json` | PASS; transport, phrase inventory/expected diff, actual ACID shortcut/open/close and native instrument navigation. This keyboard journey does not cover every editor/modal key |
| Metadata recovery | `-AcceptanceCase metadata-recovery -TestEnvironment <keyboard-environment.json> -AllowKeyboardFocusActivation`; `tmp/interactive-2d6bbc5c82e04cd095b5b22b8632074f/report.json` | PASS; guarded real Enter action, exact metadata/recovery checks and automatic cold reopen |
| Native metadata Undo diagnostic | `-AcceptanceCase metadata-undo`; `tmp/interactive-0437668c94704c87b2bf22f5d9399889/report.json`; real-action `describe_undo` probe `tmp/interactive-49a13aebbe15490ba7474d814ac58aba/report.json` | FAIL; rename persists exactly but Renoise exposes no native Undo state. Explicit description did not create one. Temporary probe removed; no dummy musical mutation or weakened assertion |
| Independent second pass | Separate reviewers of live history dispatch, native scope invariants, cold source/label contracts and regression assertions | PASS; focused Lua specs and native reruns support corrected behavior |
| Final repository regression | `./scripts/run_tests.ps1 -Tool All -LuaCommand <lua-5.1-executable>`; `tmp/gate8-final-all-regression.log` | PASS; 80 specs, 0 failed; Lua 5.1.5 |
| Packages/diff/isolation | `./tests/renoise/test_package_dev.ps1 -LuaCommand <lua-5.1-executable>`; `./scripts/package.ps1 -Tool ACID`; `git diff --check`; `tmp/gate8-final-dev-package.log`, `tmp/gate8-final-release-package.log` | PASS; 32 release files, root entrypoints/private modules present, exact GUI hash, SDK/tests/development files excluded. All 12 functional interactive reports verify installation restoration; pre-existing Renoise process remains running |
| Remaining manual acceptance | Playbook 13.1–13.8 and `acid_live_edit_manual.md` | UNVERIFIED for human-operated modal journeys, visual/acoustic judgment, full live GUI negative-target and fault/Retry matrix, exhaustive phrase-cell/receiver inspection and native arrangement/transposition/resizing. Functional passes above do not establish all seven manual steps or Gate 11 complete |

## M5 Gate 8 Documentation readiness (2026-11-02)

| Check | Command / evidence | Result |
| --- | --- | --- |
| Documentation | Root/tool README, DESIGN, ROADMAP, tests README and existing ACID manual procedures; Playbook section 13 | Updated delivered editor, schema-2, operations and persistence descriptions; native procedure routing and evidence fields prepared |
| Modal admission | `acid_gui_views_spec.lua`; `gui.lua` operation admission | PASS; staging or opening the label editor during confirmation rejects the operation without source writes, rendering or history changes |
| Lua regression | `./scripts/run_tests.ps1 -Tool ACID -LuaCommand <lua-5.1-executable>`; `tmp/gate8-acid-regression.log` | PASS; 77 specs, 0 failed; Lua 5.1.5 |
| SDK | `./scripts/setup_sdk.ps1` | PASS; pinned API 6.2 installation verified; no API calls changed |
| Independent second pass | Rotated runtime and documentation reviewers; focused GUI spec rerun; `git diff --check` | PASS; modal guard reviewed independently; procedure anchors, control names and observable Active-scope fixture corrected |
| Native acceptance | [Integrated editor verification](#integrated-editor-and-live-edit-verification-2026-11-02) | Targeted native functional checks executed separately; complete final integrated manual acceptance remains UNVERIFIED |
| Packaging | Runtime layout unchanged | Documentation readiness did not require packaging; subsequent native verification builds release/development packages separately |

## Interactive persistence acceptance (2026-11-02)

| Check | Command / evidence | Observed result |
| --- | --- | --- |
| Native storage failure injection | `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase persistence-failures -RenoiseExe <renoise-executable>`; `tmp/interactive-b32c8a272c0f45e5b5ccefa4f2859894/report.json` | PASS; before-write failure, mutate/throw rollback, unexpected third bytes, exact cache/native phrase preservation and explicit revalidation before writes resume |
| Cold recovery | Same command with `-AcceptanceCase recovery-labels-prepare`; `tmp/interactive-bc4d5b8b3d454e4581d14f6842ade6ce/report.json` | PASS; process 14780 stopped, process 17000 opened saved XRNS; exact committed source and detached New draft/mask/settings/label restored read-only; recovery copy and real writer generation verified |
| Native metadata undo | `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase metadata-undo -TestEnvironment <keyboard-environment.json> -AllowKeyboardFocusActivation`; `tmp/interactive-7b97248e7ac249f2babef022c4ffa921/report.json` | FAIL; real Enter callback renamed label exactly without musical changes, but `song:can_undo()` returned false; no native undo entry for metadata-only persistence; redo not reached |
| Musical native undo/redo | Same keyboard-enabled command with `-AcceptanceCase revision-undo`; `tmp/interactive-11425cf82f1240b7bc6477de1424bda3/report.json` | PASS; one-step Undo/Redo and GUI source restoration |
| Host and isolation | All four reports | Renoise 3.5.4 Demo / API 6.2; disposable songs; original tool installations restored, including failed metadata-undo run |
| Injection boundary | `tests/renoise/driver/persistence_acceptance.lua` | Synthetic Lua setter faults forward to native song storage; not an actual disk failure or human-operated modal test |
| Full Lua regression | `./scripts/run_tests.ps1 -Tool All -LuaCommand <lua-5.1-executable>`; `tmp/interactive-persistence-regression.log` | PASS; 76 specs, 0 failed |
| Runner and package | `tests/renoise/runner_spec.ps1`, `tests/renoise/test_package_dev.ps1`, `./scripts/package.ps1 -Tool ACID` | PASS; cold selected-PID rejection, fixed case/module allowlists, six development-module hashes/syntax checks, 32 release runtime files; manifest unchanged |
| Independent second pass | Separate module, runner and final reviewers | No remaining test implementation findings; native metadata undo remains a measured failure |
| API references | Pinned API 6.2 definitions and offline docs for `Song` undo/redo/selection, `Instrument` name/phrase insertion and `Application.save_song_as` | Verified; development-only modules excluded from release package |

## Persistence review verification (2026-11-02)

| Check | Evidence | Result |
| --- | --- | --- |
| Failed metadata writes | `acid_store_candidate_spec.lua`, `acid_pattern_store_codec_spec.lua`: rejected owned-label/draft writes, pending New labels, exact readback and unrelated successful writes | PASS; rejected metadata cannot contaminate decoded cache or later persistence |
| Canonical pitch wire values | Codec spec: noncanonical note/key/octave integers in SOURCE and DRAFT records | PASS; malformed bytes rejected and preserved |
| Recovery labels | Editor and runtime writer integration specs: custom-label recovery copy, source edit, real writer create and persisted metadata | PASS; source, label/custom and editor agree |
| Uncertain label persistence | Runtime editor spec: real store setter produces unexpected bytes; verified unchanged failures, persistence exceptions, blocked draft/label/generation/recovery writes and dirty target changes | PASS; accepted metadata retained; exact-state proof plus explicit revalidation required |
| Independent second pass | Separate store, recovery and integrity reviewers; focused codec/candidate/editor/draft/request/integrity/writer specs | PASS; failure-injection reachability and draft-write admission findings corrected and rechecked |
| Full regression | `./scripts/run_tests.ps1 -Tool All -LuaCommand <lua-5.1-executable>`; `tmp/persistence-review-regression.log` | PASS; 76 specs, 0 failed |
| Native functional regression | Renoise 3.5.4 Demo / API 6.2; `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -RenoiseExe <renoise-executable>`; `tmp/interactive-3b55dacf7ea743d09e38f855d70ae10b/report.json` | PASS; Program/Grid, staging, audition, draft/generation isolation and fixture restoration; original installation restored |
| Tested build and package | Native bundle SHA-256 comparison for GUI, audition, store, context and draft cache; `./scripts/package.ps1 -Tool ACID` | PASS; tested runtime matches working tree; 32 runtime files; manifest unchanged |
| Interactive persistence checks | [Interactive acceptance](#interactive-persistence-acceptance-2026-11-02) | Failure injection, cold recovery and musical Undo/Redo PASS; metadata-only native undo FAIL; human-operated modal checks remain unverified |

## M5 Gate 7 Extended operations and Decoded (2026-11-02)

| Check | Evidence | Result |
| --- | --- | --- |
| Lua regression | `./scripts/run_tests.ps1 -LuaCommand <lua-5.1-executable>`; `tmp/gate7-verified-regression.log` | PASS; 80 repository specs, 0 failed; Lua 5.1.5 |
| Source operations | `acid_source_operations_spec.lua` | PASS; all transforms and RNG in Active/All scope, inactive storage, exact seed vectors, T01 normalization, canonical controls, mask/flags, output-policy invariance, no-op, undo/redo and draft roundtrip |
| GUI admission | `acid_gui_views_spec.lua`, `acid_program_staging_spec.lua`, admission/recovery/timing specs | PASS; invalid parameters before confirmation, cancel, disabled-mask edits, Reset, stage guards, stale source/target and edit-undo revision rejection at both modal boundaries |
| Decoded | `acid_editor_spec.lua`, GUI paging specs | PASS; detached raw/resolved values, held flags, explicit transitions, compiler agreement and four-row paging |
| Independent second pass | Rotated model, GUI and integration reviewers; focused reruns | PASS; no remaining blockers |
| Native functional checks | Renoise 3.5.4 Demo / API 6.2; `tmp/interactive-860f572732834bc38f53d56533ee274a/report.json` | PASS; ten operations × two scopes, cancel/no-op, undo/redo, mask rejection and Reset; prompt responses simulated |
| Native isolation | Same report | PASS; exact store, phrase inventory, native selection and original installation restored |
| Tested runtime | SHA-256 comparison against native development bundle | PASS; GUI, sequencer and editor state match working tree |
| Manual acceptance | Operator report in chat | PASS; visual, keyboard and acoustic acceptance |
| Package | `./scripts/package.ps1 -Tool ACID`; `tmp/gate7-package.log`; `git diff --check` | PASS; 32 runtime files; manifest unchanged |
| Remaining native acceptance | Final integrated Gate 11 and remaining Playbook 13 checks | UNVERIFIED; final-build visual recheck, detailed native playback/lifecycle and other unexecuted procedures |

## M5 Gate 6 Clipboard, labels and duplicate (2026-11-02)

| Check | Command / evidence | Result |
| --- | --- | --- |
| Lua regression | `./scripts/run_tests.ps1 -LuaCommand <lua-5.1-executable>`; `tmp/gate-operations-regression.log` | PASS; 79 specs, 0 failed; Lua 5.1.5 |
| Auxiliary offline checks | `tmp/gate-operations-offline.log`; `tmp/gate-operations-interpreter.log` | PASS; 16 auxiliary groups and isolated interpreter policy; interpreter wrapper uses an ASCII executable path |
| Clipboard | `acid_clipboard_spec.lua`, `acid_program_staging_spec.lua` | PASS; exact detached 32-slot payloads, exclusions, malformed rejection, no-op, stage guards, session retention and authorized New paste |
| Labels | `acid_gui_views_spec.lua`, `acid_runtime_editor_spec.lua`, `acid_store_candidate_spec.lua` | PASS; accepted/attempted state, Retry/Discard, transactional history, exact rollback, stale draft/revision guards and owned/New persistence |
| Duplicate | `acid_duplicate_label_spec.lua`, `acid_runtime_writer_integration_spec.lua` | PASS; committed-source authorization, exact dirty-draft preservation, suffix/custom metadata, four boundary checks, allocation/insertion/materialization/store/verification failures, rollback blockers and stale target/source/label completion |
| Independent second pass | Rotated clipboard, label, duplicate and final reviewers | PASS; final focused suites and diff check; no remaining blockers |
| Native functional checks | `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -TestEnvironment <keyboard-environment.json>`; `tmp/interactive-894d89b53192460a8096aaf9ff50a967/report.json` | PASS; Renoise 3.5.4 Demo / API 6.2; clipboard, repeated label dialog, ACID label Undo/Redo, invalid-label rejection, committed-source duplicate, exact original draft token/revision and reselection |
| Native cleanup | Same native report | PASS; fixture phrase inventory, exact tool-data bytes, native selection and original installation restored |
| Package | `./scripts/package.ps1 -Tool ACID` | PASS; 32 runtime files; manifest version unchanged |
| Remaining native acceptance | Playbook 13.4 and final integrated Gate 11 | UNVERIFIED; human visual/keyboard journey, exhaustive native failure boundaries and native metadata Undo/Redo; acoustic acceptance unchanged |

## M5 Gate 5 Audition (2026-11-02)

| Check | Evidence | Result |
| --- | --- | --- |
| Identity and lifecycle | `acid_audition_lifecycle_spec.lua`: fresh indices, non-send tracks, replacement/removal, selection changes, document lifecycle, one-shot timer, onset/release faults, registration/detach faults, reentrant calls and captured-song garbage collection | PASS; removed identities never redirect release to replacement objects |
| GUI integration | `acid_program_staging_spec.lua`: canonical masked and detached candidate resolution, no source/history/draft/render effects, TIME disabled, navigation/guard/modal release matrix, cleanup diagnostics, close/document/unload | PASS |
| Baseline | `./scripts/run_tests.ps1 -Tool ACID -LuaCommand <lua-5.1-executable>` | PASS; 72 specs, 0 failed |
| ACID regression and second pass | Same command; `tmp/gate5-acid-first.log`, `tmp/gate5-acid-second.log`; independent lifecycle, GUI and final reviewers | PASS; 73 specs, 0 failed; focused regressions passed after review corrections |
| Broader offline checks | `./scripts/run_offline_tests.ps1 -LuaCommand <lua-5.1-executable>`; `tmp/gate5-offline.log` | PASS; 18 groups, including 76 Lua specs; explicit ASCII short executable path avoids interpreter-wrapper path encoding issues |
| Native functional audition | Renoise 3.5.4 Demo / API 6.2; `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -RenoiseExe <renoise-executable>`; `tmp/interactive-97aa0b6635384bca8ab59b6073dcd9bc/report.json` | PASS; real note-on/off, canonical/candidate selection, second audition, navigation/modal release, TIME disabled and read-only state |
| Native isolation | Same report; disposable runner-owned process and fixture | PASS; store, phrase inventory, native selection and original tool installation restored |
| Tested build identity | Native development bundle versus working-tree `gui.lua` and `runtime/audition.lua` | PASS; exact SHA-256 matches |
| Native harness correction | `tmp/interactive-70cc9adc2ab7478886b96e44141148f9/report.json` | Initial FAIL: marker test repeated the pitch already set by audition setup; changed test to a distinct pitch, rerun passed; fixture/store/inventory restored |
| API references | `./scripts/setup_sdk.ps1`; API 6.2 `definitions/library/renoise/song.lua`: selected-object/list observables and `trigger_instrument_note_on/off`; `definitions/library/renoise/tool.lua`: `add_timer`, `has_timer`, `remove_timer`; `definitions/library/renoise/song/track.lua`: track constants; offline `docs/API/renoise/renoise.Song.html` and `renoise.ScriptingTool.html` | Verified; GUI-thread preview, send-track exclusion and workload/modal timer restrictions retained |
| Package | `./scripts/package.ps1 -Tool ACID`; archive inspection | PASS; 32 runtime files, root manifest/main, `runtime/audition.lua` included, SDK/tests/development files excluded; manifest unchanged |
| Native limits | Procedure 13.6; operator report recorded in Gate 7 evidence | Acoustic acceptance reported PASS; release timing under load, real modal suppression, native object removal, manual lifecycle and final integrated outcome-view sizing remain unverified |


## M5 Gate 4 Program staging (2026-11-02)

**Disposition:** implementation and deterministic second-pass verification PASS.
Gates 5–12 remain pending. Revision: `5ccaa982` plus this working tree.

| Check | Evidence | Result |
| --- | --- | --- |
| Detached entry and Finish | `acid_program_staging_spec.lua`: PITCH/TIME initialization, flags, inactive storage, entered markers, final-position entry, marker invalidation, navigation, normalization, equal-source Finish, one-edit Finish and failed-save recovery | PASS; no candidate history, draft or writer effects before Finish |
| Admission | Same spec: complete/incomplete decision matrix for existing source/settings/history/target/generation controls, direct incomplete Finish rejection, explicit reinvocation, canonical Grid and disabled edits | PASS; no guarded-action replay |
| Origin and recovery | Same spec: runtime/history revision drift, native selection, deletion, ownership loss, close, document release/new-document notifications, failed origin save | PASS; no replacement-target commit or native selection reversal; canonical recovery retained |
| Check | Same spec: canonical/candidate diagnostics, missing markers, coordinate-free and bounded coordinate navigation, stale-origin rejection | PASS; read-only |
| Resolved keyboard | Same spec: alternate key-12 encodings, C+ endpoint, scale mask, candidate Program and canonical Grid | PASS; shared prepared records drive highlights; raw controls preserved |
| Final ACID regression | `./scripts/run_tests.ps1 -Tool ACID -LuaCommand <lua-5.1-executable>`; `tmp/gate4-acid-final.log` | PASS; 72 specs, 0 failed, exit 0 |
| Broader offline checks | `./scripts/run_offline_tests.ps1 -LuaCommand <lua-5.1-executable>`; `tmp/gate4-offline.log` | 17 groups passed; interpreter-policy wrapper failed with the non-ASCII executable path; repository Lua selection passed 75 specs |
| Interpreter-policy recheck | `./tests/lua_interpreter_spec.ps1 -LuaCommand <short-ascii-lua-5.1-executable>`; `tmp/gate4-lua-policy.log` | PASS, exit 0; all 18 offline groups passed across the run and isolated recheck |
| Independent second pass | Separate contract, implementation and final diagnostic reviewers; focused staging/GUI/editor/draft/request checks | PASS; cursor coherence, discard reporting and diagnostic findings corrected and rechecked |
| Native functional entry | Renoise 3.5.4 Demo / API 6.2; `./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase editor-responsiveness -RenoiseExe <renoise-executable>`; `tmp/interactive-2a94cd3870954c279a4c06e69d16712e/report.json` | PASS; real widgets, exact song-data/draft/phrase isolation, marker completion/invalidation, Stay/Discard, TIME Finish and one Undo |
| Native isolation | Same native report: disposable runner-owned process, fixture inventory/store/selection and original installation restoration | PASS |
| Interactive Native + Keyboard | `./scripts/run_interactive_tests.ps1 -Suite All -Install -ApproveDisposableSong -AllowKeyboardFocusActivation -TestEnvironment <local-keyboard-environment.json>`; `tmp/interactive-4eec55c7fd2843879f5ccc8d2db6e43d/report.json` | PASS; Ctrl+Alt+B opens ACID, Escape closes it, Alt+Down changes instrument 1 to 2; native scenarios and keyboard guards pass |
| Tested build identity | Both interactive bundles compared with working-tree `gui.lua` | Exact SHA-256 matches; Renoise 3.5.4 Demo / API 6.2; original installations restored |
| Native limits | Prompt responses scripted through test-only application facade; procedure 13.2 manual modal/focus, external lifecycle, visual fit and complete manual workflow | UNVERIFIED; functional harness does not establish manual or final integrated acceptance |
| SDK | `./scripts/setup_sdk.ps1`; API 6.2 `definitions/library/renoise/application.lua` and offline `docs/API/renoise/renoise.Application.html` prompt contract | Verified; SDK excluded from runtime |
| Package | `./scripts/package.ps1 -Tool ACID`; archive root and development-file exclusion checks | PASS; 31 runtime files, root manifest/main; manifest unchanged |
| Test environment | Two `lua.exe` installations on PATH | Explicit Lua 5.1 executable selected |

## M5 Gate 0 audit (2026-11-01)

**Scope:** baseline, pinned SDK facts and call-site inventory only. No runtime,
source schema, manifest, package inputs or M4 acceptance claims changed. Gates
1+2 and all later implementation/native acceptance remain pending. This record
implements the audit required by `com.david303ttl.ACID.xrnx/M5_EDITOR_PLAYBOOK.md`
section 11; it does not claim that new M5 assertions already pass.

### Checkout and executed baseline

- Audited revision: `9d23f3123f73a45dae35e5de80fab9cb908d2df0`, branch
  `feature/M5`. Initial `git status --short`, `git diff`, and
  `git diff --cached` were empty, including untracked-file status.
- Executed `pwsh -File ./scripts/run_tests.ps1 -Tool ACID`: **70 specs passed,
  0 failed**, 74.74 seconds; Lua 5.1 via the installed Lua command wrapper.
  Each spec ran in its own process. No unrelated baseline failure was found.
- Executed `git branch --show-current`, `git rev-parse HEAD` and
  `git log -10 --oneline`. Recent commit receipt, newest first:

```text
9d23f31 docs(acid): specify prepared resolution and stage edit contracts
02d2575 docs(acid): add normative m5 editor implementation spec
2d5fc43 Merge branch 'feature/M4' into develop
ef5aca1 Merge branch 'feature/hardening4' into feature/M4
dbf2417 docs(acid): finalize M4.7 acceptance guidance
8440f8d docs(acid): close M4 with scoped acceptance
2258920 feat(acid): complete 8x8 production-session acceptance
06b20b3 test(renoise): stage latency diagnostics by inventory and history
47d478e test(renoise): add populated-song latency diagnostics
b93becf perf(acid): reduce materialization allocations and guard rollback
```

- `git ls-files sdk build tmp` returned no tracked paths;
  `git status --short --ignored sdk build tmp` reported ignored `sdk/` and
  `tmp/`. `git check-ignore sdk tmp` confirmed both exclusions. Baseline test
  artifacts remain ignored. No runtime-layout/package-input change requires a
  package build for this audit.

### Pinned SDK facts

The SDK subagent executed `pwsh -File ./scripts/setup_sdk.ps1`; the existing
installation verified successfully without download/replacement. The script's
API-6.2 asset pin is at `scripts/setup_sdk.ps1:23-24`, SHA-256
`575d6447dc1f2b3746fbf123df08f262abc027e04a5139caf892d7ce9189c49f`.
The installed marker matches; the setup script verifies required files and
recorded file hashes before accepting the installation. The SDK is ignored by
`.gitignore:26`, not bundled runtime code.

All definition paths below are relative to `sdk/renoise-api-6.2/definitions/`;
offline documentation paths are relative to `sdk/renoise-api-6.2/docs/API/`.

| API fact | Verified definitions and offline documentation | Restriction / implementation consequence |
| --- | --- | --- |
| `renoise.Song:trigger_instrument_note_on(instrument_index, track_index, note, volume)` | `library/renoise/song.lua:505-519`; `renoise/renoise.Song.html:1028-1035` | Integer instrument/track indices; optional integer or integer-array note 0..119 (default 48), volume 0..1 (default 1). GUI-thread preview only, not a sequencer or real-time clock. Send-track requests play on master instead; audition must reject send/master and require a captured sequencer track. Source legality remains 24..60, independently of host note range. |
| `renoise.Song:trigger_instrument_note_off(instrument_index, track_index, note)` | `library/renoise/song.lua:521-525`; `renoise/renoise.Song.html:1036-1040` | Optional integer or integer-array note 0..119 (default 48); releases notes started with note-on. Capture exact note and object identities; re-find current indices only for those same surviving objects. No replacement-object release. |
| `renoise.ScriptingTool:add_timer(timer, interval_in_ms)`, `remove_timer(timer)`, `has_timer(timer)` | `library/renoise/tool.lua:360-392`; `renoise/renoise.ScriptingTool.html:524-537` | Function or method/context callback, interval greater than zero. Idle-driven, workload-dependent, suppressed by modal dialogs. Approximate rounding is not a 120 ms duration guarantee. Remove/check the exact callback identity. |
| Track identity/type | `library/renoise/song/track.lua:46-50,88-98`; `library/renoise/song.lua:122-125`; `renoise/renoise.Song.html:1028-1040` | `Track.type` is read-only; normal playback track count excludes send/master. The preview method documents send-to-master fallback explicitly. Validate type and membership, not a former numeric index. |
| Document release/new | `library/renoise/tool.lua:53-63`; `renoise/renoise.ScriptingTool.html:383-395`; `library/renoise.lua:36-43` | Release fires while old song is still accessible, also before exit. New fires after create/load and on auto-reload. Song accessor identity changes: do not cache a song globally across documents. |
| Tool load/unload and idle | `library/renoise/tool.lua:24-34,45-51`; `renoise/renoise.ScriptingTool.html:350-361,374-381` | Finished loading may precede a song; will-unload is cleanup boundary. Idle is workload-dependent (roughly ten callbacks/sec), not an exact timing source. |

No unresolved declaration/signature fact was found for the planned preview API.
Object disappearance, best-effort release, actual sound and timer duration still
require Gate 5 deterministic tests and section 13.6 native checks. No Renoise
host check was executed for this audit, and earlier host receipts do not validate
the future editor.

### Source, carrier and render call-site inventory

Paths in this inventory are relative to `com.david303ttl.ACID.xrnx/` unless
prefixed with `tests/` or `scripts/`. Line references identify the audited base
revision, not a promise that subsequent edits preserve line numbers.

| Responsibility | Current owner / call sites | Required atomic cutover coverage (not implemented) |
| --- | --- | --- |
| Source construction, validation, copying, equality | `model/sequencer.lua`: `SOURCE_FIELDS:9`, `new_pattern:25-39`, pitch guards `87-89,123-125`, `validate:99-152`, `copy_source:155-167`, `same_source:169-179` | Current five-field source becomes strict seven-field source; factory owns mask defaults, note domain becomes 24..60, copy/equality include mask even disabled. |
| Alternate fixtures / local copies | `tests/acid/pitch_fixture.lua:3-10`; `tests/acid/acid_repeat_integration_spec.lua:186-208` local source copier/equality; malformed literals in `acid_sequencer_spec.lua:30-33,48-50` and `acid_phrase_persistence_spec.lua:184-185` | Update valid factories and local copy/equality; preserve intentional malformed-source rejection assertions. Do not repair bad values via decoder defaults. |
| Store codec and source/draft candidates | `renoise/pattern_store.lua`: magic `8`, `decode_source:79-101`, `encode_source:104-110`, entry/draft codecs `112-138`, `copy_entry:152-156`, draft read/write/copy `279-390`, candidate preparation `428+`, committed read `648-652` | Strict schema 2, raw source/mask and label/custom carriers, exact raw-store compare, rollback/candidate ownership; never serialize prepared provenance. Current decoder constructs from `new_pattern`, so new required wire fields must be explicitly checked rather than inherited silently. |
| History | `model/editor_state.lua`: `snapshot:112-115`, `new_history:117-145` | Detached complete source/settings/label snapshots; one history with proposed-cursor metadata transitions. |
| Draft cache | `runtime/draft_cache.lua:73-75,129-147,190-194,234-266,313-316,342-345,395-398,410-415` | Mask/label/custom copies and comparisons; exact revision identity; last-good preservation. Provenance is ephemeral, not a draft format. |
| Request capture/checkpoints/release | `runtime/requests.lua`: `VALUE_FIELDS:12-14`, value comparisons `37-64`, target baseline validation `129-152`, source capture `207-208`, baseline/value copies `229-250`, release `415-422` | Freeze complete source, records and relevant metadata; preserve private prepared provenance as identity, authenticate at checkpoints, release with request. |
| Baselines and associations | `runtime/inventory.lua:56-57,87-111,169-172,292-309`; `runtime/context.lua:1468-1480`; `writers/phrase_validator.lua:333-338,373-409`; writer checks `writers/phrase_writer.lua:201-206,591-596` | Raw source plus output/PB association includes mask. A separately rebuilt committed snapshot prepares once; it must not reuse a different source's bundle. |
| Decoded projection | `model/editor_state.lua:31-88`, `project` calls `compile_cycles(pattern,2)` | Consume runtime-owned prepared snapshot; Start/Repeating use its same resolved records. |
| Semantic cycle and loop | `model/cycle_interpreter.lua`: raw pitch/event/voice read `59-99`, `compile_cycle` / `compile_cycles:106-123`, `plan_loop:134-154` calls three cycles | Pass bundle to every cycle; resolved note/key/octave agree, raw flags/index and NOTE/TIE/REST consumption remain unchanged. |
| Output policy entry | `model/output_planner.lua`: `plan_output:13-55`, Play Once compile `28-32`, Repeat `plan_loop:34-35` | Both policies receive same prepared bundle, not a second quantizer. |
| Public and writer-private planning | `model/output_planner.lua`: `plan_internal` source copy `415-419`, policy plan `431`, control compile `433-435`; `plan` / `plan_for_materialization:529-539` | Propagate through existing shared implementation rather than introduce another planner API. |
| Physical control fallback and supplied-plan validation | `model/control_signals.lua`: `compile:81-100`, cold/successor fallback `92-98`, mandatory expected-successor recompile `111-117`, association capture `153-156`, `validate_association:57-72` | Same bundle in fallback and supplied-plan paths. Preserve successor recompilation and association rejection; no raw-only escape path. |
| Writer/materializer | `writers/phrase_writer.lua`: planner call `299-300`, source revision `318-320`, materialization `537-539`, postimage/source verification `580-596` | Request's prepared plan reaches sole materializer/transaction; committed source remains raw. |
| Ownership compatibility replan | `writers/phrase_validator.lua:373-409`, especially `planner.plan:389-409` | Standalone committed-source call prepares once; nested same-snapshot verification passes existing bundle. Trusted output still requires exact raw-source/settings association. |

### Resolution ownership decision

**Selected owner: `runtime.context`, per accepted editor source/edit revision.**
`model.sequencer.prepare_resolution` will issue/authenticate the detached bundle
and privately retain originals; it is not a global source cache. Runtime context
will supply the same issued snapshot to GUI projection and request capture.
Source/mask transitions replace it; read-only navigation does not resolve again.
Requests detach source/records as values while retaining the private issued
provenance identity through sequencer-owned validation/detachment, not through a
GUI-supplied token or generic deep copy. Exposed-source, exposed-record and paired
mutation, forged/replaced provenance and stale reuse must reject without a second
resolution. Release provenance with the projection/request/session lifetime.

The concrete transfer boundary is `runtime.requests` capture (`207-250`): obtain
the context-owned issued bundle, have the sequencer validate it against the exact
captured source, then use a sequencer-owned detached view retaining the original
private authority. Store that authority in the request owner's private record,
outside generic `VALUE_FIELDS` copying. At request checkpoints (`37-64,91-159`)
validate frozen source AND records against that retained authority and current
revision/source association. At writer preparation (`phrase_writer.lua:299-300`)
pass the authenticated detached bundle alongside `request.source` into the
existing planner. A copied table cannot confer authority; an independently
constructed or replaced token rejects. Musical source changes revoke requests
and replace the snapshot; release clears the retained authority. These are
Gates 1+2 implementation requirements, not claims about the current request code.

All vector consumers are enumerated above: projection, cycle(s), `plan_loop`,
`plan_output`, public/private planner, control fallback and successor validation,
writer preparation/materialization and source-associated compatibility rebuilds.
Independent top-level pure entry points may prepare once for their own immutable
snapshot; nested consumers must propagate it. Raw source remains the identity
for history, persistence and ownership. No vector/provenance is persisted.

The GUI cache at `gui.lua:268-281` currently keys `editor.project(pattern)` by
edit revision and instrument/phrase identity; invalidations occur at
`876-878,1051-1053,1227-1229`. It remains a presentation cache, not the shared
resolution owner. `runtime/transitions.lua:17-84` owns revision/request
invalidation. The eligibility/inventory caches at `runtime/context.lua:230-234`
and `runtime/inventory.lua:19-27,206-224` are not resolution caches. Audit every
source/mask transition against these invalidations in Gates 1+2; metadata-only
transitions must not invalidate musical projection or increment edit revision.

### Inventory search receipts

The source/render auditor searched production and test trees for
`new_pattern|copy_source|same_source|SOURCE_FIELDS|pitch_events\s*=|time_events\s*=`,
`source\s*=\s*\{`, local source-copy/equality definitions,
`compile_cycle|compile_cycles|plan_loop|plan_output|plan_for_materialization`,
`project|cache|invalidate|association`, `request.source`, `baseline.source` and
`planning_inputs`. Findings distinguish valid source construction from host
tables, output plans and intentional invalid fixtures. The complete-tree
second pass also checks generated scripts and native harness fixtures below.

The source auditor's initial SDK glob reported no files; that search result is
not an SDK absence finding. The dedicated SDK audit and independent SDK review
verified the installed, ignored SDK using its real paths and setup validator.

### GUI controls and admission inventory

| Current IDs / controls | Constructors, notifiers and behavior | Required replacement / disposition |
| --- | --- | --- |
| `acid_live_edit_state`, `acid_source_state`, `acid_source_diagnostic`, `acid_source_summary`, `acid_preview_summary` | `gui.lua:209-218` status/projection text | Retain persistent result/source status outside tabs; bounded decoded detail in workspace. |
| `acid_editor_view` | `gui.lua:224-231`, view-only notifier | Preserve read-only switching and stage lifetime. |
| `acid_timing`, `acid_pb_range` and un-ID'd output policy / PITCH span controls | `gui.lua:221-259,550-583` | Ordinary guarded source/output edits; no candidate bypass. |
| `acid_program_pitch_position`, `acid_program_time_position` | `gui.lua:589-596` position popups | Retire; independent numbered navigation/readouts. |
| `acid_program_time_command` | `gui.lua:597-604`, `sequencer.set_time` | Replace popup with explicit NOTE/TIE/REST assignment controls. |
| `acid_program_key_popup`, `acid_program_octave_popup`, `acid_program_accent`, `acid_program_slide` | `gui.lua:605-630` immediate pitch edits | Retire dropdowns, install twelve classes plus three octave controls and separate C+ endpoint. Flags preserve unrelated values. Current thirteen-entry key list at `151-152` is not the new keyboard contract. |
| `acid_program_pitch_summary`, `acid_program_time_summary` | `gui.lua:631-632` readouts | Exact raw note/key/octave, including alternate encodings; selected coordinates remain independent. |
| `acid_grid_pitch_XX` | `gui.lua:654-655`, current page PITCH selection buttons | Retain prefix only for unchanged selection role; two rows of eight per page. |
| `acid_grid_time_XX` | `gui.lua:661-671`, per-cell TIME assignment popups | Delete every old ID/notifier; new `acid_grid_select_time_XX` selection-only role, separate assignment buttons. No aliases. |
| `acid_live_edit` | `gui.lua:1002-1013`, arm/disarm only, no render on arm | Preserve existing render admission; add centralized stage guard before toggle. |
| Recovery IDs: `acid_recovery_detail`, `acid_independence_detail`, `acid_recovery_choice`, `acid_recovery_copy`, `acid_recovery_discard`, `acid_make_independent`, `acid_revalidate` | `gui.lua:1042-1107` | Retain recovery/ownership semantics, bounded/paged detail in Recovery tab; not a session clipboard implementation. |
| `acid_program_panel`, `acid_grid_panel` | `gui.lua:1138,1157` | Shared shell hierarchy, independent pages; Grid displays canonical source while staged. |
| Un-ID'd LAST STEP, page, Undo/Redo, reset, diagnostic, destination, Generate/Retry and sampler-audit controls | `gui.lua:530-583,638-701,797-939,1015-1037,1149-1222` | Update actual notifiers, not just named widgets; retain protected writer/runtime admission. |

`choose_pitch:488-504` currently changes TIME selection/page via consuming NOTE;
`choose_time:505-515` currently changes PITCH selection/page via projection.
Remove that coupling; keep the coordinate-specific diagnostic exception in
`navigate_diagnostic:517-529`. LAST STEP currently clamps TIME selection/page at
`685-695`; replace with retained read-only inactive selection. `preview_cycle`
notifier at `247-252` is already read-only. `preview_grid:635,672-684,1157-1166`
is permanently stacked content to remove in favor of bounded Decoded tab.

Reset at `1177-1182` currently replaces source with
`sequencer.new_pattern(last_step_box.value)`, resets cursors/pages and calls
`changed(false)`; factory wrapper `188-192` also resets output/PB. Replace with
the exact confirmed, single-history Reset contract preserving LAST STEP and
label/custom. There is no current Clear Memory, scoped transform, randomize,
Rename, clipboard or sequential-stage UI to preserve as a compatibility path.
Existing recovery copy/clear mechanics are not those operations.

Destination phrase loading is `749-801`, instrument switching `803-824`, native
host selection reconciliation `apply_pending_selected_phrase_selection:869-929`
and observer refresh `1225-1229`. ACID selectors need pre-action guards; native
changes are post-notification invalidation/discard, not reversible guarded
commands. Current custom dialog is at `1231`; explicit warnings are at
`90-105,172-206`. New focused dialogs/confirmations must release audition first.

`changed:530-549` records history, saves draft and flushes armed Live Edit.
Generate at `1203-1219` reconciles native selection, validates projection and
calls `runtime:request_generation("manual")`; retry is `1195-1201`.
`runtime/context.lua:585-741` enforces lifetime, editor validity, target match,
eligibility, writer occupancy, revision and authorization. Centralized stage
admission must wrap canonical mutations and render actions without bypassing
these checks. Stage-only edits, read-only Check/navigation and audition do not
enter `changed()`.

### Create routes and explicit duplicate feasibility

Production GUI dispatch is solely `gui.lua:708-724`: authorized `create` calls
`phrase_writer.create`, `regenerate` calls `phrase_writer.regenerate`, other
kinds reject. `runtime/requests.lua:232-235` currently derives kind from active
New/owned target; target verification is `91-109,133-147`.
`writers/phrase_writer.lua:243-290` requires New/no phrase for create and an
owned destination proof for regenerate. Its native insert is `504-508`; ID
allocation/preparation `306-339` and transaction/materialization/store commit/
postimage/rollback `487-601` remain the only production creation path.

Duplicate is feasible through this existing create transaction, but is **not
currently authorized**: extend request intent to retain exact verified committed
origin/source/settings/metadata while authorizing a distinct logical New
destination. Validate both identities at checkpoints; merely changing target or
setting `kind="create"` is insufficient. Derive custom duplicate label before
capture, preserve the dirty origin draft, and let the same writer allocate a new
ID. No GUI phrase API, second writer or new source store is needed.

Direct phrase insertion outside production is fixture/probe setup, not an
alternative release writer: `tests/renoise/driver/acceptance_cases.lua`
(`401-403,571-572,1186-1189,3777-3778`),
`tests/renoise/acid/probe/main.lua:222,308`, and
`tests/acid/renoise_loop_probe.lua`, `renoise_mixed_repeat_probe.lua`,
`renoise_articulation_probe.lua`. Preserve deliberate foreign/copy fixture
construction; actual tool output still uses the authorized production writer.

### Lifecycle and identity inventory

- `main.lua:5-22` registers menu/keybinding entry points only.
  `gui.lua:131-149` registers document release/new and tool unload callbacks.
  `release_context:87-106` warns on volatile drafts, detaches native/idle
  observers, releases/closes runtime, closes dialog and releases writer state.
- `gui.lua:1231-1265` uses a captured dialog/session idle watcher to detect
  invisible/closed dialog, detach watchers, disarm and close runtime; registration
  failure cleanup is `1266-1285`. `M.show:158-171` replaces stale watchers.
  Add stage discard and audition release to those existing cleanup boundaries.
- `runtime/context.lua:1896-2004` invalidates requests, detaches observers,
  releases draft/inventory/request references and lifetime state. New-document
  attachment releases old state first (`1988-2004`).
- `runtime/observers.lua:208-254` captures song/runtime/attachment serial and
  exact owner instrument/phrase objects; handlers reject stale captures.
  `detach:368-475` advances attachment serial and removes nested/root observers;
  `attach` rebuilds registrations. Extend these owners rather than create a
  parallel document lifecycle.
- Current production ACID has no note-on/off preview or timer. Stage must capture
  song/epoch/session/target revision/operation serial and exact origin objects;
  audition additionally captures exact sequencer-track object and note. Track
  membership/removal observers and exact timer cleanup are new Gate 5 work.
  Never treat a surviving numeric index as a surviving object. Modal, close,
  unload, release, external selection/ownership loss and retrigger release paths
  need deterministic tests and native uncertainty reporting.

The GUI/lifecycle auditor searched all ACID Lua for widget IDs/notifiers,
create/regenerate/phrase insertion, reset/clear/copy, dialog and preview paths,
document/observer/timer/note-trigger registration and cleanup, then searched test
owners. No second production phrase writer or audition cleanup path was found.

### Development producers and independent oracles

The independent second pass identified additional non-runtime inputs that must
not be missed by a production-only source search:

| Producer / oracle | Disposition for Gates 1+2 |
| --- | --- |
| `tests/acid/writer_request.lua:66-75,97-103`, `M.build` | Test-only detached request producer independently validates/plans today; update required source/prepared fields and authorization tests. It is not the production snapshot owner. |
| `tests/renoise/acceptance_cases_spec.lua:47-50` | Harness source construction; distinguish fake dependency-oracle values from real canonical sources, updating complete-source expectations when applicable. |
| `tests/renoise/driver/acceptance_cases.lua` | Native acceptance fixture producer uses `sequence.new_pattern`, `copy_source` and `same_source` as well as direct foreign/copy phrase setup. Update its real source/mask/label/schema payloads and persisted baseline expectations with Gates 1+2; do not classify the driver itself as only a reduced mock oracle. Native scripts generated from those fixtures must use complete sources. |
| `tests/renoise/persisted_baseline_spec.lua:11` | Intentionally reduced mock source for baseline drift oracle, not a production factory; ensure mask/metadata drift assertions cover new persisted values without silently legitimizing incomplete production sources. |
| `tests/renoise/acid/build_fixture.ps1:236-245` | Generated legacy tool-data row payload; update schema/source fixture expectations atomically, retaining old-format bytes only as explicit rejection fixtures. |
| `tests/acid/reference/pattrns_writer.lua:16-18`, `M.emit`; `tests/acid/reference/script_runner.lua` | Development-only export of an already compiled event plan, not source/provenance authorization or a second release writer. Exercise exports using resolved plans where appropriate; do not invent raw re-resolution in exporter. `acid_pattrns_spec`, `acid_editor_spec`, `acid_policies_spec` consume this reference path. |
| `tests/renoise/test_package_dev.ps1:216-218,355-357`; `tests/acid/acid_dependency_graph_spec.lua:169-170` | Reference writers are explicitly included only in development bundles and excluded from release runtime dependency graph. Preserve that boundary. |

### Spec-to-contract map and gaps

Names below are under `tests/acid/` unless explicitly prefixed. These are
existing coverage owners, not claims that M5 assertions already pass.

| Playbook requirement | Existing spec owners to update | Missing required assertions / behavior |
| --- | --- | --- |
| 10.1, 10.3 source/factories | `acid_source_values_spec`, `acid_sequencer_spec`, shared `pitch_fixture.lua`, local copier in `acid_repeat_integration_spec` | Seven-field exactness, detached masks/equality including disabled masks, dense boolean/all-false rules, 24..60 endpoint and alternate raw encodings. |
| 10.1, 10.3 semantic resolution | `acid_cycle_interpreter_spec`, `acid_compiler_spec`, `acid_control_signals_spec`, `acid_planner_association_spec`, `acid_output_planner_spec`, `acid_output_compatibility_spec`, `acid_phrase_validator_spec` | Nearest/lower-tie vectors, canonical resolved controls, unchanged raw flags/source and NOTE/TIE/REST semantics. Both policies/planner routes, `plan_loop`, fallback and mandatory supplied-plan successor verification consume same issued bundle. Reject forged/stale/source-only/vector-only/paired tampering and post-capture mutation; spy on resolver count. |
| 10.1, 10.4 codec/candidates | `acid_pattern_store_codec_spec`, `acid_phrase_persistence_spec`, `acid_store_candidate_spec`, `acid_writer_transaction_identity_spec`, writer integration/safety specs | Schema-2 exact fields/order/ASCII/hex/label custom bit; reject nonempty old magic unchanged; concurrent raw-store conflict, mutate-then-throw rollback ownership, newer-draft ABA token preservation. |
| 10.1, 10.4 history/drafts/requests | `acid_editor_spec`, `acid_draft_cache_spec`, `acid_draft_recovery_spec`, `acid_runtime_request_spec`, `acid_runtime_context_spec`, `acid_runtime_transitions_spec`, `acid_runtime_inventory_spec`, `acid_source_revision_spec` | Mask/label/custom end-to-end; proposed-cursor label-only failure/retry; metadata revision versus musical revision; mixed accepted-local-state failure; immutable prepared provenance carried privately and never serialized. |
| 10.1, 10.5 GUI/admission | `acid_gui_views_spec`, `acid_gui_independence_spec`, `acid_gui_admission_spec`, `acid_gui_recovery_spec`, `acid_gui_timing_race_spec`, `acid_runtime_editor_spec` | Independent selectors/pages and inactive TIME inspection, retired ID absence, bounded tabs, raw control readouts/C+, revision-safe shared projection, no selection render/history/draft writes. Existing `acid_gui_views_spec:406,414` references old TIME/key popup IDs and must be replaced, not aliased. |
| 10.5 staging | Existing GUI/admission/history owners plus proposed cohesive `acid_program_staging_spec` | Detached candidate initialization, target/origin identity, entered conjunction, no-change marker behavior, one-edit/equal-source Finish, incomplete guards and abandonment of guarded action, external change discard, Grid canonical display. No current stage implementation or direct suite exists. |
| 10.5 audition/lifetime | `acid_runtime_lifetime_spec`, `acid_runtime_observers_spec`, GUI lifecycle coverage plus proposed `acid_audition_lifecycle_spec` | Preview only selected resolved pitch; exact instrument/track/note identities, timer registration/removal failures, disappearing objects, retrigger/modal/stale callback/teardown release; mocks never prove sound or duration. |
| 10.6 clipboard/labels/duplicate | `acid_id_allocation_spec`, `acid_phrase_materializer_spec`, `acid_phrase_spec`, persistence/writer transaction and runtime request owners; proposed `acid_clipboard_spec`, `acid_duplicate_label_spec` | Session payload exclusions/bounds/deep copies, strict label bytes and metadata-only history, committed-origin duplicate authorization/label derivation/new ID, dirty-draft preservation and failure rollback. None has a direct current behavior suite. |
| 10.6 reset/transforms/RNG | Existing source/editor owners plus proposed `acid_source_operations_spec` | Exact reset preservation, Selected/Active/All-32 scopes, shared TIME normalization, mask non-destructiveness, deterministic Park-Miller vectors and random draws including MIDI 60. `acid_gate_operations_spec` tests native gate writing, not these source operations. |
| 10.2 new unowned behavior | Proposed `acid_scale_mask_spec`, staging/audition/clipboard/source-operations/duplicate-label specs named above | None exists at audit baseline. Add only for cohesive previously unowned responsibilities; update existing owners rather than duplicate their coverage. |

Runner discovery is `scripts/run_tests.ps1:46-60`: top-level
`tests/acid/*_spec.lua` (not recursive) and recursive `tests/renoise/**/*_spec.lua`
for `-Tool ACID`; sorted and launched separately at `68-89`. New behavior specs
must use those discoverable names/locations. Shared helpers/fixtures are not
standalone specs. The 70 baseline specs include offline Renoise harness tests;
they do not assert new M5 behavior. No native acceptance was rerun.

The following exhaustive baseline roster assigns every discovered spec either
to a section 10 owner or an explicit ancillary regression responsibility. Names
in the first ten rows omit the common `tests/acid/` prefix and `_spec.lua` suffix;
the final row uses paths relative to `tests/renoise/` with the same suffix omitted.
All remain part of the full regression, including ancillary specs that do not
own a new M5 feature. A factory call inside an ancillary suite still receives
the new source defaults through the canonical factory; hard-coded source/wire
assertions must be updated, not made permissive.

| Baseline specs | Section 10 / ancillary disposition |
| --- | --- |
| `acid_sequencer`, `acid_source_values`, `acid_editor`, `acid_source_revision` | 10.1/10.3/10.4 canonical values, revision immutability, projection/history and source operations. |
| `acid_compiler`, `acid_cycle_interpreter`, `acid_control_signals`, `acid_planner_association`, `acid_output_planner`, `acid_policies` | 10.3 semantic event/loop/policy routes and shared prepared association. |
| `acid_articulation`, `acid_articulation_semantics`, `acid_articulation_resolution`, `acid_glide_overlap`, `acid_legato`, `acid_legato_writer`, `acid_pitch_bend`, `acid_gate_operations`, `acid_gate_transaction`, `acid_timing` | 10.3 ancillary rendered-event regression: articulation collisions, resolved gates/slide, legato/PB, native emission/rollback and exact timing. Preserve semantics while source compilation changes. Gate operations are not editor transforms. |
| `acid_pattern_store_codec`, `acid_store_candidate`, `acid_phrase_persistence`, `acid_draft_cache`, `acid_draft_recovery`, `acid_live_identity`, `acid_id_allocation` | 10.4/10.6 codec, durable draft identity, exact candidate/ID ownership; update source/metadata carriers and failure checks. |
| `acid_phrase_snapshot`, `acid_phrase_snapshot_seal`, `acid_phrase_snapshot_empty`, `acid_regeneration`, `acid_output_compatibility`, `acid_phrase_validator`, `acid_target_capabilities` | 10.3/10.4 ancillary postimage/seal/ownership/target compatibility boundaries. Preserve seal grammar and empty-cell handling; mask affects source association, not seals' grammar or target capabilities. |
| `acid_phrase`, `acid_phrase_materializer`, `acid_writer_capture`, `acid_writer_inspection`, `acid_writer_safety`, `acid_writer_transaction_identity`, `acid_repeat_integration` | 10.3/10.4/10.6 sole writer, authorized request/inspection, materialization, source rollback and Repeat integration. Capture harness checks delegation/readback, not actual sound. |
| `acid_gui_admission`, `acid_gui_independence`, `acid_gui_recovery`, `acid_gui_timing_race`, `acid_gui_views` | 10.5 shell/admission/projection/recovery owners; replace old-widget assertions, preserve typed failure and timing invalidation behavior. |
| `acid_runtime_context`, `acid_runtime_editor`, `acid_runtime_independence`, `acid_runtime_integrity`, `acid_runtime_inventory`, `acid_runtime_lifetime`, `acid_runtime_mutation`, `acid_runtime_observers`, `acid_runtime_request`, `acid_runtime_transitions`, `acid_runtime_writer_integration` | 10.4/10.5/10.6 runtime authorization, Make Independent, integrity, mutation/reconciliation, inventory, revisions, lifecycle/observers and writer integration. Extend existing failure/identity assertions rather than weaken them for duplicate or metadata. |
| `acid_capture_trigger`, `acid_mono_probe`, `renoise_long_repeat_trigger`, `renoise_render_capture` | Ancillary native-harness duration/boundary/render/probe setup regressions; not M5 audition or native playback evidence. Fixture sources must still meet the new contract where canonical. |
| `acid_pattrns`, `acid_script_runner`, `acid_dependency_graph`, `acid_identity` | 10.3 ancillary reference export/script runner plus runtime/package identity/dependency boundaries. Exports consume resolved event plans; no second resolver, runtime reference writer or manifest bump. |
| `acceptance_cases`, `acid/probe`, `persisted_baseline`, `remote_driver`, `spike_tool` | Ancillary offline Renoise harness fixture/probe, persistence-drift oracle, development transport and passive/idle lifecycle safety. Update real source/schema payloads; preserve intentionally reduced oracle mocks and observation-only lifecycle behavior. No host execution implied. |

### Independent review and exit evidence

Dedicated source/render, GUI/lifecycle and SDK subagents performed the initial
audit. A separate SDK reviewer found no fact/signature/reference error. An
independent whole-tree second pass identified the test-only request builder,
reference exporters, generated fixture payload and direct native probe routes;
these are now recorded above. The consolidated-evidence reviewer then required
explicit dispositions for the remaining baseline specs, the native acceptance
driver producer and the request capture/checkpoint provenance transfer boundary.
Those corrections were independently re-reviewed: **PASS**, all 70 discovered
specs reconciled (65 top-level ACID plus five recursive Renoise specs), no missing
disposition and no remaining actionable finding. The reviewer verified the
producer and provenance-boundary corrections without rerunning the suite.

No normative design contradiction was found. Current raw-only compilation,
schema 1, coupled navigation and target-derived create authorization are pending
implementation gaps explicitly covered by the accepted design, not reasons to
weaken it. Initial checkout cleanliness is the baseline receipt; current audit
changes are documentation only. `pwsh -Command "git diff --check"` passed;
`git status --short` and `git diff --stat` show only this record and
`com.david303ttl.ACID.xrnx/M5_EDITOR_PLAYBOOK.md` changed. Git's existing LF/CRLF
conversion warnings are not whitespace errors. No staged changes, runtime edits,
manifest changes or tracked SDK/build artifacts were introduced.

**Gate 0 exit: PASS.** Baseline observed, SDK facts verified, complete call-site
inventory and spec dispositions recorded, shared snapshot owner selected, and
independent second-pass findings resolved. Gates 1+2 must still execute atomically;
no later implementation gate was started. M5 overall remains incomplete, and all
new native editor/audition/playback acceptance is unverified.

## M5 Gate 3 shell and Grid verification (2026-11-01)

**Disposition: PASS for Gate 3 implementation, deterministic verification and
independent second-pass review. Native feasibility remains UNVERIFIED.**
Scope is the shared shell, independent navigation, direct Grid controls,
bounded workspace/paging and session PITCH indicators. Program staging,
audition and later operation gates are not part of this change.

- Fresh baseline: `pwsh -File ./scripts/run_tests.ps1 -Tool ACID` exited 0;
  **71 specs passed, 0 failed**, Lua 5.1, isolated processes, 61.55 seconds.
- An intermediate full-repository run during active implementation exited 1:
  **74 specs, 5 failed**. The new GUI exceeded Lua 5.1's 60-upvalue limit in
  its refresh closure, preventing the five GUI specs from loading. This is
  development failure evidence, not final acceptance.
- A subsequent ACID integration run exited 1: **71 specs, 5 failed** in
  60.39 seconds. GUI compilation succeeded; four specs still referenced removed
  dropdowns and the view spec failed its C+ assertion. These integration failures
  were development failures, not acceptance results.
- Following selector cutover, a repository run exited 1: **74 specs, 1 failed**
  in 71.94 seconds. Admission, independence, recovery and timing-race GUI specs
  passed; the expanded views spec still failed. Independent review additionally
  identified C+ admission outside UP and premature indicator baseline acceptance
  for a success without a verified destination. Both production issues were
  corrected before the passing repository run below.
- After those corrections, `pwsh -File ./scripts/run_tests.ps1` exited 0:
  **74 specs passed, 0 failed**, Lua 5.1, isolated processes, 67.10 seconds.
  This includes all five GUI specs, the ACID model/runtime/writer regressions,
  ARP regressions and offline Renoise harness specs. It is deterministic
  repository evidence, not native layout or playback acceptance.
- Implementation retains one source and existing request/writer/store owners.
  Program/Grid have independent PITCH and TIME pages/selections; inactive TIME
  remains inspectable after LAST STEP shrink and cannot be directly edited.
  Grid uses two rows of eight cells per memory and selection-only TIME buttons.
  Twelve chromatic controls, three octave controls and UP-only C+ replace the
  old dropdowns. Raw pitch encoding remains visible and untouched by navigation.
- A fixed-height stack hosts Decoded, Pattern / Copy, Extended / Clear, Output
  and Recovery. Decoded and Recovery details each show at most four rows/lines
  per page. Later operation tabs explicitly report unavailable operations;
  staging, audition, clipboard, labels UI and transforms are not implemented by
  this gate.
- Stored/referenced/modified PITCH indicators derive from retained source,
  canonical traversal and a detached load/verified-commit baseline. The reviewed
  success path rejects stale, noncurrent, absent or mismatched destination
  identities before advancing that baseline. Disabled C+ callbacks cannot bypass
  UP-only admission. Native harness probes now use replacement button actions
  and readouts rather than retired widget IDs.
- Independent source/API and assertion-level reviews found and corrected the
  UP-only C+ guard, destination-baseline guard, missing raw-encoding/reopen/paging
  assertions, and native probe cursor assumption. The probe now explicitly
  selects and verifies PITCH 1 before evaluating note/octave edits. Added
  regressions were rerun after fixture/counter setup corrections; the earlier
  passing run alone did not cover subsequently added assertions.
- The post-review ACID run exited 1: **71 specs, 2 failed** in 62.98 seconds.
  Newly expanded views and recovery fixtures failed their setup/status
  assertions; all other specs passed. This supersedes the earlier all-pass
  snapshot and was subsequently superseded by the final successful run below.
- Expanded assertions also exposed a missing displayed-indicator refresh after
  verified baseline acceptance. The success path now calls the guarded cached
  GUI refresh immediately after accepting that baseline. Independent re-review
  found no additional source/history mutation or generation request in this
  correction. The missing-destination regression, existing cancellation paths,
  restored-source indicators and raw-encoding/paging assertions now pass.
- Final command: `pwsh -File ./scripts/run_offline_tests.ps1`, exit 0:
  **18 offline check groups passed**, including **74 Lua specs, 0 failed** in
  60.57 seconds. This final run includes the expanded regression assertions and
  reviewed production/harness fixes. The preceding offline run failed only its
  Lua group (the two GUI fixture failures above); its other 17 groups passed.
- Independent production, SDK, assertion-coverage, native harness and evidence
  reviews were performed by agents other than the implementer. Findings were
  corrected and rechecked, including the final indicator refresh and explicit
  PITCH cursor verification. No unresolved deterministic Gate 3 finding remains.
  This is scoped Gate 3 review evidence, not final M5 Gate 12 acceptance.
- Release archive construction passed with
  `pwsh -File ./scripts/package.ps1 -Tool ACID`: 31 runtime files, unchanged
  manifest version 0.1. `pwsh -File ./tests/renoise/test_package_dev.ps1` exited 0,
  checking release exclusions, development payload/fixture hashes, generated
  Lua 5.1 entrypoint syntax, bootstrap and packaging rejection cases.
  `pwsh -File ./tests/package_license_spec.ps1` verified all three archive
  licenses; `pwsh -File ./tests/renoise/runner_spec.ps1` passed transport,
  ownership, keyboard configuration, reporting and installation lifecycle mocks.
- Native feasibility procedure 13.1.6 is **UNVERIFIED**. Read-only process
  detection found no running Renoise process. No installation, song replacement,
  or host UI actions were performed. The existing native API harness has no
  automated clipping/legibility/reachability assertion for this shell; mocks
  cannot establish display-scale fit. GUI-heavy Gates 4–7 must wait for actual
  native feasibility evidence.

### Gate 3 revalidation (2026-11-02)

- A delegated contract audit confirmed that the remaining Gate 3 obligation is
  native layout feasibility procedure 13.1.6, not later Program staging or
  operation implementation. This checkpoint does not advance Gates 4–7.
- Fresh `pwsh -File ./scripts/run_offline_tests.ps1` initially encountered two
  Lua executables on PATH, causing interpreter resolution to supply an array
  where the runner expects one executable. An explicit `-LuaCommand` resolved
  unambiguously, but the interpreter-policy group still failed its
  forwarding-command-wrapper assertion.
- A further full offline run, with the second Lua installation removed from PATH
  for that process only, completed **74 Lua specs, 0 failed**, using Lua 5.1 in
  isolated processes. The other **17 offline groups passed**, including GUI
  regressions, development/release packaging and synthetic audio checks. The
  interpreter-policy group again failed the forwarding-wrapper assertion, so
  the aggregate offline command exited 1. This is not a fresh 18-group pass;
  the earlier dated successful receipt remains historical evidence. No runner
  or machine-wide environment changes were made.
- Read-only process detection found no running Renoise process. No native UI,
  installation or song operations were performed. Clipping, legibility and
  reachability remain **UNVERIFIED**; mocks and offline package checks do not
  close procedure 13.1.6. GUI-heavy Gates 4–7 remain paused at this dependency.
- A separate focused run of `pwsh -File ./scripts/run_tests.ps1 -Tool ACID`
  with an explicit `-LuaCommand` selecting the installed Lua 5.1 executable
  exited 0: **71 specs passed, 0 failed**, in 25.74 seconds. `git diff --check`
  passed for this acceptance-record update.
- The additional independent implementation review subsequently found a stale
  projection after an accepted local edit whose runtime draft transition failed.
  The runtime revision remained unchanged, so the GUI cache could keep showing
  the previous source. `gui.lua` now invalidates that cache after edit admission
  and history movement, including failed draft saves. Navigation behavior is
  unchanged. The admission spec covers the failed edit and failed-save Undo:
  divergence reports a resolution-association error rather than stale preview,
  and restoring the matching source displays a valid projection again.
- The reviewer ran the ACID suite after the fix: **71 specs passed, 0 failed**.
  Coordinator verification of the final runtime/test changes used
  `pwsh -File ./scripts/run_tests.ps1` with an explicit Lua 5.1 `-LuaCommand`:
  exit 0, **74 specs passed, 0 failed**, in 26.39 seconds. Earlier offline-group
  and packaging results above precede this fix and are not final-build native
  evidence. No deterministic Gate 3 review finding remains unresolved.

### Native editor execution follow-up (2026-11-02)

- Subsequent operator visual inspection **FAILED** layout feasibility: editing
  Grid pitches expands the dialog width. The supplied screenshot shows longer
  sharp/key-10 labels widening the first PITCH row beyond the TIME rows.
  This supersedes the earlier unverified disposition with an observed fit
  failure; a corrected build requires renewed visual inspection. Pattern / Copy
  and Extended / Clear operation placeholders belong to later implementation
  gates and are not evidence that those operations have been implemented.
  Output contains active output-policy and PB-range controls; Recovery contains
  the existing recovery controls and an empty-state message when no detached
  draft is available. Neither panel is an unavailable-operation placeholder.
- Renoise 3.5.4 Demo / API 6.2 was available later in the session. The native
  runner used separate runner-owned processes and disposable documents, rather
  than attaching to the existing user process. The Native smoke suite passed;
  report: `tmp/interactive-e149fce9443f471684b02667114cf398/report.json`.
- The first `editor-responsiveness` run failed on unsupported `Button.value`
  access in the acceptance harness. Subsequent runs exposed stale TIME callback
  aliases, a Program-only readout assertion while Grid was visible, missing
  sample arrays for Grid actions, and a zero-padded Grid key alias mismatch.
  These harness defects were corrected in `tests/renoise/driver/acceptance_cases.lua`.
  No production GUI behavior was weakened to pass the checks.
- Final native command: `pwsh -File ./scripts/run_interactive_tests.ps1 -Install
  -ApproveDisposableSong -AcceptanceCase editor-responsiveness` with the installed
  Renoise 3.5.4 executable selected explicitly. Result: **PASS**;
  report: `tmp/interactive-d307f0f4ea614b4aaaaa228d294a5000/report.json`.
  This is functional native editor evidence, not pixel-based layout acceptance
  or performance acceptance. Run artifacts remain ignored and uncommitted.
- Final repository Lua regression run with explicit Lua 5.1: **74 specs passed,
  0 failed**, 26.66 seconds. Native runs built the development bundle and restored
  their temporary installation and disposable fixture state on completion.
- Before the subsequent operator failure above, procedure 13.1.6 was
  **UNVERIFIED** for visual clipping, legibility and physical control reachability.
  The available harness exercises callbacks and
  native widgets but does not capture or inspect desktop pixels. Actual visual
  observation is still required; the native functional pass does not authorize
  advancing GUI-heavy Gates 4–7.

### Grid fit correction verification (2026-11-02)

- The operator screenshot exposed unequal PITCH button widths driven by longer
  pitch labels. The correction uses explicit API 6.2 `size` bounds for cells and
  dynamic readouts. Output and Recovery panel selection now has explicit GUI
  regression coverage; later-gate copy/transform placeholders remain unchanged.
- The native `editor-responsiveness` harness now compares the Grid panel width
  and all 16 visible PITCH cell widths before and after source edits. It sweeps
  all twelve pitch-class keys, including sharps and raw keys 10/11, and exercises
  octave, accent and slide edits. It also selects all five lower workspace tabs
  and verifies active Output controls. The assertions use actual native widget
  dimensions, not mock `size` values.
- Native Renoise 3.5.4 / API 6.2 run passed with the twelve-class sweep:
  `tmp/interactive-9ea0a41c7865456994a1829cada307ff/report.json`.
  This verifies width stability for the exercised build and actions, not pixel
  legibility or final integrated native acceptance. The development package
  validation script also passed with the explicit Lua 5.1 interpreter.
- An intermediate repository regression run during GUI-test updates failed only
  the views spec's decoded paging fixture assertion (74 specs, 1 failed). This
  development failure is not a final successful regression receipt.
- Integration review rejected an intermediate tooltip-only compact label because
  raw controls and ACCENT/SLIDE must remain visible. The final cell is a fixed
  98x38 column: an 18-pixel position/SRM header and a 20-pixel button displaying
  raw note/key/octave and both flag states (for example `60/12+1 A-S-`). Alternate
  raw encodings remain distinguishable. The two rows of eight cells are retained.
- Final native run against that hierarchy passed:
  `tmp/interactive-5e190aeba24e4ea486fd8d2623589237/report.json`. The Grid measured
  **812 pixels wide**, remained stable through the twelve-class sweep and
  octave/flag edits, and all **five tabs** selected successfully. Output controls
  were available. Fixture store, inventory and native selection restoration passed.
- Final repository Lua run: **74 specs passed, 0 failed**, 31.73 seconds; the
  implementer also passed **71 ACID specs**. Independent final integration review
  found no defect in visible raw fields, fixed cell hierarchy or rendering purity.
  `pwsh -File ./scripts/package.ps1 -Tool ACID` built
  `dist/com.david303ttl.ACID_0.1.xrnx` with 31 runtime files. Manifest unchanged.
- The reported width-growth defect is corrected and natively regression-tested.
  Operator visually rechecked the corrected build after the final native run and
  confirmed Gate 3 layout acceptance. This supersedes the preceding screenshot
  failure. Program/Grid, both pages, fixed lower workspace, Decoded/Recovery
  paging, label readability, reachability and stable pitch-edit width were
  inspected at the operator's normal display scale. Pattern/Copy and
  Extended/Clear remain intentionally unavailable pending their later gates;
  Output and Recovery are available. Gate 3 native feasibility is PASS. Gate 11
  must repeat visual acceptance against the final integrated M5 build.

## M5 Gates 1+2 deterministic exit (2026-11-01)

**Disposition: PASS for the combined deterministic Gates 1+2 cutover.** Source,
schema, labels/custom metadata, history, draft/request carriers and prepared
resolution now transition together through the existing compiler, planner,
control, ownership and writer owners. No Gate 1-only intermediate acceptance
was taken. No later implementation gate was started.

- Fresh pre-change baseline: `pwsh -File ./scripts/run_tests.ps1 -Tool ACID`;
  **70 passed, 0 failed** (2026-11-01; per-spec process isolation).
- Final combined regression: `pwsh -File ./scripts/run_tests.ps1 -Tool ACID`;
  **71 passed, 0 failed** (2026-11-01; 66.73 seconds, per-spec process
  isolation). The additional discovered spec is the behavior-named
  `acid_scale_mask_spec.lua`.
- Deterministic source assertions cover exact seven-field sources, factory mask
  defaults, dense boolean mask validation, disabled all-false masks, enabled
  empty rejection, MIDI 24/60 endpoints, copy/equality, mask immutability,
  nearest-note resolution and lower-note ties. Prepared bundle tests reject
  forged provenance, source/mask association drift, source/record tampering and
  post-capture request mutation. Resolver spies exercise projection, compiler,
  Repeat/Play Once planning, control fallback/successor validation and private
  materialization without re-resolution.
- Codec tests cover exact deterministic schema-2 bytes, SOURCE/LABEL association,
  custom-bit roundtrip, pending `Untitled`, stable ordering, uppercase hex,
  schema-1/unsupported rejection, malformed masks/labels and unchanged raw bytes
  on rejects. Candidate tests cover exact raw-store conflict, draft preservation,
  setter-before/after-mutation failures, readback uncertainty and exact rollback.
- History now snapshots label/custom with source/settings, classifies label-only,
  mixed and musical/output changes, and uses authenticated proposed cursor
  transitions. Metadata-only label writes advance a separate metadata revision;
  requests reject stale metadata and preserve frozen prepared provenance.
- Writer integration verifies default `Pattern <ID>` labels on New create,
  explicit custom label preservation through regeneration, masked raw-source
  persistence, coherent resolved output, and rollback of phrase identity when a
  captured raw-store change revokes the source candidate.
- Pinned SDK setup/audit remains the Gate 0 receipt; no new Renoise APIs were
  added. `git diff --check` passed after implementation (only Git's existing
  LF/CRLF conversion warnings were emitted). No package inputs or runtime layout
  changed, so packaging was not required.
- Renoise native checks were not run. Masked host playback, label cold reopen,
  and actual GUI/native behavior remain **UNVERIFIED**. Lua tests do not assert
  sound, native playback or host persistence behavior. Gates 3+ and independent
  Gate 12 review remain pending; this record does not claim M5 completion.

### Independent foundational second-pass follow-up (2026-11-01)

An independent review of the changed Gate 1+2 production and test diff against
playbook sections 4.1–4.6, 11.2 and 12, using the Gate 0 owner/call-site receipt
above, found one concrete prepared-resolution provenance defect. The factory
bundle's exposed `resolved_records` table was also retained as the private
provenance baseline. Mutating the original bundle in place therefore mutated
the supposed private baseline and could pass `validate_prepared`. Request
detachment happened to make its existing tamper test pass, but did not satisfy
the factory-bundle contract.

Fixed `model.sequencer.prepare_resolution` to retain a separate private copy of
all 32 canonical records. `same_records` now rejects nonnumeric array keys
without raising. `acid_scale_mask_spec.lua` now asserts rejection after mutation
of the original issued bundle and graceful rejection of malformed record keys.
The focused spec passed when run directly with `lua
tests/acid/acid_scale_mask_spec.lua`.

After the correction, `pwsh -File ./scripts/run_tests.ps1 -Tool ACID` completed
**71 specs, 0 failed** in 64.60 seconds using Lua 5.1 with per-spec process
isolation. `git diff --check` passed; Git emitted only its existing LF/CRLF
conversion warnings. No other concrete defect was found in the reviewed
foundational source, schema/label, history, prepared-resolution, source
association, or writer rollback paths. This is the requested independent
Gate 1+2 review evidence, not the complete section 12 Gate 12 closeout: later
gates remain pending, and native Renoise/editor/playback behavior remains
**UNVERIFIED**.

## M4 scoped closeout

**M4 / Gate 8 closeout (2026-11-01): PASS — CLOSED by scoped project decision.** The accepted scope includes the 8×8 production workflow, native Undo/Redo, two cold reopens and captured MIDI note/OFF/pitch-bend events. The 16×8 acceptance disposition is also PASS under the scope decision; its retained run stopped at the recorded native-selection interruption after 112 regenerations, and remaining stress execution is waived. Latency has no active acceptance threshold and recovery snapshots remain unchanged.

The 16×8 acceptance is **PASS by scope decision**, with the remaining stress execution waived. Its retained run created 128 owned phrases plus one explicit Create and completed 112 regenerations before a native-selection change stopped the run. The cause is unknown; the native runner report status is FAIL because it records a partial execution, not a completed 16×8 stress run. Sample/VST audio capture is **WAIVED** and audio is **UNVERIFIED**. No further Gate 8 or performance investigation is required.

## Production-session native evidence

| Scenario | Acceptance disposition / run result | Existing artifact and identity |
| --- | --- | --- |
| 8×8 production-session-8x8 | **PASS:** 64 base creations, one additional Create, 133 regenerations; seed, edits, drafts, native Undo/Redo, cold reopen and playback phases passed. MIDI is **PASS** (6 notes, 6 OFFs, 12 pitch-bend events); audio is **WAIVED**, with no audio pass claimed. | [Native report](../../tmp/interactive-74c947cf55204a5da1e53b0edc30610e/report.json), run 74c947cf55204a5da1e53b0edc30610e, SHA-256 8484522B90D3482A94101D23F34F4498C73AD741ABCE374DAA9FC51EA5008D74. Development bundle: tmp/acid-dev-74c947cf55204a5da1e53b0edc30610e/. |
| 16×8 production-stress-16x8 | **PASS (scope accepted; native runner report FAIL/partial):** the project accepted the 16×8 result at the recorded scope and waived remaining execution. The retained run created 128 base phrases, one additional Create and completed 112 regenerations before native selection changed. This PASS records the acceptance disposition; the execution stopped at the interruption and is not a completed full stress run. | [Native report](../../tmp/interactive-87d1837cdf674a6abb393275a0c481db/report.json), run 87d1837cdf674a6abb393275a0c481db, SHA-256 9CA21E450EE6A3E7CE57ED60B63FF7F29B860D200D7C8F6847355AAF496B042D. Development bundle: tmp/acid-dev-87d1837cdf674a6abb393275a0c481db/. |

Both reports record source commit 06b20b31b098971750d70355aa8fc706615ac315 (the parent of reviewed commit 2258920) and Renoise 3.5.4 / API 6.2. The report and per-run development-bundle paths identify the retained native evidence; these are not post-commit executions of 2258920. The 8×8 report's overall playback phase is interpreted here as MIDI PASS with audio WAIVED.

The dated sections below preserve the state and plans recorded at their checkpoints. Their historical OPEN/PENDING statuses and staging/render-callback instructions are superseded by this closeout and the synchronous direct-writer architecture.

## Bounded production-scale investigation (2026-11-01)

**Gate 8: FAIL; OPEN. Implementation/acceptance remains INCOMPLETE.** The current
30 ms gate fails in measured Warm callbacks. This iteration implements diagnostic
execution and controlled profiling only; it does **not** implement or execute
`production-session-8x8` or `production-stress-16x8`. No integrated production
creation/regeneration, playback, cold-process or recovery acceptance is claimed.
The phase-1 evidence below does not declare all requested phase-1 measurements
complete: separate admission and adoption/reconciliation costs remain unresolved.
Later implementation phases have not been completed.

**Identity:** base commit `47d478e1e749d789bef9be425e98d81cf9adfdd3`, with the
uncommitted diagnostic/documentation changes described here. No production Lua,
manifest, source format or schema changed; no commit, push or merge was made.
Native reports include their packaged development-file hashes and source SHA;
those package identities, rather than HEAD alone, identify the measured harness.
Final implementation/documentation patch (excluding this self-referential evidence
file): `tmp/acceptance-investigation-working-tree.patch`, SHA-256
`7fc799c91d5b99f6200442043ad60aea80ee861193f50ccff944a48d010131d0`.
Later report-field/timer fixes do not retrospectively apply to older artifacts.

### Implemented changes and review

- `tests/renoise/driver/acceptance_cases.lua`: one existing parameterized latency
  fixture now measures empty phrase inventory, populated early history and the
  same populated inventory after two revisions per owned phrase. Each stage has
  three Warm samples and a separate Detailed sample. Store size/source rows are
  counted outside callbacks; current code also records GC memory and exact
  callback-entry row/byte counts. The helper retains the reused GUI runtime and
  restores its profiling wrappers, instead of assuming each dialog creates a
  fresh runtime. No direct writer setup/history action counts as GUI acceptance.
- `tests/renoise/acceptance_cases_spec.lua`: Warm-only aggregation retains an
  earlier performance FAIL and excludes Detailed overhead from release judgement.
  Each Detailed callback's observed ceiling status remains separate.
- `tests/acid/production_session_acceptance.md`: distinguishes strict release
  execution from `FUNCTIONAL_DIAGNOSTIC`, with unchanged safety stop conditions
  and 30 ms ceiling; removes contradictory prohibitions on diagnostic 16x8 after
  a complete 8x8 functional journey. The smaller latency case is not that journey.
- `tests/renoise/README.md`: documents the diagnostic matrix/report semantics.
  Playbook and roadmap contain short references to this canonical evidence.

Independent reviewer checked the actual diff and native reports. Its concrete
finding that Detailed overhead could determine the release verdict was fixed;
Warm violations now determine it. Timer failures now deactivate the callback,
verify exact removal and retry cleanup through the failure path. Review found no
normal-completion wrapper restoration defect. It explicitly rejected any full
production-acceptance interpretation and distinguished editor fixture restoration
from runner-owned disposable-process teardown.

### Controlled evidence and optimization decision

All numbers below are milliseconds from the existing host `os.clock()` delta
multiplied by 1000. Three Warm samples per stage are too few for p95/p99 or a
representative production latency distribution. These are sample-target GUI
callbacks; receivers remain loaded, but actual playback is not tested.

| Diagnostic / native report under `tmp/` | Inventory / retained rows before helper | Warm callbacks, ms | Detailed recovery capture |
| --- | --- | --- | --- |
| 8x8 `interactive-a6fc9437fd6a4675b6c78690b239953e/report.json` | 0 phrases / 0 rows | 46.89, 59.32, 68.93 | 1 capture |
| Same 8x8, early | 72 phrases / 64 rows | 528.24, 483.92, 475.00 | 73 captures / 349.80 ms |
| Same 8x8, late | 72 phrases / 192 rows | 648.52, 510.23, 590.27 | 73 captures / 434.20 ms |
| 16x8 `interactive-a40bfcede80b46b78e5daa48236c1229/report.json` | 0 phrases / 0 rows | 62.49, 83.45, 63.13 | 1 capture |
| Same 16x8, early | 144 phrases / 128 rows | 1280.78, 1133.48, 961.43 | 145 captures / 953.50 ms |
| Same 16x8, late | 144 phrases / 384 rows | 1188.06, 2046.69, 1004.31 | 145 captures / 1051.23 ms |

8x8 retains ten native instruments (two empty defaults); 16x8 has sixteen.
Every helper adds one temporary phrase and restores its original inventory,
selection and store before returning. Thus timed inventories are 1/73/145 phrases,
and the callback has additional helper revisions beyond the pre-helper row count.
Older reports do not expose exact callback-entry row counts; current code does.
Fixture seeding/history uses development writer requests outside the timer.
The 8x8/16x8 reports verify 64/128 seeded owned phrases plus 8/16 foreign sentinels
and 128/256 history regenerations, **zero counted integrated GUI creations and
zero counted production-session regenerations**. All nine Warm samples per run
fail the unchanged ceiling; functional diagnostic status is PASS. Process shutdown
and installation restoration are PASS in both reports.

**Demonstrated principal cost:** `runtime.integrity:capture_mutation()` snapshots
every native phrase before the synchronous mutation scope. Its whole-song recovery
capture accounts for most populated callback cost, with 73/145 captures rather
than a constant single target. The empty-inventory controls retain the same loaded
instrument mix; early/late controls hold native phrase inventory fixed while
tripling retained immutable rows. History contributes cost and noise, but is not
the dominant measured scaling factor. The measured recovery count matches native
inventory, not revision count. Existing detailed timings are nested, not additive.

| Detailed stage | 8x8 early / late, ms | 16x8 early / late, ms |
| --- | --- | --- |
| Recovery/preimage capture | 349.80 / 434.20 | 953.50 / 1051.23 |
| Persistent preparation | 4.93 / 17.91 | 10.63 / 32.83 |
| Persistent commit | 1.24 / 37.27 | 26.91 / 4.11 |

Planning, materialization and native verification timings are in each Detailed
sample's `profile` fields. Request-guard time includes the writer; reused runtime
owners mean admission/adoption were not independently timed by these wrappers.
Do not subtract overlapping totals to invent separate stage measurements.

**Optimization decision: no production correction.** Removing or narrowing the
whole-song recovery preimage would change existing recovery proofs, including
peer-state checks after failures. No safe localized replacement was demonstrated.
Do not trade that protection for a faster benchmark or introduce speculative
history caching. No optimization pass or architectural workaround was added.

**Clock limits:** pinned API 6.2 `definitions/library/standard.lua` and offline
`docs/API/modules/os.html` say Renoise replaces `os.clock()` with a high precision
timer; standard Lua CPU-clock semantics cannot be assumed. The older matrix
reports used an idle-dispatch probe, which does not prove CPU versus wall time.
Integer `os.time()` around callbacks independently observes only 0/1/2-second
elapsed buckets, with one-second resolution. These coarse observations support
second-scale 16x8 stalls but cannot verify a 30 ms wall-time gate. Current code
uses one verified-removed 2000 ms host timer outside the timed callback to probe
elapsed-clock behavior. The repeat 8x8 report
`tmp/interactive-c0159b9a96a0413a9562476f3e186607/report.json` records requested
2000 ms / `os.time()` 2 seconds / `os.clock()` 1.996443359 seconds, with
functional PASS, all nine Warm samples over budget, and verified process shutdown
and installation restoration. Its early Warm callbacks were 906.60/728.14/764.54 ms;
late callbacks were 786.02/699.51/705.39 ms. Repeat variability is substantial;
some matrix runs overlapped offline tests, so background load was not controlled.
Do not label these values independently verified CPU time or precise wall time.

**Current-harness 16x8 repeat:**
`tmp/interactive-11f97e3575424c0f84111e6f0cc4053b/report.json` records functional
PASS, performance FAIL, 128 owned + 16 foreign phrases and 256 setup/history
regenerations. Empty/early/late Warm callbacks were respectively
82.30/67.19/90.51, 1239.85/990.54/952.63 and 1209.45/1058.47/1045.12 ms.
The three-sample early/late medians are 990.54/1058.47 ms; maxima are
1239.85/1209.45 ms. No p95/p99 claim is justified. The host timer probe records
2000 ms requested, 2 seconds `os.time`, 1.995154297 seconds `os.clock`.
Exact callback-entry row counts were 1/129/385, with 1266/50892/150354 store bytes.
Detailed early/late recovery capture was 937.52/730.58 ms; planning 9.96/9.47 ms;
materialization 87.98/52.55 ms (including native verification 24.54/10.05 ms);
source preparation 9.25/25.92 ms; commit 3.00/4.23 ms. These are nested timings.
GC memory is reported per sample and varies nonmonotonically; neither absence
nor presence of a production memory leak is established. All twelve helper
functional/cleanup assertions and runner shutdown/restoration pass.

**Harness failures retained:** initial reports
`tmp/interactive-6cfac8cc968d468cb59de021ca4f89c0/report.json` (nil empty store)
and `tmp/interactive-753b3f6d40a74c27ad57ba60df12d425/report.json`,
`tmp/interactive-36194dc7aef94efbaff903bac3bcdd9b/report.json` (lost reference to
reused GUI runtime) failed before fixture seeding and stopped. These were harness
defects, fixed before the successful matrix runs; they are not production journey
failures or passes. Each failure's process shutdown and installation restore
passed. They are not omitted from the run history.

### Acceptance and release limitations

| Mandatory requirement | 8x8 | 16x8 |
| --- | --- | --- |
| Real parameterized production-session driver | NOT IMPLEMENTED | NOT IMPLEMENTED |
| 64/128 creations and 128/512 regenerations in one production GUI window | NOT RUN; diagnostic writer setup excluded | NOT RUN; diagnostic writer setup excluded |
| Eight/sixteen active mixed tracks, phrase triggering and receiver events | NOT RUN | NOT RUN |
| Musical slot matrix, independent full oracle and peer/foreign isolation journey | NOT RUN | NOT RUN |
| 128 cross-instrument switches, dirty A→B→C→A, no-op navigation at scale | NOT RUN | NOT RUN |
| Interleaved musical Undo/Redo, negative actions and recovery at scale | NOT RUN | NOT RUN |
| Two true cold-process production-song reopen stages | NOT RUN | NOT RUN |
| Sample audio path / loaded VST audio / ACID-delivered MIDI NOTE/OFF/PB | UNVERIFIED / UNVERIFIED / UNVERIFIED | UNVERIFIED / UNVERIFIED / UNVERIFIED |
| Every measured callback ≤30 ms | FAIL | FAIL |
| Full history, observer/reference/temp-object growth acceptance | INCOMPLETE | INCOMPLETE |

The earlier physical MIDI loopback probe remains historical precondition evidence,
not current ACID phrase delivery. Loaded Surge XT instances and configured MIDI
routes in these diagnostics do not prove audible output or event delivery. No
receiver was replaced by a mock. No operator listening observations were obtained.
The fresh `editor-responsiveness` Detailed report
`tmp/interactive-2a9708f3628549748ce507ffc0fa3c1a/report.json` passes its narrower
functional assertions and restoration, with a 53.96 ms Live Edit callback; it is
not a production journey or a performance PASS.

**Performance recommendation:** keep 30 ms executable and Gate 8 open. Present
synchronous full-song recovery capture exceeds that budget materially at both
scales. This evidence does not justify a replacement ceiling or establish typical
manual Generate, navigation, cold initialization or playback responsiveness.
Any further engineering should first define how to preserve existing recovery
proofs; do not continue isolated millisecond tuning based on this diagnostic.

### Fresh scoped native prerequisites

These are current narrow checks, not scaled production-session acceptance.
All launched runs below verify process shutdown and installation restoration.

| Case | Report under `tmp/` | Result / limitation |
| --- | --- | --- |
| Strict Warm editor | `interactive-3737e63d471143e3809d9a836cea8685/report.json` | FAIL: Live Edit 44.37 ms; unchanged 30 ms gate stops the case. |
| Strict Warm three-instrument workflow | `interactive-bedeb49e4ce74a52980620501b007a80/report.json` | FAIL: Live Edit 127.82 ms; not 8x8 evidence. |
| Direct output feasibility | `interactive-6fae80717d2a4492b91c19186681b794/report.json` | PASS: existing native materializer/oracle assertions; no acoustic claim. |
| Integrity/observers | `interactive-2866b09d2db9437a99fcd5111bee8900/report.json` | PASS: existing scoped native assertions. |
| Writer recovery | `interactive-0b9375ef2f8c4c3a88b8c1773101f1e1/report.json` | PASS: existing scoped native failure/recovery assertions. |
| Manual revision Undo/Redo | `interactive-9aa8e23b2b824362adf786fffd0eec00/report.json` | PASS: actual guarded native actions; not scaled/interleaved production acceptance. |
| Live Edit revision Undo/Redo | `interactive-6a63583e264c47508676ec19c02c0243/report.json` | PASS: actual guarded native actions; same scale limit. |
| Make Independent twice-cold round trip | `interactive-0d65ef00ace04af29475daf51461c0c8/report.json` | PASS: two fresh-process reopen transitions and scoped identity/source/foreign-state assertions; not the production song. |

The first Undo invocation, `interactive-acc071509c4f49b49591d2890e3a4815/report.json`,
was ERROR in preflight because that configuration omitted the locally available
AutoHotkey path. It did not launch Renoise or deploy an installation. The rerun
used the existing configured executable; no installation/download was required.
The full ordered invocation list is `tmp/acceptance-investigation-prerequisites.json`.

### Verification of this working tree

- ACID Lua: **70/70 PASS**, `tmp/acceptance-investigation-final-acid.log`.
- Full repository Lua: **73/73 PASS**, `tmp/acceptance-investigation-final-lua.log`.
- Offline: **18/18 groups PASS**, `tmp/acceptance-investigation-offline.log`;
  printed negative-fixture FAILs are expected controls, not suite failures.
- Runner argument/lifecycle checks: **PASS**,
  `tmp/acceptance-investigation-final-runner.log`.
- Explicit release/development packaging: **PASS**,
  `tmp/acceptance-investigation-package.log` and
  `tmp/acceptance-investigation-package-dev.log`. Release archive
  `tmp/acceptance-investigation-release/com.david303ttl.ACID_0.1.xrnx` has 31
  entries, root manifest/main, preserved module paths and no SDK/tests/dev code.
- Independent review: concrete Detailed-aggregation and timer-cleanup defects
  fixed; missing full acceptance evidence explicitly retained above.
- `git diff --check`: **PASS**. No push or merge.

These checks do not complete the requested final phase because full production
journeys, mixed playback and scaled persistence/recovery are still absent.

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

## Focused metadata recovery acceptance (2026-11-02)

Renoise 3.5.4 / API 6.2, PowerShell 7, working tree with scoped metadata receipts.
Report: `tmp/interactive-df4b9b7e770246e3b651e291b5e7efc4/report.json`.
The runner owns both processes (8580 → 14404), stages fixtures, applies guarded
Enter input to the prepared dialog, saves the XRNS and checks it in a fresh
process. Original installation restoration passed; both test processes stopped.

```powershell
./scripts/run_interactive_tests.ps1 -Suite Native -Scenario transport -AcceptanceCase metadata-recovery -Install -ApproveDisposableSong -TestEnvironment <keyboard-environment.json> -AllowKeyboardFocusActivation
```

| Check | Result |
| --- | --- |
| Owned and New label persistence | PASS: exact accepted label/custom bit, unchanged musical revision, separate metadata revision, unchanged target identity/source/settings/native content and foreign phrase preimages. |
| Unrelated native recovery failure | PASS: the injected recovery snapshot seam throws if called; both renames complete with zero recovery reads, generation captures or render calls. This is synthetic failure injection over native objects. |
| Uncertain metadata setter | PASS for both destinations: changed storage blocks further label writes and generation, without accepting attempted labels or advancing metadata history. Setter faults forward to real song storage; they do not emulate disk failure. |
| Explicit recovery proof | PASS: changed/nonexact bytes reject; exact preimages permit inspection without clearing the blocker; storage drift after proof rejects clearance; a fresh proof clears only explicitly and cannot be reused. |
| Unrelated native edits | PASS: an unrelated phrase note changes while blocked; metadata recovery and retry succeed without reverting it. |
| Save and cold reopen | PASS: exact full persisted baseline comparison; owned label, New draft label/custom bit and both unrelated note edits survive. Restoring both editor destinations makes no persisted changes or generation requests. |
| Deterministic regressions | PASS: 74/74 ACID-selected Lua specs under Lua 5.1, including execution of the acceptance module and a negative test that restores whole-song capture. Runner and development package suites pass. |

The runner stages fixtures even when `transport` is the only selected catalog
scenario if a native acceptance case also runs. An empty catalog selection
remains valid for this acceptance-only path.

This covers the runtime rename seam and metadata receipts. Planned Gate 6 label
editor and ACID history controls remain separate. Native host metadata Undo/Redo
still has its recorded no-entry failure; audition sound/timing is unaffected by
this acceptance result.

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
