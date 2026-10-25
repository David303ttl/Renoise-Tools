# Tests

## Pure Lua checks (no Renoise required)

From the repository root, with Lua installed:

```sh
lua tests/arp_engine_spec.lua
lua tests/tb303_sequencer_spec.lua
```

## Renoise 3.5+ manual smoke test

1. Install both packages independently (see each tool README). Leave the existing Digitakt tool installed.
2. Restart Renoise or run **Tools > Reload All Tools** with scripting development enabled.
3. Open **Tools > ARP...**. Check that the dialog appears. Change Up/Down/Up-Down; verify the example MIDI-note ordering changes. Click **Inspect selected pattern** and check it reports the current pattern/track.
4. Open **Tools > TB303...**. Check that the dialog appears and changing 8/12/16 adjusts the draft time-slot count. Click **Inspect selected pattern**.
5. Verify both tools can also be opened from the Pattern Editor context menu.
6. Verify neither tool has changed any notes, effects, automation or other pattern content; both are read-only scaffolds.
7. Verify DigitaktSampleChain still opens as before.

These tests are guidance only; they were **not run inside Renoise** when this scaffold was created. Functional sequencing and destructive-write tests will be added with the actual engines.
