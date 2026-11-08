# ACID phrase destinations

Use a disposable song with sample, plugin, MIDI, hybrid and empty instrument
slots where available.

1. Select **New Phrase**, edit the source, and click **Generate**. Select the
   owned phrase, change source and output settings, and generate again. Confirm
   the selected phrase updates in place and that its source and settings return
   when reselected and after save/reopen.
2. Select a foreign phrase or manually change an owned phrase. **Generate**
   must refuse an unsafe target and retain the draft. Delete or reorder phrases
   while ACID is open; confirm callbacks follow exact destination identity or
   refuse a stale target, never writing to a phrase that reused its old index.
   Selecting **New Phrase** is the explicit path to create another phrase; existing
   phrases and unrelated song content remain unchanged.
3. With an owned phrase and unsaved edit, change the instrument receiver by
   loading or removing a plugin, sample or MIDI receiver. Generate against the
   current receiver without treating receiver changes as phrase-cell drift. Edit
   a native phrase cell separately and confirm that changed output is rejected.
   Include a pitch-slide source when a receiver change affects bend requirements.
4. With Live Edit enabled, select another ACID-owned phrase in Renoise's Phrase
   Editor. ACID follows the selection and restores that phrase's source and Bend
   range without rendering unchanged source. Choosing a destination in ACID leaves
   the native Phrase Editor selection unchanged. Editing updates the selected
   destination in place without changing phrase count or order.
5. After Generate and Live Edit, use Renoise Undo and Redo. Check phrase cells,
   source, output mode, Bend range and editor controls at each settled state;
   Undo must not trigger generation. Save and reopen, then verify the restored
   revision and any uncommitted draft separately.
6. Close ACID and change Phrase Editor selection. No later selection may cause
   an edit.

Inspect cells and playback separately. Phrase writes do not certify receiver
sound or native GUI behavior.
