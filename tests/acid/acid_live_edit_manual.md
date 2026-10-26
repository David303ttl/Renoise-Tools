# ACID Live Edit manual verification

Run `pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID`
locally in VS Code. No GitHub workflows.

1. Load a Renoise instrument with an existing ACID-owned phrase and its
   saved source. Open ACID. Ensure Live Edit is OFF by default.
2. Enable Live Edit. Verify this action alone does NOT change the phrase.
3. Change a PITCH key, octave, ACCENT and SLIDE, then change a TIME action.
   Allow Renoise's event loop to process the edits. Check the *same phrase*
   changes and no additional phrase remains in the instrument.
4. Rapidly modify several controls. Expect coalesced writes, not a write
   for every UI callback. Change again while a render is pending; the final
   phrase must match the last displayed editor state.
5. Turn Live Edit OFF, change a note and verify the phrase does not update.
   Use the existing manual Generate/Regenerate button and verify it works.
6. Select New Phrase, a different instrument, or a foreign/modified phrase.
   Live Edit must disable and must not write to any other phrase.
7. Change songs with the dialog open. No pending live write may touch the new
   song. Close and reopen the editor; no stale listener may keep writing.
8. Edit a generated phrase manually in Renoise while Live Edit is on.
   The ownership seal should prevent destructive replacement; Live Edit
   must stop and display the error.
9. Verify the saved source survives closing ACID and saving/reopening the
   XRNS after the last completed live render.

Limitations: Live Edit is an opt-in *phrase regeneration* feature, not
per-sample real-time DSP. The renderer still relies on Renoise's asynchronous
script compilation, and phrase playback behavior must be checked in Renoise.
The timer debounce is 350 ms, not a hard rendering deadline.
