# ACID — Renoise functional acceptance

**M4 gate:** instrument/phrase synchronization, ownership, in-place regeneration, persistence and one playback smoke. No new audio captures or receiver matrices. See [M4.7](../../com.david303ttl.ACID.xrnx/ROADMAP.md#m47--instrumentphrase-synchronization-and-regeneration-safety-p0).

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

## Target sanity

- Generate and regenerate with one sample instrument, one available plugin instrument and an empty instrument. Empty instrument may be silent; the editor and writer must remain usable.
- MIDI-only, hybrid and alias fidelity are receiver-dependent release checks, not M4 blockers.
- Existing NOTE/TIE/REST, sample glide and reference VST PB audio results remain accepted; no repeat capture required.

## M3.6 Plugin/MIDI pitch bend

**Accepted:** phrase-contained M1 delivery and ±12 bend/center reset with Surge XT VST3, Renoise 3.5.4, global slot 03. Native sample and VST glide/REST checks passed at phrase LPB 8 and 6. [Evidence](audio_capture_evidence.md#phrase-pitch-bend-receiver-check-2026-10-28).

PB Off/on safety, range overflow and receiver-independent structural behavior belong to Lua regression tests. Other receivers are not certified; no additional audio-capture gate.

## Save, reopen and Live Edit

1. Save and reopen the XRNS. Confirm current source and Repeat/Play Once policy
restore for each owned phrase.
2. Explicitly select New Phrase, then enable Live Edit and confirm one owned phrase is created and bound. Make a source edit and confirm rendering starts
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
   and preserves the last-good phrase until success. Modify or delete the destination externally; confirm Live Edit suspends safely without appending, preserves the draft and last-good/unrelated phrases, and requires an explicit new destination.


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

## M4.7 acceptance record

| Check | Result |
| --- | --- |
| Static Straight/Triplet timing and meter playback | Passed; [timing evidence](acid_timing_manual.md) |
| Native sample glide and Surge XT PB | Passed for bounded reference setups |
| Add/rename/reorder/delete instrument while ACID remains open | Pending |
| Renoise instrument/phrase selection follows 1:1 without unintended writes | Pending |
| Existing owned phrase regenerate in place; no added phrase | Pending |
| Target deleted, modified or foreign: no automatic append/overwrite | Pending |
| Explicit new phrase creates exactly one bound owned phrase | Pending |
| Draft/source PB/timing/output settings survive switching and save/reopen | Pending |
| Live Edit context changes and stale asynchronous completion | Pending |
| One playback/transport smoke in Renoise | Pending |
