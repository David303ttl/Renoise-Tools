# ACID timing — Renoise acceptance

**Status:** static timing accepted in Renoise 3.5.4. Remaining M4 gate: [instrument and phrase hardening](../../com.david303ttl.ACID.xrnx/ROADMAP.md#m47--instrumentphrase-synchronization-and-regeneration-safety-p0).

## Measured phrase-period and BPM/LPB acceptance

| Test | Result |
| --- | --- |
| Straight / Triplet, song LPB 2, 3, 4, 6, 8, 12, 16, 32 at BPM 60, 120, 180 | 48/48 offline WAVs passed |
| Straight 16 / Triplet 12 | 4-beat cycles passed |
| Straight 12 / Triplet 9 | 3-beat cycles passed |
| Triplet 15 | 5-beat cycle passed |
| Triplet 64 | 21⅓-beat cycle, 256 attacks over four traversals, passed |
| Repeat metadata | Phrase LPB 8/6, shuffle 0, two lines per step, validated loop endpoints |
| 3/4, 4/4 and 7/8 | Passed across host-pattern boundaries |
| Maximum onset deviation | ≤0.667 ms; no accumulating drift |

**Accepted configuration:** Renoise 3.5.4, ACID-installed writer, single host trigger, 48 kHz stereo PCM24, four traversals per phrase. Original WAVs, render sidecars, hashes and individual reports remain under ignored `tmp/acid-m4-acceptance/` if available.

## Targeted glide and bend playback

| Target | Result |
| --- | --- |
| Native sample, phrase LPB 8 and 6 | C→G glide, REST silence and C return passed |
| Surge XT VST3, ±12 PB, phrase LPB 8 and 6 | C→G bend, REST silence and C return passed |
| Phrase-contained M1 receiver check | Surge XT slot 03, +6.99 semitones and center reset passed |

Receiver behavior outside these setups is not certified.

## Remaining manual check

Use one disposable Renoise song after M4.7 implementation:

1. Add, rename, reorder, delete and select instruments while ACID remains open; verify synchronized target choices.
2. Select existing owned phrases and regenerate each in place; no duplicate phrase or unintended instrument/phrase selection.
3. Create one new phrase explicitly; switch instruments with Live Edit active; confirm no implicit append or stale commit.
4. Switch Program/Grid, edit, Undo/Redo, save/reopen and verify per-phrase settings and drafts.
5. During playback, check stop/start/seek and BPM/LPB changes using Straight and Triplet.

**Not required for M4:** new WAV batches, independent beat-click captures, soundcard loopback calibration, repeated onset analysis, additional VST receiver matrices or exhaustive articulation recordings. Use an existing diagnostic tool only for a reproduced defect.
