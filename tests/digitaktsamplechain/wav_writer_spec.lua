dofile('tests/bootstrap.lua')('digitaktsamplechain')
local wav = require("wav_writer")
local host = require("host_stub")
local function file_proxy(file, overrides)
  local proxy = {}
  for _, method in ipairs({ "write", "flush", "seek", "read", "close" }) do
    local name = method
    proxy[name] = overrides[name] or function(_, ...)
      return file[name](file, ...)
    end
  end
  return proxy
end
local function assert_commit_rejected(destination, frames, payload, expected_error)
  local writer = assert(wav.open(destination, frames, 48000))
  local temporary = writer.temporary
  assert(writer:write(payload))
  local rename, rename_calls = os.rename, 0
  os.rename = function(...)
    rename_calls = rename_calls + 1
    return rename(...)
  end
  local committed, err = writer:commit()
  os.rename = rename
  assert(not committed and err:find(expected_error, 1, true), err)
  assert(rename_calls == 0, "rejected destination must not be renamed")
  assert(writer:abort() and not io.open(temporary, "rb"))
end
local function uint(bytes, offset, length)
  local value = 0
  for index = offset + length - 1, offset, -1 do value = value * 256 + bytes:byte(index) end
  return value
end
local header = assert(wav.header(10, 48000))
assert(#header == 44 and header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WAVE")
assert(header:sub(13, 16) == "fmt " and header:sub(37, 40) == "data")
assert(uint(header, 5, 4) == 56 and uint(header, 17, 4) == 16)
assert(uint(header, 21, 2) == 1 and uint(header, 23, 2) == 1)
assert(uint(header, 25, 4) == 48000 and uint(header, 29, 4) == 96000)
assert(uint(header, 33, 2) == 2 and uint(header, 35, 2) == 16 and uint(header, 41, 4) == 20)
for _, invalid in ipairs({ 0, -1, 1.5, math.huge, 0/0, "1" }) do
  assert(not wav.assert_size(invalid))
end
assert(wav.assert_size(2147483629) and not wav.assert_size(2147483630))
assert(not wav.header(1, 0) and not wav.header(1, math.huge))

assert(wav.quantize(-1) == -32768 and wav.quantize(1) == 32767)
assert(wav.quantize(-2) == -32768 and wav.quantize(2) == 32767)
assert(wav.quantize(0.5) == 16384 and wav.quantize(-0.5) == -16384)
assert(wav.quantize(0.2) == 6554 and wav.quantize(-0.2) == -6554)
assert(wav.quantize(-0.1 / 32768) == 0, "rounding should not bias negative near-zero samples")
assert(not pcall(wav.quantize, 0/0) and not pcall(wav.quantize, math.huge))
assert(wav.quantize(0.25, function() return 0 end) == 8191)
assert(wav.quantize(0.25, function() return 0.5 end) == 8192)
assert(wav.quantize(0.25, function() return 0.999 end) == 8193)
assert(wav.quantize(0, function() error("digital silence must stay silent") end) == 0)
local rng1, rng2 = wav.new_dither(), wav.new_dither()
for _ = 1, 100 do
  local a, b = rng1(), rng2()
  assert(a == b and a >= 0 and a < 1)
end
local values = { 0.25, -0.5, 0, 1, -1 }
local payload = wav.encode(values, 1, #values)
local output_header = assert(wav.header(#values, 48000))
assert(payload == string.char(0, 32, 0, 192, 0, 0, 255, 127, 0, 128))
local all = wav.encode(values, 1, #values, wav.new_dither())
local rng = wav.new_dither()
assert(all == wav.encode(values, 1, 2, rng) .. wav.encode(values, 3, #values, rng))

local path = host.temp_path()
host.write_file(path, "original WAV")
local output = assert(wav.open(path, #values, 48000))
local temporary = output.temporary
assert(host.read_file(path) == "original WAV", "opening output must not truncate the destination")
assert(output:write(payload))
assert(host.read_file(path) == "original WAV")
assert(output:commit())
local content = host.read_file(path)
assert(#content == 44 + #payload and content:sub(1, 44) == output_header and content:sub(45) == payload)
assert(not io.open(temporary, "rb"))
assert(not output:write(payload) and not output:commit())
assert(output:abort() and host.read_file(path) == content)

-- Cancel and incomplete writes never touch the existing destination.
output = assert(wav.open(path, #values, 48000))
temporary = output.temporary
assert(not output:commit())
assert(not output:write(payload .. payload))
assert(not output:write("x"))
assert(output:write(payload:sub(1, 2)))
assert(output:abort() and output:abort())
assert(host.read_file(path) == content and not io.open(temporary, "rb"))

-- Existing destinations must stat as regular files before any rename.
local directory_destination = path .. ".destination-directory"
assert(os.mkdir(directory_destination))
assert_commit_rejected(directory_destination, #values, payload, "not a regular file")
assert(io.exists(directory_destination) and os.remove(directory_destination))

host.set_stat_type(path, "link")
assert_commit_rejected(path, #values, payload, "not a regular file")
host.set_stat_type(path, nil)
assert(host.read_file(path) == content)

local stat = io.stat
io.stat = function(name)
  if name == path then return nil, "simulated destination stat failure", 13 end
  return stat(name)
end
assert_commit_rejected(path, #values, payload, "simulated destination stat failure")
io.stat = stat
assert(host.read_file(path) == content)

-- Errors from writes, flushes and close are all surfaced and cleanable.
for _, failure in ipairs({ "write", "flush", "close" }) do
  output = assert(wav.open(path, #values, 48000))
  temporary = output.temporary
  local ok, err
  if failure == "write" then
    assert(output.file:close())
    output.file = { write = function() return nil, "simulated write" end,
      close = function() return true end }
    ok, err = output:write(payload)
  else
    assert(output:write(payload))
    local raw = output.file
    local overrides = {
      [failure] = function()
        if failure == "close" then raw:close() end
        return nil, "simulated " .. failure
      end,
    }
    output.file = file_proxy(raw, overrides)
    ok, err = output:commit()
  end
  assert(not ok and err:find("simulated " .. failure))
  output:abort()
  assert(not io.open(temporary, "rb") and host.read_file(path) == content)
end

-- Failure to remove an existing destination leaves it intact.
output = assert(wav.open(path, #values, 48000))
assert(output:write(payload))
local remove = os.remove
os.remove = function(name)
  if name == path then return nil, "simulated removal failure" end
  return remove(name)
end
local ok, committed, commit_err = pcall(output.commit, output)
os.remove = remove
assert(ok and not committed and commit_err:find("simulated removal failure", 1, true))
assert(host.read_file(path) == content)
assert(output:abort())

-- A failed final move is reported after the old destination is removed.
output = assert(wav.open(path, #values, 48000))
assert(output:write(payload))
temporary = output.temporary
local rename = os.rename
os.rename = function(from, to)
  if from == temporary then return nil, "simulated install failure" end
  return rename(from, to)
end
ok, committed, commit_err = pcall(output.commit, output)
os.rename = rename
assert(ok and not committed and commit_err:find("simulated install failure", 1, true))
assert(not io.exists(path))
assert(output:abort())
host.write_file(path, content)
local warning

-- A directory cleanup failure warns after installation and remains retryable.
output = assert(wav.open(path, #values, 48000))
assert(output:write(payload))
local directory = output.staging_directory
os.remove = function(name)
  if name == directory then return nil, "simulated directory cleanup failure" end
  return remove(name)
end
ok, committed, warning = pcall(output.commit, output)
os.remove = remove
assert(ok and committed and warning:find(directory, 1, true))
assert(warning:find("simulated directory cleanup failure", 1, true))
assert(host.read_file(path) == content and io.exists(directory))
assert(output:abort() and not io.exists(directory))

-- Header write errors close the staging file without touching the destination.
local io_open = io.open
local staged
io.open = function(name, mode)
  if mode == "wb" then
    staged = name
    local file = assert(io_open(name, mode))
    assert(file:close())
    return { write = function() return nil, "simulated header failure" end,
      close = function() return true end }
  end
  return io_open(name, mode)
end
local opened, open_err
ok, opened, open_err = pcall(wav.open, path, #values, 48000)
io.open = io_open
assert(ok and not opened and open_err:find("simulated header failure"))
assert(not io.open(staged, "rb") and host.read_file(path) == content)
assert(not wav.open(path .. "/missing/out.wav", #values, 48000))

-- A competing file appearing at reservation time is preserved and retried.
local mkdir = os.mkdir
local collision
os.mkdir = function(directory)
  if not collision then
    collision = directory
    host.write_file(directory, "competing writer")
  end
  return mkdir(directory)
end
ok, opened, open_err = pcall(wav.open, path, #values, 48000)
os.mkdir = mkdir
assert(ok and opened, open_err)
assert(host.read_file(collision) == "competing writer")
assert(opened:abort() and os.remove(collision))

-- Exhausted collisions and directory errors never truncate existing paths.
local tmpname = os.tmpname
os.tmpname = function() return "digitakt-reservation-token" end
collision = path .. ".digitakt-reservation-token.tmp"
host.write_file(collision, "existing staging path")
ok, opened, open_err = pcall(wav.open, path, #values, 48000)
os.tmpname = tmpname
assert(ok and not opened and open_err:find("reserve", 1, true))
assert(host.read_file(collision) == "existing staging path")
assert(os.remove(collision))
os.mkdir = function() return nil, "simulated directory failure" end
ok, opened, open_err = pcall(wav.open, path, #values, 48000)
os.mkdir = mkdir
assert(ok and not opened and open_err:find("simulated directory failure", 1, true))

-- Failed file creation releases its reservation; cleanup failures name the path.
for _, cleanup_failure in ipairs({ false, true }) do
  local directory
  io.open = function(name, mode)
    if mode == "wb" then
      directory = name:match("^(.*)/audio.wav$")
      return nil, "simulated open failure"
    end
    return io_open(name, mode)
  end
  os.remove = function(name)
    if cleanup_failure and name == directory then return nil, "simulated directory cleanup failure" end
    return remove(name)
  end
  ok, opened, open_err = pcall(wav.open, path, #values, 48000)
  io.open, os.remove = io_open, remove
  assert(ok and not opened and open_err:find("simulated open failure", 1, true))
  if cleanup_failure then
    assert(open_err:find(directory, 1, true) and open_err:find("simulated directory cleanup failure", 1, true))
    assert(remove(directory))
  end
  host.assert_no_staging_directories()
end
assert(host.read_file(path) == content)
assert(os.remove(path))
host.assert_no_staging_directories()
print("DigitaktSampleChain PCM, dither and staged file specs passed")
