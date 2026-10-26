# ACID.xrnx — Detailed Development Roadmap

**Project:** ARP/SEQ / ACID.xrnx  
**Target:** Renoise 3.5+, Lua 5.1-compatible XRNX, scripting API 6.2  
**Working branch:** `develop`  
**Baseline:** merged ACID M1 + Live Edit, commit `75999f9ee01e4840199797847271ed092be6dbab`  
**Document status:** implementation plan; outstanding TB-303 hardware claims require evidence and playback verification  
**Current manifest:** `0.1` (experimental; do not increment as part of roadmap work)  
**Updated:** 2026-10-26

## 1. Product objective and scope

ACID is a lightweight, native Renoise **phrase-based acid sequencer**, not a synthesizer. The canonical source of a pattern is its independent **PITCH memory** and **TIME memory**. ACID translates that source into a native Renoise instrument phrase, preserves it in song-scoped tool data, and supports manual generation and optional Live Edit.

Keep the recognizable TB-303 sequencing ideas while labeling departures explicitly:

- Original-style PITCH entries store a key, octave DOWN/NORMAL/UP, ACCENT, and SLIDE. The default key is **C**, normal octave, with ACCENT/SLIDE off.
- TIME entries are **NOTE**, **TIE**, and **REST**. NOTE consumes one pitch entry; TIE and REST do not. Consecutive time and pitch positions are *not* interchangeable.
- **LAST STEP = 1–64** is an ACID extension. Pages 01–16, 17–32, 33–48, and 49–64 belong to **one continuous sequence**, not four independent 16-step patterns.
- ACID must never describe experimental native-sample glide, gate, velocity, or filter behavior as acoustically identical to a TB-303 without measurements.
- No embedded DSP synth, mandatory VST, arbitrary MIDI-effect rack, or redesign of ARP.xrnx is part of this roadmap.

The [design contract](DESIGN.md) defines architecture and unresolved fidelity issues. This file defines **sequence, deliverables, acceptance gates, and verification**. When a historical detail is uncertain, maintain a research/test item; do not convert an assumption into a guarantee.

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

**Do not infer from the above** that repeat playback, authentic slide envelopes, timing feel, or release characteristics are complete. The current phrase writer sets `phrase.looping = false`, the semantic compiler describes an initial one-pass traversal, and `0Gxx` with 50% gate is still experimental.

### Important model debt to address in M2

`sequencer.new_pattern` initializes **64 valid C pitches**, and `compiler.compile` currently uses `#pattern.pitch_events` as the playback wrap length. This is a storage default, **not proof that every pattern must cycle through 64 pitches**. If a user programs a shorter independent pitch stream, the playback cursor policy must be explicit, documented, and tested. Introducing a logical pitch-memory length may require a **backward-compatible** update to saved song snapshots.

## 3. Priorities and dependency map

| Order | Milestone | User-visible result | Dependency |
| --- | --- | --- | --- |
| Completed | M1 — Editable source, phrase output and Live Edit | Edit ACID patterns and regenerate native phrases | — |
| Next | **M2 — Continuous sequence and loop correctness** | Reliable repeated patterns and deterministically consumed pitches | M1 |
| Next | **M3 — Articulation and native sample fidelity** | Predictable gate, selective slide and accent behavior | M2 semantic contracts |
| Next | **M4 — Timing modes and tempo robustness** | Straight/triplet programming and stable timing | M2 + gate-placement decisions |
| Later | **M5 — Pattern composition workflow** | Efficient multi-phrase editing, duplication, arrangement | M2; stable persistence |
| Final | **M6 — Stability, documentation and release** | Testable, packaged, supportable ACID tool | M2–M5 |

**Milestone completion** requires both deterministic Lua checks *and* targeted manual Renoise verification when the milestone touches rendered notes, audio, GUI, phrases, persistence, or undo. A passing mock test alone is not an audio conformance result.

---

## 4. M2 — Continuous playback and loop correctness

**Goal:** a phrase can repeat predictably over successive cycles, including PITCH consumption and release/slide intent at the last-to-first boundary. Make loop behavior correct in the semantic model *before* teaching the writer to emit it.

**Priority:** highest. **Recommended implementation:** small feature branch from `develop`, separate commits for each subtask. **Avoid treating `looping = true` alone as completion.**

