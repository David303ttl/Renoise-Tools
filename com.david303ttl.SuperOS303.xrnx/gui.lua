-- SPDX-License-Identifier: GPL-3.0-only
local protocol = require("protocol")
local Transport = require("transport")

local M = {}
local dialog, vb, device = nil, nil, nil
local state = {group = nil, config = nil, pattern = nil, selected = 0, variation = 0,
  step = 0, draft_time = 1, draft_note = 0, draft_octave = 1,
  draft_accent = false, draft_slide = false, draft_ratchet = 0}
local ports_in, ports_out = {}, {}
local display = {}

local function status(message)
  if display.status then display.status.text = message end
  renoise.app():show_status("SuperOS-303: " .. message)
end

local function error_message(message)
  status(message)
  renoise.app():show_error("SuperOS-303: " .. message)
end

local function send(body)
  if not device then return false end
  local ok, issue = device:send(body)
  if not ok then error_message(issue) end
  return ok
end

local function selected_pattern()
  return display.pattern_select.value - 1
end

local function requested_variation()
  return display.variation_select.value - 1
end

local function clear_snapshot()
  state.pattern = nil
  if display.pattern_info then display.pattern_info.text = "No verified pattern loaded" end
  if display.write_step then display.write_step.active = false end
  if display.write_ratchet then display.write_ratchet.active = false end
  if display.write_length then display.write_length.active = false end
end

local function update_controls()
  local p = state.pattern
  if not p then return end
  local step = math.min(state.step, p.length - 1)
  state.step = step
  display.step_select.max = p.length
  display.step_select.value = step + 1
  local s = protocol.step(p, step)
  state.draft_time = (s.time <= 2) and s.time or 0
  state.draft_note = s.semitone or 0
  state.draft_octave = s.octave or 1
  state.draft_accent = s.accent or false
  state.draft_slide = s.slide or false
  state.draft_ratchet = (s.ratchet == 2 or s.ratchet == 3) and s.ratchet or 0
  display.time_select.value = state.draft_time + 1
  display.note_select.value = state.draft_note + 1
  display.octave_select.value = state.draft_octave + 1
  display.accent_select.value = state.draft_accent
  display.slide_select.value = state.draft_slide
  display.ratchet_select.value = (state.draft_ratchet == 0 and 1) or state.draft_ratchet
  display.length_select.value = p.length
  display.pattern_info.text = string.format(
    "Group %d | Pattern %d | Variation %d | %d steps%s | Step %d: %s",
    state.group + 1, p.pattern + 1, p.variation + 1, p.length,
    p.triplet and " triplet" or "", step + 1,
    ({"REST", "NOTE", "TIE", "RESERVED"})[s.time + 1])
  local editable = p.variation == 0 and p.pattern == selected_pattern() and
    p.group == state.group and device and device:is_open()
  display.write_step.active = not not editable
  display.write_ratchet.active = not not editable
  display.write_length.active = not not editable
end

local function on_event(event)
  if event.type == "error" then
    status("Ignored invalid SysEx: " .. event.message)
  elseif event.type == "config" then
    state.config = event
    display.config_info.text = string.format(
      "Firmware %s | MIDI ch %d | V2 ch %d | V3 ch %d | Clock %s | Thru %s | RX %s / TX %s",
      event.version == "" and "unknown" or event.version, event.channel,
      event.var2_channel, event.var3_channel, event.flags % 2 == 1 and "on" or "off",
      math.floor(event.flags / 2) % 2 == 1 and "on" or "off",
      math.floor(event.flags / 4) % 2 == 0 and "on" or "off",
      math.floor(event.flags / 8) % 2 == 0 and "on" or "off")
    status("Configuration received")
  elseif event.type == "group" then
    if state.group ~= event.group then
      state.group = event.group
      clear_snapshot()
      display.group_info.text = "Hardware group " .. (event.group + 1) ..
        " (change groups on the 303, then fetch again)"
    end
  elseif event.type == "pattern" or event.type == "poly" then
    if state.group == nil then
      status("Read group first (Config). Pattern not assigned to a group")
      return
    end
    if event.pattern ~= selected_pattern() or event.variation ~= requested_variation() then
      return
    end
    if event.type == "poly" then
      clear_snapshot()
      display.pattern_info.text = "Variation 3 is polyphonic. Read-only in this tool."
      status("Poly variation received; mono editor disabled")
      return
    end
    event.group = state.group
    state.pattern = event
    update_controls()
    status("Pattern received and checksum verified")
  elseif event.type == "changed" then
    if state.pattern and event.pattern == state.pattern.pattern then
      clear_snapshot()
      status("Hardware edited this pattern. Fetch it again before writing.")
    end
  elseif event.type == "ack" then
    status(event.status == 0 and "Device ACK" or
      ("Device NAK (" .. event.status .. ")"))
  elseif event.type == "active" then
    if event.group ~= nil and event.group <= 3 then
      on_event({type = "group", group = event.group})
    end
  end
