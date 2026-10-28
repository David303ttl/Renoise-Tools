# ACID M3.5 Renoise manual checklist

**Acceptance status (2026-10-28): partial.** Renoise 3.5.4 checks in a
disposable song verified installed-writer Repeat generation and measured the
M4 timing fixtures; the bounded Surge XT phrase bend/reset check also passed.
The broader M3.5 target, source, persistence, ownership and Live Edit checklist
below remains incomplete. Record Renoise version, target type and
pass/fail/not-run for each item before treating those gates as complete. A
passing Lua mock is not a playback receipt.

## Program/Grid and source

1. Open ACID on a fresh instrument slot. Confirm the draft is editable without
   a Create step, with C pitches, NOTE commands, LAST STEP 16 and PITCH span 16.
2. Change LAST STEP to 32, then 64, and PITCH span to 3. Confirm LAST STEP
   accepts values from 1–64. Edit TIME 32 and 64 and PITCH positions 1–3.
   Switch Program → Grid → Program. Confirm the source values,
   decoded preview and generated phrase cells do not change from view switches.
   With Live Edit enabled, confirm switching views does not queue a render.
3. Edit TIME 17, reduce LAST STEP 16, then restore 17. Confirm TIME 17 remains
   unchanged. Save and reopen the XRNS and repeat the check.
4. Enter TIE at TIME 01. Confirm it is stored as NOTE. Click Reset Source once
   and confirm the source resets immediately. Use Undo and Redo and confirm
   the source and output policy follow each edit.

## Output policy and destination safety

1. Record the selected instrument's phrase trigger mode and phrase program.
   Generate an ACID-owned phrase with Repeat, then choose Play Once and
   regenerate it, then return to Repeat. Confirm only the owned phrase layout
   and saved output policy change; PITCH/TIME, trigger mode and phrase program
   remain unchanged.
2. With at least two owned phrases, select the second phrase and regenerate it.
   Confirm it is updated in place, the first phrase is unchanged, and the
   destination chooser remains on the selected phrase.
3. Verify Repeat contains a cold introduction and repeating body. Verify Play
   Once contains one traversal and a final release. Inspect NOTE/TIE/REST cells,
   the final release and the ownership seal.
4. Edit an owned phrase manually and confirm ACID refuses replacement while
   preserving it. Confirm a foreign phrase is also preserved.

## Target families and articulation

Repeat the generation check with a sample instrument, a plugin-only instrument,
an external MIDI instrument with a configured output, a hybrid instrument, and
an empty slot. Confirm plugin/MIDI output keeps the note order and reports any
slide approximation. Confirm an empty slot commits a silent phrase with a
warning. Record actual note, velocity, OFF and pitch-bend/glide behavior; do
not infer these from phrase cells alone.

Use a source with NOTE–TIE–NOTE–REST, an outgoing SLIDE at the Repeat seam, a
connected ACCENT change and a large pitch interval. Generate manually and with
Live Edit. Confirm generation commits in each case, notes remain ordered, REST
and Play Once releases are present, and reduced-fidelity behavior is reported
as an approximation. Confirm failures leave the last-good phrase and recoverable
source intact.

With a sample target, also use NOTE–TIE–NOTE–NOTE with an outgoing slide into
the third NOTE. Confirm its 0G command completes before the fourth NOTE's
midpoint OFF, and both the glide and OFF remain in the phrase.

## Plugin and MIDI SLIDE

1. Use a plugin-only or MIDI-only target with no samples. Enable the receiver's
   mono-legato portamento and choose an audible glide time. Keep its preset and
   routing unchanged while generating. Record receiver and configuration.
2. Generate NOTE C → NOTE G with outgoing SLIDE on C. Inspect the target line:
   G starts in another note column with delay 00; C has OFF with delay 01 in its
   original column. Capture note-on G before note-off C. Listen for continuous
   pitch movement without an envelope restart. A polyphonic receiver may overlap
   notes instead; do not record that as glide success.
3. Disable the SLIDE flag. Confirm a midpoint OFF separates C and G and the
   receiver produces a fresh attack. Re-enable it and confirm overlap returns.
4. Try C → C with SLIDE. Confirm the second C emits neither a new note-on nor
   a note-off; a subsequent REST releases the held C. A changed accent on this
   held voice produces an explicit limitation rather than a retrigger.
5. Repeat three distinct sliding notes for several cycles. Inspect all three
   note columns and the last-to-first seam. Capture note order and delayed OFFs;
   confirm no accumulating notes. Repeat with C → G → C and same-pitch seam.
6. Exercise TIE, connected ACCENT, REST, 64 steps, Play Once tail, stop/start,
   seek and Live Edit regeneration. Verify note-offs in the MIDI/plugin capture.
   Test hybrid layers separately; their sample envelopes may retrigger.

## M3.6 Plugin/MIDI pitch bend