### M2.0 — Define the conformance oracle

**Work**

- Create a table of authoritative hardware references (Roland documentation / verified demonstrations / reference implementation behavior) for: PITCH/TIME entry, LAST STEP, pitch cursor reset, ties, rests, slide across boundary, and first trigger.
- Specify two profiles: **hardware-informed 16-step semantics** and **ACID 1–64-step extension**. Mark any assumed or provisional rule as such.
- Define “initial trigger”, “subsequent loop”, “leading TIE”, “trailing TIE”, “ending REST”, and “next NOTE” in the semantic compiler.
- Decide what happens when the number of NOTE commands differs from the logical pitch sequence length. Test this explicitly rather than deriving behavior from allocated array size.

**Deliverable:** `docs`/design decision notes or a focused M2 semantics document, plus machine-readable fixture descriptions.

**Gate:** each ambiguous rule has a documented chosen behavior and test expectation; any claim of hardware fidelity is supported or marked unresolved.

### M2.1 — Model deterministic repeating TIME/PITCH cycles

**Work**

- Add a pure-Lua multi-cycle traversal or an equivalent state-transition representation that can be tested for 2+ consecutive iterations.
- Preserve independent TIME cursor, logical PITCH cursor, current note, previous SLIDE state, and current gate/hold state.
- Do **not** reset or silently wrap at the boundaries between 16-step UI pages.
- Distinguish first playback (starts silent) from continuous repetition (may inherit a sounding voice).
- Keep NOTE/TIE/REST and octave flags intact for all lengths 1–64.

**Likely modules:** `model/sequencer.lua`, `model/compiler.lua`, possibly a new `model/loop_state.lua`.

**Acceptance tests:** explicit 1, 16, 17, 32, 33, 48, 49, and 64-step patterns; NOTE-TIE-NOTE; NOTE-REST-NOTE; all-rest; all-note; a loop with a leading TIE; loop ending in REST and loop ending in held note. Assert events for at least **three cycles**, including pitch indices and transitions.

### M2.2 — Separate logical pitch length from 64 stored defaults

**Work**

- Represent **PITCH memory capacity (64)** separately from **the number of pitches in the playback sequence**, once the hardware-inspired cursor rule is settled.
- Preserve untouched C entries as valid entries; “not edited” must never mean “invalid note”.
- Determine how users explicitly choose/derive the active PITCH sequence span without turning TIME steps into pitch-index assignments.
- Evaluate how loop restart and pitch wrap interact if, for example, 12 TIME steps contain five NOTE commands while only three PITCH entries belong to the active pitch stream.
- Version and migrate the existing `ACID-PITCH-TIME-1` song snapshot format **only if the stored schema changes**. Old XRNS songs must load without silently changing the intended sequence; if intent cannot be recovered uniquely, preserve old behavior and expose a clear compatibility choice.

**Acceptance tests:** fewer PITCH entries than NOTE triggers, more PITCH entries than NOTE triggers, saved 64-default-C pattern, persistence migration, and stable decoded preview across page changes and regeneration.

### M2.3 — Resolve loop-boundary TIE, REST and SLIDE

**Work**

- Encode the exit state of a cycle and how it is consumed at the next cycle's first NOTE/TIE/REST.
- TIE holds the previous note if a valid held voice exists; TIE never advances the PITCH cursor.
- REST ends the sounding note; the next NOTE is a fresh attack regardless of previous SLIDE intention.
- Slide should be attached to the appropriate transition, including same-pitch slide cases, but the semantic compiler must not assume Renoise `0Gxx` achieves envelope-continuous legato.
- Document behavior of a leading TIE on cold start and after the first loop. Test last-step to first-step transitions with and without intermediate rests.

**Deliverable:** fully specified semantic boundary state plus diagnostics if the selected phrase representation cannot render the requested transition faithfully.

### M2.4 — Native looping phrase output

**Work**

- Replace one-shot-only output with a **verified loop-capable** native phrase strategy.
- Confirm phrase looping, LPB, note-off placement, early release, and Renoise's treatment of a note sustained over the phrase boundary.
- If Renoise cannot preserve the required held voice or selective glide at a native phrase restart, do not silently fake it: isolate a documented fallback/limitation, or render a verified repeated segment when musically equivalent.
- Retain guarded temporary rendering, phrase ownership seals, live-regeneration serialization, destination selection and per-phrase source persistence.
- Ensure changing LAST STEP does not leave obsolete generated lines or stale ownership state.

