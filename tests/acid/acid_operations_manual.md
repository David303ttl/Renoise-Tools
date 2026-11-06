# ACID scales and operations

Use a disposable song. Check source and phrase cells after an operation; a
changed draft does not change the committed phrase until **Generate** or Live
Edit writes it.

## Scales

1. Browse roots C–B, categories, names, aliases and search. Browsing and
   **Follow scale** do not edit the source. Selecting a scale applies its mask
   at the chosen root as one undoable edit; undo and redo restore the mask.
2. Toggle a pitch class. The selector should show a matching scale or
   **Custom / current mask**. Selecting the custom entry leaves the mask
   unchanged. With **Follow scale** and MASK enabled, Program and Grid note
   entry snaps to the nearest allowed pitch class, with ties downward. With
   MASK disabled or Follow off, entry remains chromatic. Existing notes are not
   rewritten.
3. Import a `.txt` scale file. Valid rows use semitone intervals from root and
   include `0`; blank lines and `#` comments are ignored, and `[Category]`
   headings are optional:

   ```text
   [Custom]
   My bright scale = 0 2 4 7 9
   My dark scale = 0, 3, 5, 7, 10
   ```

   Confirm import changes the library only and survives reopening the tool.
   Duplicate pitch-class sets become aliases. Cancelled, malformed or
   conflicting imports leave the library and editor unchanged.

## Operation scopes and deterministic vectors

Use Program and Grid. In Grid, set **Length** and **Pitch span** to 32. Put
REST/TIE in TIME 02–07; set non-C notes with flags in PITCH 01–05; enter
distinctive TIME values in 08–32 and flagged PITCH values in 06–32. Generate a
baseline, then set Length to 7 and Pitch span to 5 with Live Edit off. Keep this
unequal-scope fixture: Active memory means TIME 01–07 or PITCH 01–05; All 32
stored covers each complete array.

1. Apply **Clear TIME** and **Clear PITCH** in both scopes. Active clears only
   the active range; All 32 stored also clears inactive entries. Verify Length,
   Pitch span, inactive values and flags remain unchanged where outside scope.
   Each application is one undoable edit.
2. Disable MASK. For **Randomize PITCH**, use Active memory, Seed 1, Minimum
   MIDI 24, Maximum MIDI 60. Apply produces PITCH 01–05 raw MIDI values
   `28, 51, 40, 43, 32`, preserves flags and leaves PITCH 06–32 intact. Applying
   again with Seed 1 is unchanged. Seed 2 produces a different vector; returning
   to Seed 1 reproduces the first. Repeat with All 32 stored and inspect inactive
   slots.
3. For **Randomize TIME**, use Seed 1 and NOTE/TIE/REST weights 2/1/1. The first
   five commands are `N, R, N, T, N`; Active leaves TIME 08–32 intact. Repeat
   with All 32 stored. Seeds 7, 8, then 7 reproduce the first Seed 7 result.
   PITCH and TIME remember separate seeds. **Repeat last** uses the previous
   operation seed and current settings without changing the visible seed field.
4. Parameter edits alone do not alter source or history. Apply acts directly
   and creates one edit. Undo/Redo, reapplication of the same seed, and Repeat
   last should reproduce the expected values. Invalid parameters and staged
   sequential entry do not alter remembered seeds.
5. Save and reopen separate Active and All fixture copies. Verify all 32 stored
   values, Length, Pitch span, mask and settings restore; committed phrase cells
   remain at baseline until generated. Check the remaining operations, Reset
   Pattern, no-op behavior and single-step Undo/Redo.
