# Native 0G rate and articulation edge probe

This development-only probe appends six disposable Selective phrases to the
existing `ACID ARTICULATION PROBE` instrument. It does not change ACID runtime
behavior. Run it in a fresh disposable song after the diagnostic profile and
120 BPM calibration have passed:

In Renoise's Scripting Terminal, use **Load** to open
`tests/acid/renoise_native_effect_edge_probe.lua`, then run the loaded script.
This is a Renoise Lua helper, not a PowerShell script.
The helper writes portable preflight and final phrase/profile readbacks under
`tmp/acid-articulation/`. It refuses duplicate names by default. If the same
phrases already exist, inspect the preflight readback first, then set
`ACID_NATIVE_EDGE_APPEND_MISSING_AFTER_READBACK = true` in the Renoise
scripting context and rerun. Existing phrase properties and every non-empty
NOTE/effect cell are checked before any existing phrase is reused; no cell is
rewritten.

The script reports each phrase's program index. Select phrases by the exact
names below because indices depend on the instrument's existing phrases:

| Phrase | BPM | Phrase events | Host NOTE OFF |
| --- | ---: | --- | ---: |
| `ACID 0G08 RATE SWEEP` | 90 and 150 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 2 | step 12 |
| `ACID 0G20 RATE SWEEP` | 90 and 150 | NOTE 48 at step 0; NOTE 52 with `0G20` at step 2 | step 12 |
| `ACID 0G40 RATE SWEEP` | 90 and 150 | NOTE 48 at step 0; NOTE 52 with `0G40` at step 2 | step 12 |
| `ACID 0G08 REST CANCEL` | 120 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 1; NOTE OFF/REST at step 2 | step 8 |
| `ACID 0G08 FRESH NOTE` | 120 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 1; unflagged NOTE 48 at step 6 | step 8 |
| `ACID 0G08 GATED FRESH NOTE` | 120 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 1; NOTE OFF at line 12/step 5.5 with no effect; unflagged NOTE 48 at step 6 | step 8 |

Phrases are one-shot, LPB 8, one visible note and effect column, no key
tracking, and have 17/25 lines for the 8/12-step cases. `0G00` continues each
command through the next event or phrase end. Render a 2-second silent
pre-roll, the host trigger sequence, and at least 500 ms after the final host
OFF. Use 48 kHz, PCM24, precise rendering, no normalization, and peak at or
below -6 dBFS. For the six rate controls, capture each phrase at both BPM 90
and 150, keeping LPB 8 and TPL 12 fixed. Use three unchanged captures per
phrase/tempo pair. Record phrase readback, selected program, tempo, trigger,
WAV SHA-256, and render metadata.

The authored coverage prediction is
`ceil(4 * 16 / 0G-amount)` phrase command lines. At LPB 8/TPL 12, that is two
lines per straight TIME step, and each phrase line lasts 7500 / BPM ms. Thus
the four-semitone sweep predicts 8, 2, and 1 command lines for `0G08`, `0G20`,
and `0G40`. This protocol follows the existing independent native effect
control; it does not enable or claim new ACID runtime support. Analyze a
capture with its matching ID:

```powershell
./tests/acid/analyze_articulation_audio.ps1 `
  -CaseId native_0g20_bpm_90 `
  -OraclePath tests/acid/fixtures/native_effect_edge_cases.json `
  -WavPath tmp/acid-articulation/<capture>.wav `
  -OutputPath tmp/acid-articulation/<capture>.analysis.json
```

REST CANCEL checks for a partial moving transition followed by silence after
the REST/NOTE OFF. The ungated FRESH NOTE case is retained as a negative
control: three existing renders had no fresh attack at step 6 while pitch 48
was present, showing the glide state persists without an intervening NOTE OFF.
Do not discard those failed analyses. GATED FRESH NOTE adds the explicit NOTE
OFF at line 12/step 5.5, with no `0G` command on that line, then attacks NOTE
48 at step 6; its oracle requires silence before step 6 and the new attack.

For the writer variant, in ACID's tool scripting context set:

```lua
ACID_ARTICULATION_ORACLE_PATH = "tests/acid/fixtures/native_effect_edge_cases.json"
ACID_ARTICULATION_CASE_ID = "writer_0g20_rest_gated_fresh_note"
ACID_ARTICULATION_WRITER_MODE = "slide"
```

Then load/run `tests/acid/renoise_articulation_writer.lua`. The generated
source is `N T N T N T R`, pitches 48/52/48, slide index 1, fixed `0G20`.
Capture its connected glide at step 2, early gate at step 3.5, unflagged NOTE
at step 4, and REST release at step 6, with host OFF at step 8. Analyze three
unchanged writer captures as `writer_0g20_rest_gated_fresh_note` using the
same custom oracle path.

Run `./tests/acid/test_native_effect_edge_protocols.ps1` for
fixture arithmetic and synthetic instantaneous-jump, no-motion, and reversed
trajectory negatives. These synthetic checks are analyzer-protocol checks,
not Renoise playback evidence.

