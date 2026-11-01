# ACID phrase destination checks

Use a disposable song in Renoise 3.5. Open ACID and edit the ready draft, then
generate a new phrase. Change the source and output policy and regenerate the
selected owned phrase. Confirm the source and phrase policy restore when the
destination is selected again and after saving and reopening the XRNS.

While ACID holds an owned phrase and an unsaved edit, load or remove a plugin,
sample, or MIDI receiver on that instrument. Confirm the edit remains attached
and Generate uses the current receiver without reporting a changed committed
baseline. With pitch slides enabled, include a receiver change that alters the
required pitch-bend commands. Edit a native phrase cell separately and confirm
that genuine output drift still blocks regeneration.

Append a second phrase and confirm the first phrase remains unchanged. Select a
foreign phrase and confirm it cannot be replaced. Manually edit an owned phrase
and confirm ACID refuses to regenerate it. Rejected older snapshots and seals
remain untouched; recreate their source in the current editor.

With Live Edit enabled, select another ACID-owned phrase in Renoise's Phrase
Editor. Confirm ACID's destination follows that selection and restores its
source and PB Range without rendering an unchanged saved source. Choose each
existing phrase in ACID's Destination menu and confirm Renoise's Phrase Editor
selection remains unchanged. Change a PITCH or TIME entry; the ACID destination
must regenerate in place, the phrase count must stay unchanged, and Renoise's
native selection must remain unchanged. Regeneration must not insert or delete
any phrase. After the action, select another owned phrase in Renoise and confirm
ACID follows that selection and restores its source and settings. Close ACID and
confirm later Phrase Editor selections do not trigger edits.

Earlier Renoise 3.5.4 check with the script writer: selecting phrase 01 in Renoise's native map updated ACID's
destination and restored phrase 01's source. Choosing phrase 02 in ACID left
Renoise's selection on 01; regenerating 02 kept the count at two and then
selected 02 as a structural side effect. This is regression evidence for the
replaced writer, not acceptance of the direct writer.

After a manual Regenerate and after a Live Edit, use Renoise's native Undo and
Redo. At each settled state, verify the phrase cells, ACID source, output policy,
PB Range and visible editor controls all match that revision. The phrase object,
list order and count must stay unchanged. Undo must not trigger generation.
Repeat after saving and reopening the song. An uncommitted draft must remain
recoverable without replacing the restored revision's editor state.

For the Program/Grid and Repeat/Play Once cutover checks, use the
[current Renoise checklist](acid_m35_s_manual.md). The current-format
save/reopen and ownership behavior has deterministic Lua coverage; native GUI,
undo and playback acceptance must be recorded separately.
