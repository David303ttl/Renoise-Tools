# SuperOS-303 Renoise Tool

A standalone Renoise 3.5 / scripting API 6.2 tool for controlling SuperOS-303
hardware directly over MIDI/SysEx. It does **not** flash firmware or switch
firmware modes. The tool does not depend on ACID or DigitaktSampleChain.

## Install

From the Renoise-Tools repository root, run:

```powershell
./scripts/run_tests.ps1 -Tool SuperOS303 -LuaCommand lua5.1
./scripts/package.ps1 -Tool SuperOS303
```

Open the generated `dist/com.david303ttl.SuperOS303_0.1.xrnx` with Renoise.
Use **Tools > SuperOS-303...** (or the Pattern Editor menu).

## Basic hardware test

1. Connect hardware MIDI OUT to Renoise MIDI IN, and Renoise MIDI OUT to
   hardware MIDI IN (USB MIDI or an interface with properly wired DIN ports).
   Select **both** ports in the tool and click **Connect**.
2. **Read config** queries SysEx 0x20 and should receive 0x21 (configuration)
   and 0x1C (active group). The displayed group is read from the hardware.
3. Pick pattern A1-A8 or B1-B8 and variation 1-3; click **Fetch**. The tool
   reports the hardware's active pattern and fetches it with **Use hardware
   pattern**. Choosing a pattern in the editor only selects what to edit.
   Mono patterns are checked against the 60-byte firmware format and checksum.
4. For **variation 1** only, choose a step and adjust NOTE/REST/TIE,
   pitch, accent, slide, ratchet or length. Write buttons apply immediately,
   including during playback. Each write triggers an automatic readback; a
   mismatch displays the returned value. Use **Fetch** to retry a missing reply.
   Changing controls alone does not write to hardware.
5. **Queue pattern** selects a pattern at the next hardware pattern wrap
   (immediately when stopped). **Set edit variation** sends the hardware
   edit-target command. Both prompt before sending.

## Important constraints

- **Group selection is performed on the hardware.** The firmware's pattern
  request command addresses 16 slots inside its currently active group; a
  pattern number alone does not select a group. Switching hardware groups
  invalidates the cached snapshot.
- **Variations 2 and 3 are read-only.** Variation 3 poly messages are
  recognized; chord editing is not supported.
- Variation 1 edits affect hardware pattern storage. Save a backup with the
  working desktop editor before testing writes.
- Incoming hardware edits to the displayed variation refresh the cached pattern
  automatically. A successful send means the MIDI driver accepted the message,
  not that the hardware persisted it. Readback is required.
- SysEx RX and TX must be enabled on the hardware. An unmatched or incomplete
  response is not interpreted as a connected device.
- The tool does not send MIDI clock or Start/Stop. For Renoise-led transport,
  enable the correct MIDI clock output in Renoise and external clock receive
  on the hardware. Keep clock routing separate from the tool's control port.
- If another editor uses the same MIDI port, disconnect it while testing
  to avoid competing SysEx messages.
- The tool cannot manage the host's physical port permissions or reconnect
  automatically after hot-unplugging. Use Refresh ports, then Connect.

The application protocol is defined by
`303-OS/src/midi.cpp` and `303-OS/tools/web-pattern-edit/index.html`.
Current mono pattern format: 32 pitch bytes, 8 packed time bytes,
12 metadata bytes (length is byte 52), 8 packed ratchet bytes;
60 bytes raw, 69 bytes 7-bit packed. Firmware needs the matching protocol.

## License

Copyright (C) 2026 David303ttl. GPL-3.0-only; see LICENSE.
