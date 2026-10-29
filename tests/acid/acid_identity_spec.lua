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
print("ACID package identity checks passed")
