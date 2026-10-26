# Tests

## Pure Lua checks (no Renoise required)

From the repository root, with Lua installed:

```sh
lua tests/arp_engine_spec.lua
lua tests/acid_sequencer_spec.lua
lua tests/arp_v04_spec.lua
lua tests/arp_gui_spec.lua
```

## Renoise 3.5+ manual smoke test

1. Install the ARP package independently (see its README). Leave the existing Digitakt tool installed.
2. Restart Renoise or run **Tools > Reload All Tools** with scripting development enabled.
3. Follow [the ARP v0.4 manual test guide](arp_v04_manual.md) in a disposable song.
4. Open **Tools > ACID...** and confirm its read-only scaffold still opens.
5. Verify DigitaktSampleChain still opens as before.

The Lua checks do not replace Renoise integration testing. ARP's manual generation, undo, and save/reload behavior have not yet been verified inside Renoise.
