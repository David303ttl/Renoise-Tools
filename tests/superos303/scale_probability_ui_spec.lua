-- Integration regression for scale write/readback and retained probability data.
assert(dofile("tests/bootstrap.lua")("superos303"))
local protocol = require("protocol")
local C = require("constants")
local model = require("pattern_model")
local views, sent = {}, {}
local callback, status
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
renoise = {
  app = function() return {
    show_status = function(_, text) status = text end,
    show_error = function(_, text) error(text) end,
    show_prompt = function() return "Write" end,
    show_custom_dialog = function() return {visible = true} end
  } end,
  ViewBuilder = function()
    return setmetatable({}, {__index = function()
      return function(_, properties) return view(properties) end
    end})
  end,
  Midi = {
    available_input_devices = function() return {"Hardware IN"} end,
    available_output_devices = function() return {"Hardware OUT"} end,
    create_input_device = function(_, _, sysex)
      callback = sysex
      return {name = "Hardware IN", is_open = true,
        close = function(self) self.is_open = false end}
    end,
    create_output_device = function()
      return {name = "Hardware OUT", is_open = true,
        send = function(_, msg) sent[#sent + 1] = msg end,
        close = function(self) self.is_open = false end}
    end
  }
}
local function control(label)
  for _, v in ipairs(views) do if v.text == label then return v end end
  error("missing view " .. label)
end
local function popup(first)
  for _, v in ipairs(views) do
    if v.items and v.items[1] == first then return v end
  end
  error("missing popup " .. first)
end
local function click(label)
  local v = control(label)
  assert(v.active ~= false, label .. " inactive")
  v.notifier()
end
local function send(body)
  callback(protocol.frame(body))
end
local function reply(cmd, pattern, raw)
  local checksum = protocol.checksum(raw)
  local body = {0x7D, cmd, pattern, checksum % 128, math.floor(checksum / 128)}
  for _, value in ipairs(protocol.pack7(raw)) do body[#body + 1] = value end
  send(body)
end
local raw = {}
for i = 1, C.PATTERN_SIZE do raw[i] = 0 end
raw[1], raw[33], raw[52] = 0x10, 1, 16
raw[2], raw[33] = 0x11, 1 + 2 * 4 + 16 -- NOTE, TIE, NOTE, REST
local prob = {}
for i = 1, C.PROBABILITY_SIZE do prob[i] = 0 end
prob[1] = 13 + 8 * 16
prob[2] = 2 + 10 * 16
prob[3] = 1

require("gui").show()
click("Connect")
send({0x7D, 0x21, 1, 1, 0, 8, 2, 3})
send({0x7D, 0x1C, 0})
click("Fetch")
reply(C.COMMAND.PATTERN_REPLY, 0, raw)
assert(sent[#sent][3] == C.COMMAND.REQUEST_PROBABILITY,
  "pattern fetch must request probabilities automatically")
reply(C.COMMAND.PROBABILITY_REPLY, 0, prob)
assert(control("Write probability").active == true)

local tabs = popup("Steps")
tabs.value = 2 -- Scale page
assert(control("Set mask").active ~= false)
local preset = popup("Chromatic")
preset.value = 4 -- minor pentatonic
click("Set mask")
local mask = model.preset_mask(0, 4)
assert(mask == 1193)
local enabled = model.scale({type = "pattern", raw = raw}).enabled
click("Write scale")
assert(sent[#sent - 1][3] == C.COMMAND.SCALE)
assert(sent[#sent][3] == C.COMMAND.REQUEST_PATTERN)
local expected = model.with_scale({type = "pattern", raw = raw}, mask, enabled)
reply(C.COMMAND.PATTERN_REPLY, 0, expected)
assert(status:match("Write confirmed"), status)
assert(control("Write probability").active == true,
  "scale readback must preserve already loaded probabilities")

local count = #sent
click("Fetch")
reply(C.COMMAND.PATTERN_REPLY, 0, expected)
assert(#sent == count + 1, "re-fetch must not needlessly re-request cached probabilities")
assert(control("Write probability").active)

tabs.value = 3 -- probability page
local numbers = {}
for _, v in ipairs(views) do
  if v.min == 0 and v.max == 13 then numbers[#numbers + 1] = v end
end
assert(#numbers == 4)
assert(numbers[1].value == 13 and numbers[2].value == 8 and
  numbers[3].value == 2 and numbers[4].value == 10)
click("Write probability")
local write = sent[#sent - 1]
assert(write[3] == C.COMMAND.PROBABILITY)
assert(write[9] == 3, "high probability bits must be preserved")
reply(C.COMMAND.PROBABILITY_REPLY, 0, prob)
assert(status:match("Probability write confirmed"), status)

local step_selectors = {}
for _, v in ipairs(views) do
  if v.views and v.views[1] and v.views[1].text == "Step" then
    step_selectors[#step_selectors + 1] = v.views[2]
  end
end
assert(#step_selectors == 2, "Steps and Probability must both expose step selection")
local step_editor, probability_step = step_selectors[1], step_selectors[2]
probability_step.value = 3
assert(step_editor.value == 3, "probability selection must select the same grid step")
assert(numbers[1].value == 0 and numbers[2].value == 0 and
  numbers[3].value == 0 and numbers[4].value == 0, "selection must load that step's levels")

local function change_probability()
  numbers[1].value, numbers[2].value = 5, 9
  numbers[3].value, numbers[4].value = 0, 13
  click("Write probability")
  local message = sent[#sent - 1]
  assert(message[3] == C.COMMAND.PROBABILITY and message[5] == 2,
    "probability write must address the step selected on the Probability tab")
  assert(message[6] == 21 and message[7] == 80 and message[8] == 0 and message[9] == 3,
    "changed levels must reach the wire with both high bits intact")
end

change_probability()
reply(C.COMMAND.PROBABILITY_REPLY, 0, prob)
assert(status:match("Probability write not confirmed"), "unchanged readback must reject the edit")
assert(numbers[1].value == 0, "failed writes must show the returned hardware value")
change_probability()
prob[7], prob[8] = 149, 208
reply(C.COMMAND.PROBABILITY_REPLY, 0, prob)
assert(status:match("Probability write confirmed") and status:match("step 3") and status:match("NOTE"),
  "confirmation must identify the edited NOTE step")
assert(numbers[1].value == 5 and numbers[2].value == 9 and numbers[4].value == 13)

probability_step.value = 2
assert(control("TIE holds the previous NOTE's probability result. Choose a NOTE step."))
numbers[1].value = 13
click("Write probability")
prob[4] = 13
reply(C.COMMAND.PROBABILITY_REPLY, 0, prob)
assert(status:match("step 2") and status:match("TIE holds"),
  "stored TIE probabilities must explain why playback does not change")
probability_step.value = 4
assert(control("This step is silent. Choose a NOTE step to hear probabilities."))
step_editor.value = 1
assert(probability_step.value == 1 and numbers[1].value == 13,
  "Steps selection must update the Probability tab and its values")

send({0x7D, 0x1C, 1})
assert(control("Write probability").active == false)
assert(probability_step.active == false, "a cleared snapshot must disable probability selection")
print("SuperOS-303 scale/probability and tab regression passed")
