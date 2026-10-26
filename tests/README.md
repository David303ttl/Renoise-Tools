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
lua tests/arp/arp_v04_spec.lua
lua tests/acid/acid_sequencer_spec.lua
```

`bootstrap.lua` configures module lookup for the selected tool. Specs still run
as separate processes when using the suite runner.

## Renoise manual checks

The pure Lua tests do not replace checks in Renoise 3.5+. Use a disposable song
and follow the relevant guides:

- [ARP v0.4 gates and regeneration](arp/arp_v04_manual.md)
- [ARP v0.5 routing and note divisions](arp/arp_v05_manual.md)
- ACID read-only scaffold: open Tools > ACID and inspect the selected pattern

Keep the existing DigitaktSampleChain tool installed and confirm it still opens
after reloading tools. Real Renoise integration, playback, undo, and save/reload
behavior require manual validation.
