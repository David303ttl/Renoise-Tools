# Renoise Tools

Native Lua/XRNX tools for Renoise.

## Tools

| Tool | Status | Source |
| --- | --- | --- |
| DigitaktSampleChain | Existing tool (unchanged) | [DigitaktSampleChain](com.david303ttl.DigitaktSampleChain.xrnx/) |
| ARP | 0.4 experimental: pattern generation, gates, and ownership-verified regeneration | [ARP](com.david303ttl.ARP.xrnx/) |
| TB303 | 0.1 scaffold: working menu/dialog + separate pitch/time model; **does not write patterns** | [TB303](com.david303ttl.TB303.xrnx/) |

Each `.xrnx` directory is a standalone Renoise tool. Package and version them independently; internal Lua modules ship with their respective tool.

These new tools target Renoise 3.5 (Lua API 6.2).

Development status:
1. ARP has a pure-Lua planner and guarded pattern writer; see its README and manual test guide for current behavior and limitations.
2. TB303 remains a read-only scaffold. Its sequencer model and Renoise event mapping are still in development.
3. Renoise integration and save/reload behavior still need manual validation in a real Renoise instance.

See [manual smoke tests](tests/README.md).
