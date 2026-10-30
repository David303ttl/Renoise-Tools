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
  local allowed = {
    model = {model=true},
    renoise = {model=true, renoise=true},
    writers = {model=true, renoise=true, writers=true},
    runtime = {model=true, renoise=true, writers=true, runtime=true},
  }
  local obsolete = {
    ["writers.phrase_ownership"] = true,
    ["model.pattern_store"] = true,
    ["model.target_capabilities"] = true,
    ["model.draft_cache"] = true,
  }
  for name in pairs(obsolete) do
    assert(not sources[name], "obsolete module remains: " .. name)
  end
  local pb_choice_table_count = 0
  for name, source in pairs(sources) do
    local module_path = "." .. name .. "."
    for _, directory in ipairs({"test", "tests", "sdk", "fixtures", "scenarios", "keyboard", "__dev"}) do
      assert(not module_path:find("." .. directory .. ".", 1, true),
        "development module in runtime inventory: " .. name)
    end
    for _, token in ipairs(tokens(source)) do
      assert(token.kind ~= "name" or (token.value ~= "dofile" and token.value ~= "loadfile"),
        name .. " uses a runtime file loader outside the private require graph")
    end
    graph[name] = dependencies(source)
    local owner = name:match("^([^.]+)%.")
    for dependency in pairs(graph[name]) do
      assert(sources[dependency], name .. " imports missing module " .. dependency)
      assert(not obsolete[dependency], name .. " imports obsolete module " .. dependency)
      local dependency_owner = dependency:match("^([^.]+)%.")
      if allowed[owner] then
        assert(dependency_owner and allowed[owner][dependency_owner],
          name .. " imports forbidden module " .. dependency)
      end
    end
    local _, pb_choice_tables = source:gsub("%{%s*0%s*,%s*2%s*,%s*12%s*,%s*24%s*,%s*48%s*%}", "")
    if pb_choice_tables > 0 then
      assert(name == "model.policies" and pb_choice_tables == 1,
        name .. " duplicates the PB choices policy")
      pb_choice_table_count = pb_choice_table_count + pb_choice_tables
    end
  end
  if sources.main then
    assert(pb_choice_table_count == 1, "PB choices policy must have one canonical table")
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
rejects({["model.a"]="require('renoise.b')", ["renoise.b"]=""}, "forbidden module")
rejects({["renoise.a"]="require('writers.b')", ["writers.b"]=""}, "forbidden module")
rejects({["writers.a"]="require('runtime.b')", ["runtime.b"]=""}, "forbidden module")
rejects({["renoise.store"]="require('runtime.context')", ["runtime.context"]=""}, "forbidden module")
rejects({["model.a"]="require('runtime.context')", ["runtime.context"]=""}, "forbidden module")
rejects({["writers.a"]="require('gui')", ["gui"]=""}, "forbidden module")
rejects({["runtime.context"]="require('gui')", ["gui"]=""}, "forbidden module")
rejects({["model.a"]="require('model.b')", ["model.b"]="local function lazy() return require('model.a') end"}, "require cycle")
rejects({["writers.a"]="require('writers.a')"}, "require cycle")
rejects({["model.a"]="require('model.missing')"}, "missing module")
rejects({["model.a"]="require(module_name)"}, "literal module name")
rejects({["model.a"]="require('model.' .. module_name)"}, "literal module name")
rejects({["model.a"]="require('gui')", ["gui"]=""}, "forbidden module")
validate({["model.a"]="", ["writers.b"]="local function lazy() return require('model.a') end"})
validate({["model.a"]="", ["renoise.a"]="require('model.a')", ["writers.a"]="require('renoise.a')", ["runtime.a"]="require('writers.a')"})
rejects({["model.policies"]="", ["model.a"]="", ["writers.a"]="local choices = {0, 2, 12, 24, 48}"}, "duplicates the PB choices policy")
rejects({["writers.phrase_ownership"]="", ["writers.a"]="require('writers.phrase_ownership')"}, "obsolete module")
rejects({["model.pattern_store"]=""}, "obsolete module remains")
rejects({["tests.driver"]=""}, "development module in runtime inventory")
rejects({["__dev.remote_driver"]=""}, "development module in runtime inventory")
rejects({["gui"]="dofile('tests/driver.lua')"}, "runtime file loader")
rejects({["gui"]="local loader = loadfile"}, "runtime file loader")
rejects({["gui"]="require('__dev.remote_driver')"}, "missing module")

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
assert(sources["runtime.context"], "runtime context interface is missing")
validate(sources)
dofile('tests/bootstrap.lua')('acid')
local articulation = require("model.articulation")
local gates = require("writers.gate_writer")
assert(articulation.apply == nil, "articulation must expose planning only")
assert(gates.apply == nil and gates.plan == nil and gates.location == nil, "gate writer must expose planned application only")
print("acid_dependency_graph_spec: OK")
