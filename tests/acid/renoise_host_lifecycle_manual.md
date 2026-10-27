# Native host lifecycle probe

This development probe separates the song-pattern host event from the phrase's
own NOTE/OFF cells. It uses the diagnostic instrument created by
`renoise_articulation_probe.lua`; use the same freshly loaded, unmodified base
song for each case. After each capture, close without saving and reopen that
base before building another variant. The probe builder does not alter ACID's
runtime or promote acoustic support.

## Build host NOTE, OFF, and retrigger cases

From the repository root, set one case and execute the builder in Renoise's
Scripting Terminal:

```lua
ACID_HOST_LIFECYCLE_CASE = "host_note_off"
dofile("tests/acid/renoise_host_lifecycle_probe.lua")
```

Available cases are `host_note_off`, `fresh_retrigger`, `transport_stop_start`,
`transport_seek`, and `keymapped_trigger`. Set
`ACID_HOST_LIFECYCLE_BPM` to 90, 120, or 150 before building; default is 120.
Use a fresh disposable song copy between cases because each build adds a phrase,
track, and sequence pattern. The helper prints the event positions and wrap
time, then selects the pattern start.

Each pattern starts with 16 silent TIME steps (two seconds at 120 BPM) so the
first attack is not at the file boundary. Analyzer step 0 is aligned to the
first host NOTE after that pre-roll. At 120 BPM, LPB 8, and TPL 12:

| Case | Native song-pattern events | Question |
| --- | --- | --- |
| `host_note_off` | NOTE 48 at line 33, host OFF at line 49 (relative step 8) | Does host OFF stop the phrase voice, and what release tail follows? |
| `fresh_retrigger` | NOTE 48 at lines 33 and 49 (relative step 8), host OFF at line 65 (relative step 16) | Does the second host NOTE restart the same-pitch phrase attack? |
| `transport_stop_start` | NOTE 48 at line 33, host OFF at line 161 | Does stopping and restarting the transport cut and retrigger the phrase? |
| `transport_seek` | NOTE 48 at line 33, host OFF at line 161 | Does seeking back to line 33 while playing retrigger the phrase? |
| `keymapped_trigger` | NOTE 48 at line 33, host OFF at line 49 (relative step 8) | Does a keymapped phrase respond like selective phrase playback? |

The builder consumes `ACID_HOST_LIFECYCLE_CASE` and
`ACID_HOST_LIFECYCLE_BPM` and clears them after a successful build. Rendering
the selected last pattern from its first line retains the two-second silent
pre-roll and all later host events.

For the keymapped case, the helper adds a 48-only mapping to its new held NOTE
phrase, selects the Renoise Keymap phrase mode, and verifies the mapping
read-back. Confirm that mode and the mapping are visible in the Phrase editor
before capture. The mapping is deliberately limited to one key so the input
event is unambiguous.

The analyzer-ready 120 BPM protocols are independently recorded in
`fixtures/host_lifecycle_cases.json`. Build or check that fixture, then run its
synthetic controls from PowerShell 7:

```powershell
pwsh -NoProfile -File ./tests/acid/build_host_lifecycle_cases.ps1
pwsh -NoProfile -File ./tests/acid/test_host_lifecycle_cases.ps1
```

Analyze each retained WAV with the matching case ID. For example:

```powershell
pwsh -NoProfile -File ./tests/acid/analyze_articulation_audio.ps1 `
  -WavPath ./tmp/acid-articulation/host-lifecycle/host-off-take.wav `
  -OraclePath ./tests/acid/fixtures/host_lifecycle_cases.json `
  -CaseId host_note_off_native
```

The fixture expects host NOTE at step 0 and OFF at step 8; the retrigger case
adds another NOTE at step 8 and ends with OFF at step 16. Each attack has its
own settled pitch window, the final OFF must reach the silence threshold within
10 ms, and each render/capture needs at least 500 ms after the declared windows.
The keymapped protocol has equivalent acoustic windows but does not enable or
claim ACID runtime support for keymapped playback. Synthetic positives and
seeded failures qualify the analyzer protocol only; native captures remain
unverified until measured.

## Record stop, restart, and seek state

Build either transport case from a clean probe base and save the disposable song
so the probe is easy to reopen. Create the ignored output directory from
PowerShell 7:

```powershell
New-Item -ItemType Directory -Force tmp/acid-articulation/host-lifecycle
```

In the Renoise Scripting Terminal, load
`tests/acid/renoise_host_transport_record.lua` while the selected sequence is
the `ACID HOST LIFECYCLE TRANSPORT` pattern. It samples `transport.playing` and
`transport.playback_pos` every 50 ms (nominal timer interval) for 30 seconds by
default, writing a new CSV below `tmp/acid-articulation/host-lifecycle/`.
Optional globals `ACID_HOST_TRANSPORT_SAMPLE_MS` (20–1000 ms) and
`ACID_HOST_TRANSPORT_RECORD_SECONDS` (5–600 s) adjust the sample interval and
duration. Start Audacity recording, start song playback, stop after the first
NOTE has sounded, restart from pattern line 1, then seek back to line 1 while
playing. Restart the stop/start take at pattern line 1; in the seek take, jump
to line 33 while transport is running. The readback records observed playing
state and sequence/line; use the Audacity waveform to measure event and release
timing.

Use the same Renoise playback endpoint as Audacity's WASAPI loopback input. Keep
the raw stereo PCM24 capture at 48 kHz, avoid resampling or processing the
original, and note the audio device, driver, buffer, Renoise/Audacity versions,
BPM, and take hash. A changed soundcard means previous loopback level and noise
calibration cannot be reused. Capture each lifecycle action in its own fresh
take, with a held-note control and enough post-event tail for the observed
release. Preserve failed and inconclusive takes.

The recorder is a timed readback of Renoise's transport properties, not a
sequencer or a precise event timestamp source. Built-in offline song rendering
can verify the static NOTE/OFF/retrigger patterns, but cannot validate a manual
stop, restart, or seek action; those cases require the live transport action
and a separately recorded loopback capture. Do not mark a case acoustically
accepted from the initial NOTE, a timer trace, or a synthetic analyzer result.
