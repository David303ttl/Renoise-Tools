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

**Do not infer from the M1 baseline** that repeat playback, authentic slide envelopes, timing feel, or release characteristics are complete. M2 now provides baseline Repeat phrase generation; its actual writer-generated audio still needs Renoise verification. `0Gxx` and gate behavior remain experimental.

### Important model debt to address in M2

The current source stores **64 valid C pitches** and carries an independent active span; a new pattern defaults to a 16-entry span in Original mode. This is a storage default, **not proof that every pattern cycles through 64 pitches**. The M2 interpreter resets pitch consumption at each TIME cycle; this is an ACID rule, not measured original CPU behavior.

## 3. Priorities and dependency map

| Order | Milestone | User-visible result | Dependency |
| --- | --- | --- | --- |
| Completed | M1 — Editable source, phrase output and Live Edit | Edit ACID patterns and regenerate native phrases | — |
| In progress | **M2 — Continuous sequence and loop correctness** | Reliable repeated patterns and deterministically consumed pitches | M1 |
| Next | **M3 — Articulation and native sample fidelity** | Predictable gate, selective slide and accent behavior | M2 semantic contracts |
| Next | **M4 — Timing modes and tempo robustness** | Straight/triplet programming and stable timing | M2 + gate-placement decisions |
| Required for fidelity | **M5 — Source programming and Renoise workflow** | Separate step-entry/check workflow, source management and scoped Extended editing | M2; stable persistence |
| Final | **M6 — Stability, documentation and release** | Testable, packaged, supportable ACID tool | M2–M5 |

**Milestone completion** requires both deterministic Lua checks *and* targeted manual Renoise verification when the milestone touches rendered notes, audio, GUI, phrases, persistence, or undo. A passing mock test alone is not an audio conformance result.

---

## 4. M2 — Continuous playback and loop correctness

**Goal:** a phrase repeats predictably over successive cycles, including PITCH consumption and NOTE/TIE/REST behavior at the last-to-first boundary. Baseline Repeat output is implemented; remaining work verifies actual writer output and protects unsupported slide/audio-mode cases.

**Priority:** highest. **Recommended implementation:** small feature branch from `develop`, separate commits for each subtask. **Avoid treating `looping = true` alone as completion.**

**Implementation and verification record:** [M2 blueprint](M2_BLUEPRINT.md), checked against original Roland documentation, the pinned OS-303 firmware and current ACID code. It defines Original/Extended entry, the cursor/voice contract, logical PITCH span, source/seal cutover, native-loop experiments, safety work and acceptance fixtures. M2 remains incomplete until ACID writer-generated audio and lifecycle behavior pass the remaining checks; no hardware fidelity is implied.

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
cycle interpreter. Old development source formats and seals are refused. One
current-format Extended source/seal save/reopen case passed; broader field and
GUI coverage remains in the manual checklist.

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

**Recorded partial acceptance:** the ACID writer's baseline output for lengths 1/16/17/32/33/48/49/64 matched the sampled pitch/silence grid over three cycles. 16-to-17, 32-to-33 and 48-to-49 are page boundaries, **not musical resets**. Sample-release, transport and other lifecycle checks remain open.

The Renoise 3.5.4 WAV probe verified loop endpoint behavior and grid/pitch
markers at all eight required lengths for the recorded test instrument. Two
hand-built native mixed-event phrases also passed recorded pitch/silence
checkpoints over four steady periods. ACID's writer-generated Repeat phrases
then passed 780 sampled mid-step pitch/silence checkpoints across three cycles
at lengths 1, 16, 17, 32, 33, 48, 49 and 64, with source save/load and loop
metadata checks. Sample release/cut tail, voice continuity, slide, stop/start,
seek and undo remain acceptance gates. A 64-step all-REST source also produced
the expected empty 257-line phrase and passed source/ownership checks. The GUI
opened an existing 64-step Extended/span-3 Repeat source and regenerated its
owned phrase. One Live Edit change on a 16-step Extended/span-3 Repeat phrase
also regenerated TIME02 TIE→REST and passed saved-source, cold/repeating OFF,
and ownership checks. Rapid/in-flight edits, disable/close races and
dialog/notifier lifecycle remain untested. A fresh trigger after host NOTE OFF
matched the first six TIME events on one 16-step Repeat source. Transport
stop/start and seek are still untested. See the
[repeat record](../tests/acid/acid_loop_manual.md) and
[regeneration record](../tests/acid/acid_regeneration_manual.md).

### M2.5 — Regressions and merge gate

Maintain `tests/acid/acid_loop_*_spec.lua` and `tests/acid/acid_loop_manual.md`. Test:

