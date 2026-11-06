# Tests

## Lua suites

Run all specs, or select the affected tool. Each spec runs in a separate Lua
process so mocks and module caches stay isolated.

```powershell
./scripts/run_tests.ps1
./scripts/run_tests.ps1 -Tool ARP
./scripts/run_tests.ps1 -Tool ACID -LuaCommand lua5.1
./scripts/run_tests.ps1 -Tool Renoise
```

`-Tool ACID` includes the Renoise harness specs; `-Tool Renoise` runs only those
specs. The runner discovers root `.xrnx` tools and matching
`tests/<short-name>/` directories. To register a tool, add
`tests/<short-name>/config.lua`:

```lua
return { runtime_root = "com.example.MyTool.xrnx" }
```

Specs can live anywhere below that directory and start with
`dofile("tests/bootstrap.lua")("mytool")`. A spec can also run directly from
the repository root with `lua tests/<tool>/<spec>.lua`.

`./scripts/run_offline_tests.ps1` runs the Lua suites and repository offline
checks. Tool-specific offline checks are registered in
`tests/<short-name>/offline.ps1`.

## Renoise checks

Mocks cover model logic and API interactions they meaningfully simulate. Run
host checks when the change depends on actual Renoise behavior. Use a disposable
song and choose the relevant case; see the [host runner guide](renoise/README.md).

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase gui-layout
```

The runner supports `Native`, `Keyboard` and `All` suites. Keyboard tests and
Native cases that send keys require AutoHotkey v2 and an external configuration.
On a shared desktop, select a foreground Renoise instance with
`-RenoiseProcessId`. Window activation requires `-AllowKeyboardFocusActivation`.

Manual cases requiring listening or physical interaction are documented by tool:

- [ARP](arp/arp_manual.md)
- [ACID phrase playback](acid/acid_phrase_manual.md)
- [ACID timing](acid/acid_timing_manual.md)
- [ACID articulation](acid/acid_articulation_manual.md)
- [ACID destinations and sampler controls](acid/acid_phrase_destination_manual.md)
- [ACID live editing](acid/acid_live_edit_manual.md)
- [ACID editor presentation](acid/acid_editor_presentation_manual.md)
- [ACID operations](acid/acid_operations_manual.md)
- [DigitaktSampleChain](../com.david303ttl.DigitaktSampleChain.xrnx/README.md#verification)

## Packaging

Package after changing runtime layout or package inputs:

```powershell
./scripts/package.ps1 -Tool ACID
```

`./tests/package_license_spec.ps1` checks that every archive contains its tool's
full GPLv3 license.
