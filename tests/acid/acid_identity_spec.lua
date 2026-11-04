dofile('tests/bootstrap.lua')('acid')
local function read(path)
  local file = assert(io.open(path, "rb"))
  local value = assert(file:read("*a"))
  file:close()
  return value
end

local root = "com.david303ttl.ACID.xrnx/"
local manifest = read(root .. "manifest.xml")
assert(manifest:find("<Id>com.david303ttl.ACID</Id>", 1, true))
assert(manifest:find("<Name>ACID</Name>", 1, true))
assert(manifest:find("<Version>0.1</Version>", 1, true))

local main = read(root .. "main.lua")
assert(main:find("Main Menu:Tools:ACID...", 1, true))
assert(main:find("Pattern Editor:ACID...", 1, true))

local gui = read(root .. "gui.lua")
local store = read(root .. "renoise/pattern_store.lua")
assert(gui:find("show_custom_dialog(\"ACID - PITCH/TIME\"", 1, true))
assert(gui:find('items={"Program","Grid"}', 1, true))
assert(gui:find('items={"Play Once","Repeat"}', 1, true))
local sequencer=require("model.sequencer")
local source=sequencer.new_pattern()
assert(source.length==sequencer.PAGE_SIZE)
for i=1,sequencer.MAX_STEPS do assert(source.time_events[i]=="N") end
assert(not gui:find("Audio test", 1, true))
assert(not gui:find("Create / Reset Pattern", 1, true))
assert(not gui:find("setup_confirmed", 1, true))
assert(not store:find("editor_view", 1, true) and not store:find("view_mode", 1, true))

local function observable()
  local handlers = {}
  return {
    add_notifier = function(_, handler) handlers[handler] = true end,
    has_notifier = function(_, handler) return handlers[handler] == true end,
    remove_notifier = function(_, handler) handlers[handler] = nil end,
  }
end
local menus, bindings = {}, {}
local tool = {
  app_release_document_observable = observable(),
  app_new_document_observable = observable(),
  tool_will_unload_observable = observable(),
  add_menu_entry = function(_, entry) menus[#menus + 1] = entry end,
  add_keybinding = function(_, entry) bindings[#bindings + 1] = entry end,
}
renoise = {tool = function() return tool end}
assert(loadfile(root .. "main.lua"))()
local production_gui = assert(package.loaded.gui)
assert(type(production_gui.show) == "function")
assert(not production_gui.get_ui_state().dialog_visible,
  "startup registers commands without opening a dialog")
local expected_menus = {"Main Menu:Tools:ACID...", "Pattern Editor:ACID..."}
assert(#menus == #expected_menus and #bindings == 1)
local show_calls = 0
local show = production_gui.show
production_gui.show = function() show_calls = show_calls + 1 end
for index, entry in ipairs(menus) do
  assert(entry.name == expected_menus[index])
  entry.invoke()
end
assert(bindings[1].name == "Global:ACID:Show")
bindings[1].invoke()
production_gui.show = show
assert(show_calls == #menus + #bindings, "every entry point reaches the same GUI")
for _, name in ipairs({"renoise.selection_context", "renoise.sampler_audit", "runtime.independence", "runtime.eligibility"}) do
  assert(package.loaded[name] == nil, "startup loaded a retired module: " .. name)
end
print("ACID package identity checks passed")
