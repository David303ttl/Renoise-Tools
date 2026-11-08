-- SPDX-License-Identifier: GPL-3.0-only
local protocol = require("protocol")
local Transport = require("transport")
local C = require("constants")

local M = {}
local dialog, vb, device = nil, nil, nil
local state = {group = nil, config = nil, pattern = nil, selected = 0, variation = C.VARIATION_CV,
  step = 0, draft_time = C.TIME_NOTE, draft_note = C.DEFAULT_SEMITONE,
  draft_octave = C.DEFAULT_OCTAVE, draft_accent = false, draft_slide = false,
  draft_ratchet = C.RATCHET_OFF}
local ports_in, ports_out = {}, {}
local display = {}

local function pattern_name(pattern)
  return (pattern < C.PATTERNS_PER_SECTION and "A" or "B") ..
    (pattern % C.PATTERNS_PER_SECTION + C.UI_INDEX_BASE)
end

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
  return display.pattern_select.value - C.UI_INDEX_BASE
end

local function requested_variation()
  return display.variation_select.value - C.UI_INDEX_BASE
end

local function clear_snapshot()
  state.pattern = nil
  state.pending_write = nil
  if display.pattern_info then display.pattern_info.text = "No verified pattern loaded" end
  if display.write_step then display.write_step.active = false end
  if display.write_ratchet then display.write_ratchet.active = false end
  if display.write_length then display.write_length.active = false end
end

local function fetch_pattern(message, expected)
  if not device or not device:is_open() then
    error_message("Connect MIDI first")
    return false
  end
  if state.group == nil then
    error_message("Read config and receive the hardware group first")
    return false
  end
  clear_snapshot()
  state.pending_write = expected
  status(message or "Fetching selected pattern...")
  return send(protocol.request_pattern(selected_pattern(), requested_variation()))
end

local function matches_write(pattern, expected)
  if expected.kind == "length" then return pattern.length == expected.length end
  local step = protocol.step(pattern, expected.step)
  if expected.kind == "ratchet" then return step.ratchet == expected.count end
  if step.time ~= expected.time then return false end
  return step.time ~= C.TIME_NOTE or protocol.pitch(step.semitone, step.octave,
    step.accent, step.slide) == expected.pitch
end

local function update_controls()
  local p = state.pattern
  if not p then return end
  local step = math.min(state.step, p.length - 1)
  state.step = step
  display.step_select.max = p.length
  display.step_select.value = step + C.UI_INDEX_BASE
  local s = protocol.step(p, step)
  state.draft_time = (s.time <= C.TIME_TIE) and s.time or C.TIME_REST
  state.draft_note = s.semitone or C.DEFAULT_SEMITONE
  state.draft_octave = s.octave or C.DEFAULT_OCTAVE
  state.draft_accent = s.accent or false
  state.draft_slide = s.slide or false
  state.draft_ratchet = (s.ratchet == C.RATCHET_DOUBLE or s.ratchet == C.RATCHET_TRIPLE) and
    s.ratchet or C.RATCHET_OFF
  display.time_select.value = state.draft_time + C.UI_INDEX_BASE
  display.note_select.value = state.draft_note + C.UI_INDEX_BASE
  display.octave_select.value = state.draft_octave + C.UI_INDEX_BASE
  display.accent_select.value = state.draft_accent
  display.slide_select.value = state.draft_slide
  for index, count in ipairs(C.RATCHET_COUNTS) do
    if count == state.draft_ratchet then display.ratchet_select.value = index break end
  end
  display.length_select.value = p.length
  display.pattern_info.text = string.format(
    "Group %d | Pattern %s | Variation %d | %d steps%s | Step %d: %s",
    state.group + C.UI_INDEX_BASE, pattern_name(p.pattern), p.variation + C.UI_INDEX_BASE, p.length,
    p.triplet and " triplet" or "", step + C.UI_INDEX_BASE,
    C.TIME_NAMES[s.time + C.UI_INDEX_BASE])
  local editable = p.variation == C.VARIATION_CV and p.pattern == selected_pattern() and
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
      event.var2_channel, event.var3_channel,
      protocol.has_flag(event.flags, C.CONFIG_FLAG.CLOCK) and "on" or "off",
      protocol.has_flag(event.flags, C.CONFIG_FLAG.THRU) and "on" or "off",
      protocol.has_flag(event.flags, C.CONFIG_FLAG.RX_DISABLED) and "off" or "on",
      protocol.has_flag(event.flags, C.CONFIG_FLAG.TX_DISABLED) and "off" or "on")
    status("Configuration received")
  elseif event.type == "group" then
    if state.group ~= event.group then
      state.group = event.group
      state.active_pattern = nil
      clear_snapshot()
      display.active_info.text = "Active hardware pattern unknown; start playback or select a pattern on the 303"
      display.group_info.text = "Hardware group " .. (event.group + C.UI_INDEX_BASE) ..
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
    local expected = state.pending_write
    state.pending_write = nil
    state.pattern = event
    update_controls()
    if expected then
      status(matches_write(event, expected) and "Write confirmed by hardware readback" or
        "Write not confirmed: hardware returned a different value. Hardware state shown.")
    else
      status("Pattern received and checksum verified")
    end
  elseif event.type == "changed" then
    if state.pattern and event.pattern == state.pattern.pattern and
       event.variation == state.pattern.variation then
      fetch_pattern("Hardware edited this pattern. Reading back hardware state...")
    end
  elseif event.type == "ack" then
    status(event.status == C.ACK_OK and "Device ACK" or
      ("Device NAK (" .. event.status .. ")"))
  elseif event.type == "active" or event.type == "position" then
    if event.group ~= nil and event.group < C.GROUPS then
      on_event({type = "group", group = event.group})
      state.active_pattern = event.pattern
      display.active_info.text = string.format("Hardware reports group %d, pattern %s",
        event.group + C.UI_INDEX_BASE, pattern_name(event.pattern))
    end
  end
