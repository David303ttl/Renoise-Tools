# ACID successor-aware gate acceptance

Automated scheduling and mocked cell validation do not establish sample-envelope
behavior. Use a disposable song and the [capture preparation](renoise_articulation_probe_manual.md).
Current results use licensed Renoise 3.5.4 offline rendering on the current
desktop. All 21 authored one-shot NOTE/TIE/TIE-TIE tail, fresh-successor and
Repeat NOTE/REST and TIE/REST protocols pass at90/120/150BPM on the exact
diagnostic profile. The latest fresh batch contains36 checked WAV files: 12
unique case renders and 24 byte-identical copies; all pass, with no invalid
captures. These are deterministic offline results, not Audacity loopback or
independent soundcard captures. The older Demo/normalized-loopback observations
below remain historical; fresh passing two-TIE cases supersede earlier invalid
high-peak takes for current acceptance.

The [evidence record](audio_capture_evidence.md) is authoritative for hashes,
invalid takes, current boundaries and the separately qualified offline families.
These measurements document the former profile-scoped renderer. M3.5 removes
that runtime eligibility policy. Use the current [Gate S checklist](acid_m35_s_manual.md)
for GUI and output-policy acceptance; retain this page as a record of the
measured gate evidence.

## Authored sources and deadlines

The following oracle IDs have `_bpm_90`, `_bpm_120` and `_bpm_150` variants in
[audio_cases.json](fixtures/audio_cases.json). Coordinates are zero-based TIME
steps. All use pitch 48 without SLIDE or ACCENT; they are planned/authored and
acoustically unverified. The 10 ms tail deadline is frozen independently of the
writer; its step offset changes with BPM. Do not widen it to fit a capture.

| ID prefix | TIME | Expected attack steps | Expected OFF steps |
| --- | --- | --- | --- |
| `one_shot_note_tail` | N | 0 | 0.5 |
| `one_shot_tie_tail` | NT | 0 | 1.5 |
| `one_shot_two_ties_tail` | NTT | 0 | 2.5 |
| `tie_before_fresh_note` | NTN | 0, 2 | 1.5, 2.5 |
| `two_ties_before_fresh_note` | NTTN | 0, 3 | 2.5, 3.5 |
| `repeat_note_rest_seam` | NR | 0, 2, 4, 6 | 1, 3, 5, 7 |
| `repeat_tie_rest_seam` | NTR | 0, 3, 6, 9 | 2, 5, 8, 11 |

Repeat cases include one cold cycle and three steady cycles. Also capture the
existing `one_step_repeat` and `trailing_tie_fresh_note` cases at their authored
120 BPM to measure midpoint gates at cold-to-steady and steady-to-steady seams.
The existing `isolated_note`, `note_tie` and `note_tie_tie` cases end in REST;
their OFF belongs at the REST boundary, so they cannot substitute for the new
one-shot-tail cases. Longer 16/17/64-step seam playback and silent all-rest
synchronization remain separate native checks; existing slide-seam sources do
not qualify unconnected gate playback.

## Actual writer procedure

1. Prepare the reference instrument and capture route, run independent controls
   and calibration, and retain readback and original WAV hashes. Use the same
   declared normalization policy for controls and candidates.
2. Select ACID's tool scripting context. Set `ACID_ARTICULATION_CASE_ID` to the
   exact tempo-specific ID and set `ACID_ARTICULATION_OUTPUT_POLICY = "repeat"`
   for Repeat cases (or `"play_once"` for one-shot cases), then run
   `tests/acid/renoise_articulation_writer.lua`. Do not use the generic application
   terminal: it lacks `renoise.tool().app_idle_observable`. Wait for the generated
   status and retain its metadata/readback. A refusal is a recorded unsupported
   result; never patch around it or substitute a hand-built phrase for acceptance.
3. At the authored BPM, set host LPB 8 and TPL 12. Set
   `ACID_ARTICULATION_CAPTURE_STEPS` to source length for one-shot cases and four
   times source length for Repeat. Run `renoise_articulation_trigger.lua`; retain
   at least two seconds after host OFF. Capture the writer-selected phrase without
   editing any cells. Stop and freshly trigger between takes using the start
   helper. Record three unchanged takes for every claimed support row.
4. Align once to the first onset. Check all expected pitch/silence windows, each
   OFF-to-silence deadline, held-step absence of a new attack and every seam.
   Inspect the actual merged note/OFF/volume/effect cells against the metadata.
   Host OFF, stop/start, seek and keymapped playback require their own experiments.
5. The standard analyzer deliberately returns `unsupported` for these planned
   cases. Qualify its complete gate protocol and seeded-failure controls before
   promoting a case to ready. Never relabel a case merely to obtain a passing
   report. Record route/profile, BPM, triggering, output policy, take count, hashes,
   measured edges and remaining limitations in the evidence record before
   changing runtime eligibility.

After qualifying enabled output, manually recheck Generate/Regenerate, foreign
and modified ownership rejection, current source save/reopen, Live Edit and
undo/redo in Renoise. None of those native lifecycle checks ran in this change.

## Local verification record (2026-10-27)

- `./scripts/run_tests.ps1 -Tool ACID`: all 21 specs passed, including 1,936
  independent successor-oracle combinations, cell collision/setter rollback,
  one-shot generation/regeneration and phrase/source transaction rollback.
- `./tests/acid/test_audio_oracle.ps1`: 62 cases validated; seven malformed
  mutations rejected. `validate_loop_oracle.ps1` passed 18 semantic cases and
  all eight structural lengths.
- `./tests/acid/test_audio_analyzer.ps1` and `test_audio_normalization.ps1`:
  synthetic positive/negative controls and normalization checks passed.
- `./scripts/package.ps1 -Tool ACID`: built version 0.1 with 18 runtime files;
  archive inspection confirmed root manifest/main, module directories and no
  SDK or development files. `git diff --check` passed.

The shared validator preserves the actual rendered native volume cells across
articulation writes. Exact normal/accent quantization and captured level response
remain separate accent acceptance work; preservation alone does not verify them.
