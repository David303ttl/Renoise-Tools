-- Configure private module lookup for one standalone tool before a spec requires modules.
-- Specs run in separate processes so module caches and Renoise mocks cannot leak.
return function(tool)
  assert(type(tool) == "string", "tool name must be a string")
  local name = string.lower(tool)
  assert(name:match("^[a-z0-9][a-z0-9_-]*$"), "invalid Renoise tool name: " .. tostring(tool))

  local test_root = "tests/" .. name
  local config = dofile(test_root .. "/config.lua")
  assert(type(config) == "table", "tool config must return a table")
  for key in pairs(config) do
    assert(key == "runtime_root", "unknown tool config field: " .. tostring(key))
  end

  local root = config.runtime_root
  assert(type(root) == "string" and root:match("^[%w_.-]+%.xrnx$"),
    "invalid runtime_root for tool " .. name)
  assert(not root:find("..", 1, true) and not root:find("/", 1, true) and not root:find("\\", 1, true),
    "runtime_root must name a root .xrnx directory")
  local configured_name = root:match("%.([^.]+)%.xrnx$")
  assert(configured_name and string.lower(configured_name) == name,
    "runtime_root does not match requested tool: " .. name)
  local manifest = assert(io.open(root .. "/manifest.xml", "r"),
    "runtime_root does not contain manifest.xml: " .. root)
  manifest:close()
  local main = assert(io.open(root .. "/main.lua", "r"),
    "runtime_root does not contain main.lua: " .. root)
  main:close()

  local paths = { root .. "/?.lua", root .. "/?/init.lua" }
  paths[#paths + 1] = test_root .. "/?.lua"
  paths[#paths + 1] = test_root .. "/?/init.lua"
  package.path = table.concat(paths, ";") .. ";" .. package.path
  return root
end
