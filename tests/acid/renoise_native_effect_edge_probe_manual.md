# Native 0G edge checks

Run `renoise_native_effect_edge_probe.lua` in a disposable song with the
`ACID ARTICULATION PROBE` instrument. The probe writes one-shot phrases at
LPB 16 with four lines per straight TIME step. The song transport profile is
120 BPM, LPB 8, and TPL 12 unless a case specifies another BPM.

| Phrase | BPM | Events | Host OFF |
| --- | --- | --- | --- |
| `ACID 0G08 RATE SWEEP` | 90, 150 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 2 | step 12 |
| `ACID 0G20 RATE SWEEP` | 90, 150 | NOTE 48 at step 0; NOTE 52 with `0G20` at step 2 | step 12 |
| `ACID 0G40 RATE SWEEP` | 90, 150 | NOTE 48 at step 0; NOTE 52 with `0G40` at step 2 | step 12 |
| `ACID 0G08 REST CANCEL` | 120 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 1; REST at step 2 | step 8 |
| `ACID 0G08 FRESH NOTE` | 120 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 1; NOTE 48 at step 6 | step 8 |
| `ACID 0G08 GATED FRESH NOTE` | 120 | NOTE 48 at step 0; NOTE 52 with `0G08` at step 1; OFF at step 5.5; NOTE 48 at step 6 | step 8 |

The phrase has four lines per TIME step. A phrase line lasts `3750 / BPM` ms;
the command-coverage estimate is `ceil(4 * 16 / 0G-amount)` lines. Use three
unchanged captures per phrase/tempo pair. Record phrase readback, tempo,
trigger, WAV hash, and render settings.

Analyze a capture with its case ID:

```powershell
./tests/acid/analyze_articulation_audio.ps1 `
  -CaseId native_0g20_bpm_90 `
  -OraclePath tests/acid/fixtures/native_effect_edge_cases.json `
  -WavPath tmp/acid-articulation/<capture>.wav `
  -OutputPath tmp/acid-articulation/<capture>.analysis.json
```

For the writer check, set `ACID_ARTICULATION_ORACLE_PATH`,
`ACID_ARTICULATION_CASE_ID="writer_0g20_rest_gated_fresh_note"`, and
`ACID_ARTICULATION_OUTPUT_POLICY="play_once"` in ACID's scripting context.
Run `renoise_articulation_writer.lua`, then capture and analyze three unchanged
renders using the same oracle file.

Current-layout Renoise playback checks have not been performed in this work
session. Synthetic analyzer checks do not establish playback behavior.
