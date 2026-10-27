# ACID M3.5 Renoise manual checklist

**Results: not run in this workspace.** Run these checks in Renoise 3.5 with a
disposable song. Record the Renoise version, target type and pass/fail/not-run
for each item before treating the functional gates as complete. A passing Lua mock is not a
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
   and confirm the source resets immediately. Use Undo and Redo and confirm
   the source and output policy follow each edit.

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

## Plugin and MIDI SLIDE

1. Use a plugin-only or MIDI-only target with no samples. Enable the receiver's
   mono-legato portamento and choose an audible glide time. Keep its preset and
   routing unchanged while generating. Record receiver and configuration.
2. Generate NOTE C → NOTE G with outgoing SLIDE on C. Inspect the target line:
   G starts in another note column with delay 00; C has OFF with delay 01 in its
   original column. Capture note-on G before note-off C. Listen for continuous
   pitch movement without an envelope restart. A polyphonic receiver may overlap
   notes instead; do not record that as glide success.
3. Disable the SLIDE flag. Confirm a midpoint OFF separates C and G and the
   receiver produces a fresh attack. Re-enable it and confirm overlap returns.
4. Try C → C with SLIDE. Confirm the second C emits neither a new note-on nor
   a note-off; a subsequent REST releases the held C. A changed accent on this
   held voice produces an explicit limitation rather than a retrigger.
5. Repeat three distinct sliding notes for several cycles. Inspect all three
   note columns and the last-to-first seam. Capture note order and delayed OFFs;
   confirm no accumulating notes. Repeat with C → G → C and same-pitch seam.
6. Exercise TIE, connected ACCENT, REST, 64 steps, Play Once tail, stop/start,
   seek and Live Edit regeneration. Verify note-offs in the MIDI/plugin capture.
   Test hybrid layers separately; their sample envelopes may retrigger.

## Save, reopen and Live Edit

1. Save and reopen the XRNS. Confirm current source and Repeat/Play Once policy
restore for each owned phrase.
2. Enable Live Edit on New Phrase and confirm it creates and binds an owned
   phrase automatically. Make a source edit and confirm rendering starts
   immediately without Generate or a debounce wait. Make several edits during
   rendering and confirm the latest source applies automatically next.
   Disable Live Edit during an in-flight
   render and confirm the destination remains consistent.
3. Change songs while ACID is open, then close/reopen the tool. Confirm stale
   jobs are invalidated and no phrase in the new song is changed.
4. Edit without generating, switch destinations and return, then close and
   reopen ACID. Confirm the draft is restored. Save the XRNS with an ungenerated
   edit, reopen the song and confirm the draft restores separately from the
   last committed phrase. Generate and confirm the pending draft is cleared.
5. Use Undo and Redo during Live Edit. Confirm source and output policy follow
   the selected edit and the final generated phrase matches the source. Change
   BPM, LPB/TPL and groove during playback, then stop/start/seek. Confirm Live
   Edit remains armed and note/OFF order stays correct.
6. Cause a recoverable render failure and confirm Live Edit stays enabled.
   Correct the problem by editing the source; confirm it renders immediately
   and preserves the last-good phrase until success. Modify or delete the
   destination externally; confirm Live Edit creates and binds a separate owned
   phrase automatically and preserves unrelated content.


## Async generation and draft safety

1. Generate a new phrase, edit its draft while rendering, then switch to a
   different phrase or instrument before completion. Return to the generated
   phrase and confirm the pending edit survives. Confirm the other destination
   and its draft remain unchanged.
2. Change plugin, MIDI route or sample availability while rendering. Confirm
   the commit suspends, preserves the last-good phrase and reports the change.
3. Reorder instruments and phrases, delete the selected target and duplicate an
   owned ID. Confirm writes never reach a different destination. Recovering a
   draft does not authorize overwriting a foreign or modified phrase.
4. Make song tool data unwritable or corrupt in a disposable test. Confirm the
   source remains recoverable in the editor, persistence failure is visible and
   closing the song warns about any draft that could not be stored.

## Diagnostics and Windows scaling

At 125% and 150% scaling, inspect dirty, queued, rendering, committed,
approximate and error states. Confirm target and cause are readable
and diagnostic text can be selected. Use Go to source error and confirm the
reported TIME/PITCH location is selected without modifying source.

## Result record

| Check | Target / Renoise version | Result | Notes |
| --- | --- | --- | --- |
| Program/Grid and source | | Not run | |
| Repeat / Play Once | | Not run | |
| Sample target | | Not run | |
| Plugin-only target and legato SLIDE | | Not run | |
| External MIDI target and legato SLIDE | | Not run | |
| Hybrid target | | Not run | |
| Empty slot | | Not run | |
| Save/reopen and recovery | | Not run | |
| Async generation and draft safety | | Not run | |
| Windows 125% / 150% scaling | | Not run | |
