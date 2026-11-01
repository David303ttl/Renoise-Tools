-- Exercise enabled articulation generation, live regeneration, and XRNS persistence in Renoise.
local song = assert(renoise.song(), "Open the disposable ACID articulation song first")
local path = debug.getinfo(1, "S").source:gsub("\\", "/")
local root = assert(path:match("^@(.*)/tests/acid/renoise_articulation_lifecycle.lua$"),
  "Load this helper from its repository file path")
local provenance = dofile(root .. "/tests/acid/capture_provenance.lua")
local output_policy = rawget(_G, "ACID_ARTICULATION_OUTPUT_POLICY") or "repeat"
assert(output_policy == "repeat" or output_policy == "play_once", "Invalid phrase output policy")
assert(renoise.tool() and renoise.tool().app_idle_observable
  and renoise.tool().app_new_document_observable,
  "Run in ACID's scripting context")

local oracle_relative=rawget(_G,"ACID_ARTICULATION_LIFECYCLE_ORACLE_PATH") or
  "tests/acid/fixtures/audio_cases.json"
assert(type(oracle_relative)=="string" and oracle_relative~=""
  and oracle_relative:sub(1,1)~="/" and oracle_relative:sub(1,1)~="\\"
  and not oracle_relative:find("[\r\n]"),"Oracle path must be repository-relative")
oracle_relative=oracle_relative:gsub("\\","/")
for segment in oracle_relative:gmatch("[^/]+") do
  assert(segment~="..","Oracle path cannot leave the repository")
end
local oracle = dofile(root .. "/tests/acid/fixture_json.lua").read(
  root .. "/" .. oracle_relative)
local case_id = rawget(_G,"ACID_ARTICULATION_LIFECYCLE_CASE_ID") or
  (output_policy == "repeat" and "repeat_note_rest_seam_bpm_120" or "one_shot_tie_tail_bpm_120")
local case
for _, candidate in ipairs(oracle.cases) do
  if candidate.id == case_id then case = candidate;break end
end
assert(case and case.qualification.protocol_status == "ready",
  "Expected ready lifecycle fixture is missing")
assert(case.playback.renderer=="acid-writer"
  and case.playback.looping==(output_policy=="repeat"),
  "Lifecycle fixture does not match the selected phrase output policy")

local instrument_index, instrument
for index, candidate in ipairs(song.instruments) do
  if candidate.name == "ACID ARTICULATION PROBE" then
    assert(not instrument, "Multiple articulation probe instruments exist")
    instrument_index, instrument = index, candidate
  end
end
assert(instrument, "Create the articulation probe first")
assert(instrument.phrase_playback_mode == renoise.Instrument.PHRASES_PLAY_SELECTIVE,
  "The reference probe must use selective phrase playback")
assert(#instrument.samples == 1 and instrument.samples[1].sample_buffer.has_sample_data,
  "The reference probe must contain its single playable sample")
local expected_bpm = 120
assert(song.transport.bpm == expected_bpm and song.transport.lpb == 8
  and song.transport.tpl == 12 and song.transport.groove_enabled == false,
  "Lifecycle fixture requires 120 BPM, LPB 8, TPL 12, and groove disabled")
local instrument_name=instrument.name

-- Keep the terminal's module cache isolated to ACID, as the writer helper does.
local old_path = package.path
package.path = root .. "/com.david303ttl.ACID.xrnx/?.lua;" .. old_path
local loaded, writer, sequencer, ownership, store, runtime_context, policies = pcall(function()
  return require("writers.phrase_writer"), require("model.sequencer"),
    require("renoise.phrase_ownership"), require("renoise.pattern_store"),
    require("runtime.context"), require("model.policies")
end)
package.path = old_path
assert(loaded, writer)
local module_sources={}
for name, entry in pairs({
  writer={writer.create,"writers/phrase_writer.lua"},
  sequencer={sequencer.new_pattern,"model/sequencer.lua"},
  context={runtime_context.new,"runtime/context.lua"},
  ownership={ownership.status,"renoise/phrase_ownership.lua"},
  store={store.load,"renoise/pattern_store.lua"}
}) do
  module_sources[name]=provenance.describe(root,entry[1],entry[2])
end
local fixture_pitch=dofile(root.."/tests/acid/pitch_fixture.lua")

local source = case.source
local pattern = sequencer.new_pattern(source.length)
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

local target_index
local result_path = root .. "/tmp/acid-articulation/lifecycle_" .. output_policy .. "_" .. os.time() .. ".txt"
local song_path = root .. "/tmp/acid-articulation/lifecycle_" .. output_policy .. "_" .. os.time() .. ".xrns"
local function unused(pathname)
  local file = io.open(pathname,"rb")
  if file then file:close();return false end
  return true
