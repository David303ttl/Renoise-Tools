# ACID direct output feasibility

Run the fixed native case from the repository root with PowerShell 7:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase direct-output-feasibility
```

The runner launches its own Renoise process and uses a disposable document.
The case appends identified probe phrases to the selected instrument,
materializes the existing planner's complete expected cell/property image,
and compares native readback across all 512 lines, 12 note columns and 8 effect
columns. It independently renders the same semantic plan with the existing
script renderer and applies the existing gate writer before comparison.
The matrix covers straight/triplet timing, sample capability false/true and
both output policies. Capability profiles test generated native cells; they
do not establish actual sampler, plugin or MIDI playback.

Injected failures after properties, early cells and late cells must restore
a detached pre-output snapshot exactly, including visible/hidden/tail sentinels,
column metadata and phrase settings. One representative transaction commits
and reads back a real source-store candidate, then restores both the phrase
and exact source bytes after a simulated post-commit failure. A false request
guard must reject source commit without changing raw bytes. Cleanup uses
created object identity and verifies original phrase ordering and source bytes.

The native matrix passed on Renoise 3.5.4 / API 6.2; see
[runtime_acceptance.md](runtime_acceptance.md) for the report and exact limits.
Receiver/PB branches, populated script/mapping restoration, actual host setter
failures, failed restoration, playback safety and acoustic equivalence remain
unverified. A passing matrix does not authorize production cutover by itself.

Test direct Song API undo variants separately:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase source-undo-feasibility
```

This records source-only, synchronous phrase/source and split-callback edits
using the two documented undo-description APIs. Inspect every reported state;
a missing undo state requires a real user-action follow-up and cannot count as
atomic undo success. The observed idle-driven run exposed no undo states. The
separate real Make Independent dialog-action run did expose one undo state,
but retained newer source bytes when the old phrase was restored. Neither test
establishes the final direct writer's undo behavior. Full logical undo remains
a cutover gate.
