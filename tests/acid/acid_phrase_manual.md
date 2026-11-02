# ACID native phrase workflow acceptance

Use the [integrated setup/evidence fields](acid_regeneration_manual.md) and
[canonical retained workflow checks](../../com.david303ttl.ACID.xrnx/M5_EDITOR_PLAYBOOK.md#138-retained-renoise-workflow-acceptance).
Use [timing acceptance](acid_timing_manual.md) for Straight/Triplet, Play Once,
Repeat and sentinel inspection. Native playback remains unverified until an
observed result is recorded against the tested build and receiver.

1. Open **Tools > ACID...**, select **New Phrase** and prepare a representative
   NOTE/TIE/REST source with ACCENT and outgoing SLIDE on the last consumed
   PITCH entry. Select **Output > Phrase output > Repeat**, then **Generate**.
   Record LAST STEP, PITCH span, timing, actual phrase cells and receiver.
2. In Renoise's instrument **Phrase Editor**, select the generated phrase and
   choose native phrase playback **Prg** with that phrase program selected.
   In the **Pattern Editor**, enter a C-4 note with the same instrument on a
   sequencer track, followed by OFF after the listening interval. Start the
   song transport. Verify actual receiver output, then stop and retrigger.
   Record the chosen phrase program, trigger note, track, transport settings,
   note release and observed end-to-start slide. If the host labels differ,
   record the actual controls rather than assuming equivalent settings.
3. In Renoise's **Pattern Sequencer**, insert/repeat the trigger pattern and
   add a second trigger at a known song position. Play through both. ACID
   supplies phrase content; native patterns arrange and trigger it. Compare
   stop/retrigger with the continuous single-sequence loop. Independent phrase
   switches have no inherited continuity guarantee.
4. On a separate disposable copy, use the Phrase Editor's native key tracking
   **Transpose** and base note C-4, then trigger C-4 and D-4 from the Pattern
   Editor. Record actual transposition and receiver behavior. Also transpose
   phrase cells with Renoise's phrase selection transpose command and record
   the exact command. Reopen ACID and try **Regenerate** after destination
   changes: record ownership/incompatibility rejection and retained draft.
5. On another fixture copy, change native phrase length in the Phrase Editor
   and inspect playback and ACID's rejection of the changed destination.
   Contrast this with changing ACID **LAST STEP** or **Active PITCH span** and
   regenerating an unchanged owned target. Those source controls retain all
   32 stored slots; manual destination edits may invalidate ownership and
   regeneration does not promise to preserve arbitrary manual phrase edits.
6. Execute canonical 13.8 indicator cases on both Grid pages with a 32-slot
   fixture: default-but-referenced, nondefault-but-unreferenced, edited back to
   baseline, Undo/Redo and reload. Record legibility of stored/referenced/
   modified indicators separately from stage markers and canonical values.
7. Execute canonical 13.8 populated-song responsiveness checks. Record actual
   instrument/phrase counts, max-32 fixture, selection/page/view actions and
   observable stalls. Verify navigation neither persists nor generates; do not
   invent a millisecond acceptance threshold or infer resolution counts from
   perceived responsiveness.
