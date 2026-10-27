# Articulation audio capture evidence

## Desktop grid calibration — 2026-10-27

**PASS** for `grid_calibration_all_note_pitch_span_16` through Renoise to Audacity WASAPI loopback. Windows system volume was left unchanged. This validates the authored timing/pitch markers on this route; it does not establish native glide continuity, runtime gate widths, accent behavior or hardware fidelity.

| Capture property | Observed value |
| --- | --- |
| Renoise | 3.5.4, desktop Demo loopback route |
| Audacity | 3.7.8 |
| Endpoint | `1 - PHL24E1N1100A (AMD High Definition Audio Device)`; Audacity Windows WASAPI loopback |
| Renoise configuration | WASAPI shared; saved buffer setting 35 ms; exclusive mode false |
| Export | 48000 Hz, signed PCM24, stereo; no normalization, effects or resampling applied |
| Tempo | 120 BPM, song/phrase LPB 8, TPL 12 |
| Profile | `acid-reference-168-frame-saw`; 168 frames at 44100 Hz, root 48, peak 0.35, sample volume 3.0, instrument volume 1.0, diagnostic volume envelope attached |
| Phrase | Program 1; 69 physical lines, loop [35, 69); OFF on even lines 2–68 |
| Host | NOTE 48 on line 1, OFF on line 137, 224-line pattern; transport stopped before retrigger |
| WAV | `tmp/acid-articulation/calibration_gated_fresh.wav`; 46.010 s including leading and trailing silence |
| Report | `tmp/acid-articulation/calibration_gated_fresh_report.json` |
| Sample read-back | `tmp/acid-articulation/reference_saw.txt`; one nine-decimal sample value per line |

| Measurement | Result |
| --- | --- |
| Onsets | 68 expected and detected; all matched after one alignment at 4345 ms |
| Pitch windows | 68 passed; largest absolute pitch error 0.08 cents |
| Half-step silence windows | 68 passed; loudest window -91.23 dBFS |
| Largest absolute onset error | 3 ms (limit 5 ms) |
| First-to-last drift | 0 ms across 67 intervals (8375 ms) |
| Peak | -50.68 dBFS; no clipping |
| Stereo difference | -61.23 dB relative RMS |

SHA-256:

- WAV: `febb4e74e677e0e07c85ecf53ca3d661653d1c4bd8ca4bd0b38e78c152edcbdd`
- Report: `0bf3f72b9447a1aa751cca0addc26c448bb433efa5ec1e397871ca7cc6fb1cca`
- Sample read-back: `d5204330fbbaa71b8464503fcdc19577d2bc16dde0dfcea4201c4a74aa473739`

Raw artifacts remain ignored local files. Previous ungated or silent captures are not calibration evidence. The diagnostic calibration uses half-step OFF markers independently of production gate scheduling. Endpoint enhancements/spatial-processing state was not independently audited during this run; recalibrate if route or profile settings change. Low captured level passed this marker test. The user subsequently authorized separately normalized analysis copies; their independent findings below supersede any inference of envelope/silence qualification from that low-level pass. Windows volume remains unchanged.

## Automated verification

The successor-aware gate implementation adds 21 planned/authored oracle cases
(seven source families at 90/120/150 BPM), bringing the oracle to 62 cases.
They separate one-shot midpoint tails and fresh successors from the existing
REST-ending cases and cover Repeat REST seams over one cold plus three steady
cycles. The [gate procedure](acid_gate_manual.md) records exact expected OFF
positions and the qualification sequence. These cases are not ready analyzer
protocols and do not change native support. No new native capture, GUI, ownership,
save/reopen, undo or Live Edit check was performed during this implementation.
Neither application was running; both are installed and ignored desktop-control
helpers exist, but the failed normalized control qualification remains unresolved.

