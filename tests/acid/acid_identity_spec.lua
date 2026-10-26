dofile('tests/bootstrap.lua')('acid')
-- Run from repository root: lua tests/acid/acid_identity_spec.lua
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
assert(gui:find("show_custom_dialog(\"ACID\"", 1, true))
print("ACID package identity checks passed")
