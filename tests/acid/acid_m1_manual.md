# ACID PITCH / TIME editor (Renoise manual QA)

Follow the current source workflow in
[acid_m35_s_manual.md](acid_m35_s_manual.md) and the current timing/output
acceptance in [acid_timing_manual.md](acid_timing_manual.md). Verify independent
TIME length and active PITCH span through 32, including editing both memories at
their final position, Program/Grid equivalence, save/reopen, and Undo/Redo.

Phrase verification uses four phrase lines per source step: Straight LPB 16
and Triplet LPB 12. Renoise host acceptance for max-length playback, both
output policies, loop endpoints/sentinel, and conditional PB reset alignment
remains pending; use the timing checklist to record results.
