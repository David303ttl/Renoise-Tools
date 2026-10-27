# ACID articulation probe capture

This probe measures Renoise playback through Windows WASAPI loopback. The result describes the observed Renoise build, sample profile and capture route; it does not identify Renoise's internal voice allocation.

## Prepare the disposable song

1. From the repository root in PowerShell 7, create the ignored sample-output folder with `New-Item -ItemType Directory -Force tmp/acid-articulation`. Open a disposable Renoise song copy. In the Renoise Scripting Terminal, run `tests/acid/renoise_articulation_probe.lua` once. The script adds one named sample instrument and seven named phrases. It refuses to reuse an existing probe instrument.
2. Run `tests/acid/renoise_articulation_trigger.lua`. It adds a new regular track and a new sequencer pattern at the end of the song. The only trigger events are note 48 on line 1 and OFF on line 137. The phrase loop runs for four 17-step passes: a 17-step cold intro followed by three steady passes. Line 69 remains the phrase's exclusive-end sentinel. The 224-line trigger pattern lasts 14 seconds and leaves 87 lines after OFF, so the two-second release-tail capture finishes before the song sequence can wrap and retrigger.
3. Keep the song unsaved. The two named probe objects are disposable. Do not rerun the instrument-creation script in the same song. The trigger helper may be rerun to change duration: set `ACID_ARTICULATION_CAPTURE_STEPS = 100` and optionally `ACID_ARTICULATION_TAIL_SECONDS = 5.5` in the terminal, then rerun `renoise_articulation_trigger.lua`. Duration is in straight sixteenth steps (125 ms each at 120 BPM). Calculate looping captures as the cold intro plus all requested steady cycles; nonlooping cases must cover their final expected event and tail. Defaults are 68 steps and 5.5 seconds of tail. The helper moves the existing OFF, prints the actual hold/wrap times and rejects configurations beyond Renoise's 512-line pattern capacity. Clear the overrides with `ACID_ARTICULATION_CAPTURE_STEPS = nil; ACID_ARTICULATION_TAIL_SECONDS = nil` to restore defaults. It requires at least two seconds of tail; use separate runs when a capture cannot fit.

## Configure and capture

1. In Renoise Preferences → Audio, select **WASAPI** and the same shared playback endpoint that Audacity uses for its **Windows WASAPI** **(loopback)** input; leave exclusive mode off. On this desktop that endpoint exposes 48000 Hz through WASAPI, so use 48000 Hz in Renoise, Audacity's project and the exported PCM24 WAV. Do not resample the recording. Retain the original export unchanged; explicit gain-normalized analysis copies are permitted under the policy below. Leave Windows system volume unchanged. Disable OS enhancements, spatial processing, recording effects, automatic gain and monitoring feedback. Mute other applications and any unrelated audible Renoise tracks.
2. Use Renoise BPM 120, song LPB 8, TPL 12 and phrase LPB 8. The reference instrument uses a generated 168-frame, 44100 Hz saw (root note 48, linear interpolation, forward whole-cycle loop, amplitude 0.35, sample volume 3.0), NNA Cut and a tempo-synced volume envelope with 10 ms attack, 20 ms decay to 0.65 sustain and 5 ms release. The probe prints the envelope read-back and writes the sample read-back inside `tmp/acid-articulation/`. Record the sample SHA-256 with the capture metadata.
3. Select the target phrase by setting the probe instrument's Phrase Program: 1 is calibration, 2 is held NOTE/OFF, 3 is same-pitch retrigger, 4 is REST, and 5–7 are 0G08/20/40. The calibration phrase is already selected when the probe is created. Its second line in each step contains OFF to create a half-step timing marker; these markers do not establish runtime gate behavior. For pitch and level controls, run `tests/acid/renoise_articulation_flat_control.lua`; restore the diagnostic envelope with `tests/acid/renoise_articulation_probe_envelope.lua` before measuring envelope timing or glide continuity.
4. Start Audacity recording at least one second before Renoise playback. In the Renoise Scripting Terminal, run `tests/acid/renoise_articulation_start.lua`; it verifies the host note, unique OFF and available tail, then starts at the trigger pattern's exact sequence position. Do not retrigger the host note. Let the pattern reach the printed OFF line (137 by default) and record at least two seconds more, then stop before the printed sequence-wrap time (14 seconds by default). Stop Renoise playback too, so the song cannot wrap and retrigger during export.
5. Export the original without effects and retain it unchanged. Normalization is permitted on a separate analysis copy with its gain receipt. Record Renoise version/edition, Audacity version, Windows endpoint and driver, buffer size, sample rate/format/channels, BPM/LPB/TPL, phrase program, profile settings and WAV SHA-256. Keep raw WAVs and scratch reports under the ignored `tmp/acid-articulation/` directory; retain only hashes and portable artifact references in committed records.

