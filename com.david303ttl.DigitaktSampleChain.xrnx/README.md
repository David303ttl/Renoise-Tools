# Digitakt Sample Chain

Exports the selected instrument's raw sample buffers as a 48 kHz, 16-bit mono
WAV for Elektron Digitakt. Requires Renoise 3.5 / scripting API 6.2.

## Export behavior

- Non-empty sample slots are exported in instrument order. Playback tuning,
  volume, loops and effects are not rendered. On sliced instruments, the master
  and alias slots are each included as listed; the exporter does not deduplicate them.
- Source sample rates are automatically converted to 48 kHz with windowed-sinc
  interpolation and anti-alias filtering when downsampling. Source buffers are
  unchanged. Output lengths preserve duration to the nearest frame (minimum one).
  Source bit depth does not restrict export; output is always 16-bit PCM.
- **Spaced (Digitakt Grid):** each slot has the longest converted source's frame count.
  Auto uses one slot per source; fixed counts are 4, 8, 16, 32 and 64. A fixed
  count must cover every non-empty source. Extra slots are silent.
- **Slot padding:** adds 64 silent frames at both edges, increasing each spaced
  slot by exactly 128 frames. Padding and empty slots remain digital silence,
  including with dither enabled. Slot counts and padding are disabled in Chain mode.
- **Chain (Direct Concatenation):** joins samples without spacing. The duration
  readout reports the mean sample length and the exact total, not a slicing grid.
- **Mono conversion:** average both stereo channels, or select Left or Right.
  All three choices use the only channel of a mono source.
- **Fade-out:** optional 20 ms linear fade ending at zero. Shorter samples fade
  over their entire length; a faded one-frame sample is silent.
- **Dither:** optional TPDF with a one-LSB peak amplitude before nearest-integer
  signed PCM quantization. A private fixed-seed generator makes repeated exports
  byte-identical without consuming or reseeding Renoise's global RNG.

## Usage

1. Select the instrument and open `Sample Editor > Export Digitakt Sample Chain`.
2. Choose the layout, mono conversion and processing options.
3. Click `Export Chain` and choose a destination in the save dialog.
4. Wait for the completion readout, or click `Cancel Export`. Closing the dialog
   also cancels on the next timer callback. A canceled or failed attempt clears
   the previous duration readout.

Audio is read and written in bounded chunks on Renoise's GUI thread between UI
events. No complete chain or complete source audio is copied into Lua tables.
The source buffers are never modified, so no song undo entry is created.

Do not edit source audio while exporting. Observed buffer, slice, sample-list or
instrument-list changes abort the export; song release and tool unload cancel
it and release timers and observers. Buffer dimensions are also checked between
chunks. API 6.2 does not document whether same-size audio edits always notify;
that behavior needs native verification and is not a snapshot-isolation guarantee.

Output is staged beside the destination. Cancellation and write/flush/close
failures leave an existing destination unchanged. Replacement uses a temporary
backup; failed restoration reports the original backup's recovery path. Cleanup
failures are reported rather than hidden. This is not a power-loss-safe file
transaction. Chains exceeding the standard 32-bit RIFF size limit are rejected.

## Verification

Run from the repository root:

```powershell
./scripts/run_tests.ps1 -Tool DigitaktSampleChain -LuaCommand lua5.1
./scripts/package.ps1 -Tool DigitaktSampleChain
```

The offline specs cover slot geometry, fades, mono conversion, PCM bytes, private
dither, source invalidation, file failures, cancellation and mocked GUI wiring.
They do not establish native GUI behavior, playback or Digitakt import.

Manual checks in a disposable Renoise song:

1. Export unequal-length 48 kHz mono/stereo samples with Auto and fixed counts,
   padding on/off, and both modes. Reimport the WAV and verify frame counts,
   slot boundaries, pitch, mono-channel selection and the duration readout.
2. Exercise very short fades and dither; repeat an unchanged export and compare
   the files. Confirm empty sample slots and sliced instruments follow the
   documented source ordering.
3. Export mixed 44.1/48/96/192 kHz sources and different source bit depths. Check
   pitch, duration, alias suppression and unchanged source buffers. Confirm
   undersized fixed grids are rejected without altering an existing destination.
   Cancel the save dialog with no error shown.
4. Export a long chain, use the UI, then cancel or close the dialog. Confirm the
   original destination survives and staging files are removed.
5. During a long export, edit audio without changing its length, resize a buffer,
   change slices, load a new song, and disable/reload the tool. Confirm exports
   stop, no stale callbacks run, and no source samples or undo history are changed.

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
