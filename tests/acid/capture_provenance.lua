-- Convert a loaded ACID module source path into portable capture metadata.
local M = {}

local function normalize(path)
  return (path:gsub("\\", "/"):gsub("/+$", ""))
end

function M.describe(root, fn, module_path)
  assert(type(root) == "string" and type(module_path) == "string")
  assert(type(fn) == "function")
  local source = debug.getinfo(fn, "S").source
  assert(type(source) == "string" and source:sub(1, 1) == "@",
    "Loaded module has no file source")
  local path = normalize(source:sub(2))
  local relative = "com.david303ttl.ACID.xrnx/" .. module_path
  local suffix = "/" .. relative
  assert(path:sub(-#suffix):lower() == suffix:lower(),
    "Loaded module source does not match " .. relative)

  local repository_module = normalize(root .. "/" .. relative):lower()
  local source_lower = path:lower()
  local from_repository = source_lower == repository_module
    or source_lower:sub(1, #repository_module + 1) == repository_module .. "/"
  local origin = from_repository and "repository" or "installed"
  return origin .. "/" .. relative
end

return M
