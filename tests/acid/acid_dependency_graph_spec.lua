local function tokens(source)
  local result, pos = {}, 1
  while pos <= #source do
    local rest = source:sub(pos)
    local comment = rest:sub(1, 2) == "--"
    local start = comment and 3 or 1
    local equals = rest:sub(start):match("^%[(=*)%[")
    if equals then
      local closing = "]" .. equals .. "]"
      local finish = assert(rest:find(closing, start + #equals + 2, true), "unclosed long string")
      if not comment then
        result[#result + 1] = {kind="string", value=rest:sub(start + #equals + 2, finish - 1)}
      end
      pos = pos + finish + #closing - 1
    elseif comment then
      pos = pos + (rest:find("\n", 1, true) or #rest)
    elseif rest:match("^%s") then
      pos = pos + 1
    elseif rest:sub(1, 1) == '"' or rest:sub(1, 1) == "'" then
      local quote, finish = rest:sub(1, 1), 2
      while finish <= #rest and rest:sub(finish, finish) ~= quote do
        finish = finish + (rest:sub(finish, finish) == "\\" and 2 or 1)
      end
      assert(finish <= #rest, "unclosed string")
      local literal = rest:sub(1, finish)
      result[#result + 1] = {kind="string", value=assert((loadstring or load)("return " .. literal))()}
      pos = pos + finish
    else
      local name = rest:match("^[%a_][%w_]*")
      result[#result + 1] = {kind=name and "name" or "symbol", value=name or rest:sub(1, 1)}
      pos = pos + (name and #name or 1)
    end
  end
  return result
end

local function dependencies(source)
  local found, list = {}, tokens(source)
  for index, token in ipairs(list) do
    if token.kind == "name" and token.value == "require" then
      local argument = list[index + 1]
      if argument and argument.value == "(" then
        argument = list[index + 2]
        assert(list[index + 3] and list[index + 3].value == ")", "require must use a literal module name")
      end
      assert(argument and argument.kind == "string", "require must use a literal module name")
      found[argument.value] = true
    end
  end
  return found
end

local function validate(sources)
  local graph = {}
  for name, source in pairs(sources) do
    graph[name] = dependencies(source)
    for dependency in pairs(graph[name]) do
      assert(sources[dependency], name .. " imports missing module " .. dependency)
      if name:match("^model%.") then
        assert(dependency:match("^model%."), name .. " imports forbidden module " .. dependency)
      end
    end
  end
  local visiting, visited, path = {}, {}, {}
  local function visit(name)
    assert(not visiting[name], "require cycle: " .. table.concat(path, " -> ") .. " -> " .. name)
    if visited[name] then return end
    visiting[name], path[#path + 1] = true, name
    for dependency in pairs(graph[name]) do visit(dependency) end
    path[#path], visiting[name], visited[name] = nil, nil, true
  end
  for name in pairs(graph) do visit(name) end
end

local function rejects(sources, message)
  local ok, err = pcall(validate, sources)
  assert(not ok and tostring(err):find(message, 1, true), tostring(err))
end

local imports = dependencies([==[
-- require("ignored.line")
--[=[ require("ignored.block") ]=]
local text = "require('ignored.string')"
local block = [[require('ignored.long_string')]]
local function lazy() return require ( 'model.lazy' ) end
local other = require "model.direct"
local long = require [=[model.long]=]
]==])
assert(imports["model.lazy"] and imports["model.direct"] and imports["model.long"])
local count = 0
for _ in pairs(imports) do count = count + 1 end
assert(count == 3)
rejects({["model.a"]="local function lazy() return require('writers.b') end", ["writers.b"]=""}, "forbidden module")
rejects({["model.a"]="require('model.b')", ["model.b"]="local function lazy() return require('model.a') end"}, "require cycle")
rejects({["writers.a"]="require('writers.a')"}, "require cycle")
rejects({["model.a"]="require('model.missing')"}, "missing module")
rejects({["model.a"]="require(module_name)"}, "literal module name")
rejects({["model.a"]="require('model.' .. module_name)"}, "literal module name")
validate({["model.a"]="", ["writers.b"]="local function lazy() return require('model.a') end"})

local root = "com.david303ttl.ACID.xrnx"
local command = 'pwsh -NoProfile -Command "Get-ChildItem -LiteralPath ' .. root
  .. ' -Recurse -File -Filter *.lua | ForEach-Object { [IO.Path]::GetRelativePath((Get-Location).Path, $_.FullName) }"'
local files = assert(io.popen(command, "r"))
local sources = {}
for path in files:lines() do
  local normalized = path:gsub("\\", "/")
  local relative = assert(normalized:match("^" .. root:gsub("%.", "%%.") .. "/(.+)%.lua$"), path)
  local file = assert(io.open(path, "rb"))
  sources[relative:gsub("/", ".")] = file:read("*a")
  file:close()
end
assert(files:close())
assert(sources.main and sources["model.articulation"] and sources["writers.gate_writer"], "runtime inventory is incomplete")
validate(sources)
dofile('tests/bootstrap.lua')('acid')
local articulation = require("model.articulation")
local gates = require("writers.gate_writer")
assert(articulation.apply == nil, "articulation must expose planning only")
assert(gates.apply == nil and gates.plan == nil and gates.location == nil, "gate writer must expose planned application only")
print("acid_dependency_graph_spec: OK")
