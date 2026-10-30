# Test suite

The pure Lua specs run without Renoise. Each spec is launched in its own Lua
process so mocked Renoise APIs and loaded modules cannot affect another tool.
Default discovery includes the offline Renoise driver and fixture-probe specs;
`-Tool ACID` includes those harness specs, and `-Tool Renoise` selects only them.

From the repository root, run every spec with PowerShell:

```powershell
./scripts/run_tests.ps1
```

If Lua is installed under a different command name, pass it explicitly:

```powershell
./scripts/run_tests.ps1 -LuaCommand lua5.1
```

Run the offline Lua, PowerShell preflight, runner and package checks with one
command. Lua 5.1 or newer and LuaJIT 2.x are supported:

```powershell
./scripts/run_offline_tests.ps1 -LuaCommand lua5.1
```

The checks remain available individually: `./scripts/run_tests.ps1`,
`./scripts/test_host_preflight.ps1`, `./tests/renoise/runner_spec.ps1`,
`./tests/renoise/test_package_dev.ps1 -LuaCommand lua5.1`, and
`./tests/package_license_spec.ps1`.

The development package integration suite requires Windows and Lua 5.1 or newer.
Both runners check `_VERSION` and report the interpreter used. They default to
`lua` from `PATH`; use `-LuaCommand` for an explicit executable name or path.
See the [development setup guide](../docs/DEVELOPMENT.md#required-tools).
Production code remains Lua 5.1 compatible, with explicit Lua 5.1 baseline checks.
A newer local interpreter cannot validate that baseline.

A single spec can also be run directly from the repository root, for example:

```sh
lua tests/arp/arp_writer_spec.lua
lua tests/acid/acid_compiler_spec.lua
```

`bootstrap.lua` configures module lookup for the selected tool. Specs still run
as separate processes when using the suite runner.

## Real Renoise and manual checks

Run the available Native smoke in a fresh Renoise instance with a disposable song:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong
```

Add `-RenoiseProcessId <pid>` to use an existing instance. Other instances and
virtual desktops can remain in use. No desktop/profile attestation or recorded
spike evidence is required. Select `-Suite Keyboard` or `-Suite All` to run
keyboard checks; Native remains focus-free and does not require AutoHotkey.
Offline mocks and manual diagnostics do not count as native test passes. See
[Renoise testing](renoise/README.md) for executable/tool path overrides and checks.
Normal release tools are independent of this development harness.

For other manual checks, use a disposable song and follow the relevant guides:

- [ARP v0.4 gates and regeneration](arp/arp_v04_manual.md)
- [ARP v0.5 routing and note divisions](arp/arp_v05_manual.md)
- [ACID phrase playback](acid/acid_phrase_manual.md)
- [ACID articulation modes](acid/acid_slide_manual.md)
- [ACID sampler and control signals](acid/acid_sampler_control_manual.md)
- [ACID Repeat acceptance and deferred audio checks](acid/acid_loop_manual.md)
- [ACID Live Edit](acid/acid_live_edit_manual.md)
- [ACID regeneration, ownership and persistence](acid/acid_regeneration_manual.md)

Keep the existing DigitaktSampleChain tool installed and confirm it still opens
after reloading tools. Real Renoise integration, playback, undo and save/reload behavior require
manual validation until an executed native scenario explicitly covers them.

## Package license checks

Run `./tests/package_license_spec.ps1` with PowerShell 7 to build all XRNX
archives into a temporary directory and verify that each contains the
identical, full GPLv3 LICENSE at archive root.
