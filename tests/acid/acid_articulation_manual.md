# ACID articulation acceptance

Articulation is scheduled from source NOTE/TIE/REST, SLIDE, ACCENT, and the
successor-aware gate timeline. Renoise playback acceptance for the current
four-line source-step layout remains pending.

## Pending checks

Use a disposable song, max-length N=32 sources where applicable, and both
Straight (LPB 16) and Triplet (LPB 12). Record source, output policy, phrase
metadata, instrument setup, and observed cells and playback separately.

- Verify NOTE attacks and release, TIE hold, REST release, and fresh NOTE attack.
- Verify connected and same-pitch SLIDE behavior, including Repeat seams.
- Verify ACCENT response for NOTE and TIE cases; record target-specific limits.
- Verify Play Once final release and Repeat cold/steady gate behavior.
- Verify PB reset and attack alignment at the current phrase layout. A 1/256-line
  ordering delay is bounded and host-tick-quantized, not sample-accurate.
- Keep target-specific sound response separate from semantic/cell correctness.

No current-layout Renoise articulation checks have been performed. Lua or
synthetic audio checks do not establish host playback behavior or hardware
fidelity.
