# ACID Renoise articulation probe

Use this manual for a disposable Renoise song when checking phrase playback.
The current ACID layout uses four phrase lines per source step: Straight LPB
16 and Triplet LPB 12. Host playback checks remain pending.

## Capture procedure

1. Use one Renoise instance and a disposable song. Prepare a known playable
   instrument and record its sample/plugin, routing, and envelope configuration.
2. Set song tempo and transport timing as desired. Do not use these settings to
   infer or rewrite ACID's phrase LPB. Disable unrelated audible tracks and
   effects that would obscure the observation.
3. In ACID, generate a source with a recorded timing mode and output policy.
   Include a max-length N=32 case and representative NOTE/TIE/REST, SLIDE,
   ACCENT, gate, and PB-reset events where relevant.
4. Inspect the generated phrase: verify LPB 16 Straight or LPB 12 Triplet,
   four lines per source step, correct line count, loop endpoints, and an empty
   exclusive-end sentinel for Repeat.
5. Trigger the phrase and record playback without editing cells during the run.
   Check source-step durations, attacks, releases, holds, loop seams, and
   unintended retriggers. Repeat for Play Once and Repeat.
6. For PB reset ordering, test fresh attacks both when the channel is known
   centered and when it is not. Delay 1 plus center reset applies only in the
   latter case; otherwise delay 0. Renoise quantizes the 1/256-line ordering to
   host ticks, so it is bounded but not sample-accurate.
7. Record Renoise build, tempo, timing mode, phrase LPB, output policy, source,
   instrument setup, phrase metadata, and observed playback. Keep structural
   inspection results separate from audio observations.

No Renoise host checks for the current layout have been performed. A structurally
valid phrase or a mocked/synthetic result does not by itself establish playback
behavior, receiver compatibility, or hardware fidelity.
