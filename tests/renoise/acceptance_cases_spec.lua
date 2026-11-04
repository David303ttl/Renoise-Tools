local file = assert(io.open("tests/renoise/driver/acceptance_cases.lua", "rb"))
local contents = file:read("*a")
file:close()
local prefix = assert(contents:match("^(.-)local function save_independent_fixture"))
local helpers = assert(loadstring(prefix .. [[
  return {
    selection_trace_passes = selection_trace_passes,
    same_native_selection = same_native_selection,
    same_native_color = same_native_color,
    production_output_matches = production_output_matches,
    editor_fixture_passes = editor_fixture_passes,
    draft_values_preserved = draft_values_preserved,
    install_profile_wrapper = install_profile_wrapper,
    callback_latency_acceptance = callback_latency_acceptance,
    resolve_acceptance_profile = resolve_acceptance_profile,
    production_latency_fixture = production_latency_fixture,
    production_latency_functional_status = production_latency_functional_status,
    diagnostic_performance = diagnostic_performance,
    source_value = source_value,
    canonical_baseline = canonical_baseline,
  }
]]))()

local SELECTED_COLOR,IDLE_COLOR={0xF0,0xC0,0x40},{0x40,0x40,0x40}
assert(helpers.same_native_color(SELECTED_COLOR,{unpack(SELECTED_COLOR)}))
assert(not helpers.same_native_color(SELECTED_COLOR,IDLE_COLOR))
assert(not helpers.same_native_color(nil,nil) and not helpers.same_native_color(SELECTED_COLOR,nil),
  "missing native color observations cannot verify selection highlighting")

local codec=dofile("tests/renoise/driver/json.lua")
local expected_output={properties={lpb=16},lines={},empty_note={},empty_effect={}}
local native_output={properties={lpb=16},lines={}}
for line=1,2 do
  expected_output.lines[line]={note_columns={{note_value=48,delay_value=0}},
    effect_columns={{number_value=0,amount_value=0}}}
  native_output.lines[line]={notes={{note_value=48,delay_value=0}},
    effects={{number_value=0,amount_value=0}}}
end
assert(helpers.production_output_matches(native_output,expected_output))
for _,change in ipairs({{"notes","note_value",49},{"notes","delay_value",1},
    {"effects","number_value",1},{"effects","amount_value",127}}) do
  local cell=native_output.lines[2][change[1]][1]
  local before=cell[change[2]]
  cell[change[2]]=change[3]
  assert(not helpers.production_output_matches(native_output,expected_output),
    "native oracle accepted corrupted tail "..change[2])
  cell[change[2]]=before
end
native_output.lines[2].notes={}
assert(not helpers.production_output_matches(native_output,expected_output),
  "native oracle accepted a missing column")
local hidden_source={length=1,pitch_length=1,timing_mode="triplet",pitch_events={},time_events={}}
for step=1,32 do
  hidden_source.pitch_events[step]={key=step%12,note=36+step%12,octave=0,
    accent=step%2==0,slide=step%3==0}
  hidden_source.time_events[step]=step%2==0 and "R" or "N"
end
local encoded_source=codec.encode(helpers.source_value(hidden_source,true,codec))
local reopened_source=helpers.source_value(assert(codec.decode(encoded_source)),false)
assert(helpers.canonical_baseline(reopened_source)==helpers.canonical_baseline(hidden_source),
  "checkpoint JSON lost hidden PITCH/TIME memory or source settings")
assert(getmetatable(reopened_source.pitch_events)==nil and reopened_source.pitch_events[32].key==8,
  "checkpoint decoder must restore ordinary source arrays with inactive values intact")

local production_trace = {
  {selection_scope = "required", selection_stable = true},
}
assert(helpers.selection_trace_passes(production_trace), "stable production selection was rejected")
production_trace[1].selection_stable = false
assert(not helpers.selection_trace_passes(production_trace), "production selection drift was waived")
production_trace[1].selection_stable = nil
assert(not helpers.selection_trace_passes(production_trace), "unmeasured production selection was accepted")

local fixture_trace = {
  {operation = "editor-responsiveness fixture lifecycle", event = "phrase-list-change",
    selection_scope = "harness-fixture"},
  {operation = "editor-responsiveness fixture lifecycle", event = "selected-phrase-change",
    selection_scope = "harness-fixture"},
  {operation = "regenerate instrument 1 target 1", event = "transaction-settled",
    selection_scope = "required", selection_stable = true},
}
assert(helpers.selection_trace_passes(fixture_trace),
  "explicit test fixture lifecycle contaminated production selection results")
