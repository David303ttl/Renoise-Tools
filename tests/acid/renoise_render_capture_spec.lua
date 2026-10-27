local files, opens, handles, render_call, render_behavior

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return string.char(value % 256, math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function make_wav(sample_rate, seconds)
  local channels, bits = 2, 24
  local block_align = channels * bits / 8
  local frames = sample_rate * seconds
  local data_size = frames * block_align
  local fmt = u16(1) .. u16(channels) .. u32(sample_rate) .. u32(sample_rate * block_align)
    .. u16(block_align) .. u16(bits)
  return "RIFF" .. u32(4 + 8 + #fmt + 8 + data_size) .. "WAVEfmt " .. u32(#fmt) .. fmt
    .. "data" .. u32(data_size) .. string.rep("\0", data_size)
end

local function reset()
  files, opens, handles, render_call = {}, {}, {}, nil
  render_behavior = "complete"
  io.open = function(path, mode)
    opens[#opens + 1] = {path = path, mode = mode}
    if mode == "rb" then
      if not files[path] then return nil end
      local handle = {closed = false, position = 1}
      handles[#handles + 1] = handle
      function handle:close() self.closed = true end
      function handle:read(count)
        if self.position > #files[path] then return nil end
        local value = files[path]:sub(self.position, self.position + count - 1)
        self.position = self.position + #value
        return value
      end
      function handle:seek(whence, offset)
        offset = offset or 0
        if whence == "set" then self.position = offset + 1
        elseif whence == "cur" then self.position = self.position + offset
        elseif whence == "end" then self.position = #files[path] + offset + 1
        else return nil end
        return self.position - 1
      end
      return handle
    end
    local handle = {closed = false, content = ""}
    function handle:write(value) self.content = self.content .. value; return self end
    function handle:close()
      self.closed = true
      files[path] = self.content
    end
    return handle
  end

  local song = {
    rendering = false,
    file_name = "disposable.xrns",
    transport = {bpm = 120, lpb = 8, tpl = 12},
    patterns = {{number_of_lines = 64}, {number_of_lines = 64}},
    sequencer = {pattern_sequence = {1, 2}}
  }
  function song.sequencer:pattern(index) return self.pattern_sequence[index] end
  function song:render(options, path, callback)
    render_call = {options = options, path = path, callback = callback,
      bpm = self.transport.bpm, lpb = self.transport.lpb}
    if render_behavior == "refuse" then return false, "mock render refusal" end
    local render_bpm = render_behavior == "wrong-tempo" and 120 or self.transport.bpm
    local seconds = 64 * 60 / (render_bpm * self.transport.lpb)
    files[path] = make_wav(options.sample_rate, seconds)
    if render_behavior == "complete" or render_behavior == "wrong-tempo" then callback() end
    return true
  end
  _G.renoise = {
    song = function() return song end,
    SongPos = function(sequence, line) return {sequence = sequence, line = line} end,
    RENOISE_VERSION = "3.5.4"
  }
  _G.ACID_RENDER_OUTPUT_PATH = "C:/tmp/render-spec.wav"
  _G.ACID_RENDER_START_SEQUENCE, _G.ACID_RENDER_START_LINE = 1, 1
  _G.ACID_RENDER_END_SEQUENCE, _G.ACID_RENDER_END_LINE = 1, 64
  _G.ACID_RENDER_SOURCE_SAMPLE_SHA256 = string.rep("a", 64)
  _G.ACID_RENDER_WRITER_RECORD = "writer_case.txt"
  _G.ACID_RENDER_CONTEXT = "case=repeat;steps=256"
end

local function run()
  dofile("tests/acid/renoise_render_capture.lua")
end

local function rejected_without_metadata()
  assert(not pcall(run))
  assert(not files["C:/tmp/render-spec.wav.render.txt"], "Rejected render must not create metadata")
  assert(not render_call, "Rejected render must not start")
end

reset()
run()
assert(render_call.path == "C:/tmp/render-spec.wav")
assert(render_call.options.start_pos.sequence == 1 and render_call.options.start_pos.line == 1)
assert(render_call.options.end_pos.sequence == 1 and render_call.options.end_pos.line == 64)
assert(render_call.options.sample_rate == 48000 and render_call.options.bit_depth == 24)
assert(render_call.options.interpolation == "precise" and render_call.options.priority == "high")
local metadata = files["C:/tmp/render-spec.wav.render.txt"]
assert(metadata:find("status=completed", 1, true))
assert(metadata:find("duration_check=passed", 1, true))
assert(metadata:find("rendered_lines=64", 1, true))
assert(metadata:find("actual_duration_ms=4000.000", 1, true))
assert(metadata:find("actual_channels=2", 1, true), "WAV channel count must be recorded")
assert(not metadata:find("message=Rendered duration", 1, true))
assert(metadata:find("source_sample_sha256=" .. string.rep("a", 64), 1, true))
assert(metadata:find("writer_record=writer_case.txt", 1, true))
assert(metadata:find("capture_context=case=repeat;steps=256", 1, true))
assert(ACID_RENDER_CONTEXT == nil, "Capture context must be consumed to prevent stale metadata")

reset()
local song = renoise.song()
song.rendering = true
rejected_without_metadata()
assert(#opens == 0, "Busy-render refusal must happen before any file operation")

reset()
ACID_RENDER_START_SEQUENCE, ACID_RENDER_START_LINE = 2, 1
ACID_RENDER_END_SEQUENCE, ACID_RENDER_END_LINE = 1, 64
rejected_without_metadata()

reset()
files["C:/tmp/render-spec.wav"] = "existing"
assert(not pcall(run))
assert(not render_call)
assert(files["C:/tmp/render-spec.wav"] == "existing")
local checked = opens[#opens]
assert(checked.mode == "rb")
assert(handles[#handles].closed, "Existing output probe must close its file handle")

reset()
files["C:/tmp/render-spec.wav.render.txt"] = "existing"
assert(not pcall(run))
assert(not render_call)
assert(files["C:/tmp/render-spec.wav.render.txt"] == "existing")
assert(handles[#handles].closed, "Existing metadata probe must close its file handle")

reset()
render_behavior = "refuse"
assert(not pcall(run))
assert(files["C:/tmp/render-spec.wav.render.txt"]:find("status=failed", 1, true))
assert(files["C:/tmp/render-spec.wav.render.txt"]:find("mock render refusal", 1, true))

reset()
render_behavior = "pending"
run()
local pending = files["C:/tmp/render-spec.wav.render.txt"]
assert(pending:find("status=pending", 1, true))
renoise.song().transport.bpm = 90
renoise.song().file_name = "changed.xrns"
render_call.callback()
local completed = files["C:/tmp/render-spec.wav.render.txt"]
assert(completed:find("status=completed", 1, true))
assert(completed:find("duration_check=passed", 1, true))
assert(completed:find("bpm=120", 1, true), "Callback must use the pre-render transport snapshot")
assert(completed:find("source_song=disposable.xrns", 1, true), "Callback must use the pre-render song snapshot")

reset()
renoise.song().transport.bpm = 90
render_behavior = "wrong-tempo"
run()
local wrong_tempo = files["C:/tmp/render-spec.wav.render.txt"]
assert(wrong_tempo:find("status=completed", 1, true), "WAV export itself completed")
assert(wrong_tempo:find("duration_check=failed", 1, true),
  "A WAV rendered at the previous engine tempo must not qualify against the requested transport")
assert(wrong_tempo:find("actual_duration_ms=4000.000", 1, true))
assert(wrong_tempo:find("expected_duration_ms=5333.333", 1, true))

reset()
song = renoise.song()
song.rendering = true
song.rendering = false
ACID_RENDER_SOURCE_SONG_SHA256 = "invalid"
rejected_without_metadata()

print("ACID offline render capture checks passed")
