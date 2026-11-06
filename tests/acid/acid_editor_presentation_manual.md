# ACID editor checks

Use Renoise 3.5 / API 6.2 at normal and high display scaling. Check source
presentation, native interaction and audible audition as separate behaviors.

1. Open **Tools > ACID...**. Confirm the dialog fits without clipping. Expand
   sequential entry, OPERATIONS parameters and multiline feedback; verify controls
   remain reachable. Switch Program/Grid and pages. View and page changes must not
   edit, save or generate.
2. Use **Length** and **Pitch span** to inspect positions 16, 17 and 32. Check
   note keys/octaves, C+, ACCENT, SLIDE and TIME commands. Inactive TIME entries
   remain inspectable but cannot be assigned. REST, silent TIE and inactive TIME
   disable pitch editing/audition; selecting PITCH or a mapped TIME entry restores
   them. Undo/Redo of a timing edit restores the mapping.
3. Verify independent TIME-to-PITCH mapping with **Length 8** and **Pitch span
   16**. Set TIME to Note, Tie, Note, Note, Note, Note, Note, Note. T01 and T02
   map to P01; T03–T08 map to P02–P07. Only P01–P07 are green. Set P01 to E2 and
   P02 to E4. Grid shows resolved notes above TIME; Program shows pitch references
   below commands. Selecting T03 outlines T03 and P02, displays `T03 → P02 · E4`,
   and edits/auditions P02. Selecting P01 outlines T01/T02 while retaining their
   fills. An unused pitch or REST outlines no unrelated TIME entry. T09–T16 are
   dim and unassignable. At Length 32, verify wrapping with Pitch span 2 and
   cross-page links; with Pitch span 32, selecting T17 reveals P17.
4. During sequential timing entry, Program shows pending mapping and Grid shows
   accepted source; Cancel restores accepted mapping. Navigation creates no edit,
   save or Live Edit write. Check amber primary selection, distinct secondary
   slide outlines, and visible NOTE/TIE/REST fills at both display scales. Long
   note labels and both Program button lines must fit their canvases.
5. Enable SLIDE on P01 with P01=E2 and P02=E4. TIME references show outgoing
   arrows on T01/T02 and incoming on T03. Selecting T01, T02, T03, P01 or P02
   outlines both pitch endpoints and T01–T03; context reads
   `Slide: T01 / P01 E2 → T03 / P02 E4 · via T02`. Selecting T03 still edits and
   auditions P02. Replacing T02 with REST removes arrows while P01 retains `SLD`;
   selecting P01 identifies the blocking REST. Undo restores the connection.
   Repeat during sequential entry and verify pending/accepted mappings and Cancel.
   Revisit T17 after browsing P01 and confirm P17 is revealed without altering a
   pitch or marking another timing step entered.
6. Slide the final used pitch. Repeat shows loop arrows and `next cycle`; Play
   Once removes the boundary connection and identifies pattern end. Check slides
   through ties across TIME 16/17, repeated uses of one pitch, and a one-step
   repeating slide to itself. Verify arrows, labels and context do not clip.
7. Audition in both views. Grid auditions its displayed accepted pitch;
   Program auditions the staged pitch during PITCH entry. Check note release on
   position/page/view changes, edits, target changes, dialog close and song
   release.
8. In Program, enter incomplete PITCH and TIME sequences. **Finish** stays
   disabled; **Generate** identifies the first missing position without applying
   the candidate. Grid cannot advance or mark positions entered. Unrelated edits
   stay blocked while entry is staged. **Cancel** restores accepted values. For an unresolved
   recovery guard, check the available retry/discard actions and confirm a
   blocked action can be retried after resolving the guard.
9. Copy and paste PITCH, TIME and Both. Confirm each scope's eligibility, one
   undoable edit for changed data and no edit for an identical paste. Undo and
   Redo restore the source. Check Rename validation, Duplicate's committed
   source, and Reset pattern behavior.
10. In **OUTPUT**, check **Mode** (Play Once/Repeat) and **Bend range**, including
    Off and the tooltip's receiver-matching, channel-wide bend and isolated
    monophonic routing guidance. Select **New Phrase** and an owned phrase;
    **Generate** creates or updates only that destination.

Use the [phrase checks](acid_phrase_manual.md) for native phrase playback and
the [Live Edit checks](acid_live_edit_manual.md) for destination writes.
