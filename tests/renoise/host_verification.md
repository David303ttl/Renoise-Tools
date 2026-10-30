# Renoise verification

Environment: Windows, PowerShell 7, Lua 5.1, Renoise 3.5.4, API 6.2.

| Check | Result |
| --- | --- |
| Full offline runner | PASS: 18 groups; final Lua rerun 67/67; deterministic audio/oracle checks pass |
| Editor responsiveness | PASS: 30 UI actions below 30 ms; note/octave/command maxima 1.66/1.72/1.92 ms; armed/busy edits 3.89/28.22 ms with latest-note commit; clean edits perform no native cell scans or seal hashes; cold phrase validation 59.48 ms; `interactive-b0e25d94064c43f0a7f4f5f40ae9c6b3` |
| Native and keyboard suite | PASS: transport, both inventory scenarios, real ACID shortcut, Escape and native instrument navigation; `interactive-8d3b6767f79c4cf5816a609adc228a07` |
| Make Independent round trip | PASS: native identity/source preservation, same-object regeneration, save/reload and reopened regeneration; `interactive-6506582d68a141a6b0f1a421455bf238` |
| Draft Recovery | PASS: native recovery copy/discard and preserved drafts; `interactive-03a224e4971d48d6a8e8f39517157337` |
| Integrity and column observers | PASS: post-commit adoption blocker, explicit revalidation, fresh commit, idle/busy column metadata notifications and detach; `interactive-6b9b6691929a4e07af6588492a43c294` |
| Test-driver startup | PASS: idle-only startup, unload cancellation, bounded read-only handshake reconnect, local TCP regression and fresh native smoke; `interactive-d07c3207b0014ace897f3fc407640826` |
| Offline preflight, transport and runner regressions | PASS |
| Fresh-launch Native smoke | PASS: handshake, document reset, stable inventory, driver shutdown and installation restoration |
| Selected-PID Native smoke with a concurrent instance | PASS: target startup resumed after deployment; both instances remained open; original installation restored |
| Loaded-instance reload | PASS: native Reload All Tools, Native smoke, original-file restoration/reload and ACID dialog opening; both instances preserved |
| Host startup timeout | PASS: exit 1, ERROR report, verified backups retained; both instances preserved; recovery restored original files |
| Active-connection loss on driver reload | PASS: exit 1, ERROR report, verified backups retained; both instances preserved; recovery restored original files |
| Release/development package separation | PASS |
| Keyboard E2E | PASS: unattended shortcut, dialog visibility, native navigation readback and input guards; see dated record below |
| Playback, rendering, undo and persistence acceptance | Not covered by the transport smoke; use the ACID manual guides |

Snapshots contain native inventory values and selection indices. Indices describe
positions at readback time, not persistent object identity. Driver shutdown is
complete only after its per-run completion file is observed and removed.

## Runner verification rerun (2026-10-29)

The fresh-launch command was executed from the repository root in PowerShell 7:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -StartupTimeoutSeconds 45
```

Run `51d5a00dea1e4fccab5e75aa5ac1708e` passed on Renoise 3.5.4 / API 6.2,
against source commit `5298732dab24bee1448f6b032a273d04a7e8b244` before the
runner corrections in this rerun. Its inspected report is retained locally at
`tmp/interactive-51d5a00dea1e4fccab5e75aa5ac1708e/report.json`; temporary
reports and credentials remain untracked. The report independently records ten
instruments, zero phrases, document epoch 1, matching snapshots and empty queues.
The snapshot SHA-256 is
`61256cf58875dea9f6046a2b59bd569ccddc7bf0a6091f1b482d737854ba723e`.
Driver shutdown and original-installation restoration passed. Graceful process
closure timed out; identity-checked forced termination closed only the
runner-launched disposable process.

Final-change verification on 2026-10-30 used the same command and passed as run
`4cd6c1ca637b4766b8c1bb5d33da34a1`, with report at
`tmp/interactive-4cd6c1ca637b4766b8c1bb5d33da34a1/report.json`.
Both snapshot epochs matched the reset epoch, with the same inventory and
snapshot digest above. Driver shutdown, identity-checked process cleanup and
installation restoration passed. The intermediate verification run
`d67ebbc970f847428a975e7152cc7426` also passed. These reports were inspected;
they describe the local working tree based on the source commit above, including
the runner corrections, rather than a newly committed revision.

Offline second-pass checks passed: runner transport/ownership/installation specs
(including refusal before sending on process-identity failure, nonboolean or
missing response fields, startup timeout, connection loss and retained-backup
paths), host preflight, development packaging, transport Lua specs, all 50
repository Lua specs, release packaging (28 runtime files), and `git diff --check`.

The selected-PID, loaded-instance, concurrent-instance and native interruption
results in the table above are earlier observations, not new executions in this
rerun. Their original temporary report identifiers were not recorded. Reproduce
selected-instance checks with the following command, using a disposable song and
reloading ACID in the selected instance when prompted:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -RenoiseProcessId <pid>
```

