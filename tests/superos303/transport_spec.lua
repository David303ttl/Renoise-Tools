assert(dofile("tests/bootstrap.lua")("superos303"))
local sent, input, output
renoise = {Midi = {
  available_input_devices = function() return {"Test Input"} end,
  available_output_devices = function() return {"Test Output"} end,
  create_input_device = function(_, callback, sysex_callback)
    assert(type(callback) == "function")
    input = {name = "Test Input", is_open = true, close = function(self) self.is_open = false end,
      on_sysex = sysex_callback}
    return input
  end,
  create_output_device = function()
    output = {name = "Test Output", is_open = true,
      send = function(_, message) sent = message end,
      close = function(self) self.is_open = false end}
    return output
  end
}}
local Transport = require("transport")
local got
local t = Transport.new(function(event) got = event end)
local ok, issue = t:open("Test Input", "Test Output")
assert(ok, issue)
assert(t:is_open())
assert(t:send({0x7D, 0x20}))
assert(sent[1] == 0xF0 and sent[2] == 0x7D and
  sent[3] == 0x20 and sent[4] == 0xF7)
local allowed, warning = t:send({0x7D, 0x4A})
assert(not allowed and warning:match("unsafe"))
input.on_sysex({0xF0, 0x7D, 0x1C, 2, 0xF7})
assert(got and got.type == "group" and got.group == 2)
t:close()
assert(not t:is_open())
print("SuperOS-303 MIDI transport spec passed")
