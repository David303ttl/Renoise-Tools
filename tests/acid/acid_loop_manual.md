# ACID native phrase repeat verification

The pure cycle interpreter and physical intro plus steady-cycle plan have
automated semantic coverage. A Renoise 3.5.4 offline WAV render at BPM 137 and
phrase LPB 8 tested lengths 1, 16, 17, 32, 33, 48, 49 and 64 using one
sustained selective phrase per length. Each render covered four nominal
periods; pitch/marker checks found zero mismatches. The tested sample was a
168-frame, 44.1 kHz saw-like single-cycle sample, looped from frame 1 to 168,
root note 48, NNA Cut, mapped across note values 0–119. Song LPB was set to 8
for the renders. This verifies the tested grid periods and pitch markers for
those lengths; it does not verify mixed NOTE/TIE/REST boundaries, held-voice
continuity, slide, transport restart/seek, or general sampler configurations.

The WAV probe confirmed that `loop_end` is exclusive: range 1..9 repeats lines
1–8, range 1..7 repeats lines 1–6, and intro range 9..17 repeats lines 9–16.
A one-step phrase also needs one extra endpoint line. The planner uses this
sentinel convention. A corrected mixed-event probe passed 64 mid-step
pitch/silence checkpoints across four steady cycles for two hand-built native
phrases (`N,T,N,R,N,T,T,T`, span 3; `N,T,N,T,T,T,T,R`, span 2). See the full
[mixed-event result](renoise_mixed_repeat_probe_manual.md).

**ACID writer result (Renoise 3.5.4):** generated and source-saved baseline
Repeat phrases for lengths 1, 16, 17, 32, 33, 48, 49 and 64. Each used active
PITCH span 3 and TIME `N,T,R` at steps 1–3, followed by NOTE commands for the
remaining steps when present. One sustained trigger was rendered and sampled at
780 mid-step pitch/silence checkpoints across three cycles; no mismatches were
found. The generated phrases had `4L+1` physical lines for TIME length `L`,
`loop_start=2L+1` and `loop_end=4L+1` (exclusive sentinel). Phrase ownership
and source save/load were also checked. This verifies the recorded source,
metadata and sampled pitch/silence schedule only. Sample release/cut tail,
voice continuity, transport stop/start, seek, undo and slide remain unverified.

ACID now enables baseline Repeat generation by default, and refuses slide
transitions and non-baseline audio modes in Repeat. For the standalone
Scripting Terminal endpoint probe and setup, see
[`renoise_loop_probe_manual.md`](renoise_loop_probe_manual.md). Phrase-loop
property signatures come from the pinned API 6.2 definitions; they do not
prove playback behavior beyond the recorded probe.

**All-REST writer result (Renoise 3.5.4):** a 64-step Repeat source generated a
257-line phrase with 257 empty note cells and passed source/ownership checks.
The render callback reported 128 raw events, while the rendered phrase had
zero NOTE or NOTE OFF events. Treat this as a silent-source check; the callback
event count is not the musical note count.

**Fresh trigger after release (Renoise 3.5.4):** a 16-step ACID-generated
Repeat phrase was triggered at song line 1, released with a host NOTE OFF after
64 song lines, and triggered again at line 81. WAV frequency/silence checks
compared the first six TIME steps of both traversals. Both matched
`N,T,R,N,N,N` with pitch 36, pitch 36, silence, pitch 39, pitch 43 and pitch 36.
This verifies a new trigger after release for this phrase and sample setup;
transport stop/start, seeking, and other phrase states remain unverified.

## Renoise visual and persistence checks (2026-10-27)

These checks used Renoise 3.5.4 Demo, a disposable song, BPM 137, song LPB 8,
phrase LPB 8, and a 168-frame mono 44.1 kHz sample. They verify generated
phrase structure and editor behavior, not audio output.

**Writer page-boundary cells:** an Extended 64-step Repeat source used NOTE at
steps 16/32/48, TIE at 17/33/49, and REST at 18/34/50; other TIME entries were
NOTE. ACID generated phrase 02 with 257 lines, `loop_start=129`, and exclusive
`loop_end=257` (116 notes, 6 NOTE OFFs, 128 raw events). Inspection of the
writer-generated primary note column found:

| TIME steps | Cold intro cells | Repeating-cycle cells |
| --- | --- | --- |
| 16 NOTE, 17 TIE, 18 REST | 31 NOTE, 33 TIE hold, 35 NOTE OFF | 159 NOTE, 161 TIE hold, 163 NOTE OFF |
| 32 NOTE, 33 TIE, 34 REST | 63 NOTE, 65 TIE hold, 67 NOTE OFF | 191 NOTE, 193 TIE hold, 195 NOTE OFF |
| 48 NOTE, 49 TIE, 50 REST | 95 NOTE, 97 TIE hold, 99 NOTE OFF | 223 NOTE, 225 TIE hold, 227 NOTE OFF |

