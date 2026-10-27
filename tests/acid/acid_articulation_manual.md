# ACID articulation verification

The development harness is implemented separately from the installable tool. Audio support remains unverified beyond the recorded grid calibration. The original held-note analysis was invalid because sustained level was too low and stereo channels differed. The user subsequently authorized gain normalization of explicit analysis copies; those reruns require their own provenance and calibration and do not change the original result. See the [capture evidence](audio_capture_evidence.md) for retained artifacts, hashes and measurements. An invalid control cannot choose a native glide strategy.

## Reproduce the checks

Use PowerShell 7 from the repository root:

```powershell
./tests/acid/validate_audio_oracle.ps1
./tests/acid/test_audio_oracle.ps1
./tests/acid/test_audio_analyzer.ps1
./scripts/run_tests.ps1 -Tool ACID
./tests/acid/analyze_articulation_audio.ps1 -CaseId grid_calibration_all_note_pitch_span_16 -WavPath tmp/acid-articulation/calibration_gated_fresh.wav -OutputPath tmp/acid-articulation/calibration_review.json
```

Output files must be new paths. Raw captures, reports, profile read-backs and writer records remain under ignored `tmp/acid-articulation/`. Record SHA-256 with `Get-FileHash -Algorithm SHA256`. Follow the [probe procedure](renoise_articulation_probe_manual.md) for disposable song setup, capture settings and writer output. A synthetic pass verifies analyzer discrimination and cannot establish native playback.

## Oracle qualification

`fixtures/audio_cases.json` contains 62 cases: seven ready independent native calibration/control/0G candidate protocols and 55 planned writer cases. The [gate procedure](acid_gate_manual.md) documents the 21 added one-shot-tail, fresh-successor and Repeat REST-seam cases across 90/120/150 BPM. Ready means the analyzer has a defined protocol; it does not mean acoustic acceptance passed. The CLI returns `unsupported` for planned cases before reading a WAV. Source flags use one-based PITCH indices; acoustic positions use zero-based straight TIME steps. One step is 60000/(BPM*4) milliseconds. Expected windows were authored independently of the runtime gate scheduler.

The writer fixtures now freeze independently authored semantic attacks, held pitches, forbidden attacks, continuity spans, OFF edges and silence windows wherever those follow from source intent. REST successors release exactly at the REST boundary; disconnected NOTE successors and one-shot tails release halfway through the final held step. Repeating fixtures cover cold plus three steady passes at every structural length. Slide seams require continuity and no fresh attack, including same-pitch connections. The informational release_edges array lists all OFFs; silence windows enforce each gap and release measures the final edge.

Each planned case records qualification.protocol_status and explicit blockers. Authored means the semantic protocol is specified, not acoustically accepted. Blocked means additional independent evidence is needed to freeze the full protocol: glide strategy/rate and settling deadlines; pitch-matched hold controls; emitted quantized accent cells and gain-compensated ratios; silent-case synchronization; or separately timed host OFF, retrigger, stop/start, seek and keymapped events. The CLI continues to return unsupported for every planned case. Lifecycle placeholders cannot pass on their initial NOTE alone. These remaining evidence gates prevent a case-completeness or runtime support claim.
## Analyzer implementation and limits

The analyzer reads RIFF/WAVE chunks directly without an audio-library dependency. It accepts mono or stereo integer PCM16/24/32 and supported 32-bit IEEE float, checks chunk geometry and truncation, decodes signed samples, and records the WAV SHA-256. Capture checks require the configured sample rate, peak below -6 dBFS, dual-mono stereo difference at most -60 dB relative RMS, detectable alignment and enough retained tail. Stereo measurements use the left channel after the channel check.

Alignment occurs once at the first detected expected onset; later expected times use BPM without per-cycle correction. The onset detector uses 10 ms RMS windows and 1 ms hops. It detects floor crossings or a trough at most 0.75 of a five-window median baseline followed by a 1.4-fold recovery within 10 ms. It compensates the look-ahead window and uses a refractory interval (40 ms normally, 90 ms for calibration). This is an envelope-restart heuristic, not a fitted attack/decay template; very close attacks and ambiguous native envelopes require separate control evidence.

Stable pitch uses linearly interpolated rising zero crossings and the median period, with at least four crossings and 40 ms of audio. Frequency targets use `(44100/168)*2^((note-48)/12)`, with ±15 cents tolerance. This estimator is intended for the reference saw, not arbitrary polyphonic recordings. Silence uses window RMS below -60 dBFS. Continuity uses 5 ms RMS windows with 1 ms hops against the authored baseline window; a dip greater than 6 dB lasting 4 ms, or a detected onset, fails. Native pitch-dependent comparisons still need matching hold controls.

Glide measurements require intermediate directional movement and a settled target window; an instantaneous pitch jump is insufficient. Release checks require audible sustain before OFF, inspect 2 ms RMS windows with 1 ms hops for the silence crossing, and confirm that crossing over 8 ms by default. The threshold is the lower of -60 dBFS and 40 dB below pre-OFF sustain. Reports include onset, pitch, silence, continuity, glide and release measurements where specified. Missing onset origin, malformed files and capture-quality failures are `invalid`; excess repeated-position cycle drift is `invalid`; other measured deviations are `fail`; planned protocols are `unsupported`. Exit codes are 0 for pass, 1 for fail and 2 for invalid/unsupported. Treat uncertain estimates as inconclusive in the manual record, regardless of a numerical result.

