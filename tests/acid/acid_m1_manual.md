# ACID M1: paged PITCH / TIME editor (Renoise manual QA)

Implementation branch: feature/acid-m1-pitch-time-64. The 64-step capacity is a
software extension; a hardware TB-303 has a 16-step pattern limit.

## Local deterministic regression

Run from the repository root in VS Code:

```powershell
pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID
```

The new `tests/acid/acid_m1_editor_spec.lua` covers 1/16/17/32/33/48/49/64
steps, independent NOTE consumption, pitch wrap, octave transposition, page
boundaries, TIE and REST, and exact-step errors.

## Renoise smoke test (requires Renoise 3.5/API 6.2)

1. Install the ACID tool from this branch. Open an instrument with a playable
   sample and no foreign phrase content. Open Tools > ACID.
2. Confirm LAST STEP=16, choose Create / Reset Pattern. PITCH and TIME grids
   become active. Verify creation is mandatory before editing.
3. Edit P01 keyboard C, octave DOWN, ACCENT on, SLIDE on. Edit P02 D#, octave
   UP. Verify the two controls independently alter the decoded MIDI pitches.
4. Set TIME step 01 to NOTE, step 02 to TIE, and step 03 to NOTE using
   the per-step dropdown selectors. Click the step header to inspect it. Preview: step 1 P01, step 2 holds P01,
   step 3 P02. P03 onwards should be marked unused.
5. Set LAST STEP=17, select TIME page 17-32 and set step 17 to NOTE. Verify it
   maps to the next pitch position, not automatically to P17.
6. Set LAST STEP=64 and visit all four PITCH and TIME pages. Edit steps 16,
   17, 32, 33, 48, 49, 64; ensure state persists when switching pages.
7. Shrink LAST STEP to 16, then enlarge again. Time values outside the active
   range should be restored in this open draft.
8. Select a NOTE with no PITCH memory initialized in a fresh draft. Verify the
   warning reports the exact TIME step and PITCH P01 and refuses generation.
9. Generate an ACID phrase using an initialized pattern with valid NOTE
   pitches. Check the phrase line count equals two times LAST STEP and the
   decoded preview matches events. Regression-check phrase ownership,
   regeneration, selective-slide collisions, and manual edits.
10. Change songs with the dialog open. Verify generation is cancelled and the
    outdated dialog cannot target the new song.

## Known limits

- Native sample slide, gates, and loop boundary articulation are experimental;
  a correct editor preview is not evidence of faithful audio behavior.
- The editor currently uses straight 1/16 divisions; triplet is not ready
  for rendering and must not be silently enabled.
- Draft pattern persistence across dialog close, song save/reopen, and undo
  remains a separate milestone. Reset clears the current unsaved draft.
- Native Renoise GUI rendering and playback have not been exercised in this
  environment. The tests must be run locally before merge.
