# ACID.xrnx — Detailed Development Roadmap

**Project:** ARP/SEQ / ACID.xrnx  
**Target:** Renoise 3.5+, Lua 5.1-compatible XRNX, scripting API 6.2  
**Working branch:** `develop`  
**Baseline:** merged ACID M1 + Live Edit, commit `75999f9ee01e4840199797847271ed092be6dbab`  
**Document status:** implementation plan; outstanding TB-303 hardware claims require evidence and playback verification  
**Current manifest:** `0.1` (experimental; do not increment as part of roadmap work)  
**Updated:** 2026-10-27

## 1. Product objective and scope

ACID is a lightweight, native Renoise **phrase-based acid sequencer**, not a synthesizer. Its target is to behave as close to the **original Roland TB-303 sequencer** as Renoise permits, including independent programming, repetition and NOTE/TIE/REST/SLIDE articulation. The canonical source is independent **PITCH memory** and **TIME memory**. ACID translates that source into a native instrument phrase, preserves it in song-scoped tool data, and supports manual generation and optional Live Edit. Renoise supplies transport, arrangement, phrase triggering and performance transposition.

Keep the recognizable TB-303 sequencing ideas while labeling departures explicitly:

- Original-style PITCH entries store a key, octave DOWN/NORMAL/UP, ACCENT, and SLIDE. The default key is **C**, normal octave, with ACCENT/SLIDE off.
- TIME entries are **NOTE**, **TIE**, and **REST**. NOTE consumes one pitch entry; TIE and REST do not. Consecutive time and pitch positions are *not* interchangeable.
- **LAST STEP = 1–64** is an ACID extension. Pages 01–16, 17–32, 33–48, and 49–64 belong to **one continuous sequence**, not four independent 16-step patterns.
- Prioritize original behavior in new drafts; expose independent short PITCH-span cycling and longer patterns as explicit **Extended** functions under the same new interpreter. Both modes follow Roland's leading-TIE normalization and outgoing-SLIDE rules.
- ACID must never describe experimental native-sample glide, gate, velocity, or filter behavior as acoustically identical to a TB-303 without measurements.
- No embedded DSP synth, mandatory VST, arbitrary MIDI-effect rack, or redesign of ARP.xrnx is part of this roadmap.

**Extended expansion scope:** retain the established 64-step storage/direct-grid
and explicit PITCH-span design. The only additional OS-303-inspired sequencer
expansions are independent PITCH/TIME randomization, targeted source transformations
and a non-destructive scale mask. Do not add ACID performance transpose, pattern
queues/chains, half/double length shortcuts or recording against the playback
cursor; those workflows belong to Renoise. Existing Live Edit remains source
editing followed by guarded phrase regeneration, not a new performance engine.

**Clean WIP cutover:** earlier ACID implementations are development iterations.
There is no user-base requirement to preserve their behavior or saved formats.
Replace superseded source schemas, interpreters and ownership seals directly;
add no backward compatibility, migration shims, importers or historical behavior
modes. Retain Extended musical functions. Test patterns from earlier iterations
may be recreated. Ownership checks, write preflight and rollback continue to
protect current-format ACID content and unrelated Renoise song data.

The [design contract](DESIGN.md) defines architecture and unresolved fidelity issues. This file defines **sequence, deliverables, acceptance gates, and verification**. When a historical detail is uncertain, maintain a research/test item; do not convert an assumption into a guarantee.

