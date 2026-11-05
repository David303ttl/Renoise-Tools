-- SPDX-License-Identifier: GPL-3.0-only
local json = require("native_json")
local runner = require("export_runner")
local settings = require("chain_options")
local tool = renoise.tool()
local RATE, BUFFER_BITS, MONO, STEREO = 48000, 32, 1, 2
local HEADER_BYTES, PCM_BYTES, FULL_SCALE, BYTE_BASE = 44, 2, 32768, 256
local GRID_COUNT, EDGE_FRAMES, LONG_FRAMES = 4, 64, 131072
local FINAL_EDIT_FRAMES = 32769
local CONTROLLER_INTERVAL_MS, CASE_TIMEOUT_SECONDS = 10, 20
local tests, cleanups, current_job = {}, {}, nil

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = assert(file:read("*a"))
  assert(file:close())
  return content
end

local config = json.decode(read_file(tool.bundle_path .. "native-config.json"))
local report_path = config.run_directory .. "/native-report.json"
local report = {
  nonce = config.nonce, status = "RUNNING", cases = json.array(),
  renoise_version = renoise.RENOISE_VERSION, api_version = renoise.API_VERSION,
}

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  assert(file:write(content))
  assert(file:close())
end

local function save_report()
  write_file(report_path, json.encode(report))
end

