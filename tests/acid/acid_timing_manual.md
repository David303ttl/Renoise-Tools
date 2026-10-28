# ACID timing: Renoise manual verification

Status: partial visual check on 2026-10-28, Renoise 3.5.4, Surge XT VST3,
fresh song and default all-NOTE source. Manual generation and regeneration
committed a 16-step Straight Repeat and 16-, 12- and 64-step Triplet Repeat.
The triplet phrases displayed LPB 6 and shuffle 0; their lengths were 65, 49
and 257 lines respectively. Visible initial cells alternated NOTE and OFF.
The 64-step Play Once phrase displayed 128 lines in both modes, with LPB 6
for Triplet and 8 for Straight, and shuffle 0. These are visual observations;
measured playback duration and the remaining checks below have not been fully
verified. Later targeted readback and playback measurements are recorded below.
Lua mocks do not establish playback or receiver behavior.

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

## Targeted triplet renderer readback

Status: **Readback passed; repeated playback across the wrap not yet checked**.
On 2026-10-28, Renoise 3.5.4 generated the fixture below through the installed
ACID writer against Surge XT. The host readback checked all 385 note-column-1
cells in the Play Once and Repeat phrases: the expected notes, midpoint OFFs,
zero delays and the empty sentinel matched. Play Once read back LPB 6, shuffle
0, length 128 and looping disabled; Repeat read back LPB 6, shuffle 0, length
257, looping enabled and endpoints 129 and 257. The generated result carried
the expected warning that the phrase program was off. The raw readback is
`tmp/acid-articulation/timing-readback-2026-10-28.txt`, SHA-256
`402d43f42763ef0a509418c83a2b3c04c368b4d0fa929535015df211e4ee4fed`.
This does not establish audible behavior across the loop wrap.

Use the actual generated phrase in Renoise, not the Lua
integration mock. In a disposable song, set Extended mode, TIME length 64,
PITCH length 64, every TIME step to NOTE, and Triplet timing. Set the PITCH
sequence to C-4 throughout except steps 1, 12, 33, 49 and 64, which should be
C-3, D-3, E-3, F-3 and G-3 respectively. Disable accents and slides. Generate
both Play Once and Repeat, and record the actual note and OFF cells from the
phrase editor or Renoise scripting terminal. Confirm the remaining NOTE steps
also retain their C-4 values and no unexpected events appear between them.

| Source step | Expected note | Play Once / cold line | Repeat steady line |
| --- | --- | --- | --- |
| 1 | C-3 | 1 | 129 |
| 12 | D-3 | 23 | 151 |
| 33 | E-3 | 65 | 193 |
| 49 | F-3 | 97 | 225 |
| 64 | G-3 | 127 | 255 |

The midpoint OFF for each listed NOTE belongs on the following line, including
lines 128 and 256 at the ends of the cold and steady cycles. Confirm Play Once
has LPB 6, shuffle 0, 128 lines and looping disabled. Confirm Repeat has LPB 6,
shuffle 0, 257 lines, looping enabled, `loop_start = 129` and `loop_end = 257`;
line 257 is an empty sentinel and the loop end is exclusive. Inspect the last
steady NOTE/OFF at lines 255–256 and the first steady NOTE/OFF at lines 129–130,
then listen across several wraps for the G-3 to C-3 boundary and missing,
duplicated or misplaced notes. Record the source settings, phrase metadata,
actual cells, Renoise version and observed wrap behavior. A metadata-only or
mock result does not pass this check.

## Targeted glide and bend playback

Status: **Bounded live loopback measurements passed** on 2026-10-28 at 120 BPM,
Renoise 3.5.4, through the PHL24E1N1100A WASAPI loopback at 48 kHz stereo.
ACID generated Play Once phrases from NOTE C-4, TIE, NOTE G-4, TIE, REST,
REST, NOTE C-4, REST, with SLIDE on the first pitch. The sample was a 168-frame
44.1 kHz forward-loop saw, root C-4, with note-cut behavior. The VST was Surge
XT VST3, current modified Init preset, both scenes at ±12 semitones and
portamento 0 ms; ACID's bend range was 12. The song used LPB 4 and TPL 12.
These are measured loopback results, not a listening assessment or evidence for
other receivers and settings.

| Capture | Phrase LPB | Measured pitch trajectory and release | SHA-256 |
| --- | --- | --- | --- |
| `timing-audio-1.wav`, Surge | 8 | Approximately 130 → 161 → 195 Hz; silence after REST; subsequent note approximately 130 Hz | `8bd1ade443b748b8133a587a5aeaa1191c26018a6e17d9ce2dba32338c6989ac` |
| `timing-audio-2.wav`, Surge | 6 | Approximately 130 → 158 → 195 Hz; silence after REST; subsequent note approximately 130 Hz | `5020a4df9c48af7b0bcc3b3d6deeee8930b0a3ed2a414287c983853ca6bde343` |
| `timing-audio-3.wav`, sample | 8 | Approximately 262 → 316 → 393 Hz; silence after REST; subsequent note approximately 262 Hz | `7b0d8c6385fb2c7cc1aa90effab5434aee224a610d3f46b1e7cf2a06d98738f1` |
| `timing-audio-4.wav`, sample | 6 | Approximately 262 → 297 → 394 Hz; silence after REST; subsequent note approximately 262 Hz | `d4b1b3c52a8216ada5c1a8f420462ddd89c00f4b77528105d35c1631707a8e7d` |

Files and host readback are under `tmp/acid-articulation/`. Captures are
stereo PCM16 without normalization; peak amplitudes were below 0.014. Pitch
estimates use 45 ms windowed spectra and are approximate. The sample's measured
level stayed continuous during its upward transition; the later C confirms the
VST's bend returned to center. The generated sample phrases used `0G1C` and
continuation commands. Both generated VST phrases contained M1 commands.

For further checks, use the same tempo and
source at each timing setting; capture or listen to the generated phrases, and
record the instrument, preset, routing, BPM and results separately for LPB 8
(Straight) and LPB 6 (Triplet).

1. With a sample instrument, generate a connected C-4 to G-4 slide followed
   by a REST. Confirm an audible continuous upward glide, arrival at the target,
   and release at REST without an unintended retrigger or stuck voice. Inspect
   the generated glide and OFF cells as supporting evidence.
2. With the reference bend-responsive VST, set matching ±12-semitone ranges in
   ACID and the receiver and disable the VST's own glide. Generate a C-4 to
   G-4 slide followed by REST. Confirm the held voice bends toward G, releases,
   and the bend returns to center; trigger a subsequent C-4 to detect a stuck
   bend. Confirm commands reach the intended receiver, and record audible or
   captured pitch and reset behavior as well as the phrase cells. Follow the
   receiver controls in [the pitch-bend procedure](acid_m35_s_manual.md).

| Check | LPB 8 | LPB 6 | Evidence / details |
| --- | --- | --- | --- |
| Sample glide and REST release | Measured | Measured | Bounded saw sample above |
| Reference VST bend, release and center reset | Measured | Measured | Surge XT configuration above |

Record failures and inconclusive results explicitly. Generated command structure
alone does not establish the audible result or complete timing acceptance.
