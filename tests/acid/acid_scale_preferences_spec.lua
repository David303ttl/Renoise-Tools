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
assert(preferences.load(nil) == "", "missing Renoise must load as an empty library")
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

local bad, bad_error = preferences.save(tool, {})
assert(bad == nil and bad_error, "non-text library values must be rejected")

_G.renoise = original_renoise
print("ACID custom scale preference persistence checks passed")
