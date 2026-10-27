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

Raw artifacts remain ignored local files. Previous ungated or silent captures are not calibration evidence. The diagnostic calibration uses half-step OFF markers independently of production gate scheduling. Endpoint enhancements/spatial-processing state was not independently audited during this run; recalibrate if route or profile settings change. Low captured level passed this marker test and must not be compensated by changing Windows volume or normalizing captures.

## Automated verification

- `./tests/acid/validate_audio_oracle.ps1`: seven cases and all 68 explicit calibration events accepted. Corrupted steady-cycle pitch and premature silence marker rejected.
- `./tests/acid/test_audio_analyzer.ps1`: four positive controls, 20 held-pitch onset controls and 11 seeded failures accepted. Seeded failures include pitch, drift, clipping, retrigger, continuity gap, early release (including 12 ms before OFF), instantaneous glide and delayed jumps at 20/35/50 ms.
- `./scripts/run_tests.ps1 -Tool ACID`: 17 Lua specs passed, including configurable host durations, safe OFF relocation and capacity/tail rejection.

Synthetic tests validate analyzer discrimination; native playback is established only by the recorded grid capture above. The onset refractory interval limits detection of arbitrarily close extra attacks.

## Remaining native measurements

Capture held NOTE/OFF, same-pitch retrigger and REST controls, followed by three unchanged captures of each 0G08/20/40 candidate using the [capture procedure](renoise_articulation_probe_manual.md). Record a supported native strategy/rate or an explicit failure before enabling glide integration. Calibration alone does not complete the articulation acceptance matrix.
