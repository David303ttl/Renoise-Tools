-- Configure module lookup for one standalone tool before a spec requires modules.
-- Specs run in separate Lua processes so tool modules and GUI mocks cannot leak.
return function(tool)
  local roots = {
    arp = "com.david303ttl.ARP.xrnx",
    acid = "com.david303ttl.ACID.xrnx",
  }
  local root = assert(roots[tool], "unknown Renoise tool: " .. tostring(tool))
  local paths = { root .. "/?.lua", root .. "/?/init.lua" }
  if tool == "acid" then
    paths[#paths + 1] = "tests/acid/?.lua"
    paths[#paths + 1] = "tests/acid/?/init.lua"
  end
  package.path = table.concat(paths, ";") .. ";" .. package.path
  return root
end
