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
./scripts/run_tests.ps1 -Tool DigitaktSampleChain -LuaCommand lua5.1
```

Run the offline Lua, PowerShell preflight, runner and package checks with one
command. Lua 5.1 or newer and LuaJIT 2.x are supported:

```powershell
./scripts/run_offline_tests.ps1 -LuaCommand lua5.1
```

The shared runner owns interpreter/process checks, registration regressions, Lua
specs, and release packaging. Tool checks live behind an optional
`tests/<short-name>/offline.ps1` entrypoint accepting `-LuaCommand`. Entrypoints
run in separate PowerShell processes in tool-name order and must return a
nonzero exit code on failure. ACID owns host preflight, native runner mocks,
development packaging, and loop-oracle validation through its entrypoint.
Adding another tool does not require editing either shared runner.

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

Tool suites are discovered from root `.xrnx` directories and matching directories
under `tests/` (lowercase short names). Specifications are discovered
recursively in deterministic order. `All` is reserved for suite selection;
`renoise` is a reserved host suite: ACID
includes it, while other tools do not. Unknown selectors, ambiguous registrations,
orphaned test directories, and missing or
invalid configuration fail explicitly. A tool without specs is skipped by `All`;
selecting that tool directly fails.

To register a tool, add its implementation and `tests/<short-name>/config.lua`:

```lua
return { runtime_root = "com.example.MyTool.xrnx" }
```

Configuration uses this single-field literal form (a trailing comma is allowed).
The runtime root must identify the matching repository tool directory. Put Lua
specifications anywhere under that test directory and start each spec with
`dofile("tests/bootstrap.lua")("mytool")`. The bootstrap derives the test path
and configures module lookup for that tool. Specs still run
as separate processes when using the suite runner.

ACID regression coverage targets the synchronous production planner, phrase
materializer, writer and runtime. Musical expectations must be independent of
retired writers. Native acceptance covers ownership, rollback, persistence,
Undo/Redo and lifecycle behavior; mocked checks do not establish playback.

For ACID runtime tests, use `runtime_phrase_fixture.fixture('new')` for checks
that need no owned destination. The default fixture retains complete owned
phrases for content, identity, navigation and recovery checks. Keep full-capacity
snapshot coverage, including hidden columns and inactive lines. Reuse
`tests/assert_unreachable.lua` for retained-reference checks.

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
- [ACID integrated editor procedures and evidence](acid/acid_regeneration_manual.md)
- [Digitakt sample-chain export checks](../com.david303ttl.DigitaktSampleChain.xrnx/README.md#verification)

The [integrated editor guide](acid/acid_regeneration_manual.md)
defines native checks and evidence fields, including operation
dialogs with inactive memory. Scripted modal answers do not establish that
human journey or distinguish Active from All-32 at 32/32 bounds. Procedure
readiness is not a native pass.

DigitaktSampleChain offline checks cover streaming, file replacement, audio math
and mocked GUI/lifecycle behavior. Run `./tests/digitaktsamplechain/run_native.ps1`
with Renoise closed for its separate fresh-process native probe. The
[native results](renoise/host_verification.md#digitakt-native-export-2026-11-05)
cover real sample buffers, timers, reimport, undo preservation and notifier-driven
GUI checks. These recorded results predate the mandatory explicit grid
divisions change and must not be treated as a PASS for the updated grid behavior.
Same-size edits emit no buffer notification on the verified host; the exporter
detects already-written audio changes using bounded PCM readback.
`-WaveformDirectory tmp/000` adds exhaustive 64-file batches against the supplied
single-cycle corpus, preserving generated chains and a hashed source manifest;
see the [corpus results](renoise/host_verification.md#digitakt-single-cycle-corpus-2026-11-05).
Real Renoise integration, playback, undo and save/reload behavior require
manual validation until an executed native scenario explicitly covers them.

## Package license checks

Run `./tests/package_license_spec.ps1` with PowerShell 7 to build all XRNX
archives into a temporary directory and verify that each contains the
identical, full GPLv3 LICENSE at archive root.
