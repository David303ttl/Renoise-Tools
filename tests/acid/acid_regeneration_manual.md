# ACID integrated editor acceptance

Use Renoise 3.5 / API 6.2, the current ACID build and a disposable song.
The [editor playbook, section 13](../../com.david303ttl.ACID.xrnx/M5_EDITOR_PLAYBOOK.md#13-native-renoise-click-procedures-and-evidence-ledger)
is the canonical procedure. Execute every applicable numbered check; record
actual observations separately from deterministic/native harness results.
This guide prepares execution and claims no native pass.

## Setup and evidence

Record source commit and local changes, package identity, Renoise/API version,
OS/display scale, receiver and routing, fixture XRNS path/hash, and evidence
paths. Save a clean fixture before testing. Preserve original song tool-data
bytes and complete phrase preimages before failure tests. Stop on uncertain
rollback/readback and retain the affected document without retrying over it.

Open **Tools > ACID...**. Select an instrument with an audible receiver and a
non-send track. Select **New Phrase**, turn Live Edit off, and use **Generate**
to create an owned phrase. Use **Regenerate** for that unchanged owned target.
Retain both a clean committed fixture and a dirty draft fixture; never infer
committed state from the visible editor alone. Current stores use schema 2;
schema 1 must reject read-only without conversion or reset.

Use one row per numbered check, splitting rows when host/fixture differs:

| Procedure/check | Build / host / fixture / receiver | Actual clicks and input | Observed source / draft / phrase / history / sound | Evidence path / failure / uncertainty | Status |
| --- | --- | --- | --- | --- | --- |
| 13.x.y | | | | | Unverified |

Empty observations remain unverified. Include before/after values, affected
positions, phrase inventory and whether an actual human dialog was used.
For save/reopen, record the saved file and a fresh Renoise process identity.

| Canonical procedure | Execution focus / existing detailed guide |
| --- | --- |
| 13.1 Fresh source and shared views | Program/Grid, independent selectors/pages, all 32 stored slots and baseline-relative indicators; capture both views at normal display scale |
| 13.2 Sequential entry | PITCH/TIME entry, Check/Finish/Discard and navigation admission; distinguish staged values from canonical Grid/draft |
| 13.3 Mask and output | Extended / Clear mask controls, raw/resolved Decoded rows, tie-breaking and Generate/save/reopen |
| 13.4 Clipboard, labels, duplicate and failures | Pattern / Copy controls, all 32 values, metadata-only history, duplicate pre-save/readback and rollback evidence |
| 13.5 Clear and randomization | Execute the inline-parameter scope fixture below, then every remaining canonical check |
| 13.6 Audition and lifecycle | Actual sound/release, busy-host timing, modal/context cleanup and captured-object identity |
| 13.7 Persistence, ownership, undo and Live Edit | [Live Edit](acid_live_edit_manual.md), exact source/output association, corrupt/unsupported store byte preservation |
| 13.8 Retained workflow | [Native phrase workflow](acid_phrase_manual.md), stored/referenced/modified indicator cases and populated-song responsiveness |

## Scale library and scale-aware editing

Use a disposable song and retain a copy before testing. The scale selector,
root, category, search and Follow controls are session settings; the pitch mask
and pattern remain project data. Follow constrains Program/Grid note entry only
when the mask is enabled. Root/category/search browse without source edits;
selecting a scale applies its absolute mask at the chosen root as one undoable edit.

1. Open **Extended / Clear** and confirm the selector includes **Custom**,
   root choices C through B, categories, scale names, search, and an unchecked
   **Follow scale** control. Search a distinctive bundled scale name and verify
   the result list narrows by name or alias. Clear search and verify the list
   returns. Check that scales with identical pitch classes are represented once
   with their alternate names discoverable as aliases.
2. Select a bundled scale at C. Verify exactly its pitch classes become checked
   and MASK turns on. Click **Undo** once; verify the prior mask and disabled
   state return. Click **Redo**; verify the selected scale mask returns. Change
   root and confirm source, draft, history, and native phrase are unchanged.
   Select the same preset at the new root and verify the new absolute mask is
   one undoable edit. Undo that edit and confirm the previous mask returns
   independently of the browser root. Return to the old root and confirm its
   matching preset is detected without a source edit.
3. Manually toggle one class. Verify the selected scale updates to a matching
   catalog entry when one exists, otherwise to **Custom / current mask**. Select
   **Custom / current mask** and verify it does not modify the current mask.
   Confirm changing category or search does not create pattern edits or history
   entries.
4. Turn **Follow scale** on with MASK enabled. In Program, enter allowed and
   disallowed note classes through the key controls. Verify disallowed entry
   snaps to the nearest allowed pitch class, with equal-distance ties snapping
   downward. Repeat through Grid pitch entry and inspect allowed-note key
   highlighting. Turn Follow off and verify both editors accept chromatic notes
   again. With Follow on but MASK disabled, verify note entry remains
   chromatic. Confirm existing notes are not rewritten by selecting a scale or
   toggling Follow.
5. Import a valid custom `.txt` file using the Renoise file picker. Record the
   exact file and fixture contents. Verify new scales are available under the
   custom/imported category, the imported library survives reopening the tool,
   and import itself does not modify the active mask, pattern, draft, or Undo
   history. Import a duplicate pitch-class set under a second name and verify it
   appears as an alias of the existing entry instead of a second scale. Import
   a conflicting preset or alias name with different notes and verify the entire
   import is rejected without changing preferences or the editor.
6. Cancel the file picker and verify all state remains unchanged. Try malformed
   rows, invalid pitch classes, duplicate-only files, and a file with one valid
   and one invalid row. Record whether each import is accepted or rejected;
   verify rejected input leaves the library and editor untouched. Verify the
   documented text format with a small hand-written file and capture any parser
   diagnostics. Include a comment containing `=`; it must be ignored. The
   expected format is one scale per line, with semitone
   intervals from the root; `0` is required. Blank lines and `#` comments are
   ignored, and `[Category]` headings are optional:

   ```text
   # Semitone offsets from the root
   [Custom]
   My bright scale = 0 2 4 7 9
   My dark scale = 0, 3, 5, 7, 10
   ```
7. Save and reopen the song in a fresh Renoise process. Verify mask and pattern
   are restored while root, browser selection, search, and Follow return to their
   documented defaults. Confirm the imported scale remains in the library.
   Verify Recovery and stale-draft guards prevent scale or Follow control edits
   from admitting an unrelated pattern edit.

## Direct operations and inactive memory

This fixture distinguishes scopes through the real controls. Do not substitute
a 32/32 active fixture. Repeat in Program and Grid.

1. In **Grid**, set LAST STEP and Active PITCH span to 32. Across both pages,
   enter REST/TIE at T02..T07 and non-C flagged notes at P01..P05 so each
   Active clear changes the source. Also enter distinctive TIME NOTE/TIE/REST
   values at 8..32 and nondefault PITCH notes with ACCENT/SLIDE at 6..32.
   Record every stored value. Generate a clean
   baseline, then set LAST STEP to 7 and Active PITCH span to 5 with Live Edit
   off. Record this dirty draft and the unchanged committed phrase.
2. Select workspace **Extended / Clear**, operation **Clear TIME**, scope
   **Active memory**, then **Apply**. Verify immediate application without a
   prompt, retaining LAST STEP 7 and PITCH span 5. Confirm
   T01..T07 are NOTE and T08..T32 are unchanged. Raise LAST STEP to 32 for Grid
   inspection, then use ACID **Undo** to restore that bound and the operation.
3. Repeat **Clear TIME** with **All 32 stored** for T01..T32;
   Apply changes inactive TIME too while LAST STEP remains 7. Undo. Repeat
   **Clear PITCH** with both scopes: Active affects P01..P05, All affects P01..P32;
   inspect retained notes and flags on both Grid pages after temporarily raising
   the span. Undo inspection edits before comparing the operation baseline.
4. Disable **MASK** for the fixed chromatic vector below. Select
   **Randomize PITCH > Active memory**. Set inline Seed 1, Minimum
   MIDI 24, Maximum MIDI 60. Inspect selected scope and parameters. Verify parameter
   edits alone leave source/history/draft unchanged. Click **Apply** and verify
   direct application without a prompt.
   Verify P01..P05 raw MIDI 28,51,40,43,32, flags preserved and P06..P32 intact.
   Verify Seed stays 1; Apply again and verify no change. Set Seed to 2 and
   Apply: verify a fresh result and Seed stays 2.
   Without Undo, set Seed to 1 and Apply: verify the first result returns.
   Set Seed to 2 and Apply: verify the second result returns. Undo these two
   recall edits before continuing. Keep range, mask and scope unchanged.
   Undo the second Apply. Set Seed to 1 and Apply: the original result stays
   unchanged and Seed stays 1. Undo the first edit and Redo it.
   Undo; reset Seed to 1, repeat with All 32 stored and inspect inactive entries as well.
5. Repeat **Randomize TIME** using Seed 1, NOTE/TIE/REST weights 2/1/1, both
   scopes and direct Apply. The first five commands are N,R,N,T,N;
   Active retains T08..T32. Inspect TIME 01 normalization using the canonical
   13.5 fixture. Scope changes never change LAST STEP or PITCH span.
   Apply Seed 7, then Seed 8, then Seed 7 again without Undo: verify the first
   timing result returns with unchanged weights and scope.
   Confirm PITCH/TIME retain separate seeds and Last used values when
   switching operations. Undo a random edit, then **Repeat last** with unchanged
   settings/mask: verify the result returns and the seed field stays unchanged.
   Before an operation's first valid Apply, Repeat last is disabled. Set a seed
   to 2147483646 and Apply: verify Last used and the seed field both show it.
   Invalid parameters and staged entry leave seed fields and Last used unchanged.
6. After each applied scope case, save the dirty draft, close Renoise, reopen
   the exact XRNS in a fresh process and open ACID. Compare all 32 stored values,
   bounds, mask, settings and label with the captured draft; committed phrase
   cells remain the baseline until Generate. Use separate saved fixture copies
   for Active and All so neither comparison depends on a prior operation.
7. Execute the remaining 13.5 operations, immediate Reset Pattern, no-op and
   single Undo/Redo checks. Record inline-control legibility and button reachability.
