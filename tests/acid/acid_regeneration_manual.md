# ACID safe regeneration

Use a disposable Renoise song and a sample instrument. The tool remains at
version 0.1. Record the Renoise version, tool revision and observations; these
checks cannot be inferred from automated tests.

**Performed on Renoise 3.5.4 (isolated disposable test song):** generated a
four-step NOTE/TIE/NOTE/REST baseline one-shot phrase in a new slot, loaded its
persisted source, changed a pitch and regenerated the same slot, then manually
edited a generated note and confirmed regeneration refused the modified
phrase. The phrase count remained intact. This checks the basic current-format
one-shot path only. Undo/redo, UI lifecycle invalidation, Live Edit under
pressure, and stop/start/seek were not tested.

**Save/reopen check on Renoise 3.5.4 (isolated temporary tool and disposable
XRNS):** saved and reopened a current-format generated phrase and verified both
its ownership seal and source data loaded. The source was Extended, four TIME
steps `N,T,N,R`, active PITCH span 3, with an inactive P60 carrying octave-up
and slide flags. This confirms persistence for that case only; undo/redo,
Live Edit/UI lifecycle, broader field roundtrips, and audio behavior after
reopen were not checked by this probe.

**GUI smoke on Renoise 3.5.4 (isolated probe tool):** opened the current ACID
GUI, loaded an existing Extended source with 64 TIME steps, active PITCH span
3 and Repeat selected, then regenerated its owned 257-line phrase successfully.
This confirms that narrow load-and-regenerate path only. Live Edit, dialog
close, notifier cleanup, undo and other GUI lifecycle behavior were not tested.

**Live Edit single-change smoke on Renoise 3.5.4 (isolated tools):** selected
an existing 16-step Extended/span-3 Repeat phrase, enabled Live Edit, and
changed TIME02 from TIE to REST. The GUI reported regeneration. A separate
isolated tool verified saved source TIME02=`R`, NOTE OFF at cold line 3 and
repeating line 35, and a valid owned seal. This covers one edit/regeneration
only; rapid edits, edits while a render is in flight, disabling Live Edit,
dialog close, notifier cleanup and undo remain untested.

1. Create a new ACID phrase, then regenerate it after editing the source.
   Check that the selected phrase is updated, the phrase count is unchanged,
   and unrelated instruments, phrases and tracks are unchanged.
2. Change a generated note, effect, loop flag or loop endpoint by hand.
   Regeneration must refuse the modified phrase without changing it or its
   saved source. Repeat with a foreign phrase and a duplicate ACID ID.
3. Select a phrase or song data from an earlier development format. Confirm
   that ACID refuses it without adoption, conversion or an automatic write.
   Recreate the pattern using the current source format.
4. Save and reopen the song. Load an unchanged current-format phrase and
   compare the source, including all stored pitches, active span, TIME memory,
   entry and playback modes, and audio mode. Selection or loading must not
   rewrite the stored source.
5. In a disposable copy, switch or delete the destination, disable Live Edit,
   or close the song during a render. Verify stale work cannot commit and that
   only its own temporary phrases are removed. Inspect and retain recovery
   material if a rollback or cleanup fails.
6. Exercise undo and redo around regeneration and save/reopen. Record whether
   phrase data and source data remain consistent after each action.

The content seal detects changed generated phrase content; it is not a
cryptographic guarantee. A backup is retained until phrase and source writes
have been checked. See [the loop protocol](acid_loop_manual.md) for playback,
length, boundary and Live Edit cases.

From the repository root, run `./scripts/run_tests.ps1 -Tool ACID` and
`./scripts/package.ps1 -Tool ACID` in PowerShell 7. Automated checks do not
replace this Renoise protocol.
