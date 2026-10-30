# Test suite

The pure Lua specs run without Renoise. Each spec is launched in its own Lua
process so mocked Renoise APIs and loaded modules cannot affect another tool.

From the repository root, run every spec with PowerShell:

```powershell
./scripts/run_tests.ps1
```

If Lua is installed under a different command name, pass it explicitly:

```powershell
./scripts/run_tests.ps1 -LuaCommand lua5.1
```

The development package integration suite runs on Windows and requires Lua
5.1. Install instructions are in the
[development setup guide](../docs/DEVELOPMENT.md#required-tools). After
extracting a Lua 5.1.x Windows build, run:

```powershell
$lua51 = Join-Path $env:LOCALAPPDATA 'Programs/Lua51/lua5.1.exe'
./tests/renoise/test_package_dev.ps1 -LuaCommand $lua51
```

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
spike evidence is required. Keyboard coverage is not implemented. Offline mocks
and manual diagnostics do not count as native test passes. See
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
