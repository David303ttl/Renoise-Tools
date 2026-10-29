# Renoise verification

Environment: Windows, PowerShell 7, Lua 5.1, Renoise 3.5.4, API 6.2.

| Check | Result |
| --- | --- |
| Offline preflight, transport and runner regressions | PASS |
| Fresh-launch Native smoke | PASS: handshake, document reset, stable inventory, driver shutdown and installation restoration |
| Selected-PID Native smoke with a concurrent instance | PASS: target startup resumed after deployment; both instances remained open; original installation restored |
| Reload of ACID already loaded in a selected instance | Not checked by the automated smoke |
| Release/development package separation | PASS |
| Keyboard tests | Not implemented |
| Playback, rendering, undo and persistence acceptance | Not covered by the transport smoke; use the ACID manual guides |

Snapshots contain native inventory values and selection indices. Indices describe
positions at readback time, not persistent object identity. Driver shutdown is
complete only after its per-run completion file is observed and removed.

Manual host checks cover clean new/save/load, dirty-song Cancel/Save/Discard,
tool reload and foreground activation. `save_song_as` can write a fixture without
delivering a saved-document notification; verify completion from native readback.
