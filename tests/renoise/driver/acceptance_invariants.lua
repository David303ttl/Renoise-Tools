local M = {}
local EDITOR_FIXTURE_OPERATION = "editor-responsiveness fixture lifecycle"
local REQUIRED_SELECTION_SCOPE = "required"
local FIXTURE_SELECTION_SCOPE = "harness-fixture"
local ACCEPTANCE_PROFILES = { Warm = true, Detailed = true }
local PROFILED_ACCEPTANCE_CASES = {
  ["editor-responsiveness"] = true,
  ["multi-instrument-workflow"] = true,
}
M.editor_fixture_operation = EDITOR_FIXTURE_OPERATION

function M.selection_trace_passes(trace)
  if type(trace) ~= "table" or #trace == 0 then return false end
  for _, event in ipairs(trace) do
    if event.selection_scope == REQUIRED_SELECTION_SCOPE then
      if event.selection_stable ~= true then return false end
    elseif event.selection_scope == FIXTURE_SELECTION_SCOPE then
      if event.operation ~= EDITOR_FIXTURE_OPERATION or
          (event.event ~= "phrase-list-change" and event.event ~= "selected-phrase-change") or
          event.selection_stable ~= nil then
        return false
      end
    else
      return false
    end
  end
  return true
end

function M.selection_scope_for_operation(operation)
  if operation == EDITOR_FIXTURE_OPERATION then return FIXTURE_SELECTION_SCOPE end
  return REQUIRED_SELECTION_SCOPE
end

function M.same_native_selection(left, right)
  return left ~= nil and right ~= nil and
    rawequal(left.instrument, right.instrument) and rawequal(left.phrase, right.phrase) and
    left.instrument_index == right.instrument_index and left.phrase_index == right.phrase_index
end

function M.same_native_color(left, right)
  if left == nil or right == nil then return false end
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for index, value in ipairs(left) do
    if value ~= right[index] then return false end
  end
  return #left == #right
end

function M.editor_fixture_passes(prerequisites, result)
  return prerequisites == true and type(result) == "table" and
    result.editor_fixture_inventory_restored == true and
    result.editor_fixture_native_selection_restored == true
end

function M.install_profile_wrapper(profile_mode, target, key, wrap)
  if profile_mode ~= "Detailed" or type(target) ~= "table" or type(target[key]) ~= "function" then
    return nil, false
  end
  local original = target[key]
  target[key] = wrap(original)
  return original, true
end

function M.callback_latency_acceptance(profile_mode)
  if profile_mode == "Detailed" then return "NOT_CLAIMED" end
  return "NOT_GATED"
end

function M.resolve_acceptance_profile(case_name, profile_mode)
  if profile_mode ~= nil and not PROFILED_ACCEPTANCE_CASES[case_name] then
    return nil, "instrumentation profile is only valid for editor-responsiveness and multi-instrument-workflow"
  end
  if not PROFILED_ACCEPTANCE_CASES[case_name] then return nil end
  profile_mode = profile_mode or "Warm"
  if not ACCEPTANCE_PROFILES[profile_mode] then
    return nil, "instrumentation profile must be Warm or Detailed"
  end
  return profile_mode
end

return M
