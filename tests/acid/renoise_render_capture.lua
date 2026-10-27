-- Render an explicit song section to a new WAV and retain its settings.
local song = assert(renoise.song(), "Open the disposable ACID song first")

local output_path = assert(rawget(_G, "ACID_RENDER_OUTPUT_PATH"),
  "Set ACID_RENDER_OUTPUT_PATH to a new absolute WAV path")
local start_sequence = assert(rawget(_G, "ACID_RENDER_START_SEQUENCE"),
  "Set ACID_RENDER_START_SEQUENCE")
local start_line = assert(rawget(_G, "ACID_RENDER_START_LINE"), "Set ACID_RENDER_START_LINE")
local end_sequence = assert(rawget(_G, "ACID_RENDER_END_SEQUENCE"), "Set ACID_RENDER_END_SEQUENCE")
local end_line = assert(rawget(_G, "ACID_RENDER_END_LINE"), "Set ACID_RENDER_END_LINE")
local sample_rate = rawget(_G, "ACID_RENDER_SAMPLE_RATE") or 48000
local bit_depth = rawget(_G, "ACID_RENDER_BIT_DEPTH") or 24
local interpolation = rawget(_G, "ACID_RENDER_INTERPOLATION") or "precise"
local priority = rawget(_G, "ACID_RENDER_PRIORITY") or "high"
local source_song_sha256 = rawget(_G, "ACID_RENDER_SOURCE_SONG_SHA256")
local source_sample_sha256 = rawget(_G, "ACID_RENDER_SOURCE_SAMPLE_SHA256")
local writer_record = rawget(_G, "ACID_RENDER_WRITER_RECORD")
local capture_context = rawget(_G, "ACID_RENDER_CONTEXT")
_G.ACID_RENDER_CONTEXT = nil

assert(not song.rendering, "A Renoise render is already in progress")

local absolute_path = type(output_path) == "string" and (
  output_path:match("^%a:/") or output_path:match("^%a:\\")
  or output_path:sub(1, 1) == "/" or output_path:sub(1, 2) == "\\\\")
assert(absolute_path and output_path:match("%.wav$")
  and not output_path:find("[\r\n]"), "Output path must be a WAV filename")
assert(type(start_sequence) == "number" and start_sequence == math.floor(start_sequence)
  and start_sequence >= 1 and start_sequence <= #song.sequencer.pattern_sequence,
  "Invalid start sequence")
assert(type(end_sequence) == "number" and end_sequence == math.floor(end_sequence)
  and end_sequence >= 1 and end_sequence <= #song.sequencer.pattern_sequence,
  "Invalid end sequence")
local start_pattern_index = song.sequencer:pattern(start_sequence)
local end_pattern_index = song.sequencer:pattern(end_sequence)
assert(type(start_line) == "number" and start_line == math.floor(start_line)
  and start_line >= 1 and start_line <= song.patterns[start_pattern_index].number_of_lines,
  "Invalid start line")
assert(type(end_line) == "number" and end_line == math.floor(end_line)
  and end_line >= 1 and end_line <= song.patterns[end_pattern_index].number_of_lines,
  "Invalid end line")
assert(end_sequence > start_sequence or (end_sequence == start_sequence and end_line > start_line),
  "Render end must follow its start")
assert(sample_rate == 22050 or sample_rate == 44100 or sample_rate == 48000
  or sample_rate == 88200 or sample_rate == 96000 or sample_rate == 192000,
  "Unsupported sample rate")
assert(bit_depth == 16 or bit_depth == 24 or bit_depth == 32, "Unsupported bit depth")
assert(interpolation == "default" or interpolation == "precise", "Unsupported interpolation")
assert(priority == "low" or priority == "realtime" or priority == "high", "Unsupported priority")
assert(capture_context == nil or type(capture_context) == "string",
  "Render context must be a string")
