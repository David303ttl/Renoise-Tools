# ACID.xrnx

Renoise 3.5+ ACID sequencer, **version 0.1 (unfinished)**.

The tool can be opened from **Tools > ACID...** or the Pattern Editor context
menu. The dialog is still a read-only scaffold; **no notes are generated or
modified** yet. The manifest stays at `0.1` until the native-sample sequencer
is finished and verified in Renoise.

The implementation now contains a separately testable pitch/time memory model
(`sequencer.lua`) and a semantic NOTE/TIE/REST/slide compiler (`compiler.lua`).
The deterministic `pattrns_writer.lua` module additionally emits a one-shot scripted
phrase source from semantic events. It handles NOTE, TIE (no new event), REST
(explicit note-off when required), and provisional accent velocity.

The pattrns output is **not the finished playable ACID sequence**. Native
selective slide, correct gate duration, phrase looping and cross-boundary
articulation still require a verified native phrase renderer. The current GUI
remains read-only. These modules do not claim playback correctness.

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
- Future: Renoise script-phrase API bridge, native phrase writer, safe regeneration, persistence

## Local tests

From the repository root using Lua (e.g. VS Code terminal):

```sh
lua tests/acid_sequencer_spec.lua
lua tests/acid_compiler_spec.lua
lua tests/acid_pattrns_spec.lua
lua tests/acid_identity_spec.lua
```

Other local Lua implementations, including `texlua`, may run the same tests.
No workflows are needed. These tests do not replace real Renoise playback
validation.

When installing ACID, remove the previous development tool package from
Renoise's `Scripts/Tools` directory to avoid duplicated menu entries.

## Development installation

Copy/symlink `com.david303ttl.ACID.xrnx` into Renoise's user `Scripts/Tools`
folder and reload tools (or restart Renoise). Or ZIP the **contents** of this
directory and rename the archive to `com.david303ttl.ACID.xrnx`; the archive
root must contain `manifest.xml`.
