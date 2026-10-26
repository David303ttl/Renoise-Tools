# ACID.xrnx

Renoise 3.5+ ACID sequencer, **version 0.1 (unfinished)**.

The tool opens from **Tools > ACID...** or the Pattern Editor context menu.
The dialog now has a **Generate Test Phrase** command for native-sample
instruments which have no existing phrases. It writes a NEW test phrase only;
it does not change song pattern tracks or user-created phrases. The manifest stays at `0.1` until the native-sample sequencer
is finished and verified in Renoise.

The implementation now contains a separately testable pitch/time memory model
(`sequencer.lua`) and a semantic NOTE/TIE/REST/slide compiler (`compiler.lua`).
The deterministic `pattrns_writer.lua` module additionally emits a one-shot scripted
phrase source from semantic events. It handles NOTE, TIE (no new event), REST
(explicit note-off when required), and provisional accent velocity.

The pattrns output is **not the finished playable ACID sequence**. Native
selective slide, correct gate duration, phrase looping and cross-boundary
articulation still require a verified native phrase renderer. The main pitch/time editor
remains a draft: only a fixed eight-step audio fixture can be generated.
Renoise playback correctness has not yet been verified.

See [DESIGN.md](DESIGN.md) for the architecture, semantics, unresolved hardware
and playback cases, and milestone plan. The proposed output is a rendered
native instrument phrase, produced via pattrns and finalized with native
sample articulation commands after real playback verification.

## Architecture

- `main.lua`: registers menus
- `gui.lua`: existing native read-only ViewBuilder dialog
- `sequencer.lua`: draft pitch/time state, validation
- `compiler.lua`: pure Lua semantic pitch/time state machine
- `pattern_writer.lua`: read-only selection inspection (legacy scaffold)
- `pattrns_writer.lua`: deterministic one-pass scripted phrase source emitter
- `phrase_writer.lua`: asynchronous Renoise script commit and native phrase render
- Future: full editor, selective glide, safe regeneration, persistence

## Local tests

From the repository root using Lua (e.g. VS Code terminal):

```sh
lua tests/acid_sequencer_spec.lua
lua tests/acid_compiler_spec.lua
lua tests/acid_pattrns_spec.lua
lua tests/acid_identity_spec.lua
lua tests/acid_phrase_spec.lua
lua tests/acid_phrase_validator_spec.lua
```

Other local Lua implementations, including `texlua`, may run the same tests.
No workflows are needed. These tests do not replace real Renoise playback validation.

See [first native phrase playback test](../../tests/acid_phrase_manual.md)
for the current in-Renoise test procedure.

When installing ACID, remove the previous development tool package from
Renoise's `Scripts/Tools` directory to avoid duplicated menu entries.

## Development installation

Copy/symlink `com.david303ttl.ACID.xrnx` into Renoise's user `Scripts/Tools`
folder and reload tools (or restart Renoise). Or ZIP the **contents** of this
directory and rename the archive to `com.david303ttl.ACID.xrnx`; the archive
root must contain `manifest.xml`.

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
These modes use the same fixed 8-step test sequence, not the draft editor.

Run the manual comparison in [tests/acid_slide_manual.md](../../tests/acid_slide_manual.md).
Run `texlua tests/acid_articulation_modes_spec.lua` locally in VS Code.
This stage is not verified in real Renoise, and the glide speed and
sample-envelope behavior are not yet calibrated.

## Editable control-signal prototype (0.1)

The dialog now includes an initial PITCH entry editor (C-3..C-4,
ACCENT, SLIDE), a separate TIME step editor (NOTE/TIE/REST), and a
read-only Sampler/Modulation/Effects inspection command. These controls
feed the native phrase generator. A pure-Lua control-signal timeline
separates note gate edges, pitch targets, ties and rests; the 50% gate
is an experiment, not historical calibration.

See [Sampler and control tests](../../tests/acid_sampler_control_manual.md).
Run `lua tests/acid_control_signals_spec.lua` along with all existing
local specs. **This new GUI/instrument behavior still needs a Renoise
smoke test** before we consider it validated.
