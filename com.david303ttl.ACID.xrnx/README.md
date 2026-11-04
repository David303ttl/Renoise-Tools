# ACID.xrnx

ACID is an experimental Renoise 3.5 / scripting API 6.2 phrase sequencer. It
edits independent PITCH and TIME memories and renders a native instrument
phrase. Renoise supplies the sound generator, transport and arrangement. The
manifest remains at version 0.1.

## Editing a sequence

Open **Tools > ACID...**, use the Pattern Editor context menu, or assign a
shortcut to `Global:ACID:Show` in **Edit > Preferences > Keys**. Renoise
keeps shortcuts in each user's keymap. ACID does not set a default shortcut. The command
opens or focuses the same ACID window as the menu entries. A fresh draft is
ready immediately: 32 C pitch entries, 32 NOTE commands, Length 16 and a
Pitch span of 16. Change Length and Pitch span independently as needed.
The header places Instrument first, then Phrase with Rename and Duplicate.
Length, Timing, Reset pattern and Pitch span sit above the editor.
Program and Grid have independent PITCH and TIME cursors and pages. Grid
selects sixteen positions per page for direct editing with shared pitch and
NOTE/TIE/REST controls. Program offers direct Edit One and staged Re-enter
PITCH or Re-enter TIME. Both views
edit the same source; switching views does not change or regenerate the
sequence. Reducing Length keeps hidden TIME entries available if the length
is increased again; inactive TIME positions remain inspectable but cannot be
edited directly. All 32 PITCH entries remain stored and editable.

TIME buttons show **Note**, **Tie** or **Rest**; assignment controls highlight
the selected command. Grid pitches show Renoise note names with **ACC** and
**SLD** when enabled. Hover for raw pitch values and source markers: S stored,
R referenced, M modified from the accepted baseline. Grid shows canonical
source; Program shows the candidate during re-entry.

Shared feedback shows unresolved save, destination, scale, audition and output
issues. Routine successful Live Edit stays quiet; explicit Generate confirms
completion. Entry navigation appears only during re-entry.

Re-enter starts a detached candidate over the active memory span. Set each value
and press **Enter and Advance** to mark it entered. Back and Restart Cursor only
move the stage cursor; changing an entered value clears its marker. Generate
reports missing entries without applying an incomplete candidate. **Finish** is
available only after every position is entered and applies one undoable edit;
**Discard** abandons the candidate. Neither action automatically resumes a
blocked navigation or command: invoke that action again. Closing the dialog or
changing song drops the candidate and retains the canonical draft best effort.

**Audition PITCH** previews the selected resolved pitch or PITCH-stage candidate
through the selected native instrument and non-send track. TIME-stage audition
is disabled. It changes no source or phrase. Release is nominally scheduled
after 120 ms, subject to host load; cleanup is best effort if captured host
objects disappear. ACID never substitutes a replacement object at a reused index.

Timing selects straight sixteenth steps or 1/8 triplet steps. Straight uses
phrase LPB 16 and triplet LPB 12, with four phrase lines per source step. A
cycle of N steps lasts N/4 or N/3 quarter-note beats respectively, so each step
keeps its 1/4-beat or 1/3-beat duration. Changing timing keeps
both memories intact. Phrase timing is local to the phrase; ACID does not change
the song tempo, LPB or meter. Timing is saved with the source and is included
in Undo, Redo and Reset. Phrase output and PB Range are separate phrase settings.
At N=32, Play Once has 128 lines. Repeat has 257 lines: the steady loop starts
at line 129 and ends exclusively at line 257, the empty sentinel. The phrase
capacity is 512 lines. Renoise API 6.2 allows at most 126 phrases per instrument.

A NOTE consumes the next active PITCH entry. TIE holds the current semantic
voice without consuming pitch memory, and REST releases it. ACCENT and outgoing
SLIDE belong to PITCH entries. Entering TIE at TIME 01 stores NOTE. Repeat
cycles reset pitch consumption to P01 while preserving the sounding voice for
boundary interpretation.

## Scales and randomization

In **Extended / Clear**, choose a root and then a scale to apply its MASK.
Root, category, and search are browsing controls and never change the stored
mask by themselves. Selecting a scale applies the absolute note set at that
root as one undoable edit. Identical note sets appear once with searchable
aliases. Edit the checkboxes for a custom mask. MASK preserves raw notes and
filters audition/output.

