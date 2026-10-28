# ACID — accepted audio evidence

**Policy:** existing qualified results remain accepted. Audio capture, metronome reference, WASAPI calibration and VST receiver matrices are optional defect diagnostics, not M4 closure requirements. [M4 gates](../../com.david303ttl.ACID.xrnx/ROADMAP.md#m45--closure-gates).

## M3 articulation

| Scope | Accepted result |
| --- | --- |
| NOTE/TIE/REST gates and release | 21 one-shot/Repeat protocols passed across BPM 90/120/150 on the reference sample profile |
| Moving glide and Repeat seams | Scoped sample writer playback passed |
| Accent | Scoped native sample level/retention checks passed |

Results apply to the stated reference instrument and Renoise configuration, not all receiver types.

## Phrase pitch-bend receiver check (2026-10-28)

| Scope | Accepted result |
| --- | --- |
| Renoise 3.5.4, Surge XT VST3, global instrument slot 03 | Phrase-contained M1 delivered bend and center reset with instrument/sample field empty (255) |
| PB ±12 held C→G→C | 130.82 Hz → 195.92 Hz → 130.92 Hz; +6.99 semitones, reset passed |
| Generated short C→G slide | Intermediate and endpoint bend observed |
| Sample and VST LPB 8/6 | C→G glide, REST silence and note return passed |

No general VST, hybrid or external-MIDI delivery guarantee.

## M4 phrase timing audio receipts (2026-10-28)

**Renoise 3.5.4, installed ACID writer, 48 kHz PCM24, four traversals.**

| Scope | Accepted result |
| --- | --- |
| Straight/Triplet, BPM 60/120/180, song LPB 2/3/4/6/8/12/16/32 | 48/48 passing WAVs |
| Straight 16 / Triplet 12 | Four-beat cycle |
| Straight 12 / Triplet 9 | Three-beat cycle |
| Triplet 15 | Five-beat cycle |
| Triplet 64 | 21⅓ beats, 256 expected attacks over four traversals |
| Meter and host-pattern boundaries | 3/4, 4/4 and 7/8 passed |
| Maximum measured onset error | 0.667 ms; no accumulating drift |

Source baseline: `0df7d907bc531eecb07d026bd1d98a88cff05893`. WAVs, hashes, sidecars and per-onset reports are in ignored `tmp/acid-m4-acceptance/` where retained. No recapture required for M4.

## Diagnostics

Retain the deterministic Lua regressions, audio-oracle validators and reusable targeted probes. The following are **not scheduled acceptance tasks**: loopback-route calibration, additional raw WAV captures, repeated audio-onset analysis, independent click-track measurement or broad receiver qualification. Run a targeted diagnostic only for a reproduced regression.
