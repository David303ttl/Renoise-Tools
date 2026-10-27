# ACID control and target checks

ACID compiles NOTE/TIE/REST, SLIDE and ACCENT through one semantic renderer.
Gate timing and glide operations are derived from the sequence; there is no
renderer-mode selector. Use a disposable song.

1. Open ACID on a sample instrument and confirm the fresh draft is editable.
2. Set a short TIME sequence such as `N,T,N,R`, edit its pitches, and mark an
   outgoing SLIDE. Generate once with Repeat, then choose Play Once and
   regenerate the owned phrase.
3. Inspect note order, NOTE OFF cells, loop settings and any approximation
   status. Confirm the selected instrument's global trigger settings and
   unrelated song content are unchanged.
4. Repeat on plugin-only, MIDI-only, hybrid and empty slots. Record actual
   note-on, velocity, OFF and pitch-bend behavior separately from phrase cells.

The old Baseline/Retrigger/Selective Slide comparisons are retired. Their M3
measurements remain in the audio evidence records and do not constrain current
musical editing. For current manual acceptance use
[acid_m35_s_manual.md](acid_m35_s_manual.md); playback remains unverified until
each target is actually captured in Renoise.
