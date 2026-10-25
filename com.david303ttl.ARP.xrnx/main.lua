-- ARP.xrnx entry point. No pattern-writing actions are registered yet.
local gui = require("gui")

local function show_tool()
  gui.show()
end

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:ARP...",
  invoke = show_tool
}

renoise.tool():add_menu_entry {
  name = "Pattern Editor:ARP...",
  invoke = show_tool
}