fixture_trace[2].operation = "regenerate instrument 1 target 1"
assert(not helpers.selection_trace_passes(fixture_trace),
  "a non-fixture selection event was incorrectly exempted")
fixture_trace[2].operation = "editor-responsiveness fixture lifecycle"
fixture_trace[2].selection_stable = false
assert(not helpers.selection_trace_passes(fixture_trace),
  "fixture event unexpectedly claimed a production selection measurement")

local instrument, phrase = {}, {}
local initial_selection = {instrument = instrument, phrase = nil, instrument_index = 1, phrase_index = 0}
local fixture_selection = {instrument = instrument, phrase = phrase, instrument_index = 1, phrase_index = 4}
assert(not helpers.same_native_selection(initial_selection, fixture_selection),
  "fixture selection drift was treated as restoration")
assert(helpers.same_native_selection(initial_selection,
  {instrument = instrument, phrase = nil, instrument_index = 1, phrase_index = 0}),
  "the original no-phrase selection was not recognized after native restoration")

local editor_fixture_result = {
  editor_fixture_inventory_restored = true,
  editor_fixture_native_selection_restored = true,
}
assert(helpers.editor_fixture_passes(true, editor_fixture_result),
  "restored editor fixture should pass the shared final status gate")
for _,field in ipairs({"editor_fixture_inventory_restored", "editor_fixture_native_selection_restored"}) do
  editor_fixture_result[field] = false
  assert(not helpers.editor_fixture_passes(true, editor_fixture_result),
    "direct and integrated editor acceptance must fail when " .. field .. " is false")
  editor_fixture_result[field] = nil
  assert(not helpers.editor_fixture_passes(true, editor_fixture_result),
    "direct and integrated editor acceptance must fail when " .. field .. " is unreported")
  editor_fixture_result[field] = true
end
assert(not helpers.editor_fixture_passes(false, editor_fixture_result),
  "fixture restoration cannot pass when the owning workflow prerequisites fail")

local wrapper_target={callback=function(value)return value+1 end}
local warm_callback=wrapper_target.callback
local original,installed=helpers.install_profile_wrapper("Warm",wrapper_target,"callback",function(inner)
  return function(...)return inner(...)end
end)
assert(not installed and original==nil and rawequal(wrapper_target.callback,warm_callback) and
  wrapper_target.callback(2)==3,"Warm mode installed or changed a profiling wrapper")
local detailed_wrapped_calls=0
original,installed=helpers.install_profile_wrapper("Detailed",wrapper_target,"callback",function(inner)
  return function(...)
    detailed_wrapped_calls=detailed_wrapped_calls+1
    return inner(...)
  end
end)
assert(installed and rawequal(original,warm_callback) and wrapper_target.callback(2)==3 and
  detailed_wrapped_calls==1,"Detailed mode did not install its requested diagnostic wrapper")
wrapper_target.callback=original
assert(helpers.callback_latency_acceptance("Warm",{edit=30})=="NOT_GATED",
  "Warm latency must be record-only")
assert(helpers.callback_latency_acceptance("Warm",{edit=1100})=="NOT_GATED",
  "Latency must not fail functional acceptance")
assert(helpers.callback_latency_acceptance("Detailed",{edit=1000})=="NOT_CLAIMED",
  "Detailed timing must remain diagnostic and cannot claim latency acceptance")
assert(helpers.resolve_acceptance_profile("editor-responsiveness")=="Warm" and
  helpers.resolve_acceptance_profile("multi-instrument-workflow")=="Warm",
  "profiled native acceptance cases must default to Warm")
local latency_8=helpers.production_latency_fixture("production-latency-8x8")
assert(helpers.diagnostic_performance({})=="NOT_MEASURED")
assert(helpers.diagnostic_performance({{instrumentation_profile="Warm",elapsed_ms=30,
  performance_acceptance="PASS"}})=="NOT_GATED")
assert(helpers.diagnostic_performance({{instrumentation_profile="Warm",elapsed_ms=31,
  performance_acceptance="NOT_CLAIMED"},{instrumentation_profile="Warm",elapsed_ms=1,
  performance_acceptance="PASS"}})=="NOT_GATED",
  "latency diagnostics must not impose an acceptance ceiling")
