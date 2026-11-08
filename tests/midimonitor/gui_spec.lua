assert(dofile("tests/bootstrap.lua")("midimonitor"))
local views, show, flush, unload, dialog, input, output
views = {}
local function control(kind, properties)
  if kind == "row" or kind == "column" then
    assert(properties.views, "API 6.2 containers require a views property")
    assert(properties[1] == nil, "children must be in views")
  end
  local values = properties
  local result = setmetatable({}, {
    __index = function(_, key)
      if key == "scroll_to_last_line" then return function() end end
      return values[key]
    end,
    __newindex = function(_, key, value)
      local previous = values[key]
      values[key] = value
      if key == "value" and previous ~= value and values.notifier then values.notifier(value) end
    end
  })
  result.kind = kind
  views[#views + 1] = result
  return result
end
local tool = {
  add_menu_entry = function(_, entry) show = entry.invoke end,
  add_keybinding = function() end,
  add_timer = function(_, callback) flush = callback end,
  tool_will_unload_observable = {add_notifier = function(_, callback) unload = callback end}
}
local app = {show_custom_dialog = function(_, title)
  assert(title == "MIDI Monitor")
  dialog = {visible = true, show = function() end}
  return dialog
end}
renoise = {
  tool = function() return tool end,
  app = function() return app end,
  ViewBuilder = function()
    return setmetatable({}, {__index = function(_, kind)
      return function(_, properties) return control(kind, properties) end
    end})
  end,
  Midi = {
    available_input_devices = function() return {"Input"} end,
    available_output_devices = function() return {"Output"} end,
    create_input_device = function(_, receive, sysex)
      input = {is_open = true, receive = receive, sysex = sysex,
        close = function(self) self.is_open = false end}
      return input
    end,
    create_output_device = function()
      output = {is_open = true, sent = {},
        send = function(self, message) self.sent[#self.sent + 1] = message end,
        close = function(self) self.is_open = false end}
      return output
    end
  }
}
local function find(kind, text)
  for _, view in ipairs(views) do
    if view.kind == kind and (not text or view.text == text) then return view end
  end
  error("missing " .. kind .. ": " .. tostring(text))
end

dofile("com.david303ttl.MidiMonitor.xrnx/main.lua")
assert(not dialog and not input, "loading the tool must not open windows or MIDI ports")
show()
assert(not input, "opening the monitor must not connect automatically")
local out_select
for _, view in ipairs(views) do
  if view.items and view.items[1] == "(no output)" then out_select = view end
end
out_select.value = 2
find("button", "Connect").notifier()
input.receive({0x90, 60, 80})
input.sysex({0xF0, 0x7D, 0x21, 0xF7})
flush()
local log = find("multiline_text")
assert(log.text:match("RX.*90 3C 50") and log.text:match("SysEx.*F0 7D 21 F7"))
assert(#output.sent == 0)
find("button", "Send").notifier()
flush()
assert(#output.sent == 1 and output.sent[1][1] == 0xF0 and output.sent[1][4] == 0xF7)
assert(log.text:match("TX.*F0 7D 20 F7"))
find("textfield").text = "90 3C FF"
find("button", "Send").notifier()
assert(#output.sent == 1, "invalid input must not reach the driver")

local visible_text = log.text
dialog.visible = false
input.receive({0xFA})
flush()
assert(input.is_open and log.text == visible_text, "hidden capture must keep ports open without updating views")
dialog.visible = true
flush()
assert(log.text:match("RX.*Start.*FA"), "background messages must be retained")
find("button", "Clear").notifier()
flush()
assert(log.text == "")
unload()
assert(not input.is_open and not output.is_open, "unload must release both ports")
print("MIDI monitor GUI and background capture spec passed")
