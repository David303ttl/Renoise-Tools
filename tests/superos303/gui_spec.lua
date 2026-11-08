assert(dofile("tests/bootstrap.lua")("superos303"))
local protocol = require("protocol")
local views, sent, errors = {}, {}, {}
local input, output, status = nil, nil, nil
local prompts = 0
local fail_command, immediate_reply

local function view(properties)
  local values = properties or {}
  local result = setmetatable({}, {
    __index = values,
    __newindex = function(_, key, value)
      local previous = values[key]
      values[key] = value
      if key == "value" and previous ~= value and values.notifier then
        values.notifier(value)
      end
    end
  })
  views[#views + 1] = result
  return result
end

local app = {
  show_status = function(_, message) status = message end,
  show_error = function(_, message) errors[#errors + 1] = message end,
  show_prompt = function() prompts = prompts + 1; return "Write" end,
  show_custom_dialog = function() return {visible = true} end
}
renoise = {
  app = function() return app end,
  ViewBuilder = function()
    return setmetatable({}, {__index = function()
      return function(_, properties) return view(properties) end
    end})
  end,
  Midi = {
    available_input_devices = function() return {"Test Input"} end,
    available_output_devices = function() return {"Test Output"} end,
    create_input_device = function(_, _, callback)
      input = {name = "Test Input", is_open = true, on_sysex = callback,
        close = function(self) self.is_open = false end}
      return input
    end,
    create_output_device = function()
      output = {name = "Test Output", is_open = true,
        close = function(self) self.is_open = false end,
        send = function(_, message)
          if message[3] == fail_command then error("injected send failure") end
          sent[#sent + 1] = message
          if message[3] == 0x10 and immediate_reply then
            input.on_sysex(immediate_reply)
          end
        end}
      return output
    end
  }
}

local function find(field, value)
  for _, control in ipairs(views) do
    if control[field] == value then return control end
  end
  error("missing control: " .. tostring(value))
end

local function click(text)
  local button = find("text", text)
  assert(button.active ~= false, text .. " must be enabled")
  button.notifier()
end

local function editable(expected)
  for _, text in ipairs({"Write step", "Write ratchet", "Write length"}) do
    assert(find("text", text).active == expected, text .. " enabled state")
  end
end

local raw = {}
for i = 1, protocol.PATTERN_SIZE do raw[i] = 0 end
raw[1], raw[33], raw[52] = protocol.pitch(4, 3, false, false), 1, 8
local function reply(pattern)
  local sum = protocol.checksum(raw)
  local body = {0x7D, 0x11, pattern or 0, sum % 128, math.floor(sum / 128)}
  for _, byte in ipairs(protocol.pack7(raw)) do body[#body + 1] = byte end
  body[#body + 1] = 0
  return protocol.frame(body)
end

local function readback(pattern)
  input.on_sysex(reply(pattern))
  editable(true)
end

local function wrote_and_requested(command, before)
  assert(#sent == before + 2, "write must be followed by one readback request")
  assert(sent[before + 1][3] == command, "wrong write opcode")
  local request = sent[before + 2]
  assert(request[3] == 0x10 and request[4] == 0 and request[5] == 0,
    "readback must target selected pattern and variation")
  editable(false)
  assert(status:match("Reading back hardware state"))
end

require("gui").show()
editable(false)
click("Connect")
input.on_sysex(protocol.frame({0x7D, 0x21, 1, 1, 0, 8, 2, 3}))
input.on_sysex(protocol.frame({0x7D, 0x1C, 0}))
click("Fetch")
readback()

local note
for _, control in ipairs(views) do
  if control.items and control.items[1] == "C" and control.items[13] == "High C" then
    assert(not note, "note editor must be unique")
    note = control
  end
end
assert(note and note.value == 5, "fetched pitch must populate the editor")

local before = #sent

-- Two consecutive edits must work without a manual Fetch between writes.
for _, semitone in ipairs({6, 9}) do
  note.value = semitone + 1
  before = #sent
  click("Write step")
  wrote_and_requested(0x16, before)
  assert(sent[before + 1][6] == protocol.pitch(semitone, 3, false, false))
  input.on_sysex(reply(1))
  editable(false)
  input.on_sysex(protocol.frame({0x7D, 0x11}))
  editable(false)
  raw[1] = protocol.pitch(semitone, 3, false, false)
  readback()
  assert(note.value == semitone + 1, "editor must show the actual readback")
  assert(status:match("Write confirmed by hardware readback"))
end
assert(prompts == 0, "live edits must not interrupt playback with confirmation prompts")

note.value = 2
click("Write step")
readback()
assert(status:match("Write not confirmed"), "unchanged hardware must not report success")
assert(note.value == 10, "failed write must show the returned hardware note")

for _, edit in ipairs({{"Write ratchet", 0x28}, {"Write length", 0x18}}) do
  before = #sent
  click(edit[1])
  wrote_and_requested(edit[2], before)
  readback()
end

fail_command = 0x10
before = #sent
click("Write step")
assert(#sent == before + 1, "write should succeed before readback send fails")
editable(false)
assert(status:match("MIDI send failed"), "readback send error must stay visible")
fail_command = nil
click("Fetch")
readback()

-- A reply delivered during send must not be cleared by the write handler.
immediate_reply = reply()
click("Write step")
editable(true)
assert(status:match("Write confirmed by hardware readback"))
immediate_reply = nil

before = #sent
input.on_sysex(protocol.frame({0x7D, 0x15, 0, 0, 0}))
editable(true)
assert(#sent == before, "playback anchors must leave the editor writable")
input.on_sysex(protocol.frame({0x7D, 0x16, 0, 0, 0, 0, 1, 1}))
editable(true)
assert(#sent == before, "another variation's edit must not invalidate the CV snapshot")
input.on_sysex(protocol.frame({0x7D, 0x16, 0, 0, 0, 0, 1, 0}))
editable(false)
assert(#sent == before + 1 and sent[#sent][3] == 0x10,
  "hardware edits must refresh without a manual Fetch")
readback()

before = #sent
input.on_sysex(protocol.frame({0x7D, 0x1E, 8, 0}))
assert(#sent == before, "hardware selection must not send a selection command")
click("Use hardware pattern")
assert(#sent == before + 1 and sent[#sent][3] == 0x10 and sent[#sent][4] == 8,
  "B1 must fetch slot 8 without queuing a different hardware pattern")
readback(8)
assert(find("text", "B1"))

input.on_sysex(protocol.frame({0x7D, 0x15, 8, 0, 2}))
editable(false)
assert(find("text", "G3"))
click("Use hardware pattern")
readback(8)

click("Disconnect")
editable(false)
assert(#errors == 1, "only the injected send failure should show an error")
assert(prompts == 0, "step, ratchet and length writes must not ask for confirmation")
print("SuperOS-303 GUI write/readback spec passed")
