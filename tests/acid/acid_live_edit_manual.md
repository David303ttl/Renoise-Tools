# ACID Live Edit checks

Use a disposable song with an ACID-owned phrase selected.

1. With Live Edit off, change a pitch and a TIME command. Confirm the draft is
   dirty and the phrase cells stay unchanged. Save and reopen; confirm the draft
   is recoverable separately from committed phrase content.
2. Enable Live Edit without editing. Confirm arming and navigation do not write.
   Switch views, pages and owned phrase destinations; each destination retains
   its own draft and source/output association.
3. Change a pitch, octave, ACCENT, SLIDE, TIME command or output setting. Confirm
   each accepted musical edit writes the same owned phrase in place. Label changes
   and mask browsing do not render. Turn Live Edit off and confirm edits leave the
   phrase unchanged until **Generate**.
4. Switch destinations between edits. Confirm no stale write reaches another
   phrase. Test ACID Undo/Redo with Live Edit both off and on, then check native
   Renoise Undo/Redo as described in the [destination checks](acid_phrase_destination_manual.md).
5. Select **New Phrase** and edit with Live Edit off. The phrase is created
   only after **Generate**. Foreign, manually changed, deleted or colliding
   destinations must block writes while preserving the draft.
6. Change songs or close ACID between edits. Reopen and verify the active song,
   observers and destination identity. Save/reopen and compare source, settings,
   draft and phrase cells; reopening must not generate.
7. Cause an ordinary generation failure and retry with **Generate**. Then test a
   persistent song-integrity blocker on a disposable copy: changing destination
   or closing and reopening ACID must not clear it. Confirm blocked writes retain
   the draft and do not change phrase cells.
