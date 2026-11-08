# ACID timing checks

Use a disposable Renoise song. TIME **Length** and active **Pitch span** are
independent and range from 1 to 32. Straight uses LPB 16; Triplet uses LPB 12.
Each source step occupies four phrase lines. At length 32, Play Once has 128
lines; Repeat has 257 lines, `loop_start=129`, exclusive `loop_end=257`, and an
empty sentinel on line 257. Phrase capacity is 512 lines.

1. Set **Length** to 1 and then 32. Generate Play Once and Repeat in Straight
   and Triplet. Expect 4/9 lines at length 1 and 128/257 at length 32; Repeat
   loop start is `4N+1` and exclusive end is `8N+1`. Check LPB, the empty
   sentinel and final release. No event may occupy the exclusive-end sentinel.
2. In Repeat, play the cold intro and at least three steady cycles in both
   timing modes. Check 1/4-beat Straight and 1/3-beat Triplet steps, loop seams,
   and accumulated drift. Include NOTE-TIE-NOTE, NOTE-REST-NOTE, all-NOTE,
   all-REST, trailing TIE, ending REST, and a connected slide at the seam.
3. Check fresh pitch-bend attacks with and without a required center reset. A
   reset uses delay 1 only when the bend channel is not known centered; otherwise
   use delay 0. Renoise quantizes delay to host ticks, so this is not
   sample-accurate.
4. Check stop/start, seek, BPM/LPB changes, phrase release, and keymapped
   triggering. Keep phrase-cell inspection distinct from receiver playback.

Mocks and cell inspection establish structure only. Playback results apply to
the tested Renoise build and receiver.
