-- SPDX-License-Identifier: GPL-3.0-only
local protocol = require("protocol")
local Transport = require("transport")
local C = require("constants")
local model = require("pattern_model")

local M = {}
local dialog, vb, device = nil, nil, nil
local state = {group = nil, config = nil, pattern = nil, selected = 0, variation = C.VARIATION_CV,
  step = 0, draft_time = C.TIME_NOTE, draft_note = C.DEFAULT_SEMITONE,
  draft_octave = C.DEFAULT_OCTAVE, draft_accent = false, draft_slide = false,
  draft_ratchet = C.RATCHET_OFF}
local ports_in, ports_out = {}, {}
local display = {}
local grid_buttons = {}
local scale_boxes = {}
local poly_boxes = {}
local probability_boxes = {}

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
  state.probability = nil
  state.pending_probability = nil
  if display.pattern_info then display.pattern_info.text = "No verified pattern loaded" end
  if display.write_step then display.write_step.active = false end
  if display.write_ratchet then display.write_ratchet.active = false end
  if display.write_length then display.write_length.active = false end
  if display.write_metadata then display.write_metadata.active = false end
  if display.write_scale then display.write_scale.active = false end
  if display.write_poly then display.write_poly.active = false end
  if display.write_probability then display.write_probability.active = false end
  if display.grid_title then display.grid_title.text = "Fetch a pattern to view its steps" end
  for _, button in ipairs(grid_buttons) do button.text = "--" end
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
  if expected.kind == "metadata" or expected.kind == "scale" then
    for i = 1, #expected.raw do
      if pattern.raw[i] ~= expected.raw[i] then return false end
    end
    return true
  end
  if expected.kind == "length" then return pattern.length == expected.length end
  local step = model.step(pattern, expected.step)
  if expected.kind == "ratchet" then return step.ratchet == expected.count end
  if expected.kind == "poly" then
    if step.time ~= expected.time then return false end
    if expected.time ~= C.TIME_NOTE then return true end
    if step.accent ~= expected.accent or step.slide ~= expected.slide then return false end
    for i = 1, C.POLY_VOICES do
      if step.voices[i] ~= expected.voices[i] then return false end
    end
    return true
  end
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
  local s = model.step(p, step)
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
  local info = model.metadata(p)
  display.direction_select.value = math.min(info.direction, 5) + 1
  display.triplet_select.value = info.triplet
  display.transpose_select.value = info.transpose
  local is_poly = p.type == "poly"
  if not is_poly then
    local scale = model.scale(p)
    display.scale_enabled.value = scale.enabled
    for i, control in ipairs(scale_boxes) do
      control.value = protocol.has_flag(scale.mask, 2 ^ (i - 1))
    end
  end
  for i, control in ipairs(poly_boxes) do
    local value = is_poly and s.voices and s.voices[i] or C.POLY_EMPTY
    if value == nil or value == C.POLY_EMPTY then
      control.value = C.POLY_VOICES * 13 + 1
    else
      local semi, octave = value % 16, math.floor(value / 16)
      control.value = semi <= 12 and octave * 13 + semi + 1 or C.POLY_VOICES * 13 + 1
    end
  end
  local prob = state.probability
  if prob and prob.pattern == p.pattern and prob.group == p.group then
    local value = model.probability(prob.raw, step)
    for i, key in ipairs({"accent", "slide", "down", "up"}) do
      probability_boxes[i].value = value[key]
    end
    display.prob_double.value = value.double
  end
  display.pattern_info.text = string.format(
    "Group %d | Pattern %s | Variation %d%s | %d steps%s",
    state.group + C.UI_INDEX_BASE, pattern_name(p.pattern), p.variation + C.UI_INDEX_BASE,
    is_poly and " POLY" or "", p.length, info.triplet and " triplet" or "")
  display.grid_title.text = "Pattern overview (select a step to edit)"
  for index, button in ipairs(grid_buttons) do
    button.text = (index == step + 1 and ">" or "") .. model.step_label(p, index - 1)
    button.active = index <= p.length
  end
  local editable = p.pattern == selected_pattern() and
    p.variation == requested_variation() and p.group == state.group and
    device and device:is_open()
  display.write_step.active = not not (editable and not is_poly)
  display.write_ratchet.active = not not (editable and p.variation == C.VARIATION_CV)
  display.write_length.active = not not (editable and not is_poly)
  display.write_metadata.active = not not (editable and not is_poly)
  display.write_scale.active = not not (editable and not is_poly)
  display.write_poly.active = not not (editable and is_poly)
  display.write_probability.active = not not (editable and
    p.variation == C.VARIATION_CV and prob and prob.pattern == p.pattern and
    prob.group == state.group)
