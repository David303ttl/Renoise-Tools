-- SPDX-License-Identifier: GPL-3.0-only
local Monitor = require("monitor")
local C = require("constants")
local monitor = Monitor.new()
local dialog, input_select, output_select, log_view, status, counts, thru
local inputs, outputs = {}, {}

local function set_status(text)
  if status then status.text = text end
end

local function disconnect()
  monitor:close()
  if thru then thru.value = false end
  set_status("Disconnected")
end

local function refresh()
  disconnect()
  inputs = renoise.Midi.available_input_devices()
  outputs = renoise.Midi.available_output_devices()
  input_select.items = #inputs > 0 and inputs or {"(no inputs)"}
  local items = {"(no output)"}
  for _, name in ipairs(outputs) do items[#items + 1] = name end
  output_select.items = items
  input_select.value, output_select.value = 1, 1
end

local function flush()
  if not dialog or not dialog.visible or not monitor.dirty then return end
  log_view.text = monitor:text()
  log_view:scroll_to_last_line()
  thru.value = monitor.thru
  monitor.dirty = false
  if monitor.input then
    counts.text = string.format("RX %d | TX %d | Last %d messages",
      monitor.rx, monitor.tx, #monitor.lines)
  end
end

local function show()
  if dialog and dialog.visible then dialog:show() return end
  local vb = renoise.ViewBuilder()
  status = vb:text {text = "Disconnected", width = C.LOG_WIDTH}
  counts = vb:text {text = "", width = C.LOG_WIDTH}
  input_select = vb:popup {items = {"(no inputs)"}, width = C.PORT_WIDTH, notifier = disconnect}
  output_select = vb:popup {items = {"(no output)"}, width = C.PORT_WIDTH, notifier = disconnect}
  log_view = vb:multiline_text {text = "", width = C.LOG_WIDTH, height = C.LOG_HEIGHT,
    font = "mono", style = "border"}
  thru = vb:checkbox {value = monitor.thru, notifier = function(value)
    if value and (not monitor.input or not monitor.output) then
      thru.value = false
      set_status("Connect an input and output before enabling Thru")
      return
    end
    monitor.thru = value
  end}
  local message = vb:textfield {text = "F0 7D 20 F7", width = C.SEND_WIDTH}
  local function row(children) return vb:row {spacing = C.SPACING, views = children} end
  local content = vb:column {margin = C.MARGIN, spacing = C.SPACING, views = {
    row {
      vb:text {text = "RX input", width = C.PORT_LABEL_WIDTH}, input_select,
      vb:text {text = "TX output", width = C.PORT_LABEL_WIDTH}, output_select},
    row {
      vb:button {text = "Refresh ports", notifier = refresh},
      vb:button {text = "Connect", notifier = function()
        local ok, issue = monitor:open(inputs[input_select.value], outputs[output_select.value - 1])
        thru.value = false
        set_status(ok and "Capturing" or issue)
      end},
      vb:button {text = "Disconnect", notifier = disconnect},
      thru, vb:text {text = "Thru: forward RX to TX"},
      vb:checkbox {value = monitor.show_clock, notifier = function(value) monitor.show_clock = value end},
      vb:text {text = "Show MIDI clock"}},
    vb:text {text = "TX logs sends from this monitor. Other Renoise output requires a virtual MIDI loopback."},
    status, counts, log_view,
    row {
      vb:text {text = "Send hex"}, message,
      vb:button {text = "Send", notifier = function()
        local bytes, issue = Monitor.parse(message.text)
        if not bytes then set_status(issue) return end
        local ok, send_issue = monitor:send(bytes)
        if not ok then set_status(send_issue) end
      end}},
    row {
      vb:button {text = "Clear", notifier = function() monitor:clear() end},
      vb:button {text = "Save log...", notifier = function()
        local path = renoise.app():prompt_for_filename_to_write("log", "Save MIDI log")
        if path == "" then return end
        local ok, issue = monitor:save(path)
        set_status(ok and "Log saved" or ("Cannot save log: " .. tostring(issue)))
      end},
      vb:text {text = "Capture continues in the background and when this window is closed. Disconnect to stop."}}
  }}
  refresh()
  monitor.dirty = true
  dialog = renoise.app():show_custom_dialog("MIDI Monitor", content)
  flush()
end

renoise.tool():add_menu_entry {name = "Main Menu:Tools:MIDI Monitor...", invoke = show}
renoise.tool():add_keybinding {name = "Global:MIDI Monitor:Show", invoke = show}
renoise.tool():add_timer(flush, C.REFRESH_MS)
renoise.tool().tool_will_unload_observable:add_notifier(disconnect)