This closes the writer-coverage gap for those page boundaries at the cell and
layout level. The cells were inspected in Renoise; this session could not
record their sound.

**Live Edit length and span:** with Live Edit on, LAST STEP and active PITCH
span were changed through 64→17→1→64. The same phrase resized 257→69→5→257
lines, and changing the span did not append another phrase. With Live Edit off,
LAST STEP/span changes left the previous 257-line phrase pending; manual
Generate then resized it to 69 lines. No stale lines or extra phrase were
observed in these checks. Rapid edits and changes while a render was in flight
were not tested.

**Original-mode persistence:** generated a 16-step Original Repeat phrase
(phrase 01: 32 notes, 0 NOTE OFFs), saved the temporary XRNS, reopened it, and
reopened ACID. ACID reported `Restored ACID source for phrase 01`; regenerating
that phrase succeeded. This adds one Original-mode source/seal roundtrip. It
does not cover every stored field or entry-mode switching.

**Ownership and context guards:** changing loop start, loop end, and an effect
through the Renoise Scripting Terminal each caused regeneration refusal. After
the displayed loop/effect values were restored, that phrase remained refused;
the untouched phrase still regenerated. Changing songs with ACID open also
caused the stale editor to refuse generation until ACID was reopened.

**Deferred audio and lifecycle checks:** the WAV render command displayed
`Rendering is disabled in the demo version of Renoise`. Sample release/cut
tail, ending-REST audibility, held-voice continuity, cold-intro versus steady
cycle sound, transport stop/start and seek, and keymapped triggering therefore
remain unverified in this session. The UI identifies slide continuity and
advanced audio modes as unsupported in Repeat, but a fresh source-specific
slide-refusal request was not completed here. Rapid/in-flight edits, disable or
close during a job, undo/redo, forced source-save/rollback failure, and manual
cutover checks for earlier formats/seals also remain outstanding.

Per the user's decision on 2026-10-27, the M2 implementation and structural
acceptance are closed with these audio checks deferred until a registered
Renoise build is available. Do not treat that closure as audio or hardware
fidelity evidence.

The earlier 4-step NOTE/TIE/NOTE/REST phrase experiment used an endpoint that
produced a 7-line period instead of the intended 8 lines. Its TIE/OFF result is
exploratory only; use the corrected two-case result linked above for the
recorded pitch/silence checkpoints.

Use a disposable song. Record the Renoise build, OS, BPM, song LPB/TPL, phrase
LPB, sample loop configuration, source, expected phrase lines, loop endpoints,
and observed playback. Use a looping single-cycle saw sample. Keep cell
inspection results separate from recorded audio or transient measurements.

1. Generate baseline Repeat phrases through ACID for lengths 1, 16, 17, 32, 33,
   48, 49 and 64 TIME steps. Trigger once and listen for at least three cycles;
   host retriggers must not conceal the phrase period. Confirm no grid drift and
   compare generated loop endpoints and cells against the hand-built probes.
2. Test mixed NOTE/TIE/REST patterns at steps 16/17, 32/33 and 48/49. Include
   NOTE-TIE-NOTE, NOTE-REST-NOTE, all NOTE, all REST, and a leading REST that
   receives a held voice only on repetition.
3. Compare the cold intro with the steady loop cycle for a trailing TIE, ending
   REST and ordinary last NOTE. Verify Repeat refuses outgoing SLIDE transitions
   (including equal-pitch cases) and non-baseline audio modes. Do not interpret
   those refusals as evidence of native slide behavior; correct phrase cells
   alone do not prove sample voice continuity or attack behavior.
4. Test sustained phrase trigger, release, host stop/start, and seek. Check
   keymapped triggering separately from selective phrase triggering.
5. Change LAST STEP and active PITCH span through 64→17→1→64 with Live Edit
   both off and on. Verify no stale lines/effects, no unrelated phrase changes,
   and correct queued regeneration while an earlier render is in flight.
6. Edit note, effect, loop start and loop end manually. Regeneration must refuse
   each modified phrase. Force source-save and rollback failures if possible;
   confirm exact old source, phrase, and playback selection restoration or
   identify retained recovery material.

Writer-generated baseline Repeat passed the recorded grid and pitch/silence
checks, and the 2026-10-27 writer-cell, Live Edit, Original-mode roundtrip, and
ownership/context checks are recorded above. Sample release/cut tail, native
voice continuity, source-specific slide refusal, stop/start, seek, undo, and
the remaining lifecycle/failure-injection checks are still unverified. Do not
describe native sample glide or held-voice continuity as verified from the
tested checkpoints.
