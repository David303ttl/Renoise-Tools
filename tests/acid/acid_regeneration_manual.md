# ACID regeneration checks

Use a disposable Renoise song and the current ACID tool. The current source has
32 PITCH entries, 32 TIME entries, active lengths 1-32, and persistence format
`ACID-PITCH-TIME-1`.

1. Generate length-32 Play Once and Repeat phrases in Straight and Triplet.
   Verify phrase LPB 16/12, four lines per source step, and line counts 128/257.
2. For Repeat, verify loop start 129, exclusive end 257, and an empty line-257
   sentinel. Inspect notes, releases, gates, glide effects, and pitch-bend cells.
3. Save and reopen the song. Verify the 32-entry source, active lengths, timing
   mode, phrase output policy, and PB range are restored without source writes.
4. Modify an owned phrase manually and verify regeneration refuses to replace
   it. Restore an unchanged phrase and verify regeneration keeps its identity
   and does not increase phrase count.
5. Exercise Live Edit during source changes, close, and song changes. Verify
   stale renders do not commit and failed rollback leaves visible recovery data.
6. Record Renoise version and results for each check. No current-layout Renoise
   checks have been performed in this work session.
