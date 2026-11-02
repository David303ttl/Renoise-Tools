-- SPDX-License-Identifier: GPL-3.0-only
local M = {}

local MODEL_NAME = "AcidScalePreferences"
local PROPERTY_NAME = "custom_scales"

local function get_document_api()
  local api = rawget(_G, "renoise")
  if type(api) ~= "table" or type(api.Document) ~= "table" or
    type(api.Document.create) ~= "function" then
    return nil
  end
  return api.Document
end

local function property_value(property)
  if property == nil then return nil end
  local ok, value = pcall(function() return property.value end)
  if ok and value ~= nil then return value end
  if type(property) == "string" then return property end
  return nil
end

local function ensure_property(tool)
  if tool == nil then return nil, "Renoise tool is unavailable" end

  local ok, preferences = pcall(function() return tool.preferences end)
  if not ok then return nil, "Could not read tool preferences" end

  if preferences == nil then
    local document_api = get_document_api()
    if not document_api then return nil, "Renoise Document API is unavailable" end
    local created, document = pcall(function()
      return document_api.create(MODEL_NAME)({[PROPERTY_NAME] = ""})
    end)
    if not created or document == nil then
      return nil, "Could not create scale preferences document"
    end
    local assigned = pcall(function() tool.preferences = document end)
    if not assigned then return nil, "Could not assign scale preferences document" end
    preferences = document
  end

  local found, property = pcall(function() return preferences[PROPERTY_NAME] end)
  if found and property ~= nil then return property end

  local added, add_error = pcall(function()
    if type(preferences.add_property) ~= "function" then
      error("preferences document cannot add properties")
    end
    preferences:add_property(PROPERTY_NAME, "")
  end)
  if not added then return nil, tostring(add_error) end

  local reread, created_property = pcall(function() return preferences[PROPERTY_NAME] end)
  if not reread or created_property == nil then
    return nil, "Could not access custom scale preference"
  end
  return created_property
end

function M.load(tool)
  local property = ensure_property(tool)
  if not property then return "" end
  local value = property_value(property)
  if type(value) ~= "string" then return "" end
  return value
end

function M.save(tool, text)
  if type(text) ~= "string" then return nil, "Scale library must be text" end
  local property, err = ensure_property(tool)
  if not property then return nil, err end
  local assigned = pcall(function() property.value = text end)
  if not assigned then return nil, "Could not save custom scale preferences" end
  return true
end

return M
