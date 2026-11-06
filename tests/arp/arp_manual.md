# ARP manual checks

Use a disposable song with LPB 4, a source chord on Track 01 and an empty
destination Track 02. Choose a playable destination instrument.

1. Select instrument 01 in ARP while the source notes use instrument 00. Generate
   and confirm destination events name instrument 01, source notes remain intact,
   and the source track becomes OFF. With **Disable source note playback (OFF)**
   cleared, confirm generation leaves the source track state unchanged.
2. Set Rate 1/32, Gate 100%, and expose two destination note columns. Confirm
   notes alternate between columns with delays 00 and 80 hex, and the delay
   subcolumn appears. Reduce the rate to 1/16 and regenerate; stale events in
   the second column should be removed. At LPB 1, 1/32 requires eight visible
   columns; requests beyond the available twelve must refuse without writing.
3. At LPB 4, verify 1/4 with Gate 50% places OFF events two lines after each ON.
   Verify fractional-rate gates where supported. Confirm 1/16 at LPB 4 with
   Gate 50%, and 1/32 with Gate 50%, refuse without changing the pattern when
   ON/OFF events collide. Confirm a release beyond the pattern end also refuses.
4. Regenerate unchanged output and confirm it replaces the owned events. Edit a
   generated event, then regenerate and confirm ARP refuses without changing the
   edit. Add unrelated events in another note or effect column and confirm they
   survive. Save, reopen, and confirm valid ownership still permits regeneration.
5. After generation, rename or reorder a track/pattern and confirm regeneration
   refuses. Confirm duplicate track names also block regeneration. Test legacy
   ARP04 output only after clearing the previous generated destination.