end

local function close_ports()
  if device then device:close() end
  state.config, state.group = nil, nil
  clear_snapshot()
  if display.connection then display.connection.text = "Disconnected" end
  if display.group_info then display.group_info.text = "Hardware group unknown" end
  if display.config_info then display.config_info.text = "No config read yet" end
end

local function refresh_ports()
  close_ports()
  ports_in = renoise.Midi.available_input_devices()
  ports_out = renoise.Midi.available_output_devices()
  -- Popup values are 1-based. Empty device lists are represented by a placeholder.
  display.in_select.items = #ports_in > 0 and ports_in or {"(no inputs)"}
  display.out_select.items = #ports_out > 0 and ports_out or {"(no outputs)"}
  display.in_select.value, display.out_select.value = 1, 1
end

local function connect()
  if #ports_in == 0 or #ports_out == 0 then
    error_message("No MIDI ports available")
    return
  end
  close_ports()
  local ok, issue = device:open(ports_in[display.in_select.value],
                               ports_out[display.out_select.value])
  if not ok then error_message(issue) return end
  display.connection.text = "Connected: " .. device.input.name .. " / " .. device.output.name
  status("Ports open. Reading hardware configuration...")
  send(protocol.request_config())
end

local function require_snapshot()
  local p = state.pattern
  if not p or p.group ~= state.group or p.pattern ~= selected_pattern() or
    p.variation ~= requested_variation() then
    error_message("Fetch the selected pattern before writing")
    return nil
  end
  if p.variation ~= 0 then
    error_message("Variation 2/3 editing is disabled until resident-slot writes can be verified")
    return nil
  end
  if not device or not device:is_open() then
    error_message("Connect MIDI first")
    return nil
  end
  return p
end

local function confirm_write(action, details)
  return renoise.app():show_prompt("SuperOS-303: " .. action,
    details .. "\n\nThis writes to the hardware. Continue?",
    {"Write", "Cancel"}) == "Write"
end

local function write_step()
  local p = require_snapshot()
  if not p then return end
  local time = display.time_select.value - 1
  local pitch = protocol.PITCH_EMPTY
  if time == 1 then
    pitch = protocol.pitch(display.note_select.value - 1,
      display.octave_select.value - 1,
      display.accent_select.value, display.slide_select.value)
  end
  if not confirm_write("Edit step", string.format(
      "Group %d, pattern %d, variation 1, step %d", state.group + 1,
      p.pattern + 1, state.step + 1)) then return end
  if send(protocol.write_step(p.pattern, state.step, time, pitch)) then
    clear_snapshot()
    status("Step sent. Use Fetch to verify the actual hardware state.")
  end
end

local function write_ratchet()
  local p = require_snapshot()
  if not p then return end
  local count = ({0, 2, 3})[display.ratchet_select.value]
  if not confirm_write("Edit ratchet", string.format(
      "Group %d, pattern %d, step %d: %dx",
      state.group + 1, p.pattern + 1, state.step + 1, count)) then return end
  if send(protocol.write_ratchet(p.pattern, state.step, count)) then
    clear_snapshot()
    status("Ratchet sent. Fetch to verify.")
  end
end

local function write_length()
  local p = require_snapshot()
  if not p then return end
  local length = display.length_select.value
  if p.triplet and length > 24 then
    error_message("Triplet patterns cannot exceed 24 steps")
    return
  end
  if not confirm_write("Change length", string.format(
      "Group %d, pattern %d: %d -> %d steps", state.group + 1, p.pattern + 1,
      p.length, length)) then return end
  if send(protocol.write_length(p.pattern, length, p.triplet)) then
    clear_snapshot()
    status("Length sent. Fetch to verify.")
  end
end

