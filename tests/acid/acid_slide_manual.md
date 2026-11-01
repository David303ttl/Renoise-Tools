# ACID slide and articulation checks

Use a disposable Renoise song with the current four-line phrase layout: Straight
LPB 16 or Triplet LPB 12, with source lengths up to 32.

1. Generate Play Once and Repeat sources containing NOTE, TIE, REST, SLIDE, and
   ACCENT. Inspect step starts, midpoint releases, glide commands, loop seams,
   and the Repeat sentinel.
2. Test sample, plugin, and MIDI targets separately. Record the receiver and
   routing configuration for each playback result.
3. For pitch-bend output, verify center reset precedes the first attack only
   when the bend channel is not known centered. Check that other fresh attacks
   use delay zero and that overlap OFF ordering uses `ORDER_DELAY`.
4. Record cell inspection separately from playback. Renoise playback quantizes
   note delays to ticks; the one-unit overlap ordering is not sample-accurate.

No current-layout Renoise playback checks have been performed in this work
session.
