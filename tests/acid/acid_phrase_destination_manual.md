# ACID M1: reopening, song persistence and phrase destinations

Run locally in Renoise 3.5+ against the M1 branch. Do not run GitHub workflows.

1. With a sample instrument containing no phrases, open ACID. Set LAST STEP=16;
   Create Pattern; change P02 to D#, octave UP, accent ON; set TIME step 02
   to TIE and step 04 to REST. Choose NEW PHRASE and generate.
2. Close ACID and reopen it. The current instrument/phrase program should select
   the generated ACID phrase automatically. Check that its original PITCH
   memory, TIME states, LAST STEP, accent/slide and renderer mode all reappear.
3. Save the XRNS, close/reopen Renoise and reload the song. Select this same
   phrase and ensure its source is restored from song.tool_data.
4. Choose NEW PHRASE, create a new pattern, set LAST STEP=17 and generate.
   Verify a second phrase was appended without changing the first phrase.
   Switch destination between phrases 01 and 02; each must reload its own
   source, and the instrument phrase program must address the generated slot.
5. Add a manually created phrase. Select it in ACID. It must be shown as
   foreign and blocked from overwrite. ACID should require NEW PHRASE.
6. Edit a sealed ACID phrase directly in Renoise. Its status should be
   modified; ACID must refuse overwrite or restoration of stale source.
7. Open an older ACID 0.1 phrase with no snapshot ID. Its original PITCH/TIME
   state is not recoverable from rendered notes. Do not silently invent memory.
8. Run the local Lua tests with
   pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID

Known boundary: this implementation persists the source when successfully
generating a phrase; unsaved UI edits are not autosaved before generation.