end

local function on_event(event)
  if event.type == "error" then
    status("Ignored invalid SysEx: " .. event.message)
  elseif event.type == "config" then
    state.config = event
    display.cfg_channel.value = event.channel
    display.cfg_clock.value = protocol.has_flag(event.flags, C.CONFIG_FLAG.CLOCK)
    display.cfg_thru.value = protocol.has_flag(event.flags, C.CONFIG_FLAG.THRU)
    display.cfg_brightness.value = event.brightness
    display.cfg_var2.value = event.var2_channel
    display.cfg_var3.value = event.var3_channel
    display.write_config.active = true
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
  elseif event.type == "probability" then
    if state.group ~= nil and state.pattern and event.pattern == state.pattern.pattern then
      event.group = state.group
      state.probability = event
      local expected = state.pending_probability
      state.pending_probability = nil
      update_controls()
      if expected then
        local actual = model.probability(event.raw, expected.step)
        local same = actual.accent == expected.accent and
          actual.slide == expected.slide and actual.down == expected.down and
          actual.up == expected.up and actual.double == expected.double
        status(same and "Probability write confirmed by hardware readback" or
          "Probability write not confirmed: hardware returned different values")
      else
        status("Probability table received and checksum verified")
      end
    end
  elseif event.type == "changed" then
    if event.command == C.COMMAND.PROBABILITY and state.pattern and
       state.pattern.variation == C.VARIATION_CV and
       state.pattern.pattern == event.pattern then
      send(protocol.request_probability(event.pattern))
      return
    end
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
  if display.write_config then display.write_config.active = false end
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
  if p.type == "poly" then return end
  local body = protocol.write_step(p.pattern, state.step, time, pitch)
  if p.variation ~= C.VARIATION_CV then
    body = protocol.write_blob(p, model.with_step(p, state.step, time, pitch))
  end
  if send(body) then
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
  local body = protocol.write_length(p.pattern, length, p.triplet)
  if p.variation ~= C.VARIATION_CV then
    body = protocol.write_blob(p, model.with_length(p, length))
  end
  if send(body) then
    fetch_pattern("Length sent. Reading back hardware state...",
      {kind = "length", length = length})
  end
end

local function write_config()
  if not device or not device:is_open() or not state.config then
    error_message("Read hardware configuration before writing")
    return
  end
  local changes = {
    channel = display.cfg_channel.value,
    clock = display.cfg_clock.value, thru = display.cfg_thru.value,
    brightness = display.cfg_brightness.value,
    var2_channel = display.cfg_var2.value, var3_channel = display.cfg_var3.value
  }
  if send(protocol.write_config(state.config, changes)) then
    status("Configuration sent. Reading hardware settings...")
    send(protocol.request_config())
  end
end

local function write_metadata()
  local p = require_snapshot()
  if not p or p.type == "poly" then return end
  local raw, issue = model.with_metadata(p, display.direction_select.value - 1,
    display.triplet_select.value, display.transpose_select.value)
  if not raw then error_message(issue) return end
  if send(protocol.write_blob(p, raw)) then
    fetch_pattern("Pattern settings sent. Reading back...", {kind = "metadata", raw = raw})
  end
end