local function make_ui()
  vb = renoise.ViewBuilder()
  local function text_view(value)
    return vb:text {text = value}
  end
  local function label_row(label, control)
    return vb:row {spacing = 8, views = {vb:text {text = label, width = 112}, control}}
  end
  display.in_select = vb:popup {items = {"(no inputs)"}, width = 270,
    notifier = close_ports}
  display.out_select = vb:popup {items = {"(no outputs)"}, width = 270,
    notifier = close_ports}
  display.connection = text_view("Disconnected")
  display.group_info = text_view("Hardware group unknown")
  display.config_info = text_view("No config read yet")
  display.status = text_view("Connect a MIDI input and output to start")
  display.pattern_info = text_view("No verified pattern loaded")
  display.pattern_select = vb:valuebox {min = 1, max = 16, value = 1, width = 80,
    notifier = function() clear_snapshot() end}
  display.variation_select = vb:popup {items = {"1 - CV", "2 - MIDI", "3 - MIDI / Poly"},
    value = 1, width = 130, notifier = function() clear_snapshot() end}
  display.step_select = vb:valuebox {min = 1, max = 32, value = 1, width = 80,
    notifier = function(value)
      state.step = value - 1
      if state.pattern then update_controls() end
    end}
  display.time_select = vb:popup {items = {"REST", "NOTE", "TIE"}, value = 2, width = 100}
  display.note_select = vb:popup {
    items = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B", "High C"},
    value = 1, width = 100}
  display.octave_select = vb:popup {items = {"-1", "0", "+1", "+2"},
    value = 2, width = 95}
  display.accent_select = vb:checkbox {value = false}
  display.slide_select = vb:checkbox {value = false}
  display.ratchet_select = vb:popup {items = {"Off", "2x", "3x"}, value = 1}
  display.length_select = vb:valuebox {min = 1, max = 32, value = 16, width = 80}

  display.write_step = vb:button {text = "Write step", active = false,
    notifier = write_step}
  display.write_ratchet = vb:button {text = "Write ratchet", active = false,
    notifier = write_ratchet}
  display.write_length = vb:button {text = "Write length", active = false,
    notifier = write_length}

  return vb:column {margin = 10, spacing = 8, views = {
    text_view("SuperOS-303 | Hardware MIDI / SysEx"),
    label_row("MIDI Input", display.in_select),
    label_row("MIDI Output", display.out_select),
    vb:row {spacing = 8, views = {
      vb:button {text = "Refresh ports", notifier = refresh_ports},
      vb:button {text = "Connect", notifier = connect},
      vb:button {text = "Disconnect", notifier = close_ports},
      vb:button {text = "Read config", notifier = function()
        if device and device:is_open() then send(protocol.request_config()) end
      end}
    }},
    display.connection, display.config_info, display.group_info,
    vb:row {spacing = 8, views = {
      text_view("Pattern"), display.pattern_select,
      text_view("Variation"), display.variation_select,
      vb:button {text = "Fetch", notifier = function()
        if state.group == nil then
          error_message("Read config and receive the hardware group first")
          return
        end
        clear_snapshot()
        send(protocol.request_pattern(selected_pattern(), requested_variation()))
      end},
      vb:button {text = "Queue pattern", notifier = function()
        if not device or not device:is_open() or state.group == nil then
          error_message("Connect and read group first")
          return
        end
        local pat = selected_pattern()
        if confirm_write("Queue pattern",
            string.format("Group %d, pattern %d", state.group + 1, pat + 1)) then
          send(protocol.queue_pattern(pat))
        end
      end},
      vb:button {text = "Set edit variation", notifier = function()
        if not device or not device:is_open() or state.group == nil then
          error_message("Connect and read group first")
          return
        end
        if confirm_write("Set hardware edit variation",
            string.format("Pattern %d, variation %d", selected_pattern() + 1,
              requested_variation() + 1)) then
          send(protocol.select_variation(selected_pattern(), requested_variation()))
        end
      end}
    }},
    display.pattern_info,
    label_row("Step", display.step_select),
    vb:row {spacing = 8, views = {
      text_view("Time"), display.time_select,
      text_view("Note"), display.note_select,
      text_view("Octave"), display.octave_select,
      text_view("Accent"), display.accent_select,
      text_view("Slide"), display.slide_select
    }},
    vb:row {spacing = 8, views = {display.write_step,
      text_view("Ratchet"), display.ratchet_select, display.write_ratchet,
      text_view("Length"), display.length_select, display.write_length}},
    text_view("Writes require confirmation. Re-fetch after each write."),
    text_view("Variations 2/3 are read-only. No firmware update commands."),
    display.status
  }}
end

function M.show()
  if dialog and dialog.visible then dialog:show() return end
  device = device or Transport.new(on_event)
  close_ports()
  local view = make_ui()
  refresh_ports()
  dialog = renoise.app():show_custom_dialog("SuperOS-303", view)
end

return M
