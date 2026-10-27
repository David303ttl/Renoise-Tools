# ACID articulation probe capture

This probe measures Renoise playback through Windows WASAPI loopback. The result describes the observed Renoise build, sample profile and capture route; it does not identify Renoise's internal voice allocation.

## Prepare the disposable song

1. From the repository root in PowerShell 7, create the ignored sample-output folder with `New-Item -ItemType Directory -Force tmp/acid-articulation`. Open a disposable Renoise song copy. In the Renoise Scripting Terminal, run `tests/acid/renoise_articulation_probe.lua` once. The script adds one named sample instrument and seven named phrases. It refuses to reuse an existing probe instrument.
2. Run `tests/acid/renoise_articulation_trigger.lua`. It adds a new regular track and a new sequencer pattern at the end of the song. The only trigger events are note 48 on line 1 and OFF on line 137. The phrase loop runs for four 17-step passes: a 17-step cold intro followed by three steady passes. Line 69 remains the phrase's exclusive-end sentinel. The 224-line trigger pattern lasts 14 seconds and leaves 87 lines after OFF, so the two-second release-tail capture finishes before the song sequence can wrap and retrigger.
3. Keep the song unsaved. The two named probe objects are disposable. Do not rerun the instrument-creation script in the same song. The trigger helper may be rerun to change duration: set `ACID_ARTICULATION_CAPTURE_STEPS = 100` and optionally `ACID_ARTICULATION_TAIL_SECONDS = 5.5` in the terminal, then rerun `renoise_articulation_trigger.lua`. Duration is in straight sixteenth steps (125 ms each at 120 BPM). Calculate looping captures as the cold intro plus all requested steady cycles; nonlooping cases must cover their final expected event and tail. Defaults are 68 steps and 5.5 seconds of tail. The helper moves the existing OFF, prints the actual hold/wrap times and rejects configurations beyond Renoise's 512-line pattern capacity. Clear the overrides with `ACID_ARTICULATION_CAPTURE_STEPS = nil; ACID_ARTICULATION_TAIL_SECONDS = nil` to restore defaults. It requires at least two seconds of tail; use separate runs when a capture cannot fit.

## Configure and capture

1. In Renoise Preferences → Audio, select **WASAPI** and the same shared playback endpoint that Audacity uses for its **Windows WASAPI** **(loopback)** input; leave exclusive mode off. On this desktop that endpoint exposes 48000 Hz through WASAPI, so use 48000 Hz in Renoise, Audacity's project and the exported PCM24 WAV. Do not resample or normalize the recording. Leave Windows system volume unchanged. Disable OS enhancements, spatial processing, recording effects, automatic gain and monitoring feedback. Mute other applications and any unrelated audible Renoise tracks.
2. Use Renoise BPM 120, song LPB 8, TPL 12 and phrase LPB 8. The reference instrument uses a generated 168-frame, 44100 Hz saw (root note 48, linear interpolation, forward whole-cycle loop, amplitude 0.35, sample volume 3.0), NNA Cut and a tempo-synced volume envelope with 10 ms attack, 20 ms decay to 0.65 sustain and 5 ms release. The probe prints the envelope read-back and writes the sample read-back inside `tmp/acid-articulation/`. Record the sample SHA-256 with the capture metadata.
3. Select the target phrase by setting the probe instrument's Phrase Program: 1 is calibration, 2 is held NOTE/OFF, 3 is same-pitch retrigger, 4 is REST, and 5–7 are 0G08/20/40. The calibration phrase is already selected when the probe is created. Its second line in each step contains OFF to create a half-step timing marker; these markers do not establish runtime gate behavior. For pitch and level controls, run `tests/acid/renoise_articulation_flat_control.lua`; restore the diagnostic envelope with `tests/acid/renoise_articulation_probe_envelope.lua` before measuring envelope timing or glide continuity.
4. Start Audacity recording at least one second before Renoise playback. In the Renoise Scripting Terminal, run `tests/acid/renoise_articulation_start.lua`; it verifies the host note, unique OFF and available tail, then starts at the trigger pattern's exact sequence position. Do not retrigger the host note. Let the pattern reach the printed OFF line (137 by default) and record at least two seconds more, then stop before the printed sequence-wrap time (14 seconds by default). Stop Renoise playback too, so the song cannot wrap and retrigger during export.
5. Export without normalization or effects. Record Renoise version/edition, Audacity version, Windows endpoint and driver, buffer size, sample rate/format/channels, BPM/LPB/TPL, phrase program, profile settings and WAV SHA-256. Keep raw WAVs and scratch reports under the ignored `tmp/acid-articulation/` directory; retain only hashes and portable artifact references in committed records.

## Calibration gate

Run the known grid calibration before interpreting any articulation A/B case. The expected reference is `grid_calibration_all_note_pitch_span_16` in `fixtures/audio_cases.json`: 68 pitch events across the 17-step cold intro and three steady passes. Run the oracle validator and analyzer from PowerShell 7:

```powershell
./tests/acid/validate_audio_oracle.ps1
./tests/acid/analyze_articulation_audio.ps1 -CaseId grid_calibration_all_note_pitch_span_16 -WavPath tmp/acid-articulation/calibration.wav
```

The analyzer uses a -60 dBFS onset floor and 10 ms onset RMS windows with 1 ms hops, aligned once to the first onset. Continuity and release measurements retain 5 ms RMS windows. The onset refractory interval limits detection of closely spaced extra attacks; this gate validates the authored grid markers. Require all 68 events in order, no missing or extra onsets, pitch within ±15 cents, each onset within ±5 ms, no clipping and no more than 5 ms accumulated drift. Do not align individual cycles or edit/stretch the recording. A failed calibration invalidates the route; check the output/loopback endpoint and settings, then capture a fresh calibration. Repeat calibration after any endpoint, driver, sample profile or capture-setting change.

## Result classes

Record each run as **pass**, **acoustic fail**, **invalid capture** or **inconclusive**. A failed calibration, clipping, contamination, channel mismatch, missing tail or excess drift is invalid. An uncertain pitch or onset estimate is inconclusive and does not enable support. Capture each A/B candidate three times with unchanged settings. Keep WAVs and scratch reports untracked under `tmp/acid-articulation/`; retain their SHA-256 hashes and portable artifact references in the evidence record.

The recorded desktop calibration and remaining native experiments are listed in [audio capture evidence](audio_capture_evidence.md).
