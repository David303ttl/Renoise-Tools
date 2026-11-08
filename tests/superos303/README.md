# SuperOS-303 hardware check

Run the Lua suite from the repository root:

```powershell
./scripts/run_tests.ps1 -Tool SuperOS303 -LuaCommand lua5.1
```

The Windows hardware check captures MIDI through WinMM in the background,
without activating windows, sending keys, or changing the Renoise song. It
uses the tool's protocol module, identifies the playing slot, edits one NOTE
step during playback, verifies its readback, captures outgoing notes, then
restores and verifies every original pattern byte. Captures and the original
pattern are saved under ignored `tmp/`.

```powershell
./tests/superos303/run_hardware.ps1 -InputPort '<hardware input>' -OutputPort '<hardware output>'
```

Leave the hardware playing and allow at least two full loops per capture
(`-CaptureSeconds`, default 4). `-StartTransport` sends MIDI Start if no notes
are detected and MIDI Stop afterward; it requires an existing clock source.
The script does not generate clock. Keep other editors from modifying the
pattern during the test. Its original pattern is restored in a `finally` block.

To verify the Renoise UI, fetch variation 1, edit a note, and click **Write
step** while playback runs. Check that no prompt appears, readback confirms
the edit, and a second write works without **Fetch**. Hardware panel edits
should refresh automatically. The background check verifies the data and MIDI
output; panel display and analog audio require checking the physical hardware.
