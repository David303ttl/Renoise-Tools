# Mixed NOTE/TIE/REST probe

Run `renoise_mixed_repeat_probe.lua` in a disposable song with the `ACID LOOP
PROBE` instrument and a looping single-cycle sample.

The probe uses Straight timing at phrase LPB 16 and song LPB 8. Each step has
four phrase lines. The eight-step cold traversal uses lines 1-32; the steady
cycle uses lines 33-64; line 65 is the exclusive-end sentinel. Each source
cycle lasts two beats.

| Case | TIME | PITCH span | Expected behavior |
| --- | --- | --- | --- |
| `tie_seam_span3` | N,T,N,R,N,T,T,T | 36,43,48 | REST releases before the next NOTE; trailing TIEs hold the final voice to the seam. |
| `rest_seam_span2` | N,T,N,T,T,T,T,R | 40,47 | REST releases the final voice; the next cycle starts with P01. |

Inspect phrase cells and render four steady periods after the cold traversal.
Record the Renoise version, tempo, sample profile, phrase layout, and observed
seam/release behavior. No current-layout playback run has been performed in
this work session.
