# Renoise development setup

ARP and ACID target Renoise 3.5 / scripting API 6.2. The existing frozen
DigitaktSampleChain tool retains its API 6.1 manifest.

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
3. Run the pure-Lua specs with a separately installed Lua 5.1-compatible interpreter:

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

Use the current Windows desktop and Renoise installation. No dedicated test
account, VM or special profile is required. Check the detected Renoise executable,
version, current session and selected PID before host tests. Use a fresh disposable
song; save or close working projects first. Never silently replace an existing
ACID installation, rewrite the user's keymap or terminate an existing Renoise
process. The future interactive runner will support both an explicitly selected
PID and a process it launches itself.

```powershell
pwsh -NoProfile -File ./scripts/test_host_preflight.ps1
lua tests/renoise/spike_tool_spec.lua
```

These are synthetic checks, not native E2E. For the current real-host manual
probe and live preflight invocation, see [Renoise test host](../tests/renoise/README.md).
T0.3 adds a mocked transport test; the PowerShell runner and automated
Native/Keyboard smoke remain pending T0.4–T0.8. Never count the manual behavior
spike or mocked transport as an automated Renoise scenario pass.

Plain-Lua tests verify model logic and mocked API interactions. Actual playback,
native phrase rendering, GUI behavior, undo and save/reload require Renoise.
