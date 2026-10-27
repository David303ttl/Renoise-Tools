# Native phrase loop probe (Renoise API 6.2)

This standalone experiment checks Renoise phrase loop endpoints and basic
sustained NOTE/TIE/REST behavior without using ACID's phrase writer. It only
creates phrases on a dedicated instrument named `ACID LOOP PROBE`. It refuses
to run if that instrument already contains phrases. Run it only in a
disposable song copy; it does not alter any existing instrument or phrase.

Renoise 3.5.4 endpoint behavior was also measured using the separate offline
WAV probe: `loop_end` is exclusive, ranges 1..9 and 9..17 repeat lines 1–8 and
9–16 respectively, and the 1/16/17/32/33/48/49/64 marker renders had zero
pitch/marker mismatches. See [the ACID repeat record](acid_loop_manual.md) for
the sample and render setup. The four-phrase NOTE/TIE/NOTE/REST experiment
described below used a 7-line repeated period for an intended 8-line phrase;
its observed TIE sustain and OFF release are preliminary only and do not pass
the mixed-event check. Use the endpoint sentinel convention in a corrected
probe before treating those observations as acceptance evidence.

## API contract checked

The pinned API 6.2 definitions in
`sdk/renoise-api-6.2/definitions/library/renoise/song/instrument/phrase.lua`
define phrase loop start in `1..number_of_lines`, loop end in
`loop_start..number_of_lines` with `loop_end > loop_start`, and looping as the
switch between one-shot and loop playback. The same definition sets phrase
LPB to `1..256`, says it is phrase-local, and states that TPL is not configured
per phrase. `instrument.lua` defines `insert_phrase_at(index)`,
`delete_phrase_at(index)` and a 126-phrase limit. The note-off value is
`renoise.PatternLine.NOTE_OFF` in `definitions/library/renoise/song/pattern/line.lua`.
The offline API pages are `sdk/renoise-api-6.2/docs/API/renoise/renoise.InstrumentPhrase.html`
and `renoise.PatternLine.html`.

The API text says playback begins at the phrase start before entering its loop.
It does not establish audible endpoint inclusion, note release, or voice
continuity. Those are the measurements this probe records.

When checking whether an object returned by `instrument.phrases` is the exact
phrase inserted by the script, use Renoise's `rawequal` identity comparator.
The pinned global API documentation specifies that it compares Renoise API
object identities; ordinary equality may compare phrase contents instead.

## Preconditions

1. Save a disposable XRNS copy and open it in the Renoise version under test.
2. Create a new, otherwise unused instrument named exactly `ACID LOOP PROBE`.
   Load one looping single-cycle saw sample and map it across at least
   note values 36–50 so every marker uses the same sample. Record the sample
   loop mode, root note, mapping and Renoise version.
3. Confirm the probe instrument has no phrases. The script refuses any
   instrument with a different name or with existing phrases and checks that
   at least one sample buffer contains data.
4. In the Scripting Terminal, run the script using the local repository path,
   replacing the placeholder with the actual path to this checkout:

   ```lua
   dofile("<repository-root>/tests/acid/renoise_loop_probe.lua")
   ```

   A successful run appends four clearly named phrases. If setup errors, the
   script attempts to remove only phrase objects it created in that run.
5. Set the dedicated instrument's phrase playback mode to **Selective**. For
   each phrase, select its phrase program, place one trigger note using this
   instrument in a song pattern, and sustain playback without host retriggers.
   Keep unrelated instruments and phrases out of the trigger path.

## Endpoint cases

Each phrase uses LPB 8. At a fixed song BPM, an eight-line loop is expected to
repeat every `8 / 8 = 1` beat. Record the actual period in phrase lines and
beats, including the marker-note order. Trigger each case for at least five
repetitions from a single host note.

