dofile("tests/bootstrap.lua")("acid")

local preferences = require("runtime.scale_preferences")
local original_renoise = rawget(_G, "renoise")

local function observable(value)
  return {value = value}
end

local function document(properties)
  local result = properties or {}
  function result:add_property(name, value)
    self[name] = observable(value)
  end
  return result
end

_G.renoise = nil
local missing, missing_error = preferences.load(nil)
assert(missing == nil and missing_error, "unavailable preferences must report an error")
local unsupported, unsupported_error = preferences.save(nil, "scale text")
assert(unsupported == nil and unsupported_error,
  "saving without a tool or Document API must report an error")

local created_count = 0
_G.renoise = {
  Document = {
    create = function(model_name)
      assert(model_name == "AcidScalePreferences")
      return function(initial)
        created_count = created_count + 1
        local result = document()
        for name, value in pairs(initial) do result[name] = observable(value) end
        return result
      end
    end
  }
}

local tool = {preferences = nil}
assert(preferences.load(tool) == "")
assert(tool.preferences and tool.preferences.custom_scales.value == "")
local first = "[Custom]\nDorian b2 = 0, 1, 3, 5, 7, 9, 10\n"
assert(preferences.save(tool, first))
assert(preferences.load(tool) == first)
assert(created_count == 1, "preferences document should be created once")

local second = first .. "Altered = 0, 1, 4, 6, 8, 10\n"
assert(preferences.save(tool, second))
assert(preferences.load(tool) == second,
  "saving should replace the complete custom library text")

local existing_preferences = document({keep_me = observable("existing value")})
local existing_tool = {preferences = existing_preferences}
assert(preferences.load(existing_tool) == "")
assert(existing_tool.preferences == existing_preferences,
  "existing preferences document must be preserved")
assert(existing_preferences.keep_me.value == "existing value")
assert(preferences.save(existing_tool, first))
assert(existing_tool.preferences == existing_preferences)
assert(existing_preferences.keep_me.value == "existing value")
assert(preferences.load(existing_tool) == first)

local broken_tool = {preferences = document({custom_scales = observable(42)})}
local loaded, load_error = preferences.load(broken_tool)
assert(loaded == nil and load_error, "invalid preferences must not be treated as an empty library")
local refusing = setmetatable({}, {
  __index = function(_, key) if key == "value" then return first end end,
  __newindex = function(_, key) if key == "value" then error("write refused") end end
})
local failed_tool = {preferences = document({custom_scales = refusing})}
local saved, save_error = preferences.save(failed_tool, second)
assert(not saved and save_error and preferences.load(failed_tool) == first,
  "preference setter failure must preserve the previous library")
local truncated_value = first
local truncating = setmetatable({}, {
  __index = function(_, key) if key == "value" then return truncated_value end end,
  __newindex = function(_, key, value)
    if key == "value" then truncated_value = value:sub(1, 5) end
  end
})
local truncated_tool = {preferences = document({custom_scales = truncating})}
local result, error_text, uncertain = preferences.save(truncated_tool, second)
assert(not result and uncertain and error_text:find("may have changed", 1, true),
  "unverified persistence must report an uncertain result")
local bad, bad_error = preferences.save(tool, {})
assert(bad == nil and bad_error, "non-text library values must be rejected")

_G.renoise = original_renoise
print("ACID custom scale preference persistence checks passed")
