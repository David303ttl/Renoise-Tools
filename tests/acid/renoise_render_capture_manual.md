# ACID offline Renoise render capture

**Optional diagnostic only.** M4 timing/audio evidence is accepted; no further offline render or capture is a closure gate.

Use `tests/acid/renoise_render_capture.lua` only to reproduce a concrete audio or timing regression in a disposable song.

- Select the source song sequence/line range and an unused WAV output path.
- Set `ACID_RENDER_OUTPUT_PATH` and the start/end position globals documented in the helper source.
- Capture 48 kHz PCM24 and retain the generated render sidecar with the WAV.
- Set BPM first, let Renoise return to idle, then invoke render separately; a combined tempo-change/render command may use cached tempo.
- Do not overwrite previous captures. Record Renoise version, settings, source commit and result.

Accepted results: [timing](acid_timing_manual.md), [audio evidence](audio_capture_evidence.md). No loopback calibration or large matrix is required.