With MASK enabled, **Randomize PITCH** samples allowed notes in the MIDI range.
**Follow scale** snaps Program/Grid note entry; green keys mark allowed classes.
Follow defaults off. Root/browser/Follow are session controls; MASK is saved with
the pattern and supports Undo/Redo.

PITCH and TIME have separate seeds and **Last used** values. Random
operations decorrelate adjacent seeds before sampling. **Apply** keeps the
entered seed. Change the seed for another result; return to an earlier seed
and Apply with the same range/weights, mask and scope to recall its result.
**Repeat last** reuses Last used with current settings/mask without changing the seed field.
Undo restores the pattern, not seed controls. Seeds last for the editor session.

**Import .txt** adds scales such as `My scale = 0 2 3 5 7 9 10`, saves them in
tool preferences and deduplicates them. Conflicting names with different
intervals are rejected. See [the text format](../docs/acid-scales.md).

## Generating phrases

Choose any instrument slot and an existing unchanged ACID-owned phrase or
**New Phrase**. **Repeat** is the default output policy. **Play Once** renders
one traversal with an explicit final release. Changing this policy changes the
owned phrase layout and saved phrase settings, not the PITCH/TIME source or the
instrument's global phrase trigger settings.

The Phrase control binds ACID to an exact instrument and phrase.
Selecting an ACID-owned phrase in Renoise's Phrase Editor loads its source and
PB Range into ACID. Navigation and restoring a saved draft never generate music.
Native instrument and phrase changes refresh the choices without inferring
that a copied phrase belongs to ACID.

Manual Generate and Regenerate remain available. Live Edit optionally applies
each valid source/settings edit immediately through the single serialized,
synchronous writer. The write finishes inside the initiating user action; if a
writer job is already active, only the latest pending trigger is retained.
Undo and Redo cover source edits and phrase output policy and PB Range. A failed
Live Edit remains armed; correct the source or use Retry Live Edit. Enabling
Live Edit arms subsequent edits without writing.
Label-only changes use ACID Undo/Redo without rendering, source dirtying or a
phrase revision. Native host Undo for label metadata is not guaranteed.
Normal generation creates only for an explicitly selected **New Phrase**
destination; Duplicate has its own verified committed-source authorization.
Foreign, modified, deleted and colliding phrases block generation; choose New
explicitly to create separate output.
Uncommitted drafts with an unambiguous song key are stored separately from the
last committed phrase in song tool data and recover after saving and reopening
the XRNS. A successful write clears only the exact draft revision it commits;
later edits remain dirty. If a draft has an ambiguous destination or persistence
fails, it remains available in the open session and ACID reports the unsaved
state. Give a new draft's instrument a unique name or generate its phrase before
closing the song. Detached drafts are session-only and have no manual recovery
interface. ACID protects
foreign or modified phrases and uses ownership checks, source persistence and
verified rollback when updating an owned phrase in place. The persisted source
schema is `ACID-PITCH-TIME-2`. Only empty song tool data or strict schema 2
is accepted. Unsupported or corrupt data blocks writes and retains its bytes;
ACID offers no conversion or reset. With Live Edit off, the source remains dirty until
a successful Generate applies the draft.

Native copies with the same ACID ID block every holder of that ID. ACID does
not re-key copies or adopt imports. Select another valid destination or New
explicitly; selection cannot clear a song-wide integrity blocker.

Create needs one free phrase slot under Renoise's 126-phrase instrument limit;
it inserts the final destination. Regenerate updates the exact existing phrase
without inserting a separate staging/backup phrase, deleting, or reordering
phrases, including when its instrument has no free phrase slots. The write
completes inside the initiating user action.
Each successful generation receives a fresh source revision ID; older source
rows remain in the song so native Undo and Redo can restore matching music,
source and settings. The revision number in the phrase name changes while its
position and native phrase object stay the same. This increases stored source
data with committed revisions.
If cleanup, rollback or committed-source adoption cannot be verified, ACID
blocks further mutations and retains integrity evidence. These states have no
repair action in ACID. Changing targets, reopening the dialog or reattaching
the same song does not establish safety or clear a persistent song blocker.
Existing phrase content and saved data remain protected; failed draft saving
is still reported separately. Do not rely on retry or reopening as a repair.

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

## Pattern tools

