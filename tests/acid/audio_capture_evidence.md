# Articulation audio capture evidence

## Current evidence status — 2026-10-28

The current desktop has licensed Renoise 3.5.4 and uses offline WAV rendering;
it has a different soundcard from the earlier Audacity WASAPI loopback setup.
Renoise 3.5.4 offline renders pass all 21 authored gate protocols across
90/120/150 BPM, tested moving/same-pitch Repeat glide classes, flat NOTE/TIE
accent response and native/writer effect-edge cases. The packaged-tool GUI
Generate/Live Edit/save-reopen case is also recorded below. Identical offline
exports are deterministic render repetitions, not independent soundcard
captures. No current-desktop WASAPI loopback calibration is claimed. Mapped
NOTE accents retain their level across TIEs; accent changes on connected slide
chains remain explicitly refused. Manual transport stop/start, seek and Live
Edit during playback are still unverified, so M3 is not complete. Earlier entries retain
the dated findings from the prior Demo/loopback setup; later sections identify
which conclusions they supersede.

## Current-desktop route probe — 2026-10-28

The RME route was checked after the previous PHL24 endpoint was found to be
unavailable on this desktop. This is route evidence only; no current-desktop
grid calibration or articulation result is claimed.

| Probe | Result | Raw WAV |
| --- | --- | --- |
| Renoise ASIO Hammerfall DSP → Audacity RME WASAPI loopback | **Invalid for playback analysis:** 16.23 s, stereo PCM24 at 48 kHz, peak integer sample 10 (about −118.5 dBFS), effectively silent | `tmp/acid-m4-acceptance/rme-loopback-route-probe-20261028.wav`; SHA-256 `CE9331D5BFD3427CDF904E289124DC99BDDD1E724302F766F398C6366235A0D5` |
| Renoise shared WASAPI Analog 1+2 → Audacity RME WASAPI loopback | **Route-only pass:** one host NOTE/OFF probe was audible; 6.26 s, stereo PCM24 at 48 kHz, peak −6.81 dBFS, RMS −22.83 dBFS | `tmp/acid-m4-acceptance/rme-wasapi-route-probe-20261028.wav`; SHA-256 `317F66E3D6709335C2C7061419CC71C2D93E44A1AA5840D0BD8BD57795901D85` |

The shared-WASAPI setting was temporary. Renoise was restored to ASIO
Hammerfall DSP at 48 kHz, 256 samples (5.3 ms), with dithering enabled. The
route probe does not replace the required 68-event calibration. A follow-up
grid take reached the 14-second host-pattern wrap and retriggered, so it was
invalid for calibration and was not analyzed or exported. No valid current-
desktop timing/articulation capture is retained; acceptance remains **Not Run**.

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

- `./tests/acid/validate_audio_oracle.ps1`: 62 cases and all 68 explicit calibration events accepted. Eight malformed-fixture mutations rejected; successor-REST boundaries and seven repeat seam lengths checked.
- `./tests/acid/test_audio_analyzer.ps1`: five positive controls, 20 held-pitch onset controls, scale-invariant attack/retrigger timing, four diagnostic attack-signature controls, 13 seeded failures and four malformed WAV-header controls accepted. Seeded failures include pitch, drift, clipping, retrigger, continuity gap, early release (including 12 ms before OFF), instantaneous glide and delayed jumps at 20/35/50 ms.
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
| Grid | 68 onsets within 3 ms; 68 pitches within 0.08 cents; **67/68 silence windows still fail** after corrected alignment and timing | The first analysis began at +5 ms, before the declared 10 ms deadline. Corrected +10 ms windows report -90.55 to -46.13 dBFS, above the -60 dBFS limit in 67 windows. This remains a failed profile calibration; it does not test the new gate writer. |
| Held NOTE/OFF | Corrected report origin 4805 ms, matching the raw report; threshold crossing at 5425 ms vs expected OFF at 5430 ms | The old normalized result's +10 ms tail came from an onset origin 15 ms early. The corrected single capture does not establish a 5 ms envelope or a valid release result; minimum pre-OFF sustain also misses its threshold. |
| Same-pitch retrigger | Corrected normalized-copy onsets at 4705 and 4955 ms; 250 ms interval and zero onset error | The old +6 ms result disappears when the onset floor is shifted by the receipt's +44.58268 dB gain. The original stereo capture still misses the -60 dB channel-difference limit, and sustain/release controls remain unqualified. |
| Local 0G20 + following G00, 48→55 | Fail: settled pitch about 330.73 Hz, note 52, roughly 300 cents below target 55; directional movement and local continuity metrics passed | This provisional local strategy/rate does not meet the authored target. No native strategy or runtime support is selected. |

## Follow-up timing and profile audit — 2026-10-27

The oracle now starts each calibration silence window at the half-step OFF plus the nominal 5 ms release and a 5 ms tolerance (`0.58` step at 120 BPM). The prior `0.54` start measured only 5 ms after OFF. Analyzer reports now add the normalization receipt gain to the source-relative -60 dBFS onset floor and record both values; the absolute silence threshold stays at -60 dBFS in the analysis copy. Synthetic scaled-attack/retrigger controls confirm this floor compensation preserves detected event times.

On the retained retrigger waveform, the compensated floor reports 4705/4955 ms instead of 4705/4956 ms, restoring the authored 250 ms spacing. On the held control, compensation moves alignment from 4790 to 4805 ms and changes the inferred release tail from +10 ms to -5 ms. That shows the prior 10 ms result was alignment-sensitive; neither result qualifies the realized envelope. The normalized calibration grid still fails 67 silence windows at the corrected deadline. The current Renoise 3.5.4 volume-envelope parameter exposes a runtime maximum of 765.765 although the API definition lists 0–4095. The probe builder now reads that parameter maximum for its shortest-release trial. A fresh rebuilt profile and capture are required to determine whether its realized release meets the oracle.

These remain exploratory independent controls, not captures of the new gate writer and not three-run acoustic acceptance. Keep writer glide refused. Rebuild and measure the reference profile, recalibrate, then capture the actual writer cases three times. Rates 08/40, Mono/Glide, REST, 90/150 BPM, and accent cases remain separate checks.

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

## Capture input-level check — 2026-10-27

The Renoise track meter showed about **-5.6 dBFS peak** and **-10.4 dBFS RMS** while the raw WASAPI calibration WAV peaked at **-50.68 dBFS**. Audacity's **Recording Level** control was at **5%**. This was a capture-path level mismatch; the signal at Renoise was already at a normal digital level.

Audacity's Recording Level was moved to **97%** and its tooltip was checked. Its separate **Playback Level** remained at 76%, Renoise's track meter remained near -5.6 dBFS peak, and Windows system playback volume was not changed. On this same Renoise 3.5.4/Audacity 3.7.8 WASAPI loopback route, the exploratory held-probe WAV then measured **-6.25 dBFS peak** and **-81 dB stereo difference**, about 44.4 dB higher than the low-level calibration. This is near the -6.1 dBFS analysis reference and below clipping. This makes 97% a measured setting for this endpoint and route only; another endpoint or driver needs a fresh level and calibration check. The repeatable setup is documented in the [capture manual](renoise_articulation_probe_manual.md).

