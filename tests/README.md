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

A single spec can also be run directly from the repository root, for example:

```sh
lua tests/arp/arp_writer_spec.lua
lua tests/acid/acid_compiler_spec.lua
```

`bootstrap.lua` configures module lookup for the selected tool. Specs still run
as separate processes when using the suite runner.

## Real Renoise and manual checks

The pure Lua tests do not replace real-host verification. The ACID host-preflight
and manual behavior spike are described in [Renoise host testing](renoise/README.md):

```powershell
pwsh -NoProfile -File ./scripts/test_host_preflight.ps1
lua tests/renoise/spike_tool_spec.lua
```

The live Windows preflight/spike requires an explicitly selected Renoise PID
and a disposable song. It may run on the current desktop; a separate Windows
account or VM is not required. Automated Native/Keyboard E2E remains pending
until the T0 runner is implemented; manual observations are not automated passes.

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
