# Renoise verification

Environment: Windows, PowerShell 7, Lua 5.1, Renoise 3.5.4, API 6.2.

| Check | Result |
| --- | --- |
| Offline preflight, transport and runner regressions | PASS |
| Fresh-launch Native smoke | PASS: handshake, document reset, stable inventory, driver shutdown and installation restoration |
| Selected-PID Native smoke with a concurrent instance | PASS: target startup resumed after deployment; both instances remained open; original installation restored |
| Loaded-instance reload | PASS: native Reload All Tools, Native smoke, original-file restoration/reload and ACID dialog opening; both instances preserved |
| Host startup timeout | PASS: exit 1, ERROR report, verified backups retained; both instances preserved; recovery restored original files |
| Active-connection loss on driver reload | PASS: exit 1, ERROR report, verified backups retained; both instances preserved; recovery restored original files |
| Release/development package separation | PASS |
| Keyboard tests | Not implemented |
| Playback, rendering, undo and persistence acceptance | Not covered by the transport smoke; use the ACID manual guides |

Snapshots contain native inventory values and selection indices. Indices describe
positions at readback time, not persistent object identity. Driver shutdown is
complete only after its per-run completion file is observed and removed.

## Runner verification rerun (2026-10-29)

The fresh-launch command was executed from the repository root in PowerShell 7:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -StartupTimeoutSeconds 45
```

Run `51d5a00dea1e4fccab5e75aa5ac1708e` passed on Renoise 3.5.4 / API 6.2,
against source commit `5298732dab24bee1448f6b032a273d04a7e8b244` before the
runner corrections in this rerun. Its inspected report is retained locally at
`tmp/interactive-51d5a00dea1e4fccab5e75aa5ac1708e/report.json`; temporary
reports and credentials remain untracked. The report independently records ten
instruments, zero phrases, document epoch 1, matching snapshots and empty queues.
The snapshot SHA-256 is
`61256cf58875dea9f6046a2b59bd569ccddc7bf0a6091f1b482d737854ba723e`.
Driver shutdown and original-installation restoration passed. Graceful process
closure timed out; identity-checked forced termination closed only the
runner-launched disposable process.

Final-change verification on 2026-10-30 used the same command and passed as run
`4cd6c1ca637b4766b8c1bb5d33da34a1`, with report at
`tmp/interactive-4cd6c1ca637b4766b8c1bb5d33da34a1/report.json`.
Both snapshot epochs matched the reset epoch, with the same inventory and
snapshot digest above. Driver shutdown, identity-checked process cleanup and
installation restoration passed. The intermediate verification run
`d67ebbc970f847428a975e7152cc7426` also passed. These reports were inspected;
they describe the local working tree based on the source commit above, including
the runner corrections, rather than a newly committed revision.

Offline second-pass checks passed: runner transport/ownership/installation specs
(including refusal before sending on process-identity failure, nonboolean or
missing response fields, startup timeout, connection loss and retained-backup
paths), host preflight, development packaging, transport Lua specs, all 50
repository Lua specs, release packaging (28 runtime files), and `git diff --check`.

The selected-PID, loaded-instance, concurrent-instance and native interruption
results in the table above are earlier observations, not new executions in this
rerun. Their original temporary report identifiers were not recorded. Reproduce
selected-instance checks with the following command, using a disposable song and
reloading ACID in the selected instance when prompted:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -RenoiseProcessId <pid>
```

Inspect the emitted `report.json`, its operation trace and both snapshot files;
check installation restoration and that developer-owned instances remain open.
For startup timeout or active-connection loss, require a nonzero exit and ERROR
report, then inspect the reported retained backups before recovery. These
interruption checks must use controlled disposable instances.

Manual host checks cover clean new/save/load, dirty-song Cancel/Save/Discard,
tool reload and foreground activation. `save_song_as` can write a fixture without
delivering a saved-document notification; verify completion from native readback.
