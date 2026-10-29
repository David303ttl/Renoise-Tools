# Windows host verification

Verified on 2026-10-29 with Windows, PowerShell 7, Renoise 3.5.4 and API 6.2.
The accepted development workflow uses the current desktop, an explicitly
selected existing Renoise process, and a fresh disposable song. Dedicated-account
isolation is excluded from this acceptance scope.

| Check | Observed result |
| --- | --- |
| Live identity and desktop | SID, APPDATA/known folder/profile, WTS session, input desktop, process ownership, executable metadata and SHA-256 collected successfully. |
| Safety preflight | Passed on the selected current-session Renoise process. An absent selected PID was rejected. |
| New and load | Clean new/save/new/load sequence completed with release/new-document callbacks and the expected fixture filename. |
| Dirty new song | Cancel preserved the dirty fixture; Yes saved and continued; No discarded and continued. |
| Dirty fixture load | Cancel preserved the dirty fixture; Yes saved and loaded; No discarded and loaded the saved fixture. |
| Tool reload | Unload, finished-loading and new-document notifications observed. |
| Activation | Windows foreground ownership changed Renoise → another application → Renoise; Renoise activation callbacks were also recorded. |
| Evidence gate | Execution preflight passed using the captured traces, source hashes, selected process start time and current environment. |
| Existing ACID | Replacement remained unauthorized. No ACID runtime files were changed. |

The API `save_song_as` wrote the fixture but did not deliver a saved-document
notification to the requesting probe during this run. File → Save delivered the
notification and resumed the sequence. Completion must not be inferred from the
save request or a fixed delay.

Song userdata string conversion and equality are unsupported on this host. The
probe records document generations from lifecycle callbacks, not object addresses
or direct reference comparisons.

Local raw traces, source snapshots, evidence JSON and prompt/result screenshots
are retained in `tmp/host-spike/`. They include host-specific paths and are
intentionally untracked. Evidence applies to its recorded process/session and
source hashes; regenerate it after those change. This verifies host prerequisites,
not ACID playback or a general unattended runner.

Verification commands passed: `scripts/test_host_preflight.ps1` (36 checks),
`scripts/test_host_preflight_live.ps1` with the selected PID and captured evidence
(7 checks), `lua tests/renoise/spike_tool_spec.lua` (7 mocked checks), and
`scripts/run_tests.ps1` (50 existing Lua specs). PowerShell parsing and
`git diff --check` also passed. Renoise was left on a fresh song; the probe's
armed marker was removed and tools reloaded to stop observation logging.
