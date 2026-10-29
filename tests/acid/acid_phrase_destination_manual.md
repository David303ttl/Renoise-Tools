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
selection remains unchanged. Change a PITCH or TIME entry; the ACID destination
must regenerate in place and the phrase count must stay unchanged. Temporary
phrase operations may change Renoise's native selection; verify that their
notifications do not redirect ACID's destination. During an asynchronous render,
select another owned phrase in Renoise and confirm ACID follows that selection
without restoring the earlier native selection on completion. Close ACID and
confirm later Phrase Editor selections do not trigger edits.

Renoise 3.5.4 check: selecting phrase 01 in Renoise's native map updated ACID's
destination and restored phrase 01's source. Choosing phrase 02 in ACID left
Renoise's selection on 01; regenerating 02 kept the count at two and then
selected 02 as a structural side effect. Live Edit and selection changes during
render remain unverified.

For the Program/Grid and Repeat/Play Once cutover checks, use the
[current Renoise checklist](acid_m35_s_manual.md). The current-format
save/reopen and ownership behavior has deterministic Lua coverage; native GUI,
undo and playback acceptance must be recorded separately.
