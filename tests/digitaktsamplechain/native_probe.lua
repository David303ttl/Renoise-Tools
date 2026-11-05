-- SPDX-License-Identifier: GPL-3.0-only
local json = require("native_json")
local runner = require("export_runner")
local settings = require("chain_options")
local tool = renoise.tool()
local RATE, BUFFER_BITS, MONO, STEREO = 48000, 32, 1, 2
local HEADER_BYTES, PCM_BYTES, FULL_SCALE, BYTE_BASE = 44, 2, 32768, 256
local GRID_COUNT, EDGE_FRAMES, LONG_FRAMES = 4, 64, 131072
local FINAL_EDIT_FRAMES = 32769
local TEST_TONE_HZ, ALIAS_TONE_HZ, TONE_LEVEL = 1000, 30000, 0.5
local SIGNAL_EDGE_FRAMES, MAX_ALIAS_RMS = 64, 0.02
local CONTROLLER_INTERVAL_MS, CASE_TIMEOUT_SECONDS = 10, 20
local CORPUS_BATCH_SIZE, CORPUS_TIMEOUT_SECONDS, VERIFY_YIELD_FRAMES = 64, 90, 4096
local SOURCE_BITS, MILLISECONDS_PER_SECOND = 16, 1000
local RIFF_CHUNK_START, CHUNK_HEADER_BYTES = 13, 8
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
local function add(name, callback, timeout)
  tests[#tests + 1] = { name = name, run = callback, timeout = timeout or CASE_TIMEOUT_SECONDS }
end
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

for _, divisions in ipairs({ 4, 8, 16, 32, 64 }) do
  for _, padded in ipairs({ false, true }) do
    local count, use_padding = divisions, padded
    add("native-grid-" .. tostring(count) .. (padded and "-padded" or ""), function()
      local source = instrument({ 3, 5, 0 })
      local options = settings.defaults()
      options.slot_count = count
      options.zero_pad = use_padding
      local edge = use_padding and EDGE_FRAMES or 0
      local slot_frames = 5 + edge * 2
      local path = output("grid-" .. tostring(count) .. "-" .. tostring(use_padding))
      local before = source.samples[1].sample_buffer:sample_data(1, 1)
      coroutine.yield()
      local original_name = source.name
      source.name = "Native export undo sentinel"
      coroutine.yield()
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
      check(undo, "undo sentinel was not registered")
      renoise.song():undo()
      check(source.name == original_name, "export added an undo entry ahead of the sentinel")
    end)
  end
end

for _, mode in ipairs({ "average", "left", "right" }) do
  local selected = mode
  add("native-stereo-" .. mode, function()
    local source = instrument({ 3 }, RATE, STEREO)
    local options = settings.defaults()
    options.mode, options.mono = "chain", selected
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
  options.mode, options.fade = "chain", true
  local path = output("fade")
  local result, failure = export(source, options, path)
  check(result and not failure, failure)
  local content = verify_wav(path, 3)
  check(pcm(content, 1) == 8192 and pcm(content, 2) == 4096 and pcm(content, 3) == 0)
end)

add("native-source-bit-depths", function()
  for _, depth in ipairs({ 16, 24, 32 }) do
    local source = instrument({ 5 })
    local buffer = source.samples[1].sample_buffer
    check(buffer:create_sample_data(RATE, depth, MONO, 5))
    buffer:prepare_sample_data_changes(false)
    for frame = 1, 5 do buffer:set_sample_data(1, frame, 0.25) end
    buffer:finalize_sample_data_changes()
    local path = output("depth-" .. depth)
    local options = settings.defaults()
    options.mode = "chain"
    local result, failure = export(source, options, path)
    check(result and not failure, failure)
    local content = verify_wav(path, 5)
    check(uint(content, 35, 2) == 16 and pcm(content, 1) == 8192)
    check(buffer.bit_depth == depth, "export changed source bit depth")
  end
end)

add("native-sliced-slot-order", function()
  local source = instrument({ 6 })
  source.samples[1]:insert_slice_marker(3)
  coroutine.yield()
  local path = output("slices")
  local result, failure = export(source, settings.defaults(), path)
  check(result and not failure, failure)
  check(result.slot_count == GRID_COUNT and #source.samples <= GRID_COUNT)
  local content = verify_wav(path, result.frames)
  local slot_frames = result.frames / result.slot_count
  for index, sample in ipairs(source.samples) do
    local buffer = sample.sample_buffer
    local expected = math.floor(buffer:sample_data(1, 1) * FULL_SCALE + 0.5)
    check(pcm(content, (index - 1) * slot_frames + 1) == expected, "slice/master slot order mismatch")
  end
end)

add("native-reproducible-dither-and-reimport", function()
  local source = instrument({ 17 })
  local options = settings.defaults()
  options.mode, options.dither = "chain", true
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
    local buffer = source.samples[1].sample_buffer
    buffer:prepare_sample_data_changes(false)
    for frame = 1, rate do
      buffer:set_sample_data(1, frame, TONE_LEVEL * math.sin(2 * math.pi * TEST_TONE_HZ * (frame - 1) / rate))
    end
    buffer:finalize_sample_data_changes()
    local options = settings.defaults()
    options.mode = "chain"
    local result, failure = export(source, options, output("converted-" .. rate))
    check(result and not failure, failure)
    check(result.frames == RATE and result.sample_rate == RATE)
    check(source.samples[1].sample_buffer.sample_rate == rate)
    local content = verify_wav(output("converted-" .. rate), RATE)
    local crossings = 0
    for frame = 2, RATE do
      if pcm(content, frame - 1) <= 0 and pcm(content, frame) > 0 then crossings = crossings + 1 end
    end
    check(math.abs(crossings - TEST_TONE_HZ) <= 1, "sample-rate conversion shifted pitch")
  end
end)

add("native-downsampling-alias-suppression", function()
  local rate = 96000
  local source = instrument({ rate }, rate)
  local buffer = source.samples[1].sample_buffer
  buffer:prepare_sample_data_changes(false)
  for frame = 1, rate do
    buffer:set_sample_data(1, frame, TONE_LEVEL * math.sin(2 * math.pi * ALIAS_TONE_HZ * (frame - 1) / rate))
  end
  buffer:finalize_sample_data_changes()
  local path = output("alias-suppression")
  local options = settings.defaults()
  options.mode = "chain"
  local result, failure = export(source, options, path)
  check(result and not failure, failure)
  local content, energy, count = verify_wav(path, RATE), 0, 0
  for frame = SIGNAL_EDGE_FRAMES + 1, RATE - SIGNAL_EDGE_FRAMES do
    local value = pcm(content, frame) / FULL_SCALE
    energy, count = energy + value * value, count + 1
  end
  local rms = math.sqrt(energy / count)
  check(rms < MAX_ALIAS_RMS, "downsampling alias energy exceeds limit")
  return { alias_rms = rms, input_frequency = ALIAS_TONE_HZ }
end)

add("native-preflight-rejections", function()
  local source = instrument({ 1, 1, 1, 1, 1 })
  local options = settings.defaults()
  options.slot_count = GRID_COUNT
  local job, err = runner.start(source, options, output("rejected-count"), {})
  check(not job and err:find("do not fit"))
  options.slot_count = nil
  job, err = runner.start(source, options, output("rejected-missing-grid"), {})
  check(not job and err:find("grid division"), "missing grid division was accepted")
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
      buffer:set_sample_data(1, 1, -0.25)
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
  local options = settings.defaults()
  options.mode = "chain"
  local result, failure = export(source, options, path, function()
    if current_job and current_job.written_frames > 0 and not edited then
      edited = true
      local buffer = source.samples[1].sample_buffer
      buffer:prepare_sample_data_changes(false)
      buffer:set_sample_data(1, 1, -0.25)
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
  verify_wav(destination, 20)
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

local function source_pcm(path)
  local content, position = read_file(path), RIFF_CHUNK_START
  while position + CHUNK_HEADER_BYTES - 1 <= #content do
    local length = uint(content, position + 4, 4)
    if content:sub(position, position + 3) == "data" then
      local payload = content:sub(position + CHUNK_HEADER_BYTES, position + CHUNK_HEADER_BYTES + length - 1)
      check(#payload == length, "truncated source PCM")
      return payload
    end
    position = position + CHUNK_HEADER_BYTES + length + length % 2
  end
  error("source WAV has no data chunk")
end

local function source_frame(payload, frame)
  local value = uint(payload, (frame - 1) * PCM_BYTES + 1, PCM_BYTES)
  return value >= FULL_SCALE and value - FULL_SCALE * 2 or value
end

if config.waveforms then
  local variants = {
    { id = "grid64", mode = "spaced", slots = CORPUS_BATCH_SIZE },
    { id = "padded", mode = "spaced", slots = CORPUS_BATCH_SIZE, pad = true },
    { id = "chain", mode = "chain" },
    { id = "fade", mode = "spaced", slots = CORPUS_BATCH_SIZE, fade = true },
    { id = "dither", mode = "spaced", slots = CORPUS_BATCH_SIZE, pad = true, dither = true },
  }
  report.waveforms = { count = #config.waveforms, batch_size = CORPUS_BATCH_SIZE }
  for first = 1, #config.waveforms, CORPUS_BATCH_SIZE do
    local batch_first = first
    local batch_last = math.min(first + CORPUS_BATCH_SIZE - 1, #config.waveforms)
    local batch_number = math.floor((first - 1) / CORPUS_BATCH_SIZE) + 1
    for _, variant in ipairs(variants) do
      local chosen = variant
      local name = string.format("single-cycle-%03d-%s", batch_number, chosen.id)
      add(name, function()
        local source = instrument({})
        local entries, longest, total = {}, 0, 0
        for file_index = batch_first, batch_last do
          local fixture = config.waveforms[file_index]
          local sample = source:insert_sample_at(#source.samples + 1)
          check(sample.sample_buffer:load_from(fixture.path), "could not load " .. fixture.name)
          sample.name = fixture.name
          local buffer = sample.sample_buffer
          check(buffer.sample_rate == RATE and buffer.number_of_channels == MONO
            and buffer.bit_depth == SOURCE_BITS, "corpus oracle requires 48 kHz mono 16-bit PCM")
          local payload = source_pcm(fixture.path)
          local frames = buffer.number_of_frames
          check(#payload == frames * PCM_BYTES)
          entries[#entries + 1] = { buffer = buffer, frames = frames, pcm = payload, name = fixture.name }
          longest, total = math.max(longest, frames), total + frames
        end
        local options = settings.defaults()
        options.mode, options.slot_count = chosen.mode, chosen.slots
        options.zero_pad, options.fade, options.dither = chosen.pad or false, chosen.fade or false, chosen.dither or false
        local path = output(name)
        local result, failure = export(source, options, path)
        check(result and not failure, failure)
        local edge = options.zero_pad and EDGE_FRAMES or 0
        local slots = options.slot_count or #entries
        local slot_frames = longest + edge * 2
        local expected_frames = options.mode == "chain" and total or slots * slot_frames
        local content = verify_wav(path, expected_frames)
        check(result.frames == expected_frames and result.total_sec == expected_frames / RATE)
        local expected_mean = options.mode == "chain" and total / #entries or slot_frames
        check(result.slot_sec == expected_mean / RATE)
        local absolute = 0
        for slot = 1, slots do
          local entry = entries[slot]
          local length = options.mode == "chain" and entry.frames or slot_frames
          local fade = entry and math.min(entry.frames,
            math.floor(RATE * settings.FADE_OUT_MS / MILLISECONDS_PER_SECOND)) or 0
          for frame = 1, length do
            local original_frame, expected = frame - edge, 0
            if entry and original_frame >= 1 and original_frame <= entry.frames then
              expected = source_frame(entry.pcm, original_frame)
              if options.fade and original_frame > entry.frames - fade then
                local gain = fade == 1 and 0 or (entry.frames - original_frame) / (fade - 1)
                expected = math.floor(expected * gain + 0.5)
              end
            end
            absolute = absolute + 1
            local actual = pcm(content, absolute)
            local tolerance = options.dither and expected ~= 0 and 1 or 0
            check(math.abs(actual - expected) <= tolerance,
              string.format("%s slot %d frame %d: expected %d, got %d", name, slot, frame, expected, actual))
            if absolute % VERIFY_YIELD_FRAMES == 0 then coroutine.yield() end
          end
        end
        check(absolute == expected_frames)
        local imported_index = #source.samples + 1
        local imported = source:insert_sample_at(imported_index).sample_buffer
        check(imported:load_from(path), "chain reimport failed")
        check(imported.sample_rate == RATE and imported.number_of_frames == expected_frames
          and imported.number_of_channels == MONO and imported.bit_depth == SOURCE_BITS)
        for frame = 1, expected_frames do
          check(imported:sample_data(1, frame) * FULL_SCALE == pcm(content, frame), "reimported audio differs")
          if frame % VERIFY_YIELD_FRAMES == 0 then coroutine.yield() end
        end
        source:delete_sample_at(imported_index)
        if options.dither then
          local repeated, repeat_error = export(source, options, output(name .. "-repeat"))
          check(repeated and not repeat_error, repeat_error)
          check(read_file(output(name .. "-repeat")) == content, "corpus dither is not reproducible")
        end
        for _, entry in ipairs(entries) do
          check(entry.buffer.number_of_frames == entry.frames and entry.buffer.sample_rate == RATE)
          for frame = 1, entry.frames do
            check(entry.buffer:sample_data(1, frame) * FULL_SCALE == source_frame(entry.pcm, frame), "source waveform changed")
          end
        end
        return {
          files = #entries, first = entries[1].name, last = entries[#entries].name,
          frames = expected_frames, seconds = expected_frames / RATE,
          slots = slots, slot_frames = options.mode == "chain" and json.null or slot_frames,
          output = name .. ".wav", reimport_verified = true,
        }
      end, CORPUS_TIMEOUT_SECONDS)
    end
  end
end

local index, fiber, deadline, completed = 0, nil, nil, false
local resetting, fresh_document = false, false
local controller
local function document_ready()
  if resetting then fresh_document = true end
end
tool.app_new_document_observable:add_notifier(document_ready)
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
  if not fresh_document then
    if not resetting then
      resetting = true
      renoise.app():new_song_no_template()
    end
    return
  end
  if tool.app_new_document_observable:has_notifier(document_ready) then
    tool.app_new_document_observable:remove_notifier(document_ready)
  end
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
    deadline = os.time() + tests[index].timeout
  end
  if os.time() > deadline then finish_case(false, "native case timeout"); return end
  local ok, detail = coroutine.resume(fiber)
  if not ok then finish_case(false, tostring(detail))
  elseif coroutine.status(fiber) == "dead" then finish_case(true, detail) end
end

tool:add_timer(controller, CONTROLLER_INTERVAL_MS)