Inspect the emitted `report.json`, its operation trace and both snapshot files;
check installation restoration and that developer-owned instances remain open.
For startup timeout or active-connection loss, require a nonzero exit and ERROR
report, then inspect the reported retained backups before recovery. These
interruption checks must use controlled disposable instances.

Manual host checks cover clean new/save/load, dirty-song Cancel/Save/Discard,
tool reload and foreground activation. `save_song_as` can write a fixture without
delivering a saved-document notification; verify completion from native readback.

## Native fixture and isolation verification (2026-10-30)

T0.5 passes on Renoise 3.5.4 / API 6.2. The independently constructed fixture
contains two foreign phrases, visible/hidden/tail note and effect sentinels,
12 named note columns with a hidden muted column, mappings, and exact ACID
source/settings/draft bytes. Those 797 store bytes are shared with
`tests/acid/fixtures/pattern_store.txt` and its offline codec assertions.
No production writer supplies expected output, and no owned association or
persistent host identity is claimed by these read-only cases.

The final fixture builder completed `-ApproveInstall -Force`, including verified
installation restoration and atomic replacement of the existing fixture. Its
transport tempo is explicitly 120; generation does not inherit that preference.
The checked-in 4088-byte XRNS has SHA-256
`647262514c0ceff0435997aa8a4fd160a22fe1e904decf32580f46a77aff3b33`.

