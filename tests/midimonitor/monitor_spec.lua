assert(dofile("tests/bootstrap.lua")("midimonitor"))
local Monitor = require("monitor")
local callback, sysex_callback, output, input, fail_send
renoise = {Midi = {
  create_input_device = function(name, midi, sysex)
    assert(name == "Input")
    callback, sysex_callback = midi, sysex
    input = {is_open = true, close = function(self) self.is_open = false end}
    return input
  end,
  create_output_device = function(name)
    if name == "Missing" then error("unavailable") end
    output = {is_open = true, sent = {},
      close = function(self) self.is_open = false end,
      send = function(self, message)
        if fail_send then error("driver failed") end
        self.sent[#self.sent + 1] = message
      end}
    return output
  end
}}

for _, valid in ipairs({"90 3C 7F", "C0 01", "F0 7D 20 F7", "F8", "F2 00 01"}) do
  assert(Monitor.parse(valid), valid)
end
for _, invalid in ipairs({"", "GG", "90 3C", "90 3C FF", "C0 01 02", "3C 7F",
  "F0 7D 20", "F0 80 F7", "F8 F8", "F7", "F9", "0x90 3C 7F"}) do
  assert(not Monitor.parse(invalid), invalid)
end

local monitor = Monitor.new()
assert(monitor:open("Input", "Output"))
callback({0x90, 60, 100})
assert(monitor.rx == 1 and monitor.tx == 0 and #output.sent == 0,
  "capture must not forward by default")
assert(monitor:text():match("RX.*Note on ch 1.*90 3C 64"))
sysex_callback({0xF0, 0x7D, 0x20, 0xF7})
assert(monitor:text():match("RX.*SysEx.*F0 7D 20 F7"))

monitor.thru = true
callback({0x91, 61, 0})
assert(monitor.rx == 3 and monitor.tx == 1 and #output.sent == 1)
assert(monitor:text():match("TX.*Note off ch 2.*91 3D 00"))
sysex_callback({0xF0, 0x7D, 0x21, 1, 0xF7})
assert(monitor.tx == 2 and output.sent[2][5] == 0xF7)

local lines = #monitor.lines
callback({0xF8})
assert(#monitor.lines == lines and monitor.rx == 5 and monitor.tx == 3,
  "hiding clock must not prevent forwarding or counting it")
monitor.show_clock = true
callback({0xF8})
assert(#monitor.lines == lines + 2)
assert(monitor:send(assert(Monitor.parse("B0 01 40"))))
assert(monitor:text():match("TX.*CC ch 1.*B0 01 40"))

local previous_tx = monitor.tx
fail_send = true
callback({0x90, 60, 1})
assert(not monitor.thru and monitor.tx == previous_tx,
  "failed forwarding must disable Thru without logging a successful TX")
assert(monitor:text():match("ERROR.*driver failed"))
fail_send = false

monitor:clear()
assert(monitor.rx == 0 and monitor.tx == 0 and #monitor.lines == 0)
for i = 1, Monitor.MAX_ENTRIES + 2 do monitor:append("message " .. i) end
assert(#monitor.lines == Monitor.MAX_ENTRIES)
assert(monitor.lines[1]:match("message 3$"))
assert(monitor.lines[#monitor.lines]:match("message 502$"))

local path = os.tmpname()
assert(monitor:save(path))
local file = assert(io.open(path, "rb"))
local saved = file:read("*a")
file:close()
assert(os.remove(path))
assert(saved == monitor:text() .. "\n", "saved log must match retained messages")

monitor:close()
assert(not input.is_open and not output.is_open)
assert(not monitor:send({0xF8}))
assert(monitor:open("Input", nil), "input-only capture must work")
callback({0xFA})
assert(monitor:text():match("RX.*Start.*FA"))
monitor:close()
assert(not monitor:open("Input", "Missing"))
assert(monitor.input == nil and monitor.output == nil)
print("MIDI monitor capture, forwarding and message validation spec passed")