## Calibration gate

Run the known grid calibration before interpreting any articulation A/B case. The expected reference is `grid_calibration_all_note_pitch_span_16` in `fixtures/audio_cases.json`: 68 pitch events across the 17-step cold intro and three steady passes. Run the oracle validator and analyzer from PowerShell 7:

```powershell
./tests/acid/validate_audio_oracle.ps1
./tests/acid/test_audio_oracle.ps1
./tests/acid/test_audio_analyzer.ps1
./tests/acid/analyze_articulation_audio.ps1 -CaseId grid_calibration_all_note_pitch_span_16 -WavPath tmp/acid-articulation/calibration.wav
```

The analyzer uses a -60 dBFS onset floor and 10 ms onset RMS windows with 1 ms hops, aligned once to the first onset. Continuity uses 5 ms RMS windows; release uses 2 ms RMS threshold windows with 1 ms hops and an 8 ms confirmation by default. The onset refractory interval limits detection of closely spaced extra attacks; this gate validates the authored grid markers. Require all 68 events in order, no missing or extra onsets, pitch within ±15 cents, each onset within ±5 ms, no clipping and no more than 5 ms accumulated drift. Do not align individual cycles or edit/stretch the recording. A failed calibration invalidates the route; check the output/loopback endpoint and settings, then capture a fresh calibration. Repeat calibration after any endpoint, driver, sample profile or capture-setting change.

## Result classes

Record each run as **pass**, **acoustic fail**, **invalid capture** or **inconclusive**. A failed calibration, clipping, contamination, channel mismatch, missing tail or excess drift is invalid. An uncertain pitch or onset estimate is inconclusive and does not enable support. Capture each A/B candidate three times with unchanged settings. Keep WAVs and scratch reports untracked under `tmp/acid-articulation/`; retain their SHA-256 hashes and portable artifact references in the evidence record.

The recorded desktop calibration and remaining native experiments are listed in [audio capture evidence](audio_capture_evidence.md).

## Capture the actual writer separately

Independent native controls and ACID writer output answer different questions. After creating the probe, choose ACID's Scripting Terminal context and set these globals before running `tests/acid/renoise_articulation_writer.lua` from its repository file:

```lua
ACID_ARTICULATION_CASE_ID = "isolated_note"
ACID_ARTICULATION_WRITER_MODE = "retrigger"
```

Use a case whose oracle `playback.renderer` is `acid-writer`. The helper loads the canonical source and calls the unchanged writer. `baseline`, `retrigger`, `slide` and `mono` are existing writer mode identifiers; selecting one does not qualify its sound. The helper preserves writer preflight, ownership and unsupported-mode refusals. It requires ACID's tool scripting context with `renoise.tool().app_idle_observable`; the generic application terminal cannot run the asynchronous writer and is rejected before generation. It supports selective triggering only, refuses another tool's cached module context and does not overwrite its metadata record. Wait for `Writer phrase ready` before recording: generation is asynchronous. A refusal, failure or pending record is not captured output.

The helper appends and selects the generated phrase and writes a portable record under `tmp/acid-articulation/writer_<case>_<time>.txt`, including sample/mapping/envelope settings, trigger options, transport, phrase metadata and every generated note cell. Keep that record with the WAV and its hash. Configure the trigger hold using `ACID_ARTICULATION_CAPTURE_STEPS`, rerun the trigger helper, then run the start helper after recording begins. Capture long cases separately if the required hold and tail exceed one 512-line song pattern. Keep planned oracle cases unsupported until their acoustic protocols and native controls are qualified; generating their source cannot turn an analyzer refusal into a pass.

## Deterministic playback start

