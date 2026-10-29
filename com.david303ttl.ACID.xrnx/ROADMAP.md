# ACID.xrnx — Detailed Development Roadmap

**Project:** ARP/SEQ / ACID.xrnx  
**Target:** Renoise 3.5+, Lua 5.1-compatible XRNX, scripting API 6.2  
**Integration target:** `develop`
**Document status:** implementation plan; M4 timing contract implementation-ready; M3.5/M3.6 audio acceptance and TB-303 hardware fidelity remain separately evidence-gated  
**Current manifest:** `0.1` (experimental; do not increment as part of roadmap work)  
**Updated:** 2026-10-28

## 1. Product objective and scope

ACID is a lightweight, native Renoise **phrase-based acid sequencer**, not a synthesizer. Its target is to behave as close to the **original Roland TB-303 sequencer** as Renoise permits, including independent programming, repetition and NOTE/TIE/REST/SLIDE articulation. The canonical source is independent **PITCH memory** and **TIME memory**. ACID translates that source into a native instrument phrase, preserves it in song-scoped tool data, and supports manual generation and optional Live Edit. Renoise supplies transport, arrangement, phrase triggering and performance transposition.

Keep the recognizable TB-303 sequencing ideas while labeling departures explicitly:

- Original-style PITCH entries store a key, octave DOWN/NORMAL/UP, ACCENT, and SLIDE. The default key is **C**, normal octave, with ACCENT/SLIDE off.
- TIME entries are **NOTE**, **TIE**, and **REST**. NOTE consumes one pitch entry; TIE and REST do not. Consecutive time and pitch positions are *not* interchangeable.
- **LAST STEP = 1–32** is an ACID extension. The two 16-step pages belong to **one continuous sequence**, not independent patterns.
- Keep one semantic source model: TIME length and active PITCH span are independent values from 1–32. Both stored arrays have capacity 32.
- ACID must never describe experimental native-sample glide, gate, velocity, or filter behavior as acoustically identical to a TB-303 without measurements.
- No embedded DSP synth, mandatory VST, arbitrary MIDI-effect rack, or redesign of ARP.xrnx is part of this roadmap.
- Every valid ACID source must compile to playable phrase events for any selected Renoise instrument slot: sample-based, plugin/VST, external MIDI, hybrid, or empty (empty targets generate a silent phrase with a warning).
- Valid musical edits never depend on a measured BPM, a diagnostic sample fingerprint, or a specific test-pattern layout. Evidence qualifies **fidelity claims**, not permission to sequence. See M3.5.

**Extended expansion scope:** retain the established 32-step storage/direct-grid
and explicit PITCH-span design. The only additional OS-303-inspired sequencer
expansions are independent PITCH/TIME randomization, targeted source transformations
and a non-destructive scale mask. Do not add ACID performance transpose, pattern
queues/chains, half/double length shortcuts or recording against the playback
cursor; those workflows belong to Renoise. Existing Live Edit remains source
editing followed by guarded phrase regeneration, not a new performance engine.

**Current WIP renderer contract:** use one automatic articulation pipeline and
phrase-specific Repeat/Play Once output policy. Remove deprecated audio playback modes (`baseline`,
`retrigger`, `slide`, `mono`) and their code paths, enum values, selectors,
configuration, serialized fields, APIs, mode-specific tests and obsolete fixtures.
Preserve the musical **SLIDE** flag and **retrigger**
semantics as independent NOTE behavior, not named audio modes. General-purpose
pitch, gate, OFF, and glide math may be implemented afresh or factored into
capability-aware operators **without retaining deprecated mode identities**.
The current WIP source schema is `ACID-PITCH-TIME-1`; ownership checks, write preflight and rollback must still
protect unrelated Renoise content.

The [design contract](DESIGN.md) defines architecture and unresolved fidelity issues. This file defines **sequence, deliverables, acceptance gates, and verification**. When a detail is uncertain, maintain a research/test item; do not convert an assumption into a guarantee.

