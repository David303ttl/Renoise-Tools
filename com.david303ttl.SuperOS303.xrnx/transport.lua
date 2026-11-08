-- SPDX-License-Identifier: GPL-3.0-only
-- Renoise raw MIDI device adapter. Only non-bootloader SuperOS opcodes are sent.
local protocol = require("protocol")
local C = require("constants")
local CMD = C.COMMAND
local Transport = {}
Transport.__index = Transport

local allowed = {
  [CMD.REQUEST_PATTERN] = true, [CMD.WRITE_STEP] = true, [CMD.WRITE_LENGTH] = true,
  [CMD.QUEUE_PATTERN] = true, [CMD.EDIT_VARIATION] = true, [CMD.REQUEST_CONFIG] = true,
  [CMD.WRITE_CONFIG] = true, [CMD.WRITE_RATCHET] = true
}

function Transport.new(on_event)
  return setmetatable({on_event = on_event, input = nil, output = nil}, Transport)
end

function Transport:close()
  if self.output then pcall(function() self.output:close() end) end
  if self.input then pcall(function() self.input:close() end) end
  self.output, self.input = nil, nil
end

local function contains(list, value)
  for _, item in ipairs(list) do if item == value then return true end end
  return false
end

function Transport:open(input_name, output_name)
  self:close()
  if not contains(renoise.Midi.available_input_devices(), input_name) then
    return false, "MIDI input is unavailable: " .. tostring(input_name)
  end
  if not contains(renoise.Midi.available_output_devices(), output_name) then
    return false, "MIDI output is unavailable: " .. tostring(output_name)
  end

  local ok, result = pcall(function()
    self.input = renoise.Midi.create_input_device(input_name,
      function() end,
      function(message)
        local event, err = protocol.decode(message)
        if event then
          self.on_event(event)
        elseif err ~= "not SuperOS SysEx" then
          self.on_event({type = "error", message = err})
        end
      end)
    self.output = renoise.Midi.create_output_device(output_name)
  end)
  if not ok or not self.input or not self.output then
    self:close()
    return false, "Cannot open MIDI ports: " .. tostring(result)
  end
  return true
end

function Transport:is_open()
  return self.input ~= nil and self.output ~= nil and
    self.input.is_open and self.output.is_open
end

function Transport:send(body)
  if not self:is_open() then return false, "MIDI ports not connected" end
  if not allowed[body[C.BODY_COMMAND]] then return false, "unsupported or unsafe SuperOS opcode" end
  local ok, err = pcall(function() self.output:send(protocol.frame(body)) end)
  if not ok then return false, "MIDI send failed: " .. tostring(err) end
  return true
end

return Transport
