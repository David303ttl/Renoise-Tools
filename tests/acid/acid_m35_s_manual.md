# ACID M3.5-S Renoise manual checklist

**Results: not run in this workspace.** Run these checks in Renoise 3.5 with a
disposable song. Record the Renoise version, target type and pass/fail/not-run
for each item before treating Gate S as complete. A passing Lua mock is not a
playback receipt.

## Program/Grid and source

1. Open ACID on a fresh instrument slot. Confirm the draft is editable without
   a Create step, with C pitches, NOTE commands, LAST STEP 16 and PITCH span 16.
2. Change LAST STEP to 32, then 64, and PITCH span to 3. Confirm LAST STEP
   accepts values from 1–64. Edit TIME 32 and 64 and PITCH positions 1–3.
   Switch Program → Grid → Program. Confirm the source values,
   decoded preview and generated phrase cells do not change from view switches.
   With Live Edit enabled, confirm switching views does not queue a render.
3. Edit TIME 17, reduce LAST STEP 16, then restore 17. Confirm TIME 17 remains
   unchanged. Save and reopen the XRNS and repeat the check.
4. Enter TIE at TIME 01. Confirm it is stored as NOTE. Click Reset Source once
   and confirm the source resets immediately. Use Undo Reset and confirm the
   previous source and output policy return.

## Output policy and destination safety

1. Record the selected instrument's phrase trigger mode and phrase program.
   Generate an ACID-owned phrase with Repeat, then choose Play Once and
   regenerate it, then return to Repeat. Confirm only the owned phrase layout
   and saved output policy change; PITCH/TIME, trigger mode and phrase program
   remain unchanged.
2. With at least two owned phrases, select the second phrase and regenerate it.
   Confirm it is updated in place, the first phrase is unchanged, and the
   destination chooser remains on the selected phrase.
3. Verify Repeat contains a cold introduction and repeating body. Verify Play
   Once contains one traversal and a final release. Inspect NOTE/TIE/REST cells,
   the final release and the ownership seal.
4. Edit an owned phrase manually and confirm ACID refuses replacement while
   preserving it. Confirm a foreign phrase is also preserved.

## Target families and articulation

Repeat the generation check with a sample instrument, a plugin-only instrument,
an external MIDI instrument with a configured output, a hybrid instrument, and
an empty slot. Confirm plugin/MIDI output keeps the note order and reports any
slide approximation. Confirm an empty slot commits a silent phrase with a
warning. Record actual note, velocity, OFF and pitch-bend/glide behavior; do
not infer these from phrase cells alone.

Use a source with NOTE–TIE–NOTE–REST, an outgoing SLIDE at the Repeat seam, a
connected ACCENT change and a large pitch interval. Generate manually and with
Live Edit. Confirm generation commits in each case, notes remain ordered, REST
and Play Once releases are present, and reduced-fidelity behavior is reported
as an approximation. Confirm failures leave the last-good phrase and recoverable
source intact.

With a sample target, also use NOTE–TIE–NOTE–NOTE with an outgoing slide into
the third NOTE. Confirm its 0G command completes before the fourth NOTE's
midpoint OFF, and both the glide and OFF remain in the phrase.

## Save, reopen and Live Edit

1. Save and reopen the XRNS. Confirm current source and Repeat/Play Once policy
restore for each owned phrase. Earlier development source/seal formats should
not be adopted; recreate those patterns.
2. Enable Live Edit, make several rapid source edits, and confirm the final
   source is rendered once edits settle. Disable Live Edit during an in-flight
   render and confirm the destination remains consistent.
3. Change songs while ACID is open, then close/reopen the tool. Confirm stale
   jobs are invalidated and no phrase in the new song is changed.

## Result record

| Check | Target / Renoise version | Result | Notes |
| --- | --- | --- | --- |
| Program/Grid and source | | Not run | |
| Repeat / Play Once | | Not run | |
| Sample target | | Not run | |
| Plugin-only target | | Not run | |
| External MIDI target | | Not run | |
| Hybrid target | | Not run | |
| Empty slot | | Not run | |
| Save/reopen and recovery | | Not run | |