end

local function close_ports()
  if device then device:close() end
  state.config, state.group, state.active_pattern = nil, nil, nil
  clear_snapshot()
  if display.connection then display.connection.text = "Disconnected" end
  if display.group_info then display.group_info.text = "Hardware group unknown" end
  if display.active_info then display.active_info.text = "Active hardware pattern unknown" end
  if display.config_info then display.config_info.text = "No config read yet" end
end

local function refresh_ports()
  close_ports()
  ports_in = renoise.Midi.available_input_devices()
  ports_out = renoise.Midi.available_output_devices()
  -- Popup values are 1-based. Empty device lists are represented by a placeholder.
  display.in_select.items = #ports_in > 0 and ports_in or {"(no inputs)"}
  display.out_select.items = #ports_out > 0 and ports_out or {"(no outputs)"}
  display.in_select.value, display.out_select.value = C.UI_INDEX_BASE, C.UI_INDEX_BASE
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
  if p.variation ~= C.VARIATION_CV then
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
  local time = display.time_select.value - C.UI_INDEX_BASE
  local pitch = protocol.PITCH_EMPTY
  if time == C.TIME_NOTE then
    pitch = protocol.pitch(display.note_select.value - C.UI_INDEX_BASE,
      display.octave_select.value - C.UI_INDEX_BASE,
      display.accent_select.value, display.slide_select.value)
  end
  if send(protocol.write_step(p.pattern, state.step, time, pitch)) then
    fetch_pattern("Step sent. Reading back hardware state...",
      {kind = "step", step = state.step, time = time, pitch = pitch})
  end
end

local function write_ratchet()
  local p = require_snapshot()
  if not p then return end
  local count = C.RATCHET_COUNTS[display.ratchet_select.value]
  if send(protocol.write_ratchet(p.pattern, state.step, count)) then
    fetch_pattern("Ratchet sent. Reading back hardware state...",
      {kind = "ratchet", step = state.step, count = count})
  end
end

local function write_length()
  local p = require_snapshot()
  if not p then return end
  local length = display.length_select.value
  if p.triplet and length > C.TRIPLET_STEPS then
    error_message(string.format("Triplet patterns cannot exceed %d steps", C.TRIPLET_STEPS))
    return
  end
  if send(protocol.write_length(p.pattern, length, p.triplet)) then
    fetch_pattern("Length sent. Reading back hardware state...",
      {kind = "length", length = length})
  end
end

