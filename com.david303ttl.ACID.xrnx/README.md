# ACID.xrnx

Renoise 3.5+ ACID sequencer, **version 0.1 (unfinished)**.

The tool opens from **Tools > ACID...** or the Pattern Editor context menu.
The dialog now has **Generate / Regenerate ACID Phrase** for native-sample
instruments. Initial creation requires no existing phrases. Later generation
may safely replace the single unmodified ACID-owned phrase, while refusing
foreign or manually edited phrases. An old unmarked `ACID 0.1 TEST` phrase
requires explicit one-time adoption. No song pattern tracks are modified. The manifest stays at `0.1` until the native-sample sequencer
is finished and verified in Renoise.

The implementation now contains a separately testable pitch/time memory model
(`model/sequencer.lua`) and a semantic NOTE/TIE/REST/slide compiler (`model/compiler.lua`).
The deterministic `writers/pattrns_writer.lua` module additionally emits a one-shot scripted
phrase source from semantic events. It handles NOTE, TIE (no new event), REST
(explicit note-off when required), and provisional accent velocity.

The pattrns output is **not the finished playable ACID sequence**. Native
selective slide, correct gate duration, phrase looping and cross-boundary
articulation still require a verified native phrase renderer. The main pitch/time editor
remains a draft: the test generator starts with an eight-step fixture and
accepts the dialog's edited pitch/time state.
Renoise playback correctness has not yet been verified.

See [DESIGN.md](DESIGN.md) for the architecture, semantics, unresolved hardware
and playback cases, and milestone plan. The proposed output is a rendered
native instrument phrase, produced via pattrns and finalized with native
sample articulation commands after real playback verification.

## Architecture

- `main.lua`: registers menus
- `gui.lua`: native ViewBuilder dialog with pitch/time editing and test-phrase controls
- `model/sequencer.lua`: draft pitch/time state, validation
- `model/compiler.lua`: pure Lua semantic pitch/time state machine
- `renoise/selection_context.lua`: read-only selection inspection (legacy scaffold)
- `writers/pattrns_writer.lua`: deterministic one-pass scripted phrase source emitter
- `writers/phrase_writer.lua`: asynchronous Renoise script commit and native phrase render
- `model/articulation.lua`, `model/control_signals.lua`: experimental articulation and gate planning
- `writers/gate_writer.lua`, `writers/phrase_validator.lua`: native gate commands and rendered phrase validation
- `renoise/sampler_audit.lua`: read-only sampler inspection
- `writers/phrase_ownership.lua`: content-sealed ownership and guarded phrase regeneration
- `model/memory_status.lua`: independent TIME/PITCH usage reporting
- Future: verified playback, complete editor, persistence

## Local tests

From the repository root using Lua (e.g. VS Code terminal):

```powershell
./scripts/run_tests.ps1 -Tool ACID
```

Individual specs can also be run directly, for example
`lua tests/acid/acid_compiler_spec.lua`.

Other local Lua implementations, including `texlua`, may run the same tests.
No workflows are needed. These tests do not replace real Renoise playback validation.

See [first native phrase playback test](../tests/acid/acid_phrase_manual.md)
for the current in-Renoise test procedure.

When installing ACID, remove the previous development tool package from
Renoise's `Scripts/Tools` directory to avoid duplicated menu entries.

## Development installation

Copy/symlink `com.david303ttl.ACID.xrnx` into Renoise's user `Scripts/Tools`
folder and reload tools (or restart Renoise). Or run `./scripts/package.ps1 -Tool ACID` from the repository root and install
the resulting `.xrnx` archive from `dist/`. Its root contains `manifest.xml`
and `main.lua`.

## Render event validation

Renoise may report raw script events including time steps without musical
note output. ACID now verifies the rendered native phrase's 16 lines, the
four expected pitches, both OFF positions, and empty steps rather than
requiring the raw callback count to equal six. The user screenshot established
8 raw events for the expected 6 note/OFF events. Re-run the manual test in a
new sample instrument with no phrases; the previous failed-test phrase may
still be present and should be inspected or discarded manually.

## Native articulation experiments (still 0.1)

The ACID dialog has three separate modes: Baseline, Retrigger + Gate,
and Selective Slide + Gate. Experimental native note-column `0Gxx`
commands and pre-retrigger OFF cells are added only after rendering and
validating a new phrase. Existing instrument phrases are never replaced.
These modes start with the same eight-step test fixture; the dialog's pitch/time
controls can edit the state passed to the generator.

Run the manual comparison in [tests/acid/acid_slide_manual.md](../tests/acid/acid_slide_manual.md).
Run `lua tests/acid/acid_articulation_modes_spec.lua` locally in VS Code.
This stage is not verified in real Renoise, and the glide speed and
sample-envelope behavior are not yet calibrated.

## Editable control-signal prototype (0.1)

The dialog now includes an initial PITCH entry editor (C-3..C-4,
ACCENT, SLIDE), a separate TIME step editor (NOTE/TIE/REST), and a
read-only Sampler/Modulation/Effects inspection command. These controls
feed the native phrase generator. A pure-Lua control-signal timeline
separates note gate edges, pitch targets, ties and rests; the 50% gate
is an experiment, not historical calibration.

See [Sampler and control tests](../tests/acid/acid_sampler_control_manual.md).
Run `lua tests/acid/acid_control_signals_spec.lua` along with all existing
local specs. **This new GUI/instrument behavior still needs a Renoise
smoke test** before we consider it validated.

## Regeneration and memory visibility

ACID shows TIME filled/total, NOTE/TIE/REST counts, PITCH entries/16,
free PITCH slots, next pitch index, and a compact command list. The
pitch stream wraps independently; it does not need to have as many
entries as NOTE events. Newly generated phrases are signed in their
name using a content checksum. Regeneration uses a temporary render,
checks ownership and manual edits, backs up the old phrase, and then
replaces its contents in the same phrase slot. Modifying a generated
phrase invalidates its ownership checksum; regeneration refuses it.

See [manual regeneration QA](../tests/acid/acid_regeneration_manual.md).
The new implementation still needs the user's in-Renoise verification;
local specs alone do not prove safe real-world regeneration.