**Likely modules:** `writers/phrase_writer.lua`, `writers/pattrns_writer.lua`, `writers/phrase_validator.lua` and articulation boundary handling.

**Acceptance in Renoise:** phrases of 1/16/17/32/33/48/49/64 steps audibly repeat and match the expected grid for multiple cycles. 16-to-17, 32-to-33 and 48-to-49 are page boundaries, **not musical resets**.

### M2.5 — Regressions and merge gate

Create `tests/acid/acid_loop_*_spec.lua` and `tests/acid/acid_loop_manual.md`. Test:

- Triple-cycle event equality/continuity under the chosen cursor policy.
- Long patterns with TIE/REST and slide at steps 16/17, 32/33, 48/49, 64/1.
- Changes to LAST STEP and logical PITCH length while Live Edit is ON and OFF.
- New phrase, regeneration of an owned phrase, and refusal of foreign/modified phrases.
- Save/reopen/reload of patterns, preserving pre-M2 snapshots and any new source fields.
- No leftover temporary phrases, broken ownership seals, or changed non-ACID content on a failed render.

**M2 done when:** a 64-step sequence can loop repeatedly with correct decoded events, stable pitch-memory semantics and no unintended page-boundary discontinuity. **Do not conflate this gate with verified TB-303-sounding slides; that is M3.**

---

## 5. M3 — Gate, accent and selective glide fidelity

**Goal:** translate semantic articulation into predictable native-sample playback. A pitch-changing effect is not sufficient proof that the *same voice* glides without envelope retrigger.

### M3.1 — Establish a repeatable audio reference harness

- Prepare a **disposable**, looping single-cycle sawtooth Renoise sample instrument with fixed sample mappings, amplification envelope, LPB and instrument settings.
- Record controlled cases to WAV where needed; compare note-on transients, held portions, pitch motion and NOTE-OFF timing.
- Build short A/B fixtures (slide on/off, accent on/off, NOTE vs TIE, NOTE vs REST, same-note vs octave glide).
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

**Goal:** correctly represent the time base, especially TB-303-style triplet programming, without changing the meaning of existing straight patterns.

### M4.1 — Research and define timing modes

- Confirm original time-mode/step-length behavior using versioned hardware references; distinguish an original programming mode from arbitrary DAW “swing”.
- Define supported straight and triplet grids, musical duration, UI labels, and how LAST STEP applies.
- Separate the **semantic event timeline** from Renoise phrase LPB, line counts and note-delay resolution.

### M4.2 — Deterministic timing conversion

- Implement a timing compiler that emits rational musical positions or a fixed high-resolution tick representation without cumulative rounding drift.
- Choose LPB/phrase lengths/delays based on representability; reject impossible mappings with precise step/line diagnostics.
- Reuse the M3 gate/articulation timeline so timing modes do not destroy note lengths or selective glide.
- Persist the timing mode with the source snapshot, with backward-compatible defaults for existing straight-sixteenth sequences.

### M4.3 — Verification

Test 1–64 steps in each supported timing mode, including irregular LAST STEP values, NOTE/TIE/REST patterns, loop restart, multiple BPM values, and Renoise LPB changes. Verify actual output in Renoise. **M4 done when:** audio/phrase timing matches the documented grid and repeats without drift; “triplet” is never a cosmetic label.

---

## 7. M5 — Pattern composition and Renoise workflow

**Goal:** make multiple independently editable ACID sequences practical to arrange, without expanding ACID into an all-purpose sequencer.

### M5.1 — Pattern management

- Friendly pattern labels instead of exposing only sealed hash names; keep the stable ownership ID separate from the display label when possible.
- Duplicate an ACID pattern into a new phrase, copy PITCH-only / TIME-only / both memories, reset safely to the C defaults.
- Navigation between phrases must restore the correct source, renderer settings and timing mode without silently discarding an unsaved edit.
- Respect foreign and manually modified phrase ownership, and make conflicts actionable.

### M5.2 — Arrangement and triggering