| Probe phrase | Loop data | Expected observation |
| --- | --- | --- |
| `full 1-8` | 8 lines, start 1, end 8; markers at lines 1, 3, 5, 7, 8 | Determine whether line 8 is included and whether the marker sequence repeats with an eight-line period. |
| `full 1-7` | 8 lines, start 1, end 7; same markers | Compare period and marker order with `full 1-8`; determine the audible role of the endpoint value. |
| `intro + 9-16` | 16 lines, start 9, end 16; cold markers in lines 1–7 and steady markers in 9–16 | First traversal begins at line 1; subsequent traversals repeat lines 9–16. Measure first traversal duration and steady period separately. |

Do not assume the API endpoint is inclusive based only on the displayed value.
Use marker order and timing to determine the actual period. Record whether a
fresh trigger starts at line 1 and whether a new trigger after release also
starts at line 1.

## Sustained NOTE / TIE / REST case

`NOTE TIE NOTE REST` is an eight-line phrase with NOTE 36 at line 1, no new
note at the TIE position (step 2), NOTE 43 at line 5 (step 3), and explicit
NOTE OFF at line 7 (step 4). At LPB 8, each TIME step occupies two lines.
Looping is enabled over lines 1–8.

Expected semantic observations:

- The first note sounds from line 1 through the step-2 TIE gap without a new
  attack at line 3.
- NOTE 43 begins at line 5 as a new attack.
- NOTE OFF at line 7 releases the sounding note; line 8 is silent.
- The same four-step marker and release pattern repeats every eight lines.

Record whether the sample loop sustains across the TIE gap, whether note 43
re-triggers, how quickly OFF releases it, and whether phrase wrap adds a note,
cuts the held sample early, or changes the measured period. This case tests
basic NOTE/TIE/REST playback only; it does not test selective slide or claim
TB-303 envelope fidelity.

## Results record

| Field | Observed value |
| --- | --- |
| Field | Observed value |
| --- | --- |
| Date / tester | 2026-10-27 / implementation verification |
| Renoise version / OS | Renoise 3.5.4 / Windows |
| Song BPM / LPB / TPL | 137 BPM / song LPB 8 / TPL not recorded |
| Probe instrument sample / loop mode / root note | Saw-like single cycle, 168 frames at 44.1 kHz, sample loop 1–168, root 48, NNA Cut, mapped notes 0–119 |
| Trigger note and selected phrase program | Sustained selective phrase trigger; per-length render probe |
| Endpoint behavior | `loop_end` is exclusive; 1..9 repeats 1–8, 1..7 repeats 1–6, 9..17 repeats 9–16 |
| Length WAV render | 1, 16, 17, 32, 33, 48, 49 and 64 steps; four nominal periods per render; zero pitch/marker mismatches |
| `full 1-8`: marker order / period | Separate four-phrase probe used end 8; its repeated period was not accepted as an endpoint result |
| `full 1-7`: marker order / period | Exploratory only; do not use for acceptance |
| `intro + 9-16`: first duration / repeated period | Separate four-phrase probe; use the measured sentinel result above (9..17 repeats 9–16) |
| NOTE/TIE/NOTE/REST audible result | TIE gap sustained and OFF released; wrong endpoint produced 7-line period instead of 8, so mixed-event acceptance remains blocked |
| Fresh trigger and trigger after release | Not verified |
| Audio recording / screenshot paths | WAVs were rendered to the local TEMP directory; no artifacts committed |
| Result per case (Pass / Fail / Blocked) | Endpoint and eight grid lengths: pass for measured setup; mixed NOTE/TIE/REST period: fail as configured; restart/seek: not tested |
| Notes / unresolved behavior | Corrected-layout mixed-event probe, cold/repeat articulation, slide continuity, stop/start, seek, alternate mappings, undo and save/reopen remain unverified |

Delete the dedicated `ACID LOOP PROBE` instrument or the four phrases after
recording results. Do not run the script again in the same instrument: it
intentionally refuses non-empty probe instruments instead of touching prior
results.