local function write_scale()
  local p = require_snapshot()
  if not p or p.type == "poly" then return end
  local mask = 0
  for i, control in ipairs(scale_boxes) do
    if control.value then mask = mask + 2 ^ (i - 1) end
  end
  if mask == 0 then error_message("Scale must contain at least one note") return end
  local enabled = display.scale_enabled.value
  local raw = model.with_scale(p, mask, enabled)
  local body = p.variation == C.VARIATION_CV and
    protocol.write_scale(p.pattern, mask, enabled) or protocol.write_blob(p, raw)
  if send(body) then
    fetch_pattern("Scale sent. Reading back...", {kind = "scale", raw = raw})
  end
end

local function write_poly()
  local p = require_snapshot()
  if not p or p.type ~= "poly" then return end
  local time = display.time_select.value - 1
  local voices = {}
  for i, control in ipairs(poly_boxes) do
    local v = control.value - 1
    voices[i] = v >= C.POLY_VOICES * 13 and C.POLY_EMPTY or
      (v % 13 + math.floor(v / 13) * 16)
  end
  local accent, slide = display.accent_select.value, display.slide_select.value
  if send(model.with_poly_step(p, state.step, time, voices, accent, slide)) then
    fetch_pattern("Poly step sent. Reading back...", {kind = "poly", step = state.step,
      time = time, voices = voices, accent = accent, slide = slide})
  end
end

local function request_probability()
  local p = state.pattern
  if not p or p.variation ~= C.VARIATION_CV or p.type ~= "pattern" then
    error_message("Load variation 1 before requesting probabilities")
    return
  end
  send(protocol.request_probability(p.pattern))
end

