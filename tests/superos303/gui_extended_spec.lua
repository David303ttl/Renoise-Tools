-- Offline GUI integration coverage for mono-shadow, poly, config and probability writes.
assert(dofile("tests/bootstrap.lua")("superos303"))
local p = require("protocol")
local C = require("constants")
local views, sent = {}, {}
local input, status
local function view(properties)
  local data = properties or {}
  local result = setmetatable({}, {
    __index = data,
    __newindex = function(_, key, value)
      local old = data[key]
      data[key] = value
      if key == "value" and old ~= value and data.notifier then data.notifier(value) end
    end
  })
  views[#views + 1] = result
  return result
end
local app = {
  show_status = function(_, message) status = message end,
  show_error = function(_, message) error(message) end,
  show_prompt = function() return "Write" end,
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
    available_input_devices = function() return {"Input"} end,
    available_output_devices = function() return {"Output"} end,
    create_input_device = function(_, _, callback)
      input = {name = "Input", is_open = true, on_sysex = callback,
        close = function(self) self.is_open = false end}
      return input
    end,
    create_output_device = function()
      return {name = "Output", is_open = true,
        send = function(_, msg) sent[#sent + 1] = msg end,
        close = function(self) self.is_open = false end}
    end
  }
}
local function find_text(text)
  for _, control in ipairs(views) do
    if control.text == text then return control end
  end
  error("missing control: " .. text)
end
local function click(text)
  local control = find_text(text)
  assert(control.active ~= false, text .. " is inactive")
  control.notifier()
end
local function feed(body)
  input.on_sysex(p.frame(body))
end
local function response(command, pat, raw, var)
  local sum = p.checksum(raw)
  local body = {0x7D, command, pat, sum % 128, math.floor(sum / 128)}
  for _, b in ipairs(p.pack7(raw)) do body[#body + 1] = b end
  if var then body[#body + 1] = var end
  feed(body)
end
local function last_command()
  return sent[#sent][3]
end
local raw = {}
for i = 1, C.PATTERN_SIZE do raw[i] = 0 end
raw[1], raw[33], raw[52] = p.pitch(4, 1, false, false), 1, 16

require("gui").show()
click("Connect")
feed({0x7D, 0x21, 1, 1, 0, 8, 2, 3})
feed({0x7D, 0x1C, 0})
click("Write MIDI config")
assert(last_command() == C.COMMAND.REQUEST_CONFIG)
assert(sent[#sent - 1][3] == C.COMMAND.WRITE_CONFIG)

-- Select variation 2 without relying on internal widget variable IDs.
local variation
for _, control in ipairs(views) do
  if control.items and control.items[1] == "1 - CV" then variation = control end
end
assert(variation)
variation.value = 2
click("Fetch")
response(C.COMMAND.PATTERN_REPLY, 0, raw, 1)
assert(find_text("Write step").active)
local before = #sent
click("Write step")
assert(#sent == before + 2)
assert(sent[before + 1][3] == C.COMMAND.WRITE_BLOB)
assert(last_command() == C.COMMAND.REQUEST_PATTERN)
assert(sent[before + 1][#sent[before + 1] - 1] == 1,
  "variation 2 blob must append index 1 before F7")

-- Poly variation 3 is a native chord stream, not mono data.
variation.value = 3
click("Fetch")
local poly = {}
for i = 1, C.POLY_SIZE do poly[i] = 0 end
poly[1], poly[2], poly[3] = 16, 252, 255
poly[97], poly[113], poly[115] = 1, 1, 16
response(C.COMMAND.POLY_REPLY, 0, poly)
assert(find_text("Write poly step").active)
assert(find_text("Write step").active == false)
before = #sent
click("Write poly step")
assert(#sent == before + 2)
assert(sent[before + 1][3] == C.COMMAND.POLY_STEP)
assert(last_command() == C.COMMAND.REQUEST_PATTERN)

-- Probability table is independent of the mono pattern snapshot.
variation.value = 1
click("Fetch")
response(C.COMMAND.PATTERN_REPLY, 0, raw, 0)
click("Read probabilities")
assert(last_command() == C.COMMAND.REQUEST_PROBABILITY)
local probs = {}
for i = 1, C.PROBABILITY_SIZE do probs[i] = 0 end
response(C.COMMAND.PROBABILITY_REPLY, 0, probs)
assert(find_text("Write probability").active)
before = #sent
click("Write probability")
assert(#sent == before + 2)
assert(sent[before + 1][3] == C.COMMAND.PROBABILITY)
assert(last_command() == C.COMMAND.REQUEST_PROBABILITY)
response(C.COMMAND.PROBABILITY_REPLY, 0, probs)
assert(status:match("Probability write confirmed"), status)
print("SuperOS-303 extended GUI spec passed")