- Triple-cycle event equality/continuity under the chosen cursor policy.
- Long patterns with TIE/REST and slide at steps 16/17, 32/33, 48/49, 64/1.
- Changes to LAST STEP and logical PITCH length while Live Edit is ON and OFF.
- New phrase, regeneration of an owned phrase, and refusal of foreign/modified phrases.
- Save/reopen/reload of current-format patterns and all new source fields; earlier source formats and seals confer no load/ownership support.
- No leftover temporary phrases, broken ownership seals, or changed non-ACID content on a failed render.

**M2 done when:** a 64-step sequence can loop repeatedly with correct decoded events, stable pitch-memory semantics and no unintended page-boundary discontinuity. **Do not conflate this gate with verified TB-303-sounding slides; that is M3.**

M2 must also distinguish Original entry from Extended input and complete the
clean source/seal cutover. Passing this milestone does not complete the original
sequencer goal; the fidelity requirements in M3–M5 remain required.

---

## 5. M3 — Gate, accent and selective glide fidelity

**Goal:** translate semantic articulation into predictable native-sample playback. A pitch-changing effect is not sufficient proof that the *same voice* glides without envelope retrigger.

### M3.1 — Establish a repeatable audio reference harness

- Prepare a **disposable**, looping single-cycle sawtooth Renoise sample instrument with fixed sample mappings, amplification envelope, LPB and instrument settings.
- Record controlled cases to WAV where needed; compare note-on transients, held portions, pitch motion and NOTE-OFF timing.
- Build short A/B fixtures (slide on/off, accent on/off, NOTE vs TIE, NOTE vs REST, same-note vs octave glide).
- Include accents within a slide chain and successive accented notes; separate PITCH flag changes from gate retrigger and from the resulting amp/filter response. Treat any accent accumulation or decay law as a measurement question.
- Capture Renoise configuration, BPM/LPB, rendered phrase lines, audible observations and unresolved discrepancies; label observations distinct from historical claims.

### M3.2 — Correct gate and release semantics

- Replace the **50% test gate** with a documented model of normal-note gate/retrigger, extended TIE, ending REST and slide-connected hold.
- Decide how release can be represented in native phrase columns or delays/ticks without destructive collisions.
- Use explicit scheduling at line/tick resolution only when the Renoise phrase engine can reproduce the intended timing.
- Define gate behavior at pattern end and at repeated phrase boundary (depends on M2).

**Tests:** note lengths for one-step NOTE, NOTE-TIE, NOTE-TIE-TIE, adjacent NOTE, REST, and loops; confirm correct release on every case.

### M3.3 — Selective glide without accidental retrigger

- Test local `0Gxx` versus any native mono/glide alternative on the same fixed sample.
- Verify directional interval, same-note slide, short/long slide, octave jumps, incoming vs outgoing slide flag, and loop-boundary glide.
- Prove no unintended new attack or overlay occurs when legato is required; reject modes that cannot guarantee the selected semantics.
- Ensure effect-column use and OFF placement remain collision-safe; do not overwrite user-owned cells.

**Tests:** semantic unit specs, effect placement/specs, native recorded A/B checks.

### M3.4 — Accent response

- Keep PITCH-owned ACCENT as the canonical control, not a TIME attribute.
- Specify provisional volume/velocity behavior separately from optional dedicated Renoise instrument modulation (amp/filter envelopes).
- Do not claim the sample instrument duplicates a TB-303's analog accent/filter envelope; identify a verified preset/profile if required.
- Preserve existing instrument configuration unless the user explicitly chooses a reversible setup operation.

### M3 merge gate

In Renoise, notes, ties and rests have the expected release/attack behavior; slides are demonstrably connected when supported; accent changes are repeatable; all unsupported cases are identified rather than approximated silently. Normal regeneration, Live Edit, ownership and persistence remain intact.

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

**Start M2.0 + M2.1 + M2.2 first**, with *no simultaneous M3 sound changes*.

Suggested implementation order:

1. Freeze R01–R04, Original entry fixtures and Extended cycle fixtures separately; document the provisional pitch cursor rule and original-memory uncertainty.
2. Add multi-cycle interpreter tests covering three passes and logical pitch length, especially shorter-than-64 streams.
3. Replace the development schema/seal contracts directly, including entry mode and explicit span; remove superseded decoders, behavioral branches and adoption paths.
4. Implement native looping output once semantic expectations are passing.
5. Resolve loop-boundary TIE/REST intent before attempting loop-boundary slide audio.
6. Verify looping in Renoise (1, 16, 17, 32, 33, 48, 49, 64 steps), then integrate to `develop` only after manual pass.

**Definition of success for the next PR:** multiple audible repeats follow exactly the intended PITCH/TIME traversal, page transitions are musically transparent, current-format sources roundtrip correctly, the clean cutover retains Extended functions, and Live Edit does not overwrite user-edited/foreign content.

The ordering is intentional: **semantic correctness → repeatable native phrase output → articulation fidelity → timing fidelity → source editing and Renoise integration → hardened release**.