## Support matrix

| Profile / trigger / operation | Evidence | Support decision |
| --- | --- | --- |
| Reference diagnostic profile, selective, grid marker | Retained loopback calibration passes reanalysis | Capture route qualified for that recorded marker configuration only |
| Reference diagnostic profile, selective, held/retrigger/REST controls | Normalized held numeric pass; retrigger onset fails by 6 ms; REST and three-run controls pending | Continuity detector not qualified for native acceptance |
| Reference diagnostic profile, selective, 0G08/20/40 | Normalized 0G20 stops about 300 cents below target; valid repeated captures pending | Provisional 0G20 strategy fails; no native strategy selected |
| Separate native Mono/Glide variant | Not captured | Unsupported experiment; no instrument-wide strategy enabled |
| ACID writer gate modes and repeat seams | Helper can record generation/refusal and cells; native gate captures pending | Existing runtime refusals retained |
| ACID writer accent and connected accent | Level controls and native comparisons pending | No acoustic support claim |
| Keymapped trigger, host release, retrigger, stop/start and seek | Planned separate protocols | Unverified; selective calibration does not enable them |

No runtime articulation is enabled automatically by profile creation, oracle validation, analyzer results or this documentation. The next prerequisite is a valid audible, channel-consistent held/retrigger/REST control set, followed by three unchanged captures of each native candidate. Record a measured strategy/rate or explicit blocker before downstream renderer integration. Repeat 90/150 BPM acceptance only after the 120 BPM protocol is qualified. No internal voice-count or TB-303 hardware-fidelity claim follows from a mixed WAV.

For a tempo sweep, set `ACID_ARTICULATION_BPM` to 90, 120 or 150 before running both development trigger/start helpers. Unset means 120 BPM. Rebuild the host trigger after each change: hold duration remains in TIME steps, tail duration remains in seconds and pattern lines are recomputed at that BPM. Start rejects a transport BPM differing from the override. Use the printed wrap deadline and matching authored analyzer timing; qualify each tempo with a fresh calibration and controls before accepting candidates. The Lua duration checks cover all three tempos; they do not establish playback or acoustic acceptance at 90/150 BPM.

## Authorized normalized analysis copies

The user permits peak normalization for analysis. Raw exports remain unchanged. Create a separately named copy with `normalize_articulation_audio.ps1`, targeting -6.1 dBFS with a common scalar across all channels, and retain its gain receipt. Record original/copy SHA-256, original/copy peak, applied linear/dB gain and script settings. Pass the receipt to the analyzer so the machine-readable result preserves processing provenance. No resampling, time edits, compression, limiting or denoising belongs to this protocol. Optional `-Mono` records an arithmetic L/R average only when source stereo difference is at most -40 dB; it qualifies a separate mono-copy path, not original stereo agreement.

Recalibrate the known grid under the same documented normalization policy before evaluating normalized native controls. Capture all three A/B repetitions with unchanged playback settings. Prefer a shared gain for amplitude comparisons; with independently normalized copies, subtract their gain difference from measured level deltas before comparing emitted-cell ratios or accent repeatability. For A then B, `source_delta_db = copy_delta_db - (gain_b_db - gain_a_db)`. A normalized absolute noise floor is a different measurement from the original one; onset/silence control qualification must be rerun. Retain and label both result sets. Gain normalization preserves channel disagreement and signal-to-noise ratio. Optional recorded mono averaging has a separate result and cannot replace the original stereo finding.


## Diagnostic signature and native comparison helpers

Attack/decay reports include RMS windows at 0–5, 8–18 and 32–52 ms relative to each detected attack. The provisional diagnostic matches only when early/peak is below 0.75, sustain/peak is 0.45–0.90, peak RMS exceeds 0.001 and the complete window exists. Other results are explicitly inconclusive. These measurements do not gate native acceptance until positive retrigger, held and silent native controls qualify the thresholds. Repeated-source-position drift above 5 ms invalidates a capture.

`renoise_articulation_mono.lua` creates a separately named `ACID ARTICULATION MONO PROBE` copied from the diagnostic instrument. It uses native monophonic glide (default amount 32, optional `ACID_ARTICULATION_MONO_GLIDE`) without 0G commands. Its two phrases compare 48→55 and 48→48. Set `ACID_ARTICULATION_PROBE_NAME = "ACID ARTICULATION MONO PROBE"` before the trigger/start helpers; unset it to return to the polyphonic reference. Switching the trigger requires rerunning its builder. Duplicate variants are refused. This instrument-wide candidate cannot implement selective flags unless unflagged transitions independently pass.

`renoise_articulation_readback.lua` prints the selected named profile, realized envelope points and `fade_amount` from the ordinary application terminal. API 6.2 specifies the fade range but no timing conversion; its actual value must be retained with captures rather than inferred to express a millisecond release. The native variant builder, profile readback and duplicate refusal ran successfully in Renoise; no Mono/Glide WAV acceptance was performed.
