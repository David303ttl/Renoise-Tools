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
archive, with a test-only driver and a bootstrap appended to its staged
**main.lua**; production source files and the manifest stay unchanged. The
bootstrap resolves the sidecar next to the bundle at runtime and contains no
absolute desktop path. The session file contains only the loopback address,
port and random per-run test secrets; it stores no username or operating
system session identifier. Its ACL is limited to the current Windows user.
Keep the output directory at its generated path while using the bundle because
the staged bootstrap locates that sidecar relative to the bundle. This command
does not install the tool or modify Renoise.

The driver currently validates the session and binds only to **127.0.0.1**;
it closes client connections until the constrained protocol is implemented.
Run the deterministic packaging and admission checks with:

~~~powershell
pwsh -NoProfile -File ./tests/renoise/test_package_dev.ps1
lua ./tests/renoise/remote_driver_spec.lua
~~~

The packaging test compiles each generated `main.lua` with Lua 5.1 without
executing the Renoise bootstrap. If `lua` is not Lua 5.1, pass the interpreter
name with `-LuaCommand lua5.1`.

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

## Host preflight and behavior spike

Development tests use the current Windows desktop and an explicitly selected Renoise
process, or a process started by the future runner. No dedicated account, VM, profile
marker, fixed installation path or administrator provisioning is required. Start
with a disposable song, not an unsaved working project. Local evidence records
host observations; it is not a permission to modify tools or songs.

`host_preflight.psm1` exports `Test-RenoiseHostPreflight`. It reads the current
Windows identity, session, desktop, APPDATA, executable metadata, and Renoise
process itself. Callers select the Renoise PID explicitly; preflight verifies its
executable, owner, session, start time, and profile paths. It never launches,
attaches to, or terminates Renoise. Execution mode requires a local evidence JSON
whose raw trace and source hashes match the current environment and selected PID.
The evidence stores observations and context, not caller-supplied verification
booleans. `Safety` performs non-destructive checks; `Execution` validates local
host evidence. Neither mode implicitly authorizes installing/replacing ACID,
changing a developer's working song, or terminating an existing Renoise process.

The standalone probe in `spike_tool/` has no ACID runtime dependency and is a
manual diagnostic, not an automated E2E suite. Copy its
contents into a separate tool directory named
`com.david303ttl.RenoiseTestHostSpike.xrnx` beneath the current profile's
`Scripts\Tools`. Invoke **Tools → Renoise Test Host Spike → Initialize log and
create fresh test song** once. This replaces the old raw trace, requests a new
song, saves that disposable song to a unique fixture, then asynchronously creates
another new song and loads the fixture. It logs Renoise lifecycle callbacks at
each step. After this automatic sequence, reload the test tool from Renoise's
Scripting Editor once to record `tool_will_unload` and `tool_finished_loading`.
On Renoise 3.5.4, the API save wrote the fixture without delivering the saved
notification to the requesting probe. Use **File → Save** if it remains waiting
after the fixture is saved; the observed notification resumes the sequence.
If the initial new-song request presents Renoise's save prompt, choose
the intended Save, Discard, or Cancel action in Renoise; the probe will not choose
for you.

For dirty-document observations, use **Mark current fixture dirty (tempo +1 BPM)**
and invoke the dirty
new-song or fixture-load menu action. Resolve the prompt in Renoise, then choose
the matching **Record dirty prompt** item. Repeat as needed for Cancel, Save, and
Discard for both new-song and fixture-load operations. The menu record is an
operator observation, so retain a screenshot of each prompt and resulting
document state with the raw trace.

For window activation, start the foreground observer for the Renoise PID selected
by preflight, alt-tab to another window and back, then retain its output:

```powershell
pwsh -NoProfile -File ./tests/renoise/Capture-Foreground.ps1 `
  -RenoiseProcessId <renoise-pid> `
  -OutputPath <evidence-directory>\foreground.jsonl `
  -DurationSeconds 120
```

The observer checks that the process belongs to the current user and session. It
records foreground transitions and executable identity, and does not activate or
control Renoise.

Build the local evidence JSON from the selected PID, raw traces, and probe sources
after the host checks are complete:

First copy `main.lua`, `manifest.xml`, and `spike-observations.jsonl` from the
installed probe into an evidence directory. Use that snapshot as `ApiTracePath`;
the running probe continues appending activation events to its original trace.
Keep screenshots beside the snapshot. These artifacts belong under ignored
`tmp/`, not in the repository history.

```powershell
pwsh -NoProfile -File ./tests/renoise/build_spike_evidence.ps1 `
  -RenoiseProcessId <renoise-pid> `
  -ApiTracePath '<spike tool folder>\spike-observations.jsonl' `
  -ForegroundTracePath '<evidence directory>\foreground.jsonl' `
  -OutputPath '<evidence directory>\behavior-evidence.json'
```

Safety preflight can run before collecting behavior. Execution preflight reads
the evidence JSON and validates its environment, process, hashes, and raw flow
events:

```powershell
Import-Module ./tests/renoise/host_preflight.psm1 -Force
Test-RenoiseHostPreflight -Mode Safety -Configuration ([pscustomobject]@{
  RenoiseExe = '<Renoise.exe path>'
  RenoiseProcessId = <renoise-pid>
  TemporaryDirectory = $env:TEMP
})
Test-RenoiseHostPreflight -Configuration ([pscustomobject]@{
  RenoiseExe = '<Renoise.exe path>'
  RenoiseProcessId = <renoise-pid>
  TemporaryDirectory = $env:TEMP
  BehaviorEvidencePath = '<evidence directory>\behavior-evidence.json'
})
```

The tool logs `requested` actions separately from observed callbacks. A request
return does not establish completion. Missing events, unexpected document
transitions, or unknown modal dialogs fail closed. API 6.2 documents callback
lifecycle but does not establish prompt or foreground behavior; those require
observations from the running Renoise UI.

Run synthetic fail-closed checks (no Renoise host required):

```powershell
pwsh -NoProfile -File ./scripts/test_host_preflight.ps1
```

These checks use synthetic contexts and temporary junctions; they do not establish
native Renoise behavior or constitute a native smoke test. A real-host spike is
established only when the raw observations and current environment evidence have
been collected from Renoise.

Run the separate Windows integration checks against the selected process:

```powershell
./scripts/test_host_preflight_live.ps1 -RenoiseExe '<Renoise.exe path>' `
  -RenoiseProcessId <renoise-pid> -RequireSafetyPass `
  -BehaviorEvidencePath '<evidence directory>\behavior-evidence.json'
lua tests/renoise/spike_tool_spec.lua
```

`InstallReplacementAuthorized` is a preflight compatibility result, not consent
to install. A runner must obtain explicit developer approval before changing an
existing ACID installation and preserve any existing files for restoration.
An existing ACID installation that differs from the repository bundle cannot
be replaced by the current preflight. A selected existing Renoise process must
never be killed by the runner. The standalone spike does not modify ACID.
