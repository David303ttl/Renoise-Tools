# TB303.xrnx — design contract (0.1 development)

Status: **experimental**. Keep `manifest.xml` at version **0.1** until the entire
native-sample sequencer is finished, working, and manually verified in Renoise.
A passing pure-Lua test is **not** evidence of correct audio playback.

## Purpose and boundaries

Build a standalone native Renoise 3.5+ XRNX tool that models the original
Roland TB-303 **separate pitch/time memories**, then produces a playable
Renoise *native sample instrument phrase*. The sequencer is independent of any
303 synthesizer. No custom DSP, plugins, MIDI synth support or GitHub Actions
are part of the first implementation.

References:
- Roland TB-03 original-mode manual:
  https://static.roland.com/assets/media/pdf/TB-03_eng03_W.pdf
- Pattrns guide: https://renoise.github.io/pattrns/guide/index.html
- Pattrns event interface: https://renoise.github.io/pattrns/guide/event.html
- Renoise phrases: https://tutorials.renoise.com/wiki/Phrase_Editor

## Four layers (keep separate)

1. `sequencer.lua`: serializable TB-303 pattern state and validation.
2. `compiler.lua`: deterministic pitch/time interpreter. Returns *semantic*
   NOTE, TIE, REST, and continuity/slide intentions, not Renoise note commands.
3. **Planned** pattrns adapter: translates musical events into an instrument
   scripted phrase and renders it into a regular phrase.
4. **Planned** native-phrase articulation adapter: applies exact note releases,
   accents, and selective sample glide (`0Gxx`) *after* rendering.

The rendered regular phrase is the main playback target. A script-only phrase
must not be considered equivalent until note-off/slide support is proven.
Use a looping single-cycle sawtooth sample for initial playback tests.

## 0.1 model implemented so far

```lua
{
  length = 4,                        -- 1..16 timing slots
  pitch_events = {
    { note = 36, accent = false, slide = true },
    { note = 39, accent = true,  slide = false },
  },
  time_events = { "N", "T", "N", "R" }
}
```

- `N` consumes the next pitch entry and triggers a new semantic note event.
- `T` consumes no pitch; sustains the active semantic note if there is one.
- `R` consumes no pitch; terminates the active semantic note if there is one.
- Accent and slide belong to **pitch entries**, not time slots.
- An active note's `slide=true` makes the transition to the next NOTE a
  slide, unless an intervening REST has ended the note. This also works after
  intervening TIE steps and for repeated pitches.
- Pitch entries wrap when exhausted **within one time-memory traversal**.
- An output `boundary` record describes the intended transition from the
  end to the next loop's first note, including leading ties. The compiler's
  step events represent an initial traversal starting from silence. It does
  **not** yet render the second traversal or cross-pattern transitions.

Draft state accepts partly entered arrays. Compilation requires a complete
TIME array. Patterns containing no NOTE events are permitted (silence).

## Research and unresolved compatibility decisions

These must be resolved against actual TB-303 behavior and Renoise playback,
not silently chosen by the renderer:

- Exact original pitch-memory cursor restart/reset when pattern length and
  pitch-entry count differ; state restoration across chained patterns.
- Leading TIE behavior on initial playback versus repeated loops.
- Whether `0Gxx` preserves sample-voice identity, attack envelope and expected
  pitch trajectory for every slide interval, including same-note slides.
- Gate duration for non-slide NOTE and release behavior at a REST.
- Exact loop boundary slides, first trigger vs subsequent loop articulation,
  and inter-pattern slide continuity.
- 303 triplet programming/time-grid mapping into phrase LPB and Renoise delay.
- Accurate accent envelope/filter response (velocity is an interim mapping).

No renderer may silently substitute a note retrigger, tick cut or global
instrument portamento for a selective 303 slide. A failed representability
check must leave existing musical content unchanged.

## Persistence and regeneration

The original pitch and time memories, plus renderer parameters, are canonical
and must be stored independently of generated phrase events. Use TB303-scoped
song data, not ARP's metadata. Adapt ARP's guarded preflight/snapshot/rollback
principles, but do not import ARP's private modules or share tool data.
Detect user-edited generated content and refuse destructive regeneration.

## Next implementation steps (still version 0.1)

1. Verify baseline pitch/time interpreter cases and original-model conformance.
2. Implement a pattrns script emitter with repeatable test fixtures.
3. Integrate Renoise instrument script-phrase commit/render APIs.
4. Test native sample glide, release and loop mechanics **in Renoise**.
5. Implement the final phrase articulation and protected regeneration.
6. Add usable Pitch / Time / Preview ViewBuilder interface and persistence.
7. Manually verify save/reopen, repeat, tempo changes and instrument playback.

All automated tests are plain Lua from VS Code. No GitHub workflows.
