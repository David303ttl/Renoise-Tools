-- ACID.xrnx entry point. No sequence rendering actions are registered yet.
local gui = require("gui")

local function show_tool()
  gui.show()
end

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:ACID...",
  invoke = show_tool
}

renoise.tool():add_menu_entry {
  name = "Pattern Editor:ACID...",
  invoke = show_tool
}
