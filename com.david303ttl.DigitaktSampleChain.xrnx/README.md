# Digitakt Sample Chain

Exports an instrument's raw samples as 48 kHz, 16-bit mono WAV for Elektron
Digitakt. Requires Renoise 3.5 / scripting API 6.2.

## Export

Open **Sample Editor > Export Digitakt Sample Chain**, choose a layout and
processing options, then select a destination. Non-empty sample slots are read
in instrument order; playback tuning, volume, loops and effects are not
rendered. Sliced instruments export their listed master and alias slots without
deduplication.

Source rates are converted to 48 kHz with windowed-sinc interpolation and
anti-alias filtering when downsampling. Output duration is preserved to the
nearest frame, with at least one frame. Stereo samples can be averaged or
reduced to Left or Right; mono samples use their only channel. Optional
processing includes a 20 ms linear fade and TPDF dither. The dither generator
has a fixed private seed, so repeated exports are byte-identical.

**Grid** creates 4, 8, 16, 32 or 64 slots, each as long as the longest
converted sample; extra slots are silent. The selected grid must fit every
non-empty sample. **Slot padding** adds 64 silent frames at each edge. Both
options are disabled in **Concatenated** mode, which
joins samples and reports mean sample length and total duration.

Use **Cancel Export** to stop a long export; closing the dialog cancels it on the
next timer callback. Audio is processed in bounded chunks on Renoise's GUI
thread. The source buffers are unchanged, and export creates no song undo entry.
Do not edit, replace or delete source samples during export; changes between chunks can produce
inconsistent audio.

Output is staged in a reserved directory beside the destination. Failures before
installation leave an existing destination unchanged. Installation removes an
existing regular file before moving the staged WAV; if that move fails, the old
file is no longer present. Chains exceeding the standard 32-bit RIFF size are
rejected.

## Verification

Run `./scripts/run_tests.ps1 -Tool DigitaktSampleChain` from the repository root.
Run `./tests/digitaktsamplechain/run_native.ps1` with Renoise closed for native
checks of sample buffers, timers, GUI views, undo, WAV reimport and staging
behavior. To include supplied mono WAVs, pass a directory such as `tmp/001`:

```powershell
./tests/digitaktsamplechain/run_native.ps1 -WaveformDirectory tmp/001
```

Mocks do not establish file-dialog interaction, audible output or Digitakt
hardware import.

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](../LICENSE).
