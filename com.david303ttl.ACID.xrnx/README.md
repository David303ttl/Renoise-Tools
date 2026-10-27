# ACID.xrnx

ACID is an experimental Renoise 3.5 / scripting API 6.2 phrase sequencer. It
edits independent PITCH and TIME memories and renders a native instrument
phrase. Renoise supplies the sound generator, transport and arrangement. The
manifest remains at version 0.1.

## Editing a sequence

Open **Tools > ACID...** or use the Pattern Editor context menu. A fresh draft
is ready immediately: 64 C pitch entries, 64 NOTE commands, LAST STEP 16 and
an active PITCH span of 16. Change LAST STEP and the active PITCH span as
needed. Program view selects one PITCH entry and TIME step for editing. Grid
view edits sixteen positions directly across four continuous pages. Both views
edit the same source; switching views does not change or regenerate the
sequence. Reducing LAST STEP keeps hidden TIME entries available if the length
is increased again.

A NOTE consumes the next active PITCH entry. TIE holds the current semantic
voice without consuming pitch memory, and REST releases it. ACCENT and outgoing
SLIDE belong to PITCH entries. Entering TIE at TIME 01 stores NOTE. Repeat
cycles reset pitch consumption to P01 while preserving the sounding voice for
boundary interpretation.

## Generating phrases

Choose any instrument slot and an existing unchanged ACID-owned phrase or
**New Phrase**. **Repeat** is the default output policy. **Play Once** renders
one traversal with an explicit final release. Changing this policy changes the
owned phrase layout and saved phrase settings, not the PITCH/TIME source or the
instrument's global phrase trigger settings. The decoded Start/Repeating
preview is read-only.

Manual Generate and Regenerate remain available. Live Edit optionally applies
valid source edits after a short debounce. Undo and Redo cover source edits and
phrase output policy. A failed Live Edit remains armed; correct the source or
use Retry Live Edit. If the destination changes, select it again before writing.
Uncommitted drafts are stored separately from the last committed phrase in
song tool data and recover after saving and reopening the XRNS. If a new draft
has an ambiguous destination or persistence fails, it remains available in the
open session and ACID reports the unsaved state. Give a new draft's instrument
a unique name or generate its phrase before closing the song. ACID protects
foreign or modified phrases and uses staged rendering, ownership checks, source persistence and
rollback before replacing an owned phrase. Source records and ownership seals
use the current v3 contract.

The renderer derives NOTE, TIE, REST, gate, release and slide intent from the
source. It attempts native sample glide when the target has sample data. Plugin
and MIDI targets retain ordered note events and receive an explicit slide
approximation where continuous pitch movement cannot be represented by their
phrase route. Connected accent behavior and sample envelope response depend on
the target and are not claimed to match TB-303 hardware. Empty instrument slots
can receive a silent phrase and are reported as needing a generator.

Phrase generation has been checked with Lua mocks for the current renderer
contract. Renoise playback and routing checks for Program/Grid switching,
Repeat/Play Once, plugin, MIDI, empty slots, and Live Edit recovery are still
pending; see the [M3.5 manual checklist](../tests/acid/acid_m35_s_manual.md).
The full M3.5 instrument and Live Edit gates remain tracked in
[ROADMAP.md](ROADMAP.md). Triplet timing is not implemented.

## Development checks

From the repository root in PowerShell 7:

```powershell
./scripts/run_tests.ps1 -Tool ACID
./tests/acid/validate_loop_oracle.ps1
./scripts/package.ps1 -Tool ACID
```

Each Lua spec runs in a separate process. Semantic and mocked tests do not
establish Renoise audio behavior. ACID's GUI and phrase-writer regression specs
cover editable LAST STEP, Reset/Undo, selected-phrase regeneration, and sample
slide commands scheduled before midpoint OFFs. Run the
[M3.5 manual checklist](../tests/acid/acid_m35_s_manual.md) in Renoise to
verify phrase playback and GUI behavior. The package has `manifest.xml` and
`main.lua` at its root and excludes development files.
