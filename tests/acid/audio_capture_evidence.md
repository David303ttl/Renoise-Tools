# ACID Renoise playback verification

Current target: 32 source steps, four phrase lines per step, Straight LPB 16,
and Triplet LPB 12. Phrase output policies are Play Once and Repeat.

## Checks

- Generate lengths 1 and 32 in both timing modes and output policies.
- Verify Play Once line counts 4 and 128; verify Repeat line counts 9 and 257.
- At length 32 Repeat, verify loop start 129, exclusive end 257, and an empty
  sentinel at line 257.
- Inspect gate, glide, legato, pitch-bend, and reset placement at all four line
  offsets per step.
- Check phrase duration, repeated playback, loop seam, and fresh-attack timing.

Current-layout Renoise playback evidence is pending. Mocked specs validate
planning and phrase-cell expectations but do not establish playback behavior.