- Make it clear how instrument phrases are triggered from Renoise's regular patterns and how the selected destination is played.
- Consider helper actions for inserting phrase triggers **only with explicit target selection and write preflight**.
- Evaluate pattern chaining after M2 loop semantics are stable. Joining patterns must make boundary articulation and state transition rules explicit.
- Do not change a user's unrelated tracks, instrument routing, sample setup or phrase contents as an invisible side effect.

### M5.3 — Editor refinement

- Improve page/current-step indicators, keyboard legibility, used versus unused PITCH markers and precise error navigation.
- Distinguish **stored C entry**, **referenced PITCH entry**, and **user-modified PITCH entry**; avoid conflating edit history with musical validity.
- Provide visible dirty/rendering/committed/failed states. Define what happens to unsaved drafts when closing, switching instruments, or changing songs.
- Maintain responsive Live Edit with many phrases and 64-step patterns; avoid regenerating on selection-only UI clicks.

**M5 done when:** a user can create, duplicate, select, play and revisit multiple ACID phrases in a saved XRNS without manually rebuilding source memories, accidental overwrite or hidden regeneration.

---

## 8. M6 — Hardening, regression coverage and release readiness

### M6.1 — Data safety, undo and persistence

- Exercise undo/redo during manual regeneration and asynchronous Live Edit; reconcile stored canonical source and generated phrase ownership after changes.
- Verify deletion/reordering of instruments and phrases does not cause stale IDs or destination indices to overwrite another phrase.
- Test cancellation, document close/reopen, interrupted rendering, malformed snapshots and a failed post-render `tool_data` save.
- Prefer a transaction-like contract: no “success” status unless the phrase and its canonical source are both committed and consistent. Audit/repair partial-commit paths.
- Version stored schema deliberately and add migration tests before altering it.

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
| Default C + 64-position storage | Initial state and validation | Fresh-pattern controls and output |
| LAST STEP and four pages | 1/16/17/32/33/48/49/64 lengths | Boundary edits, no false resets |
| Repeated phrase loops | At least three semantic cycles | Audible/visual repeats across several cycles |
| Leading/trailing TIE, REST, SLIDE | Explicit boundary state assertions | Phrase boundary and actual envelope response |
| Gate and release | Scheduled timeline/collision tests | OFF locations and recorded attack/release |
| Straight and triplet timing | Grid conversion and no cumulative drift | BPM/LPB/triplet repeat checks |
| Several target phrases | IDs, snapshot roundtrip, ownership | Switching, adding and regenerating phrase slots |
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

1. **Logical PITCH count and cursor restart:** 64 stored defaults versus a shorter actively played PITCH stream; position at pattern repeat.
2. **First-iteration versus repeated-iteration state:** leading TIE, ending REST, slide from final active note to first NOTE.
3. **Native sample voice continuity:** does `0Gxx` really move an existing voice with no new amp/filter attack?
4. **Original gate and accent envelope:** historical behavior versus achievable sample instrument response.
5. **Original triplet/time programming:** exact duration/entry semantics versus straightforward 1/16 subdivision.
6. **Persistence semantics:** restore on reopen, handling draft edits without generation, undo versus song-scoped source data.

For every such decision, supply **reference + decision + test fixture + manual playback observation + documented limitation**. If a decision is provisional, indicate that in GUI text and documentation.

## 11. Immediate next work package

**Start M2.0 + M2.1 + M2.2 first**, with *no simultaneous M3 sound changes*.

Suggested implementation order:

1. Freeze a small set of deterministic PITCH/TIME reference patterns and explicitly document pitch cursor semantics.
2. Add multi-cycle interpreter tests covering three passes and logical pitch length, especially shorter-than-64 streams.
3. Evolve the memory schema carefully, including saved-pattern migration.
4. Implement native looping output once semantic expectations are passing.
5. Resolve loop-boundary TIE/REST intent before attempting loop-boundary slide audio.
6. Verify looping in Renoise (1, 16, 17, 32, 33, 48, 49, 64 steps), then integrate to `develop` only after manual pass.

**Definition of success for the next PR:** multiple audible repeats follow exactly the intended PITCH/TIME traversal, page transitions are musically transparent, previously saved phrases load correctly, and Live Edit does not overwrite user-edited/foreign content.

The ordering is intentional: **semantic correctness → repeatable native phrase output → articulation fidelity → timing fidelity → composition workflow → hardened release**.
