# ACID editor presentation checks

Use Renoise 3.5 / API 6.2 and a disposable song.

1. Open ACID in Program and Grid. Confirm diagnostic, decoded, inspector and
   recovery controls are absent. Switch editors while Live Edit is enabled:
   phrase contents and Undo history must remain unchanged.
2. Assign Note, Tie and Rest to TIME 02 with a Note at TIME 01. Confirm both
   views show the same full command name, distinct colors on unselected steps,
   and a highlighted assignment button. Undo and Redo each edit.
3. Inspect both TIME pages and inactive steps. Confirm labels remain readable
   and inactive steps cannot be assigned. Enter timing and check labels show
   pending assignments; Cancel restores the accepted assignments.
4. Confirm Grid pitches show Renoise note names, ACC and SLD only when enabled,
   with musical note identification on hover. Neither view shows selected-position
   summaries or source-interpretation diagnostics. Each view has Audition
   beside its PITCH controls; Note/Tie/Rest sit below its TIME positions.
5. Confirm Enter pitches/Enter timing appear in Program during normal editing.
   The launch row follows the TIME assignment controls. During entry, launch
   controls disappear and Back, Enter and advance, Restart,
   Finish and Cancel appear with cursor progress. Restart preserves entered
   markers; Cancel requires confirmation and leaves source/history unchanged.
   Switch to Grid and back: progress and Finish/Cancel remain reachable, Grid
   shows accepted values and cannot edit pending values.
6. Enter all positions except 5, then attempt Generate from another page.
   Confirm Finish is disabled, feedback identifies position 5 and Program reveals
   it with matching cursor progress without saving or generating. Repeat in Grid:
   the view stays Grid and directs completion in Program. Finish complete entry,
   then invoke Generate again. Check generation failures and audition cleanup errors
   remain readable. Successful Live Edit stays quiet; a new edit clears an old
   explicit success confirmation while unresolved warnings remain visible.
7. Compare dialog height, spacing and text clipping in both views at the
   display scaling used for normal work. Confirm no workspace tabs or blank
   reserved area remain. Expand entry, random parameters and multiline feedback;
   controls must stay reachable and inactive rows must collapse.
8. Confirm Instrument precedes Phrase, Rename and Duplicate. Select New Phrase
   and an owned phrase; confirm native selection and the accepted name agree.
   Attempt destination changes during entry and an unresolved rename attempt;
   neither may bypass its guard.
9. Rename with an invalid name, then a valid name. On an injected save failure,
   confirm the proposal survives, Retry saves once and label-only Undo restores
   the accepted name without changing destination or notes.
10. Confirm Length, Timing, Reset pattern and Pitch span appear in that order
    above the editor. Reduce Length with a different Pitch span, then restore it:
    inactive TIME entries and PITCH memory must remain intact. Check both Timing
    divisions and undoable Reset pattern; Reset must respect pending entry.
11. Confirm Program/Grid, Undo, Redo, clipboard scope, Copy and Paste share one
    toolbar. No Pattern / Copy tab or clipboard contents report remains. Copy
    PITCH, select TIME and confirm Paste is inactive. Return to PITCH, edit and
    paste: one Undo restores the edit; identical Paste adds no history or write.
    Repeat with TIME and Both. Copy, scope selection and editor switching must
    not save or generate. During entry or an unresolved rename, Paste remains
    inactive. Undo/Redo save failures remain visible without a success paragraph.
12. Set Pitch span 32 and Length 16. Select P17 with TIME 01 selected, edit its
    key/octave, C+, accent and slide, then switch views. PITCH and TIME selections
    and pages remain independent. Check positions 16, 17 and 32 in each memory;
    inactive TIME stays inspectable without accepting assignments. View/page
    changes must not save, generate or add history.
13. Enable a scale mask and audition from each view: the resolved note must
    agree with the selected pitch. Confirm release on position/page/view changes,
    editing, destination changes and dialog close. During PITCH entry check both
    audition controls share eligibility; during TIME entry both are disabled.
    Check song release/unload cleanup; unresolved release failures must remain
    in shared feedback. Injected failure coverage is in
    `acid_audition_lifecycle_spec.lua` and `acid_program_staging_spec.lua`.
14. Confirm SCALE follows the editor: Root, Scale and Follow, then Category,
    Search and Import, then the mask controls. Root, filtering and Follow must
    not save or add history. Selecting a scale applies one undoable mask edit;
    aliases/categories appear in its tooltip. Import failures use shared feedback.
15. Confirm OPERATIONS follows SCALE without a workspace tab. Exercise all ten
    operations in Active memory and All 32 stored scopes. Only Randomize PITCH
    shows seed/range; only Randomize TIME shows seed/weights. Apply with seed A,
    change the field to B and Repeat last: it uses A with current settings and
    leaves B displayed. Repeated parameter changes must leave no blank rows.

16. Confirm OUTPUT follows OPERATIONS: Mode and Bend range, then Live Edit and
    Generate. Hover Bend range for receiver matching, channel-wide bend and
    isolated monophonic routing guidance, including Off behavior. No Retry Live
    Edit button remains. Arm Live Edit and navigate without writing; edit once,
    then verify one protected write. After an ordinary write failure, Generate
    retries through normal admission. New Phrase creates once; subsequent
    Generate updates that exact owned phrase. Stale or blocked targets must
    never append, reroute or clear safeguards.
