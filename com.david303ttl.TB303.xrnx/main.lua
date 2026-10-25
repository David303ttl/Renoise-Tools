-- TB303.xrnx entry point. No sequence rendering actions are registered yet.
local gui = require("gui")

local function show_tool()
  gui.show()
end

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:TB303...",
  invoke = show_tool
}

renoise.tool():add_menu_entry {
  name = "Pattern Editor:TB303...",
  invoke = show_tool
}
