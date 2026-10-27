# ACID offline Renoise render capture

Use this helper in the ACID Scripting Terminal with a disposable song. It renders
the selected song section through Renoise to a new WAV; it does not use the
desktop audio device. This makes the result independent of the playback
soundcard. It still measures the selected Renoise build, song, instruments,
effects and render settings, and does not verify WASAPI playback or loopback.

1. Open a fresh disposable song with the diagnostic instrument and a trigger
   pattern, or create an actual writer phrase with
   `renoise_articulation_writer.lua`. Put a silent sequence before the trigger
   sequence and include it in the render range. Starting the file on the first
   trigger produced a bad first-onset alignment even when later calibration
   events aligned; a two-second silent sequence before the trigger fixes the
   render pre-roll. Allow enough pattern lines after host OFF for the release
   tail.
2. Set BPM in one Renoise terminal command, let Renoise return to idle, then run
   the render helper in a separate command. Changing BPM and rendering in the
   same callback can produce a WAV at the previous engine tempo even when the
   transport property and sidecar show the requested BPM. The helper checks the
   actual WAV duration against the captured section and tempo, but the transport
   change must settle before render starts. Select the ACID Scripting Terminal,
   set the output path and explicit song section, then run
   `tests/acid/renoise_render_capture.lua`. Positions are
   one-based sequence and pattern-line indices. The helper defaults to 48000 Hz,
   24-bit PCM, precise interpolation and high priority. Override those settings
   with `ACID_RENDER_SAMPLE_RATE`, `ACID_RENDER_BIT_DEPTH`,
   `ACID_RENDER_INTERPOLATION` (`default` or `precise`) and
   `ACID_RENDER_PRIORITY` (`low`, `realtime` or `high`).
3. Wait for Renoise's render to finish. The helper writes a sibling
   `.render.txt` file with `status=pending` before rendering, then
   `status=completed` in Renoise's success callback. It also compares rendered
   WAV frames, stereo channel count, sample rate and bit depth with the expected
   duration calculated from the selected section and transport snapshot. Analyze only when
   `duration_check=passed`; `failed` indicates that actual render timing differs
   from metadata, and `unavailable` means the output geometry could not be
   verified. A refusal records `status=failed`; if Renoise closes before the
   callback, pending means the render was not confirmed. The helper refuses
   existing output and metadata paths.
4. Optionally include context before running it:

   ```lua
   ACID_RENDER_SOURCE_SAMPLE_SHA256 = "<64-digit sample hash>"
   ACID_RENDER_SOURCE_SONG_SHA256 = "<64-digit saved song hash>"
   ACID_RENDER_WRITER_RECORD = "tmp/acid-articulation/writer_case_time.txt"
   ```

   Hash fields are optional and must be SHA-256 hex. The writer record should
   identify the actual source phrase and generated note cells for writer cases.
   Calculate the WAV hash after completion with
   `Get-FileHash -Algorithm SHA256` in PowerShell 7.
5. Open the completed WAV in Audacity for inspection if useful. Keep it at the
   rendered sample rate; do not normalize, crop, resample or apply effects to
   the evidence file. Run the authored analyzer protocol against the original
   WAV and retain its report beside the capture under ignored `tmp/`.

Example for a trigger pattern that is the final sequence entry:

```lua
ACID_RENDER_OUTPUT_PATH = "<REPO>/tmp/acid-articulation/render.wav"
ACID_RENDER_START_SEQUENCE = #renoise.song().sequencer.pattern_sequence
ACID_RENDER_START_LINE = 1
ACID_RENDER_END_SEQUENCE = ACID_RENDER_START_SEQUENCE
ACID_RENDER_END_LINE = renoise.song().patterns[
  renoise.song().sequencer:pattern(ACID_RENDER_END_SEQUENCE)].number_of_lines
dofile("<REPO>/tests/acid/renoise_render_capture.lua")
```

Replace `<REPO>` with this checkout's absolute path before running the example.

For Repeat captures whose host hold exceeds one pattern, build a separate
multi-pattern trigger in a fresh disposable song. `ACID_LONG_CAPTURE_STEPS` is
the total host hold in straight TIME steps; for four passes of a 64-step source,
set it to `256`. The helper creates an empty silent pre-roll sequence, a single
host NOTE, as many 512-line trigger patterns as required, and one host OFF at
the calculated boundary. It leaves the old single-pattern selective start
checker untouched and does not launch playback.

```lua
ACID_LONG_CAPTURE_STEPS = 256
ACID_LONG_CAPTURE_TAIL_SECONDS = 3
ACID_ARTICULATION_BPM = 120
dofile("<REPO>/tests/acid/renoise_long_repeat_trigger.lua")
ACID_RENDER_OUTPUT_PATH = "<REPO>/tmp/acid-articulation/repeat_64x4.wav"
dofile("<REPO>/tests/acid/renoise_render_capture.lua")
```

The long trigger helper fills `ACID_RENDER_START_SEQUENCE/LINE` and
`ACID_RENDER_END_SEQUENCE/LINE` to include the silent pre-roll and complete
release tail. The render sidecar records the step count and selected phrase
program. Use the output positions printed by the builder to check the OFF
boundary before rendering. The helper accepts up to 99 trigger patterns; each
pattern has at most 512 lines. This makes it possible to render longer host
holds while preserving one continuous NOTE/OFF pair.

The Renoise API defines section rendering with `renoise.SongPos` start and end
positions, but does not describe the endpoint's acoustic tail behavior. Confirm
the first render's duration and final release window in the analyzer before
using that range for an acceptance capture. Do not use an offline-render pass as
evidence for the desktop playback route or actual hardware behavior.

On the fresh licensed desktop, the first calibration render started at the
trigger and failed the first-onset alignment. A rerender including two seconds
of silent pre-roll passed all 68 calibration events. With the tested master
pre-fader volume at 0.94, its raw peak was -6.36 dBFS. These are Renoise offline
render findings for that song and configuration; they do not verify Audacity
loopback or another desktop audio route.
