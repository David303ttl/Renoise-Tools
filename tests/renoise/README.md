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

The output contains an extracted **com.david303ttl.ACID.xrnx** development tool
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

The packaging test compiles each generated `main.lua` with Lua 5.1 without
executing the Renoise bootstrap. If `lua` is not Lua 5.1, pass the interpreter
name with `-LuaCommand lua5.1`.

## Interactive runner

Use PowerShell 7 and Lua 5.1. Run the available Native test against a fresh Renoise
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

`-Install` allows temporary replacement of ACID and `-ApproveDisposableSong`
allows resetting the test song. The selected PID and listener owner are checked
before commands. Only the `transport` scenario is currently implemented. It checks
ping, capabilities, new-document completion and stable native inventory readback.
Snapshots compare values and selection positions, not Lua wrapper identities.
Keyboard tests are not implemented; use the default `Native` suite. Requesting
`Keyboard` or `All` reports the missing coverage with a nonzero result, without
blocking Native runs or ordinary tool use.

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
Native API tests do not require foreground focus; future keyboard tests must
focus their selected Renoise window while sending input.

`./scripts/test_host_preflight_live.ps1 -RenoiseExe '<path>'` checks executable
and temporary-directory readiness; add `-RenoiseProcessId <pid>` to check a target.
No host acceptance is inferred from offline mocks. Record actual native results
when those tests run, and keep unexecuted checks visibly pending.
