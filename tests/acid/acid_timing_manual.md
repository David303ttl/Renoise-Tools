# ACID timing — Renoise acceptance

## Current phrase contract

Source TIME length and independent active PITCH span are each 1–32. Straight
uses phrase LPB 16 and Triplet uses phrase LPB 12; each source step occupies
four phrase lines. A Straight step lasts 1/4 beat and a Triplet step lasts 1/3
beat.

At N=32, Play Once has 128 lines. Repeat has 257 lines, loop start 129, and
exclusive loop end 257. Line 257 is an empty sentinel. Phrase capacity remains
512 lines. Gate positions are represented on the 256-unit-per-source-step
timeline and mapped through the selected four-line layout.

## Pending Renoise checks

These host checks have not been performed. Use a disposable Renoise song and
record the build, source, timing mode, output policy, phrase LPB, line count,
loop endpoints, and observed playback.

1. Generate N=32 Straight Play Once. Verify LPB 16, 128 lines, four phrase
   lines per source step, and the final release.
2. Generate N=32 Triplet Play Once. Verify LPB 12, 128 lines, four phrase
   lines per source step, and the final release.
3. Generate N=32 Repeat in both modes. Verify 257 lines, `loop_start=129`,
   `loop_end=257`, and an empty sentinel.
4. Play both modes across cold-to-steady and steady-to-steady seams. Verify
   source-step durations of 1/4 and 1/3 beat and check for drift.
5. Inspect the last source step and sentinel under both output policies. Confirm
   no event is placed in the sentinel and no extra audible line occurs.
6. Check PB fresh-NOTE alignment with and without a required center reset. Use
   delay 1 plus center reset only when the bend channel is not known centered;
   otherwise use delay 0. The 1/256-line ordering is host-tick-quantized,
   bounded, and not sample-accurate.
7. During playback, check stop/start/seek and BPM/LPB changes in Straight and
   Triplet.
8. Check instrument and phrase selection, in-place regeneration, explicit new
   phrase creation, Live Edit, and source/settings save/reopen.

Receiver-specific behavior outside the checked setup is not certified. Do not
interpret structural inspection or mocked tests as actual playback acceptance.