The start helper validates the unique named instrument, pattern and track, selective phrase program, single host NOTE/OFF and empty modifier/effect cells. It stops transport twice to silence held voices, sets the chosen BPM / LPB 8 / TPL 12, disables groove and metronome, clears block/pattern/sequence looping and starts at the dedicated trigger's line 1. These changes apply to the disposable song. Set `ACID_ARTICULATION_BPM = 90`, `120` or `150` before running both the trigger and start helpers; the default is 120 when unset. The trigger keeps the hold in TIME steps and rounds the requested tail up to whole lines using the chosen BPM. Start refuses a transport BPM that differs from the override, so rerun the trigger after changing tempo. Clear `ACID_ARTICULATION_BPM = nil` and rerun the trigger to restore 120 BPM. At 90/120/150 BPM each step lasts approximately 166.667/125/100 ms; use the printed hold/wrap durations rather than the default 14-second wrap when recording. Tempo sweeps require matching authored analyzer timing and fresh calibration; helper support alone does not qualify a tempo's acoustic results.

## Current qualification and pending work

The oracle currently has seven ready native protocols and 34 planned writer cases. Eight planned gate families have authored full half-step NOTE/TIE/REST windows; the remaining 26 have initial windows and explicit incomplete requirements. The analyzer returns `unsupported` for planned cases. The original held-note analysis was invalid because sustained level and stereo consistency did not meet the original control requirements; user-authorized gain normalization may be evaluated on a separate retained analysis copy. The retained grid calibration still passes reanalysis, but it cannot establish diagnostic-envelope continuity or choose a native strategy/rate. Keep the sample gain and Windows volume fixed while investigating the profile/routing. Recalibrate for any profile or endpoint change and rerun calibration under the same analysis-copy normalization policy used for A/B controls.

The [articulation manual](acid_articulation_manual.md) records the support matrix, actual analyzer algorithms, commands, exact case-completeness blockers and native decision. Runtime gate/glide/accent support is not enabled automatically by these scripts or records.

## Authorized analysis-copy normalization

The user authorized normalization after the original low-level capture analysis. Keep the source WAV unchanged and create a separate peak-normalized analysis copy with `normalize_articulation_audio.ps1`. Use a -6.1 dBFS target and one positive gain scalar for both channels. Retain source and output SHA-256, source/output peaks and applied linear/dB gain in the script's receipt. Supply the receipt when analyzing the copy; label all reported absolute levels as analysis-copy levels.

Rerun the grid calibration with this same documented copy policy before interpreting normalized A/B controls. Apply the same gain to compared captures where possible. If each copy has its own peak-derived gain, calculate the source level difference as `measured_copy_delta_db - (gain_b_db - gain_a_db)`; independent peak normalization otherwise erases amplitude differences. Accent results require this compensation and the actual emitted volume cells. Relative continuity within one WAV keeps its gain ratio. Absolute silence and onset thresholds apply to the analyzed copy and require the calibration/control reruns, rather than inheriting the original low-level pass.

Normalization changes gain only. It cannot repair source clipping, contamination, channel disagreement, missing sustain, resampling or timing drift. Preserve both channels by default. An explicitly recorded `-Mono` copy may average L/R only when source stereo difference is at most -40 dB; this qualifies the mono-copy path and does not establish original stereo channel agreement. Keep both original and normalized results in the evidence record. A normalized-copy pass describes that declared processing path and cannot silently replace an invalid original result.

Example commands (PowerShell 7); the output and receipt paths must be new:

```powershell
./tests/acid/normalize_articulation_audio.ps1 -WavPath tmp/acid-articulation/calibration_gated_fresh.wav -OutputPath tmp/acid-articulation/calibration_normalized.wav
./tests/acid/analyze_articulation_audio.ps1 -CaseId grid_calibration_all_note_pitch_span_16 -WavPath tmp/acid-articulation/calibration_normalized.wav -NormalizationProvenancePath tmp/acid-articulation/calibration_normalized.wav.normalization.json -OutputPath tmp/acid-articulation/calibration_normalized_report.json
```

Read `gain_db` from the calibration receipt and use that same value with `-GainDb` when creating A/B copies; the normalizer refuses a fixed gain that exceeds its peak ceiling. `-ProvenancePath` selects a custom receipt path. Use optional `-Mono` only for the explicitly recorded mono-copy protocol above, and apply the same policy to calibration and the compared controls. The analyzer verifies the receipt's retained source/output hashes using `-NormalizationProvenancePath`.
