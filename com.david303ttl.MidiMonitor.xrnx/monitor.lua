-- SPDX-License-Identifier: GPL-3.0-only
local C = require("constants")
local Monitor = {}
Monitor.__index = Monitor
Monitor.MAX_ENTRIES = C.MAX_ENTRIES

local function status_base(status)
  return math.floor(status / C.STATUS_GROUP_SIZE) * C.STATUS_GROUP_SIZE
end

function Monitor.parse(text)
  local bytes = {}
  for token in tostring(text):gmatch("%S+") do
    if not token:match(C.HEX_BYTE_PATTERN) then return nil, "Use two-digit hex bytes separated by spaces" end
    bytes[#bytes + 1] = tonumber(token, C.STATUS_GROUP_SIZE)
  end
  local status = bytes[C.STATUS_INDEX]
  if not status or status < C.STATUS_MIN then return nil, "Start with a MIDI status byte" end
  if status == C.SYSEX_START then
    if #bytes < C.SYSEX_MIN_BYTES or bytes[#bytes] ~= C.SYSEX_END then return nil, "SysEx must end with F7" end
  else
    local kind = status_base(status)
    local count
    if kind < C.SYSEX_START then
      count = (kind == C.PROGRAM_CHANGE or kind == C.CHANNEL_PRESSURE) and
        C.PROGRAM_MESSAGE_BYTES or C.CHANNEL_MESSAGE_BYTES
    elseif status == C.TIME_CODE or status == C.SONG_SELECT then count = C.PROGRAM_MESSAGE_BYTES
    elseif status == C.SONG_POSITION then count = C.CHANNEL_MESSAGE_BYTES
    elseif C.MESSAGE_NAMES[status] then count = C.REALTIME_MESSAGE_BYTES end
    if not count or #bytes ~= count then return nil, "Invalid MIDI message length or status" end
  end
  local last = status == C.SYSEX_START and #bytes - 1 or #bytes
  for i = C.DATA_START, last do
    if bytes[i] > C.DATA_MAX then return nil, "MIDI data bytes must be 00-7F" end
  end
  return bytes
end

function Monitor.new()
  return setmetatable({lines = {}, rx = 0, tx = 0, dirty = true,
    thru = false, show_clock = false}, Monitor)
end

function Monitor:append(text)
  self.lines[#self.lines + 1] = os.date("%H:%M:%S") .. " " .. text
  if #self.lines > self.MAX_ENTRIES then table.remove(self.lines, 1) end
  self.dirty = true
end

function Monitor:record(direction, message)
  self[direction == "RX" and "rx" or "tx"] = self[direction == "RX" and "rx" or "tx"] + 1
  self.dirty = true
  if message[C.STATUS_INDEX] == C.CLOCK and not self.show_clock then return end
  local status = message[C.STATUS_INDEX]
  local kind = status_base(status)
  local label = C.MESSAGE_NAMES[status] or C.MESSAGE_NAMES[kind] or "MIDI"
  if kind < C.SYSEX_START then label = label .. " ch " .. (status % C.STATUS_GROUP_SIZE + 1) end
  if kind == C.NOTE_ON and message[C.VELOCITY_INDEX] == 0 then
    label = "Note off ch " .. (status % C.STATUS_GROUP_SIZE + 1)
  end
  local hex = {}
  for _, byte in ipairs(message) do hex[#hex + 1] = string.format(C.HEX_BYTE_FORMAT, byte) end
  self:append(string.format("%s  %s [%d bytes] %s", direction, label, #message, table.concat(hex, " ")))
end

function Monitor:close()
  self.thru = false
  if self.input then pcall(function() self.input:close() end) end
  if self.output then pcall(function() self.output:close() end) end
  self.input, self.output = nil, nil
  self.dirty = true
end

function Monitor:send(message)
  if not self.output or not self.output.is_open then return false, "Select an output and connect first" end
  local ok, issue = pcall(function() self.output:send(message) end)
  if not ok then
    self:append("ERROR  MIDI send failed: " .. tostring(issue))
    return false, tostring(issue)
  end
  self:record("TX", message)
  return true
end

function Monitor:open(input_name, output_name)
  self:close()
  if not input_name then return false, "Select a MIDI input" end
  local ok, issue = pcall(function()
    if output_name then self.output = renoise.Midi.create_output_device(output_name) end
    local function receive(message)
      self:record("RX", message)
      if self.thru then
        local sent = self:send(message)
        if not sent then self.thru = false end
      end
    end
    self.input = renoise.Midi.create_input_device(input_name, receive, receive)
  end)
  if not ok or not self.input or not self.input.is_open or
     (output_name and (not self.output or not self.output.is_open)) then
    self:close()
    return false, "Cannot open MIDI ports: " .. tostring(issue)
  end
  self:append("Connected RX: " .. input_name .. " | TX: " .. (output_name or "none"))
  return true
end

function Monitor:clear()
  self.lines, self.rx, self.tx, self.dirty = {}, 0, 0, true
end

function Monitor:text()
  return table.concat(self.lines, "\n")
end

function Monitor:save(path)
  local file, issue = io.open(path, "wb")
  if not file then return false, issue end
  local ok, written, reason = pcall(function() return file:write(self:text(), "\n") end)
  local closed, close_issue = file:close()
  if not ok then return false, written end
  if not written then return false, reason end
  if not closed then return false, close_issue end
  return true
end

return Monitor
