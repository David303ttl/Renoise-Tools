# ACID editor presentation checks

Use Renoise 3.5 / API 6.2 and a disposable song.

1. Open ACID in Program and Grid. Confirm diagnostic, decoded, inspector and
   recovery controls are absent. Switch editors while Live Edit is enabled:
   phrase contents and Undo history must remain unchanged.
2. Assign Note, Tie and Rest to TIME 02 with a Note at TIME 01. Confirm both
   views show the same full command name, distinct colors on unselected steps,
   and a highlighted assignment button. Undo and Redo each edit.
3. Inspect both TIME pages and inactive steps. Confirm labels remain readable
   and inactive steps cannot be assigned. Re-enter TIME and check labels show
   candidate assignments; discard restores the accepted assignments.
4. Confirm Grid pitches show Renoise note names, ACC and SLD only when enabled,
   and raw pitch values and source markers remain available on hover.
5. Confirm staging navigation appears during re-entry and disappears after
   Finish or Discard. Switch to Grid during staging and back to Program.
6. Attempt Generate with incomplete entry and verify missing-position feedback
   and source navigation. Check generation failures and audition cleanup errors
   remain readable. Successful Live Edit stays quiet; a new edit clears an old
   explicit success confirmation while unresolved warnings remain visible.
7. Compare dialog height, spacing and text clipping in both views at the
   display scaling used for normal work, including every workspace tab.