local function make_ui()
  vb = renoise.ViewBuilder()
  local function text_view(value)
    return vb:text {text = value}
  end
  local function label_row(label, control)
    return vb:row {spacing = C.UI_SPACING, views = {vb:text {text = label, width = C.UI_LABEL_WIDTH}, control}}
  end
  display.in_select = vb:popup {items = {"(no inputs)"}, width = C.UI_PORT_WIDTH,
    notifier = close_ports}
  display.out_select = vb:popup {items = {"(no outputs)"}, width = C.UI_PORT_WIDTH,
    notifier = close_ports}
  display.connection = text_view("Disconnected")
  display.group_info = text_view("Hardware group unknown")
  display.active_info = text_view("Active hardware pattern unknown")
  display.config_info = text_view("No config read yet")
  display.status = text_view("Connect a MIDI input and output to start")
  display.pattern_info = text_view("No verified pattern loaded")
  local patterns = {}
  for pattern = 0, C.PATTERNS - 1 do patterns[#patterns + 1] = pattern_name(pattern) end
  display.pattern_select = vb:popup {items = patterns, value = C.UI_INDEX_BASE, width = C.UI_ADDRESS_WIDTH,
    notifier = function() clear_snapshot() end}
  display.variation_select = vb:popup {items = {"1 - CV", "2 - MIDI", "3 - MIDI / Poly"},
    value = C.UI_INDEX_BASE, width = C.UI_VARIATION_WIDTH, notifier = function() clear_snapshot() end}
  display.step_select = vb:valuebox {min = C.UI_INDEX_BASE, max = C.STEPS,
    value = C.UI_INDEX_BASE, width = C.UI_ADDRESS_WIDTH,
    notifier = function(value)
      state.step = value - C.UI_INDEX_BASE
      if state.pattern then update_controls() end
    end}
  display.time_select = vb:popup {items = {"REST", "NOTE", "TIE"},
    value = C.TIME_NOTE + C.UI_INDEX_BASE, width = C.UI_NOTE_WIDTH}
  display.note_select = vb:popup {
    items = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B", "High C"},
    value = C.DEFAULT_SEMITONE + C.UI_INDEX_BASE, width = C.UI_NOTE_WIDTH}
  display.octave_select = vb:popup {items = {"-1", "0", "+1", "+2"},
    value = C.DEFAULT_OCTAVE + C.UI_INDEX_BASE, width = C.UI_OCTAVE_WIDTH}
  display.accent_select = vb:checkbox {value = false}
  display.slide_select = vb:checkbox {value = false}
  display.ratchet_select = vb:popup {items = {"Off", "2x", "3x"}, value = C.UI_INDEX_BASE}
  display.length_select = vb:valuebox {min = C.MIN_LENGTH, max = C.STEPS,
    value = C.DEFAULT_LENGTH, width = C.UI_ADDRESS_WIDTH}

  display.write_step = vb:button {text = "Write step", active = false,
    notifier = write_step}
  display.write_ratchet = vb:button {text = "Write ratchet", active = false,
    notifier = write_ratchet}
  display.write_length = vb:button {text = "Write length", active = false,
    notifier = write_length}

  return vb:column {margin = C.UI_MARGIN, spacing = C.UI_SPACING, views = {
    text_view("SuperOS-303 | Hardware MIDI / SysEx"),
    label_row("MIDI Input", display.in_select),
    label_row("MIDI Output", display.out_select),
    vb:row {spacing = C.UI_SPACING, views = {
      vb:button {text = "Refresh ports", notifier = refresh_ports},
      vb:button {text = "Connect", notifier = connect},
      vb:button {text = "Disconnect", notifier = close_ports},
      vb:button {text = "Read config", notifier = function()
        if device and device:is_open() then send(protocol.request_config()) end
      end}
    }},
    display.connection, display.config_info, display.group_info, display.active_info,
    vb:row {spacing = C.UI_SPACING, views = {
      text_view("Pattern"), display.pattern_select,
      text_view("Variation"), display.variation_select,
      vb:button {text = "Fetch", notifier = function()
        fetch_pattern()
      end},
      vb:button {text = "Use hardware pattern", notifier = function()
        if state.active_pattern == nil then
          status("Start playback or select a pattern on the 303 to identify its active pattern")
          return
        end
        display.pattern_select.value = state.active_pattern + C.UI_INDEX_BASE
        fetch_pattern()
      end},
      vb:button {text = "Queue pattern", notifier = function()
        if not device or not device:is_open() or state.group == nil then
          error_message("Connect and read group first")
          return
        end
        local pat = selected_pattern()
        if confirm_write("Queue pattern",
            string.format("Group %d, pattern %s", state.group + C.UI_INDEX_BASE, pattern_name(pat))) then
          send(protocol.queue_pattern(pat))
        end
      end},
      vb:button {text = "Set edit variation", notifier = function()
        if not device or not device:is_open() or state.group == nil then
          error_message("Connect and read group first")
          return
        end
        if confirm_write("Set hardware edit variation",
            string.format("Pattern %s, variation %d", pattern_name(selected_pattern()),
              requested_variation() + C.UI_INDEX_BASE)) then
          send(protocol.select_variation(selected_pattern(), requested_variation()))
        end
      end}
    }},
    display.pattern_info,
    label_row("Step", display.step_select),
    vb:row {spacing = C.UI_SPACING, views = {
      text_view("Time"), display.time_select,
      text_view("Note"), display.note_select,
      text_view("Octave"), display.octave_select,
      text_view("Accent"), display.accent_select,
      text_view("Slide"), display.slide_select
    }},
    vb:row {spacing = C.UI_SPACING, views = {display.write_step,
      text_view("Ratchet"), display.ratchet_select, display.write_ratchet,
      text_view("Length"), display.length_select, display.write_length}},
    text_view("Write buttons apply immediately and read back automatically. Fetch to retry."),
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
