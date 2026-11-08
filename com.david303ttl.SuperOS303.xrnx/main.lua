-- SPDX-License-Identifier: GPL-3.0-only
local gui = require("gui")

local function show()
  gui.show()
end

renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:SuperOS-303...",
  invoke = show
}

renoise.tool():add_menu_entry {
  name = "Pattern Editor:SuperOS-303...",
  invoke = show
}

renoise.tool():add_keybinding {
  name = "Global:SuperOS-303:Show",
  invoke = show
}