In the editor toolbar beside Program/Grid and Undo/Redo, choose PITCH, TIME or
Both, then Copy or Paste. Paste requires a matching copied scope and available
editing; pending entry or an unresolved rename must be resolved first. The
session clipboard holds all 32 records and the corresponding active bounds.
It excludes timing, mask, labels, output settings and destination identity.
Copy and scope selection do not save or generate. Paste is one ordinary edit;
an identical paste does nothing. Paste into New Phrase follows the usual
Live Edit or manual Generate authorization.

**Rename** accepts 1–32 ASCII characters: start with a letter or digit, followed
by letters, digits, spaces, underscores, periods or hyphens. Input is never
trimmed or truncated. Labels are song metadata, may repeat and do not change
the sealed native phrase name. A fresh draft is Untitled; first generation
uses `Pattern <ID>` unless you explicitly entered a custom label. A failed
label-only save retains the accepted label/history and offers Retry or Discard
Attempt. Resolve it before switching target or using Undo/Redo. Discard does
not clear an independent storage-integrity blocker.

**Duplicate** creates a fresh owned phrase from the verified committed source,
mask and output settings. It preserves a dirty original draft only after a
successful durable save and exact readback; failure aborts the duplicate.
It never substitutes the dirty draft for committed music.

In **Extended / Clear**, the optional twelve-class mask resolves raw pitches
to the nearest enabled note within MIDI 24–60, with lower-note ties. Raw values
remain intact. A disabled empty mask is valid; enabling it or removing its
last enabled class is rejected. Decoded Start/Repeating pages show four TIME
steps at a time, including consumed PITCH index, raw and resolved note, and
articulation. The renderer uses the same resolution.

Clear and transform operations offer Active memory or All 32 stored scope
and apply immediately in Program and Grid. Clear PITCH resets notes and both flags;
Clear TIME sets NOTE. Clear TIE changes TIE to NOTE, while TIE-to-REST changes
it to REST. Clear REST and REST-to-NOTE change REST to NOTE. Clear ACCENT or
SLIDE changes only that flag. Seeded PITCH randomization uses a selected raw
24–60 range and retains flags; TIME randomization uses NOTE/TIE/REST weights.
Set randomization seed, range or weights inline in Extended / Clear, select
scope, then Apply for one direct edit in either view.
TIME 01 normalizes a drawn TIE to NOTE. Scope never changes active bounds;
All 32 also edits inactive storage. Each changed result is one undoable edit.

**Reset pattern** preserves Length and label. It resets all pitch notes and
flags, all TIME commands, PITCH span to 16, timing to straight, mask to disabled
with every class selected, and output/PB settings to defaults. An identical
reset has no edit effect. Reset applies immediately in both views and one
Undo restores the complete changed state.

## Using generated phrases in Renoise

Use Renoise's instrument phrase playback controls to enable phrase triggering,
then enter instrument notes and phrase-selection commands in the Pattern
Editor and arrange those patterns in the Pattern Sequencer. Phrase keymap or
program selection, trigger-note transposition and native phrase length controls
belong to Renoise. ACID does not configure their instrument-wide settings.

Change ACID LAST STEP or PITCH span to change its source, then Generate.
Editing generated phrase notes, length or loop properties directly can invalidate
ownership and block regeneration. Regeneration replaces generated content;
arbitrary manual edits are not preserved. A verified single-sequence loop does
not establish continuous slides across independent phrase switches.

## Native acceptance status

Recorded deterministic and native results, host versions and limitations are
in the [acceptance record](../tests/acid/runtime_acceptance.md). Final integrated
editor, playback, persistence, Undo/Redo and Live Edit acceptance remains
unverified until the required native procedures are executed. Procedure
readiness and mocked tests do not establish sound, timing or GUI behavior.

Max-length timing/layout playback, PB center-reset alignment at LPB 16/12,
host groove and receiver-dependent audio require the
[manual checklist](../tests/acid/acid_m35_s_manual.md) and
[timing checklist](../tests/acid/acid_timing_manual.md). A receiver that ignores
pitch-bend commands will not produce the intended bend; use PB Off for
receiver-controlled note overlap. Generation requires LPB transport timing and
rejects unsupported speed timing before changing phrases or saved source.

## Development checks

Use the [editor presentation checklist](../tests/acid/acid_editor_presentation_manual.md)
for labels, phrase controls, staging visibility and layout.

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
