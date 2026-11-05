# ACID editor acceptance

Run in Renoise 3.5 / API 6.2 with a disposable song. Record display scaling and
mark any scenario not performed as unverified. Inspect phrase contents and
audible playback separately.

1. Open ACID at normal display scaling. Confirm the full interface fits without
   clipping. Expand sequential entry, random-operation parameters and multiline
   feedback; controls remain reachable and unused rows collapse. The dialog
   width stays constant throughout; Program and Grid may have different heights.
2. Edit PITCH spans and TIME lengths at positions 16, 17 and 32. Check note
   keys, octaves, C+, accent, slide and TIME commands. Switch Program and Grid,
   page each memory, and confirm TIME selection reveals its linked PITCH slot,
   inactive TIME positions remain inspectable but cannot be assigned, TIME
   assignments highlight the selected command, and view/page changes add no
   edit, save or generation.
   With Length 8 and Pitch span 16, set TIME to Note, Tie, Note, Note, Note,
   Note, Note, Note. Both views identify P01, P01 hold, P02 through P07; only
   P01–P07 are green. Set P01 to E2 and P02 to E4. Grid shows these resolved
   note names above TIME; Program shows pitch references below the commands.
   Select T03: T03 and P02 have amber outlines, the context reads
   `T03 → P02 · E4`, and the pitch controls edit/audition P02. Select P01:
   T01 and T02 are outlined, retaining their red/blue fills. Select an unused
   pitch: no unrelated TIME step is outlined. Select a Rest: no PITCH slot is
   outlined. T09–T16 are dim, have no pitch references or trailing asterisks,
   and remain unassignable. Tooltips distinguish unused and out-of-span pitches.
   At Length 32, test pitch wrapping with span 2 and links across both TIME
   pages. With span 32, select T17 and confirm P17 is revealed. Page/view
   navigation creates no history, save or Live Edit write. Undo/Redo of a timing
   edit restores references and outlines. During timing entry Program maps the
   pending candidate, Grid maps accepted source, and Cancel restores accepted
   references. Check amber borders and both Program button lines at normal and
   high display scaling, including long note labels with ACC/SLD.
   Enable Slide on P01. Both views show `SLD→`; TIME references show outgoing
   arrows on T01/T02 and an incoming arrow on T03. Selecting T01, T02, T03,
   P01 or P02 outlines both pitch endpoints and T01–T03. The context reads
   `Slide: T01 / P01 E2 → T03 / P02 E4 · via T02`. Selecting T03 still edits
   and auditions P02. Replace T02 with REST: the arrows disappear, P01 retains
   `SLD`, and selecting P01 identifies T02 as the blocking REST. Undo restores
   the connection. Repeat during timing entry: Program shows pending connections,
   Grid shows accepted connections, and Cancel restores the accepted mapping.
   Enable Slide on the final used pitch. Repeat shows loop arrows and a context
   containing `next cycle`; Play Once removes that boundary connection and
   identifies the pattern end. Test a slide through ties across TIME pages 16/17,
   repeated uses of a pitch, and a one-step repeating slide to itself. Check
   arrow glyphs, Program pitch labels and context lines for clipping at both
   display scales. Verify generated phrase contents and audible slide behavior
   separately for the intended target; UI links express source intent.
3. Enter pitches and timing. Confirm progress, Back, Enter and advance, Restart,
   Finish and Cancel work. An incomplete entry identifies the first missing
   position; Finish stays unavailable. In Grid, Back, Enter and advance and
   Restart stay disabled and cannot mark positions entered; Finish and Cancel
   remain reachable. A stale target cannot commit the entry.
4. Copy and paste PITCH, TIME and Both. Confirm scope eligibility, one undoable
   edit for a changed paste and no edit for an identical paste. Undo and Redo
   restore the expected source.
5. Browse scales by root, category and search; select a scale, use Follow,
   edit the mask and import a scale. Browsing does not edit source. Applying a
   scale is one undoable edit, and import failures remain visible.
6. Apply all ten operations to Active memory and All 32 stored positions.
   Confirm only the relevant randomization parameters appear. Repeat last uses
   the previous operation seed with current settings and leaves the seed field
   unchanged.
7. Check OUTPUT Mode and Bend range, including Off and the bend-range tooltip's
   receiver matching, channel-wide bend and isolated monophonic routing guidance.
   Select New Phrase and an owned phrase. Generate creates one phrase or updates
   the exact selected phrase. Arm Live Edit and navigate without writing; make
   one edit and confirm one protected write. An ordinary failure can be retried
   with Generate through normal admission. Unsafe targets remain unavailable.
8. Check Rename, Duplicate and Reset. Confirm validation, guards, destination
   identity, source and history behavior. Audition pitches in both views and
   confirm Grid auditions its displayed accepted pitch while Program auditions
   the staged pitch during PITCH entry. Confirm note release on position/page/view
   changes, editing, target changes, dialog close and song release. Change
   instrument/phrase selection, delete or
   reorder a target, and close/reopen ACID. No stale callback may affect the
   next selection or session.
9. Save and reopen the song with ungenerated edits. Confirm supported drafts
   restore automatically. For an unavailable target or persistent blocker,
   confirm the message accurately describes the limitation and no action claims
   to repair or clear it. Confirm no removed workflow is presented.

Use [the phrase destination guide](acid_phrase_destination_manual.md),
[Live Edit guide](acid_live_edit_manual.md) and
[host lifecycle guide](renoise_host_lifecycle_manual.md) for detailed safety
checks. Mocked tests do not establish Renoise playback behavior.
