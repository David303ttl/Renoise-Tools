# ACID timing: Renoise manual verification

Status (2026-10-28): measured offline phrase-period and BPM/LPB checks pass in
Renoise 3.5.4; the complete M4 gate remains blocked by the unmeasured
independent host-beat reference and live transport checks below. The initial
visual check used Surge XT VST3, a fresh song and default all-NOTE source.
Manual generation and regeneration
committed a 16-step Straight Repeat and 16-, 12- and 64-step Triplet Repeat.
The triplet phrases displayed LPB 6 and shuffle 0; their lengths were 65, 49
and 257 lines respectively. Visible initial cells alternated NOTE and OFF.
The 64-step Play Once phrase displayed 128 lines in both modes, with LPB 6
for Triplet and 8 for Straight, and shuffle 0. These are visual observations;
measured playback duration and the remaining checks below have not been fully
verified. Later targeted readback and playback measurements are recorded below.
Lua mocks do not establish playback or receiver behavior.

On 2026-10-28, a further interactive check in Renoise 3.5.4 used an
untitled song, Surge XT and a new 16-step all-NOTE draft. In Program view,
selecting Triplet changed the displayed division and cycle from 1/16 and
16/4 beats to 1/8 triplet and 16/3 beats. Undo restored Straight and Redo
restored Triplet. With Live Edit off, Generate committed a new owned phrase
and the editor reported 32 notes and 32 OFF events. The host warned that the
phrase program was off. This check did not measure playback, test Grid or
exercise the remaining source and target-switching cases below.

The user subsequently confirmed that the 12-step Triplet Repeat phrase was
audible and repeated evenly when triggered. That listening observation
predates the measured captures below and is not a host-beat reference.

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

For pitch-bend ordering, inspect fresh attacks after center resets at LPB 8 and
6: the reset is on the attack line and the note delay is one 1/256-line unit.
Check successive attacks and loop wraps for drift, and record whether the
receiver observes the reset before each attack. Cell placement alone does not
establish receiver ordering or audio behavior.

For source and editor verification, enter distinct PITCH flags and TIME commands
on multiple pages, toggle timing in both Program and Grid, and confirm the
memories are unchanged and the displayed division and N/4 or N/3 beat duration
match. With Live Edit off, confirm the source stays marked dirty through view
changes and Undo/Redo until Generate succeeds. Save and reopen an ungenerated
draft and verify its timing; then generate, switch between owned phrases with
different timing, PB Range and output settings, and verify each restores its own
values. Test new and foreign destinations with Live Edit armed, and check that
rapid timing changes commit only the latest source without modifying the foreign
phrase. These source/editor checks remain unverified in Renoise.

## Measured phrase-period and BPM/LPB acceptance

**Status: static Renoise 3.5.4 audio measurements passed; live acceptance is
still open.** ACID generated Repeat phrases through the installed writer in
the disposable `tmp/acid-m4-acceptance/probe_song.xrns`. The instrument was
`ACID ARTICULATION PROBE`, global slot `01`, phrase program `08`, Selective
phrase mode. Every timing capture used one host NOTE, one later host OFF, four
phrase traversals (one cold plus three steady), a silent pre-roll, 48 kHz stereo
PCM24, precise interpolation and no normalization. Straight phrases read back
LPB 8; Triplet phrases LPB 6; every phrase had shuffle 0. The analyzer checked
the measured onset schedule against the expected step positions with a 5 ms
tolerance and retained each WAV, render sidecar, run receipt and JSON report.

The complete 8 × 3 × 2 matrix used song LPB 2, 3, 4, 6, 8, 12, 16 and 32 at
60, 120 and 180 BPM. Each of its 48 WAVs passed with the expected number of
attacks: 64 for Straight 16 and 48 for Triplet 12. Results by BPM were:

| BPM | Expected four-beat cycle | Measured cycle intervals (ms) | Maximum onset error | Cases |
| ---: | ---: | --- | ---: | ---: |
| 60 | 4,000 ms | 4,000 / 4,000 / 4,000 | 0.667 ms | 16 |
| 120 | 2,000 ms | 2,000 / 2,000 / 2,000 | 0.667 ms | 16 |
| 180 | 1,333.333 ms | 1,333 / 1,333 / 1,334 | 0.667 ms | 16 |

