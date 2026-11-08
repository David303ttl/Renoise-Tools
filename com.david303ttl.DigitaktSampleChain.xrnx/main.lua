-- SPDX-License-Identifier: GPL-3.0-only
local gui = require("gui")

renoise.tool():add_menu_entry {
  name = "Sample Editor:Export Digitakt Sample Chain",
  invoke = function()
    gui.show()
  end,
}
