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
- **Grid (Digitakt Slices):** select exactly 4, 8, 16, 32 or 64 equal divisions
  (default: 4). Each division has the longest converted source's frame count.
  The selected grid must cover every non-empty source; extra divisions are silent.
- **Slot padding:** adds 64 silent frames at both edges, increasing each grid
  division by exactly 128 frames. Padding and empty slots remain digital silence,
  including with dither enabled. Grid divisions and padding are disabled in
  Concatenated mode.
- **Concatenated:** joins samples without spacing or grid divisions. The duration
  readout reports the mean sample length and exact total, not a slicing grid.
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
events. Rendering and PCM encoding yield after an 8 ms budget, checked every
32 frames. File I/O, callbacks and an individual batch can exceed that budget.
No complete chain or complete source audio is copied into Lua tables.
Before replacement, a second bounded pass re-renders the source and compares it
with the staged PCM; the WAV header and length are also checked. The source
buffers are never modified and export creates no song undo entry.

Do not edit source audio while exporting. Observed buffer, slice, sample-list or
instrument-list changes abort the export; song release and tool unload cancel
it and release timers and observers. Buffer dimensions are checked between
chunks. Renoise 3.5.4 does not notify same-size edits; PCM readback verification
detects changes affecting audio that has not yet been checked. An edit after a
region is checked can go undetected. Continuous editing is not snapshot-isolated,
so keep sources stable during both passes.

Output is staged in an atomically reserved directory beside the destination.
Colliding paths are retried without opening or truncating them.
Cancellation and write/read/seek/flush/close
failures leave an existing destination unchanged. Replacement uses a temporary
backup and rejects an existing destination that is not a regular file; failed
restoration reports the original backup's recovery path. Cleanup failures are
reported rather than hidden. The destination is not locked against other
processes, and replacement is not a power-loss-safe file transaction.
Chains exceeding the standard 32-bit RIFF size limit are rejected.

## Verification

Run from the repository root:

```powershell
./scripts/run_tests.ps1 -Tool DigitaktSampleChain -LuaCommand lua5.1
./tests/digitaktsamplechain/run_native.ps1
./scripts/package.ps1 -Tool DigitaktSampleChain
```

The offline specs cover slot geometry, fades, mono conversion, PCM bytes, private
dither, source invalidation, staging collisions, file failures, cancellation,
time-budget yielding, terminal callback errors and mocked GUI wiring.
They do not establish native GUI behavior, playback or Digitakt import.

The native runner requires Renoise closed, creates a fresh disposable song in
its own process, and installs a separate test-only probe. Production tool
installations are not replaced. Reports, copied test inputs and logs stay under
ignored `tmp/digitakt-native-<run-id>/`; the owned process and unchanged probe
are removed after the run.

Native coverage includes buffers, timers, source changes, undo, GUI views,
WAV reimport, 44.1/96/192 kHz conversion and staging collisions. See the
[host verification record](../tests/renoise/host_verification.md#digitakt-hardening-verification-2026-11-06).

For a supplied mono 16-bit PCM WAV corpus:

```powershell
./tests/digitaktsamplechain/run_native.ps1 -WaveformDirectory tmp/001 -StartupTimeoutSeconds 600
```

Files are copied and hash-verified, sorted by ordinal filename and tested in
batches of at most 64. Original files are not modified. Generated
`single-cycle-<batch>-<variant>.wav` chains, the ordered source manifest and
native report remain in the run directory. Each primary chain is checked
against file-backed PCM and reimported into Renoise. Other sample rates use the
exporter's resampling model for the PCM reference; separate analytical tone tests
check pitch and alias suppression independently.

Results: 53/53 native cases with 256 supplied 44.1 kHz files; 43/43 with
65 generated 48 kHz files, including a partial batch. See the
[supplied-corpus results](../tests/renoise/host_verification.md#digitakt-supplied-single-cycle-corpus-2026-11-06)
and [generated-corpus check](../tests/renoise/host_verification.md#digitakt-native-export-2026-11-06).

Remaining manual checks:

1. Export unequal-length 48 kHz mono/stereo samples with each supported grid
   division (4/8/16/32/64), padding on/off, and Concatenated mode. Reimport
   the WAV and verify frame counts,
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
5. Check actual file-dialog interaction and visual fit at different DPI settings,
   tool disable/reload during export, audible output and import on Digitakt
   hardware. Automated notifier calls do not establish mouse/keyboard interaction
   or listening results.

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