- `./tests/acid/validate_audio_oracle.ps1`: 41 cases and all 68 explicit calibration events accepted. Seven malformed-fixture mutations rejected; successor-REST boundaries and seven repeat seam lengths checked.
- `./tests/acid/test_audio_analyzer.ps1`: five positive controls, 20 held-pitch onset controls, four diagnostic attack-signature controls, 13 seeded failures and four malformed WAV-header controls accepted. Seeded failures include pitch, drift, clipping, retrigger, continuity gap, early release (including 12 ms before OFF), instantaneous glide and delayed jumps at 20/35/50 ms.
- `./scripts/run_tests.ps1 -Tool ACID`: 19 Lua specs passed, including 90/120/150 BPM host durations, safe OFF relocation, named probe switching, strict-global handling, writer callback failures and native-variant cleanup.

Synthetic tests validate analyzer discrimination; native playback is established only by the recorded grid capture above. The onset refractory interval limits detection of arbitrarily close extra attacks.

## Remaining native acceptance measurements

Capture held NOTE/OFF, same-pitch retrigger and REST controls, followed by three unchanged captures of each 0G08/20/40 candidate using the [capture procedure](renoise_articulation_probe_manual.md). Record a supported native strategy/rate or an explicit failure before enabling glide integration. Calibration alone does not complete the articulation acceptance matrix.


## Fresh capture and authorized normalization — 2026-10-27

The same Renoise 3.5.4/Audacity 3.7.8 WASAPI endpoint was used at 120 BPM, LPB 8, TPL 12, 48000 Hz stereo PCM24. No source recording was overwritten or resampled. Grid host hold was 68 steps; independent held/retrigger/0G20 controls used 32 steps, OFF at line 65, 152 host lines (9.5 seconds). The updated double-stop/loop-reset start helper ran successfully at 120 BPM for the controls. The profile remained the original diagnostic instrument, not a newly rebuilt profile.

The fresh raw grid (`calibration_recheck.wav`) passed all 68 timing/pitch/silence windows with maximum onset error 3 ms and peak -50.68 dBFS. Raw held, retrigger and 0G20 analyses were **invalid**: stereo difference was about -57.6 dB versus the -60 dB threshold, and held sustain around -59 dBFS did not satisfy the frozen minimum. This does not prove native early release: the low-level onset floor delayed absolute alignment by about 15 ms.

The user explicitly authorized normalization. `normalize_articulation_audio.ps1` made PCM24 analysis copies using one calibration-derived gain of **+44.58268024352661 dB** (169.48607104586046 linear). Optional `-Mono` applied arithmetic L/R averaging, recorded in each receipt, after the source passed its -40 dB conversion guard. These are a separately qualified mono-copy path; they do not establish original stereo agreement. Calibration peak became -6.10018 dBFS. Originals and receipts remain under `tmp/acid-articulation/`.

| Normalized diagnostic | Recorded result before signature qualification | Interpretation |
| --- | --- | --- |
| Grid | 68 correct onsets, zero onset error, 68 pitches within 0.05 cents; **68 failed silence windows** | Gain revealed release tails hidden by the earlier absolute floor/alignment. First OFF is nominally 5072.5 ms; sound remains around -31 dBFS at 5080 ms and approaches silence by 5090 ms. Authored silence starts 5077.5 ms. The normalized route/profile is not calibrated for acceptance. |
| Held NOTE/OFF | Numeric pass; observed OFF-to-silence about 10 ms | One control observation, not three-run qualification or a verified 5 ms envelope. |
| Same-pitch retrigger | Fail: second onset 6 ms later than expected (5 ms limit); release about 10 ms | Detector/native signature qualification remains necessary. |
| Local 0G20 + following G00, 48→55 | Fail: settled pitch about 330.73 Hz, note 52, roughly 300 cents below target 55; directional movement and local continuity metrics passed | This provisional local strategy/rate does not meet the authored target. No native strategy or runtime support is selected. |

These are exploratory single takes with failed calibration, not valid acoustic acceptance. Do not fix them by widening only candidate windows. Audit realized envelope/release and detector qualification, rerun synthetic controls, then recalibrate and repeat unchanged A/B captures three times. Rates 08/40, Mono/Glide, REST, 90/150 BPM and complete writer captures remain separate checks.