The [second-pass reference record](M2_BLUEPRINT.md#24-original-roland-reference-checked-in-the-second-pass)
identifies the April 1982 Roland manual, checksum, printed pages and R01–R04
observations. Original documentation outranks replacement firmware. The proposed
Original entry mode is a supported programming subset; full fidelity also needs
M3 articulation, M4 triplets and M5 source programming/Renoise integration. An extended
source does not become original-compatible merely because it has 16 steps.

## 2. Baseline: implemented versus not yet proven

### M1 — Native 64-step editor and phrase integration: completed

Implemented on `develop`:

| Area | Delivered |
| --- | --- |
| Memory | Independent PITCH/TIME model; 64 stored pitch positions initialized to C; LAST STEP 1–64 |
| Editor | Four 16-step pages, PITCH controls and TIME NOTE/TIE/REST selectors, decoded preview, highlighted selection and diagnostics |
| Phrasing | Pattrns-based render to regular native instrument phrase; baseline and experimental retrigger/gate/slide modes |
| Destination | Select an existing ACID-owned phrase or append a new phrase to a chosen instrument |
| Persistence | Original source snapshots via song-scoped `tool_data`, associated with sealed phrase IDs |
| Protection | Ownership checks, temporary render, guarded replacement and rollback attempts |
| Live Edit | Opt-in debounced (350 ms), serialized automatic regeneration; manual Generate/Regenerate retained |
| Verification | User-confirmed local Lua regressions and in-Renoise testing for M1, phrase selection/persistence, and Live Edit |

**Do not infer from the M1 baseline** that repeat playback, authentic slide envelopes, timing feel, or release characteristics are complete. M2 provides baseline Repeat phrase generation and has passed the recorded pitch/grid renders plus the available writer-cell, Live Edit, ownership, and source-persistence checks. Additional acoustic acceptance remains unverified; M3 will first qualify a Demo-compatible loopback path. `0Gxx` and gate behavior remain experimental.

### Important model debt to address in M2

The current source stores **64 valid C pitches** and carries an independent active span; a new pattern defaults to a 16-entry span in Original mode. This is a storage default, **not proof that every pattern cycles through 64 pitches**. The M2 interpreter resets pitch consumption at each TIME cycle; this is an ACID rule, not measured original CPU behavior.

## 3. Priorities and dependency map

| Order | Milestone | User-visible result | Dependency |
| --- | --- | --- | --- |
| Completed | M1 — Editable source, phrase output and Live Edit | Edit ACID patterns and regenerate native phrases | — |
| Completed (implementation) | **M2 — Continuous sequence and loop correctness** | Reliable repeated patterns and deterministically consumed pitches | M1 |
| Next | **M3 — Articulation and native sample fidelity** | Predictable gate, selective slide and accent behavior | M2 semantic contracts |
| Next | **M4 — Timing modes and tempo robustness** | Straight/triplet programming and stable timing | M2 + gate-placement decisions |
| Required for fidelity | **M5 — Source programming and Renoise workflow** | Separate step-entry/check workflow, source management and scoped Extended editing | M2; stable persistence |
| Final | **M6 — Stability, documentation and release** | Testable, packaged, supportable ACID tool | M2–M5 |

**Milestone completion** normally requires deterministic Lua checks and targeted Renoise verification for rendered notes, audio, GUI, phrases, persistence, or undo. If a user accepts deferring a check, record the scope decision and keep the deferred claim explicitly unverified; a passing mock test alone is not an audio conformance result.

---

## 4. M2 — Continuous playback and loop correctness

**Goal:** a phrase repeats predictably over successive cycles, including PITCH consumption and NOTE/TIE/REST behavior at the last-to-first boundary. The implementation and structural acceptance are closed; additional audio-level acceptance remains unverified and is carried into the M3 loopback harness.

**Status (2026-10-27):** M2 implementation closed by user decision after code/spec coverage and available Renoise 3.5.4 Demo checks. This status does not claim sample-envelope fidelity or complete acoustic acceptance. See the [manual results](../tests/acid/acid_loop_manual.md), [Live Edit results](../tests/acid/acid_live_edit_manual.md), and [regeneration results](../tests/acid/acid_regeneration_manual.md). **Do not treat `looping = true` alone as evidence of audio behavior.**

**Implementation and verification record:** [M2 blueprint](M2_BLUEPRINT.md), checked against original Roland documentation, the pinned OS-303 firmware and current ACID code. It defines Original/Extended entry, the cursor/voice contract, logical PITCH span, source/seal cutover, native-loop experiments, safety work and acceptance fixtures. Renoise Demo disabled new offline WAV rendering; release/cut-tail, voice-continuity, transport, keymapped-trigger, and remaining lifecycle checks are documented as deferred follow-up. M3 qualifies loopback capture for the relevant audio checks; this does not retroactively pass them. No hardware fidelity is implied.

### M2.0 — Define the conformance oracle

**Work**

- Use R01–R04 as operator-level evidence. Keep original CPU traces/measurements, replacement-firmware behavior and proposed software rules distinct; document any disagreement.
- Specify **Original entry** and **Extended entry**, including bounds and leading-TIE normalization. Mark active PITCH wrap, initialization and cursor rules as provisional where original evidence is absent. Do not infer fidelity from length alone.
- Define “initial trigger”, “subsequent loop”, “leading TIE”, “trailing TIE”, “ending REST”, and “next NOTE” in the semantic compiler.
- Decide what happens when the number of NOTE commands differs from the logical pitch sequence length. Test this explicitly rather than deriving behavior from allocated array size.

**Deliverable:** `docs`/design decision notes or a focused M2 semantics document, plus machine-readable fixture descriptions.

**Gate:** each ambiguous rule has a documented chosen behavior and test expectation; any claim of hardware fidelity is supported or marked unresolved.

The conformance decisions are recorded in [M2_SEMANTICS.md](M2_SEMANTICS.md),
with three-cycle expectations in [loop_cases.json](../tests/acid/fixtures/loop_cases.json).
The pure cycle interpreter is covered against those expectations. Native phrase
playback is documented separately and remains subject to its manual gates.

### M2.1 — Model deterministic repeating TIME/PITCH cycles

**Work**

- Add a pure-Lua multi-cycle traversal or an equivalent state-transition representation that can be tested for 2+ consecutive iterations.
- Preserve independent TIME cursor, logical PITCH cursor, current note, previous SLIDE state, and current gate/hold state.
- Do **not** reset or silently wrap at the boundaries between 16-step UI pages.
- Distinguish first playback (starts silent) from continuous repetition (may inherit a sounding voice).
- Keep NOTE/TIE/REST and octave flags intact for all lengths 1–64.

**Likely modules:** `model/sequencer.lua`, `model/compiler.lua`, possibly a new `model/loop_state.lua`.

**Acceptance tests:** explicit 1, 16, 17, 32, 33, 48, 49, and 64-step patterns; NOTE-TIE-NOTE; NOTE-REST-NOTE; all-rest; all-note; leading-TIE entry normalized to NOTE in both modes; loop ending in REST and loop ending in held note. Assert events for at least **three cycles**, including pitch indices and transitions.

The pure cycle interpreter and three-cycle fixture tests are implemented and
integrated with the current source/editor. Phrase generation and playback
verification are tracked under M2.3–M2.5.

### M2.2 — Separate logical pitch length from 64 stored defaults

**Work**

- Represent **PITCH memory capacity (64)** separately from **the number of pitches in the playback sequence**, once the hardware-inspired cursor rule is settled.
- Preserve untouched C entries as valid entries; “not edited” must never mean “invalid note”.
- Determine how users explicitly choose/derive the active PITCH sequence span without turning TIME steps into pitch-index assignments.
- Persist `entry_mode=original|extended`. New Original drafts use TIME length 16, active PITCH span 16 and 64 stored C entries; span selection belongs to Extended. This span/default policy is an ACID choice, not a claim about original cleared memory.
- Both entry modes convert TIME 01 TIE to NOTE before preview/compile (R03), consuming P01. Raw leading-TIE source is invalid in either mode; do not rewrite it during compilation or loading. Mode changes are explicit draft edits and cannot silently shorten a longer source.
- Evaluate how loop restart and pitch wrap interact if, for example, 12 TIME steps contain five NOTE commands while only three PITCH entries belong to the active pitch stream.
- Replace `ACID-PITCH-TIME-1` with the new source format. Remove its decoder and any historical semantics selectors, compatibility labels or import/adoption paths. Earlier development patterns are unsupported and may be recreated; current-format save/load must be exact.

**Acceptance tests:** entered T01 becomes NOTE and consumes P01 in both modes; raw leading-TIE source is rejected in both; fewer/more PITCH entries than NOTE triggers in Extended; full-C and inactive storage roundtrip in the current format; earlier development formats unsupported; stable preview and explicit entry-mode changes.

The current source, editor and persistence use these fields and the shared
cycle interpreter. Automated coverage rejects old development source formats
and seals. A current-format Extended source/seal save/reopen case and an
Original-mode Renoise save/reopen case both passed. Full field-by-field GUI
coverage and in-Renoise rejection of earlier formats/seals were not checked.

### M2.3 — Resolve loop-boundary TIE, REST and SLIDE

**Work**

- Encode the exit state of a cycle and how it is consumed at the next cycle's first NOTE/TIE/REST.
- TIE holds the previous note if a valid held voice exists; TIE never advances the PITCH cursor.
- REST ends the sounding note; the next NOTE is a fresh attack regardless of previous SLIDE intention.
- Slide should be attached to the appropriate transition, including same-pitch slide cases, but the semantic compiler must not assume Renoise `0Gxx` achieves envelope-continuous legato.
- Test the first NOTE on cold start versus repetition: it attacks initially and receives an outgoing SLIDE from the final held pitch on repeat. Equal pitches form a tied connection; a leading REST breaks it (R02/R03).
- Keep same-pitch slide as a connected transition with no new attack when supported; verify it independently of pitch movement. Extended retains this Roland behavior and does not permit literal leading TIE.

**Deliverable:** fully specified semantic boundary state plus diagnostics if the selected phrase representation cannot render the requested transition faithfully.

The semantic interpreter and baseline Repeat planner implement cold/repeated
NOTE/TIE/REST boundaries. Repeat slide transitions are currently refused;
native slide continuity remains unverified.

### M2.4 — Native looping phrase output

**Work**

- Keep the baseline Repeat path loop-capable and guarded; refuse unsupported cases rather than substituting articulation.
- Confirm phrase looping, LPB, note-off placement, early release, and Renoise's treatment of a note sustained over the phrase boundary.
- Test sustained selective phrase triggering separately from fresh trigger, note release, stop/start and seek. Phrase mappings have separate loop/key-tracking properties; keymapped playback requires its own evidence before support is claimed.
- If Renoise cannot preserve the required held voice or selective glide at a native phrase restart, do not silently fake it: isolate a documented fallback/limitation, or render a verified repeated segment when musically equivalent.
- Retain guarded temporary rendering, phrase ownership seals, live-regeneration serialization, destination selection and per-phrase source persistence.
- Ensure changing LAST STEP does not leave obsolete generated lines or stale ownership state.

**Likely modules:** `writers/phrase_writer.lua`, `writers/pattrns_writer.lua`, `writers/phrase_validator.lua` and articulation boundary handling.

**Recorded audio acceptance:** the ACID writer's baseline output for lengths 1/16/17/32/33/48/49/64 matched the sampled pitch/silence grid over three cycles. 16-to-17, 32-to-33 and 48-to-49 are page boundaries, **not musical resets**. Sample-release, voice-continuity, transport and other lifecycle checks are deferred follow-up.

The Renoise 3.5.4 WAV probe verified loop endpoint behavior and grid/pitch
markers at all eight required lengths for the recorded test instrument. Two
hand-built native mixed-event phrases also passed recorded pitch/silence
checkpoints over four steady periods. ACID's writer-generated Repeat phrases
then passed 780 sampled mid-step pitch/silence checkpoints across three cycles
at lengths 1, 16, 17, 32, 33, 48, 49 and 64, with source save/load and loop
metadata checks. Sample release/cut tail, native voice continuity, slide,
transport stop/start, seek and undo remain deferred audio or lifecycle checks.

Renoise 3.5.4 Demo checks on 2026-10-27 verified writer-generated NOTE/TIE/REST
cells around 16/17, 32/33 and 48/49 in both intro and loop regions, including
the 257-line phrase and loop endpoints. LAST STEP and active PITCH span changes
through 64→17→1→64 resized the same phrase with Live Edit on; with Live Edit off,
manual Generate performed the pending resize. Original-mode source/seal
save/reopen and regeneration passed. Loop start, loop end, and effect mutations
caused ownership refusal; song changes invalidated the open editor until
reopened. A 64-step all-REST source also produced
the expected empty 257-line phrase and passed source/ownership checks. The GUI
opened an existing 64-step Extended/span-3 Repeat source and regenerated its
owned phrase. One Live Edit change on a 16-step Extended/span-3 Repeat phrase
also regenerated TIME02 TIE→REST and passed saved-source, cold/repeating OFF,
and ownership checks. Rapid/in-flight edits, disable/close races and
dialog/notifier lifecycle remain untested. A fresh trigger after host NOTE OFF
matched the first six TIME events on one 16-step Repeat source. Renoise Demo
blocked a new WAV render, so no audio result is claimed for the 2026-10-27
checks. Rapid/in-flight edits, disable/close races, rollback failure injection,
undo, and in-Renoise cutover checks remain unverified. See the
[repeat record](../tests/acid/acid_loop_manual.md),
[Live Edit record](../tests/acid/acid_live_edit_manual.md), and
[regeneration record](../tests/acid/acid_regeneration_manual.md).

### M2.5 — Regressions and closure record

The verification matrix was:

- Triple-cycle event equality/continuity under the chosen cursor policy.
- Long patterns with TIE/REST and slide at steps 16/17, 32/33, 48/49, 64/1.
- Changes to LAST STEP and logical PITCH length while Live Edit is ON and OFF.
- New phrase, regeneration of an owned phrase, and refusal of foreign/modified phrases.
- Save/reopen/reload of current-format patterns and all new source fields; earlier source formats and seals confer no load/ownership support.
- No leftover temporary phrases, broken ownership seals, or changed non-ACID content on a failed render.

**M2 implementation closure (2026-10-27):** the 64-step interpreter, Original
and Extended source behavior, clean current-format cutover, guarded Repeat
writer, and source/phrase transaction path are implemented and spec-covered.
Available Renoise verification confirmed writer cells at all three page seams,
Live Edit line cleanup with the requested LAST STEP/span changes, refusal after
loop/effect edits, stale-song invalidation, and Original-mode save/reopen. The
previously recorded WAV checks cover grid periods and sampled pitch/silence;
Demo-specific rendering limits prevent additional audio verification now.

M2 is closed as an implementation milestone by user decision. Release/cut-tail,
held-voice continuity, cold-versus-steady articulation, request-level slide
refusal, transport stop/start/seek, and keymapped triggering remain explicitly
unverified; M3 first qualifies loopback capture for its relevant audio checks. Undo, failure injection, rapid
in-flight edits, and manual rejection of earlier formats/seals are also not
claimed as passed. Passing M2 does not complete the original sequencer goal or
establish TB-303 sound fidelity; M3–M5 requirements remain.

---

## 5. M3 — Gate, accent and selective glide fidelity

**Goal:** translate semantic articulation into predictable native-sample playback. Pitch movement alone does not establish envelope continuity. M2's source traversal, outgoing SLIDE, REST interruption, cold/steady distinction and exclusive loop-end sentinel remain authoritative.

**Status:** planning only; no new audio acceptance is claimed. M2 implementation remains closed. Its deferred release, continuity and trigger checks become explicit M3 prerequisites where relevant; undo and lifecycle work outside this scope remains tracked for M6. Historical gate duration and analog accent response remain unverified.

### M3.0 — Decisions, boundaries and blockers

| Decision | Implementation contract |
| --- | --- |
| Native gate profile | For articulated modes, adopt 50% of the final held step as an explicit provisional ACID profile, not a measured TB-303 value. Replace the accidental test-only behavior with a complete cyclic scheduler; no new gate control or hardware claim. |
| Timing | Straight sixteenths only: phrase LPB 8, two lines per step, song TPL 12 for the reference captures. One step is 15000/BPM ms; one line is 7500/BPM ms. No delay-column or tick commands in M3. Reject other output grids rather than round; rational/triplet conversion belongs to M4. |
| Gate and glide independence | Gate work may proceed if the glide experiment fails. Slide-connected cases retain precise refusals until verified; no fallback to a fresh attack. |
| Instrument boundary | Runtime generation never changes the user's sample, NNA, modulation, routing or Mono/Glide settings. A measured reference profile is a support prerequisite, not a promise for arbitrary instruments. |
| Existing modes | Keep Baseline as the structural reference without claiming calibrated gates. Retrigger + Gate implements the gate profile and refuses connected slides it cannot render. Selective Slide + Gate combines verified gate/glide behavior. Do not promote experimental Mono to a distinct verified strategy while it uses the same local effect path. |
| Defaults | Repeat remains the new-source default. Do not silently change renderer defaults or persisted settings; enabling a verified path must be explicit and covered by manual and Live Edit tests. |

**Named blockers:** `writers/phrase_writer.lua` currently refuses every Repeat slide and every non-baseline Repeat mode. `model/control_signals.lua` only emits early OFF when it later sees a fresh NOTE: final held steps and the steady-to-steady seam lack successor scheduling. `model/articulation.lua` defaults to `0x02`, while the writer supplies `0x20`; these must become one explicit renderer policy. `renoise/sampler_audit.lua` reports counts only; it is not an instrument builder or a profile validator.

**Order:** harness and calibration → isolated voice-continuity experiment (research item 3) → gate implementation and glide decision → supported glide integration → accent → acceptance record. Run the continuity experiment before investing in glide integration; gate implementation does not depend on its success.

### M3.1 — Establish a repeatable audio reference harness

**Implementation record (2026-10-27):** the development probe, tempo-aware
trigger/start helpers, actual-writer capture/read-back helper, strict oracle
validation, offline analyzer and normalization/provenance tests are implemented.
See [articulation verification](../tests/acid/acid_articulation_manual.md) and
[capture evidence](../tests/acid/audio_capture_evidence.md). The oracle contains
seven executable independent protocols and 34 planned writer cases with
authored deterministic semantic windows and explicit native-dependent
qualification blockers. This does not pass the acoustic exit gate. Raw desktop
grid calibration passed again; held/retrigger/0G20 controls were recorded, with
raw control analyses invalid. User-authorized normalized-copy recalibration
exposes failed silence windows, so downstream native acceptance remains blocked.
No renderer support or manifest version changed.

**Development deliverables** (outside the installable tool):

- `tests/acid/renoise_articulation_probe.lua`, `renoise_articulation_trigger.lua`, `renoise_articulation_start.lua`, `renoise_articulation_flat_control.lua`, `renoise_articulation_probe_envelope.lua` and `renoise_articulation_probe_manual.md`: create a disposable named instrument, controlled phrases and a dedicated song-pattern host trigger, start the exact selected sequence position for capture, toggle a flat-envelope pitch/level control and the diagnostic envelope, reuse the safety conventions of the loop probes, and capture the actual ACID writer output as well as independent native controls. Refuse duplicate named probe objects; clean up only objects created by this run. Keep the existing sampler inspection read-only.
- `tests/acid/fixtures/audio_cases.json`: authored, machine-readable acoustic oracle, separate from `loop_cases.json` semantic expectations.
- `tests/acid/validate_audio_oracle.ps1`: validate schema, units, windows, references and case completeness without Renoise or WAVs.
- `tests/acid/analyze_articulation_audio.ps1`: PowerShell 7 offline WAV analyzer with documented PCM decoding, alignment, RMS, onset and pitch algorithms; emit machine-readable results and a readable per-window report. No private application or audio-library dependency. Tests must include synthetic known-good signals and deliberate onset, drift, pitch, gap, clipping and retrigger failures; do not validate it only against ACID output.
- `tests/acid/acid_articulation_manual.md`: configuration, evidence index, support matrix, negative results and unresolved decisions. Raw WAVs and scratch reports stay untracked; record SHA-256 hashes and portable artifact references so a retained capture can be checked again.

**Reference instrument contract:** the probe builds the sample and profile; hand-built alternatives do not count until all settings match. Generate one deterministic 168-frame mono saw cycle at 44100 Hz, loop forward over the entire cycle, root note 48, mapping 0–119, no transpose/finetune, fixed interpolation and no sample FX, filter, randomization, velocity-to-filter or pitch modulation. Use linear interpolation and record the generated sample hash. Derive expected frequency from 44100/168 Hz at note 48 and the mapped semitone ratio, not equal-tempered C: this sample is approximately six cents sharp. Use NNA Cut, normal polyphonic playback and explicit OFF; compare native Mono/Glide only on a separate disposable variant. Set gain for captured peaks below -6 dBFS. Use a diagnostic amplitude envelope with 10 ms linear attack, 20 ms decay to 0.65 sustain, and 5 ms release after OFF. Disable envelope looping and all other modulation. This attack/decay signature makes a repeated envelope detectable. Measure the actual realized envelope: if Renoise's available envelope time base cannot express these values, stop, inspect the pinned API 6.2 definitions/offline docs, and record a representable profile and revised oracle before capturing acceptance. Never silently approximate it. Use a flat-envelope companion control to isolate pitch and level analysis. Record all mappings, envelope points/time base, gains, NNA, interpolation, modulation routing and trigger settings in the capture metadata.

**Demo-compatible capture protocol:**

1. Use Renoise WASAPI in shared mode and Audacity Windows WASAPI loopback on the exact same playback endpoint. This desktop exposes 48000 Hz for that endpoint through WASAPI; set Renoise, the Audacity project and export to 48000 Hz without resampling. Export unnormalized PCM24 WAV (PCM16 is accepted when PCM24 is unavailable). Keep the Windows system volume unchanged. Disable OS enhancements, spatial processing, auto gain, recorder effects and monitoring feedback. Mute other applications and unrelated Renoise tracks. OBS is an alternative only after its unprocessed lossless PCM path passes the same calibration; lossy capture is invalid.
2. Record the Renoise build/edition, capture application/version, endpoint, driver, buffer size, BPM, song LPB/TPL, phrase LPB/layout, trigger mode and profile hash. Start recording at least one second before a single sustained host trigger. The probe trigger pattern is 224 lines (14 seconds), with its only note at line 1 and OFF at line 137; the 8.5-second phrase contains one cold pass and three steady passes. Capture at least two seconds beyond OFF, then stop before the song sequence wraps and retriggers. Do not periodically retrigger the host note.
3. Run primary cases at 120 BPM, repeat gate/glide acceptance at 90 and 150 BPM. Timing derives from BPM, never recorder start time. Align once to the first detected onset; preserve all subsequent offsets. Do not align each cycle independently or time-stretch/resample to hide drift. All-rest cases require an independently captured synchronization marker followed by the measured silent region; do not infer their origin from silence.
4. Before any A/B result counts, capture a known M2 grid/marker case from `loop_cases.json` through this exact path (17-step cold intro plus three steady 17-step cycles, with line 69 as the exclusive-end sentinel). Author its expected marker pitches/positions in the audio oracle. Require correct order, no missing/extra markers and every onset/period within 5 ms after single alignment. Freeze the -60 dBFS onset floor against the live route and synthetic positive/negative controls. The user permits explicit normalized analysis copies: retain originals, record source/output hashes and applied gain, and rerun calibration and controls under the same gain policy; never silently normalize a failing candidate. Optional mono averaging must be explicit in its receipt and qualifies a separate mono analysis path. Keep Windows volume unchanged. Repeat calibration after changing endpoint, driver, profile or capture settings. Demo's disabled offline render is not a blocker for this protocol; an available offline renderer is an optional cross-check, not a replacement for loopback calibration.
5. Capture each A/B pair three times with unchanged configuration. Reject clipping, channel mismatch, contamination, missing tail, failed calibration or excess drift as invalid capture. Keep invalid distinct from acoustic fail and unsupported; no invalid result counts as pass.

**Oracle contract:** use schema identifier `ACID-AUDIO-ORACLE-1` with shared profile and capture requirements. Each case has a stable behavior-based ID, canonical source (PITCH/TIME, active span, length), playback/renderer/rate, BPM/LPB/TPL, trigger context, cycle count and explicit expected windows relative to the aligned origin. Store times in step fractions or milliseconds with declared units; expand them independently from the runtime scheduler. Specify expected attacks and forbidden-attack windows, OFF edges and release-tail deadlines, sustained/silent windows, pitch targets in Renoise note values with cents tolerances, glide direction/settling windows, and amplitude/continuity bounds. Distinguish cold, first steady and subsequent steady windows. Include separate A/B control IDs and the measurement each control validates. Expectations may not be generated by the code being tested.

**Initial numerical acceptance policy:** onset and release-envelope edge tolerance ±5 ms; cycle drift at most 5 ms over the full capture after one alignment; stable pitch within ±15 cents in windows of at least 40 ms; silence RMS below -60 dBFS after the 5 ms release plus 5 ms tolerance. Analyze continuity/release RMS over 5 ms windows with 1 ms hops, and onsets over 10 ms windows to suppress low-pitch saw-cycle dips; require at least 20 ms of silence where a gap is expected. A requested attack must match the calibrated attack/decay signature; calibrate detection with deliberate retriggers, same-pitch holds and a silent negative control. For connected transitions, forbid that attack signature within ±20 ms of the target and forbid a dip greater than 6 dB lasting 4 ms relative to adjacent sustained RMS. Compare pitch-dependent RMS against the matching hold control, not raw waveform discontinuities. Ambiguous pitch/attack estimates are inconclusive and block support; passing continuity measures establishes observable behavior for this profile, not proof of Renoise's internal voice identity. Freeze detector thresholds against positive/negative controls before evaluating candidates; any revision requires rationale and rerunning all affected captures, never tuning only a failing candidate.

**Required fixture families:** isolated NOTE; NOTE-TIE and NOTE-TIE-TIE; adjacent equal/different NOTES; NOTE-REST-NOTE; all-rest; ending REST; trailing TIE before fresh NOTE and before slide; one-step repeat; outgoing versus incoming flags; same-note/up/down/octave slides; short and tied-long slides; cold-to-steady and steady-to-steady slide seams; slide interrupted by REST; accents on/off, consecutive accents, accent changes within a slide chain. Exercise lengths 1/16/17/32/33/48/49/64 structurally and capture 1/16/17/64 with seam articulation. Test host OFF, fresh retrigger, stop/start and seek separately. Selective and keymapped triggering have separate support rows; coverage in one never enables the other.

### M3.2 — Correct gate and release semantics

**Chosen profile:** an isolated unconnected NOTE gates for half a step. A following TIE keeps the gate high through the preceding step; release occurs halfway through the final held NOTE/TIE step before a fresh NOTE. Thus NOTE-TIE lasts 1.5 steps and NOTE-TIE-TIE lasts 2.5 steps before a fresh attack. The resulting retrigger gap is half a step (62.5 ms at 120 BPM). A following REST overrides midpoint release and emits OFF exactly at the REST's start. A connected slide holds through the target without OFF. An outgoing flag with no next NOTE never creates a target or bypasses REST.

**Boundary policy:** evaluate the actual successor, not just the flattened cold+steady array. In Repeat, trailing TIE holds into an outgoing slide, releases at the final held-step midpoint before an unconnected first NOTE, or releases at the next REST boundary. Handle cold→steady and steady→steady explicitly. In one-shot, a final unconnected NOTE/TIE releases at its final held-step midpoint; an outgoing SLIDE with no successor does not sustain indefinitely. Do not write into the exclusive-end sentinel, add an unconditional end OFF or change the M2 pitch cursor contract. Host OFF/transport behavior is measured separately from scheduled releases.

**Module map:** `model/control_signals.lua` owns pure gate edges in existing 256-units-per-step coordinates with explicit successor/playback context; `writers/gate_writer.lua` maps exact supported edges to cells; `writers/phrase_validator.lua` validates the complete merged note/OFF/effect/volume plan and rejects unexpected delay, panning, instrument and cut-command data; `writers/phrase_writer.lua` supplies cold/steady context, preflights support and commits only after validation. Keep semantic voice intent separate from physical gate state. Use a shared operation plan so gate and glide cannot independently overwrite each other.

**Collision rules:** preflight all operations before mutation. Refuse missing cells, occupied note/delay/effect fields, nonrepresentable edges and contradictory OFF/target operations with TIME step, cycle and zero-based phrase-line diagnostics. Optional G00 may be omitted on OFF only if the probe verifies that omission; never silently drop a required operation. Preserve owned-phrase validation, temporary rendering, rollback, source commit and Live Edit serialization.

**Gate:** pure specs cover every successor combination, one-shot tail and both Repeat seams, including 1-step/all-rest cases; writer/validator tests cover collisions and failure rollback. Calibrated captures verify gate widths, tail deadlines and no extra attack. Enable Repeat gate mode only for its passing matrix; retain refusal for slide-bearing cases pending M3.3.

### M3.3 — Selective glide without accidental retrigger

**Experiment first:** on independent native phrases compare a deliberate retrigger, TIE hold, local target `0Gxx` plus following `0G00`, and a disposable native Mono/Glide alternative. Keep the diagnostic envelope and control pitches identical. Establish whether target notes restart the envelope, whether effects persist beyond their intended window, and whether the existing G00 interpretation actually works. No instrument-wide strategy may introduce glide on unflagged transitions.

**Rate policy:** `0x20` is the provisional writer rate; remove the inconsistent helper default when implementing. Treat it as a Renoise command amount, not a claimed duration in milliseconds. Sweep `0x08`, `0x20`, `0x40` in the experiment at 90/120/150 BPM; author per-rate settling windows from the native control evidence before integrating the writer. Require monotonic movement in the intended direction (within pitch-estimator tolerance) and target ±15 cents for at least 40 ms before the next required pitch change. Same-pitch connection requires continuity without a pitch excursion. If `0x20` cannot pass the declared short/octave cases, record a new single default or explicit supported interval/duration limits before integration; do not select a hidden rate per failing case. No UI rate feature is required.

**Refusal relaxation:** replace the blanket Repeat refusal only for the exact renderer/profile/trigger/rate/interval-duration classes whose independent controls and actual writer captures pass. Require cold attack, cold→steady connection, at least three steady cycles including steady→steady connection, same-pitch, both directions, octave, TIE extension, REST interruption, effect cancellation and no detected overlapping tail under the declared analysis and listening checks. A mixed WAV alone does not prove internal voice count. Repeat default must be exercised through normal Generate and Live Edit, not only a probe bypass. A non-baseline-mode pass does not establish slide support, and a one-shot glide pass does not establish Repeat support. Unsupported cases retain pre-mutation diagnostics identifying mode, TIME step, cycle, phrase line and missing evidence. Do not encode support as an unchecked global boolean or infer a profile from sample count alone; profile-dependent eligibility must be checked read-only or explicitly acknowledged through a documented setup workflow before enabling it.

**Fallback decision:** if no native method passes, retain precise refusals, publish the failed measurements and mark selective glide blocked. Gate/accent work can merge independently, but M3's full articulation goal remains incomplete unless the user explicitly accepts a reduced scope. Do not claim completion while every default Repeat slide is rejected.

**Modules:** `model/articulation.lua`, `writers/phrase_writer.lua`, `writers/phrase_validator.lua`, the shared gate operation plan, and read-only profile checking where necessary. Preserve outgoing PITCH ownership, same-pitch connection and REST cancellation from the M2 interpreter; do not modify semantics to fit a failing renderer.

### M3.4 — Accent response

Retain PITCH-owned ACCENT and provisional event volumes **0.7 normal / 1.0 accent** in `writers/pattrns_writer.lua`. Add volume expectations to the final phrase validator; verify the emitted native values and captured response independently. On the flat-envelope, fixed-gain reference, compare equal-pitch settled windows: predict the level ratio from actual emitted/quantized volume cells, require measured delta within ±0.5 dB of that ratio and spread across three captures at most 0.5 dB. Do not assume the abstract 0.7 value maps linearly without checking the cells and response.

Test alternating/consecutive accents, TIE retention, and accents entering/leaving slide chains using level-matched hold controls for continuity detection. Determine whether volume changes on a connected target apply without restarting the envelope; if not, refuse or clearly mark that combination unsupported rather than inventing accent accumulation. Filter-envelope emulation, analog accent decay and automatic edits to existing instruments remain outside M3 scope. Update UI/help limitations for the actual verified profile.

### M3 implementation packages and merge gates

| Package | Scope / suggested commit | Exit gate |
| --- | --- | --- |
| M3-A | `test(acid): add calibrated articulation audio harness` | Probe/profile, oracle schema and authored cases, analyzer positive/negative tests, Demo loopback calibration and independent continuity experiment recorded; any profile/API uncertainty resolved before downstream audio acceptance |
| M3-B | `fix(acid): schedule cyclic gate releases` | Full successor-aware model and shared operation validation, local specs, calibrated one-shot/Repeat gate captures; retain glide refusals |
| M3-C | `feat(acid): enable verified selective glide playback` | Native strategy/rate decision and evidence matrix; actual writer passes, scoped refusals relaxed, default Repeat Generate/Live Edit checked; if blocked, record evidence instead of claiming feature delivery |
| M3-D | `fix(acid): verify pitch-owned accent response` | Native volume validation, repeated captured level delta, explicit connected-accent support decision |
| M3-E | `docs(acid): record articulation support and limitations` | Manual results, support matrix, DESIGN/README/current instructions agree; regression and package checks complete where required |

Each behavior PR includes its specs, procedure and actual results; records are updated as evidence arrives, not postponed until the last package. Inspect relevant pinned API 6.2 definitions and offline docs before writing probe/profile or runtime API calls; SDK setup is a development prerequisite. Keep new code/fixture names behavior-based and all runtime dependencies inside ACID. No manifest/API bump or schema migration is implied.

**Merge and completion gates:** run `./scripts/run_tests.ps1 -Tool ACID` after Lua changes; run all suites if shared scripts change and `./scripts/package.ps1 -Tool ACID` for runtime layout/package-input changes. Recheck normal regeneration, ownership rejection, source save/reopen and Live Edit for enabled modes. Record which tests ran, which captures passed, which trigger/profile combinations are supported and which remain unverified. Documentation/probe infrastructure may merge before acoustic support is established; renderer support cannot be enabled on mock tests alone. Full M3 acceptance requires verified gate, connected Repeat slide and repeatable accent behavior for the declared reference profile, or an explicit user-approved reduced scope with the missing goal still visible.

---

## 6. M4 — Rhythmic fidelity and timing modes

**Goal:** correctly represent the time base, especially TB-303-style triplet programming, with an explicit stored grid for straight and triplet patterns.

### M4.1 — Research and define timing modes

- Use R04 for the original grid and limits; retain the printed-page reference rather than treating the firmware's unfinished triplet toggle as an oracle. This scope adds no ACID swing controls.
- Define supported straight and triplet grids, musical duration, UI labels, and how LAST STEP applies.
- Original timing: straight step = 1/4 quarter-note beat, triplet step = 1/3 beat; a four-beat cycle uses 16 or 12 steps respectively. Original triplet length is 1–15; any larger triplet source is Extended. Derive musical positions rationally before mapping to phrase lines.
- Separate the **semantic event timeline** from Renoise phrase LPB, line counts and note-delay resolution.

### M4.2 — Deterministic timing conversion

- Implement a timing compiler that emits rational musical positions or a fixed high-resolution tick representation without cumulative rounding drift.
- Choose LPB/phrase lengths/delays based on representability; reject impossible mappings with precise step/line diagnostics.
- Reuse the M3 gate/articulation timeline so timing modes do not destroy note lengths or selective glide.
- Persist an explicit timing mode with the source snapshot and validate it. Revise the WIP format directly when adding the field; do not infer timing from or migrate earlier development records.

### M4.3 — Verification

Test Original triplet lengths 1/9/12/15 and straight lengths 1/12/16, plus Extended 1–64 lengths in supported modes. Include irregular LAST STEP, NOTE/TIE/REST, grid changes, loop restart, multiple BPM values and Renoise LPB changes. Verify that 12 triplet steps and 16 straight steps each last four beats, and 15 triplet steps last five. **M4 done when:** audio/phrase timing matches the documented grid and repeats without drift; “triplet” is never a cosmetic label.

---

## 7. M5 — Source programming and Renoise workflow

**Goal:** complete source programming and editing, with native Renoise handling arrangement and performance. The original-style source workflow supports the fidelity goal; the three scoped Extended expansions operate on ACID's independent source memories.

### M5.0 — Original programming workflow

- Add sequential PITCH entry/check with a distinct cursor, octave controls, back/correction and pitch audition; TIME entry/check advances its own N/T/R cursor. Keep the direct grid as an Extended editing route.
- Define clear, re-enter PITCH, edit one pitch and re-enter TIME as distinct source operations. Use R02 for destructive flag-reset behavior in Original re-entry; Extended direct edits preserve flags. Provide undo and clear labels for the affected memory.
- Support pitch-owned ACCENT/SLIDE editing during pitch review; page/selection movement never edits the source. Keep M2's leading-TIE normalization in the shared command path for both entry modes.
- Specify TAP timing entry/check and its clock/quantization before implementation; do not confuse TAP audition with real-time TIME recording. Consult the relevant manual procedure and record it before claiming panel-operation fidelity.

**Acceptance:** enter one reference pattern through the Original workflow and the equivalent canonical source through the Extended grid; compare decoded events and playback. Test PITCH re-entry versus TIME re-entry, flag preservation/reset, cursor restart, correction, cancellation and save/reopen.

### M5.1 — Pattern management

- Friendly pattern labels instead of exposing only sealed hash names; keep the stable ownership ID separate from the display label when possible.
- Duplicate an ACID pattern into a new phrase, copy PITCH-only / TIME-only / both memories, reset safely to the C defaults.
- Navigation between phrases must restore the correct source, renderer settings and timing mode without silently discarding an unsaved edit.
- Respect foreign and manually modified phrase ownership, and make conflicts actionable.

### M5.2 — Extended source editing

- **Independent PITCH/TIME randomization:** generate either memory while leaving the other unchanged. Specify pitch range and rhythm densities, use a deterministic seed for reproducible tests, and retain explicit active spans. TIME generation uses N/T/R and applies the shared leading-TIE rule. Do not copy unconstrained firmware byte randomization into the validated source model.
- **Targeted transformations:** clear ACCENT, clear SLIDE, convert REST to NOTE, or TIE to REST. Each action names its affected memory and scope; unrelated pitch values, flags and timing commands remain unchanged. All transformations produce canonical source and support undo.
- **Scale mask:** store enabled pitch classes separately from raw PITCH memory; resolve them before phrase rendering. Disabling the mask restores the original pitches. Define rounding, octave limits and empty-mask handling explicitly. Quantization must not alter N/T/R consumption, accent/slide ownership or a same-pitch connected slide. Preview and render must use the same resolved notes.
- Store source-edit settings with the current source contract where needed. Test deterministic edits, no mutation of the other memory, mask bypass/roundtrip, undo and manual/Live Edit generation through the existing protected writer. Extended editing does not change Roland's articulation rules.

### Renoise integration boundary

- Document native phrase triggering, arrangement, transposition and resizing through Renoise. No ACID pattern queue, chain player, performance transpose, half/double shortcut or playback-cursor recording is required.
- Test native phrase triggering and document supported boundary continuity. R03's end-to-start slide remains a core single-sequence loop requirement; it does not require an ACID arrangement engine. Do not claim independent phrase switches preserve a voice without playback evidence.
- Keep existing Live Edit regeneration responsive and safe. Do not change unrelated tracks, instrument routing, sample setup or phrase contents as an invisible side effect.

### M5.3 — Editor refinement

- Improve page/current-step indicators, keyboard legibility, used versus unused PITCH markers and precise error navigation.
- Distinguish **stored C entry**, **referenced PITCH entry**, and **user-modified PITCH entry**; avoid conflating edit history with musical validity.
- Provide visible dirty/rendering/committed/failed states. Define what happens to unsaved drafts when closing, switching instruments, or changing songs.
- Maintain responsive Live Edit with many phrases and 64-step patterns; avoid regenerating on selection-only UI clicks.

**M5 done when:** a user can program via the Original workflow, edit using the three scoped Extended expansions, duplicate/select and revisit current-format ACID source in a saved XRNS. Preview and output agree, edits are reversible, and Renoise provides arrangement/performance without an ACID substitute. Native playback limitations remain documented.

---

## 8. M6 — Hardening, regression coverage and release readiness

### M6.1 — Data safety, undo and persistence

- Exercise undo/redo during manual regeneration and asynchronous Live Edit; reconcile stored canonical source and generated phrase ownership after changes.
- Verify deletion/reordering of instruments and phrases does not cause stale IDs or destination indices to overwrite another phrase.
- Test cancellation, document close/reopen, interrupted rendering, malformed snapshots and a failed post-render `tool_data` save.
- Prefer a transaction-like contract: no “success” status unless the phrase and its canonical source are both committed and consistent. Audit/repair partial-commit paths.
- Define the current stored schema deliberately and test its roundtrip, strict validation and unsupported-format handling. Earlier WIP formats do not require migration tests or readers.

### M6.2 — Reliability and performance

- Test 64-step all-NOTE sequences, dense articulation, multiple phrases, repeated Live Edit batches, and long song sessions.
- Verify there are no leaked timers, observers, temporary phrases, unexpected playback-mode changes or accumulating event data.
- Run all ACID local specs and the previously passing ARP suite when shared repository utilities change.

### M6.3 — Documentation and release packaging

- Update `README.md` and `DESIGN.md`, which still include older 16-step/one-phrase descriptions; keep this roadmap as the milestone tracker.
- Write current user instructions for creating, editing, looping, Live Edit, storing/reopening, phrase selection and limitations.
- Package ACID with the repository's PowerShell 7 script, verifying `main.lua` and `manifest.xml` at archive root and no SDK/test files.
- Decide version/tag **after** demonstrated functionality; manifest `0.1` stays unchanged until a release decision. Do not imply all analog aspects of the original TB-303 are reproduced.

**M6 done when:** local regression suite, manual Renoise checklist, release package inspection and documentation agree on exactly what ACID supports; there are no unresolved data-loss regressions.

---

## 9. Mandatory test and acceptance matrix

| Behavior | Lua (no Renoise) | Renoise manual |
| --- | --- | --- |
| PITCH/TIME NOTE/TIE/REST consumption | Semantic compiler state/fixtures | Decoded preview versus rendered phrase |
| Original versus Extended entry | T01 normalization, mode bounds/defaults, current-format roundtrip | Entry workflow, mode changes, preview and regenerated playback |
| Clean WIP cutover | Earlier schemas/seals unsupported; one interpreter and current decoder/verifier | Fresh patterns, save/reopen, explicit reset/recreation of development data |
| Default C + 64-position storage | Initial state and validation | Fresh-pattern controls and output |
| LAST STEP and four pages | 1/16/17/32/33/48/49/64 lengths | Boundary edits, no false resets |
| Repeated phrase loops | At least three semantic cycles | Audible/visual repeats across several cycles |
| Leading/trailing TIE, REST, SLIDE | Explicit boundary state assertions | Phrase boundary and actual envelope response |
| Gate and release | Scheduled timeline/collision tests | OFF locations and recorded attack/release |
| Straight and triplet timing | Grid conversion and no cumulative drift | BPM/LPB/triplet repeat checks |
| Several target phrases | IDs, snapshot roundtrip, ownership | Switching, adding and regenerating phrase slots |
| Original re-entry/check workflow | Separate cursors, command/flag reset rules | PITCH audition, TIME review, back/correction, undo |
| Independent PITCH/TIME randomization | Seeded output, valid N/T/R and spans, other memory unchanged | Preview/output agreement, undo and Live Edit |
| Targeted transformations | Exact flag/command changes, unaffected source unchanged | Action scope, undo and regenerated result |
| Non-destructive scale mask | Raw PITCH unchanged, deterministic mapping, bounds, bypass and roundtrip | Resolved preview/output agreement; slide connection after pitch mapping |
| Trigger, stop/start and seek | Explicit cold/repeat context, no stale voice | Sustained versus fresh trigger, release, transport, selective/keymapped coverage |
| Live Edit under pressure | Debounce, single-flight, pending edits | Rapid UI edits while playing |
| Undo/redo and failures | Injected write/cancel failures | Undo, save/reopen, manual edits, song switch |
| Packaging | Static archive layout validation | Install, start and playback in Renoise |

### Local development commands (Windows / VS Code)

```powershell
pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID
pwsh -NoProfile -File ./scripts/run_tests.ps1
pwsh -NoProfile -File ./scripts/package.ps1 -Tool ACID
```

Run specs locally (separate Lua processes as implemented by `scripts/run_tests.ps1`); **no GitHub Actions or workflows**. For new Renoise API usage, consult the pinned 6.2 SDK and associated definitions as directed in [development setup](../docs/DEVELOPMENT.md). Before a milestone merge, use a disposable Renoise song and document the *actual* test results, known caveats, and whether audio was compared.

### Branch/merge convention

- Start each milestone from current `develop` using a focused `feature/acid-mN-*` branch; split risky semantic changes from phrase writer integration.
- Never push unfinished milestone work directly into `main`.
- Keep tests and the relevant `tests/acid/*_manual.md` procedure in the same PR as each behavior change.
- User's successful local tests and Renoise validation are the merge gate. No GitHub workflow requirement.
- Merge verified milestone changes to `develop`; preserve `main` for deliberately prepared releases.

## 10. Research decisions that must remain visible

Record evidence and the final decision *before* declaring hardware fidelity:

1. **Logical PITCH count and cursor restart:** retain original cursor/initialization uncertainty; name independent short-span wrap as an extension. M2's chosen rule is not original CPU evidence.
2. **First-iteration versus repeated-iteration state:** shared leading-TIE normalization (R03), ending/leading REST, and outgoing slide from the final held pitch into the first NOTE, including equal-pitch tied connection.
3. **Native sample voice continuity:** does `0Gxx` really move an existing voice with no new amp/filter attack?
4. **Original gate and accent envelope:** historical behavior versus achievable sample instrument response.
5. **Original triplet/time programming:** apply R04 grid/limits; verify actual phrase duration, conversion and no drift. Original TAP and clear/re-entry procedures need their own operator tests.
6. **Persistence semantics:** restore on reopen, handling draft edits without generation, undo versus song-scoped source data.

For every such decision, supply **reference + decision + test fixture + manual playback observation + documented limitation**. If a decision is provisional, indicate that in GUI text and documentation.

## 11. Immediate next work package

**Continue M3-A acceptance:** the development harness and automated checks are
implemented. Complete the remaining authored protocols and resolve the
normalized grid/control measurements recorded in the evidence index before
selecting a native glide strategy. Do not change runtime articulation while
capture/profile validity is unknown. The original low-level grid pass does not
qualify normalized silence or envelope-edge measurements.

1. Freeze the profile, fixture schema, expected windows and analyzer positive/negative controls from M3.1; inspect the pinned API 6.2 definitions for the disposable builder.
2. Build and read back the disposable profile; document any representability issue before accepting audio results.
3. Calibrate loopback and run the independent `0Gxx` continuity experiment first. Record a native strategy/rate decision or an explicit blocker.
4. Implement M3-B's successor-aware gates independently. Implement M3-C only where the experiment supports it; keep unverified Repeat/profile combinations refused.
5. Verify M3-D accent levels and connected-accent behavior, then finish the support/acceptance record in M3-E.

**Next PR success:** a reproducible Demo-compatible capture path, independent fixture validation, an analyzer that detects seeded failures, and recorded calibration/continuity results sufficient to decide the next runtime work. A blocked experiment is a useful result; it does not enable an unsupported renderer or complete M3.

The ordering remains **semantic correctness → repeatable native phrase output → articulation fidelity → timing fidelity → source editing and Renoise integration → hardened release**.