Successful full-catalog runs bracketed a separate unexpected
assertion failure; the final run also verifies explicit expected/observed diff lists:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -StartupTimeoutSeconds 45
```

| Execution | Report under ignored `tmp/` | Result |
| --- | --- | --- |
| Full catalog | `interactive-0d26b899097646178ff057dd93683a5e/report.json` | PASS: transport, phrase inventory, exact expected-diff case |
| Temporary unexpected assertion failure | `interactive-b50bf059ac874b489151ce580044a8c9/report.json` | FAIL as intended, exit 1: `instrument_count` expected 3, actual 2 |
| Final full catalog after second-pass corrections | `interactive-43091f996b1044bbad9781e8d46cfb3b/report.json` | PASS: transport and both native fixture scenarios |

The temporary failure scenario was removed afterward. Each catalog case resets
and loads the fixture independently; the negative case requires exactly the
note-value diff expected 49 / actual 48. Final readbacks are stable, no undo/redo
history is available, selection stays 1/1, and pending/queued commands are zero.
The final run resets to a clean document at epoch 6. Snapshot values from both
scenarios and both successful runs match exactly after excluding only the
lifecycle epoch. Since these runs use the same sorted catalog order, they
establish repeatability but do not establish order independence. Snapshot SHA-256 values
for the final run are `872950796fb3028bfbd0abdc22089d3c2855c5cf2c2bf09bcdd38411c304c317`
(inventory, epoch 3) and
`cdd1a68bf904ffd9cdd84f96e652be29b5e59e0b596533666178e1c02ee4d1c7`
(expected diff, epoch 5), each repeated identically within its case.

Driver shutdown and original installation restoration passed in all three runs.
Only runner-launched disposable processes were closed; graceful closure timed
out and the existing identity-checked forced cleanup was used. Reports describe
the working tree based on `f1d33be41c75ed237e3adee9b0f8493274195744`, including
uncommitted harness changes, rather than a new commit.

Second-pass review corrected exact-name capture, hidden column metadata,
culture/null-safe canonical values, catalog array handling, StrictMode report
projection, missing unchanged paths, fallback count validation, monotonic epochs,
probe backup discovery and safe fixture publication. Offline checks pass:
all 50 repository Lua specs, driver/probe specs, runner specs, host preflight,
development package checks, release packaging (28 runtime files), and diff checks.
The release archive retains root `main.lua`/`manifest.xml`, private modules, and
no fixtures, driver, SDK or documentation.

This closes native fixture/isolation coverage only. Writer identity/transactions,
actual undo/redo consistency and musical playback remain with their later owning
steps; full M4 acceptance remains open.

## Keyboard E2E host acceptance (2026-10-30)

The `Keyboard` suite passed unattended on Renoise 3.5.4 Demo / API 6.2 with
AutoHotkey v2.0.31. The saved developer keymap assigns Ctrl+Alt+B (`^!b`) to
`Global:ACID:Show`. The runner activated the exact Renoise PID before each input
sequence and verified foreground ownership; no manual focus or tool reload was
needed. This host acceptance predates the revised opt-in activation policy;
no post-hardening Windows host rerun is claimed.

```powershell
./scripts/run_interactive_tests.ps1 -Suite Keyboard -TestEnvironment '<path>' -StartupTimeoutSeconds 30 -Install -ApproveDisposableSong
```

Run `82763e548e7a4a2e891b3f98676493dc` passed. The report is retained at
`tmp/interactive-82763e548e7a4a2e891b3f98676493dc/report.json`. It records the
registered production keybinding, one invocation of the real `gui.show()`
handler, observed dialog open/close, and native Alt+Down selection readback
from instrument 1 to 2. Missing mapping, wrong PID, stolen focus and GUI timeout
guards all passed without sending input. Driver shutdown and installation
restoration passed. Renoise did not close cleanly, so the runner used its
identity-checked forced cleanup on the runner-launched disposable process only.

The run used the current working tree based on the recorded repository HEAD,
including uncommitted T0.6 changes; it is host evidence for that tree, not a
committed revision.

## Scenario-order acceptance follow-up (2026-10-30)

The same-driver scenario-order acceptance passed on Renoise 3.5.4 / API 6.2:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -VerifyScenarioOrder -StartupTimeoutSeconds 45
```

Run `7ab2827bc12c4629819c6137473eeade` passed against source commit
`0e8a971ba7445361c1dd997a1eaa86ac34651ef6`; its report is retained at
`tmp/interactive-7ab2827bc12c4629819c6137473eeade/report.json`. The two
scenarios ran individually, then in reverse order. Each scenario's two
canonical snapshots matched between both runs after excluding only the
top-level `document_epoch`. All four fixture loads recorded two consecutive
matching idle cycles at the loaded document epoch. Driver shutdown and original
installation restoration passed. The report records the repository HEAD; the
run included the uncommitted harness changes described here.

The first fresh-process attempt (`b4a57973e3b4438493e8051dcf4b0914`) crashed
before scenario execution; the runner stopped only its launched process and
restored the original installation. The clean retry above completed the full
acceptance. Both reports remain under ignored `tmp/` artifacts.

## T0.7 harness integration and Native E2E (2026-10-30)

Environment: PowerShell 7, Lua 5.1.5, Renoise 3.5.4, ACID manifest API 6.2 / tool 0.1.
The report source commit is `45f91dece2e784ce4a4c77a7566c29f0839bbeff`; each
report below describes that source tree with the uncommitted T0.7 changes.

