# ACID.xrnx

ACID is an experimental Renoise 3.5 / scripting API 6.2 phrase sequencer. It
edits independent PITCH and TIME memories and renders a native instrument
phrase. Renoise supplies the sound generator, transport and arrangement. The
manifest remains at version 0.1.

## Editing a sequence

Open **Tools > ACID...** or use the Pattern Editor context menu. A fresh draft
is ready immediately: 32 C pitch entries, 32 NOTE commands, LAST STEP 16 and
an active PITCH span of 16. Change LAST STEP and the active PITCH span as
needed. Program view selects one PITCH entry and TIME step for editing. Grid
view edits sixteen positions directly across two continuous pages. Both views
edit the same source; switching views does not change or regenerate the
sequence. Reducing LAST STEP keeps hidden TIME entries available if the length
is increased again.

Timing selects straight sixteenth steps or 1/8 triplet steps. Straight uses
phrase LPB 16 and triplet LPB 12, with four phrase lines per source step. A
cycle of N steps lasts N/4 or N/3 quarter-note beats respectively, so each step
keeps its 1/4-beat or 1/3-beat duration. Changing timing keeps
both memories intact. Phrase timing is local to the phrase; ACID does not change
the song tempo, LPB or meter. Timing is saved with the source and is included
in Undo, Redo and Reset. Phrase output and PB Range are separate phrase settings.
At N=32, Play Once has 128 lines. Repeat has 257 lines: the steady loop starts
at line 129 and ends exclusively at line 257, the empty sentinel. The 512-line
phrase capacity is unchanged.

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

For the instrument selected in Renoise, choosing an existing Destination phrase
also selects it in Renoise's Phrase Editor. Selecting an ACID-owned phrase in
the Phrase Editor loads its source and PB Range into ACID. If ACID targets a
different instrument, Renoise continues to show its currently selected instrument.
With Live Edit enabled, selecting a saved phrase loads it without regenerating;
an existing recovered draft is applied automatically, as are subsequent edits.

Manual Generate and Regenerate remain available. Live Edit optionally applies
each valid source edit immediately, with one render in flight. Edits made during
rendering apply automatically as soon as that render finishes. Undo and Redo cover source edits and
phrase output policy and PB Range. A failed Live Edit remains armed; correct the source or
use Retry Live Edit. Enabling Live Edit also applies the current source. New
destinations create an ACID phrase automatically. Foreign, modified or deleted
phrases are preserved; Live Edit creates a separate owned phrase for the edits.
Uncommitted drafts are stored separately from the last committed phrase in
song tool data and recover after saving and reopening the XRNS. If a new draft
has an ambiguous destination or persistence fails, it remains available in the
open session and ACID reports the unsaved state. Give a new draft's instrument
a unique name or generate its phrase before closing the song. ACID protects
foreign or modified phrases and uses staged rendering, ownership checks, source persistence and
rollback before replacing an owned phrase. The current WIP source schema is
`ACID-PITCH-TIME-1`. With Live Edit off,
the source is marked dirty until a successful Generate applies the draft.

The renderer derives NOTE, TIE, REST, gate, release and slide intent from the
source. Sample-only targets use native sample glide. Plugin and MIDI SLIDE
uses overlapping notes: the target starts in another phrase column at delay 0
before a delayed OFF releases its predecessor. The OFF uses the minimum
note-delay unit (1/256 phrase line) per event; Renoise quantizes delays to ticks,
so this bounded ordering is host-tick-quantized, not sample-accurate, and never
accumulates into step rounding. Same-pitch connected notes hold the existing
voice. Pitch-bend attacks align to the phrase line; a fresh NOTE with a center
reset uses delay 1 only when the bend channel is not known centered, otherwise
delay 0. Repeat
preserves overlap ordering across the loop seam.

For a plugin or MIDI synth, enable its mono/legato portamento and set its glide
time. ACID sends the legato note ordering; the receiver supplies continuous
pitch motion and envelope behavior. A polyphonic receiver may play overlapping
notes instead of gliding. ACID does not change presets or enable portamento
by modifying the instrument. Hybrid instruments use
the same overlap stream; their sample layers may respond differently. Accent
changes on a held same-pitch voice are reported when they cannot be delivered.
Empty slots can receive a silent phrase and are reported as needing a generator.

**PB Range** is an optional receiver-range assumption: **Off** (default), **±2**,
**±12**, **±24** or **±48** semitones. Off retains receiver-controlled portamento.
A selected range requests native MIDI pitch-bend commands for connected
plugin/MIDI slides. Set the matching range in the receiver yourself and use an
isolated monophonic route: ordinary pitch bend affects the entire MIDI channel.
ACID does not configure or detect the receiver range. Settings belong to each
owned phrase and restore on selection/save/reopen; PITCH/TIME memory stays
unchanged. Out-of-range slides fall back to ordered notes with an approximation
warning. Hybrid sample layers may respond differently.

Phrase-contained pitch bend and center-reset playback checks are pending for
the current LPB16/12 four-line layout. This does not establish delivery for
other receivers or routes. A receiver that
ignores these commands will not produce the intended bend; use PB Off for
receiver-controlled note overlap.

Phrase generation has been checked with Lua mocks for the current renderer
contract. Renoise playback and routing checks for Program/Grid switching,
Repeat/Play Once, plugin, MIDI, empty slots, and Live Edit recovery are still
pending; see the [M3.5 manual checklist](../tests/acid/acid_m35_s_manual.md).
The full M3.5 instrument and Live Edit gates remain tracked in
[ROADMAP.md](ROADMAP.md). Generation requires LPB transport timing and rejects
unsupported speed timing before changing phrases or saved source. Straight and
triplet playback, including host groove, remain subject to the
[timing checklist](../tests/acid/acid_timing_manual.md).

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

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
