# ACID phrase destination checks

Use a disposable song in Renoise 3.5. Open ACID and edit the ready draft, then
generate a new phrase. Change the source and output policy and regenerate the
selected owned phrase. Confirm the source and phrase policy restore when the
destination is selected again and after saving and reopening the XRNS.

Append a second phrase and confirm the first phrase remains unchanged. Select a
foreign phrase and confirm it cannot be replaced. Manually edit an owned phrase
and confirm ACID refuses to regenerate it. Rejected older snapshots and seals
remain untouched; recreate their source in the current editor.

With Live Edit enabled, select another ACID-owned phrase in Renoise's Phrase
Editor. Confirm ACID's destination follows that selection and restores its
source and PB Range without rendering an unchanged saved source. Choose each
existing phrase in ACID's Destination menu and confirm Renoise's Phrase Editor
shows the matching phrase when the target instrument is selected in Renoise.
Change a PITCH or TIME entry; the selected phrase must
regenerate in place and the phrase count must stay unchanged. Close ACID and
confirm later Phrase Editor selections do not trigger edits.

On Renoise 3.5.4, selecting phrases 01 and 02 in either interface with Live
Edit enabled updated the other interface. A destination-selected phrase also
remained selected after a PITCH edit and regeneration. These checks used the
running tool and do not establish playback behavior. Assignment to
`selected_phrase_index` worked in this host despite the bundled API 6.2
definitions marking it read-only; other host versions remain unverified.

For the Program/Grid and Repeat/Play Once cutover checks, use the
[current Renoise checklist](acid_m35_s_manual.md). The current-format
save/reopen and ownership behavior has deterministic Lua coverage; native GUI,
undo and playback acceptance must be recorded separately.