local function write_probability()
  local p = require_snapshot()
  local prob = state.probability
  if not p or p.variation ~= C.VARIATION_CV or not prob or
     prob.pattern ~= p.pattern or prob.group ~= state.group then
    error_message("Fetch the probability table first")
    return
  end
  if send(protocol.write_probability(p.pattern, state.step,
      probability_boxes[1].value, probability_boxes[2].value,
      probability_boxes[3].value, probability_boxes[4].value,
      display.prob_double.value)) then
    state.pending_probability = {
      step = state.step, accent = probability_boxes[1].value,
      slide = probability_boxes[2].value, down = probability_boxes[3].value,
      up = probability_boxes[4].value, double = display.prob_double.value
    }
    state.probability = nil
    display.write_probability.active = false
    status("Probability edit sent; checking hardware table")
    if not send(protocol.request_probability(p.pattern)) then
      state.pending_probability = nil
    end
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
  display.cfg_channel = vb:valuebox {min = 0, max = 16, value = 1, width = 58}
  display.cfg_clock = vb:checkbox {value = false}
  display.cfg_thru = vb:checkbox {value = false}
  display.cfg_brightness = vb:valuebox {min = 1, max = 8, value = 8, width = 58}
  display.cfg_var2 = vb:valuebox {min = 1, max = 16, value = 2, width = 58}
  display.cfg_var3 = vb:valuebox {min = 1, max = 16, value = 3, width = 58}
  display.write_config = vb:button {text = "Write MIDI config", active = false,
    notifier = write_config}
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
  display.grid_title = text_view("Fetch a pattern to view its steps")
  grid_buttons = {}
  local grid_rows = {}
  for row_index = 0, 3 do
    local buttons = {}
    for column = 1, 8 do
      local step_number = row_index * 8 + column
      local control = vb:button {text = "--", width = 72, active = false,
        notifier = function()
          if state.pattern then
            state.step = step_number - 1
            update_controls()
          end
        end}
      grid_buttons[step_number] = control
      buttons[#buttons + 1] = control
    end
    grid_rows[#grid_rows + 1] = vb:row {spacing = 4, views = buttons}
  end
  display.grid = vb:column {spacing = 4, views = grid_rows}
  display.direction_select = vb:popup {items = model.directions, value = 1, width = 135}
  display.triplet_select = vb:checkbox {value = false}
  display.transpose_select = vb:valuebox {min = -24, max = 24, value = 0, width = 80}
  display.write_metadata = vb:button {text = "Write pattern settings", active = false,
    notifier = write_metadata}
  display.scale_enabled = vb:checkbox {value = false}
  scale_boxes = {}
  local scale_views = {}
  for index = 1, 12 do
    local control = vb:checkbox {value = true}
    scale_boxes[index] = control
    scale_views[#scale_views + 1] = vb:column {spacing = 3, views = {
      vb:text {text = model.notes[index]}, control}}
  end
  display.scale_notes = vb:row {spacing = 12, views = scale_views}
  display.write_scale = vb:button {text = "Write scale", active = false,
    notifier = write_scale}
  poly_boxes = {}
  local voice_items = {}
  for octave = 0, 3 do
    for semi = 0, 12 do
      voice_items[#voice_items + 1] = model.pitch_label(octave * 16 + semi)
    end
  end
  voice_items[#voice_items + 1] = "--"
  local poly_controls = {}
  for i = 1, 4 do
    local voice = vb:popup {items = voice_items, value = #voice_items, width = 100}
    poly_boxes[i] = voice
    poly_controls[#poly_controls + 1] = vb:text {text = "Voice " .. i}
    poly_controls[#poly_controls + 1] = voice
  end
  display.write_poly = vb:button {text = "Write poly step", active = false,
    notifier = write_poly}
  display.poly_row = vb:row {spacing = C.UI_SPACING, views = poly_controls}
  probability_boxes = {}
  local probability_views = {}
  for i, name in ipairs({"Accent", "Slide", "Down", "Up"}) do
    local control = vb:valuebox {min = 0, max = 13, value = 0, width = 63}
    probability_boxes[i] = control
    probability_views[#probability_views + 1] = vb:text {text = name}
    probability_views[#probability_views + 1] = control
  end
  display.prob_double = vb:checkbox {value = false}
  probability_views[#probability_views + 1] = vb:text {text = "Up +24"}
  probability_views[#probability_views + 1] = display.prob_double
  display.prob_row = vb:row {spacing = C.UI_SPACING, views = probability_views}
  display.write_probability = vb:button {text = "Write probability", active = false,
    notifier = write_probability}

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
    display.connection, display.config_info,
    vb:row {spacing = C.UI_SPACING, views = {
      text_view("MIDI channel"), display.cfg_channel,
      text_view("Receive clock"), display.cfg_clock,
      text_view("MIDI Thru"), display.cfg_thru,
      text_view("LED"), display.cfg_brightness}},
    vb:row {spacing = C.UI_SPACING, views = {
      text_view("Variation 2 channel"), display.cfg_var2,
      text_view("Variation 3 channel"), display.cfg_var3,
      display.write_config}},
    display.group_info, display.active_info,
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
    display.grid_title,
    display.grid,
    label_row("Step", display.step_select),
    vb:row {spacing = C.UI_SPACING, views = {
      text_view("Time"), display.time_select,
      text_view("Note"), display.note_select,
      text_view("Octave"), display.octave_select,
      text_view("Accent"), display.accent_select,
      text_view("Slide"), display.slide_select
    }},
    vb:row {spacing = C.UI_SPACING, views = {display.write_step, display.write_poly,
      text_view("Ratchet"), display.ratchet_select, display.write_ratchet,
      text_view("Length"), display.length_select, display.write_length}},
    text_view("Variation 3 poly: four independent chord voices (empty = --)"),
    display.poly_row,
    text_view("Pattern settings"),
    vb:row {spacing = C.UI_SPACING, views = {
      text_view("Direction"), display.direction_select,
      text_view("Triplet"), display.triplet_select,
      text_view("Transpose"), display.transpose_select, display.write_metadata}},
    text_view("Pitch-class scale (mono variations)"),
    vb:row {spacing = C.UI_SPACING, views = {
      text_view("Enabled"), display.scale_enabled, display.write_scale}},
    display.scale_notes,
    text_view("Variation 1 step probabilities (0-13, 13 = always)"),
    vb:row {spacing = C.UI_SPACING, views = {
      vb:button {text = "Read probabilities", notifier = request_probability},
      display.write_probability}},
    display.prob_row,
    text_view("Write commands read back from hardware. No firmware update commands."),
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
