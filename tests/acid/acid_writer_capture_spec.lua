-- Verify fixture selection, runtime writer delegation and metadata without audio claims.
dofile("tests/bootstrap.lua")("acid")
local provenance = dofile("tests/acid/capture_provenance.lua")
local repo_fn = assert((loadstring or load)("return function() end",
  "@workspace/com.david303ttl.ACID.xrnx/writers/phrase_writer.lua"))()
local installed_fn = assert((loadstring or load)("return function() end",
  "@portable-install/Tools/com.david303ttl.ACID.xrnx/writers/phrase_writer.lua"))()
assert(provenance.describe("workspace", repo_fn, "writers/phrase_writer.lua")
  == "repository/com.david303ttl.ACID.xrnx/writers/phrase_writer.lua")
assert(provenance.describe("workspace", installed_fn, "writers/phrase_writer.lua")
  == "installed/com.david303ttl.ACID.xrnx/writers/phrase_writer.lua")
local sample = { sample_buffer = { has_sample_data = true }, modulation_set_index = 0,
  sample_mapping = { note_range = {0,119}, velocity_range = {0,127} } }
local instrument = { name = "ACID ARTICULATION PROBE", samples = { sample },
  phrases = {{},{},{},{},{},{},{}}, trigger_options = {}, phrase_playback_mode = 2,
  plugin_properties = { plugin_loaded = false, alias_instrument_index = 0,
    alias_fx_track_index = 0, alias_fx_device_index = 0, midi_output_routing_index = 0 },
  midi_output_properties = { device_name = "", instrument_type = 0, channel = 1 } }
local song = { instruments = { instrument },
  transport = { timing_model = 1, lpb = 8, tpl = 12, groove_enabled = false } }
function song:is_undo_redoing() return false end
renoise = { song = function() return song end,
  Instrument = { PHRASES_PLAY_SELECTIVE = 2, MAX_NUMBER_OF_PHRASES = 126 },
  InstrumentPhrase = { MAX_NUMBER_OF_LINES = 512, MAX_NUMBER_OF_NOTE_COLUMNS = 12,
    MAX_NUMBER_OF_EFFECT_COLUMNS = 8, PLAY_PATTERN = 1, PLAY_SCRIPT = 2,
    KEY_TRACKING_NONE = 1 },
  Transport = { TIMING_MODEL_LPB = 1 },
  tool = function() return { app_idle_observable = {} } end }
local output, closed, received, refusal, synchronous_failure
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
local active, last_done, last_request, committed_baseline
local mock = assert((loadstring or load)([[
  local module={}
  function module.create(request,done)
    return ACID_CAPTURE_WRITER_TEST("create",request,done)
  end
  function module.regenerate(request,done)
    return ACID_CAPTURE_WRITER_TEST("regenerate",request,done)
  end
  function module.state() return ACID_CAPTURE_WRITER_STATE() end
  function module.is_temporary() return false end
  function module.cancel() return false end
  return module
]], "@./com.david303ttl.ACID.xrnx/writers/phrase_writer.lua"))()
ACID_CAPTURE_WRITER_STATE = function()
  if active then return "busy", active.request.token end
  return "idle", nil
end
ACID_CAPTURE_WRITER_TEST = function(kind, request, done)
  local instrument_index
  for index, candidate in ipairs(song.instruments) do
    if rawequal(candidate, request.instrument) then instrument_index = index; break end
  end
  received = { kind = kind, index = instrument_index, source = request.source,
    target = #instrument.phrases + 1, output_policy = request.output_policy,
    request = request }
  if synchronous_failure then
    done({kind="failure",status="failed",verified=false,token=request.token,
      epoch=request.epoch,request=request,phrase=nil,
      reason="synchronous native setup failure",message="synchronous native setup failure",
      diagnostics={}})
    return true
  end
  if refusal then return false, refusal end
  active = { kind = kind, request = request, done = done }
  return true
