# ACID articulation checks

Use a disposable Renoise song in Straight (LPB 16) and Triplet (LPB 12), with
four phrase lines per source step. Inspect phrase cells and listen to each
receiver separately.

1. Generate NOTE, TIE, REST and ACCENT patterns. Check NOTE attacks, midpoint
   release cells, TIE holds, REST releases, and the fresh NOTE after a hold.
   Verify Play Once final release and Repeat cold/steady behavior, including
   NOTE-TIE-NOTE, NOTE-REST-NOTE, trailing TIE and ending REST.
2. Test connected and same-pitch SLIDE, a slide through ties, a blocked slide
   across REST, and slides at the Repeat seam. Check glide commands and loop
   arrows against source intent.
3. Compare alternating and consecutive ACCENT notes at equal pitch with the
   sample, velocity mapping, routing and envelope fixed. Inspect velocity
   cells. For sample response, render with silent pre-roll and compare settled
   RMS after each onset. Repeat with TIEs; TIE lines contain no NOTE or velocity
   cells.
4. Test sample, plugin and MIDI targets separately. Check note-on, velocity,
   OFF and pitch-bend behavior for the receiver in use. Fresh attacks use a
   center reset only when the bend channel is not known centered; overlap OFF
   ordering is tick-quantized and not sample-accurate.

Do not infer acoustic behavior from cell structure or mocked tests.