end
assert(unused(result_path) and unused(song_path), "Refusing to overwrite lifecycle output")
local output = assert(io.open(result_path,"wb"), "Create tmp/acid-articulation first")
local function record(key, value)
  assert(output:write(key .. "=" .. tostring(value):gsub("[\r\n]", " ") .. "\n"))
  output:flush()
end
record("format", "ACID-ARTICULATION-LIFECYCLE-1")
record("case_id",case_id)
record("oracle",oracle_relative)
for name,source in pairs(module_sources) do record("loaded_"..name.."_source",source) end
record("output_policy",output_policy)
record("instrument_index",instrument_index)
record("instrument_name",instrument_name)
record("initial_phrase_count",#instrument.phrases)
record("song_roundtrip_path",song_path:gsub("\\","/"))
record("live_edit_path","production runtime context manual/live admission with explicit phrase_writer create/regenerate")

local function pattern_equal(left,right)
  return sequencer.same_source(left,right)
end

local function checked_source(current_song,current_instrument,phrase_index,expected,expected_policy)
  local phrase=assert(current_instrument.phrases[phrase_index], "Generated phrase is missing")
  assert(ownership.status(phrase)=="owned", "Generated phrase seal is invalid")
  local restored,actual_policy=store.load(current_song,current_instrument,phrase)
  assert(restored,actual_policy)
  assert(actual_policy==expected_policy, "Persisted phrase output policy changed")
  assert(pattern_equal(restored,expected), "Persisted source differs from the generated source")
  return phrase
end

local function finish_record(status, detail)
  record("result",status)
  if detail then record("detail",detail) end
  output:close();output=nil
end

local function save_and_reopen(expected)
  local current_song=renoise.song()
  local current_instrument=current_song.instruments[instrument_index]
  local phrase=checked_source(current_song,current_instrument,target_index,expected,output_policy)
  record("pre_save_phrase_status","owned")
  record("pre_save_source_status","exact")
  record("pre_save_phrase_name",phrase.name)
  local layout={number_of_lines=phrase.number_of_lines,looping=phrase.looping,
    loop_start=phrase.loop_start,loop_end=phrase.loop_end}
  record("pre_save_phrase_lines",layout.number_of_lines)
  record("pre_save_repeat",layout.looping)
  record("pre_save_loop_start",layout.loop_start)
  record("pre_save_loop_end",layout.loop_end)

  local app=renoise.app()
  local observer=renoise.tool().app_new_document_observable
  local completed=false
  local function on_document()
    if completed then return end
    completed=true
    observer:remove_notifier(on_document)
    local ok,err=pcall(function()
      local reopened=assert(renoise.song(), "Song did not reopen")
      local reopened_instrument=assert(reopened.instruments[instrument_index], "Probe instrument missing after reopen")
      assert(reopened_instrument.name==instrument_name, "Instrument order/name changed during roundtrip")
       local reopened_phrase=checked_source(reopened,reopened_instrument,target_index,expected,output_policy)
      assert(reopened_phrase.number_of_lines==layout.number_of_lines
        and reopened_phrase.looping==layout.looping
        and reopened_phrase.loop_start==layout.loop_start
        and reopened_phrase.loop_end==layout.loop_end,
        "Phrase loop layout changed after save/reopen")
      record("post_reopen_phrase_status","owned")
      record("post_reopen_source_status","exact")
      record("post_reopen_output_policy",output_policy)
      record("post_reopen_phrase_name",reopened_phrase.name)
    end)
    if ok then
      finish_record("PASS","Generate, Live Edit regeneration, ownership seal, and XRNS save/reopen passed")
      print("ACID articulation lifecycle passed; evidence: " .. result_path)
    else
      finish_record("FAIL",err)
      print("ACID lifecycle save/reopen failed: "..tostring(err).."; evidence: "..result_path)
    end
  end

  observer:add_notifier(on_document)
  local ok,err=pcall(function()
    app:save_song_as(song_path)
    local saved=io.open(song_path,"rb")
    assert(saved,"Renoise did not create the lifecycle XRNS")
    saved:close()
    record("save_as","completed")
    app:load_song(song_path)
  end)
  if not ok then
    observer:remove_notifier(on_document)
    error(err)
  end
end

local pb_range=policies.DEFAULT_PB_RANGE
local runtime
local target
local phase="generate"
local edits={}
local stage=1
local current_edit=pattern

local function failed_result(result)
  local detail=type(result)=="table" and (result.message or result.reason) or result
  if output then finish_record("FAIL",tostring(detail)) end
  print("ACID lifecycle generation failed: "..tostring(detail).."; evidence: "..result_path)
end

local function defer(action)
  local observer=renoise.tool().app_idle_observable
  local handler
  handler=function()
    pcall(function() observer:remove_notifier(handler) end)
    local applied,error_message=pcall(action)
    if not applied then failed_result(error_message) end
  end
  observer:add_notifier(handler)
end

local function build_edits()
  local function clone_pattern(input,length)
    local copy=assert(sequencer.copy_source(input))
    copy.length=length or copy.length
    return copy
  end
  if case_id:match("^writer_repeat_glide_") then
    local extended=clone_pattern(pattern,pattern.length+1)
    extended.time_events[extended.length]="T"
    return {
      {pattern=extended,label="Live Edit LAST STEP 8 to 9; append held TIE"},
      {pattern=clone_pattern(pattern),label="Live Edit LAST STEP 9 to 8; restore original source"}
    }
  end
  local edited=clone_pattern(pattern)
  for index=1,edited.pitch_length do
    local note=edited.pitch_events[index].note
    edited.pitch_events[index]=fixture_pitch(note==60 and note-1 or note+1,
      edited.pitch_events[index].accent,edited.pitch_events[index].slide)
  end
  return {{pattern=edited,label="Live Edit active PITCH span +1 semitone"}}
end

local function apply_live_edit()
  local editor,effects=runtime:transition("edit",
    {source=current_edit,output_policy=output_policy,pb_range=pb_range})
  if not editor or not effects or effects.accepted~=true then
    failed_result(effects and effects.reason or "Live Edit did not enter runtime admission")
  end
end

local function advance_live_edit()
  stage=stage+1
  if stage<=#edits then
    current_edit=edits[stage].pattern
    apply_live_edit()
    return
  end
  runtime:transition("disarm")
  runtime:close_dialog()
  record("live_edit_status","passed")
  save_and_reopen(current_edit)
end

local function handle_terminal(result)
  local writer_key=phase=="generate" and "generate_writer_status" or "live_writer_status"
  record(writer_key,type(result)=="table" and result.message or result)
  if type(result)~="table" or result.kind~="success" or result.verified~=true then
    failed_result(result)
    return
  end
  local current_song=renoise.song()
  local current_instrument=assert(current_song.instruments[instrument_index])
  if phase=="generate" then
    target=assert(result.phrase,"Writer success did not return its destination phrase")
    for index,candidate in ipairs(current_instrument.phrases) do
      if rawequal(candidate,target) then target_index=index;break end
    end
    assert(target_index,"Generate did not publish its phrase")
    local generated=checked_source(current_song,current_instrument,target_index,pattern,output_policy)
    assert(ownership.status(generated)=="owned",
      "Normal Generate did not create a valid ACID-owned phrase")
    record("generate_status","passed")
    record("generate_phrase_status",ownership.status(generated))
    runtime:bind_phrase(current_instrument,target)
    edits=build_edits()
    phase="live"
    stage=1
    current_edit=edits[1].pattern
    defer(function()
      runtime:transition("arm")
      apply_live_edit()
    end)
    return
  end
  local phrase=checked_source(current_song,current_instrument,target_index,current_edit,output_policy)
  assert(ownership.status(phrase)=="owned", "Live Edit output lost its ownership seal")
  record("live_edit_stage_"..stage,edits[stage].label)
  record("live_edit_stage_"..stage.."_phrase_status","owned")
  record("live_edit_stage_"..stage.."_source_status","exact")
  record("live_edit_stage_"..stage.."_phrase_name",phrase.name)
  defer(advance_live_edit)
end

local function on_terminal(result)
  local completed,error_message=pcall(handle_terminal,result)
  if not completed then failed_result(error_message) end
end

local ok,err=pcall(function()
  assert(#instrument.phrases < (renoise.Instrument.MAX_NUMBER_OF_PHRASES or 126)-2,
    "Need phrase slots for Generate staging and backup")
  local existing,read_error=store.read(song)
  assert(existing,read_error)
  runtime=runtime_context.new({
    writer=writer,
    capture=function() return nil,"No editor source" end,
    sink=function(request,done)
      if request.kind=="create" then return writer.create(request,done) end
      if request.kind=="regenerate" then return writer.regenerate(request,done) end
      return false,"Request has no explicit writer operation"
    end,
    cancel=function(token,reason)
      if type(writer.cancel)~="function" then return false end
      return writer.cancel(token,reason)
    end,
  })
  runtime:attach_document(song)
  runtime:open_dialog(on_terminal)
  runtime:bind_new(instrument)
  local editor,effects=runtime:transition("edit",
    {source=pattern,output_policy=output_policy,pb_range=pb_range})
  assert(editor,effects)
  local accepted,reason=runtime:request_generation("manual")
  if not accepted then error(reason) end
end)
if not ok then
  if output then finish_record("FAIL",tostring(err)) end
  error(err)
end