local function validate_hash(digest)
  assert(digest == nil or (type(digest) == "string"
    and #digest == 64 and not digest:find("[^%x]")),
    "Source hashes must be 64 hexadecimal characters")
end
validate_hash(source_song_sha256)
validate_hash(source_sample_sha256)

local function exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end
assert(not exists(output_path), "Refusing to overwrite an existing WAV")
local metadata_path = output_path .. ".render.txt"
assert(not exists(metadata_path), "Refusing to overwrite existing render metadata")

local rendered_lines = 0
for sequence = start_sequence, end_sequence do
  local pattern_index = song.sequencer:pattern(sequence)
  local pattern_lines = song.patterns[pattern_index].number_of_lines
  local first_line = sequence == start_sequence and start_line or 1
  local last_line = sequence == end_sequence and end_line or pattern_lines
  assert(last_line >= first_line, "Render section contains an invalid pattern range")
  rendered_lines = rendered_lines + last_line - first_line + 1
end

local metadata_snapshot = {
  source_song = tostring(song.file_name),
  renoise_version = tostring(renoise.RENOISE_VERSION or "unknown"),
  bpm = tostring(song.transport.bpm),
  lpb = tostring(song.transport.lpb),
  tpl = tostring(song.transport.tpl),
  rendered_lines = rendered_lines,
  expected_duration_ms = rendered_lines * 60000 / (song.transport.bpm * song.transport.lpb),
  duration_tolerance_ms = 2
}

local function inspect_wave_duration()
  local file, open_error = io.open(output_path, "rb")
  if not file then return nil, open_error or "could not open rendered WAV" end
  local ok, result = pcall(function()
    local function read_u32()
      local bytes = assert(file:read(4), "Truncated WAV chunk header")
      assert(#bytes == 4, "Truncated WAV chunk header")
      local a, b, c, d = bytes:byte(1, 4)
      return a + b * 256 + c * 65536 + d * 16777216
    end
    assert(file:read(4) == "RIFF", "Rendered file is not a RIFF/WAVE")
    read_u32()
    assert(file:read(4) == "WAVE", "Rendered file is not a WAVE")
    local file_size = assert(file:seek("end"), "Could not inspect rendered WAV size")
    assert(file:seek("set", 12), "Could not seek to WAV chunks")
    local sample_rate, channels, bit_depth, block_align, data_bytes
    while true do
      local chunk_id = file:read(4)
      if not chunk_id then break end
      assert(#chunk_id == 4, "Truncated WAV chunk identifier")
      local chunk_size = read_u32()
      local payload_start = assert(file:seek("cur"), "Could not inspect WAV chunk position")
      assert(payload_start + chunk_size <= file_size, "WAV chunk exceeds file size")
      if chunk_id == "fmt " then
        assert(chunk_size >= 16, "WAV format chunk is too short")
        local format = assert(file:read(16), "Truncated WAV format chunk")
        channels = format:byte(3) + format:byte(4) * 256
        sample_rate = format:byte(5) + format:byte(6) * 256
          + format:byte(7) * 65536 + format:byte(8) * 16777216
        block_align = format:byte(13) + format:byte(14) * 256
        bit_depth = format:byte(15) + format:byte(16) * 256
        assert(channels > 0, "WAV has no channels")
      elseif chunk_id == "data" then
        data_bytes = chunk_size
      end
      assert(file:seek("set", payload_start + chunk_size + chunk_size % 2),
        "Could not seek past WAV chunk")
      if sample_rate and block_align and bit_depth and data_bytes then break end
    end
    assert(sample_rate and block_align and bit_depth and data_bytes, "WAV is missing fmt or data chunk")
    assert(block_align > 0 and data_bytes % block_align == 0, "WAV data is not frame aligned")
    local frames = data_bytes / block_align
    return {
      sample_rate = sample_rate,
      channels = channels,
      bit_depth = bit_depth,
      frames = frames,
      duration_ms = frames * 1000 / sample_rate
    }
  end)
  file:close()
  if not ok then return nil, tostring(result) end
  return result
end

local function write_metadata(status, message, duration)
  local file = assert(io.open(metadata_path, "wb"), "Could not write render metadata")
  file:write("format=ACID-RENDER-1\n")
  file:write("status=" .. status .. "\n")
  file:write("source_song=" .. metadata_snapshot.source_song:gsub("[\r\n]", " ") .. "\n")
  file:write("renoise_version=" .. metadata_snapshot.renoise_version .. "\n")
  file:write("bpm=" .. metadata_snapshot.bpm .. "\n")
  file:write("lpb=" .. metadata_snapshot.lpb .. "\n")
  file:write("tpl=" .. metadata_snapshot.tpl .. "\n")
  file:write("start_sequence=" .. tostring(start_sequence) .. "\n")
  file:write("start_line=" .. tostring(start_line) .. "\n")
  file:write("end_sequence=" .. tostring(end_sequence) .. "\n")
  file:write("end_line=" .. tostring(end_line) .. "\n")
  file:write("rendered_lines=" .. tostring(metadata_snapshot.rendered_lines) .. "\n")
  file:write("expected_duration_ms=" .. string.format("%.3f", metadata_snapshot.expected_duration_ms) .. "\n")
  file:write("duration_tolerance_ms=" .. string.format("%.3f", metadata_snapshot.duration_tolerance_ms) .. "\n")
  file:write("sample_rate=" .. tostring(sample_rate) .. "\n")
  file:write("bit_depth=" .. tostring(bit_depth) .. "\n")
  file:write("interpolation=" .. interpolation .. "\npriority=" .. priority .. "\n")
  file:write("output=" .. output_path:gsub("[\r\n]", " ") .. "\n")
  if source_song_sha256 then file:write("source_song_sha256=" .. source_song_sha256 .. "\n") end
  if source_sample_sha256 then file:write("source_sample_sha256=" .. source_sample_sha256 .. "\n") end
  if writer_record then file:write("writer_record=" .. tostring(writer_record):gsub("[\r\n]", " ") .. "\n") end
  if capture_context then file:write("capture_context=" .. capture_context:gsub("[\r\n]", " ") .. "\n") end
  if duration then
    file:write("duration_check=" .. duration.status .. "\n")
    if duration.actual then
      file:write("actual_sample_rate=" .. tostring(duration.actual.sample_rate) .. "\n")
      file:write("actual_channels=" .. tostring(duration.actual.channels) .. "\n")
      file:write("actual_bit_depth=" .. tostring(duration.actual.bit_depth) .. "\n")
      file:write("actual_frames=" .. tostring(duration.actual.frames) .. "\n")
      file:write("actual_duration_ms=" .. string.format("%.3f", duration.actual.duration_ms) .. "\n")
      file:write("duration_error_ms=" .. string.format("%.3f", duration.error_ms) .. "\n")
    end
  end
  if message then file:write("message=" .. tostring(message):gsub("[\r\n]", " ") .. "\n") end
  file:close()
end

write_metadata("pending")
local ok, err = song:render({
  start_pos = renoise.SongPos(start_sequence, start_line),
  end_pos = renoise.SongPos(end_sequence, end_line),
  sample_rate = sample_rate,
  bit_depth = bit_depth,
  interpolation = interpolation,
  priority = priority
}, output_path, function()
  local actual, inspect_error = inspect_wave_duration()
  if actual then
    local difference = math.abs(actual.duration_ms - metadata_snapshot.expected_duration_ms)
    local matches = actual.sample_rate == sample_rate and actual.channels == 2
      and actual.bit_depth == bit_depth
      and difference <= metadata_snapshot.duration_tolerance_ms
    local duration = {status = matches and "passed" or "failed", actual = actual,
      error_ms = actual.duration_ms - metadata_snapshot.expected_duration_ms}
    local message
    if not matches then
      message = "Rendered duration does not match captured section tempo"
      write_metadata("completed", message, duration)
      print("Render completed, but WAV duration does not match the captured section tempo; do not analyze it as this case.")
    else
      write_metadata("completed", nil, duration)
    end
  else
    write_metadata("completed", "WAV duration could not be verified: " .. tostring(inspect_error),
      {status = "unavailable"})
    print("Render completed, but WAV duration could not be verified; do not treat its metadata tempo as verified.")
  end
end)
if not ok then
  write_metadata("failed", err or "Renoise render did not start")
  error(err or "Renoise render did not start")
end
print("Render started: " .. output_path)