end
local function terminal(kind, status, message)
  local request = assert(last_request or (active and active.request))
  if kind == "success" then
    local phrase = instrument.phrases[#instrument.phrases]
    local baseline = assert(committed_baseline, "successful capture fixture has no retained baseline")
    return { kind = "success", status = status or "committed", verified = true,
      token = request.token, epoch = request.epoch, request = request, phrase = phrase,
      id = baseline.id, message = message, diagnostics = {}, baseline = baseline }
  end
  return { kind = "failure", status = status or "failed", verified = false,
    token = request.token, epoch = request.epoch, request = request, phrase = nil,
    reason = message, message = message, diagnostics = {} }
end
local function complete(status, message)
  local current = assert(active)
  last_request, last_done = current.request, current.done
  active = nil
  local kind = (status == "committed" or status == "approximate") and "success" or "failure"
  last_done(terminal(kind, status, message))
end
local original_writer = package.loaded["writers.phrase_writer"]
package.loaded["writers.phrase_writer"] = mock
local function run(id, output_policy)
  ACID_ARTICULATION_CASE_ID = id
  ACID_ARTICULATION_OUTPUT_POLICY = output_policy
  dofile("./tests/acid/renoise_articulation_writer.lua")
end
run("repeat_slide_seam_length_17", "repeat")
assert(received.kind == "create" and received.index == 1 and received.target == 8
  and received.output_policy == "repeat")
assert(received.request.kind == "create" and received.request.target_kind == "new")
assert(received.request.token:is_current(), "runtime issued token is not the live token")
assert(type(received.request.validate_checkpoint) == "function"
  and type(received.request.mutate) == "function",
  "runtime request did not expose its checkpoint and mutation hooks")
assert(received.source.length == 17)
assert(received.source.pitch_events[1].slide and received.source.time_events[17] == "T")
assert(output:find("generation_result=pending", 1, true) and not closed)
local live_token = received.request.token
complete("error", "native rendering error")
assert(closed and output:find("generation_result=failed", 1, true))
assert(not live_token:is_current(), "terminal completion did not retire the runtime token")
local failed_output = output
last_done(terminal("failure", "error", "duplicate completion"))
assert(output == failed_output, "Late status changed the finalized metadata record")
synchronous_failure = true
run("isolated_note")
assert(closed and output:find("synchronous native setup failure", 1, true)
  and output:find("generation_result=failed", 1, true)
  and not output:find("generation_result=refused", 1, true),
  "Synchronous completion did not preserve the first terminal result")
synchronous_failure = nil
refusal = "Selected phrase is not safely ACID-owned"
run("isolated_note", "play_once")
assert(closed and #instrument.phrases == 7)
assert(output:find("generation_result=refused", 1, true)
  and output:find(refusal, 1, true), "Native refusal was lost or bypassed")
refusal = nil
for _, id in ipairs({"one_shot_note_tail_bpm_120", "one_shot_tie_tail_bpm_120",
  "one_shot_two_ties_tail_bpm_120", "tie_before_fresh_note_bpm_120",
  "two_ties_before_fresh_note_bpm_120", "repeat_note_rest_seam_bpm_120",
  "repeat_tie_rest_seam_bpm_120"}) do
  local policy=id:find("^repeat_") and "repeat" or "play_once"
  run(id, policy)
  assert(received.output_policy == policy and received.source.pitch_events[1].note == 48)
  complete("error", "capture protocol test only")
  assert(closed, "Gate case metadata did not close after failure")
end
run("isolated_note")
assert(received.output_policy == "play_once")
local phrase = dofile("tests/acid/complete_phrase_fixture.lua")()
local fixture_line=phrase.line
function phrase:line(line_index)
  local line=fixture_line(self,line_index)
  if not line then return nil end
  for _,cell in ipairs(line.note_columns) do
    cell.is_empty=(cell.note_value==121 or cell.note_value==nil) and
      (cell.instrument_value or 255)==255 and (cell.volume_value or 255)==255 and
      (cell.panning_value or 255)==255 and (cell.delay_value or 0)==0 and
      (cell.effect_number_value or 0)==0 and (cell.effect_amount_value or 0)==0
  end
  for _,cell in ipairs(line.effect_columns) do
    cell.is_empty=(cell.number_value or 0)==0 and (cell.amount_value or 0)==0
  end
  return line
end
local phrase_request = received.request
local phrase_ownership = require("renoise.phrase_ownership")
local pattern_store = require("renoise.pattern_store")
local phrase_capabilities = require("renoise.target_capabilities")
local output_planner = require("model.output_planner")
local phrase_materializer = require("writers.phrase_materializer")
local phrase_validator = require("writers.phrase_validator")
local phrase_pitch_bend = require("writers.phrase_pitch_bend")
local capacities = phrase_request.capacities
local profile = assert(phrase_capabilities.inspect(instrument))
local plan = assert(output_planner.plan(phrase_request.source, phrase_request.output_policy,
  phrase_request.pb_range, capacities, profile,
  {pitch_bend_delivery=phrase_pitch_bend.delivery_enabled}))
local before = assert(phrase_ownership.snapshot(phrase, capacities))
assert(phrase_materializer.apply(phrase, plan.expected, plan.required_visibility, before, capacities))
for line_index=1,capacities.max_lines do
  local line=phrase:line(line_index)
  for column=1,capacities.max_note_columns do
    local cell=line:note_column(column)
    cell.is_empty=(cell.note_value==121 or cell.note_value==nil) and
      (cell.instrument_value or 255)==255 and (cell.volume_value or 255)==255 and
      (cell.panning_value or 255)==255 and (cell.delay_value or 0)==0 and
      (cell.effect_number_value or 0)==0 and (cell.effect_amount_value or 0)==0
  end
  for column=1,capacities.max_effect_columns do
    local cell=line:effect_column(column)
    cell.is_empty=(cell.number_value or 0)==0 and (cell.amount_value or 0)==0
  end
end
phrase.name = assert(phrase_ownership.make_name(phrase, 8))
instrument.phrases[8] = phrase
assert(pattern_store.save(song, 8, phrase_request.source, phrase_request.output_policy, phrase_request.pb_range))
local classified = assert(phrase_validator.classify(song, instrument, phrase, profile, capacities,
  {pitch_bend_delivery=phrase_pitch_bend.delivery_enabled}))
committed_baseline = {id=8, source=classified.source, settings=classified.settings,
  snapshot=classified.baseline, planning_inputs=classified.planning_inputs}
complete("committed", "Phrase 08 generated (1 notes, 0 OFF; 1 raw events). Instrument 00.")
assert(closed and instrument.phrase_program == 8)
assert(output:find("phrase.line.1=48,255,89,255,0,0,0", 1, true),
  "Readback did not retain native quantized volume")
assert(output:find("loaded_writer_source=repository/com.david303ttl.ACID.xrnx/writers/phrase_writer.lua", 1, true)
  and output:find("loaded_sequencer_source=repository/com.david303ttl.ACID.xrnx/model/sequencer.lua", 1, true),
  "Capture metadata did not classify the loaded ACID modules")
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
ACID_CAPTURE_WRITER_STATE = nil
ACID_CAPTURE_WRITER_TEST = nil
ACID_ARTICULATION_CASE_ID = nil
ACID_ARTICULATION_OUTPUT_POLICY = nil
print("ACID writer capture delegation and readback checks passed (audio unverified)")
