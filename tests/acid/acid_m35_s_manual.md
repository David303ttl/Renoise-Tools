# ACID — Renoise functional acceptance

**Current acceptance:** instrument/phrase synchronization, ownership, in-place regeneration, persistence, plus pending host validation of the max-32 timing/layout contract. See [M4](../../com.david303ttl.ACID.xrnx/ROADMAP.md#6-m4--exact-timing-modes-and-tempo-independent-phrase-output).

## Program/Grid and source

1. Open ACID on a fresh instrument slot. Confirm the draft is editable without
   a Create step, with C pitches, NOTE commands, LAST STEP 16 and PITCH span 16.
2. Change LAST STEP to 32 and PITCH span to 32. Confirm both independent
   capacities are 1–32. Edit TIME and PITCH positions 1, 16, 17 and 32.
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

## Pending current-layout Renoise acceptance

These checks have **not** been run. Record the Renoise build, source, output
policy, phrase LPB, line count, loop endpoints and observed playback for each.

1. Generate a max-length Straight source (N=32). Verify phrase LPB 16, four
   phrase lines per source step, and 128 Play Once lines with final release.
2. Generate a max-length Triplet source (N=32). Verify phrase LPB 12, four
   phrase lines per source step, and 128 Play Once lines with final release.
3. For both timing modes, generate Repeat at N=32. Verify 257 lines, an empty
   exclusive-end sentinel, `loop_start=129`, `loop_end=257`, and the repeating
   cycle period; listen across the cold-to-steady and steady-to-steady seams.
4. Repeat Straight/Triplet at short and boundary lengths; verify step durations
   remain 1/4 and 1/3 beat respectively and no drift appears across the seam.
5. Target PB fresh attacks both when the bend channel is known centered and when
   it is not. Verify delay 0 without reset and delay 1 plus center reset when
   required. Renoise tick quantization applies; this is not sample-accurate.

## Target sanity

- Generate and regenerate with one sample instrument, one available plugin instrument and an empty instrument. Empty instrument may be silent; the editor and writer must remain usable.
- MIDI-only, hybrid and alias fidelity are receiver-dependent release checks, not M4 blockers.
- Straight/Triplet playback and PB attack/reset alignment at LPB16/12 remain pending in the timing checklist.

## Native render lifecycle

1. Generate and regenerate under normal and busy host load. Confirm committed
   source renders correctly or reports an error without replacing last-good output.
2. Cancel during rendering. Confirm staging remains and new writes are blocked
   until the callback arrives; canceled output must not replace the destination.
3. Close the song or unload the tool during rendering. Confirm no stale GUI
   updates or invalid-object errors occur. Tool reload is not a render-cancel path.
4. In a speed-timing song, confirm generation is refused without changing phrase
   count, saved source or transport. Switch timing during rendering and confirm
   the last-good destination and source remain unchanged.

Renoise 3.5.4 LPB check: phrases 01 and 02 were created and 02 was regenerated
through the native callback; count stayed two. Phrase preview started and the
Renoise output meter showed signal; Stop halted preview. Missing callbacks,
cancellation during rendering, document release during rendering and speed
timing remain unverified. The open song uses LPB timing; the API exposes
`transport.timing_model` as read-only, so no live speed-timing song was tested.

## M3.6 Plugin/MIDI pitch bend

**Pending (NOT YET PERFORMED):** Using the existing disposable-song method,
verify conditional center-reset and fresh-attack alignment at LPB 16 and 12:
delay 1 plus reset only when the bend channel is not known centered; otherwise
delay 0. Check both Straight and Triplet and actual host-tick behavior.

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
| Static Straight/Triplet timing and meter playback | Pending: LPB16/12, four lines per source step |
| Native sample glide and Surge XT PB | Pending current-layout alignment/playback checks |
| Add/rename/reorder/delete instrument while ACID remains open | Pending |
| Renoise instrument/phrase selection follows 1:1 without unintended writes | Partial; see [phrase destination check](acid_phrase_destination_manual.md) |
| Existing owned phrase regenerate in place; no added phrase | Passed in Renoise 3.5.4; phrase count stayed two |
| Target deleted, modified or foreign: no automatic append/overwrite | Pending |
| Explicit new phrase creates exactly one bound owned phrase | Passed in Renoise 3.5.4; created phrases 01 and 02 |
| Draft/source PB/timing/output settings survive switching and save/reopen | Pending |
| Live Edit context changes and stale asynchronous completion | Pending |
| One playback/transport smoke in Renoise | Passed; phrase preview produced output-meter activity |
