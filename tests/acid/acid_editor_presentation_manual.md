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
   page each memory, and confirm their cursors/pages stay independent,
   inactive TIME positions remain inspectable but cannot be assigned, TIME
   assignments highlight the selected command, and view/page changes add no
   edit, save or generation.
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
