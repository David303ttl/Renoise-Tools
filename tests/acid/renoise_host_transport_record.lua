-- Read back stop/start/seek transport state during a manual loopback capture.
local song = renoise.song()
assert(song, "Open a disposable ACID probe song first")
local sequence_index = song.selected_sequence_index
assert(sequence_index >= 1 and sequence_index <= #song.sequencer.pattern_sequence,
  "Select the lifecycle probe sequence before starting the recorder")
local pattern_index = song.sequencer:pattern(sequence_index)
local pattern = song.patterns[pattern_index]
assert(pattern and pattern.name == "ACID HOST LIFECYCLE TRANSPORT",
  "Select the ACID HOST LIFECYCLE TRANSPORT pattern first")
local interval_ms = rawget(_G, "ACID_HOST_TRANSPORT_SAMPLE_MS") or 50
local duration_seconds = rawget(_G, "ACID_HOST_TRANSPORT_RECORD_SECONDS") or 30
assert(type(interval_ms) == "number" and interval_ms >= 20 and interval_ms <= 1000
  and interval_ms == math.floor(interval_ms), "Sample interval must be an integer from 20 to 1000 ms")
assert(type(duration_seconds) == "number" and duration_seconds >= 5
  and duration_seconds <= 600, "Record duration must be between 5 and 600 seconds")

local source = debug.getinfo(1, "S").source
assert(string.sub(source, 1, 1) == "@", "Load the recorder from its file path")
local script_path = string.gsub(string.sub(source, 2), "\\", "/")
local root = assert(string.match(script_path,
  "^(.*)/tests/acid/renoise_host_transport_record.lua$"), "Could not locate the repository root")
local output_dir = root .. "/tmp/acid-articulation/host-lifecycle"
local timestamp = os.date("%Y%m%d-%H%M%S")
local output_path = output_dir .. "/transport-state-" .. timestamp .. ".csv"
local suffix = 1
local existing = io.open(output_path, "rb")
while existing do
  existing:close()
  suffix = suffix + 1
  output_path = output_dir .. "/transport-state-" .. timestamp .. "-" .. suffix .. ".csv"
  existing = io.open(output_path, "rb")
end
local output = assert(io.open(output_path, "wb"),
  "Create tmp/acid-articulation/host-lifecycle with PowerShell before starting the recorder")
output:write("sample_index,elapsed_nominal_ms,playing,sequence,line,bpm,lpb\n")
output:flush()

local tool = renoise.tool()
local sample_index = 0
local finished = false
local timer_callback
local function finish(reason)
  if finished then return end
  finished = true
  pcall(function() tool:remove_timer(timer_callback) end)
  output:write("# " .. reason .. "\n")
  output:flush()
  output:close()
  print("Transport readback saved: " .. output_path .. " (" .. tostring(sample_index) .. " samples)")
end

timer_callback = function()
  if finished then return end
  local ok, err = pcall(function()
    assert(rawequal(renoise.song(), song), "Song changed while the transport recorder was active")
    local transport = song.transport
    local pos = transport.playback_pos
    sample_index = sample_index + 1
    output:write(string.format("%d,%d,%s,%d,%d,%.6f,%d\n",
      sample_index, sample_index * interval_ms, tostring(transport.playing),
      pos.sequence, pos.line, transport.bpm, transport.lpb))
    output:flush()
  end)
  if not ok then finish("failed: " .. tostring(err)); return end
  if sample_index * interval_ms >= duration_seconds * 1000 then finish("completed") end
end
tool:add_timer(timer_callback, interval_ms)
print("Recording transport state at " .. interval_ms .. " ms nominal intervals for "
  .. duration_seconds .. " s: " .. output_path)
print("Start Audacity and song playback, then stop, restart at the same pattern start, and seek while playing.")