The generic application scripting terminal does not expose `renoise.tool()`. A writer-helper attempt recorded a real generation failure before audio capture. The helper now refuses that context before side effects and handles synchronous callback failure safely. Writer generation/readback in a real tool context remains unverified; no installable runtime code changed.

Artifact hashes (paths relative to `tmp/acid-articulation/`):

- `calibration_recheck.wav`: `49408862a8e092100ddbc376e39a69cf0b7882891b0a8f83580577bf8bb024c4`
- `calibration_recheck_report.json`: `13c5d245297fb8b2ac9682746a6b7101159d792236eb4ac3a9085d468d14f8cf`
- `held_native_1.wav`: `c8f6f317f4c0babae1b8cbf5c93bf363412521be814a97df7fb1ada6f7d6a6f8`
- `held_native_1_report.json`: `9d5c7cca7bd59f5b7e25644d786979a2f63e683dde658b382aa8c4a690b0f2d0`
- `retrigger_native_1.wav`: `31055bfbb505bb098d58a3ebd2c4991e30f678e46d5b2f8ebad34f9072a0f208`
- `retrigger_native_1_report.json`: `cd0deb0ffa8c284d90df13bf501065f24978bb3362b0e0410b11a7f47296bb56`
- `glide20_native_1.wav`: `ed2b5199ea248e733322e2c41172ba830d56e69b534e6bc9de3a01dd37491168`
- `glide20_native_1_report.json`: `ed255c23c065d80ede921f31135d926f52da43aaed1913a7d13b17e77e9b45c4`
- `calibration_normalized.wav`: `2ccd8450f7079d75219f426c871a4ea3263bf5fc5150338ed8b5f2c430d7e389`
- `calibration_normalized.wav.normalization.json`: `389b497864702bc91075c0301ebe6f1f5682baddee9e13281a48deec5923e695`
- `calibration_normalized_report.json`: `b9d94fbb367b8357104a46a3967bb9ba139affe9df6be1fc167eee32bd78802d`
- `held_native_1_normalized.wav`: `af73f1d06f8773913432eaec259b946b0bc3ac0a4d1b764421d6c0a80866b092`
- `held_native_1_normalized.wav.normalization.json`: `c8f72cfe8a928f152df30cd7e8492d7aed824e1bea1a1f6eb483bba78f4179ca`
- `held_normalized_audit_report.json`: `a695dbb55758692e4d33dff6c9a49c824ffc036ae766e9448d3bd29b44c3b1c6`
- `retrigger_native_1_normalized.wav`: `ca2655b5fdd32d4f949b0a6b16c710e2eea62da01a50357c0c3f3aca292dd0f7`
- `retrigger_native_1_normalized.wav.normalization.json`: `7612f6a076c01d30e92a7e81f0b76e14ed9dbbab13af0221a03de94b0d2207a0`
- `retrigger_normalized_audit_report.json`: `0c8b914e1bd9e76d91771c6c70e670cb13fddcfbe2c6b64e4a18d6500efedb48`
- `glide20_native_1_normalized.wav`: `79074098cc6c3ed2dbbd555b2a765cbb31bd2c7e912bea108af501bc8f4c5eb9`
- `glide20_native_1_normalized.wav.normalization.json`: `286f7a189fcedbfbbe989032d86435898ea9ebc19419cbd89b41bb5952ced019`
- `glide20_normalized_audit_report.json`: `939c7dd637f0fa7340c4c7cb4d2ef90d1fa6f90fb706428f5263966ab3d9ae1a`

Native helper checks: the separate Mono/Glide builder and standalone readback ran successfully, with native glide 32 and the same six envelope points; rerunning the builder correctly refused the duplicate. Readback showed `fade_amount=23.936000823975`, `tempo_synced=true`, sustain position 31. The pinned API documents the fade range but no timing conversion. Mono/Glide audio acceptance remains unverified. Optional-global accesses were corrected to work with Renoise's strict-global terminal.
