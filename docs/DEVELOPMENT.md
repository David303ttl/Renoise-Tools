# Renoise development setup

ARP and ACID target Renoise 3.5 / scripting API 6.2. The existing frozen
DigitaktSampleChain tool retains its API 6.1 manifest.

## Required tools

Repository PowerShell scripts require PowerShell 7 (`pwsh`). On Windows, install
it with WinGet:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Open a new terminal and check `$PSVersionTable.PSVersion` reports version 7 or
later. Microsoft also documents [other PowerShell installation methods](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows).

Local tests and development-package checks accept Lua 5.1 or newer, including
LuaJIT 2.x (which reports Lua 5.1 through `_VERSION`). Scripts use `lua` from
`PATH` by default and report the executable and language version used. Override
it with `-LuaCommand` when needed:

```powershell
./scripts/run_tests.ps1
./tests/renoise/test_package_dev.ps1 -LuaCommand lua5.4
```

Lua 5.0 and older are rejected. Future versions are accepted when compatible
with the test harness. Production ARP and ACID code must retain Lua 5.1
compatibility for Renoise's LuaJIT runtime. Run the baseline specs explicitly
with `./scripts/run_tests.ps1 -LuaCommand lua5.1`;
passing locally with a newer interpreter does not establish baseline
compatibility. Keep `.luarc.json` set to Lua 5.1.

The development package suite uses Windows ACLs and therefore runs on Windows.
Native integration checks require a Windows installation of Renoise. ARP and
ACID target Renoise 3.5 / API 6.2; get Renoise from its
[downloads page](https://renoise.com/downloads).

The Renoise `Keyboard` and `All` interactive suites additionally require
AutoHotkey v2. Download it from the
[official AutoHotkey releases](https://github.com/AutoHotkey/AutoHotkey/releases).
The current developer keymap assigns Ctrl+Alt+B to `Global:ACID:Show`; the runner
configuration represents it as `^!b`. Renoise stores shortcut assignments per
user, and ACID supplies no default. On a shared desktop, keyboard testing will not activate Renoise or steal foreground focus. It requires an existing `-RenoiseProcessId` and fails safely when Renoise is not foreground. Genuine unattended keyboard tests require a separate interactive Windows session and explicit `-AllowKeyboardFocusActivation`; Native API tests remain focus-free and require no AutoHotkey.

## Install the API reference

Use PowerShell 7 (`pwsh`) for all repository scripts. From the repository root:

```powershell
pwsh -NoProfile -File ./scripts/setup_sdk.ps1
```

The script downloads the official
[API 6.2 starter pack](https://github.com/renoise/xrnx/releases/tag/API-6.2),
checks its pinned SHA-256, and installs it into `sdk/renoise-api-6.2/`.
The SDK is ignored by Git and excluded from tool packages. It includes API
definitions, the offline scripting book, and example tools.

Rerunning the installer checks installed file hashes. Incomplete or modified SDK
contents are replaced from the verified release; keep development changes in
your own tool directories.

## Editor support

Install the [Lua extension by LuaLS](https://marketplace.visualstudio.com/items?itemName=sumneko.lua)
in VS Code, then open the repository folder. The committed `.luarc.json` selects
Lua 5.1 and points to the SDK definitions and Renoise's LuaLS plugin. Reload the
editor after the first SDK installation if its completion list has not updated.

The configuration follows the
[official API 6.2 editor settings](https://github.com/renoise/xrnx/blob/API-6.2/.vscode/settings.json).
It configures editor analysis; it does not install a Lua interpreter or Renoise.
The different tool bundles have overlapping module names, so their runtime
search paths are not merged into a single global editor path.

Open `sdk/renoise-api-6.2/docs/index.html` for the offline book. Search
`sdk/renoise-api-6.2/definitions/` for a specific method or property before using
it. Keep example tools as references; install them separately only when needed.

## Code naming, comments and documentation

Use behavior and responsibility to name code files, modules, symbols, tests and
fixture formats. Keep roadmap, blueprint, milestone, phase and work-step labels
such as `M1` and `M2` out of these names, code comments, generated code,
diagnostics and UI text. Planning labels and implementation history belong in
documentation.

Comments should briefly explain behavior, invariants, constraints or the reason
for a non-obvious decision. Avoid task narratives, progress reports, future-work
prose and version-history commentary. Meaningful domain terms such as sequencer
steps and signal phase remain appropriate. Manifest versions, persisted schema
identifiers and compatibility markers must retain their functional meaning;
do not rename them as cosmetic cleanup.

Documentation must use portable paths: repository-relative paths for local
files, pinned upstream links for reference sources, or sanitized placeholders
for external checkouts. Never commit machine-specific absolute paths, usernames
or local workspace locations.

## Development loop

1. Check the relevant API definitions and documentation.
2. Edit one tool inside its `.xrnx` directory, preserving self-contained imports.
3. Run the pure-Lua specs with a separately installed Lua 5.1 or newer interpreter:

   ```powershell
   pwsh -NoProfile -File ./scripts/run_tests.ps1
   ```

4. Build an installable archive:

   ```powershell
   pwsh -NoProfile -File ./scripts/package.ps1 -Tool ACID
   ```

5. Install the archive from `dist/` into Renoise, or use the tool's documented
   development installation. Perform the relevant [Renoise checks](../tests/README.md)
   in a disposable song.

## Real Renoise testing

Run `./scripts/run_offline_tests.ps1` for all 18 offline groups, including Lua,
PowerShell analyzers, oracle validation, harness and packaging checks.

Use your normal Renoise installation. Other Renoise instances and virtual desktops
may remain in use; no separate account, VM, profile attestation or trace evidence
is required. The Windows Native runner starts a fresh instance by default:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong
```

Use `-RenoiseProcessId <pid>` to select an existing instance with a disposable
song. Override discovery with `-RenoiseExe '<path>'` or `-ToolsDirectory '<path>'`.
The runner verifies its target, backs up the installation, stops its test driver,
and restores unchanged files. Existing Renoise instances remain open. See
[Renoise testing](../tests/renoise/README.md) for offline harness checks and details.
Keyboard E2E is available through the documented `Keyboard` or `All` suite;
its setup and host acceptance are separate from the Native suite.
Release XRNX tools have no dependency on the harness or its developer setup.

Plain-Lua tests verify model logic and mocked API interactions. Actual playback,
native phrase rendering, GUI behavior, undo and save/reload require Renoise.
