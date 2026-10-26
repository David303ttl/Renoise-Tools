# ACID 0.1 — safe regeneration and memory UI

Use a disposable Renoise song and a sample instrument containing one
existing legacy or newly generated ACID phrase. The version remains 0.1.

1. Reload the newly packaged ACID tool.
2. In the PITCH/TIME editor confirm the explicit counters:
   TIME filled / total, NOTE/TIE/REST totals, PITCH entries / 16,
   NOTE triggers, next pitch-memory entry, and free pitch slots.
   The list of timing commands must update with every edit.
3. Change TIME step 2 to REST; verify counters change. Set it back to TIE.
   Increase timing length to 12; verify four added REST steps, 12/12
   filled, and TIME cursor range capped at 12.
4. Generate on an instrument with no phrases. Record phrase index and
   the original 16-line content.
5. Change the first pitch and click Generate / Regenerate again **without
   deleting the phrase**. Verify phrase count remains one, index stays
   01, and the note changes. No other instruments or tracks are altered.
6. Modify a note manually in the generated phrase. Attempt regeneration:
   ACID must refuse to overwrite the modified phrase.
7. Use another instrument with a non-ACID phrase. Attempt regeneration:
   ACID must refuse.
8. A phrase created with the older tool is named `ACID 0.1 TEST`.
   Regeneration must initially refuse; then select **Adopt legacy ACID
   0.1 TEST once** and generate. Verify no extra permanent phrase and
   the original slot is reused. Do not adopt a phrase containing edits
   you wish to retain.
9. Try rendering invalid TIME/PITCH data; verify that the earlier valid
   phrase remains playable.
10. Save, close, reopen the Renoise song, then regenerate the unmodified
    ACID phrase. Its content signature should remain recognizable after
    loading the song.

ACID ownership uses a generated content signature in the phrase's name.
It prevents overwrites when the signature differs. It does not give
permission to modify arbitrary phrases and is not a cryptographic guarantee.
The old phrase is backed up in a temporary phrase before being replaced.

Local validation from repo root (PowerShell 7):
```powershell
pwsh -NoProfile -File ./scripts/run_tests.ps1 -Tool ACID
pwsh -NoProfile -File ./scripts/package.ps1 -Tool ACID
```
No GitHub Actions. Renoise playback/save/reload checks remain manual.
