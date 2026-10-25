# TB303.xrnx

Renoise 3.5+ TB-303 sequencer, currently **v0.1 development scaffold**.

The tool can be opened from **Tools > TB303...** or the Pattern Editor context menu. Its dialog allows changing a draft pattern length (8, 12 or 16 timing steps) and inspecting the selected pattern.

**No original TB-303 sequencing behavior is implemented yet. No notes are generated or modified.** The draft state intentionally stores pitch and timing events in separate arrays to avoid committing prematurely to ordinary tracker-step semantics.

Future milestones: original pitch/time entry workflow and step transitions; correct note/rest/tie/accent/slide and pattern-wrap event compilation; Renoise pattern rendering; instrument-specific accent/slide mapping; song-state persistence.

## Architecture

- `main.lua`: registers menus
- `gui.lua`: native ViewBuilder dialog
- `sequencer.lua`: draft pitch/time data schema
- `pattern_writer.lua`: read-only selection inspection, later the event renderer

## Development installation

Copy/symlink `com.david303ttl.TB303.xrnx` into Renoise's user `Scripts/Tools` folder and reload tools (or restart Renoise). Or ZIP the **contents** of this directory and rename the archive to `com.david303ttl.TB303.xrnx`; the archive root must contain `manifest.xml`.

See [../tests/README.md](../tests/README.md).
