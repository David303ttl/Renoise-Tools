-- Render an explicitly selected oracle source through the unmodified ACID writer.
local song = assert(renoise.song(), "Open the disposable ACID song copy first")
local case_id = assert(rawget(_G, "ACID_ARTICULATION_CASE_ID"), "Set ACID_ARTICULATION_CASE_ID first")
assert(type(case_id) == "string" and case_id:match("^[a-z0-9_]+$"), "Invalid case ID")
assert(type(renoise.tool) == "function" and renoise.tool()
  and renoise.tool().app_idle_observable,
  "Run in ACID's tool scripting context; the writer requires renoise.tool().app_idle_observable")
local script_source = debug.getinfo(1, "S").source:gsub("\\", "/")
local root = assert(script_source:match("^@(.*)/tests/acid/renoise_articulation_writer.lua$"),
  "Load this helper from its repository file path")
local provenance = dofile(root .. "/tests/acid/capture_provenance.lua")
local oracle_relative = rawget(_G, "ACID_ARTICULATION_ORACLE_PATH") or
  "tests/acid/fixtures/audio_cases.json"
assert(type(oracle_relative) == "string" and oracle_relative ~= ""
  and oracle_relative:sub(1,1) ~= "/" and oracle_relative:sub(1,1) ~= "\\"
  and not oracle_relative:find("[\r\n]"), "Oracle path must be repository-relative")
oracle_relative = oracle_relative:gsub("\\", "/")
for segment in oracle_relative:gmatch("[^/]+") do
  assert(segment ~= "..", "Oracle path cannot leave the repository")
end
local oracle_path = root .. "/" .. oracle_relative
local oracle = dofile(root .. "/tests/acid/fixture_json.lua").read(oracle_path)
local selected
for _, case in ipairs(oracle.cases) do
  if case.id == case_id then
    assert(not selected, "Duplicate oracle case ID")
    selected = case
  end
end
assert(selected, "Unknown oracle case ID")
assert(selected.playback.renderer == "acid-writer", "Select an acid-writer oracle case")
assert(selected.playback.trigger_mode == "selective",
  "This helper supports selective triggering only; keymapped playback needs a separate experiment")
local output_policy = rawget(_G, "ACID_ARTICULATION_OUTPUT_POLICY") or
  (selected.playback.looping and "repeat" or "play_once")
assert(output_policy == "repeat" or output_policy == "play_once", "Invalid phrase output policy")

local instrument_index
for index, candidate in ipairs(song.instruments) do
  if candidate.name == "ACID ARTICULATION PROBE" then
    assert(not instrument_index, "Multiple articulation probes exist")
    instrument_index = index
  end
end
assert(instrument_index, "Create the articulation probe instrument first")
local instrument = song.instruments[instrument_index]
assert(#instrument.samples == 1 and instrument.samples[1].sample_buffer.has_sample_data,
  "Probe must have exactly one playable reference sample")
assert(instrument.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
  "Probe must use selective phrase playback")

-- The terminal must use ACID's module context; never replace another tool's cached modules.
local old_path = package.path
package.path = root .. "/com.david303ttl.ACID.xrnx/?.lua;" .. old_path
local loaded, writer, sequencer, runtime_context, policies = pcall(function()
  return require("writers.phrase_writer"), require("model.sequencer"),
    require("runtime.context"), require("model.policies")
end)
package.path = old_path
assert(loaded, writer)
local writer_provenance = provenance.describe(root, writer.create, "writers/phrase_writer.lua")
local sequencer_provenance = provenance.describe(root, sequencer.new_pattern, "model/sequencer.lua")
local source = selected.source
local pattern = sequencer.new_pattern(source.length)
local fixture_pitch = dofile(root .. "/tests/acid/pitch_fixture.lua")
pattern.pitch_length = source.pitch_length
for index, note in ipairs(source.pitches) do
  pattern.pitch_events[index] = fixture_pitch(note)
end
for _, index in ipairs(source.accent_pitch_indices or {}) do
  pattern.pitch_events[index].accent = true
end
for _, index in ipairs(source.slide_pitch_indices or {}) do
  pattern.pitch_events[index].slide = true
end
for index, command in ipairs(source.time) do pattern.time_events[index] = command end

local output_name = "writer_" .. case_id .. "_" .. tostring(os.time()) .. ".txt"
local output_path = root .. "/tmp/acid-articulation/" .. output_name
local existing = io.open(output_path, "rb")
if existing then existing:close(); error("Refusing to overwrite an existing writer record") end
local output = assert(io.open(output_path, "wb"), "Create tmp/acid-articulation first")
local function record(key, value)
  assert(output:write(key .. "=" .. tostring(value):gsub("[\r\n]", " ") .. "\n"))
  output:flush()
end
record("format", "ACID-WRITER-CAPTURE-1")
record("case_id", case_id)
record("oracle", oracle_relative)
record("output_policy", output_policy)
record("loaded_writer_source", writer_provenance)
record("loaded_sequencer_source", sequencer_provenance)
record("capture_status", "not captured; generation metadata only")
local sample = instrument.samples[1]
for _, key in ipairs({"volume", "panning", "transpose", "fine_tune", "loop_start", "loop_end",
  "loop_mode", "loop_release", "interpolation_mode", "new_note_action", "modulation_set_index",
  "device_chain_index", "beat_sync_enabled", "oneshot", "autofade", "oversample_enabled"}) do
  record("sample." .. key, sample[key])
