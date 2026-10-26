# ACID 0.1 — first native phrase playback test

Test in a disposable Renoise 3.5+ song. No slides in this prototype.

1. Prepare one instrument with a playable looping sample across C-3 through G-3.
2. Make sure this instrument has no existing phrases.
3. Load ACID from the feature/acid-0.1-core branch and reload tools.
4. Open Tools > ACID... and choose the sample instrument.
5. Click Generate Test Phrase (new phrase only).
6. Verify that ACID 0.1 TEST is created with 16 lines, LPB 8 and looping OFF.
7. Verify four note-ons and two note-offs in the rendered phrase.
8. Put a note with the selected instrument into a Renoise song pattern and play.
9. Confirm notes C-3, D#3, G-3 and F-3; tied/silent steps should not retrigger.

Report the ACID status text, scripting console errors, rendered phrase contents,
and whether the audio plays. A pass proves basic phrase rendering only;
selective slide and accurate original gate semantics still need implementation.

Local test: lua tests/acid_phrase_spec.lua. No GitHub Actions.
