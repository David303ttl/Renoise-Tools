# ACID native accent level control

Use this independent native phrase control to measure the Renoise sampler's velocity-to-volume response with equal pitch and no diagnostic volume envelope. It creates a new phrase inside the disposable `ACID ARTICULATION PROBE`; it does not change ACID runtime code or existing user instruments.

1. Create a fresh disposable probe with `renoise_articulation_probe.lua`, confirm the reference saw/profile read-back, and restore its diagnostic envelope if a prior flat profile changed it.
2. In the Renoise scripting terminal set `ACID_ACCENT_CONTROL_CASE = "alternating"` or `"consecutive"` and run `renoise_articulation_native_accent.lua`. The helper sets the disposable probe to flat volume and velocity mapping, then creates four repeated C-4 NOTE/OFF pairs at phrase LPB 8. Alternating uses volume cells 89, 255, 89, 255; consecutive uses 89, 255, 255, 89. In a note volume column 255 means full/default velocity (127), not an empty event.
3. Run `renoise_articulation_trigger.lua` with its default 32-step hold and a 5.5 second tail. Keep 120 BPM, LPB 8, TPL 12, selective phrase playback and groove disabled. Render with a silent pre-roll sequence and fixed gain under the calibrated workflow. Capture three unchanged files for each control. Record the WAV hash and `native_accent_<case>_<time>.txt` metadata with every take.
4. Measure equal-pitch settled RMS for each note at the same relative window after its onset; the authored window is step +0.08 to +0.4. Predict full-to-normal delta from the emitted cells: `20*log10(128/89) = 3.156 dB`. Require the median measured delta within ±0.5 dB and the three-run spread at most 0.5 dB. Reject any invalid calibration, clipping, channel disagreement, missing/extra onset, wrong cell read-back or contaminated take. Keep all raw captures unchanged.
5. This procedure qualifies the flat reference profile's NOTE velocity response. The TIE extension below measures early-window retention across TIEs with both a native control and actual writer. Accent changes on connected slide chains remain refused until a separate strategy and test establish their behavior. Do not infer filter-envelope or analog accent behavior.

## Accent retained by TIE

Use a fresh disposable probe and switch it to the flat mapped-velocity profile with `renoise_articulation_accent_control.lua`. The independent native control helper `renoise_articulation_native_tied_accent.lua` creates NOTE/TIE/OFF/NOTE/TIE/OFF/NOTE/TIE/REST at pitch 48, with NOTE volume cells 89, 255, 89, an empty note column on each TIE, and OFF at the midpoint of the first two TIEs. It writes `native_tied_accent_<time>.txt` under ignored `tmp/acid-articulation/`.

For the actual writer control, set `ACID_ARTICULATION_CASE_ID = "writer_tied_accent"` and `ACID_ARTICULATION_ORACLE_PATH = "tests/acid/fixtures/tied_accent_case.json"`, then run `renoise_articulation_writer.lua` in retrigger mode. It records the generated phrase as `writer_writer_tied_accent_<time>.txt`. The authored source is the same three NOTE events with TIEs between them and REST after the final TIE.

Capture three unchanged 48 kHz stereo PCM24 renders per case after the calibrated flat-profile setup. Run `analyze_accent_response.ps1` with `-CaseId native_tied_accent` or `-CaseId writer_tied_accent`, the three `-WavPath` values, matching `-WriterRecord`, and a new `-OutputPath`. The analyzer verifies NOTE cells at phrase lines 1/5/9 and empty TIE cells at 3/7/11; for the native control it also verifies OFF at lines 4/8/13. It aligns the authored note grid from the first detected onset, then measures only the early TIE window at +15 to +50 ms against the preceding NOTE's +15 to +50 ms RMS. Require each level difference within ±0.5 dB. The normal/accent median difference must remain within ±0.5 dB of 3.156 dB, with three-take spread at most 0.5 dB. Synthetic checks include an early TIE level drop, a TIE-level excursion, and a missing TIE window. This protocol does not claim that the flat sample envelope reveals every NOTE restart or that the voice remains uninterrupted through the full TIE; it measures early-window mapped sample-volume level only. It does not enable connected accents on slides or establish filter-envelope behavior.

Earlier exploratory writer captures measured about 3.09 dB for mapped 89-to-full velocity. The completed fresh offline render set is recorded below; no hardware-loopback variance is claimed. See `audio_capture_evidence.md` for the broader evidence record.

## Fresh offline accent renders — 2026-10-27

A fresh flat mapped-velocity calibration `flat_accent_calibration.wav` passes all 68 pitch, onset and silence windows at 48 kHz stereo PCM24, with a -6.11 dBFS peak and dual-mono stereo difference at the analyzer's -300 dB numerical floor. Its SHA-256 is `2d1b05bc5b1b273a14c8ba85f0fefaf5590bae8fe7f91c2f09d0bacdd555cc1d`.

Three offline Renoise renders each passed for independent native and actual writer alternating/consecutive patterns. The sample modulation set was bypassed and `map_velocity_to_volume=true`; generated NOTE cells read back 89 for normal and 255 (full/default velocity) for accented notes. Render format is 48 kHz stereo PCM24, peak -6.11 dBFS, dual-mono difference at the numerical floor. Equal-pitch 15–50 ms RMS windows measure `-13.902 dBFS` normal and `-10.814 dBFS` accent. Each family measures +3.088274 dB against +3.156 dB predicted from the emitted cells, error -0.068 dB. The three exports per family are byte-identical deterministic offline renders, yielding 0.000 dB spread; they confirm render repeatability, not independent device/playback variation.

| Protocol | Result | WAV SHA-256 |
| --- | --- | --- |
| Native flat alternating | pass, +3.088274 dB | `5a409e154f83db7f7bad458fed4a7d44da20ae6fe35e5cc2dabe85fe8144615d` |
| Native flat consecutive | pass, +3.088274 dB | `9a127fcca941bfa53de02d35c4c7a7fc5cd87c2fe2b6b401647283b91f497316` |
| Actual writer alternating | pass, +3.088274 dB | `74e9bfa9a553d5a4235602ba1794a81cba93e3d5de7b4af3e597fe3f2797daa6` |
| Actual writer consecutive | pass, +3.088274 dB | `16c169c28093efd96c9f4e9947e99d88a833d6fb7ea1a65909b3bd82e3238807` |

Reports in `tmp/acid-articulation/session/` retain all three per-run hashes and level windows. These passes qualify the declared flat mapped reference, alternating/consecutive NOTE patterns and early TIE level retention. The TIE windows remain within0.085888dB of their preceding NOTE level. Connected accent changes during slide chains remain refused by writer preflight; the TIE result does not enable slide-chain accents.

Tied-accent report hashes: native `native_tied_accent_response_20261027_174423485.json`, SHA-256 `9523618033e3ea91ab92610f5bdd1ce85c152a8bf34a5ef54574083c0782ea51`; actual writer `writer_tied_accent_response_20261027_174435180.json`, SHA-256 `df25e5f4755c1d9cbf59bbbf31898d61acc58ed146a40501679ebc81287cb137`. All six WAVs have SHA-256 `ab1082dfd06cf12555c6225b53448e6a74ea87fcee84c421e7a2507d542f059a`. They are byte-identical offline-render copies, not six independent hardware captures.