The trial is **invalid as an acceptance capture**, despite its normal signal level. It ran for 54.9 seconds and detected the expected first onset at 16070 ms plus three unexpected repeats at 27570, 39070 and 50570 ms. The held-case release crossing was 9 ms after OFF and its pre-OFF sustain minimum was -15.47 dBFS, but the attack-signature check was inconclusive. Those measurements are exploratory only: extra phrase events contaminate the control, and the profile read-back/fade amount was not attached to this report. The next capture must stop after its expected OFF and required tail, before the helper's printed sequence wrap, and any extra onset rejects the run.

| Artifact | Result |
| --- | --- |
| `tmp/acid-articulation/record_level_97_probe.wav` | 48 kHz stereo PCM24; 54.9 s; peak -6.25 dBFS; stereo difference -81 dB; three unexpected onsets |
| `tmp/acid-articulation/record_level_97_probe_report.json` | `fail`; not acceptance evidence |
| WAV SHA-256 | `75ab0dcd2c17aae84a8ac3a6f378955dfc666152f71ef3f62687268f44fa420c` |
| Report SHA-256 | `2a6b799b7decc1f2dd3f26c1c1f2ca2b07f99614bf2e3e1bc884445536418561` |

The recording-level change solved the **raw capture amplitude** problem on this route. It did not resolve the nominal release measurement, attack-detector qualification, retrigger timing, or actual ACID writer acceptance. Rebuild/read back the profile, capture a clean calibration and native controls at the same level, then take the required three unchanged writer captures. Windows system volume remains unchanged.

## Fresh song and wall-clock profile correction — 2026-10-27

A fresh blank Renoise 3.5.4 song and Audacity 3.7.8 were used at 120 BPM / LPB 8 / TPL 12, on the retained WASAPI loopback route. Exports below are untouched 48000 Hz stereo PCM24; no normalization or Windows system-volume change was applied. The user's envelope-free sample is a flat control; the disposable diagnostic probe is separate.

The rebuilt probe exposed a concrete profile bug: `tempo_synced=true` produced an approximately 20 ms attack and 60 ms sustain boundary from points 11 and 31. Toggling it to `false` automatically converted these points to 21 and 60, preserving the sound. Assigning the original points **after** selecting `false` produced a matching attack signature (early/peak 0.384, sustain/peak 0.746) and a 6 ms release threshold crossing. This observed Renoise 3.5.4 polarity contradicts the API 6.2 property's prose. The builder now sets `false` before authoring its points. See `wallclock_readback.bmp`; the unchanged six points, active device, attached set and maximum fade 765.765 were read back. The earlier `unsynced_held.wav` toggled the mode without reauthoring points and therefore retained the slow shape; it is not corrected-profile acceptance.

Fresh corrected-profile results:

- `wallclock_calibration`: **pass**, all 68 onset/pitch/silence windows; peak -6.24 dBFS, stereo difference -81.45 dB.
- `wallclock_held`: analyzer **pass**, one onset, matching attack signature, +6 ms release, peak -6.29 dBFS. This capture preceded the corrected-profile calibration; repeat it after calibration for the complete acceptance sequence.
- `wallclock_rest`: **pass**, two onsets with zero timing error and the authored silence window. One capture only.
- `wallclock_retrigger`: formal **fail**, second onset not detected. The detector remains unqualified for a short attack over an outgoing voice; do not infer a scheduler defect or accept retrigger timing from this report.
- `wallclock_glide08`: formal **fail**, settled near note 49. The authored commands apply only two lines of movement.

