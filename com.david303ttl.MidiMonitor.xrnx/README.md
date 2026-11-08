# MIDI Monitor

Renoise 3.5 / API 6.2 raw MIDI and SysEx monitor. Open **Tools > MIDI Monitor...**,
select an RX input, optionally select a TX output, then **Connect**.

- Logs timestamp, direction, message type, channel, byte count and raw hex.
- **Thru** forwards incoming messages to the selected output; disabled by default.
- **Send hex** sends one MIDI or complete SysEx message, for example `F0 7D 20 F7`.
- MIDI clock is hidden by default; its messages still count and forward with Thru.
- **Save log** exports the last 500 retained messages. **Clear** resets the log and counters.
- Capture continues while Renoise is in the background and after closing the window.
  **Disconnect** stops capture and releases ports. Reopening the window disconnects
  before refreshing the available ports.

TX contains messages sent or forwarded by this monitor. The Renoise scripting API
does not expose other tools' or instruments' outgoing MIDI. To inspect that output,
route it into a virtual MIDI port, select that port as RX, select the hardware port
as TX, and enable Thru. Avoid routing the forwarded output back to the same RX port.

```powershell
./scripts/run_tests.ps1 -Tool MidiMonitor -LuaCommand lua5.1
./scripts/package.ps1 -Tool MidiMonitor
```

Install the generated `dist/com.david303ttl.MidiMonitor_0.1.xrnx` in Renoise.

GPL-3.0-only; see LICENSE.
