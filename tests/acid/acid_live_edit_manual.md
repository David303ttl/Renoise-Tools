# ACID Live Edit manual verification

Use the [integrated setup and evidence fields](acid_regeneration_manual.md)
and [canonical persistence/Live Edit checks](../../com.david303ttl.ACID.xrnx/M5_EDITOR_PLAYBOOK.md#137-persistence-ownership-undo-and-live-edit).
These procedures do not claim an executed native result.
Executed checks and remaining limits are recorded in
[integrated native verification](runtime_acceptance.md#integrated-editor-and-live-edit-verification-2026-11-02).

1. Open **Tools > ACID...** with an unchanged owned phrase selected. With
   **Live Edit** off, change a PITCH note and a TIME command. Verify a dirty
   recoverable draft and unchanged native phrase cells. Save/cold-reopen the
   song and compare draft and committed source separately.
2. Return to the clean fixture. Enable **Live Edit** without editing. Compare
   phrase cells, inventory and persisted source: arming alone must not write.
   Switch Program/Grid, pages, preview cycle, workspace and targets. Navigation
   must not generate; returning to a dirty target restores its own draft.
3. Edit PITCH, octave, ACCENT, SLIDE, TIME and output settings individually.
   Each accepted musical edit uses the guarded synchronous writer and updates
   the same owned destination. Inspect actual cells, source association and
   unchanged peers after each callback. Label-only edits and mask inspection
   must not render. Do not describe a background render or asynchronous job.
4. Make several successive edits and switch targets between settled callbacks.
   Verify each target's source/output association and no stale write to another
   target. Disable Live Edit, edit again and verify unchanged output until
   **Regenerate**. Check ACID Undo/Redo with Live Edit both off and on; record
   native host Undo separately, including metadata-only limitations.
5. Select **New Phrase**, edit with Live Edit off, then explicitly **Generate**.
   Only the selected New destination permits creation. Select a foreign,
   manually modified, deleted or colliding target; generation must block and
   retain the draft. Live Edit never silently creates a replacement phrase.
6. Change songs or close ACID between edits. Reopen and inspect song context,
   observers and destination identity. A stale editor must not write to the
   replacement song. Save/cold-reopen and compare all source/settings/draft
   values without automatic generation.
7. Execute the safe failure cases in canonical 13.4/13.7 on disposable copies.
   Preserve byte/preimage evidence, unsaved draft and independent blockers;
   record Retry and recovery behavior without inferring durable success from
   status text alone.
