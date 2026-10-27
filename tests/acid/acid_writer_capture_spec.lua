-- Verify fixture selection, writer delegation and metadata without audio claims.
dofile("tests/bootstrap.lua")("acid")
local sample = { sample_buffer = { has_sample_data = true }, modulation_set_index = 0,
  sample_mapping = { note_range = {0,119}, velocity_range = {0,127} } }
local instrument = { name = "ACID ARTICULATION PROBE", samples = { sample },
  phrases = {{},{},{},{},{},{},{}}, trigger_options = {}, phrase_playback_mode = 2 }
local song = { instruments = { instrument }, transport = {} }
renoise = { song = function() return song end, Instrument = { PHRASES_PLAY_SELECTIVE = 2 },
  tool = function() return { app_idle_observable = {} } end }
local output, closed, callback, received, refusal, synchronous_failure
local original_open = io.open
io.open = function(path, mode)
  if path:find("/tmp/acid-articulation/", 1, true) then
    if mode == "rb" then return nil end
    output, closed = "", false
    return {
      write = function(_, text) assert(not closed); output = output .. text; return true end,
      flush = function() end,
      close = function() closed = true end,
    }
  end
  return original_open(path, mode)
end
local mock = assert((loadstring or load)([[
  return function(index, callback, mode, source, target)
    return ACID_CAPTURE_WRITER_TEST(index, callback, mode, source, target)
  end
]], "@com.david303ttl.ACID.xrnx/writers/phrase_writer.lua"))()
ACID_CAPTURE_WRITER_TEST = function(index, cb, mode, source, target)
  received = { index = index, mode = mode, source = source, target = target }
  callback = cb
  if synchronous_failure then
    cb("GENERATION FAILED\nsynchronous native setup failure")
    return nil, "synchronous native setup failure"
  end
  if refusal then return nil, refusal end
  return true
end
local original_writer = package.loaded["writers.phrase_writer"]
package.loaded["writers.phrase_writer"] = { generate = mock }
local function run(id, mode)
  ACID_ARTICULATION_CASE_ID = id
  ACID_ARTICULATION_WRITER_MODE = mode
  dofile("./tests/acid/renoise_articulation_writer.lua")
end
run("repeat_slide_seam_length_17", "slide")
assert(received.index == 1 and received.target == 8 and received.mode == "slide")
assert(received.source.playback == "loop" and received.source.length == 17)
assert(received.source.pitch_events[1].slide and received.source.time_events[17] == "T")
assert(output:find("generation_result=pending", 1, true) and not closed)
callback("GENERATION FAILED\nnative rendering error")
assert(closed and output:find("generation_result=failed", 1, true))
local failed_output = output
callback("GENERATION FAILED\nduplicate completion")
assert(output == failed_output, "Late status changed the finalized metadata record")
synchronous_failure = true
run("isolated_note")
assert(closed and output:find("synchronous native setup failure", 1, true)
  and output:find("generation_result=failed", 1, true)
  and not output:find("generation_result=refused", 1, true),
  "Synchronous completion and nil return did not preserve the first terminal result")
synchronous_failure = nil
refusal = "Repeat slide continuity is unverified at TIME step 01"
run("repeat_slide_seam_length_17", "slide")
assert(closed and #instrument.phrases == 7)
assert(output:find("generation_result=refused", 1, true)
  and output:find(refusal, 1, true), "Native refusal was lost or bypassed")
refusal = nil
run("isolated_note")
assert(received.mode == "baseline" and received.source.playback == "one_shot")
local phrase = { name = "sealed writer phrase", number_of_lines = 1 }
function phrase:line()
  return { note_columns = {{note_value=48,instrument_value=255,volume_value=89,
    panning_value=255,delay_value=0,effect_number_value=0,effect_amount_value=0}} }
end
instrument.phrases[8] = phrase
callback("Phrase 08 generated (1 notes, 0 OFF; 1 raw events). Instrument 00.")
assert(closed and instrument.phrase_program == 8)
assert(output:find("phrase.line.1=48,255,89,255,0,0,0", 1, true),
  "Readback did not retain native quantized volume")
assert(not output:find("C:/", 1, true), "Metadata exposed a machine path")
assert(not pcall(run, "grid_calibration_all_note_pitch_span_16"),
  "Independent-native case was silently converted to writer acceptance")
assert(not pcall(run, "unknown_case"), "Unknown source case was accepted")
renoise.tool = nil
local previous_output = output
local missing_context, context_reason = pcall(run, "isolated_note")
assert(not missing_context and context_reason:find("tool scripting context", 1, true)
  and previous_output == output, "Missing tool context was not rejected before side effects")
io.open = original_open
package.loaded["writers.phrase_writer"] = original_writer
ACID_CAPTURE_WRITER_TEST = nil
ACID_ARTICULATION_CASE_ID = nil
ACID_ARTICULATION_WRITER_MODE = nil
print("ACID writer capture delegation and readback checks passed (audio unverified)")
