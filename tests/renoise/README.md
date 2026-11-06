# Renoise host tests

The interactive runner requires Windows, PowerShell 7, Lua 5.1 or newer, and
Renoise 3.5. It builds a disposable ACID development bundle under ignored
`tmp/`, installs it for the test, and restores backed-up tool files that remain
unchanged. The selected song may be reset, so use `-ApproveDisposableSong` only
with a disposable song.

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong
./scripts/run_interactive_tests.ps1 -RenoiseProcessId <pid> -Install -ApproveDisposableSong
```

Use `-RenoiseExe <path>` and `-ToolsDirectory <path>` to override executable and
tool-folder discovery. Most Native cases do not use keyboard input. Undo and metadata cases that do are listed below and follow the focus rules. The runner
validates the target process, backs up the installed tool before replacement,
and restores it after the driver shuts down. If shutdown cannot be confirmed or
deployed files changed, it preserves backups for recovery.

## Native acceptance cases

Choose the case that covers the changed behavior. Without `-AcceptanceCase`, the
runner executes transport and the scenario catalog.

| Case | Coverage |
| --- | --- |
| `persistence-failures` | Storage and phrase rollback after injected setter failures |
| `metadata-undo` | Label rename with native Undo/Redo |
| `metadata-recovery` | Rename failure recovery and cold-process readback |
| `editor-responsiveness` | Program/Grid edits and callback behavior |
| `gui-layout` | Compact and expanded GUI layouts |
| `gui-lifecycle` | Target changes, draft restoration and generation |
| `integrity-observers` | Integrity blocking after reopen or target change |
| `writer-recovery` | Post-commit recovery and blocked-editor behavior |
| `ownership-negatives` | Rejection of phrases without local ownership records |
| `cold-reopen-regenerate`, `cold-reopen-verify` | Persistence across a cold reopen |
| `multi-instrument-workflow` | Workflow across multiple instruments |
| `revision-undo`, `revision-live-undo` | Revision Undo/Redo behavior |

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase persistence-failures
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase gui-layout
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase metadata-undo -TestEnvironment <keyboard-environment.json> -AllowKeyboardFocusActivation
```

`metadata-undo`, `metadata-recovery`, `revision-undo` and `revision-live-undo`
use AutoHotkey to press Enter and require its keyboard setup. For shared desktop
runs, use an existing Renoise PID that owns foreground focus. `metadata-recovery`
requires a runner-launched process for cold reopen, so run it only in a dedicated
interactive session with `-AllowKeyboardFocusActivation`. Other Native cases do
not require AutoHotkey. For visual layout, audible output or physical
interaction, follow the relevant [manual check](../README.md#renoise-checks).

## Keyboard suite

`Keyboard` and `All` require AutoHotkey v2. Renoise stores key assignments per
user; ACID has no default shortcut. Configure the shortcut assigned to
`Global:ACID:Show` in an external JSON file:

```json
{
  "RenoiseExe": "<path to Renoise.exe>",
  "Keyboard": {
    "ShowShortcut": "^!b",
    "AutoHotkeyPath": "<optional path to AutoHotkey64.exe>",
    "TimeoutSeconds": 10
  }
}
```

```powershell
./scripts/run_interactive_tests.ps1 -Suite Keyboard -RenoiseProcessId <pid> -TestEnvironment <path> -Install -ApproveDisposableSong
```

On a shared desktop, pass an existing Renoise PID. The helper sends input only
while that process owns foreground focus; it does not activate windows.
`-AllowKeyboardFocusActivation` permits activation and is intended for a
dedicated interactive session.

## Scenario fixtures

Scenarios are JSON files in `tests/renoise/acid/scenarios/`; fixture songs are
flat `.xrns` files in `tests/renoise/acid/fixtures/`. See
[phrase-inventory.json](acid/scenarios/phrase-inventory.json) for an
example. Each scenario has a unique lowercase `name`, `fixture`, a
`preconditions` object (optional non-negative `instrument_count` and
`phrase_count`), fixed `actions` and `waits`, nonempty `unchanged` snapshot
paths, and nonempty `{path, expected}` assertions. `description` is optional.
`expects` defaults to `pass`; for `fail`, provide nonempty `expected_diffs`
entries with `path`, `expected` and `actual`.

The fixed `actions` sequence is `document.new`, `fixture.load`, then two
`song.snapshot` reads. `waits` must be `document.changed`, `inventory.settled`,
`snapshot.stable`. Snapshot paths use dot notation and zero-based array indexes,
for example `instruments.0.phrases.0.name`. The complete snapshots are compared
in addition to declared assertions.

```powershell
./scripts/run_interactive_tests.ps1 -Scenario transport -Install -ApproveDisposableSong
./scripts/run_interactive_tests.ps1 -Scenario <scenario-name> -Install -ApproveDisposableSong
./scripts/run_interactive_tests.ps1 -VerifyScenarioOrder -Install -ApproveDisposableSong
```

## Offline harness checks

```powershell
./scripts/test_host_preflight.ps1
./tests/renoise/runner_spec.ps1
./tests/renoise/test_package_dev.ps1
lua tests/renoise/remote_driver_spec.lua
lua tests/renoise/acceptance_cases_spec.lua
```

The bundle contains the ACID tool, loopback-only test driver, session file and
fixture directory. Build and transport checks do not establish native GUI
behavior, playback, Undo/Redo or persistence.
