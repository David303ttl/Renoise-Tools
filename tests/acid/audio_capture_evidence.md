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
