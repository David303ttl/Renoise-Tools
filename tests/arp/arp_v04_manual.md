# ARP v0.4 Renoise manual tests

Use a disposable XRNS file, LPB 4, 32 or 64 pattern lines, two sequencer
tracks and a sustained instrument.

1. Gate 50%, Rate 1/4, Up, 1 octave, chord C-4 E-4 G-4 on source line 00.
   In destination column 1 expect C-4 on 00, OFF on 02, E-4 on 04,
   OFF on 06, G-4 on 08, OFF on 10, etc.
2. With an **empty** destination, try Rate 1/8 and Gate 75%:
   ON line 00 and OFF line 01 with delay value 80 hex, repeating
   at line 02 ON / line 03 OFF with delay 80 hex.
3. With an empty destination, Rate 1/16 and Gate 50% at LPB 4 must
   refuse without writing; ON and OFF would share a single line.
4. Regenerate a valid generated pattern using Rate 1/8 and Gate 50%.
   The existing owned output must be replaced rather than stacked.
5. Edit an owned note or OFF event. Generate again: the tool must refuse
   and the destination must remain unchanged.
6. Add an unrelated event in destination note column 2 or track FX
   column; repeat regeneration without touching note column 1 and verify
   the unrelated event survives.
7. Save the XRNS file, reload, and regenerate again with the same routing:
   song ownership must still be recognized.
8. Try running over existing v0.3 output with no saved ownership:
   generation must refuse. Switch to an empty destination.
9. Put the only source note at the pattern's final line and request
   gate 50%: generation must refuse (OFF outside pattern).
10. Change source/destination name or pattern length after generation:
    no destructive rewrite should be permitted.

Tests not yet executed in a real Renoise instance.
