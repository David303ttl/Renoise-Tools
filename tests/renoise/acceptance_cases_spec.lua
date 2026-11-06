local helpers = dofile("tests/renoise/driver/acceptance_invariants.lua")
assert(helpers.selection_scope_for_operation(helpers.editor_fixture_operation) == "harness-fixture")
assert(helpers.selection_scope_for_operation("regenerate instrument 1 target 1") == "required")

local SELECTED_COLOR,IDLE_COLOR={0xF0,0xC0,0x40},{0x40,0x40,0x40}
assert(helpers.same_native_color(SELECTED_COLOR,{unpack(SELECTED_COLOR)}))
assert(not helpers.same_native_color(SELECTED_COLOR,IDLE_COLOR))
assert(not helpers.same_native_color(nil,nil) and not helpers.same_native_color(SELECTED_COLOR,nil),
  "missing native color observations cannot verify selection highlighting")

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
assert(helpers.callback_latency_acceptance("Warm")=="NOT_GATED",
  "Warm latency must be record-only")
assert(helpers.callback_latency_acceptance("Detailed")=="NOT_CLAIMED",
  "Detailed timing must remain diagnostic and cannot claim latency acceptance")
assert(helpers.resolve_acceptance_profile("editor-responsiveness")=="Warm" and
  helpers.resolve_acceptance_profile("multi-instrument-workflow")=="Warm",
  "profiled native acceptance cases must default to Warm")
assert(helpers.resolve_acceptance_profile("editor-responsiveness","Detailed")=="Detailed")
local ignored_profile,ignored_error=helpers.resolve_acceptance_profile("ownership-negatives","Detailed")
assert(ignored_profile==nil and ignored_error,"profile selector was accepted by an unrelated native case")
local invalid_profile,invalid_error=helpers.resolve_acceptance_profile("editor-responsiveness","Verbose")
assert(invalid_profile==nil and invalid_error,"unknown instrumentation profile was accepted")
local acceptance_cases=dofile("tests/renoise/driver/acceptance_cases.lua")
local accepted,reason=acceptance_cases.run("unsupported-case",function()
  error("unsupported native acceptance case was dispatched")
end)
assert(accepted==false and reason=="native acceptance case is not allowlisted",
  "unsupported native acceptance case was not rejected")
local rejected_profile_result
assert(acceptance_cases.run("ownership-negatives",function(result) rejected_profile_result=result end,nil,"Detailed"))
assert(rejected_profile_result.status=="ERROR" and rejected_profile_result.reason==ignored_error,
  "M.run did not reject profile settings for unrelated cases")
rejected_profile_result=nil
assert(acceptance_cases.run("editor-responsiveness",function(result) rejected_profile_result=result end,nil,"Verbose"))
assert(rejected_profile_result.status=="ERROR" and rejected_profile_result.reason==invalid_error,
  "M.run did not reject an unsupported profile value")

print("Acceptance driver regressions pass: profile modes and selection")
