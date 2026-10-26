# ACID M2 blueprint: deterministic repeating PITCH/TIME sequences

Date: 2026-10-26. Status: **proposed implementation contract, not implemented**.
Scope: [ROADMAP.md, M2.0–M2.5](ROADMAP.md#4-m2--continuous-playback-and-loop-correctness).
ACID baseline: `0745a4b1f9417b015f03d43e259dfe3a84618903` on `develop`.
Reference: OS-303 checkout `9a882265a46a73f438a799f4ed338c7c108a04a1`,
inspected read-only; pinned upstream source links appear below.

## 1. Intended result and limits

M2 should make one ACID sequence repeat with deterministic pitch consumption,
correct NOTE/TIE/REST intent, and no reset at a 16-step editor page boundary.
It must preserve existing saved sources and refuse unsafe regeneration. Merely
changing `phrase.looping` does not deliver this result.

This blueprint chooses a proposed software policy: **restart PITCH consumption
at P01 on each complete TIME traversal, while retaining the previous voice's
identity independently**. NOTE consumes an entry from an explicitly selected
active PITCH span. TIE and REST consume none. This policy is informed by the
inspected OS-303 cursor code; it is not a verified description of every original
TB-303 behavior.

Three evidence levels apply throughout:

- **Observed source:** established by the pinned implementation or SDK text.
- **Proposed ACID rule:** a concrete decision for implementation and fixtures.
- **Unverified playback/history:** requires Renoise or original-hardware evidence.

The hardware-informed profile covers TIME lengths 1–16. ACID extends the same
chosen transition rules to 1–64 TIME steps and 1–64 active PITCH entries. Neither
profile is a hardware certification. OS-303 itself supports 32 positions, so it
does not establish ACID's 64-step extension.

M2 does not change accent voicing, calibrate the gate fraction, introduce a
synthesizer, add ratchets or triplets, or prove envelope-continuous sample glide.
Those remain outside this work package. Manifest version `0.1`, scripting API
6.2, Lua 5.1 compatibility, tool independence and existing ARP boundaries remain
the implementation constraints.

## 2. What the OS-303 reference actually implements

### 2.1 Identity, ownership and execution

[OS-303](https://github.com/djphazer/OS-303/tree/9a882265a46a73f438a799f4ed338c7c108a04a1)
is Nicholas J. Michalek's firmware for a TB-303 CPU replacement, targeting the
AT90USB1286 / Teensy++ 2.0. Its README calls the sequencer an imitation with
additional features. It drives physical pitch, gate, accent and slide outputs;
there is no digital oscillator/filter/audio-render implementation to port into
ACID. Source is MIT licensed; this blueprint proposes independent Lua behavior,
not copying firmware code. Any later copied implementation must retain the
applicable license notice.

The inspected architecture is:

```text
DIN/MIDI clock + switches + live MIDI
                    |
               main.cpp loop()
                    |
           one static Engine instance
          /                         \
Sequence pattern[16]          chain/clock/gate/slide state
          \                         /
             pitch/gate/accent/slide getters
                    |
            drivers.h DAC outputs
                    |
             external analog circuitry

EEPROM <---- Engine Load/Save + pattern/settings records
```

`Sequence` owns stored pitch/time data and its cursors; `Engine` manages selected
pattern, chain, six-clock step division, resting state and gate/slide state.
`main.cpp::loop()` collects clock/UI/MIDI events and writes the resulting control
outputs. It is a hardware control sequencer, not a Renoise phrase engine.

### 2.2 Reproducible source map

All links below point to the inspected commit, not a moving default branch.

| Evidence | Source and symbols | What it establishes |
| --- | --- | --- |
| F01 | [engine.h:14–30, 58–76](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/engine.h#L14), `MAX_STEPS`, `Sequence` | 32 pitch bytes; eight packed TIME bytes; shared length defaults to 16; runtime cursors are separate members |
| F02 | [engine.h:62–70](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/engine.h#L62), `time_data`, `length` | TIME codes are REST=0, NOTE=1, TIE=2, RATCHET=3; there is no independent active PITCH length |
| F03 | [engine.h:159–163, 234–259](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/engine.h#L234), `SetLength`, `Sequence::Advance`, `AdvancePitch` | TIME wraps modulo length; entering TIME position zero resets the PITCH cursor; NOTE/ratchet consume pitch, TIE/REST do not |
| F04 | [engine.h:547–581](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/engine.h#L547), `Engine::Advance` | Outgoing slide state is evaluated before advancing; TIE after REST remains resting; a current slide or following TIE requests gate hold |
| F05 | [engine.h:591–610](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/engine.h#L591), `Clock`, `Reset` | Six incoming clocks per step; reset clears resting/hold/slide runtime and starts the next step from reset state |
| F06 | [engine.h:709–719](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/engine.h#L709), `get_gate` | Rest suppresses gate; held gate spans clocks; ordinary gate is high for the first three of six clocks; ratchet has its own branch |
| F07 | [main.cpp:874–924, 994–1024, 1058–1081](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/main.cpp#L994), `loop` | MIDI/DIN transport drives the engine; live MIDI can override output; running playback writes current engine pitch/accent/slide/gate to hardware |
| F08 | [engine.h:25–26, 87–115](https://github.com/djphazer/OS-303/blob/9a882265a46a73f438a799f4ed338c7c108a04a1/src/engine.h#L25), pitch getters | This checkout contains an empty-pitch sentinel and default C representation; these are distinct, not evidence that untouched ACID C entries are invalid |

The checkout was clean and local `HEAD`, `main` and `origin/main` agreed. No fetch
was performed; that observation does not claim the checkout is latest upstream.

### 2.3 Cursor trace and the important leading-TIE caveat

In forward playback, the relevant behavior is equivalent to this source trace:

1. Advance TIME, unless processing the first step after reset.
2. At TIME position zero, set `pitch_pos=0` and mark its next advance as the first.
3. On NOTE/ratchet, use the first pitch without incrementing on that first use;
   subsequently advance PITCH modulo the same shared sequence length.
4. TIE/REST leave the consumption cursor unchanged.

This supports choosing TIME-cycle cursor reset in ACID. It does **not** supply
an independent PITCH-length policy: the firmware uses one length for both.

There is also a behavior ACID should not inherit accidentally. At a TIME wrap
whose first command is TIE, `Sequence::Advance()` resets `pitch_pos` to zero
without consuming a pitch. The output getters read that position, and
`main.cpp::loop()` sends it to the DAC. Therefore, by source-level inference,
the pitch/accent control inputs during that leading TIE can come from PITCH[0],
rather than the final sounding pitch. `gate_hold` is also recomputed from this
position and the following TIME cell. The acoustic result has not been measured.

ACID must keep **next PITCH to consume** and **voice currently held** in distinct
state. Resetting the former must never retune the latter. Preserve this case as
a documented divergence from the inspected firmware, with a regression fixture.

Other details to avoid treating as ACID requirements: ratchet, reverse direction,
chain/transpose/quantizer behavior, four octave codes, packed EEPROM layout and
empty sentinel. The `Sequence` size comment is stale: the declared persisted
arrays plus metadata are 32+8+8 bytes, not the comment's 32+16+8. Derive behavior
and storage expectations from declarations and code, not comments alone.

### 2.4 Conformance evidence still missing

| Question | Present evidence | M2 treatment / additional evidence |
| --- | --- | --- |
| Independent PITCH/TIME programming | ACID source and OS-303 separate arrays | Keep independent memories; obtain original operator documentation before historical claims |
| Original LAST STEP limits | OS-303 is an extended 32-step implementation | Label ACID 64-step range as an extension; do not infer original limits from firmware |
| PITCH reset at TIME repeat | F03 establishes this checkout's policy | Adopt as a named ACID policy; original CPU behavior remains unverified |
| Leading TIE and original voice continuity | F04 plus the F03/F07 caveat | ACID holds the actual prior voice; acquire a verified hardware trace before claiming fidelity |
| Slide across a TIME boundary | Firmware slide output state | Keep outgoing semantic slide; do not equate a control pin with native sample glide |
| Cold first trigger | F05 starts resting | ACID starts silent; verify phrase trigger/retrigger in Renoise |
| Gate duration and analog release | F06 is firmware logic | Keep existing experimental gate setting; numerical/historical calibration belongs to M3 |

No original Roland manual, original CPU trace, or measured hardware recording
was validated in this research pass. A future evidence record should include
document revision/page or recording setup, pattern, clock grid, observation and
how it compares with the chosen rule. An upstream comment or demonstration title
alone is insufficient.

## 3. Current ACID architecture and the changes M2 requires

Paths in this section are relative to this tool directory. Line references name
the inspected baseline and may move after implementation.

| Component | Current contract | Required M2 responsibility |
| --- | --- | --- |
| `model/sequencer.lua:24–35, 67–99` | New patterns allocate 64 valid C pitches; dense arrays may be shorter; no active span field | Validate explicit active PITCH span separately from capacity; retain valid defaults |
| `model/compiler.lua:14–78` | One cold pass; pitch index is NOTE count modulo stored pitch count; boundary summary is a heuristic | Stateful cycle transition; explicit cold/repeat entry, full step events and cycle exits |
| `model/editor_state.lua:21–85` | Reimplements consumption using stored array length | Project the compiler's resolved mapping, including cold/repeating TIE differences |
| `model/memory_status.lua`, `gui.lua:80–156` | Stored/used pitch counts and direct editing | Distinguish capacity, active span and pitches actually referenced |
| `model/pattern_store.lua:6–76, 111–136` | `ACID-PITCH-TIME-1`; source+audio mode; variable stored pitch count; sealed phrase ID | Versioned source fields, lossless v1 load, explicit loop conversion |
| `writers/pattrns_writer.lua:66–90` | Finite one-pass script, `repeats=false` | Emit finite physical render segments; leave runtime repetition to the native phrase |
| `writers/phrase_writer.lua:80–174` | Validates one traversal, applies articulation, sets `looping=false`, swaps then stores source | Choose representable loop layout, validate final cells/metadata, commit source and phrase coherently |
| `writers/phrase_validator.lua:6–82` | Checks cold-pass NOTE/OFF/empty cells before articulation | Check the complete physical layout and post-articulation result against the selected plan |
| `writers/phrase_ownership.lua:8–90` | Seal includes `looping`, omits `loop_start`/`loop_end`; name embeds ID/hash | Version seal format and protect loop range without invalidating old seals |
| `model/control_signals.lua`, `model/articulation.lua`, `writers/gate_writer.lua` | Experimental one-pass gate/glide placement | Resolve cyclic predecessor/successor relationships without changing sound calibration |
| `model/live_regen.lua`, `gui.lua:378–400` | Debounced, serialized generation; UI manually copies current pattern fields | Copy all new source fields into an immutable job; guard completion against stale target/song state |

The current writer removes its destination backup before `store.save()`. A failed
source save can leave changed audio without the source that generated it. This
is existing debt relevant to M2's schema work, not an already solved transaction.
Cancellation also needs cleanup coverage: `cancel()` detaches observers and drops
the job; it does not itself implement complete temporary-phrase rollback.

Proposed ownership/dependency flow:

```text
GUI source draft --> model validation + explicit settings
                          |
                   pure cycle interpreter
                    /                 \
        decoded preview + fixtures    cold/repeating render plan
                                              |
                                   representability preflight
                                              |
                                  finite pattrns staging render
                                              |
                                gate/slide placement + validation
                                              |
                              native phrase metadata + new seal
                                              |
                       guarded phrase/source commit + job completion
```

Source memory remains canonical. Generated phrase cells, cursor state and editor
page selection never become a substitute for source PITCH/TIME data.

## 4. Proposed decisions for implementation

These decisions make the next implementation reviewable. They do not imply M2
has shipped or that unresolved playback behavior has been approved as accurate.

| ID | Proposed decision | Reason / verification |
| --- | --- | --- |
| D01 | PITCH capacity is 64; `pitch_length` is the active prefix P01..Pnn, 1–64 | Explicit span; no edited/non-C inference; old effective span can be preserved |
| D02 | New drafts default to `pitch_length=64` | Preserve current default source behavior; users explicitly shorten the span |
| D03 | Reset the next-consumed PITCH cursor to P01 at every TIME-cycle start | Informed by F03; fixed M2 policy, no polymetric/carry option in this milestone |
| D04 | Retain voice identity across TIME wrap, independently of D03 | A leading TIE holds the prior voice, not P01; deliberately avoids the firmware caveat |
| D05 | Only NOTE consumes pitch; wrap consumption at `pitch_length` inside a cycle | Independent memories; exact fixture expectations for mismatched counts |
| D06 | REST clears voice and outgoing slide connection; silent TIE remains silent | Next NOTE after REST attacks; no pitch consumed by either command |
| D07 | SLIDE belongs to the outgoing PITCH entry, including same-pitch transitions | Existing ACID convention; semantic intent is separate from renderer support |
| D08 | V1 sources load as legacy one-shot and preserve their effective pitch span | Reopening a song must not enable repeat or silently change its sound |
| D09 | Selecting Repeat on a legacy source explicitly adopts M2 semantics | Make compatibility choice concrete; selection alone does not rewrite the saved phrase |
| D10 | New M2 drafts default to Repeat once its writer path passes the playback gate | During incremental development keep unfinished loop output unavailable |
| D11 | Render only verified representations; unsupported continuity is a refusal with locations | No silent attack substitution or global glide modification |
| D12 | Keep the current gate calibration/audio modes while fixing cyclic connectivity | M2 handles repetition; M3 owns gate/slide fidelity |

In D01, changing LAST STEP does not change `pitch_length`; changing the active
PITCH span does not delete inactive stored entries. Editing P40 while the active
span is three leaves it stored and inactive. It must not expand the span silently.

Example: 12 TIME commands contain five NOTE commands, with active pitches
`[C, D#, G]`. Every cycle consumes P01,P02,P03,P01,P02. The next cycle restarts
P01. With five pitches and only three NOTE commands, each cycle uses P01,P02,P03;
P04/P05 are active storage but unreferenced. A carry policy would produce a
different sequence and is explicitly excluded from this M2 profile.

## 5. Pure repeating interpreter

### 5.1 Source and state contracts

Proposed canonical M2 source fields (audio mode stays alongside the pattern in
the stored entry, as today):

```lua
{
  length = 12,                 -- TIME cycle length, 1..64
  pitch_length = 3,            -- active prefix, independent of length
  semantics = "cycle_reset_v1", -- reset pitch consumption at TIME-cycle start
  playback = "loop",          -- "one_shot" or "loop"
  pitch_events = { ... },      -- exactly 64 entries in canonical v2 storage
  time_events = { ... }        -- exactly length N/T/R commands when complete
}
```

Runtime state is not persisted:

```lua
{
  cycle = 1,
  time_step = 1,
  next_pitch = 1,
  voice = nil, -- or {note, pitch_index, accent, slide, origin_cycle, origin_step}
  hold_intent = false,
  entry_kind = "cold" -- or "repeat"
}
```

`voice` means retained semantic note identity, not proof that a particular
Renoise sample voice or analog envelope remains sounding. `hold_intent` records
connection requirements for the gate layer; it must not be equated with the
current numerical gate duration. Store `pitch_index` in the voice separately
from `next_pitch`; they can legitimately differ at a loop boundary.

`origin_cycle`/`origin_step` are diagnostic provenance only. Exclude them from
semantic equality and periodicity comparisons; they never affect pitch, gate,
slide or ownership decisions. Fixture exit voices intentionally omit them.

The source validator may continue to accept incomplete drafts. Compilation
requires complete TIME and a valid active prefix for every NOTE. An empty pure
draft with no NOTE remains valid silence; normalize it to 64 default C entries
and `pitch_length=64` before v2 persistence. Reject an empty pitch stream with
NOTE rather than inventing pitches during compilation.

### 5.2 Proposed API and invariants

Keep `compiler.compile(pattern)` as a cold-pass compatibility facade. Add a
cycle interpreter in `model/compiler.lua`, or a small private
`model/loop_state.lua` if that keeps state transitions clearer:

```text
compile_cycle(pattern, entry_state) -> cycle_plan, exit_state | error
compile_cycles(pattern, count, initial_state) -> cycles, final_state | error
plan_loop(pattern, render_options) -> cold, steady, boundary, diagnostics | error
```

`compile_cycle` starts TIME at step 1 and resets `next_pitch=1` for the M2
profile. It accepts the retained incoming voice separately. `compile_cycles`
calls the same transition engine, without duplicating the NOTE/TIE/REST logic.
Reject invalid cycle counts and cap test/preview work; never run an unbounded
"find a repeating state" search inside a UI callback.

Events include cycle, absolute step, local TIME step, kind, consumed pitch index
when applicable, retained voice identity, transition and connection requirement.
Preserve existing `note`, `accent`, `slide`, `from_note`, `holds`, `releases`
where compatible, so consumers can migrate in focused commits.

Required invariants:

1. No source mutation; identical source+entry state gives identical output.
2. TIME advances once per command; only NOTE advances next PITCH.
3. Page calculations are absent from traversal and boundary code.
4. PITCH reset never changes the retained voice's note, accent or slide.
5. REST removes both retained voice and pending outgoing connection.
6. Cold start has no incoming voice; repeat entry uses the prior exit state.
7. The compatibility facade and the first multi-cycle pass agree exactly.
8. Three successive `compile_cycle` calls and `compile_cycles(...,3)` agree.

### 5.3 Transition table

| Command / entry | Output | Next PITCH | Voice and connection |
| --- | --- | --- | --- |
| NOTE, no voice | `attack`, source pitch/accent/slide | Consume, then wrap within active span | Replace voice |
| NOTE, voice with outgoing SLIDE | `slide`, from old note to new note, even if equal | Consume, then wrap | Replace voice; request connected transition |
| NOTE, voice without outgoing SLIDE | `retrigger` | Consume, then wrap | Replace voice; request normal release/attack |
| TIE, voice exists | `holds=true`, exact old note/index | Unchanged | Retain voice and its outgoing slide; extend hold intent |
| TIE, no voice | `holds=false` | Unchanged | Stay silent |
| REST, voice exists | `releases=true` | Unchanged | Clear voice, slide connection and hold |
| REST, no voice | `releases=false` | Unchanged | Stay silent |
| TIME wraps | Boundary state transfer | Reset next-consumed cursor to P01 | Preserve actual voice unless REST ended it |

An all-TIE cycle from cold start remains silent over all repeats; it does not
summon default C. An externally supplied voice can be held by all TIEs, but
cross-pattern chaining is not exposed in M2. An all-REST cycle always exits
silent. A cycle without NOTE has zero PITCH consumption.

Compute `hold_intent` afresh **after every command**, using the retained voice
and the next TIME command, with cyclic lookahead only for looping playback:

| Retained voice / next command | `hold_intent` at this step's exit |
| --- | --- |
| No voice | false |
| Next command TIE | true |
| Next command NOTE | the retained outgoing voice's `slide` flag |
| Next command REST, or STOP in one-shot playback | false |

This means a connection is required across the next step boundary; false does
not itself schedule a numerical gate-off. The gate renderer retains its explicit
mode/calibration for ordinary release. A NOTE consumes the previous voice's
slide intent to determine its incoming transition, then replaces that state with
the new pitch's slide flag. TIE retains the old flag; REST clears it. No second
pending-slide flag is needed. This prevents an incoming slide from leaking into
later transitions whose newly consumed pitch has slide disabled.

For one-shot playback, the returned exit voice describes the last semantic
command, not an additional playback event. Do not append a new OFF or promise
post-stop voice behavior from this state. Preserve legacy one-shot output;
Renoise's actual release/stop behavior remains a manual check.

### 5.4 Cold versus repeat examples

Notation: `A` attack, `X` retrigger, `S` slide. Pitches are Renoise note values.

| Source | Cycle 1 | Cycles 2 and 3 |
| --- | --- | --- |
| P=[36,39,43], TIME=N,T,N | N(P1,A), T(P1), N(P2,X) | N(P1,X), T(P1), N(P2,X) |
| P=[36,43], TIME=T,N,N | silent T, N(P1,A), N(P2,X) | T holds **43/P2**, N(P1,X), N(P2,X) |
| P=[36,43], TIME=T,N,R | silent T, N(P1,A), release | silent T, N(P1,A), release |
| P1=36/slide, TIME=N | N(P1,A) | N(P1,S), same-pitch slide intent |
| P=[36,43/slide], TIME=N,R,N | N(P1,A), release, N(P2,A) | N(P1,S), release, N(P2,A) |
| P=[36,43/slide], TIME=R,N,N | silent R, N(P1,A), N(P2,X) | R releases P2, N(P1,A), N(P2,X) |

The last example explains why a cold-pass REST cell cannot simply be reused
without checking repeat entry: cold REST has nothing to release; repeating REST
may need an OFF. The leading-TIE example is the explicit non-copy of the
OS-303 pointer/output behavior.

### 5.5 Periodicity and render planning

For this fixed cursor-reset policy, a cycle with NOTE establishes the same final
pitch identity each time. Starting from silence, compute cold cycle C1, then C2
from C1's exit, then C3 from C2's exit. Compare normalized entry/exit and commands
for C2/C3, excluding cycle numbers and origin bookkeeping. If they disagree,
return a semantic/planner error; do not silently render a guessed period.

The steady cycle is not a second independent pattern. Its leading TIE may hold
the cold cycle's last voice, and its first NOTE may have a different transition.
Do not compare only pitch numbers: REST release requirements, hold state and
slide/retrigger distinctions matter.

## 6. Memory, migration and editor behavior

### 6.1 Versioned source format

Introduce `ACID-PITCH-TIME-2` only when implementation stores the new fields.
A proposed deterministic record layout is:

```text
id|audio_mode|semantics|playback|time_length|pitch_length|pitch_tokens|time_commands
```

Keep existing pitch token encoding, sorted numeric IDs, strict bounded parsing,
no Lua evaluation, and refusal to overwrite unknown/corrupt data. V2 canonical
records contain all 64 pitch tokens, including inactive entries. Validate field
enums, uniqueness, complete TIME, active span and note/keyboard consistency.
Do not silently strip unknown future metadata and rewrite the song.

Supported combinations:

| Semantics | Playback | Meaning |
| --- | --- | --- |
| `legacy_v1` | `one_shot` | Preserve M1 cold traversal and existing audio-mode behavior |
| `cycle_reset_v1` | `one_shot` | One cold cycle, no native repetition |
| `cycle_reset_v1` | `loop` | Cold start followed by the repeating contract |
| `legacy_v1` | `loop` | Invalid; UI Repeat choice explicitly adopts `cycle_reset_v1` |

V1 migration is an in-memory decode until a deliberate successful write:

1. Parse using the original strict v1 grammar; do not guess from rendered notes.
2. Let old stored pitch count be `n`. Set active `pitch_length=n` and retain
   those exact values, keys, octaves, accents and slides.
3. Pad remaining storage to 64 with valid default C entries. Never shorten the
   active span to the last changed entry, non-C entry or number of NOTE commands.
4. Mark `semantics=legacy_v1`, `playback=one_shot`; preserve the audio mode/ID.
5. Verify original cold-pass mapping/output remains equivalent before permitting
   regeneration. If not recoverable, keep the existing phrase untouched.

The existing v1 parser requires a nonempty pitch field, even though the pure
compiler accepts silent empty streams. Do not invent support for malformed v1
empty records. A new empty silent draft is normalized under the v2 rule above.

Reading/reopening/selecting never rewrites `tool_data`. A successful explicit
Generate, regeneration or Live Edit write may serialize the whole song store as
v2, including legacy records whose semantics remain one-shot. State clearly that
older ACID builds cannot read v2; failure before commit restores the exact prior
raw `tool_data`. This is schema versioning, not a manifest version bump.

### 6.2 Explicit compatibility choice

For a loaded v1 source, show `Playback: One-shot (legacy)` and its preserved
active PITCH span. Selecting `Repeat` changes the draft to M2 semantics. It does
not alter the phrase until Generate or an authorized Live Edit regeneration.
Switching back to one-shot keeps M2 semantics; it does not infer or reconstruct
a historical format. Keep the compatibility label and source mode visible.

New sources expose `Playback: Repeat / One-shot` and `PITCH LENGTH: 1–64` beside
LAST STEP. A new draft retains 64 valid C pitches; it does not derive an active
span from click/edit history. A summary should say, for example:

```text
TIME 12 | NOTE triggers 5 | PITCH active 3 / stored 64 | referenced 3
```

Keep independent PITCH/TIME pages, selection and error navigation. Inactive
stored pitches remain editable but visibly outside the active prefix. Page
clicks and selection do not mark musical source dirty or queue regeneration.
Changing active PITCH length, LAST STEP, playback mode or pitch/time content does.

### 6.3 Preview and snapshot integration

Use one resolved compiler mapping for preview and writer inputs. For incomplete
drafts, retain actionable missing-step/pitch errors without requiring a successful
full compilation. Show `Start` and `Repeating` preview selection where a leading
TIE/REST or first transition differs. This is inspection, not a second source.

Add a single source-clone/normalization function. Both manual Generate and Live
Edit must freeze all fields, including `pitch_length`, `semantics`, `playback`
and all inactive stored pitches. `gui.lua` currently hand-copies only length and
the arrays; adding fields without updating that path would regenerate the wrong
source. No saved runtime cursors or render-plan offsets belong in the snapshot.

## 7. Native phrase representation and verification gate

### 7.1 API facts checked against the pinned SDK

`./scripts/setup_sdk.ps1` verified the existing pinned 6.2 installation. Relevant
definitions inspected:

- `sdk/renoise-api-6.2/definitions/library/renoise/song/instrument/phrase.lua`:
  `looping`, `loop_start`, `loop_end`, `number_of_lines`, `lpb`, `copy_from`,
  `line`, key tracking and `MAX_NUMBER_OF_LINES=512`.
- `.../song/instrument.lua`: 1-based `insert_phrase_at`/`delete_phrase_at`,
  `MAX_NUMBER_OF_PHRASES=126`.
- `.../song.lua`: tool-scoped song `tool_data`.
- Matching offline reference pages under
  `sdk/renoise-api-6.2/docs/API/renoise/`, especially
  `renoise.InstrumentPhrase.html` and `renoise.Instrument.html`.

The phrase documentation says playback starts at the beginning before entering
the loop, `loop_start` is 1..number_of_lines, and `loop_end` must be greater than
`loop_start` and at most number_of_lines. LPB is phrase-local, 1..256; TPL is not
phrase-local. These are writable properties. Definitions establish API shape,
not whether a held sample voice survives the loop or what the audible endpoint
convention is. Validate endpoint inclusion experimentally; do not import sample
loop or song-transport endpoint assumptions.

### 7.2 Candidate layouts

Retain the current straight grid: two lines per TIME step, LPB 8. Thus a step is
one sixteenth note. Let `L=2*length`.

| Layout | Physical data | Candidate native range | When eligible |
| --- | --- | --- | --- |
| One-shot compatibility | One cold cycle, L lines | looping disabled | Legacy/M2 one-shot |
| Single native cycle | One reusable cycle, L lines | start=1, end=L, looping enabled | Same cells can express cold and repeat requirements, and native boundary behavior passes |
| Cold intro + steady loop | C1 then C2, 2L lines | start=L+1, end=2L, looping enabled | Cold/repeat commands differ and both seams pass verification |

Ranges above are candidate assignments using documented bounds, subject to the
endpoint experiment. For one TIME step, L=2, so candidate start/end still satisfy
the documented strict inequality. At 64 steps the intro layout uses 256 lines,
below the documented 512-line limit. Do not append a release line that changes
the musical period. LPB, shuffle, key tracking and any setting affecting timing
must be explicit and validated rather than inherited from a staging phrase.

**Do not change the finite pattrns script to `repeats=true` as a shortcut.** The
script is a staging renderer, not the playback loop. Keep it finite; produce the
selected number of physical steps, then use native phrase looping. If the
intro layout is chosen, update emitter/planner limits intentionally: current
`pattrns.emit` caps plan length at 64, whereas two physical 64-step cycles need
128 render steps. Keep source length capped at 64. Compute `max_events` from
physical output requirements, not the current one-cycle `plan.length+8` formula.

### 7.3 Cold, steady and articulation constraints

For each candidate, validate three seams: cold entry, cold→steady, steady→steady.
Gate/slide planning must consume the cycle-aware plan, not call the old
single-pass compiler again and accidentally restore cold semantics.

Specific hazards:

- A leading REST may need OFF in repeats even when cold start emits no OFF.
- A leading TIE must preserve the actual prior voice without a new note.
- The first steady NOTE may require incoming slide while the cold NOTE attacks.
- A normal/retrigger transition at step 1 may need an OFF on the preceding
  cycle's last held step; it must not be scheduled at a negative/local-zero line.
- A trailing note followed by leading TIE requires cyclic hold lookahead.
- Last-to-first same-pitch slide still differs semantically from retrigger.
- Changing LAST STEP must rebuild the entire physical plan and discard stale
  lines, obsolete loop ranges and effects from the previous layout.

Keep the experimental 50% test gate parameter where that mode already uses it;
do not use OS-303's three-of-six clocks to declare it historically accurate.
M2 can correct cyclic hold/release placement without changing that calibration.
Do not add an unconditional last-line OFF: it would break held/TIE/slide seams.

### 7.4 Failures and limitations

If native looping restarts a voice that the semantic plan requires to remain
held, neither setting a flag nor concatenating two cycles proves equivalence.
Unrolling three cycles into a repeating phrase merely moves an unverified seam.
Only use intro+steady if it preserves the transient and steady-state transitions.

Return a diagnostic with TIME step, cycle role and phrase line, such as
`Repeating TIME 01: incoming slide requires voice continuity not verified by
this output mode`. Leave the destination/source unchanged. A user may explicitly
choose one-shot as a documented limitation; never downgrade silently.

M2 can pass basic repeated NOTE/TIE/REST output while selective slide remains an
identified M3 limitation, but it must not claim all articulation cases render.
The M2 report must name unsupported cases. Failure of ordinary NOTE/TIE/REST
looping or the 64-step grid blocks M2 completion.

## 8. Guarded commits, ownership and Live Edit

### 8.1 Version ownership seals without breaking old phrases

The existing hash includes `looping` but not loop endpoints. Extending that hash
in place would misclassify existing phrases as modified. Keep the old name/hash
parser and verifier unchanged for old names; introduce a distinguishable v2 seal,
for example `ACID 0.1 #12 [v2:DEADBEEF]`.

The new seal includes all existing hashed content plus loop endpoints and the
final physical layout properties. `ownership.id/status/make_name` must recognize
both formats. Recheck old ownership with the old algorithm, then issue a v2 seal
only after a successful new render. Changing loop bounds manually must make a
v2 phrase modified. Keep ID uniqueness checks and legacy adoption protections.

### 8.2 Required transaction sequence

1. Freeze source/settings and capture song generation, instrument object,
   target phrase object/ID/seal, raw `tool_data` and affected playback selection.
2. Validate source and prepare the complete serialized next store in memory.
   Check phrase-slot capacity for staging **and backup** before inserting either.
3. Produce the finite staging phrase. Own its object explicitly; do not identify
   it solely as the last phrase after asynchronous work.
4. Apply articulation, assign final layout properties, then validate all musical
   cells, loop range and period. Compute the final seal after these assignments.
5. Before mutation, verify song/instrument/target object identity, unique source
   ID and original seal again. Another owned phrase at the old index is not an
   acceptable replacement target. If store text changed, abort/rebase safely
   rather than overwrite a newer store with an old serialized candidate.
6. Retain a destination backup while replacing the phrase and writing `tool_data`.
   For an append, retain enough identity to remove only the new phrase on failure.
7. Verify phrase seal/source association and successful source write. Only then
   remove backup/staging objects and report committed success.
8. On failure, restore phrase, exact old store and affected selection as far as
   possible; report any failed restoration accurately. Never claim unchanged
   output after an unsuccessful rollback. Keep identifiable recovery material
   if cleanup/restoration fails rather than deleting the sole backup.

This is a guarded multi-object operation; the SDK does not promise a database
transaction. Undo grouping and actual undo/source consistency need Renoise
verification. M2 must address new failure paths and the source-save hole its
schema change touches; a repository-wide undo redesign remains M6.

Cancellation must detach observers and clean only this job's temporary objects.
A late render callback must be harmless after song close, cancellation or target
change. Preserve exact object checks even if indices have shifted. No unrelated
instrument setup, sample mappings, track notes or foreign phrase content changes.

### 8.3 Live Edit rules

- Preserve the 350 ms debounce and one render in flight.
- Freeze every new field before rendering; further edits queue the next job.
- Turning Live Edit off clears queued work; an in-flight job must not commit
  after its context has been invalidated. Use a job generation/token check.
- Changing instrument, phrase target or song invalidates the old job. Close and
  reopen behavior must be defined and tested, including temporary cleanup.
- A failed schema save, ownership conflict or unsupported loop stops automatic
  regeneration with an actionable status. It must not keep retrying a conflict.
- Preserve the current explicit eligibility rules for New Phrase versus an
  existing owned destination. This milestone does not add automatic creation
  merely because a page/selection changes.

## 9. Fixtures, automated checks and manual playback

### 9.1 Initial machine-readable oracle

[loop_cases.json](../tests/acid/fixtures/loop_cases.json) supplies hand-authored
three-cycle expectations for the chosen policy. It is planning/test data, not a
test runner or evidence that M2 passes. Notes use Renoise numeric note values;
PITCH/TIME indices are 1-based. `pitch_length` is the active prefix; a future
fixture loader pads stored capacity independently.

Each cycle's expected arrays correspond to NOTE, TIE or REST commands in TIME
order. `tie_notes` uses null for silence, and `rest_releases` distinguishes cold
REST from a repeat REST that receives a held voice. Fixture expectations retain
semantic voice identity; they do not assert envelope or numerical gate timing.
Keep fixture expectations independent of implementation output.

`exit_next_pitch` is the consumption cursor immediately after the final command,
before the following cycle resets it. The additional `boundary_family` describes
a deterministic source generator and hand-authored checkpoints for every required
acceptance length. Its PITCH values remain distinct above P16/P32/P48; the edge
checkpoints therefore expose accidental page resets. Expand that source template
in the future fixture loader, not in production traversal code.

### 9.2 Required suite expansion

| Proposed spec | Required assertions |
| --- | --- |
| `acid_loop_semantics_spec.lua` | Run oracle for three cycles; exact consumed indices, values, transitions, tie identities, rest releases and exits; no mutation |
| `acid_loop_lengths_spec.lua` | Full lengths 1/16/17/32/33/48/49/64; all-note/all-rest/all-tie; boundary TIE/REST/slide and same-pitch slide |
| `acid_loop_memory_spec.lua` | Active spans 1/3/16/64; NOTE counts below/equal/above span; default C valid; editing inactive storage does not change span |
| `acid_loop_persistence_spec.lua` | V1 counts 1/3/16/64; full-C v1; legacy note metadata; v2 fields/inactive storage roundtrip; unknown/corrupt refusal; read performs no write |
| `acid_loop_writer_spec.lua` | Physical layout and loop metadata; cold/repeat OFF differences; final effect/OFF collisions; representation refusal; stale lines removed |
| `acid_loop_ownership_spec.lua` | Old seals remain owned; new seals protect endpoints; foreign/modified/duplicate-ID refusal; target movement/replacement race |
| Extend live/regeneration specs | All fields frozen; LAST STEP/span changes during job; ON/OFF/context invalidation; source-save and rollback failure injection |

For page boundaries, use a 64-step source that consumes pitches above P16,
P32 and P48: placing TIE/REST at an edge alone may not expose an accidental
pitch reset. Assert explicit events around 16→17, 32→33, 48→49 and 64→1 for
three passes. Also change LAST STEP through 64→17→1→64 and verify source retention
versus generated line cleanup.

Persistence tests must compare pre/post migration **events**, not just table
fields. A v1 three-pitch source padded to 64 must still wrap at three. A saved
64-C source remains active length 64; explicitly edited C is indistinguishable
musically from default C and cannot serve as an end marker. Exercise the v1
nonempty grammar and normalized v2 silent draft separately.

### 9.3 Manual Renoise protocol to add with implementation

Create `tests/acid/acid_loop_manual.md` in the implementation PR. Use a disposable
song and an explicitly configured looping single-cycle saw sample. Record Renoise
version, instrument/sample configuration, BPM, song LPB/TPL, phrase LPB, source
fixture, output layout, loop endpoints, expected events and observed results.

1. **Loop API experiment:** render distinctive notes at candidate loop endpoints.
   Trigger once and sustain; establish which lines repeat and the exact period.
   Test both full-range and intro+loop layouts, including one-step length.
2. **Grid:** 1/16/17/32/33/48/49/64 TIME steps, at least three audible cycles,
   confirmed from a single sustained phrase trigger. Avoid host retriggers that
   could hide incorrect native looping. Record or inspect longer repeats for drift.
3. **Cursor:** distinct P1/P2/P3, five NOTE commands in 12 TIME steps; compare
   three repeats with the expected P1,P2,P3,P1,P2 restart. Then more pitches than
   NOTE commands. Check decoded preview and actual phrase playback agree.
4. **Boundary state:** leading TIE from cold and repeat; trailing TIE; ending
   REST; leading REST receiving a held voice; all REST/all TIE; last-to-first
   same-pitch and different-pitch slide intentions. Separate pitch continuity
   from envelope evidence; record WAV/transients where needed.
5. **Rendering modes:** baseline/retrigger/slide as supported. Confirm normal
   NOTE release and held TIE placement, no final unconditional OFF, no unexpected
   additional attack/overlay in claimed connected cases. Log unsupported cases.
6. **Editing:** LAST STEP and PITCH span changes with Live Edit OFF/ON, rapid edits
   during rendering, target switch, Live Edit disable and song close. Confirm
   exact phrase counts, no stale output and no edits to unrelated phrases.
7. **Compatibility/persistence:** reopen a real v1 XRNS before conversion; verify
   one-shot and pitch span preserved. Explicitly opt into Repeat, save/reopen,
   select each phrase and compare source, audio mode and loop properties.
8. **Protection/undo:** manually change note/effect/loop range; regeneration must
   refuse. Delete/reorder target/instrument during a job. Exercise undo/redo and
   save/reopen around regeneration; report consistency or unresolved limitations.

Keep audible results distinct from visual phrase-cell checks. A regular phrase
whose cells look right can still retrigger or cut a sample voice unexpectedly.

## 10. Implementation work packages and merge gates

Start from current `develop` on `feature/acid-m2-loop-semantics`. Keep focused
Conventional Commits; the titles below are suggestions, not actions performed.

| Package | Suggested commit / scope | Exit gate |
| --- | --- | --- |
| M2-A / M2.0 | `docs(acid): define m2 loop semantics and reference fixtures` | Review D01–D12, firmware caveat and unresolved evidence; no fidelity overclaim |
| M2-B / M2.1 | `feat(acid): interpret repeated pitch and time cycles` | Pure three-cycle oracle passes; boundary state independent from consumption cursor |
| M2-C / M2.2 | `feat(acid): persist explicit pitch spans compatibly` | V1 event equivalence, v2 roundtrip, strict grammar, unchanged old seals |
| M2-D / M2.2 | `feat(acid): expose pitch spans and repeating preview` | Explicit controls and Start/Repeating preview; clone paths cover every field |
| M2-E / M2.3 | `fix(acid): resolve cyclic tie rest and slide intent` | Cyclic gate/hold lookup, diagnostic positions, no numerical sound recalibration |
| M2-F / M2.4 | `feat(acid): render verified native phrase loops` | Candidate layout passes actual Renoise experiments; final validation and v2 seals |
| M2-G / M2.4–5 | `fix(acid): commit loop phrases and sources together` | Source-save failure rolls back; no stale target writes or job-object leaks |
| M2-H / M2.5 | `test(acid): cover loop playback and migration regressions` | Local specs, manual records, current documentation and package inspection agree |

Some packages can be reviewed separately, but native Repeat must remain gated
until its dependent semantics, persistence and safety checks are integrated.
Implement transaction scaffolding before exposing schema-changing writes; the
table describes review slices, not permission to ship the source-save hole.

For implementation, run `./scripts/run_tests.ps1 -Tool ACID` after Lua changes;
all specs remain separate processes. Run the whole suite if shared scripts change.
After adding runtime modules or changing package inputs, run
`./scripts/package.ps1 -Tool ACID` and inspect the archive: manifest/main at root,
private module directories preserved, no tests/SDK/reference firmware included.
No CI workflows or runtime dependency on the OS-303 checkout are introduced.

Update the implemented model contract in DESIGN.md and current user-facing
instructions as each feature lands; keep ROADMAP milestone status honest. Merge
to `develop` only after the user's local/manual verification gate. No release
tag or version bump is implied by this planning document.

## 11. M2 completion decision and present verification

M2 is complete only when:

- Independent PITCH/TIME interpretation matches documented expectations over
  three or more cycles, for all required lengths and edge transitions.
- Active pitch span, fixed cursor reset and retained voice state are explicit;
  all four pages form one sequence.
- Ordinary native looping, ties/rests and exact period pass Renoise checks;
  unsupported slide continuity is identified and never silently substituted.
- Existing songs keep source and one-shot behavior until explicit conversion;
  new fields and inactive pitches survive regeneration and save/reopen.
- Ownership, stale-job checks, rollback and Live Edit protect user content.
- The local suite and recorded manual matrix support the exact supported claims.

Present work: three delegated read-only audits covered firmware semantics, ACID
model/migration, and phrase integration. The root review traced the leading-TIE
output caveat, inspected the pinned SDK definitions/offline phrase documentation,
and ran `./scripts/run_tests.ps1 -Tool ACID`: **14 existing specs passed**.
The JSON planning fixtures were structurally checked separately. No M2 Lua
implementation, firmware build, original-hardware measurement, Renoise playback,
undo, save/reopen or package execution was performed for this documentation-only
change. Those remain implementation/acceptance work, not inferred successes.
