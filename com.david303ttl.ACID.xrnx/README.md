# ACID

ACID is an experimental phrase editor for Renoise 3.5 / scripting API 6.2. It
edits separate PITCH and TIME memories and generates a native instrument phrase.
Renoise supplies transport, sound generation and arrangement.

## Edit a pattern

Open **Tools > ACID...**, use the Pattern Editor context menu, or assign
`Global:ACID:Show` in **Edit > Preferences > Keys**. Program and Grid edit the
same source. A new draft contains 32 C pitches, 32 NOTE commands, Length 16 and
Pitch span 16. Length and Pitch span set the active TIME and PITCH ranges
independently; inactive entries remain stored. NOTE consumes a pitch, TIE holds
the current voice, and REST releases it. ACCENT and outgoing SLIDE belong to
PITCH entries. Entering TIE at TIME 01 stores NOTE.

Use Program for direct or sequential entry and Grid for page-based editing.
Sequential entry applies its candidate as one undoable edit after all active
positions are entered; Cancel discards the candidate. Both views show how TIME
commands refer to pitches and how slides connect notes. These indicators describe
the compiled pattern, not playback position. See [editor checks](../tests/acid/acid_editor_presentation_manual.md).

**Audition** previews a selected pitch or the pitch referenced by a selected
TIME step without changing the source or phrase. It is disabled during
sequential TIME entry. Cleanup is best effort if the captured host objects
disappear.

## Scales and operations

In **SCALE**, select a root and scale to apply its note mask, or edit the mask
directly. Browsing root, category or search does not change the mask. The mask
filters audition and output while preserving raw pitches. **Follow scale** snaps
new Program/Grid note entry with MASK enabled; it is a session setting. Scale
text imports are
saved in tool preferences. Each line defines a name and unique intervals from
0 through 11, including 0, for example `My scale = 0 2 3 5 7 9 10`.

PITCH and TIME randomization have separate seeds. Apply uses the entered seed;
Repeat last reuses the remembered seed with current settings. Seeds are session
state and are not part of Undo. Clear, transform and randomize operations can
target active memory or all 32 entries. A changed operation is one undoable edit.
Copy/Paste transfers PITCH, TIME or both in the session clipboard; it does not
include timing, scale mask, labels, output settings or destination. **Reset
pattern** resets all stored entries, Pitch span, timing, mask and output settings
while preserving Length and label.

## Generate phrases

Choose an instrument and either an unchanged ACID-owned phrase or **New Phrase**.
Repeat is the default output policy; Play Once renders one traversal and a final
release. **Generate** creates or updates the selected destination. **Live Edit**
also writes each admitted source/settings edit synchronously. Navigation and
draft restoration do not generate music. Undo/Redo cover source edits and phrase
output settings.

ACID only updates phrases it can verify as its own and unchanged. Foreign,
modified, deleted or colliding destinations block generation; select **New
Phrase** to create separate output. Creation needs a free phrase slot under
Renoise's 126-phrase instrument limit. Regeneration updates the existing phrase
in place. Duplicate creates a new owned phrase from the last committed source.

PITCH/TIME source, scale mask and output settings are stored in song tool data.
Uncommitted drafts recover after the XRNS is saved and reopened when their
destination is unambiguous. With Live Edit off, changes remain a draft until a
successful Generate. Ambiguous or unsaved drafts remain available in the open
session; give a new draft's instrument a unique name or generate before closing.
The persisted schema is `ACID-PITCH-TIME-2`; unsupported or corrupt data blocks
writes and is retained unchanged. ACID does not convert or reset it. Copies that
share an ACID identity block all holders of that identity. Ordinary write
failures can be retried with Generate after admission checks pass. Persistent
song-integrity blockers have no repair action in ACID and survive reopening.

Rename labels are song metadata separate from the sealed native phrase name.
Labels support ACID Undo/Redo, but Renoise's native Undo does not guarantee
label restoration. Duplicate uses committed data and aborts if preserving a dirty
draft cannot be saved and verified.

## Output behavior

Timing is local to the phrase: straight steps use LPB 16 and triplet steps LPB
12. ACID does not change song tempo, LPB or meter. Sample instruments use native
sample glide. Plugin/MIDI slides use overlapping notes; enable mono/legato
portamento and set glide time on the receiver. Renoise quantizes note delays, so
the ordering is tick-quantized, not sample-accurate. Polyphonic receivers may
play overlapping notes instead of gliding.

**Bend range** (Off, ±2, ±12, ±24 or ±48 semitones) specifies the receiver's pitch
bend range for plugin/MIDI slides. Set the same range on the receiver and use an
isolated monophonic route because pitch bend affects the entire MIDI channel.
Out-of-range slides fall back to ordered notes with a warning. ACID does not
configure the receiver or phrase-trigger settings. Hybrid sample layers may
respond differently.

Use Renoise's phrase playback controls to enable phrase triggering, then enter
instrument notes and phrase-selection commands in the Pattern Editor. Editing
generated phrase content, length or loop properties can invalidate ownership
and block regeneration; regeneration replaces its generated content.

Run `./scripts/run_tests.ps1 -Tool ACID` from the repository root. Renoise checks
are documented in the [manual guides](../tests/acid/).

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](../LICENSE).
