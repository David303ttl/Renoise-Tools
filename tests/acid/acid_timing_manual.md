# ACID timing: Renoise manual verification

Status: partial visual check on 2026-10-28, Renoise 3.5.4, Surge XT VST3,
fresh song and default all-NOTE source. Manual generation and regeneration
committed a 16-step Straight Repeat and 16-, 12- and 64-step Triplet Repeat.
The triplet phrases displayed LPB 6 and shuffle 0; their lengths were 65, 49
and 257 lines respectively. Visible initial cells alternated NOTE and OFF.
The 64-step Play Once phrase displayed 128 lines in both modes, with LPB 6
for Triplet and 8 for Straight, and shuffle 0. These are visual observations;
loop endpoints, later cells, measured playback duration and the remaining checks
below have not been verified. Lua mocks do not establish playback or receiver
behavior.

The user subsequently confirmed that the 12-step Triplet Repeat phrase was
audible and repeated evenly when triggered. Its duration against a beat
reference, transport changes, groove and pitch-bend playback remain unchecked.

Use a disposable song in Renoise 3.5 or later with a simple test instrument and
an available pitch-bend VST. Generate both Repeat and Play Once phrases in
Straight and 1/8 Triplet timing. Inspect NOTE, TIE, REST and midpoint OFF cells,
phrase LPB (8 and 6 respectively), shuffle (0), length and loop endpoints.
Check 1, 9, 12, 15, 16, 17, 33, 49 and 64 steps, including all REST. At 64
steps Repeat has 257 lines with an empty final sentinel; Play Once has 128.

Listen over several cycles: 16 straight and 12 triplet steps each occupy four
beats; 12 straight and 9 triplet occupy three; 15 triplet occupy five. Check
3/4, 4/4 and a non-bar-aligned 7/8 arrangement. Try song LPB 2, 3, 4, 6, 8,
12, 16 and 32 at BPM 60, 120 and 180. Change LPB and BPM during playback
without regenerating and record the phrase duration and tempo response.

Exercise start, stop, seek, loop-seam releases, and groove enabled and disabled.
With the reference VST, check pitch-bend slide and center reset at both phrase
LPBs; record receiver configuration and observed behavior. Check the legacy
speed timing model separately and record the displayed diagnostic.

Toggle timing during Live Edit and while a render is pending; verify that the
last selection wins and that the previous phrase survives errors. Check Undo,
Redo, Reset, draft save/reopen, switching owned phrases and instruments, and
protection of modified or foreign phrases. Record each result rather than
assuming a pass from phrase metadata alone.