end
for _, key in ipairs({"sample_rate", "bit_depth", "number_of_channels", "number_of_frames"}) do
  record("buffer." .. key, sample.sample_buffer[key])
end
for _, key in ipairs({"base_note", "map_key_to_pitch", "map_velocity_to_volume"}) do
  record("mapping." .. key, sample.sample_mapping[key])
end
record("mapping.note_range", table.concat(sample.sample_mapping.note_range, ","))
record("mapping.velocity_range", table.concat(sample.sample_mapping.velocity_range, ","))
record("instrument.volume", instrument.volume)
record("instrument.transpose", instrument.transpose)
record("trigger.monophonic", instrument.trigger_options.monophonic)
record("trigger.monophonic_glide", instrument.trigger_options.monophonic_glide)
record("trigger.quantize", instrument.trigger_options.quantize)
for _, key in ipairs({"bpm", "lpb", "tpl", "track_headroom", "groove_enabled"}) do
  record("transport." .. key, song.transport[key])
end
local set_index = sample.modulation_set_index
if set_index > 0 then
  local set = instrument.sample_modulation_sets[set_index]
  record("modulation.device_count", #set.devices)
  for index, device in ipairs(set.devices) do
    record("modulation." .. index .. ".name", device.name)
    local has_points, points = pcall(function() return device.points end)
    record("modulation." .. index .. ".target", device.target)
    if has_points and points then
      for _, key in ipairs({"tempo_synced", "play_mode", "loop_mode", "length",
        "sustain_enabled", "sustain_position", "fade_amount", "operator", "bipolar"}) do
        record("envelope." .. key, device[key])
      end
      for point_index, point in ipairs(points) do
        record("envelope.point." .. point_index,
          point.time .. "," .. point.value .. "," .. point.scaling)
      end
    end
  end
end
local pb_range = policies.DEFAULT_PB_RANGE
local runtime = runtime_context.new({
  writer = writer,
  capture = function() return nil, "No editor source" end,
  sink = function(request, done)
    if request.kind == "create" then return writer.create(request, done) end
    if request.kind == "regenerate" then return writer.regenerate(request, done) end
    return false, "Request has no explicit writer operation"
  end,
  cancel = function(token, reason)
    if type(writer.cancel) ~= "function" then return false end
    return writer.cancel(token, reason)
  end,
})
runtime:attach_document(song)
runtime:open_dialog(function(result)
  if not output then return end
  record("writer_status", type(result) == "table" and result.message or result)
  if type(result) == "table" and result.kind == "success" then
    assert(result.verified == true, "Successful writer result was not verified")
    local phrase = assert(result.phrase, "Writer success did not return its destination phrase")
    local phrase_index
    for index, candidate in ipairs(instrument.phrases) do
      if rawequal(candidate, phrase) then phrase_index = index; break end
    end
    assert(phrase_index, "Generated phrase is missing")
    for _, key in ipairs({"name", "number_of_lines", "lpb", "looping", "loop_start", "loop_end"}) do
      record("phrase." .. key, phrase[key])
    end
    for line_index = 1, phrase.number_of_lines do
      local cell = phrase:line(line_index).note_columns[1]
      record("phrase.line." .. line_index, table.concat({ cell.note_value, cell.instrument_value,
        cell.volume_value, cell.panning_value, cell.delay_value,
        cell.effect_number_value, cell.effect_amount_value }, ","))
    end
    instrument.phrase_program = phrase_index
    record("selected_phrase_program", phrase_index)
    output:close()
    output = nil
    print("Writer phrase ready; metadata: tmp/acid-articulation/" .. output_name)
    print("Configure the host trigger duration separately, then capture without editing this phrase.")
  elseif type(result) == "table" and result.kind == "failure" then
    record("generation_result", "failed; do not capture")
    if result.reason then record("diagnostic", result.reason) end
    output:close()
    output = nil
  end
end)
runtime:bind_new(instrument)
local editor_ok, editor_error = runtime:transition("edit",
  {source = pattern, output_policy = output_policy, pb_range = pb_range})
if not editor_ok then
  record("generation_result", "refused")
  record("diagnostic", editor_error)
  output:close()
  output = nil
  print("Writer did not generate the case: " .. tostring(editor_error))
  print("Diagnostic record: tmp/acid-articulation/" .. output_name)
else
  local accepted, reason = runtime:request_generation("manual")
  if not accepted then
    -- A synchronous terminal callback may already have finalized the record.
    if output then
      record("generation_result", "refused")
      record("diagnostic", reason)
      output:close()
      output = nil
    end
    print("Writer did not generate the case: " .. tostring(reason))
    print("Diagnostic record: tmp/acid-articulation/" .. output_name)
  elseif output then
    record("generation_result", "pending; wait for writer_status generated before capture")
  end
end