assert(helpers.diagnostic_performance({{instrumentation_profile="Detailed",elapsed_ms=31,
  performance_acceptance="NOT_CLAIMED"}})=="NOT_MEASURED",
  "Detailed instrumentation must not determine the Warm release judgement")
local latency_16=helpers.production_latency_fixture("production-latency-16x8")
assert(latency_8.instruments==8 and latency_8.owned_per_instrument==8 and
    latency_8.receiver_counts.sample==3 and latency_8.receiver_counts.vst==3 and
    latency_8.receiver_counts.midi==2 and latency_16.instruments==16 and
    latency_16.owned_per_instrument==8 and latency_16.receiver_counts.sample==6 and
    latency_16.receiver_counts.vst==6 and latency_16.receiver_counts.midi==4 and
    helpers.production_latency_fixture("production-latency-4x4")==nil,
  "production latency fixtures must use the explicit 8x8 and 16x8 receiver mixes")
assert(helpers.production_latency_functional_status({status="PASS",
    editor_fixture_inventory_restored=true,editor_fixture_native_selection_restored=true,
    editor_fixture_store_restored=true,
    gui_live_first_edit_elapsed_ms=80}) and
    not helpers.production_latency_functional_status({status="FAIL",
      editor_fixture_inventory_restored=true,editor_fixture_native_selection_restored=true,
      editor_fixture_store_restored=true,
      gui_live_first_edit_elapsed_ms=1}) and
    not helpers.production_latency_functional_status({status="PASS",
      editor_fixture_inventory_restored=false,editor_fixture_native_selection_restored=true,
      editor_fixture_store_restored=true,
      gui_live_first_edit_elapsed_ms=1}) and
    not helpers.production_latency_functional_status({status="PASS",
      editor_fixture_inventory_restored=true,editor_fixture_native_selection_restored=true,
      editor_fixture_store_restored=false,
      gui_live_first_edit_elapsed_ms=1}),
  "latency diagnostics must require functional completion and fixture cleanup, independent of elapsed time")
assert(helpers.resolve_acceptance_profile("editor-responsiveness","Detailed")=="Detailed")
local ignored_profile,ignored_error=helpers.resolve_acceptance_profile("ownership-negatives","Detailed")
assert(ignored_profile==nil and ignored_error,"profile selector was accepted by an unrelated native case")
local invalid_profile,invalid_error=helpers.resolve_acceptance_profile("editor-responsiveness","Verbose")
assert(invalid_profile==nil and invalid_error,"unknown instrumentation profile was accepted")
local acceptance_cases=dofile("tests/renoise/driver/acceptance_cases.lua")
local rejected_profile_result
assert(acceptance_cases.run("ownership-negatives",function(result) rejected_profile_result=result end,nil,"Detailed"))
assert(rejected_profile_result.status=="ERROR" and rejected_profile_result.reason==ignored_error,
  "M.run did not reject profile settings for unrelated cases")
rejected_profile_result=nil
assert(acceptance_cases.run("editor-responsiveness",function(result) rejected_profile_result=result end,nil,"Verbose"))
assert(rejected_profile_result.status=="ERROR" and rejected_profile_result.reason==invalid_error,
  "M.run did not reject an unsupported profile value")

local expected_source={length=4,pitch_events={{key=3}}}
local exact_recovery={pattern={length=4,pitch_events={{key=3}}},output_policy="play_once",pb_range=0}
local function same_source(left,right)
  return left.length==right.length and left.pitch_events[1].key==right.pitch_events[1].key
end
local draft_preserved,retention=helpers.draft_values_preserved(nil,nil,nil,{exact_recovery},
  expected_source,"play_once",0,same_source)
assert(draft_preserved and retention=="recovery",
  "a stale captured revision should remain preserved in recovery after a committed identity change")
local mismatched_recovery={pattern={length=4,pitch_events={{key=8}}},output_policy="play_once",pb_range=0}
assert(not helpers.draft_values_preserved(nil,nil,nil,{mismatched_recovery},
  expected_source,"play_once",0,same_source),
  "different recovery source values must not satisfy captured draft preservation")

print("Acceptance driver regressions pass: profile modes, record-only latency, recovery, drafts and selection")
