# ACID.xrnx

Renoise 3.5+ ACID sequencer, **version 0.1 (unfinished)**.

The tool can be opened from **Tools > ACID...** or the Pattern Editor context
menu. The dialog is still a read-only scaffold; **no notes are generated or
modified** yet. The manifest stays at `0.1` until the native-sample sequencer
is finished and verified in Renoise.

The implementation now contains a separately testable pitch/time memory model
(`sequencer.lua`) and a semantic NOTE/TIE/REST/slide compiler (`compiler.lua`).
Neither module requires Renoise. They do not claim playback correctness.

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
- Future: pattrns adapter, phrase writer, safe regeneration, persistence

## Local tests

From the repository root using Lua (e.g. VS Code terminal):

```sh
lua tests/acid_sequencer_spec.lua
lua tests/acid_compiler_spec.lua
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