The glide probe also mislabeled its following `G00` as a stop. The [official effect reference](https://tutorials.renoise.com/wiki/Effect_Commands) states that zero repeats the last rate. The helper now calls this continuation. At 08/20/40, two commanded lines move by approximately 1/4/8 semitones respectively, clamped to the target. Thus the retained 20 result near note 52 is consistent with the authored two-line movement from 48; it does not establish that native glide cannot reach 55. A qualified 40 capture, or enough continuation lines at a slower rate, is still required. No runtime glide support is enabled.

Some desktop attempts were invalid: silent exports did not execute a start command; `wallclock_glide20.wav` has no audio frames. Neither is acoustic evidence. Renoise and Audacity had exited before the 40 trial; no 40 result or actual writer capture is claimed. All raw/scratch artifacts remain ignored under `tmp/acid-articulation/`.

| Artifact (relative to `tmp/acid-articulation/`) | Formal result | WAV SHA-256 |
| --- | --- | --- |
| `wallclock_calibration.wav` | pass | 3affd17bcd897ec799258114b2e890fe4a5a6249a7d2292489c47324a1891b20 |
| `wallclock_held.wav` | pass | e03ed8ea4b6b8f28d05fae3b3c8ddacd3a2a8f3cc63a1d417daac913fd368ee6 |
| `wallclock_retrigger.wav` | fail | 28d031cf922803c24c446d0f3cced10ebefc7f7e12d8663a509c24625484a486 |
| `wallclock_rest.wav` | pass | 9718aac7ff70bbb967a95d733d5f28905215ff715c84236cf828505074199579 |
| `wallclock_glide08.wav` | fail | c162fe74d590f1bee8fbbfcc5155124d01415a4e0d94c5a1198b7591cabaafa0 |

Verification: all 21 ACID Lua specs passed after the profile fix; oracle validation, eight rejected oracle mutations, and analyzer synthetic acceptance (five positive controls, 20 held pitches, 13 seeded failures) passed. Full M3, repeated native controls, actual writer output, accent and lifecycle checks remain open.


Report and reference sample hashes:

- `wallclock_calibration_report.json`: `88ff55d2c56e990acbd03291b765a1d589537b136fd501aa4bc18a95837293fe`
- `wallclock_held_report.json`: `f0925747fb94824b80dee268d6f0aae4d5f0bd1f56b890d2e7159bf00afbcec1`
- `wallclock_retrigger_report.json`: `34e9f3ccdc7dcc9340f01e819e7cea5e4b289864a7306eef0960817e342ad9f8`
- `wallclock_rest_report.json`: `4f976b023d4e311759b6a417140a1a2bddfffe871287467f66a36b41c9d1165a`
- `wallclock_glide08_report.json`: `d1644e58be46df5ec96c8e9b9c5412be7ff03634b133787dd7776b2152eede57`
- `reference_saw.txt`: `d5204330fbbaa71b8464503fcdc19577d2bc16dde0dfcea4201c4a74aa473739`

## Runtime implementation and controlled native checks — 2026-10-27

The glide planner now derives required command coverage from interval and fixed rate 20, emits continuation through held TIEs, and refuses insufficient spans. Shared operation planning rejects release collisions. No Repeat support refusal was relaxed. Native `implementation_glide40.wav` passes the existing independent 40 protocol: one attack, target note55 within tolerance, continuity/no-extra-attack checks pass. This is one native capture at120BPM, not repeated writer or Repeat acceptance.

Native pattrns readback in `native_volume_conversion.txt` established 0.7->89, 1.0->255 (empty/full), 0.5->64 and 0->0. The actual writer now validates independently derived values before and after articulation, rather than snapshotting rendered volumes. Transaction tests reject wrong normal/accent cells without replacing source or destination. `writer_alternating_accents_*.txt` records successful actual native output.

Three flat writer accent captures with mapping disabled measured approximately0dB accent gain. Changing only the disposable sample's `map_velocity_to_volume` to true produced 3.0884dB in each of three unchanged captures, versus3.1564dB predicted from89/128 (error approximately-0.068dB; pair spread0.000036dB). Reports `accent_flat_exploratory.json` and `accent_velocity_exploratory.json` preserve per-take hashes and windows. These are controlled exploratory comparisons; separate flat-profile recalibration, consecutive/connected accent and full acceptance remain required. `renoise_articulation_accent_control.lua` configures this separate disposable profile. Standard flat and diagnostic helpers restore mappingfalse. Runtime generation never changes mapping or envelopes.

The onset detector's trough threshold now detects the reference retrigger while retaining recovery discrimination. Retained reference held, REST, calibration and retrigger reanalyses pass; retrigger interval254ms is4ms above nominal. Four-pitch/two-gain reset positives and continuous-glide negatives pass. This does not qualify arbitrary envelopes.

A read-only reference checker validates waveform frames, sample/mapping/routing, trigger/tuning and attached diagnostic settings; the live reference_accent setup passes. It is not yet wired to enable playback support. Analyzer now iterates authored release_edges, but dedicated multi-edge seeded tests and writer protocol promotion remain pending. All writer cases remain planned. Latest Lua suite:22 specs pass; analyzer synthetic suite and oracle mutation suite pass. Package contains19 runtime files including the private checker. Full M3 remains open.

## Repeated actual gate-writer captures — 2026-10-27

The analyzer now measures every authored `release_edges` entry. Independent two-edge signals prove that early/late first and second releases cannot be hidden by another passing edge; missing attacks are rejected. The executable `one_shot_note_tail_bpm_120` protocol also passes a synthetic correct signal and rejects independently early/late tails. Only this protocol and `isolated_note` were promoted; all other writer protocols remain planned, and protocol readiness never grants runtime support.

Actual unmodified `retrigger` writer output was generated through a disposable tool callback (not the generic application terminal). Generated cell metadata records the selected phrase, ownership seal, native volumes and OFF locations. With the diagnostic reference restored, each family below was captured three times unchanged at120BPM,48kHz stereo PCM24 after the passing implementation calibration. REST release occurs at step1 for isolated_note; the final NOTE releases at step0.5 for one_shot_note_tail_bpm_120. All six retained runs pass pitch, onset, silence and release checks. Raw WAVs were not normalized or cropped.

| Artifact under `tmp/acid-articulation/` | Result | Release tail ms | WAV SHA-256 |
| --- | --- | --- | --- |
| `writer_isolated_acceptance_1.wav` | pass | 6 | `3de54365caf0efcedb36d107ae9888e37586c22820e7c3fc8100b290d457315b` |
| `writer_isolated_acceptance_2.wav` | pass | 6 | `e50a181830143bb6fabc566b46b48d0fc70c36cc395f4ee3fdd79180f43bfb95` |
| `writer_isolated_acceptance_3.wav` | pass | 6 | `aed7296b9cc4203a456dd19fba74e78689e385879e27a4e2e29670b93088ae09` |
| `writer_tail_acceptance_4.wav` | pass | 6 | `2ece8f32d5029b1961a0899b674f70374fcb0464003692fd07d3af1710708738` |
| `writer_tail_acceptance_5.wav` | pass | 6 | `54d8acb36534a3383f49c75de3110675cd7ff1aaddb4bcf675d319fddd0e5455` |
| `writer_tail_acceptance_6.wav` | pass | 6 | `3c4b40575d62c6ec5a1fbf1d3435f1e2f0fb124b822a042f7c23a343aed0151a` |

`writer_tail_acceptance_1.wav` contains an extra onset and remains invalid for acceptance; it was not trimmed. Runs4–6 are the fresh unchanged three-run set. Tied tails, Repeat/tempo matrices, connected glide/accent and lifecycle verification remain open.

## Tied tails and profile-qualified Repeat gate path — 2026-10-27

The nine independently authored NOTE/TIE/TIE-TIE one-shot tail protocols at90/120/150BPM now have executable synthetic positives and25ms early/late negatives. Native acoustic acceptance is separate: at120BPM all three one-TIE writer captures pass; two of three two-TIE captures pass and take2 exceeds the peak ceiling(-5.50dBFS), so the two-TIE three-run acoustic gate is still open.

The runtime Repeat retrigger path now checks the exact diagnostic reference profile read-only, selective triggering,120BPM,LPB8,TPL12 and groove disabled. It retains refusals for other profiles/tempos/modes and every Repeat slide. The same profile is checked again before committing the asynchronous render. Integration tests prove mismatched profiles and unsupported tempos refuse before mutation, and a profile changing during rendering cancels the temporary phrase without changing persisted source or destination. Generic instruments are never changed to meet the profile.

Three actual unchanged Repeat NOTE/REST writer captures pass at120BPM: four attacks across cold plus three steady cycles, four matching pitch windows, four silence windows, and all four release edges. Hold was eight TIME steps with host OFF after the fourth pass; capture stopped before sequence wrap. Generated phrase retains the exclusive-end sentinel. This is one Repeat family, not full Repeat acceptance or a glide/accent claim.

| Artifact under `tmp/acid-articulation/` | Formal result | WAV SHA-256 |
| --- | --- | --- |
| `writer_tie_tail_1.wav` | pass | `cafa29da024fa5bfe48c5d24b9f3af615f7305d94cc1b8d85bd54cda9e94336b` |
| `writer_tie_tail_2.wav` | pass | `c5e8cea263b6592fb18b66284d506032f865035d371a004d020648c3bb9e6438` |
| `writer_tie_tail_3.wav` | pass | `32bb312aa58bd55b7285414058712e26b433d69f36f45ede5ef599707389bf56` |
| `writer_two_ties_tail_1.wav` | pass | `aebe57d507b1ba89234e679a40da3785ba8947f0c0adbeb318d634fcbc04d385` |
| `writer_two_ties_tail_2.wav` | invalid | `3cb19373fc6e2d1cad5c9803773aaeebab9e2af25fc9b2ca186c39e823349d4e` |
| `writer_two_ties_tail_3.wav` | pass | `34cc556b029e4eb6d00d7aa3ddb1b15677381c72ae6f3d4ce879380bf9232d63` |
| `writer_repeat_rest_1.wav` | pass | `27339e4aaf5c8d00468e4ce559bc7edf54cb4e6691217e1968213616f40242d1` |
| `writer_repeat_rest_2.wav` | pass | `c82b431d2097e3483c22fc5481db2c80dae721674e5e7a42b427ad3e6741abd4` |
| `writer_repeat_rest_3.wav` | pass | `f68bc8b509d3fa5fda0347ccb8e9bcd51a4123b4ab7ad8837cf312b889ccea80` |

## Single-instance glide and same-pitch Repeat checks — 2026-10-27

An earlier hidden disposable Renoise process remained alive alongside the visible capture instance. It was stopped; exactly one instance was confirmed before the fresh calibration below. This is a plausible cause of intermittent mixed/extra-onset takes, not proof of the cause of every earlier invalid recording. Historical invalid files remain invalid and were not trimmed. The single-instance route passes all68 calibration onset/pitch/silence windows at48kHz stereo PCM24.

Three fresh actual fixed20 four-semitone one-shot writer captures (`writer_connected_four_4`–`6`) pass target52, continuity, no extra attack and release. The authored source is NOTE/TIE/NOTE/TIE/REST with outgoing SLIDE on pitch48 into52. An independent protocol and synthetic pitch/retrigger failures cover this source. Earlier take2 exceeds the peak ceiling and remains invalid.

Three actual 16-step same-pitch Repeat writer captures pass one cold attack, stable pitch across four passes, no new attack at cold-to-steady or either steady seam, continuity at all three seams, and final host release. The source has one NOTE and fifteen TIEs with outgoing SLIDE. The dedicated host holds64TIME steps and releases after cold plus three steady cycles. Connected Repeat must not have a scheduler midpoint OFF; its oracle was corrected to measure host OFF at4*source length, with origin explicitly recorded. Other lengths remain planned. Synthetic continuity-gap rejection passes.

Runtime eligibility admits same-pitch Repeat slide only in slide mode on the exact diagnostic reference at120BPM/selective/LPB8/TPL12/no groove. Moving Repeat slides remain refused. Profile/transport eligibility is checked again before commit; tests cover matching-path generation, changed/mismatched profiles, unsupported tempos, moving-slide refusal and sentinel preservation. A separate connected-accent diagnostic profile can be recognized read-only but is not enabled by these results.

| Artifact stem under `tmp/acid-articulation/` | Result | WAV SHA-256 | Report SHA-256 |
| --- | --- | --- | --- |
| `single_instance_calibration` | pass | `d37f1e9786ca0d155548329e7c49d0e953f29c954f6a22b308e6914a9a27a8ca` | `16e708360af6bc6e0c68052cda930989fa358b120c9f0e29bec7d45c0ec44525` |
| `writer_connected_four_4` | pass | `27c8a05410d73acd6e8a55c4e10a6833ffa012d2dce1d87e30522ae3c3666bb5` | `557cf48e3de316fd385012c892357808de5cd9a3111eb09cd5b576ecdc1c2de3` |
| `writer_connected_four_5` | pass | `b237e60401de3ad21de1c2424532422d0c2879c753523a81dac3d314c226a13a` | `695df2d810fb5c8d38bd8d51e99d9cb81c6647ad1578f02b2c01594f9d47a03f` |
| `writer_connected_four_6` | pass | `7a2589e0919505a9668738aae4de9fb325417e97b26cbd7fb6ca33d63269df5c` | `73d611ac6a879bccc02917f6ab5cf275aef2c1bb4ab7ba4f3687e6b4d3593e1c` |
| `writer_repeat_same_1` | pass | `8b29db4e0d51410f90ba4eb12f7a2c299eac72e89d86d9d05198bfa57883b8dc` | `bc94ef8e0daee381e91acf83bae48fd4fec6c0209937ad8faf151ff856814518` |
| `writer_repeat_same_2` | pass | `de052dea043c2e72486e7bdce7e1c168550cf98c2ec8b0ac6fec5bbfa18dd54a` | `4af67fa8d4e85807d4d9390193558bc89de7476e1e807d2535b5f6e13a8ed487` |
| `writer_repeat_same_3` | pass | `98bf90a954a9d04ebe6863b405f5ca6da0f2fb7cc32e79c9f7829211d7f200b5` | `f1edba6b0b6f4323f08e16721c4cdcecb86933954e3b9aefb55e6512d5f9d219` |

Stopped at user request after this capture set. Full M3 remains open: broader Repeat moving glide, connected/consecutive accent, remaining lengths/tempo/profile cases and normal Generate/Live Edit/ownership/save-reopen lifecycle verification are not claimed complete.

## Fresh desktop Renoise offline renders — 2026-10-27

The fresh licensed desktop ran Renoise 3.5.4. Audacity 3.7.4 was used to import and inspect the calibration waveform. The WAVs in this section came from Renoise's offline `Song:render` API at 48 kHz stereo PCM24 with precise interpolation; Audacity was not used for loopback recording, and no listening or hardware-route result is claimed. The master pre-fader setting was 0.94 for the documented render set.

The first calibration render began at the trigger and failed the first-onset alignment. Including two seconds of silent pre-roll fixed the file-boundary alignment. The retained fixed calibration passes all 68 expected events, with no missing or extra onset; its measured peak is -6.36 dBFS and the stereo difference is -300 dB. WAV SHA-256: `70d1dd07a28bb2277888b418a5c1b1b03b48475123e28cfb65cde92a335c562f`; analyzer report SHA-256: `e54532aee1bf3d817c57830a1b1090763ca259225054fa86689de73382982a4a`. The portable artifacts are `tmp/acid-articulation/session/offline_calibration_fixed.wav` and `tmp/acid-articulation/session/offline_calibration_fixed_report.json`.

Native control and actual-writer analyses are summarized in `tmp/acid-articulation/session/native_control_analysis_summary.json` (SHA-256 `dcbd77b6d24d948f3f03029ef97bf0960266c07de626aabf5c25e954f2a6eb72`) and `writer_analysis_summary.json` (SHA-256 `aa2071102c7efed6f65aaa5aa9b1293991073c240efebd1a13d6eae26f68bc68`). Each row below represents three completed offline renders and analyses with one unique WAV hash. The byte-identical outputs establish deterministic render repeatability; they are not independent soundcard captures.

| Rendered protocol | Analysis result | WAV SHA-256 |
| --- | --- | --- |
| Native held-note control | pass | `7aed5cd04c9a48892ae3a604a339d6c242672e528acaa8332cae3499abd8520a` |
| Native same-pitch retrigger control | pass | `9b262c7c9d64a70c208772d036ac6a56e51d24fec610444ab12c4ffba26c2655` |
| Native REST-release control | pass | `44fec9f6a58571a36e450fdfe0976633422bc0adf5dd48d9c5c6c195f694a77b` |
| Native 0G08 control | fail: insufficient glide and target settling | `eadd7fde3b48d6674e831d80243a6022edba2313ab0be0b539248282a95f6bed` |
| Native 0G20 control | fail: target settling | `724eddd19f9e53316b07a0cb5decbe16f023d35c51adac892398dc3ad4fae44b` |
| Native 0G40 control | pass for its authored one-shot control | `ecc6073dafc7a36ac61d270c378ed34a0776b38785983f4f32d23adcdac7ab08` |
| Writer isolated NOTE | pass | `86534ea07c7207184ad9faab01d09c79114e1d9555da773fde0aaf58e461039f` |
| Writer one-shot four-semitone slide | pass | `546de3e11e9d38838b5f756d8b77134a5b6125219abb5175030212bd56f19c7f` |
| Writer one-shot NOTE tail | pass | `637054e80f36d2b545e5163537d3666309ece7f1e98c168beb86cf7aaafa492e` |
| Writer one-TIE tail | pass | `0b4d3a566c3722dc16b701d8c704b874f595fdd2863aefe260aae5dee68d8cca` |
| Writer two-TIE tail | pass in this deterministic export set | `bdf4ea324562bffa2e91c4d0b92f7f016ea91c3b30d70ff9a569ce93990619bf` |
| Writer Repeat NOTE/REST seam | pass | `e64012b1eda4cc24fc88815f8310aa7f0756382b96ff3096db5ca0592e8dd9de` |
| Writer 16-step same-pitch Repeat slide | pass | `911dad2c04bd5353375ff2dc2b7eeeaae5c576f47b1886ae89b5c2d13cd0b0ae` |

The offline two-TIE result does not replace the earlier actual capture set, which still contains one invalid high-peak take and remains open for acceptance.

The separate moving Repeat probe's four-semitone case (`native_repeat_glide_four_semitones_1.wav` through `_3.wav`) passed three analyses of the same WAV bytes (SHA-256 `292eeaccd5e3b305364ec6aac7d7ad11f9921c8cbf2b416e5fcb53473689de37`); the octave case (`native_repeat_glide_octave_1.wav` through `_3.wav`) failed pitch and trajectory windows in three analyses of its same WAV (SHA-256 `42e17cb391986c6f2c8d8f6f6da057ea56ef62437f6abef57877300fd4712961`). The files and `moving_repeat_glide_summary.json` are under `tmp/acid-articulation/session/`; summary SHA-256: `0077bd628e858357a1138e761ad639887699366a335800ffecd39831626b424f`. These are native instrument probes, not ACID writer evidence. Moving Repeat writer support remains refused. Accent renders are present, but their formal response analysis is still pending; no accent support claim follows from these exports.

Tempo qualification remains open. The first two 90 BPM calibration exports carry 90 BPM in their render metadata, but each WAV is 14.625 seconds long, equal to 234 pattern lines at 120 BPM; the selected section should take 19.5 seconds at 90 BPM. They are invalid for 90 BPM, and their sidecars do not prove the engine rendered at the requested tempo. The third calibration passed at 90 BPM after tempo was changed in a separate command and allowed to settle. The render helper now compares actual WAV frame duration with the selected section and captured transport; future tempo evidence requires `duration_check=passed`. The 90/150 BPM control and writer matrices remain open, with no change to the current eligibility boundary.

The Renoise lifecycle helper completed both requested modes. `tmp/acid-articulation/lifecycle_retrigger_1793116392.txt` reports Generate, Live Edit regeneration, ownership seal, and XRNS save/reopen as PASS; its record SHA-256 is `b6c1d467471d9e16b72c579b5389bc195a3a8ed7889775116ed0a3f5e51a8ba1` and paired XRNS SHA-256 is `89bd315a32b07d885be85afa6ef4bae436fd38db45b0730eb4fec24907dd6fca`. `lifecycle_slide_1793116418.txt` also reports PASS; record SHA-256 is `08cd76ed1809147e7de511c5a1d129a6588cb4dd7bada80b24c36bcc851bea959` and paired XRNS SHA-256 is `e0921047516eddbff75a43e30e57b7705152a7a51505b370e18663032b9a1c26`.

A separate GUI check (`tmp/acid-articulation/session/gui_same_pitch_edit.txt`) exercised the same-pitch slide checkbox, keyboard note selection, Generate button and save/reopen in Renoise. The record reports that the live edit emitted note 50 from initial note 49, while a subsequent keyboard change did not alter the current phrase until Generate emitted note 52. Record SHA-256: `3ae9109d725b6603120217ebf1e8e7f2df326ae5ffbf21efa712a4ab99bbcef2`; saved XRNS `gui_same_pitch_edit.xrns` SHA-256: `b62769005dbdca7b0f93ccb138e80fba8e882122d808e497caaa0c1b8ab64aa4`. This check does not cover rapid repeated edits or playback behavior.

These offline results add local render and persistence evidence. Deterministic exports do not replace independent playback captures, and the remaining moving glide, accent and tempo work stays open.

## Updated Repeat, accent and tempo renders — 2026-10-27

The following measurements use fresh Renoise 3.5.4 offline WAVs at 48 kHz stereo PCM24. They establish the named instrument and writer cases only; they are not soundcard or loopback captures. Repeated identical file hashes show deterministic render output, not independent device variation.

The fixed-bound tempo calibration passes all 68 expected events in three analyses at both 90 and 150 BPM. The earlier 90 BPM exports whose duration matched 120 BPM remain invalid and unchanged; these are new settled-tempo files. Held-note, same-pitch retrigger and REST-release controls also pass three times at each tempo.

| Calibration | Analyses | Duration | Max onset error | WAV SHA-256 |
| --- | --- | --- | --- | --- |
| 90 BPM | 3 pass | 20,000 ms | 0.667 ms | `83326e25d92e33484f04150b30d8e0d4910e0225423e9b20b114f7ebe766c468` |
| 150 BPM | 3 pass | 14,400 ms | 0 ms | `1121bd78da91c65800ba5b169db4d2ea0af1bfc3a0d124e594194923820b2a3f` |

The three one-shot writer tail families also pass three times at both 90 and 150 BPM. Each triplet has one unique WAV hash, so each result establishes repeatable offline output rather than independent captures. The latest files use `writer_one_shot_<family>_tail_bpm_<tempo>_verified_1.wav` through `_3.wav`; every sidecar records `duration_check=passed`, two channels, and zero duration error. Their hashes match the analyzed files summarized below.

| Writer protocol | BPM | Result | WAV SHA-256 |
| --- | ---: | --- | --- |
| NOTE tail | 90 | 3 pass | `076fbdb801b8c3f5488c45f3752c4e018b13c27c855ef1a6299dc96de0bc3865` |
| TIE tail | 90 | 3 pass | `849cf8938fae0e53dbb25e0e5d9ff39000967e6c65cc6795db46525655e64793` |
| two-TIE tail | 90 | 3 pass | `f17faf3b32c3db52b2048e6c04393da8a224abc396ef5319a2d512d147df940d` |
| NOTE tail | 150 | 3 pass | `bfa5359e7be2830c3ac3655f150a508c20f0efc4e78211d4f6a87304cdc6f4f1` |
| TIE tail | 150 | 3 pass | `fd7439fdfc77537a5dbb28e3c2eafcd856fc73ceff17bdc372f60d75951861e4` |
| two-TIE tail | 150 | 3 pass | `d1fe3cd2c4b3e9efaa53b7b1c1e3b66bec480dae220ba4829513e5fb2e09aad5` |

The six moving Repeat writer analyses pass for four-semitone and octave destinations, three each. Pitch-matched held controls at 48, 52 and 60 also pass three analyses each. The analyzer summary records one WAV hash per triplet; the results apply to the tested four-pass phrase and exact diagnostic profile. They do not establish other Repeat lengths or general instrument support. Summary SHA-256: `c3c3f582e8dfdd72959ec6ce9cab6e5110a9ec6f126f1323233aff5c846d018d`.

Four flat mapped-velocity accent families pass: native alternating, native consecutive, actual-writer alternating and actual-writer consecutive. Their measured normal-to-full velocity change is +3.088274 dB against +3.156 dB predicted from emitted note volumes, a -0.068 dB difference; each three-export family is byte-identical. WAV hashes and procedure are in [the accent manual](renoise_articulation_accent_manual.md). These results cover NOTE velocity on the flat mapped reference only. Connected accent changes remain unverified and refused.

The analysis summaries are retained under `tmp/acid-articulation/session/`: `calibration_fixed_bounds_analysis_summary.json` (SHA-256 `014d6a8ea44be891a5bb5d5c5a49b5641c15b580030d66fd02312e379768eefc`), `writer_tail_tempo_analysis_summary.json` (SHA-256 `2d7bd0672670ebfa309a601371053db677226507987814bb9f9d6cb33b2aa748`), and `moving_repeat_glide_summary.json` (SHA-256 above). Accent response summary hashes: native alternating `c1611e9e288426f91f3c138b0c9fd1f6234905a9691c04f6cec722a91ea26fbe`; native consecutive `0e60f77a26670173a5c42de2d9482b66579fadaf9ae18018aa6674f58ac0d7ab`; writer alternating `25c9038a1cb033a0b917b92261ccdff9eb5753f804d67b9aeb920ee49657aebf`; writer consecutive `619e6d0cb7ac2fda8c99dda30b6a81b6a334992956368fa3c47370befbab2d21`.

Earlier copies retain sidecars from a helper build that reported `actual_channels=nil`; they were left unchanged. The verified files above are separate new renders from the corrected helper, whose regression spec asserts channel metadata and consumes the optional context after one render to prevent stale case labels.

These updates supersede the earlier statement that all moving Repeat glide, accent and tempo work remained open. Remaining M3 work still includes untested Repeat lengths and gate families, connected accent behavior, and the remaining eligibility and lifecycle cases. No broad runtime support or hardware-fidelity claim follows from these offline renders.

## Fresh packaged-tool and 8/9-step Repeat checks — 2026-10-27

The moving Repeat writer coverage now includes the supported 8-step
`N T T T N T T T` and 9-step `N T T T N T T T T` layouts. At the exact
diagnostic profile (120 BPM, selective, LPB8/TPL12, no groove), three actual
writer exports each pass for four-semitone and octave movement with the
pitch-matched hold comparisons. The three exports in each family have one
shared WAV hash, so they show deterministic offline output, not three
independent playback captures.

| Writer case | Analyses | WAV SHA-256 |
| --- | --- | --- |
| 8-step four-semitone glide | 3 pass | `292eeaccd5e3b305364ec6aac7d7ad11f9921c8cbf2b416e5fcb53473689de37` |
| 8-step octave glide | 3 pass | `42e17cb391986c6f2c8d8f6f6da057ea56ef62437f6abef57877300fd4712961` |
| 9-step four-semitone glide with trailing TIE | 3 pass | `586d7fd142065a52031907166482fb7e53993df82c5aa759902fadacb619fa06` |
| 9-step octave glide with trailing TIE | 3 pass | `e9a447d726bf7476bc42ed1517f40796fdb9f188440a61c18239ed6a54e6b679` |

The 9-step WAV and sidecar triplets are under
`tmp/acid-articulation/session/`; all six sidecars report completed duration
checks. The 8-step writer WAV hashes match the separately authored native
controls. These results support only the recorded source layouts, pitches and
profile. Other moving intervals, pitches, layouts, tempos and profiles remain
refused.

The fresh ACID package was installed in Renoise and its runtime GUI was checked
on phrase 30. Generate produced the 9-step source, Live Edit remained enabled
while LAST STEP changed 9→8→9, the phrase resized without changing ownership,
and save/reopen restored the exact source and slide mode. The capture record is
`tmp/acid-articulation/session/packaged_gui_moving_repeat.txt` (SHA-256
`a01942791f7676977a47ed6968f1aaef6368e13f19fb93ad7f4c5088aab87f46`), paired
with `packaged_gui_moving_repeat.xrns` (SHA-256
`e951e729c5edbd04f9eba6d35580405482f37539b8c13a3b672e312d5c5886ee`). The
existing production-controller lifecycle record also passes 8→9→8. This covers
normal Generate/Live Edit/save-reopen for this case; it does not cover rapid
edit races or playback through an audio device.

Current audio evidence in this section and the preceding tempo/accent section
comes from licensed Renoise offline rendering on this desktop. The soundcard is
different from the earlier loopback setup, and no current-desktop Audacity
loopback calibration or independent hardware capture is claimed.

## Final gate, glide and lifecycle render matrix — 2026-10-27

The full 21-protocol gate matrix now passes across 90/120/150 BPM on the exact
diagnostic profile (selective, LPB8/TPL12, groove off): nine one-shot NOTE,
TIE and TIE-TIE tail cases plus twelve TIE-before-fresh-NOTE,
two-TIE-before-fresh-NOTE, Repeat NOTE/REST and Repeat TIE/REST cases. The
latest twelve-case batch has 36 checked files, 12 unique PCM hashes and 24
byte-identical copies; all protocols pass, with no invalid captures. Earlier
two-TIE high-peak WAVs remain retained as invalid historical takes; the newer
three-tempo set passes and supersedes that result for the current matrix.

| Evidence batch | Result | Summary SHA-256 |
| --- | --- | --- |
| Gate fresh-successor/Repeat REST, 12 protocols × 3 BPM × 3 files | all pass; 36 files, 12 unique WAVs, 24 identical copies | `c33fa0aa0fffcfb26c672b4e8f0750c36db5a622c78a7e3c2c3afc73fd40d8a1` (`writer_record_hashes.json`); batch report `d8c257e6bb4b5826e28654241f42b112f89f192c38507ce27c82ab9a1a218028` |
| Native moving glide/holds, 90 and 150 BPM | 10/10 protocols pass | `992efa2dcde47adbb9e0928c0990637e676d8f15e74a30f4fddfdab156444c8` |
| Actual writer moving glide/holds, 90 and 150 BPM | 10/10 protocols pass | `94c2559b22254d1e692147f144fd45ec9843b3b68e6895edafe6d24b79f8cd55` |
| Native effect-edge controls | 21/24 captures pass; ungated fresh NOTE fails in three identical files; no invalid files | `8c61634708d04e92bc10b3848e49842f0c18887375192134caa65f37709ffa10` |
| Native host OFF, retrigger and keymapped phrase controls | 9/9 files pass; 2 unique PCM hashes | `97b43e676638aacb4505b02637d2036459326ccb997111cadd9a4e9503734024` |
| Packaged GUI screenshot | 874×918; both help lines visible with no overflow | `ba7112dd792b2fffdd4b9b8f0ba0d5321a8eff287860baaf83f1357fff6e81cf` |

The 90/150 glide matrix covers native 8-step controls and actual writer cases
for four-semitone/octave movement in both 8/9-step layouts (the 9-step writer
source includes a trailing TIE), pitch-matched holds at48/52/60, and same-pitch
Repeat length16. At120BPM, the corresponding 8/9-step moving cases pass, as do
same-pitch Repeat lengths16/17/32/33/48/49/64. These are byte-identical render
repetitions within each triplet, not independent playback captures. No other
moving layouts/pitches/intervals are enabled.

Effect-edge results distinguish a required failure from its explicit
cancellation path. Native 0G08 followed by an ungated fresh NOTE misses the
second attack in all three renders (`ad11fcf60ccb648301fa63907a5ba8ba38e71f93c7087540d0116aa94b3b2cab`);
the target attack is not audible. A REST cancels the native glide, and an
explicit OFF before the following NOTE passes for native 0G08 and actual writer
0G20 cases. The gated writer family hash is
`a2aa3a541cd4f5cfde76cb7d792633f9ee0c7fb52a6dac2f24d59da0bb232bd0`. Do not
remove the OFF or treat the failed ungated case as support.

The host lifecycle suite passes native host OFF, fresh retrigger and keymapped
trigger controls. These do not enable keymapped triggering in ACID's runtime.
Manual transport stop/start and seek remain unverified. The final packaged GUI
is visually confirmed at 874×918 with the two help lines visible; the screenshot
is retained under `tmp/acid-articulation/session/final-packaged-gui.png`.

### Accent retention across TIE

Three native and three actual-writer offline renders pass the flat mapped
accent/TIE protocol. The normal-to-accent NOTE delta is +3.088274 dB versus
+3.156 dB predicted from emitted cells; spread is 0 dB. Each TIE level is within
0.085888 dB of its preceding NOTE level in the early 15–50 ms window. All six
WAVs share hash
`ab1082dfd06cf12555c6225b53448e6a74ea87fcee84c421e7a2507d542f059a`.
Native response report SHA-256:
`9523618033e3ea91ab92610f5bdd1ce85c152a8bf34a5ef54574083c0782ea51`; actual
writer response report SHA-256:
`df25e5f4755c1d9cbf59bbbf31898d61acc58ed146a40501679ebc81287cb137`. This
qualifies mapped level and retention through unaccented TIEs on the declared
flat profile. Accent changes on connected slide chains remain refused; no
slide-chain accent waveform or instrument-wide accent claim is made.

M3 implementation evidence now closes the authored gate matrix and named glide
classes, plus NOTE/TIE accent response and the explicit fresh-NOTE cancellation
rule. Connected slide-chain accents remain refused with pre-mutation diagnostics.
Manual transport stop/start, seek and Live Edit during playback remain
unverified. All these results use Renoise offline rendering; current-desktop
soundcard-loopback behavior remains unclaimed.

## Final regression, package and installed-tool verification — 2026-10-27

Final verification completed after the runtime and GUI updates:

- All 24 ACID Lua specs pass.
- All 11 formal PowerShell analyzer/fixture checks pass; 13 PowerShell parse
  checks and 14 Lua syntax checks pass.
- The ACID package contains 19 runtime files. Every installed runtime file's
  SHA-256 matches the repository file.
- The installed package is `dist/com.david303ttl.ACID_0.1.xrnx`, SHA-256
  `cbcc932189134e1827398fe87fbb5399fa2d97ca3d75ce33e22e742b82be49f7`.
- The final packaged GUI is 874×918 and shows both help lines without overflow.

Receipt files are retained under ignored `tmp/` paths:

| Receipt | SHA-256 |
| --- | --- |
| `tmp/acid-articulation/session/final_verification_receipt.json` | `9ff488160eabecfa344c6aec1350ba6992d77818abbbc6973543ec1a996fd775f` |
| `tmp/m3_final_verification_20261027_174820_010/receipt.json` | `0c13252b62ec63ddf9eba2e775029987c2a024d668ecff1f11df8d0a6ab4d02e` |
| `tmp/acid-articulation/session/final-packaged-gui.png` | `ba7112dd792b2fffdd4b9b8f0ba0d5321a8eff287860baaf83f1357fff6e81cf` |

A live transport/loopback closeout was attempted, but no live audio export was
produced. Audacity exited before a loopback connection was available; no cause
is inferred. Renoise was restored to the original ASIO Hammerfall DSP setup
(48 kHz, 256 samples, dithering enabled); the preferences screenshot is
`tmp/acid-articulation/session/restored-asio-preferences.png`, SHA-256
`fe8c26c430c1ab15964990b8cc9f84cd125e2ff917a68cfedc7d58b0dbf9dc59`.

The final offline evidence and installed GUI therefore verify the declared
profile's renderer and Generate/Live Edit/save-reopen workflow. They do not
verify transport stop/start, seek or Live Edit during audio playback; those
remain the selective in-app M3 manual acceptance checks. Current-desktop
soundcard-loopback behavior is separately unclaimed. Implementation and final
regression/package verification are complete.

## Phrase pitch-bend receiver check (2026-10-28)

A bounded live test ran in Renoise **3.5.4 Demo** with **Surge XT VST3** and
Audacity **3.7.8**. The current song was first saved to an untracked backup.
The refreshed ACID package was copied into Renoise's installed Tools directory,
all archive entries were hash-checked, and **Tools → Reload All Tools** reloaded
the code; initialization appeared in Renoise's host log.

Renoise and Audacity used the same **PHL24E1N1100A WASAPI** endpoint, shared
mode, at **48 kHz stereo**. Audacity's Recording Level initially read **26%**;
it was changed to **97%** using its numeric Recording Level dialog and verified
by tooltip, reproducing the earlier measured route. Playback Level and Windows
system volume were not changed. The first low-level exploratory recordings are
not acceptance receipts. An offline render attempt produced Renoise's explicit
“Rendering is disabled in the demo version” error, so accepted files below are
live loopback captures, not offline renders or normalized exports.

Receiver readback showed both Surge scenes at **±12 semitones**, with
**Portamento 0.0 ms**. The nonzero-slot receiver was cloned from the working
slot-00 receiver. No receiver compatibility inference extends beyond this
configuration.

| Native phrase check | Raw capture result |
| --- | --- |
| Instrument slot `03`, empty phrase instrument/sample field (`255`) | 130.82 Hz → 195.92 Hz → 130.92 Hz; +6.99 semitones then center; -1.95 dBFS peak |
| Slot `03`, phrase field `00` | Also responds; matching the global slot number is not a prerequisite for phrase bend delivery |

The accepted native phrase held one C note while applying bend center, +7 and
center. The phrase instrument/sample field was empty, matching the generated
notes' default MIDI channel. Its raw WAV is
`tmp/acid-articulation/phrase-slot03-carrier-empty-20261028-110433-024-6bfc86.wav`,
SHA-256 `7c5cae8beae05a6b51f951ba9761f3aac7d9218380a31f0ff254e2a93838eff0`.
The pinned API describes the phrase instrument column as a sample selector;
this playback result does not turn it into a global destination selector.

An initial generated-writer capture in slot `03` measured center **130.8 Hz**,
intermediate **159.5 Hz** (+3.45 semitones), and target **195.6 Hz** (+6.97
semitones), with no full-scale samples. That development capture still used a
populated phrase field and is supporting interpolation evidence, not the final
corrected package receipt. The writer was subsequently changed to leave the
field empty; its refreshed-package result is recorded separately below.

These tests establish audible connected pitch change for the measured phrase
and receiver. They do not establish all VSTs, external MIDI destinations,
arbitrary MIDI channels, hybrid layering, host Undo, persistence, or every
Repeat seam. Unsafe Repeat seams continue to fall back to the NOTE route for
the whole phrase, with a nonfatal diagnostic.

### Corrected installed production writer

After enabling the bounded-verified support gate, the final archive
`dist/com.david303ttl.ACID_0.1.xrnx` was built with SHA-256
`6ea3742580f89319e49ae6645778691a09d7fdf3013c81deec5eadda99da189b` and
installed through Renoise `install_tool`. All 24 installed entries were
hash-verified, and the host log confirmed fresh ACID initialization.
Generation used the installed production module,
with every M1 carrier's instrument/sample field **empty (`255`)**; the source
provenance and readback are in the untracked
`generated_production_slot03_generation.txt` receipt.

Raw file `tmp/acid-articulation/generated-production-slot03-20261028-110722-171-2dcd7e.wav`
has SHA-256 `6630289b5b8925afbef142c250617eb1d98159379a9410a21b1d3903a23b559d`.
Its measured center was **130.8 Hz**, intermediate **159.3–159.66 Hz**
(**+3.41–3.45 semitones**), and endpoint **195.56–195.66 Hz**
(**+6.96–6.97 semitones**). Raw peak was **-1.958 dBFS**, with **no full-scale
samples**. Thus the corrected installed writer delivered audible intermediate
pitch and the intended G target to the nonzero-slot receiver.

The capture chain used Audacity Recording Level **97%**, Renoise track pre-FX
**+3 dB**, and Gainer settings **12.04 dB + 6 dB**. Receiver settings remained
unchanged during the final captures. Plugin Global Volume readback alone did
not establish capture level; the raw WAV measurements are the level evidence.
Windows playback volume was unchanged. No normalization was used.

### Exact two-step short slide and instrument reordering

The final short source contained only **NOTE C → NOTE G**, outgoing SLIDE on
C, Play Once, and no following TIE. The installed production writer emitted
exactly four lines: C/center, intermediate bend, G endpoint, OFF/center.

Fresh raw capture
`tmp/acid-articulation/generated-fourline-production-slot03-20261028-111020-224-d409e2.wav`
has SHA-256 `c6d39d59cf45263df8c0856cb23e12af618a49dd76128a3cd54276c1339a1e8d`.
It is **3.59 s**, peaks at **-1.9068 dBFS**, and has **no full-scale samples**.
Center measured **130.8 Hz**. The intermediate window at **0.765–0.870 s**
measured **159.42–159.66 Hz** (**+3.42–3.45 semitones**); the endpoint window
at **0.960–1.050 s**, before OFF, measured **195.12–195.30 Hz**
(**+6.92–6.94 semitones**). Receiver settling reached within approximately six
cents of G. The capture therefore establishes intermediate motion and the
short-slide endpoint with the existing two-lines-per-step schedule.
The release/reset tail bends down before silence at approximately **1.14 s**;
this test does not establish a transparent release.

An earlier attempted short-slide export duplicated a previous recording and
was rejected as stale evidence. The accepted file above has its own hash and
was captured after clearing and verifying the existing Audacity project's
tracks, without opening another project.

A real host reordering check swapped the target between slots `03` and `04`
during generation, then restored it. The writer **suspended** the in-flight
render. `production_reorder_receipt.txt` recorded unchanged phrase count,
name and source, with ownership still `owned`. This verifies preservation of
the last-good phrase under the tested slot move, rather than only a mock.

The temporary disabled-gate fallback was also captured in slot `03` as
`tmp/acid-articulation/generated-fallback-slot03-20261028-110245-826-9f3d44.wav`,
SHA-256 `f87c62fbc0c0f9255f914f72764140e3bbd2b2e04e10037ee05c2c25c5590360`.
Its audible C→G NOTE route provided a bounded fallback check before the support
gate was enabled. This is not an unsafe-Repeat-seam playback receipt; that
whole-phrase fallback still requires its separate musical-usability check.

## M4 phrase timing audio receipts (2026-10-28)

All captures used Renoise **3.5.4**, the disposable
`tmp/acid-m4-acceptance/probe_song.xrns`, the installed ACID writer, Selective
phrase triggering in instrument slot `01`, phrase program `08`, a 168-frame
looping saw, 48 kHz stereo PCM24, precise interpolation and no normalization.
The single host NOTE held the ACID Repeat phrase through four traversals, then
one host OFF ended it. Each capture included a silent pre-roll. Straight phrase
LPB was 8; Triplet LPB was 6; shuffle was 0. The source pitch was Renoise note
value 36. The tested source revision was
`0df7d907bc531eecb07d026bd1d98a88cff05893`.

The required fixtures measured as follows; each WAV has a matching Renoise
render sidecar, single-trigger receipt and full onset report under
`tmp/acid-m4-acceptance/`.

| Fixture | Timing / steps | Expected cycle | Measured cycle intervals | Attacks | Maximum onset error | WAV SHA-256 |
| --- | --- | ---: | --- | ---: | ---: | --- |
| T01 | Straight 16 | 4 beats / 2,000 ms | 2,000 / 2,000 / 2,000 ms | 64 | 0 ms | `8edf60f1a85159335c98b0e94de0903d6047f549dad12ab5babd0afbd55ef167` |
| T02 | Triplet 12 | 4 beats / 2,000 ms | 2,000 / 2,000 / 2,000 ms | 48 | 0.667 ms | `4bcdda705cfaebbe0be524a39267b1c6db0c5becbdeffafce11cdb1947a82f41` |
| T03 | Straight 12 | 3 beats / 1,500 ms | 1,500 / 1,500 / 1,500 ms | 48 | 0 ms | `63b4fe229ab70ceba832840c8dfbef13e926c9d652aa1b3ebe6c12e176ee768e` |
| T04 | Triplet 9 | 3 beats / 1,500 ms | 1,500 / 1,500 / 1,500 ms | 36 | 0.667 ms | `7f721a09b6590457414647036708a06b6a4c488eda40af8f2f410e77019defc6` |
| T05 | Triplet 15 | 5 beats / 2,500 ms | 2,500 / 2,500 / 2,500 ms | 60 | 0.667 ms | `4c86a8fcf2a534f54a05b1d676b65d7ca3ca6527c4b887c870adf15798acf913` |
| T06 | Triplet 64 | 64/3 beats / 10,666.667 ms | 10,666 / 10,667 / 10,667 ms | 256 | 0.667 ms | `5f152d880b39258b33cc489e7844fa38c58b83f8ed835c1947e983002d6e9e0e` |

T06 read back 257 phrase lines, 128 NOTE and 128 OFF events, and loop points
129–257. Its single host NOTE remained active across the split host patterns;
the host OFF fell before a fifth-cycle NOTE. None of these six measured runs
had a missing or extra phrase attack.

The actual audio matrix comprised **48/48 passing renders**: Straight 16 and
Triplet 12 at all 8 requested song LPBs and all 3 BPMs. Every case retained the
phrase-local LPB and stayed within the calibrated 5 ms tolerance. At 60 BPM,
cycle intervals measured 4,000 ms; at 120 BPM, 2,000 ms; at 180 BPM, 1,333,
1,333 and 1,334 ms (expected 1,333.333 ms). The maximum absolute onset error
was 0.667 ms. LPB 32 WAV hashes can differ from the other LPBs because the
song arrangement spans different pattern boundaries; event schedules still
passed.

Explicit metronome groupings and host-pattern segmentation also passed:

| Arrangement | Captures | Grouping | Pattern boundary | Receipt result |
| --- | --- | --- | ---: | --- |
| 3/4 | Straight 12, Triplet 9 | 3 beats × 8 lines | 24 lines | six host patterns each; one trigger only |
| 4/4 | Straight 16, Triplet 12 | 4 beats × 8 lines | 32 lines | five host patterns each; one trigger only |
| 7/8 | Triplet 12 | 7 beats × 4 lines at song LPB 8 | 28 lines | six host patterns; 56-line aligned pre-roll |

The 3/4 Straight 12 and Triplet 9 cases each measured 1,500 ms cycles. The 4/4
Straight 16 and Triplet 12 cases each measured 2,000 ms cycles. The 7/8 case
measured 2,000 ms cycles across successive 28-line pattern boundaries. Phrase
readback and rendered audio agree; no host pattern retrigger occurred.

Each source analyzer report records the expected and measured event schedule,
cycle drift, phrase readback, Renoise version, song configuration, meter,
pattern count, source commit, WAV SHA-256 and render-sidecar SHA-256. The final
`.timing_report.json.verified.json` reports add corrected per-capture
pre-roll/hold/pattern provenance. Original and final reports are retained
alongside the raw WAVs and sidecars in ignored `tmp/` output.

At capture time the report recorded package archive SHA-256
`5b7ad1eae42d8157d4836666322846c9337e264881c78262f10d0a9d73195e50`. The
final required packaging run produced
`dist/com.david303ttl.ACID_0.1.xrnx` with SHA-256
`af4ec6d72e899991bc88f56772a6c6d97d47c512083be954c45fc4d6ac748066`; all 25
archive runtime entries matched the installed Renoise 3.5.4 ACID directory
byte for byte. Both measurements reference the same source commit; package
archive SHA values identify their respective packaging runs.

These are static offline-render measurements against the BPM/step-duration
formula using the WAV sample clock. No separately captured host metronome or
independent beat-click reference was included. Live BPM/LPB changes,
stop/start, seek, groove, Live Edit during playback and the full sample/VST
articulation matrix remain unverified, so this evidence does not close M4.