The [second-pass reference record](M2_BLUEPRINT.md#24-original-roland-reference-checked-in-the-second-pass)
identifies the April 1982 Roland manual, checksum, printed pages and R01–R04
observations. Original documentation outranks replacement firmware. The proposed
Original entry mode is a supported programming subset; full fidelity also needs
M3 articulation, M4 triplets and M5 source programming/Renoise integration. An extended
source does not become original-compatible merely because it has 16 steps.

## 2. Baseline: implemented versus not yet proven

### M1 — Native editor and phrase integration

Implemented on `develop`:

| Area | Delivered |
| --- | --- |
| Memory | Independent PITCH/TIME arrays, capacity 32 each; active TIME length and PITCH span are independent |
| Editor | Two continuous 16-step pages, PITCH controls and TIME NOTE/TIE/REST selectors |
| Phrasing | Native instrument phrase with automatic articulation rendering |
| Destination | Select an existing ACID-owned phrase or append a new phrase to a chosen instrument |
| Persistence | Original source snapshots via song-scoped `tool_data`, associated with sealed phrase IDs |
| Protection | Ownership checks, temporary render, guarded replacement and rollback attempts |
| Live Edit | Opt-in immediate, serialized automatic regeneration; manual Generate/Regenerate retained; M4.7 unifies request and cancellation handling |
| Verification | Local model coverage; Renoise playback acceptance is tracked in the manual checklist |

Playback behavior, target response and hardware fidelity require the pending
Renoise checks; deterministic tests do not establish audio behavior.

## 3. Priorities and dependency map

| Order | Milestone | User-visible result | Dependency |
| --- | --- | --- | --- |
| Completed | M1 — Editable source, phrase output and Live Edit | Edit ACID patterns and regenerate native phrases | — |
| Completed (implementation) | **M2 — Continuous sequence and loop correctness** | Reliable repeated patterns and deterministically consumed pitches | M1 |
| Completed (implementation); live acceptance open | **M3 — Articulation measurement and reference-profile renderer** | Scoped reference audio evidence; remaining host transport/live-playback checks | M2 semantic contracts |
| **Implementation complete; Renoise acceptance open** | **M3.5 — Sequencer-first rendering and instrument independence** | Unrestricted valid edits, sample/plugin/MIDI targets, adaptive articulation, persistent Live Edit | M3 semantic model + existing writer safety |
| **Implementation complete; P0 playback acceptance open** | **M3.6 — Plugin/MIDI pitch-bend slide (small follow-up)** | Optional PB Range selector; existing Renoise MIDI pitch bend for instruments without usable portamento | M3.5 source/output/ownership contract |
| Implementation planned on `feature/M4` | **M4 — Timing modes and tempo robustness** | Exact straight/triplet phrase timing independent of song LPB/BPM/meter | M3.5/3.6 renderer contracts; unresolved PB audio evidence tracked as a scoped gate |
| After M3.6 | **M5 — Source programming and Renoise workflow** | Original programming workflow, source management and Extended editing | M3.5 editor and source guarantees |
| Final | **M6 — Stability, documentation and release** | Testable, packaged, supportable ACID tool | M3.5–M5, including M3.6 |

**Milestone completion** normally requires deterministic Lua checks and targeted Renoise verification for rendered notes, audio, GUI, phrases, persistence, or undo. If a user accepts deferring a check, record the scope decision and keep the deferred claim explicitly unverified; a passing mock test alone is not an audio conformance result.

---

## 4. M2 — Continuous playback and loop correctness

**Goal:** a phrase repeats predictably over successive cycles, including PITCH consumption and NOTE/TIE/REST behavior at the last-to-first boundary. Structural behavior is covered by deterministic tests; Renoise playback acceptance remains in the manual checklist.

**Status:** semantic cycle behavior is implemented; phrase playback, voice continuity and transport behavior remain subject to the Renoise checks in [acid_loop_manual.md](../tests/acid/acid_loop_manual.md).

The cycle contract defines cursor and voice behavior independently of target sound. Phrase playback, release, transport, and target fidelity are separate Renoise acceptance checks; no hardware fidelity is implied.

### M2.0 — Define the conformance oracle

**Work**

- Use R01–R04 as operator-level evidence. Keep original CPU traces/measurements, replacement-firmware behavior and proposed software rules distinct; document any disagreement.
- Specify source bounds and leading-TIE normalization. Mark active PITCH wrap, initialization and cursor rules as provisional where evidence is absent. Do not infer fidelity from length alone.
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
- Keep NOTE/TIE/REST and octave flags intact for all lengths 1–32.

**Likely modules:** `model/sequencer.lua`, `model/compiler.lua`, possibly a new `model/loop_state.lua`.

**Acceptance tests:** explicit 1, 16, 17 and 32-step patterns; NOTE-TIE-NOTE; NOTE-REST-NOTE; all-rest; all-note; leading-TIE normalized to NOTE; loop ending in REST and loop ending in held note. Assert events for at least **three cycles**, including pitch indices and transitions.

The pure cycle interpreter and three-cycle fixture tests are implemented and
integrated with the current source/editor. Phrase generation and playback
verification are tracked under M2.3–M2.5.

### M2.2 — Independent TIME length and PITCH span

**Work**

- Represent **PITCH memory capacity (32)** separately from **the active PITCH span**.
- Preserve untouched C entries as valid entries; “not edited” must never mean “invalid note”.
- Determine how users explicitly choose/derive the active PITCH sequence span without turning TIME steps into pitch-index assignments.
- New drafts use TIME length 16, active PITCH span 16 and 32 stored C entries. This span/default policy is an ACID choice.
- TIME 01 TIE converts to NOTE before preview/compile, consuming P01. Raw leading-TIE source is invalid; do not rewrite it during compilation or loading. Length and span edits cannot silently shorten the other memory.
- Evaluate how loop restart and pitch wrap interact if, for example, 12 TIME steps contain five NOTE commands while only three PITCH entries belong to the active pitch stream.
- Define the current source contract and verify exact save/load behavior.

**Acceptance tests:** entered T01 becomes NOTE and consumes P01; raw leading-TIE source is rejected; NOTE counts differing from PITCH span wrap as specified; full-C and inactive storage roundtrip; stable preview and independent length/span edits.

The source, editor and persistence use these fields and the shared cycle
interpreter. Persistence and GUI behavior remain in the manual acceptance scope.

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

Phrase-loop behavior, output endpoints, loop seams, voice continuity, release,
transport, and persistence are covered by the pending Renoise checks in
[acid_loop_manual.md](../tests/acid/acid_loop_manual.md).

### M2.5 — Regressions and closure record

The verification matrix was:

- Triple-cycle event equality/continuity under the chosen cursor policy.
- Patterns with TIE/REST and slide at steps 16/17 and 31/32/1.
- Changes to LAST STEP and logical PITCH length while Live Edit is ON and OFF.
- New phrase, regeneration of an owned phrase, and refusal of foreign/modified phrases.
- Save/reopen/reload of current-format patterns and all canonical source fields.
- No leftover temporary phrases, broken ownership seals, or changed non-ACID content on a failed render.

The current source supports TIME lengths 1–32 with an independent active PITCH
span of 1–32. Renoise phrase playback, lifecycle, and target fidelity checks
remain pending as listed in the current manual acceptance guides.

---

## 5. M3 — Gate, accent and selective glide fidelity

**Goal:** translate semantic articulation into predictable native-sample playback. Pitch movement alone does not establish envelope continuity. M2's source traversal, outgoing SLIDE, REST interruption, cold/steady distinction and exclusive loop-end sentinel remain authoritative.

**Status:** deterministic articulation planning is implemented. Renoise playback acceptance for gate, glide, accent, transport, and Live Edit remains target- and setup-dependent; current-layout checks are listed in the manual guides.

### M3.0 — Decisions, boundaries and blockers

| Decision | Implementation contract |
| --- | --- |
| Native gate profile | For articulated modes, adopt 50% of the final held step as an explicit provisional ACID profile, not a measured TB-303 value. Replace the accidental test-only behavior with a complete cyclic scheduler; no new gate control or hardware claim. |
| Timing | Current Straight/Triplet layout uses phrase LPB 16/12 and four lines per source step. The source-step durations are 1/4 and 1/3 beat; host ticks quantize note delays. |
| Gate and glide independence | Gate and glide planning share the semantic timeline and operation validation. A target limitation does not substitute a connected slide with a fresh attack. |
| Instrument boundary | Runtime generation never changes the user's sample, NNA, modulation, routing or Mono/Glide settings. Target behavior is evaluated separately from phrase structure. |
| Renderer | One automatic articulation pipeline handles NOTE retrigger and PITCH-owned SLIDE semantics. |
| Defaults | Repeat remains the new-source default. Do not silently change renderer defaults or persisted settings; enabling a verified path must be explicit and covered by manual and Live Edit tests. |

**Current boundaries:** generation is based on semantic source and target capabilities, not diagnostic-profile admission. Target-specific audio behavior requires separate Renoise checks.

**Order:** harness and calibration → isolated voice-continuity experiment (research item 3) → gate implementation and glide decision → supported glide integration → accent → acceptance record. Run the continuity experiment before investing in glide integration; gate implementation does not depend on its success.

### M3.1 — Audio diagnostics

- Reference fixtures, native probes and offline analyzer checks are available under `tests/acid/`.
- Capture scripts, loopback calibration and acoustic oracles are **optional diagnostics for a reproducible defect**, not recurring milestone or M4 merge gates.
- Keep useful deterministic Lua/oracle tests. Do not launch a new capture matrix without a concrete runtime regression.

### M3.2 — Correct gate and release semantics
Successor-aware scheduling and shared operation validation are implemented.
Renoise playback checks for the current source-step layout remain pending.

**Chosen profile:** an isolated unconnected NOTE gates for half a step. A following TIE keeps the gate high through the preceding step; release occurs halfway through the final held NOTE/TIE step before a fresh NOTE. Thus NOTE-TIE lasts 1.5 steps and NOTE-TIE-TIE lasts 2.5 steps before a fresh attack. The resulting retrigger gap is half a step (62.5 ms at 120 BPM). A following REST overrides midpoint release and emits OFF exactly at the REST's start. A connected slide holds through the target without OFF. An outgoing flag with no next NOTE never creates a target or bypasses REST.

**Boundary policy:** evaluate the actual successor, not just the flattened cold+steady array. In Repeat, trailing TIE holds into an outgoing slide, releases at the final held-step midpoint before an unconnected first NOTE, or releases at the next REST boundary. Handle cold→steady and steady→steady explicitly. In one-shot, a final unconnected NOTE/TIE releases at its final held-step midpoint; an outgoing SLIDE with no successor does not sustain indefinitely. Do not write into the exclusive-end sentinel, add an unconditional end OFF or change the M2 pitch cursor contract. Host OFF/transport behavior is measured separately from scheduled releases.

**Module map:** `model/control_signals.lua` owns pure gate edges in existing 256-units-per-step coordinates with explicit successor/playback context; `writers/gate_writer.lua` maps exact supported edges to cells; `writers/phrase_validator.lua` validates the complete merged note/OFF/effect/volume plan and rejects unexpected delay, panning, instrument and cut-command data; `writers/phrase_writer.lua` supplies cold/steady context, preflights support and commits only after validation. Keep semantic voice intent separate from physical gate state. Use a shared operation plan so gate and glide cannot independently overwrite each other.

**Collision rules:** preflight all operations before mutation. Refuse missing cells, occupied note/delay/effect fields, nonrepresentable edges and contradictory OFF/target operations with TIME step, cycle and zero-based phrase-line diagnostics. Optional G00 may be omitted on OFF only if the probe verifies that omission; never silently drop a required operation. Preserve owned-phrase validation, temporary rendering, rollback, source commit and Live Edit serialization.

**Gate:** pure specs cover every successor combination, one-shot tail and both Repeat seams, including 1-step/all-rest cases; writer/validator tests cover collisions and failure rollback. Renoise playback acceptance uses both current timing modes and the procedure in `tests/acid/acid_gate_manual.md`.

### M3.3 — Selective glide without accidental retrigger
The planner preserves successor-bounded glide placement, fresh attacks, REST
cancellation, and explicit OFF ordering where required. Renoise playback checks
for the current four-line layout remain pending.

**Rate policy:** derive command rate and duration from target capability and available phrase timing. Treat Renoise command amounts as command values, not durations in milliseconds.

**Rendering policy:** plan cold attack, cold→steady and steady→steady seams, same-pitch and moving slides, tied extension, REST cancellation, and fresh NOTE ordering. Report target limitations with affected TIME step and phrase line. Do not gate valid source on diagnostic profile matching.

**Fallback decision:** preserve valid musical source and report target-specific approximations when exact articulation cannot be represented. Gate/accent behavior remains within the M3 acceptance scope.

**Modules:** `model/articulation.lua`, `writers/phrase_writer.lua`, `writers/phrase_validator.lua`, the shared gate operation plan, and read-only profile checking where necessary. Preserve outgoing PITCH ownership, same-pitch connection and REST cancellation from the M2 interpreter; do not modify semantics to fit a failing renderer.

### M3.4 — Accent response

Retain PITCH-owned ACCENT and provisional event volumes **0.7 normal / 1.0 accent** in `writers/pattrns_writer.lua`. Add volume expectations to the final phrase validator; verify the emitted native values and captured response independently. On the flat-envelope, fixed-gain reference, compare equal-pitch settled windows: predict the level ratio from actual emitted/quantized volume cells, require measured delta within ±0.5 dB of that ratio and spread across three captures at most 0.5 dB. Do not assume the abstract 0.7 value maps linearly without checking the cells and response.

Renoise acceptance for NOTE/TIE accent response and connected-slide behavior
remains target-dependent. Filter-envelope emulation and analog accent decay
remain outside M3 scope.

### M3 implementation packages and merge gates

| Package | Scope / suggested commit | Exit gate |
| --- | --- | --- |
| M3-A | `test(acid): add calibrated articulation audio harness` | Probe/profile, oracle schema and authored cases, analyzer positive/negative tests, Demo loopback calibration and independent continuity experiment recorded; any profile/API uncertainty resolved before downstream audio acceptance |
| M3-B | `fix(acid): schedule cyclic gate releases` | Full successor-aware model and shared operation validation, local specs, calibrated one-shot/Repeat gate captures; retain glide refusals |
| M3-C | `feat(acid): enable verified selective glide playback` | Native strategy/rate decision and evidence matrix; actual writer passes, scoped refusals relaxed, default Repeat Generate/Live Edit checked; if blocked, record evidence instead of claiming feature delivery |
| M3-D | `fix(acid): verify pitch-owned accent response` | Native volume validation, repeated captured level delta, explicit connected-accent support decision |
| M3-E | `docs(acid): record articulation support and limitations` | Manual results, support matrix, DESIGN/README/current instructions agree; regression and package checks complete where required |

Each behavior PR includes its specs, procedure and actual results; records are updated as evidence arrives, not postponed until the last package. Inspect relevant pinned API 6.2 definitions and offline docs before writing probe/profile or runtime API calls; SDK setup is a development prerequisite. Keep new code/fixture names behavior-based and all runtime dependencies inside ACID. No manifest/API bump is implied.

**Merge gates:** run local ACID specs after Lua changes and package checks after runtime changes. Check regeneration, ownership, save/reopen and Live Edit in Renoise. Use accepted reference audio evidence; capture again only for a reproduced regression.

---

## 5A. M3.5 — Post-M3 sequencer-first correction (P0; blocks M4, M5 and M6)

**Scope:** general musical rendering with independent source semantics, instrument
capabilities and write safety. Diagnostic fixtures do not restrict valid source input.

**Implementation:** Program/Grid share one canonical source; Repeat/Play Once
are phrase-specific output policies. Instrument-slot generation, adaptive sample
articulation, plugin/MIDI legato, typed render outcomes, latched Live
Edit, draft recovery and edit Undo/Redo use the same protected writer.

**Verification:** deterministic Lua and synthetic oracle checks validate source,
render planning, mocked integration and failure recovery. The
[manual checklist](../tests/acid/acid_m35_s_manual.md) records required Renoise
GUI, playback, routing, persistence and scaling checks. Those host checks are
not run in this workspace; functional acceptance remains open.

### M3.5.0 — Normative contracts and failure taxonomy

| ID | Required invariant | Acceptance |
| --- | --- | --- |
| C01 | Any structurally valid NOTE/TIE/REST/PITCH/SLIDE/ACCENT source can generate/regenerate with any valid Renoise instrument slot. | No musical edit is rejected because of unmeasured accent, interval, layout, BPM, LPB/TPL, groove, trigger route or sample profile. |
| C02 | Source semantics are independent of the target sound generator. | Identical source and timing context yield identical logical NOTE/REST/TIE/SLIDE/ACCENT event streams on sampler, plugin and MIDI targets. |
| C03 | Normal generation writes an executable native phrase; sonic accuracy is reported separately. | NOTES, RESTs, timing, velocity intent and phrase loop exist even if a target cannot produce continuous pitch glide. |
| C04 | Rendering chooses a feasible command strategy per target and time budget. | No fixed 0G20 rate, fixed 8/9-step topology, or exact-profile whitelist in production admission. |
| C05 | Articulation limitations never become silent semantic substitutions. | The destination is updated with the closest explicit approximation; UI reports affected steps and lost fidelity. |
| C06 | Live Edit is latched until user disables it, closes the dialog, changes song, or the song closes. | A recoverable compile/render problem never silently unchecks Live Edit. |
| C07 | No destructive side effects on the selected instrument or other song content. | No changes to samples, plugin state, MIDI routing, preset, NNA, trigger settings, sample mapping, instrument FX or foreign phrases. |
| C08 | Source, generated phrase, ownership seal and UI state remain consistent. | Atomic success or protected last-good phrase; source edits remain recoverable as an explicit draft. |
| C09 | Musical validity, phrase representability, sonic capability and transaction safety are separate checks. | Independent error codes and tests; fidelity evidence cannot reject an otherwise valid source. |

**Permitted hard failures only:** invalid/out-of-range canonical source; invalid or missing instrument index; Renoise API/phrase capacity or truly unrepresentable phrase size after trying supported render layouts; unsafe ownership/duplicate IDs; foreign or modified target; stale song/target; corrupt persistence; interrupted or failed transaction. Show precise cause and action. An empty but valid instrument slot is **not** an error: generate its phrase and mark playback silent until a generator is configured.

**Nonfatal fidelity diagnostics:** target does not implement continuous legato, connected-accent dynamics, plugin pitch-bend semantics, sample glide, expected envelope response or precise sub-line articulation. Report capability + affected step(s) + rendering strategy. Never call these "GENERATION FAILED" when the phrase committed.

**Priority at runtime:** source validity -> semantic timeline -> destination safety -> target capability -> feasible native operations -> guarded commit -> separately evaluated fidelity.

### M3.5.0.1 — Separate Entry, Playback and renderer strategy (P0 architecture gate)

**M3.5-S contract:** Program/Grid are editor views; Repeat/Play Once are phrase output policies. Neither the view nor output policy changes source validity or musical interpretation.

| Domain | Authority | UI contract | Must not affect |
| --- | --- | --- | --- |
| Musical source | Canonical PITCH/TIME memories, LAST STEP, active PITCH span, accent/slide flags, musical timing grid | One editable sequence | Editor view, generator type, audio-test strategy |
| Editor presentation | GUI/controller | **Program (Roland-style PITCH/TIME)** or **Grid (direct)**; both edit identical memory | Source validity, playable length, selected instrument |
| Cycle semantics | Pure compiler | Cold start, steady repeats, outgoing SLIDE, REST, TIE | User editor selection or device capability |
| Phrase output policy | Per-owned-phrase render settings | **Repeat (default)** or advanced **Play Once** | Musical source, active PITCH span, semantic event stream |
| Rendering strategy | Capability-aware renderer | Automatic sample/plugin/MIDI rendering | Source validity or musical meaning |
| Preview | Pure semantic projection | Read-only Start/Repeating inspection | Source, phrase settings and commit state |

**Entry redesign — baseline delivery in M3.5, full Roland sequential-entry workflow in M5.0**

1. Remove entry_mode=original/extended from canonical source storage, semantic validation and compile branching. Independent TIME length and active PITCH span are each 1–32; both initialized arrays have capacity 32.
2. Replace Entry mode with a nonsemantic **Program/Grid** view selector. Switching views does not reset, re-enter, normalize, reallocate, rewrite or regenerate any musical values. Selection-only actions cannot schedule Live Edit.
3. Both views can access/edit all 1–32 TIME steps and any valid active PITCH span, using two continuous 16-step pages.
4. Share source-edit commands for NOTE/TIE/REST, PITCH, octave, ACCENT, SLIDE, LAST STEP and active PITCH span. Only an explicit destructive Roland-style re-entry or Reset command may change stored flags beyond the intended edit.
5. New patterns are immediately initialized to documented C defaults with a valid TIME sequence. Remove **Create / Reset Pattern** as a prerequisite to user editing/generation; keep Reset as explicit, guarded, undoable destructive action. Changing LAST STEP preserves nonvisible stored PITCH and eligible saved TIME entries.
6. Editor view preference is GUI/session metadata, not source semantics, and does not belong in phrase ownership hashes. In M5.0 implement full Program pitch/time cursors, back/correction, check and audition over this common source.

**Playback redesign — sequence iteration is not the phrase output switch**

1. For every source compile cold-start and steady-cycle semantic interpretation, including final-to-first SLIDE, same-pitch connected transitions, TIE holds, REST interruption and subsequent attack. Do not gate cycle interpretation by a persisted source playback selector.
2. Remove playback=loop/one_shot from canonical source and source validity checks. **Repeat** is the default target phrase-output policy. Optional **Play Once** is advanced per-destination renderer metadata, not a separate category of musical pattern or editor mode.
3. Repeat output: render cold introduction plus stable repeating body with exclusive-end sentinel. Play Once output: render one cold traversal and explicit appropriate final note release. Changing policy changes phrase layout/termination only; the canonical source remains byte-equivalent.
4. Distinguish phrase looping/loop points from instrument-wide phrase triggering and from song transport. Never silently change an instrument's global phrase playback mode, key mapping, plugin preset, trigger settings or MIDI routing to make output work.
5. Start/Repeating preview remains read-only semantic inspection regardless of output policy. Stop/start/seek, phrase trigger/release and cold-to-steady audio behavior require target-aware acceptance, not calibration-profile admission.
6. Live Edit regenerates the selected owned phrase when output policy changes without mutating PITCH/TIME; invalid output/host setup leaves last-good phrase and the valid source intact.

**Delete obsolete audio modes completely — one semantic articulation pipeline**

1. **Delete** `baseline`, `retrigger`, `slide` and `mono` **as audio-mode identities**, including Baseline, Retrigger + Gate, Selective Slide + Gate, Mono and any aliases. Remove the main GUI Audio test selector, `mode_values`, `mode_choice`, `REPEAT_HELP`, menu settings, mode-specific status/help text, function arguments, constants and serialized `audio_mode` values.
2. Remove the mode parameter from `phrase_writer.generate`, `pattern_store.prepare/save/load`, live-regeneration callbacks and render-job records. Remove `AUDIO_MODES` and per-phrase mode settings; do not introduce a mode-valued default.
3. Remove `repeat_preflight(plan,mode,...)` as a mode-whitelist gate, `mode==...` writer branches, `mono` aliasing and mode-selected planning paths. A single semantic compiler always requests gate, release, connected transition and accent; instrument-specific operators choose feasible Renoise cells by capability and timing.
4. Derive musical behavior only from source: NOTE after REST = attack; unconnected NOTE = retrigger; target of outgoing SLIDE = connected transition; TIE = hold; REST = release; ACCENT = pitch-owned expressive intent. **Keep** the `slide` PITCH field and NOTE retrigger event semantics; they are musical data, not renderer modes.
5. Where the target cannot implement continuous slide or connected dynamic changes, generate ordered pitches/gates/velocity using the closest safe representation and report a **nonfatal fidelity approximation** with affected steps. Never silently claim slide continuity on a plugin from sample-only 0Gxx commands.
6. Remove existing mode-specific unit specs, GUI expectations, audio fixture IDs and snapshot expectations; **replace** them with NOTE/REST/TIE/SLIDE/ACCENT, capability, loop and transaction behavior tests. Keep reusable audio measurement utilities and independently defined expected musical cases, but no test that selects or asserts a deprecated audio mode.
7. Manual Generate and Live Edit take one unambiguous request: (canonical source, target instrument/phrase, phrase output policy). Planner strategy and fidelity diagnostics are derived typed results, never persisted modes or input flags. The current WIP source schema is `ACID-PITCH-TIME-1` and contains no audio-mode field.

**Persistence contract**

- The current WIP source/seal schema is `ACID-PITCH-TIME-1`: canonical sequence excludes editor view, source playback switch and audio-mode fields; phrase-specific output policy is stored separately.
- Update **gui.lua**, **model/sequencer.lua**, **model/cycle_interpreter.lua**, **model/editor_state.lua**, **model/pattern_store.lua**, **writers/phrase_writer.lua** and tests together. Remove deprecated mode selectors/branches/constants, positional mode parameters, mode-owned source fields, mode-dependent refusal messages and mode-specific test fixtures.
- Preserve safe destination ownership, no changes to unrelated content, staging, rollback, source-draft recovery, undo/redo, and atomic phrase/source/output-settings commit.

**Mandatory Gate S acceptance**

| Scenario | Required result |
| --- | --- |
| Program -> Grid -> Program | Byte-identical source and semantic output; no view-switch regeneration |
| TIME 32, active PITCH span 3 | Both views edit and regenerate |
| LAST STEP 16 -> 17 -> 16 | Source entries retained; no reset or Create gate |
| Read Start/Repeating preview | No source, phrase, output-policy or ownership mutation |
| Repeat -> Play Once -> Repeat | Same source; only owned phrase looping/termination differs |
| SLIDE at last/first seam | Correct cold attack and steady connected transition; no audio mode selection |
| Connected accent, REST, TIE, large glide | Normal Generate and Live Edit succeed or commit explicit sonic approximation |
| Unconnected NOTE after glide | Fresh attack, cancellation and OFF preserved where representable |
| Sample/plugin/MIDI instrument | Same musical event intent, automatic renderer, no mandatory sample |
| Save/reopen, undo/redo | Canonical source and independent phrase output policy persist; view stays nonsemantic |
| Fresh pattern | Immediately editable/generatable with C defaults; Reset explicit and undoable |

**Gate S:** no Entry or Audio test choice governs source legality; Playback becomes optional phrase-specific Repeat/Play Once output policy only. No production source, GUI control, writer API, persistence schema, unit/integration test setup, fixture, or code branch retains deprecated audio-mode identities. Required musical `slide` flags and retrigger transitions remain valid; no rendering strategy is selected before entering SLIDE.

### M3.5.1 — Instrument-agnostic destination and generation

- Replace the sample-buffer and "playable sample instrument" gate in **writers/phrase_writer.lua** with a valid Renoise instrument-slot check. Permit plugin-only, MIDI-only, hybrid and empty slots; do not inject a dummy sample.
- Use Renoise instrument phrases as the common output format. Renoise supports phrase playback for samples, plugins and MIDI. Do not make phrase creation dependent on sample_data, sample mapping, sample rate or the diagnostic envelope.
- Probe the actual instrument configuration read-only: sample layer, loaded plugin or alias, external MIDI output, hybrid layers, phrase playback mode and relevant trigger properties. A GUI tab or presence of a sample object is not proof of audible playback.
- If Pattrns scripting/rendering depends on sample-backed audition, separate event construction from audio preview and provide a **direct native phrase-cell emitter**; both routes must pass the same structural validator and guarded transaction. No rendering-to-sample, plugin freezing or third-party conversion dependency.
- Keep selecting existing owned phrases or appending a phrase to the chosen instrument. Do not overwrite another instrument's phrase, alter the selected track, or reroute audio/MIDI.
- Empty instrument: produce valid event cells and warn "No active sound source; phrase will be silent." Missing/unavailable plugin or disconnected MIDI port: keep phrase generation possible; show the target's actual playback dependency without rewriting plugin or device settings.
- Detect a target's changed capabilities at each regeneration and after song/instrument changes. Use semantic target identity and ownership, not stale GUI list indices.

**Gate I:** fresh sample, plugin-only VST/VST3 (where available), external MIDI, hybrid, empty and alias instruments all accept Generate/Regenerate and source save/reopen. No temporary phrases, unrequested instrument mutations or sample-required errors.

### M3.5.2 — General articulation planner (no test-matrix admission)

- Split **model/cycle_interpreter.lua** semantic output from **model/control_signals.lua** musical gate/connection timeline, a capability-aware articulation planner, native operation emission and post-write validation. The same planner feeds manual Generate and Live Edit.
- Remove production use of **reference_gate_context**, **eligible_repeat_slide_layout**, **eligible_repeat_same_pitch_tempo**, exact 90/120/150 BPM gates, diagnostic instrument fingerprints, hardcoded pitch pairs and blanket connected-accent refusal. Retain measured cases as offline reference tests.
- Compute slide direction, interval, available musical duration and command budget for any legal source pitch, including 0, +/-1, +/-4, +/-12, +/-25 and larger within valid note range. Rate and required continuation are derived, not fixed to 0G20.
- For sample-capable targets, evaluate 0Gxx coverage with legal rate 01..FE and FF instant behavior, available lines/ticks, NOTE/OFF locations, successor REST/NOTE and phrase seam. Search feasible rates/placements before approximating; test against native Renoise execution, not arithmetic alone.
- Use an adaptive duration/line representation where possible within Renoise phrase limits. When the exact glide cannot fit, still render its target pitch and remaining sequence; signal truncated/stepped glide. Do not emit a command sequence that audibly stalls indefinitely or erases a successor attack.
- Preserve cold -> steady and steady -> steady Repeat transitions, outgoing SLIDE across the loop seam, same-pitch connected SLIDE, REST interruption, unconnected fresh NOTE attack, TIE holds and end-of-cycle note release policy. Plan required cancellation/OFF before fresh NOTE attacks.
- Support any NOTE accent including connected-slide target and source. Generate a meaningful note velocity/volume instruction; classify an inability to vary a continuously sounding voice as a target-specific sonic limitation, not invalid source.
- Resolve cell collisions by planning alternatives (resolution/rate, available columns, safe timing placement or explicit approximation). Never drop a required OFF, accidentally retrigger a connected sample voice, write past phrase end or corrupt another column. A true API/resource bound may fail with a step/line diagnostic only after feasible layouts have been tried.
- No deprecated audio-mode implementations, internal enum, strategy aliases or settings survive M3.5-S. Render articulation directly from the NOTE/TIE/REST timeline and PITCH-owned SLIDE/ACCENT. WIP save/reopen tests use the current source schema.

**Gate A:** exhaustive legal-source property tests and specified randomized seeds generate phrases without M3 evidence-gate errors; every emitted cell passes validator; target pitches, attacks, RESTs, loop order and stored source match the semantic oracle. Sample audio failures report fidelity limitations independently.

### M3.5.3 — Sample, plugin and MIDI articulation backends

| Target capability | Required minimum | Optional enhanced path and conditions |
| --- | --- | --- |
| Native sample | NOTE/REST/TIE, deterministic OFF/gate, accent volume, target pitch and loop. | Selective 0Gxx legato, adaptive rate and connected accent where native behavior supports it. Do not change sample or modulation settings. |
| Plugin instrument (VST/VST3/AU where host supports) | Native phrase NOTE/NOTE-OFF and velocity reaching plugin; accurate pitch and rhythmic event order. | Legato/portamento only if current plugin/host behavior supports it; scoped MIDI pitch bend only with known bend range, isolated channel/voice and correct reset. |
| External MIDI | Phrase note-on/note-off/velocity and ordering; no stuck notes after REST, stop or target change within host control. | Pitch bend/CC only with confirmed channel, range and reset policy; never assume a receiving synth's glide behavior. |
| Hybrid / plugin alias | Phrase events address the selected Renoise instrument without hidden layer/alias changes. | Report per-layer articulation limitations if components react differently. |
| Empty / unavailable generator | Phrase can be created, edited, stored, inspected and replaced. | Explicit silent/missing-device status, not an installation or sample requirement. |

- Renoise sample 0Gxx is **not** a general plugin/MIDI glide command. Never emit it as proof of plugin legato. Plugin/MIDI targets emit overlapping NOTE/OFF events for receiver-controlled mono/legato portamento. The target NOTE starts in another column before a delayed predecessor OFF; connected same-pitch notes hold the existing voice. Show the receiver setup requirement and do not claim glide for a receiver that ignores overlap.
- Do not send speculative pitch bend, CC, sustain, channel pressure or instrument automation; do not overwrite user-defined plugin portamento or routing. Treat plugin-specific legato as a capability/verification path, not an assumption based on plugin format.
- Velocity/accent must preserve the PITCH-owned flag; verify native volume-cell to plugin velocity delivery and sample loudness separately. Do not claim native sample envelopes, VST amp/filter accents and TB-303 analog accent are equivalent.
- Preserve target plugin/MIDI note-off and voice lifecycle during Repeat, stop/start/seek, phrase switching, regeneration and instrument reassignment; where Renoise controls external tail behavior, state that limitation precisely.
- No required commercial plugin. Use a reproducible available test VSTi and a MIDI capture/loopback route for acceptance; no soundcard-loopback dependency for structural correctness.

**Gate B:** plugin-only and external MIDI run the same NOTE/TIE/REST/SLIDE/ACCENT source without generation refusal or phantom sample requirements; note stream and note-offs verified in Renoise. Any discontinuous SLIDE produces an explicit diagnostic, not a failed render or a false continuity claim.

### M3.5.4 — Live Edit: persistent, transactional and observable

- Keep Live Edit **armed** across arbitrary valid STEP/PITCH/ACCENT/SLIDE changes, BPM changes, TPL/LPB changes, groove changes and playback stop/start/seek. Never uncheck on a nonfatal fidelity limitation.
- Model states explicitly: **CLEAN, RENDERING, COMMITTED, APPROXIMATE, ERROR**. Expose last successful commit, current pending edit, active target and any error; "APPROXIMATE" means successful audio-limited render.
- Serialize regeneration and coalesce intermediate edits. Validate job token/document identity both before mutation and before commit. An edit while rendering enqueues the latest full canonical source and regenerates once the in-flight job resolves.
- On transient failure, retain the last-good sealed phrase, keep source draft and pending status, remain armed, and retry on the next relevant change or user Retry. Do not spin on a permanent error. Start valid edits immediately without a debounce timer or manual Generate prerequisite. Edits arriving during a render apply immediately after it settles; editor-view and cursor-only changes never rebuild.
- Only explicit New Phrase plus Generate or a real source/settings edit while Live Edit is armed may create a destination. Arming, navigation and draft restoration never render. Foreign, modified or deleted destinations block writes and preserve drafts; they never fall back to creation. Song changes invalidate and stop the session; missing instrument or corrupt persistence reports an error without disabling Live Edit.
- Closing/switching the dialog does not create a partially owned phrase. Define and test save/reopen of a dirty canonical draft separately from the last committed seal; user is warned before any unsaved draft would be lost.
- Avoid string-matching success messages as the Live Edit completion API: use typed success/failure/approximation results with structured diagnostics; manual Generate uses the same result contract.

**Gate L:** rapid edits (including while audio plays), failed render then corrected edit, tempo/groove changes, cancellation, undo/redo, target mutation, dialog close/reopen and song switch never silently disable an armed session or corrupt last-good content. Valid source edits never require Generate or an explicit resume step.

### M3.5.5 — Diagnostics and editing UI

- One primary **Generate/Regenerate** action and one **Live Edit** toggle; no mandatory technical playback-mode selection to use a valid SLIDE.
- Display **committed / approximate / rendering / failed** with target instrument and phrase. Put diagnostic text in a readable, selectable area with source TIME/PITCH step, phrase line, capability and recommended action.
- Distinguish **fatal safety/structural errors** from **nonfatal sonic approximations**. Never label a completed phrase as generation failed. Do not show reference profile, measured tempo or whitelist boundaries as required user setup.
- Allow edit navigation directly to reported step and keep the user's source editable regardless of output capability. Warnings never undo the edit, reset ACCENT/SLIDE or deselect Live Edit.
- Expose resolved instrument type and silent/unavailable target warning without requiring instrument inspection knowledge. Do not promise audio for an empty instrument.

**Gate U:** all warning/error classes have deterministic mocked GUI tests; one normal-resolution Renoise smoke verifies readable status and diagnostics. Other display scaling belongs to release QA.

### M3.5.6 — Functional acceptance

- **Local:** semantic NOTE/TIE/REST, glide fallback, phrase capacity, ownership, target identity, cancellation, rollback and draft persistence.
- **Renoise:** sample and one available plugin instrument; Program/Grid roundtrip, Repeat/Play Once, phrase selection, in-place regeneration and save/reopen.
- **Live Edit:** latest edit wins, stale render invalidation, no automatic destination creation on instrument switch or target loss.
- **Optional diagnostics:** additional receiver audio, external MIDI capture, hybrid/alias fidelity and loopback analysis are not M4 blockers. Keep target-specific support limitations explicit.
- Run tests locally with PowerShell 7 and Renoise. No workflows or capture campaigns.

**Current implementation and acceptance status:**

| Slice | Implementation | Unverified host checks |
| --- | --- | --- |
| **M3.5-S — source/editor/output** | Program/Grid, independent output policy, current 32-position source, Reset, Undo/Redo and one source/articulation contract. | View switching, phrase choice, source/output save/reopen and playback. |
| **M3.5-A — instrument targets** | Read-only sample/plugin/MIDI/hybrid/alias/empty capability detection; no sample prerequisite; capability changes suspend staged commits. | Actual generator routing, alias behavior, disconnected MIDI and unchanged instrument settings. |
| **M3.5-B — native planning** | Semantic timeline, writer validation and articulation planning. | Current four-line layout validation and boundary playback remain pending. |
| **M3.5-C — sample articulation** | Sample glide placement respects NOTE/OFF timing; limited continuity and connected accents report approximations. | Sample envelope response, fresh attacks, Repeat seams and connected dynamics. |
| **M3.5-D — plugin/MIDI/hybrid** | Periodic multi-column SLIDE legato with target NOTE before delayed predecessor OFF, same-pitch holds, velocity and read-only routing diagnostics. | Plugin velocity/OFF delivery, MIDI capture and voice lifecycle, hybrid/alias output. |
| **M3.5-E — Live Edit and drafts** | Typed outcomes and failure categories, latched recovery/retry, visible state/target, single-flight coalescing, cancellation, edit Undo/Redo and separate durable drafts. Unsafe or failed draft persistence keeps session recovery with a loss warning. | Playback edits, host undo, dirty XRNS save/reopen, target changes and error recovery. |
| **M3.5-F — verification/package** | 29 ACID and 3 ARP Lua specs pass; semantic and synthetic audio controls pass; 22-file runtime archive matches source bytes with root main.lua/manifest.xml and no development files. | Installed-tool smoke test, Windows scaling, audio/MIDI and manual acceptance checklist. |

**M3.5 complete only when:**
- Gate S passes: Program/Grid are editor views, Repeat/Play Once is output policy, and one automatic articulation pipeline handles all source articulation.
- Ordinary valid user input and all targeted instrument families regenerate through manual and Live Edit without M3 calibration-profile/layout/tempo refusals.
- A sample is never a prerequisite for a valid instrument phrase; a plugin-only instrument can be selected, written and heard through its existing plugin route.
- Every reduced-fidelity articulation commits a musically ordered phrase with explicit warning, and cannot be mistaken for a hardware-faithful slide/accent.
- All real safety failures preserve unrelated/last-good phrase data, report corrective action and retain recoverable source.
- Verified local specs, Renoise manual receipts and docs agree; no background service, mandatory VST, synth engine, implicit sample conversion, or GitHub workflows.

---

## 5B. M3.6 — Plugin/MIDI pitch-bend slide (small follow-up; before M4)

**Status:** manual PB Range assumption only; no VST profiling or configuration. Current-layout receiver and fresh-attack alignment checks remain pending.

**Implementation record:** the editor exposes the phrase-specific PB Range
setting with Undo/Redo, draft persistence and Live Edit. The protected phrase
writer selects bend rendering for plugin/MIDI routes, retains PB Off overlap and
sample glide, validates emitted commands and reports approximation fallbacks.
PB settings remain separate from canonical musical source. Linear bends use the
current four-lines-per-step phrase resolution; same-pitch connections do not
retrigger. Range overflow and Repeat layouts that cannot preserve a safe pitch
anchor use bounded ordered-note fallbacks with explicit approximations.

**API/reference check:** pinned API 6.2 PatternLine definitions and offline docs
confirm writable panning, note/instrument and effect fields. Native M1 uses the
rightmost note panning field plus the first effect column. Its main/fine MIDI
bytes encode 14-bit center 8192 as `4000` and maximum 16383 as `7F7F`; effect
`number_string` avoids confusing character-encoded API numeric effect values
with raw MIDI data. The [official manual](https://tutorials.renoise.com/wiki/Effect_Commands#midi-commands)
documents M1 targeting and main/fine ordering. InstrumentPhrase docs describe
phrase instrument columns as sample selectors, so actual plugin delivery cannot
be inferred from these API checks. The [P0 procedure and result table](../tests/acid/acid_m35_s_manual.md#m36-pluginmidi-pitch-bend)
records the bounded slot `03` Surge XT pass. That result closes the single
reference-receiver go/no-go check for its documented configuration; it does
not establish delivery or glide behavior for other receivers or routes.

### M3.6.0 — Product contract and limits

- Keep the current automatic sample `0Gxx` path and plugin/MIDI overlapping-NOTE legato as they are. **Do not** reinstate Baseline/Retrigger/Slide modes.
- Add exactly one unobtrusive **PB Range** dropdown next to the selected instrument: **Off (default), ±2, ±12, ±24, ±48 semitones**. Off preserves existing overlap/receiver-portamento behavior. Non-Off asks ACID to generate a bend-controlled connected SLIDE for the plugin/MIDI receiver.
- A selected value is **ACID's assumed range**, not a command that sets a VST's bend range. User sets the matching range in the chosen instrument; do not discover VST parameters, install presets, change instrument/plugin state, or claim the range has been verified.
- Store the PB selection only as target/owned-phrase **render settings**, separate from canonical PITCH/TIME memory and the source ownership hash. Selecting another phrase restores that phrase's saved setting; changing the value schedules normal guarded regeneration and supports existing Undo/Redo/Live Edit behavior.
- Pitch bend is **channel-wide** on ordinary MIDI receivers; require isolated monophonic use for exact connected behavior. ACID does not claim independent bends for simultaneous voices, unrelated routed tracks, or arbitrary polyphonic VST presets.
- No plugin database, per-VST calibration, plugin-specific integration, auto-portamento setup, alternative playback engine, user-defined curves, general MIDI FX rack, extra UI modes, or mandatory third-party dependency.

### M3.6.1 — Reuse native Renoise MIDI commands; one feasibility check

1. Use the documented Renoise **M1 pitch-bend MIDI command** as the first implementation target, not sample-only `0Gxx`. The Renoise manual specifies `M1` in the **rightmost note column's panning field**, a valid target instrument number, and the paired hexadecimal MIDI value in the associated effect field. Verify the exact phrase API cell-property mapping against the pinned Renoise 3.5/API 6.2 SDK before modifying `legato_writer.lua` or `phrase_validator.lua`.
2. **Single bounded in-Renoise check:** with one available VST responding to bend (suggested: Surge XT), set its bend range to ±12 and turn its own glide off; manually enter a held C note plus noncenter/center M1 commands inside a triggered native Renoise instrument phrase. Confirm audible pitch change **and reset**, and the intended MIDI target. This is a go/no-go integration check, not an audio-calibration program.
3. If phrase-contained M1 does not reach plugins through the current host/phrase route, record the specific limitation and **do not** add or silently reconfigure an Instrument MIDI Control device or track automation. Keep the existing overlap route and nonfatal limitation warning; reconsider explicit routing separately only if genuinely needed.
4. Keep target verification limited to this available reference VST and ordinary note/MIDI checks. Do not require testing dozens of synthesizers or proving compatibility across the VST ecosystem.

**Gate P0:** one concrete Renoise phrase can deliver a bend and a center reset to the chosen plugin. If not, stop M1 implementation without blocking existing musical NOTE/SLIDE generation or M4 work; report unsupported explicit PB and preserve current overlap behavior.

### M3.6.2 — Minimal bend-aware renderer

1. Implement a small deterministic phrase-cell pitch-bend emitter reusing **model/control_signals.lua**'s semantic NOTE/TIE/REST/SLIDE timeline and the existing protected phrase writer. Extend the current legato writer/validator where practical; avoid a new engine.
2. With PB **Off**, retain the existing NOTE-before-delayed-OFF legato method; with PB **On**, keep a *single active receiver note* and bend it smoothly to each connected SLIDE target. No target NOTE-on or envelope restart is requested at the connected boundary.
3. Treat a selected ±R as mapping `-R..+R` semitones onto MIDI 14-bit pitch bend `0..16383` with center `8192`. Calculate from the **held note's pitch anchor**, including accumulated connected transitions, rather than independently centering every target. Ensure complete target pitch and bend endpoint when representable; never wrap, clamp silently or jump past the chosen range.
4. Generate a short **linear** series of pitch-bend points across the available connected-step interval using the **existing phrase timing resolution**. No additional glide-time, easing or precision controls. Preserve NOTE/TIE/REST order and source-step mapping.
5. A fresh NOTE, REST, Play Once tail, normal release, or safe loop reset must stop the old note as required and restore bend to center **before the next unrelated attack**. Handle cold→steady and steady→steady phrase loops explicitly; do not issue an incorrect center reset while a connected held note is crossing the seam.
6. A same-pitch connected SLIDE holds the receiver note without a second attack. Preserve ACCENT in the source; if connected velocity/expressivity cannot change on the already-held voice, show a nonfatal warning.
7. If a connected interval or accumulated pitch offset exceeds the selected range, **never refuse valid source**. Emit an ordered NOTE fallback for the affected transition, restore pitch-bend center safely, and report **SLIDE approximated: bend range exceeded** with its TIME step. A plugin that ignores bend gets the same nonfatal limitation, not a broken/missing phrase.
8. Ensure M1 cells do not erase existing NOTE, volume, OFF, delay or instrument-column data. Extend post-render verification to check all inserted bend commands, intended MIDI target and required center resets. Keep staged phrase replacement, seals, undo, foreign-phrase protection and last-good Live Edit intact.
9. Hybrid instruments: PB applies only to responding plugin/MIDI layers; sample layers may behave differently. Show a short hybrid-articulation warning; never alter their samples or routing.

**Gate P1:** PB Off reproduces M3.5 output; PB On produces structurally valid bends and safe note/release ordering for basic connected slides and remains usable when the receiver cannot implement exact continuity.

### M3.6.3 — Small acceptance set; no research program

| Check | Pass condition |
| --- | --- |
| Off default | Current plugin legato overlap and sample 0G behavior unchanged |
| PB ±12 C→G / G→C | One held voice reaches target and returns to center as expected on the available reference VST |
| NOTE→SLIDE→NOTE→REST | No unwanted attack during connected slide; fresh attack and REST cleanup correct |
| Two connected slides + Repeat seam | Accumulated bend and cold/steady behavior correct, no stuck pitch |
| Range exceeded | Ordered NOTES still generated; explicit approximation, never source rejection |
| Range dropdown + save/reopen | Selected phrase retains setting; PITCH/TIME unchanged; Live Edit regenerates safely |
| Plugin/MIDI unavailable | Generation and editor continue with actionable warning |
| Existing tests | ACID Lua suite, packaging and one in-Renoise reference check pass; no GitHub workflows |

**Delivery:** one focused implementation PR after M3.5, with matching local Lua specs and a short addition to `tests/acid/acid_m35_s_manual.md`. If the M1 go/no-go check fails, document the blocker and close the spike without building a MIDI routing subsystem. Do not postpone M4 for open-ended testing.

**M3.6 done when:** users can select PB Off or an assumed bend range, ACID writes correct validated phrase commands where supported, existing sample/plugin pathways remain intact, and the single reference-VST playback check establishes working bend/reset behavior. Do not promise identical glide from all VST instruments.

---


## 6. M4 — Exact timing modes and tempo-independent phrase output

**Status:** Straight/Triplet max-length playback, both output policies, loop seam/sentinel, and targeted PB attack/reset checks are pending. M4 remains open for these checks and instrument/phrase synchronization and regeneration safety (M4.7). [Timing checklist](../tests/acid/acid_timing_manual.md).

### M4.0 — Fixed product and API contract (P0; decisions closed)

- Exactly one source setting: `timing_mode = "straight" | "triplet"`, default `straight`. Expose a small **Timing: Straight / Triplet** selector in the existing Program/Grid editor, not a new playback strategy or a time-signature setting. Program and Grid operate on the same source. No swing, groove, user-defined note division, tempo multiplier or song setting writes.
- **Straight** = sixteenth-note step = 1/4 quarter-note beat. **Triplet** = eighth-note triplet step = 1/3 quarter-note beat (three steps occupy one beat). The label must say **1/8 triplet**, not 1/16 triplet. Source LAST STEP is 1–32 in both modes; changing modes changes *duration*, never PITCH/TIME entries or pitch consumption.
- A cycle with N active TIME steps lasts exactly **N/4 beats** in Straight or **N/3 beats** in Triplet. 16 straight and 12 triplet steps both last four beats; 12 straight and 9 triplet steps both last three beats; 15 triplet steps last five beats. Do not round a cycle to a bar. Odd lengths and non-bar-aligned loops are intentional, including 7/8 arrangements where no integral number of eighth-triplet steps spans a 3.5-beat bar.
- Time signatures/metrical grouping are **not** a subdivision clock. Renoise's transport exposes a metronome beats-per-bar property, not a phrase meter that ACID should copy. A phrase starts at its Renoise trigger position and repeats at its own length; it does not silently re-phase at measure boundaries. Do not inspect or alter metronome, pattern length, BPM, song LPB, transport TPL, sequence position or instrument routing as part of rendering.
- Renoise API 6.2 documents independently writable `renoise.InstrumentPhrase.lpb` (1–256), `shuffle`, native line/loop properties and script `render_to_pattern({lpb=...})`. `renoise.Transport.lpb` (1–256), `bpm` (32–999) and `tpl` (1–16) are song controls; the tool must not reconfigure them. Use the pinned SDK for exact names, mutability, bounds and line-index semantics. The modern `TIMING_MODEL_LPB` is the acceptance target. Legacy `TIMING_MODEL_SPEED` uses TPL instead of song LPB: detect/report its timing as unsupported or unverified without modifying the song, silently pretending conformance or corrupting an owned phrase.
- Native phrase LPB, not song LPB, defines ACID's step clock. Explicitly force native phrase `shuffle = 0` and seal/verify that property. If song groove, host sync or a receiver affects actual playback, measure and identify that host/receiver limitation; never claim its effects were normalized by the source compiler.
- Verified reference basis: Roland R04 (printed original straight/triplet limits) and pinned API 6.2; the supported Pattrns `pattern {unit, resolution}` syntax is documented at https://renoise.github.io/pattrns/API/pattern.html and https://renoise.github.io/pattrns/guide/timebase.html. Do not use replacement firmware's unfinished triplet toggle as the timing oracle.
- M4 implements timing for the **current single 32-position source model**. The M5 Original/Extended programming UI is not implemented here. Original-compatible lengths (straight 1–16, triplet 1–15) are informational, not a new M4 mode or an excuse to reject valid sources within capacity.

### M4.1 — Exact model and one physical layout (P0)

| Property | Straight | Triplet |
| --- | ---: | ---: |
| Musical step | 1/4 beat | 1/3 beat |
| Internal integer units per beat | 24 | 24 |
| Units per TIME step | 6 | 8 |
| Half-step gate offset | 3 units | 4 units |
| Native phrase LPB | **16** | **12** |
| Native phrase lines per TIME step | **4** | **4** |
| Pattrns pulse | `unit = "1/16"`, `resolution = 1` | `unit = "1/8"`, `resolution = 2/3` |

- Add one small pure-Lua `model/timing.lua` (or a similarly focused module) that validates the two modes, returns the immutable layout and maps semantic steps to musical units and native lines. Musical timestamps are integers: `start_units = (step - 1) * units_per_step` and `mid_units = start_units + units_per_step/2`. No BPM-in-seconds calculations, repeated floating-point rounding, transport-dependent scaling or arbitrary LPB-grid search.
- Each source step occupies four phrase lines. Source step is `((s-1) % N)+1`; the layout defines first-line, midpoint and articulation placements. The existing 256 gate subdivisions per step remain an articulation-local coordinate, translated at the layout boundary.
- **Play Once**: render N physical steps into exactly `4*N` phrase lines, with explicit terminal release and no native looping. **Repeat**: render N cold + N steady physical steps into `8*N+1` lines, native looping from `4*N+1` through exclusive end `8*N+1`, with an empty end sentinel. At N=32 these are 128 and 257 lines respectively, under the 512-line phrase limit. Repeat has 128 loop lines, lasting 8 Straight beats or 10⅔ Triplet beats; the sentinel is not audible.
- Start, midpoint, loop-start, exclusive-end and source-step mapping must be computed from the same layout, with integer assertions, rather than recalculated in the GUI, Pattrns writer, validator, gate/glide plan or pitch-bend plan. Preserve output-policy and phrase ownership semantics exactly. Thread four-line placement through timing-sensitive planning and validation.
- All NOTE/TIE/REST semantic traversal, first/repeating state, outgoing SLIDE, equal-pitch connection and PITCH cursor reset remain unchanged. The timing compiler consumes the semantic plan; it never rewrites source, invents NOTE commands, pads a bar or changes loop identity.

### M4.2 — Rendering and collision rules (P0)

1. **Single layout, propagated end-to-end.** Freeze the selected layout in the staged job: Straight LPB 16, Triplet LPB 12, four phrase lines per source step. Both script rendering and final phrase metadata must use the same layout; validate before sealing/replacement. Always set and verify `phrase.shuffle=0`. Do not change the source or destination on a failed job.
2. **Pattrns exact pulses.** In `writers/pattrns_writer.lua`, emit the appropriate `unit` and `resolution` from the layout and otherwise retain existing finite source, pulse/event ordering, volume/accent expectations and async render handling. The API documents the triplet factor; do **not** emit unsupported `unit="1/12"` or assume changing LPB alone makes `unit="1/16"` a triplet. The fractional Pattrns factor is an emitter detail, **not** the timing truth: read back and validate every expected line against the integer layout, including step 32 and both physical cycles.
3. **Bounded renderer contingency.** If Pattrns on the pinned Renoise build quantizes a triplet event onto the wrong line, refuses the `resolution`, or accumulates an offset, stop using that triplet render output. Implement the *smallest* staged native-cell NOTE/OFF emitter from the same semantic plan and exact line map; reuse existing articulation, validator, ownership and rollback. No tempo-specific tolerance, adaptive grid search, silently rounded note positions or separate playback engine. Do not change straight rendering unless a failing test requires it.
4. **Gate and sample glide.** Keep the semantic gate timeline at 256 units per source step and map it to the four-line layout. Release after a terminating NOTE, not across a valid TIE/connected SLIDE, and leave REST releases at the semantic step start. Keep `0Gxx` on available phrase lines and retain collision/approximation policy. Do not silently drop a gate or required effect.
5. **Plugin/MIDI legato and PB.** Keep NOTE-before-delayed-OFF ordering, column isolation, same-pitch hold, range-overflow fallback, 14-bit bend anchor/centering and cold-to-steady/steady-to-steady checks. A fresh NOTE uses delay 1 plus center reset only when the bend channel is not known centered; otherwise it uses delay 0. The 1/256-line ordering unit is per event, Renoise-host-tick-quantized, bounded and not sample-accurate. Targeted host verification of reset/attack alignment remains pending. Protect M1 cells and reset at a loop seam. Any unreproducible slide is a **named per-step approximation**, not a source rejection or stuck receiver note.
6. **One collision policy.** Build/validate sparse NOTE, REST/OFF, gate, glide, legato and PB operations before mutating phrase cells. If two operations need an incompatible cell or native event ordering, preserve required note/gate/release safety, attempt the already-defined bounded articulation fallback and report its TIME step/cycle/line. Never overwrite a NOTE with an OFF, clobber M1/effect data, silently skip an operation or damage the existing target. Do not introduce extra effect columns/automation as an unreviewed workaround.
7. **Host and resource bounds.** Preflight API-reported phrase line/column capacity, actual instrument phrase slots, loop endpoints, selected instrument identity, validity of sealed ownership and persistable source before writing. All 1–32 length/mode and output-policy combinations fit the 512-line contract (maximum 257). Preserve source and last-good/foreign phrases on host errors; never truncate the musical phrase.
8. **Post-render verification and commit.** Validate phrase LPB, shuffle, every NOTE/REST/OFF and empty half-step, volumes, effects, pitch-bend commands/reset, loop start/end and exclusive-end sentinel *before* making the staged phrase live. Keep the current asynchronous token invalidation, temporary phrase lifecycle, ownership seal, guarded copy, rollback and Live Edit serialization. Successful generation of an all-REST pattern still has the expected line/loop/LPB metadata.

### M4.3 — Source, editor and persistence (P0)

- Add `timing_mode` to the canonical source and `sequencer.new_pattern` default/validation. Keep both 32-entry memories and their independent active lengths. Mode changes do not alter source entries or pitch consumption.
- Include timing mode in source equality/history so one dropdown change produces exactly one Undo step; Undo, Redo and Reset restore it. Extend Program/Grid summaries, preview duration/step division and diagnostics to show the selected mode and exact N/4 or N/3 beat cycle. No hidden dependence on selected Renoise pattern LPB. With Live Edit Off show the source as dirty until Generate; with Live Edit On regenerate once through the existing guarded queue. Rapid mode toggling while rendering must invalidate stale output.
- Persist the field with committed records and drafts in the sole current WIP schema, `ACID-PITCH-TIME-1`. Invalid, missing or unknown timing modes are rejected, not guessed as Straight.
- Keep `output_policy` and `pb_range` as phrase-specific render settings separate from canonical `timing_mode`. Selecting an existing owned phrase restores the correct source mode and existing PB/output settings. Switching instruments, selecting another phrase, closing/reopening a song, unsaved session drafts and new/foreign-phrase Live Edit recovery must not cross-wire timing between sources.
- Update `README.md` and a short Renoise manual verification checklist *during implementation*, not as a substitute for it. Keep `manifest.xml` at experimental 0.1 and API 6.2, package just ACID runtime files. No GitHub workflow or background listener for BPM/LPB changes.

### M4.4 — Explicit defect/blocker handling (P0)

| Risk or current dependency | Required resolution / fail-safe |
| --- | --- |
| Phrase layout and gate mapping | Use four lines per source step at LPB 16/12; map the 256 gate units through the selected layout |
| Triplet renderer pulse/readback can quantize incorrectly | Emit documented `1/8 × 2/3` pulse; assert exact four-line layout readback; use narrowly scoped native-cell contingency only if it fails |
| Articulation, legato, gate and validation placement | Thread the four-line source-step layout through planning and validation |
| Note-delay/PB center-reset ordering uses 1/256 phrase line | Conditional reset: delay 1 plus center reset only if bend channel is not known centered; otherwise delay 0. Host-tick-quantized, not sample-accurate; targeted Renoise check pending |
| Pitch-bend command generation does not establish receiver delivery | Keep receiver support bounded to actual Renoise checks; preserve safe overlap fallback/diagnostic if unsupported. Do not infer general receiver support from command generation |
| Transport speed timing model or unverified song groove | Detect/document; never rewrite global settings or silently certify musical timing not established in that host mode |
| Async render during a timing toggle/target change | Snapshot timing/target, cancel stale jobs, commit only current tokens; keep last-good phrase on cancellation/error |
| Invalid current source data / modified phrase | Reject safely; preserve tool data and do not adopt or mutate foreign content |
| Renoise host/resource cap or collision | Precise error + source retained + no partial destination replacement; allow scoped sonic approximation only when notes and releases remain correct |

**Blocker discipline:** first reproduce a failure in a deterministic local Lua spec or one small in-Renoise fixture; identify the source/host capability; use the specified narrow fallback; re-run full regression tests. If no safe fallback can produce the correct NOTE/REST musical timeline, report a hard phrase render failure without committing. Never claim every arbitrary VST, external MIDI receiver or host groove obeys ACID's articulation solely because valid note cells were written.

Phrase timing contract is LPB 16/12 with four lines per source step and protected staged commits. New host validation remains pending. Receiver-specific sound quality remains separately bounded.

### M4.5 — Closure gates

1. **Timing:** exact model, strict source/draft persistence, phrase LPB 16/12, four lines per step, output-policy lengths and repeat sentinel; structural validation and targeted Renoise playback checks.
2. **Renoise behavior:** complete M4.7 instrument and phrase synchronization, in-place regeneration, new-phrase intent, Live Edit cancellation, source/draft preservation and native selection safety.
3. **Manual smoke:** one disposable song; switch instruments and owned phrases while ACID is open, create once, regenerate in place, save/reopen and exercise Live Edit during playback. Check transport stop/start/seek and tempo response. No new WAV export or measurement required.
4. **Local:** `pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID` and `pwsh -NoProfile -File ./scripts/package.ps1 -Tool ACID` after implementation changes.

### M4.6 — Acceptance status

| Scope | Result |
| --- | --- |
| Current max-32 Straight/Triplet playback | Pending: LPB 16/12 and four lines per step |
| Play Once and Repeat boundaries | Pending: N=32 lengths, loop seam and exclusive-end sentinel |
| Targeted plugin PB attack/reset alignment | Pending after conditional-reset/layout change |
| Local verification | Pass: 32 ACID specs, oracle controls, 25-file ACID package and archive licenses |

Articulation resolution is layout-driven through planning and validation.
Pitch-bend center reset is conditional on whether the channel is known centered;
targeted Renoise verification remains pending.

The [timing checklist](../tests/acid/acid_timing_manual.md) defines the current
host checks. Independent click-track capture, repeated WAV exports and a VST
compatibility matrix are not required; use targeted diagnostics for a reproduced
defect.

### M4.7 — Instrument/phrase synchronization and regeneration safety (P0)

Implementation follows the dependency-ordered [runtime refactor playbook](M4_7_RUNTIME_REFACTOR_PLAYBOOK.md). Its fixed policies are normative. Complete each gate before its dependent work; failed evidence returns to the responsible contract.

- [x] Inventory, API 6.2 references, baseline, and early native copy/restore, notification, and undo feasibility; findings incorporated into the playbook contracts.
- [ ] Shared validation/store contracts and complete field-preservation policy.
- [ ] Runtime context, raw object identity, guards, and blocker state.
- [ ] Explicit create/regenerate writer and one cancellation/completion handshake.
- [ ] Explicit Make Independent for matching valid collision groups; no automatic re-keying or source-less adoption.
- [ ] Draft precedence, recovery chooser, read-only revalidation, and one manual/Live Edit request pipeline.
- [ ] Native observers, internal mutation reconciliation, and release/late-callback handling.
- [ ] Remove competing paths; pass all 35 focused regressions, existing suites, and required package checks.
- [ ] Pass native acceptance A–E, including field preservation, drafts, cancellation, copies, and undo.
- [ ] Final documentation/review and focused commit; keep M4 open until acceptance passes.

Gate 0 repository evidence was rechecked on 2026-10-29: pinned SDK setup
succeeded, definitions and offline docs were inspected, runtime/storage call
sites were inventoried, and all 34 ACID specs passed. The
[prerequisite feasibility record](../tests/acid/acid_m35_s_manual.md#prerequisite-feasibility-record)
contains the inventory, native observations and tested unsupported-script
rejection predicate. **Step 0 is complete**; Step 1 proceeds under the revised
contracts. This closes the prerequisite investigation, not native acceptance.
Native follow-up in Renoise 3.5.4 / API 6.2 found that undo can restore old
notes/seal while retaining the newer source record; the existing loader accepts
the mismatch. The playbook therefore
requires independent source/output compatibility validation, including after
reload, or blocked regeneration with explicit source recovery to New. Valid
seal plus valid source alone cannot authorize writing. Steps 1/3/4/6 implement
and test these requirements; Step 8 verifies the finished native behavior.

- **Live Edit scheduling:** real edits dispatch immediately through one serialized request pipeline, retaining only the latest pending snapshot. Arming, no-op edits, navigation and restoration enqueue nothing. A canceled in-flight render retains occupancy until its terminal callback; stale or blocked completion cannot automatically authorize another write. No debounce timer.
- **Live inventory:** newly added, deleted, renamed and reordered Renoise instruments appear in ACID without reopening. Track native selected instrument and phrase using supported API 6.2 observables and a guarded idle update. Detach notifiers on close/song change.
- **Binding:** resolve the exact instrument object and ACID-owned phrase identity, not a cached index. Follow user-initiated native selection; ignore internal staging selection changes. Preserve per-phrase source, timing, PB Range, output policy and uncommitted drafts on A → B → C → A switches.
- **Regenerate:** require a valid, explicit bound owned phrase. Replace it in place; keep phrase count, identity and native playback program stable. Do not fall back to the first phrase or to append on missing, modified, foreign or deleted destinations.
- **Create:** create exactly one final destination through Generate or a real source/settings edit while Live Edit is armed and New Phrase is explicitly bound. Navigation, arming, and draft recovery never generate. Create needs one staging slot; regenerate needs two temporary slots and keeps the same destination object.
- **Asynchronous safety:** capture instrument/phrase identity and selection revision; reject stale or deleted targets and in-flight output on user context changes without touching unrelated content. Failed commits preserve last-good phrases and editable drafts. No automatic reroute to a different instrument.
- **UI:** keep instrument and destination options current and show a clear Create versus Regenerate action. A missing or unsafe destination reports the actual reason and requires explicit resolution.
- **Tests:** deterministic notifier, add/delete/reorder/rename, duplicate-ID, rapid-switch, stale-callback, ownership and rollback regressions; one Renoise session exercising selection, generation, Live Edit and save/reopen.

**M4 closure:** M4.7 passes the playbook's local/package gates and native acceptance A–E. An unresolved native feasibility or integrity blocker keeps M4 open. No additional acoustic research is required.

---

## 7. M5 — Source programming and Renoise workflow

**Goal:** complete source programming and editing, with native Renoise handling arrangement and performance. Program and Grid edit the same canonical source; optional Extended transformations operate on that source without switching semantic Entry mode.

### M5.0 — Roland-style Program view (same source as Grid)

- Complete M3.5's Program view with sequential PITCH entry/check, independent TIME cursor, octave controls, back/correction and pitch audition. Grid is an alternate view of the **same source**, not a separate Extended music mode.
- Implement clear, re-enter PITCH, edit one pitch and re-enter TIME as explicit commands. Apply R02's flag-reset behavior only to an explicitly selected Roland-style re-entry operation; Grid editing and view switching never reset flags. Provide undo and labels for affected memory.
- Support pitch-owned ACCENT/SLIDE editing during pitch review; page/selection movement never edits the source. Keep M2's leading-TIE normalization in the shared command path for both entry modes.
- Specify TAP timing entry/check and its clock/quantization before implementation; do not confuse TAP audition with real-time TIME recording. Consult the relevant manual procedure and record it before claiming panel-operation fidelity.

**Acceptance:** build the same pattern via Program and Grid and compare byte-equivalent canonical source, decoded events and playback. Include >16 steps, arbitrary active PITCH span, PITCH versus TIME re-entry, flag preservation/reset, cursor restart, correction, cancellation, view changes and save/reopen.

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
- Build on M3.5's latched Live Edit and typed result states. Do not change unrelated tracks, instrument routing, sample setup, plugin configuration or phrase contents as an invisible side effect.

### M5.3 — Editor refinement

- Improve page/current-step indicators, keyboard legibility, used versus unused PITCH markers and precise error navigation.
- Distinguish **stored C entry**, **referenced PITCH entry**, and **user-modified PITCH entry**; avoid conflating edit history with musical validity.
- Refine M3.5's dirty/queued/rendering/committed/approximate/suspended/error states and durable draft workflow; do not reinvent the Live Edit scheduler in M5.
- Maintain responsive Live Edit with many phrases and max-32-step patterns; avoid regenerating on selection-only UI clicks.

**M5 done when:** a user can program through Program or Grid, apply the three scoped Extended transformations, duplicate/select and revisit current-format ACID source in a saved XRNS. Preview and output agree, edits are reversible, and Renoise provides arrangement/performance without an ACID substitute. Native playback limitations remain documented.

---

## 8. M6 — Hardening, regression coverage and release readiness

### M6.1 — Data safety, undo and persistence

- Exercise undo/redo during manual regeneration and asynchronous Live Edit; reconcile stored canonical source and generated phrase ownership after changes.
- Verify deletion/reordering of instruments and phrases does not cause stale IDs or destination indices to overwrite another phrase.
- Test cancellation, document close/reopen, interrupted rendering, malformed snapshots and a failed post-render `tool_data` save.
- Prefer a transaction-like contract: no “success” status unless the phrase and its canonical source are both committed and consistent. Audit/repair partial-commit paths.
- Define the current stored schema deliberately and test its roundtrip and strict validation.

### M6.2 — Reliability and performance

- Test 32-step all-NOTE sequences, dense articulation, multiple phrases, repeated Live Edit batches, and long song sessions.
- Verify there are no leaked timers, observers, temporary phrases, unexpected playback-mode changes or accumulating event data.
- Run ACID local specs and the ARP suite when shared repository utilities change.

### M6.3 — Documentation and release packaging

- Keep `README.md`, `DESIGN.md`, and this roadmap aligned with the current source and phrase contracts.
- Write current user instructions for creating, editing, looping, Live Edit, storing/reopening, phrase selection and limitations.
- Package ACID with the repository's PowerShell 7 script, verifying `main.lua` and `manifest.xml` at archive root and no SDK/test files.
- Decide version/tag **after** demonstrated functionality; manifest `0.1` stays unchanged until a release decision. Do not imply all analog aspects of the original TB-303 are reproduced.

**M6 done when:** documented host/device support is verified to the declared scope; local tests, release package inspection and documentation agree; there are no unresolved data-loss regressions.

---

## 9. Mandatory test and acceptance matrix

| Behavior | Lua (no Renoise) | Renoise manual |
| --- | --- | --- |
| PITCH/TIME NOTE/TIE/REST consumption | Semantic compiler state/fixtures | Decoded preview versus rendered phrase |
| Program versus Grid view (M3.5-S) | One source, independent TIME/PITCH bounds through 32, byte-equivalent semantics, view-change purity | Switch views on 17/32-step source with span 3; generated phrase unchanged |
| Current WIP source schema | `ACID-PITCH-TIME-1`; exact encoding, decoding and roundtrip validation | Fresh source save/reopen |
| Default C + 32-position storage | Initial state and validation | Fresh-pattern controls and output |
| LAST STEP, Reset and two pages | 1/16/17/32 lengths; Reset and Reset Undo restore source and output policy | Edit 16/17/32, reset once, undo, confirm boundary entries intact |
| Repeated phrase loops | At least three semantic cycles | Audible/visual repeats across several cycles |
| Repeat versus Play Once (M3.5-S) | Cold/steady source independent of output policy | Change owned phrase output without changing musical source or instrument-wide playback settings |
| Selected phrase regeneration (M3.5-S) | Regenerate the second owned phrase in place; preceding phrase unchanged | Select and regenerate second phrase; chooser remains on that phrase |
| Leading/trailing TIE, REST, SLIDE | Explicit boundary state assertions | Phrase boundary and actual envelope response |
| Gate, release and slide collision | Scheduled timeline/collision tests; sample 0G coverage ends before midpoint OFF | OFF locations and recorded attack/release |
| Instrument-agnostic phrase writing (M3.5) | Capability fixtures, no sample-buffer admission | Sample, plugin-only and empty slot smoke; other receiver families deferred to M6 |
| Articulation safety (M3.5) | Interval/layout fuzzing; explicit approximation reporting | Reference sample/VST smoke; broader fidelity in M6 |
| Plugin/MIDI commands (M3.5) | Target-compatible operations; pitch-bend safeguards | Reference VST smoke; additional MIDI capture only for a reproduced receiver defect |
| Optional PB Range (M3.6) | Off/±2/±12/±24/±48; pitch anchor, bend limit, center reset, loop seam, no source mutation | One VST phrase bend/reset check; Off regression and selected phrase save/reopen |
| Live Edit recovery (M3.5) | Typed result, armed/dirty/pending/retry/suspend transitions | Editing during playback, recoverable failure, undo, ownership loss, song change |
| Straight and triplet timing | Exact grid, 4 lines/step, output lengths and repeat endpoints | Pending max-32 LPB16/12, both policies, loop seam/sentinel and targeted PB alignment checks |
| Instrument/phrase synchronization (M4.7) | Addition, rename, reorder, deletion, identity and stale callback tests | Live inventory; native selection sync; regenerate exact owned phrase in place; explicit creation only |
| Roland-style re-entry/check workflow | Separate cursors and explicit command/flag reset rules | PITCH audition, TIME review, back/correction, switch view, undo |
| Independent PITCH/TIME randomization | Seeded output, valid N/T/R and spans, other memory unchanged | Preview/output agreement, undo and Live Edit |
| Targeted transformations | Exact flag/command changes, unaffected source unchanged | Action scope, undo and regenerated result |
| Non-destructive scale mask | Raw PITCH unchanged, deterministic mapping, bounds, bypass and roundtrip | Resolved preview/output agreement; slide connection after pitch mapping |
| Trigger, stop/start and seek | Explicit cold/repeat context, no stale voice | Sustained versus fresh trigger, release, transport, selective/keymapped coverage |
| Live Edit under pressure | Immediate dispatch, single-flight, automatic pending edits | Rapid UI edits while playing |
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
4. **Original gate and accent envelope:** TB-303 behavior versus achievable sample instrument response.
5. **Original triplet/time programming:** apply R04 grid/limits; verify actual phrase duration, conversion and no drift. Original TAP and clear/re-entry procedures need their own operator tests.
6. **Persistence semantics:** restore on reopen, handling draft edits without generation, undo versus song-scoped source data.

For every such decision, supply **reference + decision + test fixture + manual playback observation + documented limitation**. If a decision is provisional, indicate that in GUI text and documentation.

## 11. Acceptance work

| Priority | Action | Exit criterion |
| --- | --- | --- |
| P0 | M4.7 live instrument inventory and native selection sync | Add, rename, reorder, delete and switch instruments without reopening or stale bindings |
| P0 | Exact owned phrase regeneration and explicit creation | Existing phrase regenerated in place; switching and target loss never append |
| P0 | Live Edit and persistence safety | In-flight changes never write to stale targets; drafts, source and phrase ownership survive save/reopen |
| P1 | One disposable-song host smoke and local tests | Source, destination, playback and transport remain usable; regression and package checks pass |



**Blocking release rule:** M4 acceptance requires functional destination safety. Broader MIDI/hybrid/VST compatibility and hardware-faithful acoustic research belong to M6 or targeted diagnostics.
