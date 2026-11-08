# SuperOS-303 Renoise Tool

Native MIDI/SysEx hardware editor for Renoise 3.5 / scripting API 6.2, targeting
the current SuperOS-303 firmware in `David303ttl/303-OS`. It runs as a separate
Renoise tool; ACID and DigitaktSampleChain are unaffected.

## Install

From the repository root, run:

```powershell
./scripts/run_tests.ps1 -Tool SuperOS303 -LuaCommand lua5.1
./scripts/package.ps1 -Tool SuperOS303
```

Install `dist/com.david303ttl.SuperOS303_0.1.xrnx` and open
**Tools > SuperOS-303...**.

## MIDI connection

1. Connect both MIDI IN and OUT to the SuperOS device (USB or DIN interface).
   Close the desktop editor if it is using the same interface.
2. Select the input/output ports, click **Connect**, then **Read config**.
   The device should report its firmware version, MIDI channels and hardware
   group. A port that opens is not sufficient evidence of an actual device.
3. The active group is determined by the hardware knob; pattern numbers A1-A8
   and B1-B8 are *inside that group*. Select a pattern and variation, then
   **Fetch**. Use **Use hardware pattern** to follow the most recent active
   hardware pattern broadcast.
4. Use **Steps**, **Scale**, **Probability**, and **MIDI** tabs. The MIDI tab
   opens first while disconnected; loading a pattern switches to Steps.
   A 4×8 overview shows all 32 positions, notes/ties/rests, accent,
   slide and ratchet indicators. Click a step to edit it.

## Editing

- **Mono variations 1, 2 and 3**: step note, time, accent, slide and length
  editing. Variation 1 sends efficient per-step SysEx; variations 2/3 use a
  checked full-pattern blob for non-resident shadow consistency.
- **Variation 3 poly**: fetch and inspect the four-voice chord list, use the
  four voice selectors (or empty voices), time/NOTE/TIE/REST, accent and slide,
  then **Write poly step** (0x27). Poly output is four voices per NOTE event,
  and the time stream indexes chords rather than individual notes.
- **Pattern settings**: direction (forward/reverse/ping-pong/random/half
  random/Brownian), triplet mode, transpose (-24..24), and length. Changes are
  sent as validated full pattern blobs, preserving other stored metadata.
  Triplet patterns cannot exceed 24 steps.
- **Scales**: edit the 12 pitch-class mask bits or choose a root and preset,
  then apply the mask. Enable/disable quantization and click **Write scale**.
  Variation 1 uses scale SysEx 0x2A; mono variations 2/3 use checked full blobs.
  The device's returned mask and enable state are verified, not unrelated bytes.
- **Probability** (variation 1): tables are fetched automatically with a
  newly loaded variation-1 pattern. **Read probabilities** refreshes on demand.
  Set accent, slide, down/up levels (0..13) and double-up, then **Write
  probability**. Readback validates the requested step and preserves the table
  when that same pattern is refreshed. Select the target step on the Probability
  tab; selection is shared with Steps. Probabilities roll on NOTE steps. TIE
  holds the previous NOTE's result and REST is silent. Level 0 disables a
  characteristic; 13 always applies it. **Up +24** requires a nonzero Up level.
- **MIDI configuration**: MIDI listen channel (0=omni), external clock
  receive, MIDI Thru, LED brightness, and variation 2/3 output channels.
  **Write MIDI config** preserves the device's current SysEx RX/TX flags.
- **Hardware selection**: queue a pattern (at wrap or immediately when
  stopped) and choose the hardware's edit-target variation.

The incoming SysEx stream is decoded and checksummed; the tool monitors
hardware edits and refreshes the matching pattern. Normal pattern writes
automatically request a readback and report whether the returned hardware
values match. Saving via MIDI driver does not prove persistent hardware
storage. Do not simultaneously edit the same hardware state in multiple
editors.

## Constraints

- This is a native Renoise implementation, **not** an embedded web browser.
  It remains less extensive than the standalone SuperOS desktop editor.
- The 32-step overview displays one 32-step section (A or B); linked A/B
  sections remain separate addresses in this tool.
- The UI uses compact tabs instead of displaying diagnostics and all controls
  simultaneously. Errors and readback confirmations appear on the status line
  and in Renoise's status area.
- Full bank management, track-chain arrangement, randomization, extensive
  probability-lane editing, advanced poly operations, and backup/restore
  workflows are not yet implemented.
- This tool deliberately excludes all bootloader, firmware-update,
  EEPROM diagnostic and firmware-switch opcodes.
- It does not emit MIDI clock. Configure Renoise's normal MIDI clock output
  and enable clock RX on SuperOS if you want Renoise to be the timing master.
- The hardware must have SysEx RX/TX enabled. If a control does not respond,
  check input/output direction, device firmware, and port ownership.
- Make a backup in the tested desktop editor before trying bulk or live
  writes on valuable patterns.

The current firmware protocol is defined in
`303-OS/src/midi.cpp` and `303-OS/tools/web-pattern-edit/index.html`.
The mono blob is 60 bytes raw and 69 bytes 7-bit packed; the poly chord
blob is 115 bytes raw and 132 bytes packed.

## Verification

Offline tests cover codecs, packet framing, two-stream editing,
scale and probability readback, and tabbed UI behavior. Run the above test command. See `tests/superos303/README.md`
for the Windows MIDI hardware probe; that script modifies and restores a
pattern, and must be used only with a known backup.

## License

Copyright (C) 2026 David303ttl. GPL-3.0-only; see LICENSE.