The offline discovery command passed all 53 Lua specs, including the three
offline Renoise harness specs. The preflight, runner, development-package and
release-license checks also passed:

```powershell
$lua51 = Join-Path $env:LOCALAPPDATA 'Programs/Lua-5.1.5/lua51.exe'
./scripts/run_offline_tests.ps1 -LuaCommand $lua51
```

The native full-catalog run passed authenticated protocol ping and capabilities,
observed new-document completion at epoch 1, stable read-only inventory, both
fixture scenarios and final reset. Transport inventory readback was 10
instruments and zero phrases. The repeated `phrase-inventory` scenario passed
before and after the negative probe.

```powershell
$renoise = Join-Path $env:ProgramFiles 'Renoise 3.5.4/Renoise.exe'
./scripts/run_interactive_tests.ps1 -RenoiseExe $renoise -Install -ApproveDisposableSong -StartupTimeoutSeconds 45
./scripts/run_interactive_tests.ps1 -RenoiseExe $renoise -Install -ApproveDisposableSong -Scenario phrase-inventory -StartupTimeoutSeconds 45
./scripts/run_interactive_tests.ps1 -RenoiseExe $renoise -Install -ApproveDisposableSong -Scenario t07-deliberate-assertion -StartupTimeoutSeconds 90
```

| Report under ignored `tmp/` | Result |
| --- | --- |
| `interactive-a6ea38cfaeb04744ad22c2a118b99b01/report.json` | PASS: transport ping/capabilities, reset, inventory and both catalog scenarios |
| `interactive-0a2e06fe303d4e7187699f8ca35015b7/report.json` | PASS: repeated `phrase-inventory` |
| `interactive-378bfdcef0634221967508b9f19cb403/report.json` | ERROR: Renoise closed transport before a terminal response; no scenario ran; the launched process was stopped and installation restored |
| `interactive-356d4e5c71af48409ab3825e16243ba3/report.json` | PASS: clean `phrase-inventory` retry after the transport error |
| `interactive-64584bf6788b489b9c4fe3ca5a55083c/report.json` | FAIL as intended, exit 1: temporary assertion expected note value 49 and independently read 48; document cleanup, driver shutdown and installation restoration passed |
| `interactive-5eef7d26e38e4d7299cf3502dc625bfb/report.json` | PASS: `phrase-inventory` after the deliberate assertion failure |

The deliberate assertion scenario was added temporarily to the scenario catalog,
run with `-Scenario t07-deliberate-assertion`, and removed after the run. The
first attempt returned ERROR on transport closure; the retry returned the
expected FAIL classification and nonzero exit. The next Native run passed.
The Keyboard suite was not selected in this T0.7 execution; the prior Keyboard
acceptance is recorded above. The Native suite ran without a keyboard mapping or
AutoHotkey. Playback, undo/redo and other visual or audible checks remain
MANUAL under their ACID guides and are not claimed by this harness run.

## Lua compatibility and runner reporting verification (2026-10-30)

Environment: Windows, PowerShell 7, Lua 5.1.5 and Lua 5.4.6. Both interpreters
passed `scripts/run_offline_tests.ps1 -LuaCommand <interpreter>` with exit 0
against source commit `584e5cfc7bcdf81d2a8dc43d3526fd915bbd3e80` plus the
uncommitted runner reporting changes. Each run passed all 53 Lua specs and all
six offline check groups: interpreter policy, Lua specs, host preflight, runner,
development package and release package. The runner checks included scenario
status aggregation; development-package checks used the selected interpreter.
Logs are retained under ignored `tmp/offline-lua51.log` and
`tmp/offline-lua54.log`.

The first Lua 5.4 attempt passed the Lua specs and development-package checks,
but preflight, runner and release-package cleanup failed while resolving the
environment's short temporary-directory path. Both successful full runs set
process-local `TEMP` and `TMP` to the resolved repository directory
`tmp/offline-verification` before invoking the script. No scripts were changed
for this environment workaround.

