# Renoise development setup

ACID and DigitaktSampleChain target Renoise 3.5 / scripting API 6.2 and
Lua 5.1 syntax. Repository scripts require PowerShell 7. Tests accept Lua 5.1 or
newer, including LuaJIT 2.x; set `-LuaCommand` to select an executable. A newer
local interpreter does not verify Lua 5.1 compatibility.

```powershell
./scripts/run_tests.ps1 -Tool ACID -LuaCommand lua5.1
./scripts/package.ps1 -Tool ACID
```

Run the affected Lua suite after Lua changes. Package after changing runtime
layout or package inputs. Packages contain each tool's runtime files,
`manifest.xml`, `main.lua` and `LICENSE`; they exclude development files and the
SDK.

## Renoise API references

When a Renoise API change needs references that are not installed, run:

```powershell
./scripts/setup_sdk.ps1
```

The script installs the checksum-pinned API 6.2 starter pack under
`sdk/renoise-api-6.2/`. Inspect the relevant definitions and offline docs before
changing API calls. The SDK is ignored by Git and excluded from packages.
`.luarc.json` configures LuaLS for Lua 5.1 and the SDK; install the Lua extension
for editor support.

## Host checks

Use Renoise checks when correctness depends on host behavior that mocks cannot
establish, such as playback, native GUI behavior, undo or save/reload. Run only
the cases relevant to the change in a disposable song; see [test commands and
cases](../tests/README.md#renoise-checks) and the [host runner
guide](../tests/renoise/README.md).

The runner can launch a fresh Renoise instance or target one by PID. It backs up
installed tool files before deployment and restores files that remain unchanged.
Keyboard tests use AutoHotkey v2. They require Renoise already in the foreground
unless `-AllowKeyboardFocusActivation` is enabled for a dedicated interactive
session.
