# ARP.xrnx

Renoise 3.5+ pattern arpeggiator, currently **v0.1 development scaffold**.

The tool can be opened from **Tools > ARP...** or the Pattern Editor context menu. The window shows a small pure-Lua Up/Down/Up-Down ordering demo and can inspect the selected pattern and track.

**No pattern notes are generated or modified in this version.** The note ordering example is not yet driven by pattern chords.

Planned flow: source pattern track -> arpeggiator -> separate destination track -> selected Renoise instrument.

## Architecture

- `main.lua`: registers menus
- `gui.lua`: native ViewBuilder dialog
- `arp_engine.lua`: currently a pure-Lua note ordering primitive, later to handle timing and arp logic
- `pattern_writer.lua`: read-only selection inspection, later the safe note writer

## Development installation

Copy/symlink the `com.david303ttl.ARP.xrnx` directory into Renoise's user `Scripts/Tools` folder, then restart Renoise or reload all tools in scripting development mode. Alternatively ZIP the **contents** of this directory, rename the ZIP file to `com.david303ttl.ARP.xrnx`, and install that file in Renoise. The top-level `manifest.xml` must be at the archive root.

Testing instructions: [../tests/README.md](../tests/README.md).
