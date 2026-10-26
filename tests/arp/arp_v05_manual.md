# ARP v0.5 — Renoise manual tests

Use a disposable XRNS with a C-4 E-4 G-4 source chord on Track 01
line 00, an empty Track 02, LPB 4 and a short pluck/one-shot instrument.

1. Increase Track 02 visible note columns to **2** using its header.
   Open ARP v0.5, choose Source 01, Destination 02, Up, 1 octave,
   **Rate 1/32**, **Gate 100%**, Generate.
2. Expect both columns on each line:
   - Line 00: C-4 delay 00 in col1, E-4 delay 80 in col2
   - Line 01: G-4 delay 00 in col1, C-4 delay 80 in col2
   - Line 02: E-4 delay 00 in col1, G-4 delay 80 in col2
   - And so forth
   Delay subcolumn should be visible automatically.
3. Change rate to 1/16 with Gate 100% and press Generate again.
   Expect regeneration, without stale notes in column 2.
4. Change rate back to 1/32 and regenerate; both columns should fill
   again if no changes were made to generated output.
5. Manually edit one generated note in column 2, then regenerate.
   Expect refusal with original edited content preserved.
6. With Rate 1/32 and Gate 50%, expect an explanatory refusal and
   **no pattern changes**. This is a known limitation.
7. Reduce destination visible note columns to one on a new empty
   destination, select 1/32 Gate 100%; expect the tool to say it
   requires two visible note columns. It must not generate.
8. Change the LPB to 1 in a new disposable song, expand destination
   to eight columns and try 1/32 Gate 100%; expect eight delayed notes
   per line. Do not change LPB in an existing production song.
9. Recheck v0.4 supported gates at LPB 4: 1/4 + 50% should still
   create OFF at lines 02, 06, 10...
10. Save XRNS, reload it, and test regeneration of 1/32 output.

This checklist is for hands-on Renoise testing. It has not yet been
completed by the assistant.
