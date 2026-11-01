# ACID accent verification

Use a disposable Renoise song with the current Straight LPB 16 or Triplet LPB
12 phrase layout. Keep the sample, velocity mapping, routing, and envelope
configuration fixed for each comparison.

1. Generate an alternating and a consecutive ACCENT source at length 32.
2. Inspect NOTE velocity cells at four-line step starts and verify empty
   subdivisions and midpoint release cells.
3. Render each source with a silent pre-roll. Measure equal-pitch settled RMS
   after each onset and record the render format and instrument setup.
4. Repeat the comparison with TIEs between NOTE events. Confirm TIE lines do not
   contain NOTE or velocity cells, and compare early held-note RMS windows.
5. Keep structural cell checks separate from acoustic results. No current-layout
   Renoise accent or TIE playback checks have been performed in this work
   session.