These were offline checks using mocks, local transport and generated packages.
Renoise Native or Keyboard acceptance was not rerun; playback, undo/redo and
visual or audible behavior remain unverified by these runs.

## T0.8 coverage handoff and closeout (2026-10-30)

The harness handoff is complete. The [coverage table](README.md#coverage-handoff)
assigns remaining runtime acceptance to Steps 2.2–2.9, 3–6 and Step 8 A–E,
with an independent assertion, verification method and explicit pending status.
This closes T0 only; Step 8 and M4 remain open.

Environment: PowerShell 7, Lua 5.1.5, Renoise 3.5.4 Demo / API 6.2,
ACID tool 0.1. Runs used source HEAD
`f119838ccb8411bc30b8cc2340d6a3ce5c6b638b` plus the T0.8 working-tree
changes. Process-local temporary directories were resolved under ignored
`tmp/handoff-verification` to avoid short-path resolution issues.

```powershell
$taskTemp = Join-Path (Get-Location) 'tmp/handoff-verification'
New-Item -ItemType Directory -Force $taskTemp | Out-Null
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
$lua51 = Join-Path $env:LOCALAPPDATA 'Programs/Lua-5.1.5/lua51.exe'
./scripts/run_offline_tests.ps1 -LuaCommand $lua51
./scripts/package.ps1 -Tool ACID
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -VerifyScenarioOrder -StartupTimeoutSeconds 45
```

| Check / artifact under ignored `tmp/` | Result |
| --- | --- |
| `handoff-offline.log` | PASS: all six offline groups; 53 Lua specs on Lua 5.1.5, interpreter policy, preflight, runner, development package and release-license checks |
| ACID release/development package review | PASS: 28 runtime files; root manifest/main and private modules preserved; no SDK, tests, fixtures, driver or documentation in release; staged payload and fixture hashes match |
| `interactive-19a646d346c24fa5b44a0a02663b0d2a/report.json` | PASS: authenticated ping/capabilities, observed new document, inventory and both scenarios individually and in reverse order; all four loads settled for two matching idle cycles; canonical snapshots match excluding only document epoch |
| Native cleanup in the same report | PASS: scenario reset, driver shutdown and installation restore; normal process close required identity-checked forced cleanup of the runner-launched disposable process |
| `interactive-2bc729b344254d39b9cf1223109a4014/report.json` | ERROR at optional Keyboard preflight: no existing selected PID supplied; nonintrusive mode refused a fresh launch; no tool installation, song changes or keyboard input occurred |

The optional Keyboard attempt used:

```powershell
./scripts/run_interactive_tests.ps1 -Suite Keyboard -TestEnvironment tmp/acid-e2e-environment.json -Install -ApproveDisposableSong -StartupTimeoutSeconds 45
```

That environment file is an ignored local configuration, shaped as documented in
the test guide. No existing Renoise process was available, and focus activation
was not enabled. The attempt is ERROR, not PASS or an executed keyboard journey;
post-policy Keyboard host acceptance remains pending. Earlier shortcut/focus
acceptance and the T0.7 deliberate assertion failure retain their separately
dated evidence; neither was rerun here.

Dependency review found only private production imports and no unused runtime
test hooks or duplicate native fixtures. The dependency spec now rejects
development module paths and file-loader bypasses of the private require graph;
negative controls and the actual graph pass. Development packaging derives the
driver/bootstrap from test sources without changing production entrypoints.
Tracked Markdown was checked for machine-specific paths. Production interfaces,
manifest/API versions, persisted formats and transport wire formats are unchanged.

The applicable Native foundation checks pass. Native writer undo/redo and
grouping, source/draft save/reload, final-writer field preservation, copy
resolution and lifecycle safety remain PENDING with their owners in the table.
Visual and audible checks remain MANUAL / PENDING. Fixture loads and an empty
undo history do not establish writer persistence or undo behavior. No new
save/reload, playback, visual or audible acceptance was performed. Add those
scenarios with their owning behavior instead of simulating future writer passes
in the harness.
