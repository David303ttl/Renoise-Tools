# Renoise Tools

Native Lua/XRNX tools for Renoise.

## Tools

| Tool | Status | Source |
| --- | --- | --- |
| DigitaktSampleChain | Existing tool (unchanged) | [DigitaktSampleChain](com.david303ttl.DigitaktSampleChain.xrnx/) |
| ARP | 0.1 scaffold: working menu/dialog + pure-Lua note ordering example; **does not write patterns** | [ARP](com.david303ttl.ARP.xrnx/) |
| TB303 | 0.1 scaffold: working menu/dialog + separate pitch/time model; **does not write patterns** | [TB303](com.david303ttl.TB303.xrnx/) |

Each `.xrnx` directory is a standalone Renoise tool. Package and version them independently; internal Lua modules ship with their respective tool.

These new tools target Renoise 3.5 (Lua API 6.2).

Development plan:
1. Safely read/write notes to a destination track and establish a repeatable test harness.
2. Finish ARP source chord processing, step/gate settings, regeneration, and undo.
3. Validate an authentic TB-303 event model independently before mapping it to Renoise note, gate, slide, and accent events.
4. Add per-song state persistence and integration tests.

See [manual smoke tests](tests/README.md).
