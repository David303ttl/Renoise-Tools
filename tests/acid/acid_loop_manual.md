# ACID native phrase repeat verification

## Current contract

TIME length and independent active PITCH span are each 1–32. Straight uses
phrase LPB 16; Triplet uses LPB 12. Both modes use four phrase lines per source
step. At N=32, Play Once contains 128 lines. Repeat contains 257 lines with
`loop_start=129`, exclusive `loop_end=257`, and an empty sentinel on line 257.
The phrase limit is 512 lines.

## Pending Renoise checks

No host checks below have been performed. Use a disposable song and record the
Renoise build, BPM, source, timing mode, output policy, phrase metadata, and
observed playback.

1. Generate max-length Play Once phrases in Straight and Triplet. Verify LPB
   16/12 respectively, 128 lines, four lines per source step, and final release.
2. Generate max-length Repeat phrases in Straight and Triplet. Verify 257 lines,
   `loop_start=129`, `loop_end=257`, and that the sentinel is empty and inaudible.
3. Play through the cold intro and at least three steady cycles. Check the
   cold-to-steady and steady-to-steady seams, expected source-step duration,
   and absence of accumulated drift.
4. Include NOTE-TIE-NOTE, NOTE-REST-NOTE, all-NOTE, all-REST, trailing TIE,
   ending REST, and a connected SLIDE at the loop seam. Compare cell structure
   and audible behavior separately.
5. Check the final source step under both output policies. Confirm no event is
   written to the exclusive-end sentinel.
6. Check fresh PB attacks with and without a required center reset. Delay 1 and
   center reset apply only when the bend channel is not known centered;
   otherwise use delay 0. Record host-tick quantization; this is not
   sample-accurate.
7. Check phrase release, host stop/start, seek, and keymapped triggering
   separately from selective phrase playback.

Phrase-cell inspection and automated semantic checks do not establish audio
behavior. Record unresolved playback and receiver limitations without treating
them as passed.