Every matrix case stayed within the calibrated 5 ms onset tolerance. The
1 ms WAV measurement resolution accounts for the sub-millisecond errors and
the alternating 1,333/1,334 ms cycle readings at 180 BPM; no accumulating drift
was measured. Phrase LPB remained fixed at 8/6 while song LPB changed. The
renderer changed actual seconds with BPM as expected.

The required duration fixtures also passed at song LPB 8 and BPM 120:

| Fixture | Phrase | Beats per cycle | Expected / measured cycle (ms) | Attacks | Max onset error | WAV SHA-256 |
| --- | --- | ---: | --- | ---: | ---: | --- |
| T01 | Straight 16 | 4 | 2,000 / 2,000, 2,000, 2,000 | 64 | 0 ms | `8edf60f1a85159335c98b0e94de0903d6047f549dad12ab5babd0afbd55ef167` |
| T02 | Triplet 12 | 4 | 2,000 / 2,000, 2,000, 2,000 | 48 | 0.667 ms | `4bcdda705cfaebbe0be524a39267b1c6db0c5becbdeffafce11cdb1947a82f41` |
| T03 | Straight 12 | 3 | 1,500 / 1,500, 1,500, 1,500 | 48 | 0 ms | `63b4fe229ab70ceba832840c8dfbef13e926c9d652aa1b3ebe6c12e176ee768e` |
| T04 | Triplet 9 | 3 | 1,500 / 1,500, 1,500, 1,500 | 36 | 0.667 ms | `7f721a09b6590457414647036708a06b6a4c488eda40af8f2f410e77019defc6` |
| T05 | Triplet 15 | 5 | 2,500 / 2,500, 2,500, 2,500 | 60 | 0.667 ms | `4c86a8fcf2a534f54a05b1d676b65d7ca3ca6527c4b887c870adf15798acf913` |
| T06 | Triplet 64 | 64/3 | 10,666.667 / 10,666, 10,667, 10,667 | 256 | 0.667 ms | `5f152d880b39258b33cc489e7844fa38c58b83f8ed835c1947e983002d6e9e0e` |

T01 and T02 read back 65/49 lines with Repeat loops 33–65/25–49. T03/T04
read back 49/37 lines and loops 25–49/19–37. T05 read back 61 lines and loop
31–61. T06 read back 257 lines, 128 NOTE and 128 OFF events, loop 129–257;
the host OFF arrived before a fifth-cycle onset. There were no missing or
duplicated phrase attacks.

Explicit metronome grouping and host-pattern boundaries were also exercised
in the same disposable song. The single trigger remained in the first host
pattern in each arrangement; pattern boundaries did not retrigger the phrase.

| Arrangement | Fixture(s) | Renoise metronome grouping | Host pattern boundary | Captured arrangement |
| --- | --- | --- | ---: | --- |
| 3/4 | Straight 12, Triplet 9 | 3 beats × 8 lines | 24 lines | 6 patterns per capture; pre-roll aligned to a bar |
| 4/4 | Straight 16, Triplet 12 | 4 beats × 8 lines | 32 lines | 5 patterns per capture; pre-roll aligned to a bar |
| 7/8 | Triplet 12 | 7 beats × 4 lines = 28 lines at song LPB 8 | 28 lines | 6 patterns; 56-line aligned pre-roll |

The explicit 3/4 cases measured three-beat cycles at 1,500 ms; the 4/4 cases
measured four-beat cycles at 2,000 ms; the 7/8 Triplet 12 case measured
four-beat cycles at 2,000 ms while crossing 28-line host-pattern boundaries.
The detailed reports record per-onset timestamps, cycle errors, meter settings,
pattern counts, phrase readback, commit, package archive hash, WAV hash and
render-sidecar hash under `tmp/acid-m4-acceptance/`. Reports ending in
`.timing_report.json.verified.json` are the final reports with corrected
per-case arrangement provenance.

These are offline engine captures measured against the BPM/step-duration
formula using the WAV sample clock. No separately captured host metronome or
independent beat-click track was included, so the objective's independent
host-beat-reference comparison is still open. The captures also do not test
live BPM/LPB changes, stop/start, seek, groove, Live Edit during playback, or
the full sample/VST articulation matrix. They pass the static timing and
pattern-boundary portions only.

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