local function output(name) return config.run_directory .. "/" .. name .. ".wav" end
local function check(condition, message) assert(condition, message or "native assertion failed") end
local function add(name, callback) tests[#tests + 1] = { name = name, run = callback } end
local function defer(callback) cleanups[#cleanups + 1] = callback end

local function wait_for(predicate)
  while not predicate() do coroutine.yield() end
end

local function instrument(lengths, rate, channels)
  local value = renoise.song().selected_instrument
  if #value.samples > 0 and #value.samples[1].slice_markers > 0 then
    value.samples[1].slice_markers = {}
  end
  while #value.samples > 0 do value:delete_sample_at(#value.samples) end
  for index, frames in ipairs(lengths) do
    local sample = value:insert_sample_at(index)
    if frames > 0 then
      local buffer = sample.sample_buffer
      check(buffer:create_sample_data(rate or RATE, BUFFER_BITS, channels or MONO, frames))
      buffer:prepare_sample_data_changes(false)
      for frame = 1, frames do
        buffer:set_sample_data(1, frame, math.min(1, index / GRID_COUNT))
        if channels == STEREO then buffer:set_sample_data(STEREO, frame, -index / GRID_COUNT) end
      end
      buffer:finalize_sample_data_changes()
    end
  end
  return value
end

local function export(source, options, path, progress)
  local result, failure, canceled
  current_job = assert(runner.start(source, options, path, {
    on_finish = function(info) result = info end,
    on_error = function(message) failure = message end,
    on_cancel = function(message) canceled = message end,
    on_progress = progress,
  }))
  local job = current_job
  wait_for(function() return job.finished end)
  check(not tool:has_timer(job.timer), "export timer remained registered")
  current_job = nil
  return result, failure, canceled, job
end

local function uint(content, first, count)
  local value = 0
  for index = first + count - 1, first, -1 do value = value * BYTE_BASE + content:byte(index) end
  return value
end

local function pcm(content, frame)
  local value = uint(content, HEADER_BYTES + (frame - 1) * PCM_BYTES + 1, PCM_BYTES)
  return value >= FULL_SCALE and value - FULL_SCALE * 2 or value
end

local function verify_wav(path, frames)
  local content = read_file(path)
  check(#content == HEADER_BYTES + frames * PCM_BYTES, "WAV frame count mismatch")
  check(content:sub(1, 4) == "RIFF" and content:sub(9, 12) == "WAVE", "invalid WAV container")
  check(uint(content, 25, 4) == RATE and uint(content, 23, 2) == MONO, "invalid WAV format")
  check(uint(content, 41, 4) == frames * PCM_BYTES, "invalid data chunk size")
  return content
end

add("native-menu-registration", function()
  require("production_main")
  check(tool:has_menu_entry("Sample Editor:Export Digitakt Sample Chain"), "production menu was not registered")
end)

for _, fixed in ipairs({ false, true }) do
  for _, padded in ipairs({ false, true }) do
    local use_fixed, use_padding = fixed, padded
    add("native-grid-" .. (fixed and "fixed" or "auto") .. (padded and "-padded" or ""), function()
      local source = instrument({ 3, 5, 0 })
      local options = settings.defaults()
      options.slot_count = use_fixed and GRID_COUNT or nil
      options.zero_pad = use_padding
      local count, edge = use_fixed and GRID_COUNT or 2, use_padding and EDGE_FRAMES or 0
      local slot_frames = 5 + edge * 2
      local path = output("grid-" .. tostring(use_fixed) .. "-" .. tostring(use_padding))
      local before = source.samples[1].sample_buffer:sample_data(1, 1)
      local undo = renoise.song():can_undo()
      local result, failure = export(source, options, path)
      check(result and not failure, failure)
      local content = verify_wav(path, slot_frames * count)
      for slot = 1, count do
        for frame = 1, slot_frames do
          local source_frame = frame - edge
          local length = slot == 1 and 3 or (slot == 2 and 5 or 0)
          local expected = source_frame >= 1 and source_frame <= length and slot * FULL_SCALE / GRID_COUNT or 0
          check(pcm(content, (slot - 1) * slot_frames + frame) == expected, "slot boundary/content mismatch")
        end
      end
      check(result.frames == slot_frames * count and result.slot_sec == slot_frames / RATE)
      check(result.total_sec == result.frames / RATE)
      check(source.samples[1].sample_buffer:sample_data(1, 1) == before, "source buffer changed")
      check(renoise.song():can_undo() == undo, "export changed undo availability")
    end)
  end
end

for _, mode in ipairs({ "average", "left", "right" }) do
  local selected = mode
  add("native-stereo-" .. mode, function()
    local source = instrument({ 3 }, RATE, STEREO)
    local options = settings.defaults()
    options.mono = selected
    local path = output("stereo-" .. selected)
    local result, failure = export(source, options, path)
    check(result and not failure, failure)
    local expected = selected == "left" and FULL_SCALE / GRID_COUNT
      or (selected == "right" and -FULL_SCALE / GRID_COUNT or 0)
    check(pcm(verify_wav(path, 3), 1) == expected, "native channel selection mismatch")
  end)
end

add("native-mono-right-and-chain-mean", function()
  local source = instrument({ 2, 3 })
  local options = settings.defaults()
  options.mode, options.mono, options.zero_pad, options.slot_count = "chain", "right", true, GRID_COUNT
  local path = output("chain")
  local result, failure = export(source, options, path)
  check(result and not failure, failure)
  check(result.slot_sec == 2.5 / RATE and result.total_sec == 5 / RATE)
  local content = verify_wav(path, 5)
  check(pcm(content, 1) == FULL_SCALE / GRID_COUNT and pcm(content, 3) == FULL_SCALE / 2)
end)

add("native-short-fade", function()
  local source = instrument({ 3 })
  local options = settings.defaults()
  options.fade = true
  local path = output("fade")
  local result, failure = export(source, options, path)
  check(result and not failure, failure)
  local content = verify_wav(path, 3)
  check(pcm(content, 1) == 8192 and pcm(content, 2) == 4096 and pcm(content, 3) == 0)
end)

add("native-reproducible-dither-and-reimport", function()
  local source = instrument({ 17 })
  local options = settings.defaults()
  options.dither = true
  local first, second = output("dither-first"), output("dither-second")
  local result, failure = export(source, options, first)
  check(result and not failure, failure)
  result, failure = export(source, options, second)
  check(result and not failure, failure)
  check(read_file(first) == read_file(second), "dithered native exports differ")
  local imported = source:insert_sample_at(#source.samples + 1).sample_buffer
  check(imported:load_from(first), "Renoise WAV reimport failed")
  check(imported.sample_rate == RATE and imported.number_of_channels == MONO and imported.number_of_frames == 17)
  check(math.abs(imported:sample_data(1, 1) - 0.25) <= 1 / FULL_SCALE)
end)

add("native-rate-conversion", function()
  for _, rate in ipairs({ 44100, 96000 }) do
    local source = instrument({ rate }, rate)
    local result, failure = export(source, settings.defaults(), output("converted-" .. rate))
    check(result and not failure, failure)
    check(result.frames == RATE and result.sample_rate == RATE)
    check(source.samples[1].sample_buffer.sample_rate == rate)
  end
end)

add("native-preflight-rejections", function()
  local source = instrument({ 1, 1, 1, 1, 1 })
  local options = settings.defaults()
  options.slot_count = GRID_COUNT
  local job, err = runner.start(source, options, output("rejected-count"), {})
  check(not job and err:find("do not fit"))
end)

add("native-cancel-preserves-destination", function()
  local source = instrument({ LONG_FRAMES })
  local path = output("cancel")
  write_file(path, "original")
  local canceled
  current_job = assert(runner.start(source, settings.defaults(), path, {
    on_cancel = function(message) canceled = message end,
  }))
  local job, temporary = current_job, current_job.output.temporary
  wait_for(function() return job.written_frames > 0 or job.finished end)
  check(not job.finished and read_file(path) == "original", "export was not incremental")
  job:cancel()
  check(canceled and job.finished and not tool:has_timer(job.timer))
  check(read_file(path) == "original" and not io.exists(temporary), "cancellation damaged destination or leaked staging")
  current_job = nil
end)

for _, change in ipairs({ "same-size", "resize", "sample-list", "slices" }) do
  local mutation = change
  add("native-source-change-" .. change, function()
    local source = instrument({ LONG_FRAMES })
    local sample, buffer = source.samples[1], source.samples[1].sample_buffer
    local notifications = 0
    local function observe() notifications = notifications + 1 end
    sample.sample_buffer_observable:add_notifier(observe)
    defer(function()
      if sample.sample_buffer_observable:has_notifier(observe) then
        sample.sample_buffer_observable:remove_notifier(observe)
      end
    end)
    local path = output("change-" .. mutation)
    write_file(path, "original")
    local failure, result
    current_job = assert(runner.start(source, settings.defaults(), path, {
      on_finish = function(info) result = info end,
      on_error = function(message) failure = message end,
    }))
    local job, temporary = current_job, current_job.output.temporary
    wait_for(function() return job.written_frames > 0 or job.finished end)
    if mutation == "same-size" then
      buffer:prepare_sample_data_changes()
      buffer:set_sample_data(1, LONG_FRAMES, -0.25)
      buffer:finalize_sample_data_changes()
    elseif mutation == "resize" then
      check(buffer:create_sample_data(RATE, BUFFER_BITS, MONO, LONG_FRAMES / 2))
    elseif mutation == "sample-list" then
      source:insert_sample_at(#source.samples + 1)
    else
      sample:insert_slice_marker(LONG_FRAMES / 2)
    end
    wait_for(function() return job.finished end)
    check(failure and not result, "source mutation did not reject export: " .. mutation)
    if mutation == "same-size" then check(notifications > 0, "same-size edit emitted no native buffer notification") end
    check(read_file(path) == "original" and not io.exists(temporary))
    check(not tool:has_timer(job.timer))
    current_job = nil
    return { buffer_notifications = notifications }
  end)
end

add("native-final-progress-edit-rejected", function()
  local source = instrument({ FINAL_EDIT_FRAMES })
  local path = output("final-edit")
  write_file(path, "original")
  local edited = false
  local result, failure = export(source, settings.defaults(), path, function()
    if current_job and current_job.written_frames > 0 and not edited then
      edited = true
      local buffer = source.samples[1].sample_buffer
      buffer:prepare_sample_data_changes(false)
      buffer:set_sample_data(1, FINAL_EDIT_FRAMES, -0.25)
      buffer:finalize_sample_data_changes()
    end
  end)
  check(edited and failure and not result, "final progress callback source edit was committed")
  check(read_file(path) == "original")
end)

add("native-dialog-and-export-callbacks", function()
  instrument({ 3, 5 })
  local original_builder, original_app, original_start = renoise.ViewBuilder, renoise.app, runner.start
  local app, views, dialogs, errors, jobs = original_app(), {}, {}, {}, {}
  local destination = output("gui")
  renoise.ViewBuilder = function()
    local builder = original_builder()
    return setmetatable({}, { __index = function(_, kind)
      return function(_, properties)
        local callback, text = properties.notifier, properties.text
        local view = builder[kind](builder, properties)
        views[#views + 1] = { kind = kind, view = view, callback = callback, text = text }
        return view
      end
    end })
  end
  renoise.app = function()
    return setmetatable({
      prompt_for_filename_to_write = function() return destination end,
      show_error = function(_, message) errors[#errors + 1] = message end,
      show_custom_dialog = function(_, title, content)
        local dialog = app:show_custom_dialog(title, content)
        dialogs[#dialogs + 1] = dialog
        return dialog
      end,
    }, { __index = function(_, method)
      return function(_, ...) return app[method](app, ...) end
    end })
  end
  runner.start = function(...)
    local job, err = original_start(...)
    if job then jobs[#jobs + 1] = job; current_job = job end
    return job, err
  end
  defer(function()
    for _, job in ipairs(jobs) do if not job.finished then job:cancel() end end
    for _, dialog in ipairs(dialogs) do if dialog.visible then dialog:close() end end
    renoise.ViewBuilder, renoise.app, runner.start = original_builder, original_app, original_start
    package.loaded.gui = nil
  end)
  package.loaded.gui = nil
  require("gui").show()
  coroutine.yield()
  check(dialogs[1] and dialogs[1].visible, "native dialog not visible")
  local export_button, mode, slot, padding, duration
  for _, record in ipairs(views) do
    if record.kind == "button" and record.text == "Export Chain" then export_button = record end
    if record.kind == "popup" then
      if not mode then mode = record elseif not slot then slot = record end
    end
    if record.kind == "checkbox" then padding = record end
    if record.kind == "text" and record.text == "" then duration = record.view end
  end
  check(export_button and mode and slot and padding and duration)
  export_button.callback()
  check(#jobs == 1, errors[1])
  wait_for(function() return jobs[1].finished end)
  check(#errors == 0 and duration.text:find("Slot:"), errors[1])
  check(export_button.view.active)
  verify_wav(destination, 10)
  destination = ""
  export_button.callback()
  check(#jobs == 1 and duration.text == "" and #errors == 0, "save cancel retained stale state")
  mode.callback(2)
  check(not slot.view.active and not padding.view.active, "native layout dependencies failed")
  instrument({ LONG_FRAMES })
  destination = output("gui-close")
  write_file(destination, "original")
  export_button.callback()
  check(#jobs == 2, errors[1])
  dialogs[1]:close()
  wait_for(function() return jobs[2].finished end)
  check(jobs[2].canceled and read_file(destination) == "original")
  current_job = nil
end)

add("native-document-release-cancels-export", function()
  local source = instrument({ LONG_FRAMES })
  renoise.app():save_song_as(config.run_directory .. "/disposable.xrns")
  local path = output("document-release")
  write_file(path, "original")
  local canceled
  current_job = assert(runner.start(source, settings.defaults(), path, {
    on_cancel = function(message) canceled = message end,
  }))
  local job, temporary = current_job, current_job.output.temporary
  renoise.app():new_song_no_template()
  wait_for(function() return job.finished end)
  check(canceled and job.canceled and not tool:has_timer(job.timer))
  check(read_file(path) == "original" and not io.exists(temporary))
  current_job = nil
end)

local index, fiber, deadline, completed = 0, nil, nil, false
local controller
local function finish_case(ok, detail)
  if current_job and not current_job.finished then current_job:cancel() end
  current_job = nil
  for cleanup_index = #cleanups, 1, -1 do
    local cleaned, err = pcall(cleanups[cleanup_index])
    if not cleaned then ok, detail = false, tostring(detail or "") .. "\n" .. tostring(err) end
  end
  cleanups = {}
  report.cases[#report.cases + 1] = {
    name = tests[index].name, status = ok and "PASS" or "FAIL", detail = detail,
  }
  save_report()
  fiber = nil
end

controller = function()
  if completed or not renoise.song() then return end
  if not fiber then
    index = index + 1
    if index > #tests then
      completed = true
      tool:remove_timer(controller)
      report.status = "PASS"
      for _, case in ipairs(report.cases) do if case.status ~= "PASS" then report.status = "FAIL" end end
      save_report()
      return
    end
    fiber = coroutine.create(tests[index].run)
    deadline = os.time() + CASE_TIMEOUT_SECONDS
  end
  if os.time() > deadline then finish_case(false, "native case timeout"); return end
  local ok, detail = coroutine.resume(fiber)
  if not ok then finish_case(false, tostring(detail))
  elseif coroutine.status(fiber) == "dead" then finish_case(true, detail) end
end

tool:add_timer(controller, CONTROLLER_INTERVAL_MS)