### Fresh tool prerequisite

After every runtime change, run `pwsh -NoProfile -File ./scripts/package.ps1 -Tool ACID` and install the newly built `dist/com.david303ttl.ACID_0.1.xrnx`
by dragging it onto Renoise. Accept replacement of the installed tool and close
any old ACID dialog. Reload the tool or restart Renoise after saving the current
song; copying files or rebuilding the archive alone does not replace loaded Lua
modules. Run playback checks in a new disposable song. Record the package SHA-256
(`Get-FileHash ./dist/com.david303ttl.ACID_0.1.xrnx`) with the receipt so an
unchanged manifest version cannot conceal an old installation.

### Support gate and bounded receiver check

**Bounded host check (2026-10-28): passed for native phrase delivery to Surge
XT in global instrument slot `03`.** Renoise 3.5.4 Demo played a held note
with phrase-contained `M1` commands. A raw Audacity 3.7.8 capture measured
130.82 Hz → 195.92 Hz → 130.92 Hz (approximately +6.99 semitones, then center)
with the phrase instrument/sample field empty (`instrument_value = 255`).
Peak was -1.95 dBFS. See the [audio receipt](audio_capture_evidence.md#phrase-pitch-bend-receiver-check-2026-10-28).

Phrase commands now leave that field empty to follow the generated notes'
default MIDI channel. It is not a global instrument-slot destination. A slot-03
probe also responded with field `00`, so matching a slot number was not evidence
of global-slot addressing. Pattern Editor targeting must not be copied into
phrase commands.

This is a bounded receiver result, not a general VST/MIDI compatibility claim.
The private `writers/phrase_pitch_bend.lua` support gate is enabled after
checking the corrected installed writer in Renoise: empty carrier fields and
audible center → intermediate bend → G in instrument slot `03`. PB Off retains the existing
overlapping-NOTE route; unsafe Repeat seams retain the whole-phrase fallback.
Host Undo, save/reopen, external MIDI, arbitrary MIDI channels, hybrids and
other receivers still need their listed manual checks.

Offline rendering was attempted but is disabled in Renoise Demo. The accepted
receipt uses live WASAPI loopback at 48 kHz to Audacity, with Recording Level
97%, following the previously measured route. Windows playback volume was not
changed. The original song was backed up before testing.

1. Use a disposable song and one plugin-only instrument with a bend-responsive
   VST. First place it in slot `00`, then repeat in a nonzero slot such as `03`.
   Set the VST bend range to ±12 semitones and turn
   its own glide off. Record the Renoise version, VST/preset and target
   instrument slot; do not change the instrument's routing.
2. In a native instrument phrase, enter a held C note in one note column. In
   the rightmost visible note column, leave the instrument/sample field empty
   to match the generated notes' default MIDI channel. Enter
   `M1` in the panning field and `652A` in the associated effect field. Enter
   another `M1` command with `4000` while the note is still held. For a ±12
   receiver, `652A` is approximately +7 semitones and `4000` is pitch-bend
   center.
3. Trigger the phrase. Confirm the held voice bends upward and returns to C
   without a new note attack, and confirm the commands reach the intended VST.
   Record pass/fail and any host limitation here:

   | Renoise | VST / preset | Global slot | Phrase field | Package SHA-256 | Result / evidence |
   | --- | --- | --- | --- | --- | --- |
   | | | `00` | | | Not run |
   | 3.5.4 Demo | Surge XT, cloned receiver | `03` | Empty (`255`) | See audio receipt | Pass: +6.99 semitones and return to center |

4. Compare with the same held-note bend/center commands in the Pattern Editor
   as a positive control. A pattern-only success does not pass phrase delivery.
   Confirm the nonzero-slot test controls the selected receiver and leaves a
   different instrument untouched. Record audible pitch or captured audio/MIDI,
   including the +7-semitone endpoint and return to center; cell readback alone
   is insufficient.
5. If the phrase does not deliver both commands, record the specific failure
   and leave PB Range unsupported. Do not add MIDI routing devices or track
   automation as a fallback.

After P0 passes, test the generated PB Range feature with these focused cases:

| Check | Pass condition | Result |
| --- | --- | --- |
| PB Off | Existing plugin/MIDI overlapping-NOTE SLIDE and sample 0G glide are unchanged | Not run |
| PB ±12, C→G→C | One held note reaches each target and returns to center | Pass in slot `03`: +6.99 semitones and return to center; see [audio receipt](audio_capture_evidence.md#phrase-pitch-bend-receiver-check-2026-10-28) |
| NOTE→SLIDE→NOTE→REST | Connected boundary has no retrigger; REST releases and centers bend | Not run |
| Short C→G slide, no following TIE | Lines 1–4 contain C/center, intermediate bend, G endpoint, OFF/center; listen for connected motion | Pass in slot `03`: +3.42–3.45 intermediate, +6.92–6.94 endpoint; release/reset tail audibly bends down |
| Two connected slides and Repeat seam | Accumulated bend and cold/steady seam do not jump or stick | Not run |
| Unsafe Repeat seam | Whole phrase uses the overlapping-NOTE route with an approximation warning; note order, release and repeated playback remain usable | Not run |
| Instrument moved during generation | PB render is rejected without replacing the last-good phrase; regeneration targets the current slot | Slot `03` ↔ `04` move: suspended; phrase count/name/source/ownership preserved. Post-move regeneration not checked here |
| Range exceeded | Ordered NOTE fallback and TIME-step approximation warning | Not run |
| Save/reopen and Live Edit | PB Range restores for each owned phrase and regenerates safely | Not run |
| Plugin/MIDI unavailable and hybrid target | Phrase generation remains available with the documented warning | Not run |

## Save, reopen and Live Edit

1. Save and reopen the XRNS. Confirm current source and Repeat/Play Once policy
restore for each owned phrase.
2. Enable Live Edit on New Phrase and confirm it creates and binds an owned
   phrase automatically. Make a source edit and confirm rendering starts
   immediately without Generate or a debounce wait. Make several edits during
   rendering and confirm the latest source applies automatically next.
   Disable Live Edit during an in-flight
   render and confirm the destination remains consistent.
3. Change songs while ACID is open, then close/reopen the tool. Confirm stale
   jobs are invalidated and no phrase in the new song is changed.
4. Edit without generating, switch destinations and return, then close and
   reopen ACID. Confirm the draft is restored. Save the XRNS with an ungenerated
   edit, reopen the song and confirm the draft restores separately from the
   last committed phrase. Generate and confirm the pending draft is cleared.
5. Use Undo and Redo during Live Edit. Confirm source and output policy follow
   the selected edit and the final generated phrase matches the source. Change
   BPM, LPB/TPL and groove during playback, then stop/start/seek. Confirm Live
   Edit remains armed and note/OFF order stays correct.
6. Cause a recoverable render failure and confirm Live Edit stays enabled.
   Correct the problem by editing the source; confirm it renders immediately
   and preserves the last-good phrase until success. Modify or delete the
   destination externally; confirm Live Edit creates and binds a separate owned
   phrase automatically and preserves unrelated content.


## Async generation and draft safety

1. Generate a new phrase, edit its draft while rendering, then switch to a
   different phrase or instrument before completion. Return to the generated
   phrase and confirm the pending edit survives. Confirm the other destination
   and its draft remain unchanged.
2. Change plugin, MIDI route or sample availability while rendering. Confirm
   the commit suspends, preserves the last-good phrase and reports the change.
3. Reorder instruments and phrases, delete the selected target and duplicate an
   owned ID. Confirm writes never reach a different destination. Recovering a
   draft does not authorize overwriting a foreign or modified phrase.
4. Make song tool data unwritable or corrupt in a disposable test. Confirm the
   source remains recoverable in the editor, persistence failure is visible and
   closing the song warns about any draft that could not be stored.

## Diagnostics and Windows scaling

At 125% and 150% scaling, inspect dirty, queued, rendering, committed,
approximate and error states. Confirm target and cause are readable
and diagnostic text can be selected. Use Go to source error and confirm the
reported TIME/PITCH location is selected without modifying source.

## Result record

| Check | Target / Renoise version | Result | Notes |
| --- | --- | --- | --- |
| Program/Grid and source | Renoise 3.5.4, disposable probe | Partial | Timing selection and Program-view Generate were exercised; Grid roundtrip and source-preservation cases remain unrun |
| Repeat / Play Once | Renoise 3.5.4, disposable probe | Partial | Repeat phrase generation/readback and audio timing passed; full Play Once and output-policy matrix remains unrun |
| M4 static timing audio | Renoise 3.5.4, native sample probe | Pass for scoped fixtures | 48 BPM/LPB matrix renders and the six required cycle fixtures passed; see [timing measurements](acid_timing_manual.md#measured-phrase-period-and-bpmlpb-acceptance) |
| Sample target | Renoise 3.5.4, 168-frame saw | Partial | Bounded connected slide and REST captures at phrase LPB 8 and 6 are recorded in the [timing checklist](acid_timing_manual.md#targeted-glide-and-bend-playback); other sample articulations remain unrun |
| Plugin-only target and legato SLIDE | Renoise 3.5.4, Surge XT slot `03` | Partial | Bounded ±12 phrase bend/reset and short-slide captures passed; general overlap/receiver matrix remains unrun |
| External MIDI target and legato SLIDE | | Not run | |
| Hybrid target | | Not run | |
| Empty slot | | Not run | |
| Save/reopen and recovery | | Not run | |
| Async generation and draft safety | | Not run | |
| Windows 125% / 150% scaling | | Not run | |
