# Renoise test host

## Pinned API 6.2 contract

These signatures come from `sdk/renoise-api-6.2/definitions/` and the matching
offline API pages and guides. They describe the scripting surface; host-specific
prompt and window behavior has not been demonstrated by this repository work.

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
Those behaviors remain unverified until an isolated Renoise spike. Unknown modal
dialogs must fail closed; do not patch `renoise.app()` or infer success from a
request return or fixed delay.

## Isolated host preflight

`host_preflight.psm1` exports `Test-RenoiseHostPreflight`; callers cannot supply
or replace its live Windows context. It requires explicit configuration for the
dedicated Windows user SID and session ID, a profile marker and expected contents,
Renoise executable, APPDATA, Renoise Tools path, ACID installation target,
writable temporary directory, and three true behavior attestations:
`DirtyDocumentFlowVerified`, `AsyncDocumentLifecycleVerified`, and
`WindowActivationVerified`. APPDATA must match both the process environment and
Windows' ApplicationData known folder.
It checks current identity and APPDATA, a WTS-active non-session-0 desktop with
visible `WinSta0` and an accessible input desktop matching the calling thread's
desktop, Renoise executable metadata/version,
`APPDATA\Renoise\V3.x.x\Scripts\Tools`, exact ACID target, the marker, and the
absence of any Renoise process. A failed safety check returns before the temporary
write probe. The probe is removed immediately.

Dirty-document prompts, async new/load/reload lifecycle, and window activation
remain unverified here. These booleans are out-of-band operator attestations until
an isolated runner/UI spike exists; this implementation neither automates nor
detects dialogs. Leave each attestation false or unset until its behavior has
been confirmed in the isolated host; preflight rejects false or missing evidence.
The future runner must detect known prompts with supported UI automation and fail
closed on an unknown modal dialog.

Preflight never installs, starts, attaches to, or terminates Renoise. In
particular, process ownership is not inferred from an existing process. Any
future process-owning runner must retain the PID, executable path, and start time
from its own successful `Start-Process -PassThru` call and may dispose only that
positively identified process; redirected launch into another instance is an
abort condition.

Run synthetic fail-closed checks (no Renoise host required):

```powershell
pwsh -NoProfile -File ./scripts/test_host_preflight.ps1
```

These checks use synthetic contexts and temporary junctions; they do not establish
native Renoise behavior or constitute a native smoke test.
