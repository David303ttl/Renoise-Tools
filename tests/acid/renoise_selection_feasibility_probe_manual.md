# Renoise selection feasibility probe

Run the fixed native case from the repository root with PowerShell 7:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase selection-feasibility
```

The runner launches its own Renoise process and uses a disposable document.
The case appends identified probe phrases to the selected instrument and captures the native
`selected_phrase_index`, attempts indices `1` and `0`, and records API rejection,
immediate readback, and two subsequent idle readbacks for each attempt. It also
records phrase insertion/deletion effects after each attempted selection.
Cleanup removes only probe objects by identity and verifies the source bytes.

Inspect `report.json` in the emitted ignored run directory. A completed probe
is evidence of the recorded behavior; it does not mean a rejected setter works.
Require both setter pcall and stable readbacks before interpreting an assignment
as successful. Pinned API 6.2 marks this index read-only, so no production
selection restoration depends on this experiment. Native results belong in
[runtime_acceptance.md](runtime_acceptance.md).
