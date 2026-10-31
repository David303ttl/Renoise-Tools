# Renoise test host

## Development bundle

Build a disposable ACID bundle below the repository's ignored `tmp/` directory:

~~~powershell
$runDirectory = Join-Path 'tmp' ("acid-dev-" + [guid]::NewGuid().ToString("N"))
pwsh -NoProfile -File ./scripts/package_dev.ps1 -Tool ACID -OutputDirectory $runDirectory
~~~

`OutputDirectory` is repository-relative. Build staging, the session file and
the output bundle stay under `tmp/`; `.gitignore` excludes that directory.
The packaging test exercises a non-ASCII repository path. Renoise's Lua file
APIs use UTF-8 paths; the bootstrap passes `bundle_path` through unchanged and
adds only ASCII relative path components.

The output contains an extracted **com.david303ttl.ACID.xrnx** development tool,
a sibling **fixtures/** directory staged from `tests/renoise/acid/fixtures/`,
and **acid-test-session.conf**. The tool is derived from the normal release
archive, with a test-only transport/JSON codec and a bootstrap appended to its
staged **main.lua**; production source files and the manifest stay unchanged.
The bootstrap resolves the sidecar next to the bundle at runtime and contains
no absolute desktop path. The session file contains only the loopback address,
port and random per-run test secrets; it stores no username or operating
system session identifier. Its ACL is limited to the current Windows user.
Keep the output directory at its generated path while using the bundle because
the staged bootstrap locates that sidecar relative to the bundle. This command
does not install the tool or modify Renoise.

The driver binds only to **127.0.0.1**, authenticates one client with the
per-run token, and processes bounded commands from `app_idle_observable`.
Requests and responses are newline-delimited JSON. It accepts only the fixed
command allowlist in the playbook; fixture loading accepts a filename directly
under the bundle's sibling `fixtures/` or `temp/` directory. It has no Lua
execution, generic module dispatch or arbitrary path command. Request IDs are
unique for one connection, and document commands complete only after a new
document notification. Idle processing uses bounded work counts. Timeout values
round up to whole seconds because the driver uses `os.time()`; expiration is
checked after the deadline boundary so it cannot fire early, and host load can
delay reporting. A song snapshot is capped at 512 phrases and the response size
is bounded.

Offline transport tests use mocked SocketServer and document observables.
Native results are listed in [host_verification.md](host_verification.md).
Run the deterministic packaging and transport checks with:

~~~powershell
pwsh -NoProfile -File ./tests/renoise/test_package_dev.ps1
lua ./tests/renoise/remote_driver_spec.lua
~~~

The packaging test compiles each generated `main.lua` with the selected
interpreter without executing the Renoise bootstrap. Lua 5.1 or newer and
LuaJIT 2.x are accepted through `_VERSION`. It defaults to `lua` from `PATH`;
use `-LuaCommand lua5.4` (or an executable path) to override it. Syntax checks
with newer Lua versions do not establish Lua 5.1 runtime compatibility.
Run `./scripts/run_tests.ps1 -LuaCommand lua5.1`
to check the production language baseline.

## Interactive runner

Use PowerShell 7 and Lua 5.1 or newer. Run the available Native test against a fresh Renoise
process, or select an existing instance with a disposable song:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong
./scripts/run_interactive_tests.ps1 -RenoiseProcessId <pid> -Install -ApproveDisposableSong
```

Other instances and virtual desktops can stay in use. No dedicated account,
active-desktop check, profile registry match, screenshots or trace evidence is
required. Install release XRNX tools normally in Renoise; they have no test-harness dependencies.

The runner discovers Renoise, or accepts `-RenoiseExe '<path>'`. The default tool
location is the current user's version-specific Renoise Tools folder; override it
with `-ToolsDirectory '<path>'` for a custom installation. Missing folders are
created during installation. Linked parent folders are supported. Replacement
requires a verifiable backup; links inside the tool being backed up are rejected
because the backup does not copy their external contents.

### Ownership acceptance

Run the native rejection, user-action undo and cold-process checks separately:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase ownership-negatives
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase independence-undo -TestEnvironment '<path>' -AllowKeyboardFocusActivation
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase make-independent -ColdProcessRoundTrip
```

- Undo: guarded Enter to the verified PID; real dialog callback, native undo/redo,
  reopened collision fixture with empty history, all operation states through
  undo/redo exhaustion, blocked invalid regeneration and no source repair.
  Logical grouping is reported separately from safe blocking.
- Cold reopen: save → fresh process → exact-target regeneration → save → another
  fresh process; compare complete pre-save baselines (IDs, source/settings,
  phrase snapshots and raw persisted bytes) across both restarts, including
  the foreign sentinel. The route uses runtime restoration and the native writer;
  the production GUI journey remains required under Gate 8.
- Import: native donor instrument export → separate recipient song → native
  import; exact donor phrase preservation, missing source, regeneration and
  Make Independent refusal, and unchanged unrelated recipient records.
- Isolation: runner-owned processes only; `-RenoiseProcessId` is rejected for cold
  restarts. Temporary fixtures/session files and verified installation restoration.

Result classes are consistent across scenario and run reports: `PASS` means
every requested postcondition was independently observed; `FAIL` means an
assertion found a contract violation; `ERROR` means a runner, host or transport
operation failed; `SKIP` is reserved for unavailable optional coverage; and
`MANUAL` marks a check without an automated assertion. A selected suite cannot
pass when a required case is skipped or lacks an assertion. Manual observations
are recorded separately and do not count as automated passes.

`-Install` allows temporary replacement of ACID and `-ApproveDisposableSong`
allows resetting the test song. The selected PID and listener owner are checked
before commands. The transport scenario always runs first and checks ping,
capabilities, new-document completion and stable native inventory readback.
### Keyboard E2E

The `Keyboard` and `All` suites also need AutoHotkey v2. Get it from the
[official AutoHotkey releases](https://github.com/AutoHotkey/AutoHotkey/releases).
The runner finds `AutoHotkey64.exe` or `AutoHotkey.exe` on `PATH`; configure
`Keyboard.AutoHotkeyPath` in the developer's TestEnvironment file if it is
installed elsewhere.

After ACID loads, Renoise lists its real `Global:ACID:Show` command under Edit >
Preferences > Keys. The current developer keymap assigns **Ctrl+Alt+B**; enter
the same key as `^!b` in the AutoHotkey v2 key-sequence configuration. Renoise
stores assignments per user, and ACID supplies no default. For example:

~~~json
{
  "RenoiseExe": "<path to Renoise.exe>",
  "Keyboard": {
    "ShowShortcut": "^!b",
    "AutoHotkeyPath": "<optional path to AutoHotkey64.exe>",
    "TimeoutSeconds": 10
  }
}
~~~

`^!b` matches the current developer keymap. Change `ShowShortcut` if you assign
a different key combination in Renoise.

Pass the external configuration file when selecting the Keyboard suite:

~~~powershell
# Dedicated interactive Windows test session only (may activate Renoise)
./scripts/run_interactive_tests.ps1 -Suite Keyboard -TestEnvironment '<path>' -Install -ApproveDisposableSong -AllowKeyboardFocusActivation
./scripts/run_interactive_tests.ps1 -Suite All -TestEnvironment '<path>' -Install -ApproveDisposableSong -AllowKeyboardFocusActivation
# Shared work desktop: no activation; requires an existing, loaded Renoise PID in foreground
./scripts/run_interactive_tests.ps1 -Suite Keyboard -RenoiseProcessId <pid> -TestEnvironment '<path>' -Install -ApproveDisposableSong
~~~

Each sequence validates the selected Renoise PID. On a shared desktop, the helper never activates another window: if Renoise is not already foreground, it refuses input. The runner also requires an explicit existing `-RenoiseProcessId` in this mode to avoid a focus-stealing application launch. `-AllowKeyboardFocusActivation` explicitly permits activation and is intended only for a separate interactive Windows test session. A global Renoise shortcut cannot be reliably tested through real keyboard input in the background of the same Windows desktop. Native tests remain focus-free.
The runner does not change keyboard preferences. It waits for the ACID dialog's
API-visible state, closes the dialog with Escape, then uses Renoise's native
Alt+Down/Alt+Up instrument navigation documented in the
[Instrument Selector manual](https://tutorials.renoise.com/wiki/Instrument_Selector)
and verifies the selected instrument index through `song.snapshot`.
The development driver inserts a second blank instrument in the disposable song
only when needed to make that navigation observable.

Keyboard preflight checks missing mapping configuration, the helper's wrong-PID
and focus-mismatch guards, and its bounded observed-state timeout. Native remains
independently selectable and does not require AutoHotkey or a keyboard mapping.
Reports include the shortcut, AHK version, negative-case results, observed dialog
state and instrument readback. The unattended Renoise 3.5.4 / API 6.2 host run
passed on 2026-10-30; see the
[keyboard verification record](host_verification.md#keyboard-e2e-host-acceptance-2026-10-30).
Offline checks alone do not establish host acceptance.

The checked-in native fixture is built independently of the production writer:

```powershell
./tests/renoise/acid/build_fixture.ps1 -ApproveInstall -Force
lua tests/renoise/acid/probe_spec.lua
```

The builder launches its own disposable Renoise instance and temporarily installs
its fixture probe under ACID's tool ID so the saved `tool_data` belongs to ACID.
It verifies the existing installation backup and restores it after closing that
instance. Close Renoise before rebuilding the fixture; ordinary Native runner
runs support concurrent instances. Fixture construction uses explicit native
field values, and scenario expectations come from independent golden values.

### Native scenario catalog

Native fixture scenarios are JSON files in `tests/renoise/acid/scenarios/`.
The catalog is required for an interactive run; a missing directory fails
before any document is changed. Each file is one scenario:

~~~json
{
  "name": "independent-phrase",
  "fixture": "independent-phrase.xrns",
  "description": "Optional operator-facing summary",
  "preconditions": {"instrument_count": 1, "phrase_count": 1},
  "actions": ["document.new", "fixture.load", "song.snapshot", "song.snapshot"],
  "waits": ["document.changed", "inventory.settled", "snapshot.stable"],
  "unchanged": ["instruments", "tool_data_hex", "selected_instrument_index"],
  "expects": "pass",
  "assertions": [
    {"path": "instrument_count", "expected": 1},
    {"path": "instruments.0.phrases.0.name", "expected": "Phrase"}
  ]
}
~~~

`name` matches `^[a-z][a-z0-9-]{0,63}$` and must be unique. `fixture` must be a
flat `*.xrns` file name staged in the development bundle's `fixtures/`
directory. Optional `description` is a string. Required `preconditions` is an
object containing only `instrument_count` and `phrase_count`, each a
non-negative integer when present; when a count is omitted, the runner reads it
from the loaded fixture before waiting for the matching native inventory.
Optional `expects` is `pass` (the default) or `fail`. When
`expects` is `fail`, a non-empty `expected_diffs` array is required and
forbidden otherwise; each item has exactly `path`, `expected` and `actual`.
`assertions` is a non-empty array of `{path, expected}` objects. Required
`actions` and `waits` declare the fixed read-only workflow shown above; the
runner rejects other sequences. Required `unchanged` lists snapshot paths that
must exist and retain exactly the same values across both readbacks. The whole
snapshot is also compared, so unspecified fields cannot silently change. The
expected musical, selection, identity and source changes for this workflow are
none; reset/load are the only authorized document changes.

`path` walks the song snapshot with zero-based indices for arrays, for example
`instruments.0.phrases.1.lines.0.note_columns.0.note_value`. Unknown top-level
keys, malformed preconditions and malformed diffs are rejected. The catalog
sets `source_path` on each loaded scenario.

Run just the transport checks with `-Scenario transport`, transport plus one
catalog scenario with `-Scenario <name>`, or leave `-Scenario` empty to run
transport plus every catalog scenario in sorted name order. Unknown names fail
with the available scenario names. The transport-only run skips native catalog
validation and builds/deploys the driver without native fixtures. The default
suite is `Native`.

The staged fixtures directory is deployed beside the tool as
`<Tools>/fixtures`. If that path already exists, it is first copied to a
hash-verified run artifact and moved to a same-volume restore location, using
the same verified backup/restore flow as the tool directory. Restoration removes
the deployed fixtures only when their directory hash still matches the staged
hash, then restores any moved-aside original. Each scenario resets the document,
loads its fixture, and resumes after the native inventory matches on two
consecutive application-idle callbacks. The wait response records the number of
matching idle callbacks and whether settlement was observed. Its two
canonical snapshot JSON files are written under
`tmp/interactive-<run-id>/scenario-<name>/`; order acceptance writes phase-prefixed
scenario directories. The run report records epochs,
snapshot SHA-256 values and any diff.

A scenario passes only when the document was settled before and after the run,
two consecutive snapshots are identical, and the freshly loaded fixture plus
read-only inspection created no undo/redo history, did not change the selection,
and left pending and queued command counts at zero. Snapshot comparisons are
canonical value comparisons with stable key ordering and explicit `null`
handling. They make no persistent host-object-identity claims; identity-sensitive
writer checks belong to later playbook steps. This fixture contains deliberately
foreign phrases and a separate canonical source/draft store; it verifies exact
ID/source/settings bytes without claiming that either phrase is owned or safe
to regenerate. After all scenarios the runner
performs a final document reset and diagnostics settle check so the host is left
on a clean document.

Run the scenario-order acceptance check with
`./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -VerifyScenarioOrder`.
It captures each catalog scenario individually in sorted order, then executes
the catalog in reverse order in the same Renoise process and driver session. It
compares canonical snapshot values by scenario after removing only the top-level
`document_epoch`; all other snapshot fields must match. The report and separate
scenario artifact directories record each run and the driver's post-load idle
settlement observation. At least two distinct catalog scenarios are required;
a smaller catalog fails before any document is changed. This check requires a
disposable song, like other interactive runs.

The `shutdown` response confirms acceptance. The driver then stops its listener,
detaches callbacks and writes a per-run completion file beside the session config.
The runner verifies and removes that file before restoring unchanged installation files. An existing
Renoise instance stays open; reload ACID to load the restored release code. A
runner-launched instance is closed after testing. If a song prompt appears,
resolve it in Renoise. Timeouts and failed assertions return nonzero. On connection
loss, backups are retained if driver shutdown cannot be confirmed. Changed files
are preserved for manual recovery. Reports and backups are under ignored `tmp/`;
reports omit session tokens.

Run offline harness checks without Renoise:

```powershell
./scripts/test_host_preflight.ps1
./tests/renoise/runner_spec.ps1
./tests/renoise/test_package_dev.ps1
lua tests/renoise/remote_driver_spec.lua
```

## Coverage handoff

Owners and A–E contracts refer to the
[runtime playbook](../../com.david303ttl.ACID.xrnx/M4_7_RUNTIME_REFACTOR_PLAYBOOK.md#step-8--native-renoise-acceptance).
The table separates recorded harness acceptance from behavior acceptance. `PASS`
below cites existing results, not a new execution. `PENDING` means the owning
runtime gate and its native acceptance remain open; it does not block unrelated
runtime work. Methods on pending rows are the required verification method.
Native assertions must inspect host state independently of ACID's success result.
Mocks can establish local contracts but cannot close these native rows.

| Case / test or guide | Owning step | Step 8 | Method | Independent assertion | Current status |
| --- | --- | --- | --- | --- | --- |
| Harness reset, read-only fixture inventory, repeat and deliberate assertion failure: `-Suite Native`, `phrase-inventory`, `phrase-inventory-expected-diff` | T0; handoff to 2.2–2.3 / 2.9 | A, D foundation only | Native | New document epoch; exact golden native fields and store bytes; two stable snapshots; unchanged selection; no undo/redo history; wrong note expectation returns FAIL/nonzero; subsequent clean run passes | PASS recorded in [harness verification](host_verification.md#t07-harness-integration-and-native-e2e-2026-10-30); no owned-target or writer claim |
| Fixture isolation/order: `-VerifyScenarioOrder` | T0; handoff to 2.2–2.3 | A foundation only | Native | Individually loaded and reverse-order snapshots match after removing only document epoch; each load observes two matching idle cycles | PASS rerun in [handoff verification](host_verification.md#t08-coverage-handoff-and-closeout-2026-10-30) |
| Real Show shortcut, Escape and native instrument navigation: `-Suite Keyboard` | T0; handoff to 2.6 / 2.8 | A routing foundation only | Keyboard + Native | API-visible dialog opens/closes; native selected instrument changes 1 → 2; wrong PID/focus/configuration/timeout guards reject | PASS before activation-policy hardening; post-hardening host rerun PENDING, as recorded in [keyboard verification](host_verification.md#keyboard-e2e-host-acceptance-2026-10-30) |
| Document/session lifetime, release/reload and late delivery | 2.2, 2.9; writer disposal in 3; observers in 6 | A, C | Native + Keyboard | Close/reopen and new/reloaded document cannot receive old delivery; no old-song callback accesses or leaked listeners; only exact safe recovery objects remain | Local `tests/acid/acid_runtime_lifetime_spec.lua` passes document/session isolation and retained-closure scrubbing; production GUI integration and native acceptance PENDING; harness epochs do not prove session isolation |
| Live inventory, classification, raw identity and preserved baselines | 2.3, 2.9 | A, C | Native + Keyboard | Add/rename/remove/reorder and same-index replacement preserve exact target identity; identical-content phrases remain distinct; Foreign/Unavailable never becomes New; no navigation writes | PENDING; current foreign-fixture readback proves values only |
| Mutation scope, temporary neutrality and no ownership exclusions | 2.4; real writer integration in 3 | A, C, D | Native | Stage/backup names contain no owner ID across async waits; all live holders count toward collisions; own notifications do not bind temporary objects or mask external changes | PENDING; fake-writer tests cannot prove native notification ordering |
| Song blockers, global occupancy and explicit read-only revalidation | 2.5; writer terminal in 3; UI in 5 | C, D | Native + Keyboard | Pending render denies writes across songs; only its terminal callback retires occupancy; completed recovery remains blocked until an unchanged successful read-only proof; no repair writes or automatic retry | PENDING; missing/duplicate callbacks remain local injection cases unless observed natively |
| Transitions, frozen request guards and GUI authority | 2.6–2.8; closeout in 2.9 | A, B, C | Native + Keyboard | Opening/navigation/arming/reset/recovery make no request; native selection, changed baselines, removed targets and old sessions prevent stale commit or append; both manual and Live Edit use exact intended target | PENDING; Show/navigation foundation does not prove admission safety |
| Create/regenerate, capacity, rollback, preservation and undo/redo | 3 | B, C, D | Native + Manual | Create adds one actual destination; regenerate retains exact object/count; insufficient slots mutate nothing; failures restore destination/store or retain named blocked recovery; sentinel metadata/mapping/script survive; each reachable native undo/redo state is consistent or visibly blocked | PENDING; native undo/redo execution and grouping unverified; fixture no-history checks are not writer undo acceptance |
| Explicit Make Independent for native copies | 4 | C, D | Native + Keyboard | Same-/cross-instrument and mixed-instrument copies block all colliding holders; selected valid holder alone gets new ID/source; note/effect bytes and original association stay unchanged; 3-holder and source-less cases reject/admit as specified; undo/redo and save/reload remain safe | PENDING; no automatic adoption or copy-resolution pass claimed |
| Drafts, scheduling, recovery and save/reload: [regeneration](../acid/acid_regeneration_manual.md), [Live Edit](../acid/acid_live_edit_manual.md) | 5 | B, C, D | Native + Keyboard + Manual | Dirty A survives B/close/reopen/save/reload with its own settings; occupied scratch/recovery remains recoverable without rendering; only matching committed revision clears; requests never overlap or drain after blocked/stale completion | PENDING; actual runtime save/reload and durable/session draft acceptance unverified |
| Notifications, undo invalidation and late callbacks | 6 | A, C, D | Native + Keyboard | Internal mutations reconcile once without self-cancellation; external changes revoke authorization; native undo cannot silently adopt mismatched source/output; repeated opens/documents leave no duplicate listeners or old callbacks | PENDING; driver notifier cleanup does not establish runtime watcher safety |
| Supported musical output: [gate](../acid/acid_gate_manual.md), [timing](../acid/acid_timing_manual.md), [slide](../acid/acid_slide_manual.md), [articulation](../acid/acid_articulation_manual.md) | 3 / 5; final acceptance in 8 | E | Native + Manual | Independently inspect final pitch/gate/accent/slide cells and timing/loop metadata; listen on supported sampler/VST paths and record observed playback separately | MANUAL / PENDING current-writer acceptance; harness and synthetic cells do not establish audible behavior |

Steps 2.9 and 7 must map their local regressions to actual test cases/results;
the handoff does not pre-author future scenario fixtures or replace those gates.
Step 8 stays open until applicable A–E native, keyboard and manual checks pass,
including final-writer sentinel-field round trips, real undo/redo and save/reload.
Unsupported-field preflight rejection must be recorded as rejection, not a
preservation pass. Add each behavior's scenarios with its owning implementation;
the read-only harness catalog deliberately contains no simulated future writer.

## Pinned API 6.2 contract

These signatures come from `sdk/renoise-api-6.2/definitions/` and the matching
offline API pages and guides. They describe the scripting surface; observed host
results are recorded in [host_verification.md](host_verification.md).

| API | Signature and lifecycle constraints | Workaround supported by 6.2 docs |
| --- | --- | --- |
| Socket server creation | `renoise.Socket.create_server(server_address: string, server_port: integer, protocol?: renoise.Socket.Protocol) -> SocketServer?, error?`; an overload omits the address. Failures return a nil server and optional error. | Bind explicitly to `127.0.0.1`; do not use the no-address overload, which accepts connections on any address. |
| Server callbacks | `SocketServer:run(notifier_table_or_class)` starts server callbacks; optional callbacks are `socket_error(error_message)`, TCP `socket_accepted(client)`, and `socket_message(client, message)`. The SDK explicitly places socket errors on a server background thread; it does not specify callback thread affinity for accepted/message events. `SocketServer:stop()` stops a running server. | Treat every callback as asynchronous to the GUI path: authenticate, frame, validate and enqueue only. Process Renoise APIs from bounded idle work. `SocketServer:wait(timeout)` blocks the calling thread and the docs say it should be avoided when possible. |
| Tool idle | `renoise.tool().app_idle_observable: Observable`; periodically called, around ten times per second, but the interval is undefined and varies with host load. | Use it for bounded, nonblocking work; never use elapsed idle intervals as proof that a host operation settled. |
| Document lifecycle | `app_release_document_observable` fires before the old song closes and also just before application exit. `app_new_document_observable` fires after a document is created/loaded and `renoise.song()` changes; it also fires when a tool script is reloaded by auto-reload. `tool_will_unload_observable` fires before tool disable/reload and application exit. | Attach song-specific observers on new-document and release them before the old document closes. Keep stable notifier references for removal and unload cleanup. |
| New document | `renoise.app():new_song_no_template()` takes no arguments and is asynchronous: the new song appears soon after the call if the user does not abort. | Continue from `app_new_document_observable`, not immediately after the call. |
| Load song | `renoise.app():load_song(filename: string)` asks to save changes when needed, reports errors to the user, and does not load immediately. | Await the new-document observable. The docs do not specify prompt automation or a completion timeout. |
| Save song as | `renoise.app():save_song_as(filename: string)` takes a filename and saves the current song under that name; errors are shown to the user. | No synchronous completion result is documented. Observe save/document state rather than treating invocation as proof of completion. |
| Saved-document notification | `renoise.tool().app_saved_document_observable: Observable` fires after each successful document save; `renoise.song().file_name` points to the saved filename. | Use this as the documented success observation; no timing guarantee is stated. |
| Undo / redo | `renoise.song():undo()` and `:redo()` take no arguments and do nothing if unavailable; `:can_undo()` / `:can_redo()` report availability. `:is_undo_redoing()` is true while an undo/redo action is invoked. | Use `is_undo_redoing()` only to identify processing in observers; it does not promise cross-callback atomicity. |
| Key binding | `renoise.tool():add_keybinding(keybinding: ToolKeybindingEntry)` registers a binding. Entries provide a `name` and `invoke(repeated: boolean)` callback. | Check `has_keybinding(name)` before registration if duplicate registration is possible; remove with `remove_keybinding(name)`. Renoise has no API for a default shortcut: users must map the binding manually in Keyboard Preferences. |

The offline application guide states that loading and saving are not always
instantaneous because prompts may be shown. It does not establish dirty-song
prompt handling, asynchronous reload behavior, or reliable window activation.
Unknown modal dialogs must fail closed; do not patch `renoise.app()` or infer success from a
request return or fixed delay.

## Optional host diagnostics

The standalone `spike_tool/`, `Capture-Foreground.ps1` and
`build_spike_evidence.ps1` are diagnostic aids for investigating Renoise lifecycle
and keyboard behavior. Their historical observations are in
[host_verification.md](host_verification.md). They are not setup requirements or
permission gates for running tests, developing tools, or installing releases.
Native API tests do not require foreground focus. Nonintrusive Keyboard tests
require an existing selected PID that already owns foreground focus. Activation
requires `-AllowKeyboardFocusActivation` in a dedicated interactive session;
both modes verify focus before sending each input sequence.

`./scripts/test_host_preflight_live.ps1 -RenoiseExe '<path>'` checks executable
and temporary-directory readiness; add `-RenoiseProcessId <pid>` to check a target.
No host acceptance is inferred from offline mocks. Record actual native results
when those tests run, and keep unexecuted checks visibly pending.

### Exceptional writer recovery

Run all four exceptional admission/recovery regressions on real native phrases:

```powershell
./scripts/run_interactive_tests.ps1 -Install -ApproveDisposableSong -AcceptanceCase writer-recovery -StartupTimeoutSeconds 120 -CommandTimeoutSeconds 90
```

The fixed case checks post-commit identity/source preservation, contradictory
success with a captured draft, retryable blocker clearance and exceptional facade
getters. It uses injected failures in the disposable host and restores its hooks.
See the [verification record](host_verification.md#exceptional-writer-recovery-verification-2026-10-31)
for actual results and the separate manual playback/undo acceptance limit.
