# Mixed NOTE / TIE / REST loop playback probe

This temporary Renoise experiment renders two hand-built native phrases from a
single host trigger. It isolates cold intro versus steady-loop behavior,
independent PITCH spans, ties that hold a voice up to the seam, and a REST
at the seam. It does not use ACID's phrase writer and does not establish
TB-303 envelope or slide behavior. Run it only in a disposable song copy.

## Setup and run

Use the disposable Renoise song and the instrument `ACID LOOP PROBE` from
[`renoise_loop_probe_manual.md`](renoise_loop_probe_manual.md). The instrument
must contain a looping single-cycle saw mapped over notes 36–48, with sample
data loaded. Leave its phrase list available for two temporary phrases.
The song must contain one empty pattern and one sequence position. The script
adds one temporary trigger track, extends the pattern, creates two phrases,
renders WAVs under `%TEMP%`, then removes the temporary phrases and track and
restores the pattern length and instrument playback settings.

From Renoise's Scripting Terminal, run:

```lua
dofile("<repository-root>/tests/acid/renoise_mixed_repeat_probe.lua")
```

Adjust the path to the repository checkout if needed. Wait for the terminal to
print both completed render paths. The selected instrument's phrase playback
mode is temporarily set to Selective. Each render contains one host trigger,
the eight-step cold traversal, and four steady loop periods; host retriggers do
not hide phrase timing. The song render completion callback chains the files;
an idle timeout is also installed when the script is run in a Renoise tool
context. A plain Scripting Terminal session does not provide `renoise.tool()`.

## Cases and expected observations

Phrase LPB and song LPB are both 8. Each TIME step occupies two phrase lines;
the cold traversal occupies 16 lines and the steady loop is lines 17–32, with
line 33 as the exclusive loop endpoint sentinel. At BPM 137, each eight-step
period should take about 0.88 seconds.

| WAV suffix | TIME sequence | Active PITCH span | Expected semantic playback |
| --- | --- | --- | --- |
| `tie_seam_span3` | N, T, N, R, N, T, T, T | 36, 43, 48 | Cold notes are 36, 43, 48; REST releases 43 before 48 attacks. The final 48 holds through the three trailing TIEs and remains held up to the seam. TIME01 is NOTE 36, so that new note event ends the hold and may retrigger or cut the sustained sample. PITCH restarts at P01 for each cycle. |
| `rest_seam_span2` | N, T, N, T, T, T, T, R | 40, 47 | Cold notes are 40 and 47. The final REST releases 47 before wrap; the next cycle starts with a fresh attack at 40. The active pitch cursor restarts at P01 each cycle despite only two PITCH entries. |

The first 16 phrase lines are the cold traversal and lines 17–32 encode the
steady cycle. Both use the same TIME and PITCH values, while the semantic state
at their boundary differs: the first trigger begins silent, whereas the
steady cycle inherits the final voice unless REST has cleared it. TIME01 is
NOTE in both cases, so it consumes P01 and starts a new note. Compare the
first 0.88 seconds against each later period, then compare the four steady
periods with each other for timing drift, missing notes, transient changes,
unexpected releases, and sample discontinuities.

## Recorded result

**Renoise 3.5.4, 2026-10-27:** both hand-built native phrase WAVs rendered at
137 BPM, song/phrase LPB 8, with one host trigger, an eight-step cold intro and
four steady loop periods. Across 64 mid-step pitch/silence checkpoints, both
renders had zero mismatches against the expected sequences:

- `tie_seam_span3`: `N,T,N,R,N,T,T,T`, active span 3.
- `rest_seam_span2`: `N,T,N,T,T,T,T,R`, active span 2.

This validates the tested phrase-cell schedule and pitch/silence checkpoints
for these two hand-built phrases. The probe bypasses ACID's phrase writer; it
does not validate writer-generated phrases or transaction behavior. Sample
release/cut tail at the REST and NOTE seam, acoustic voice continuity, slide,
transport stop/start, seek, and other sample mappings remain unverified. The
WAVs were rendered under the local TEMP directory and were not committed.

## Output inspection commands

In PowerShell 7, list the newest probe renders and their sizes:

```powershell
Get-ChildItem -LiteralPath $env:TEMP -Filter 'acid_mixed_repeat_*.wav' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 2 Name, Length, LastWriteTime
```

If FFmpeg is installed, inspect stream format and duration:

```powershell
Get-ChildItem -LiteralPath $env:TEMP -Filter 'acid_mixed_repeat_*.wav' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 2 -ExpandProperty FullName |
  ForEach-Object { ffprobe -v error -show_entries format=duration:stream=sample_rate,channels,bits_per_sample -of default=noprint_wrappers=1 $_ }
```

Open the WAVs in Renoise or an audio editor to inspect and listen. Use the
known event schedule and 0.88-second period to mark the cold/steady boundary
and repeat seams. Record the Renoise version, OS, BPM, source sample and loop
mode, whether the sustained 48 voice remains continuous through the seam,
whether the 40 attack follows REST, and any timing or level discontinuity.
The files prove rendered output only for the recorded environment; they do not
prove original hardware behavior.

## Expected output duration

The render range covers 80 song lines at LPB 8, or ten beats. At BPM 137 this
is approximately 4.38 seconds (plus any render endpoint convention). A short
file, silent case, or duration that differs by a full phrase period indicates
the phrase loop or host render range needs investigation before interpreting
the sound.
