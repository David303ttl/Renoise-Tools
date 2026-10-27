# ACID Live Edit manual verification

The Renoise result below is an M2-era UI receipt. Current cutover acceptance is
tracked in [acid_m35_s_manual.md](acid_m35_s_manual.md); this procedure covers
the remaining Live Edit lifecycle checks.

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

## Renoise result (2026-10-27)

On Renoise 3.5.4 Demo with a disposable song, Live Edit was enabled for an
Extended Repeat phrase and LAST STEP plus active PITCH span were changed through
64→17→1→64. The same phrase changed from 257 to 69 to 5 and back to 257 lines.
The span changes did not append phrases. With Live Edit disabled, changing
LAST STEP and span left the previous phrase unchanged until manual Generate;
manual generation then resized it from 257 to 69 lines. No stale lines or
additional phrase were observed in these cases.

Changing songs while ACID was open produced `Song changed. Close and reopen
ACID.` on the stale editor. Reopening ACID restored the correct song context.
An Original-mode phrase source also survived saving and reopening the XRNS and
was accepted for regeneration.

Rapid edits, edits while a render is in flight, disabling Live Edit mid-job,
dialog close, notifier/song-close races, and undo/redo remain untested. Renoise
Demo disabled WAV rendering, so this result covers phrase mutation and context
guards only; it does not establish audio behavior. The M2 implementation was
closed on 2026-10-27 with registered-build audio checks deferred; see the
[Repeat acceptance record](acid_loop_manual.md).

Limitations: Live Edit is an opt-in *phrase regeneration* feature, not
per-sample real-time DSP. The renderer still relies on Renoise's asynchronous
script compilation, and phrase playback behavior must be checked in Renoise.
The timer debounce is 350 ms, not a hard rendering deadline.
