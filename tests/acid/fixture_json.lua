-- Small JSON reader for repository test fixtures; null is represented by M.null.
local M = {null={}}

function M.read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  local pos = 1
  local function whitespace()
    local _, last = text:find("^[ \t\r\n]*", pos)
    pos = last + 1
  end
  local value
  local function string_value()
    assert(text:sub(pos,pos) == '"')
    pos = pos + 1
    local out = {}
    while pos <= #text do
      local char = text:sub(pos,pos)
      pos = pos + 1
      if char == '"' then return table.concat(out) end
      if char == "\\" then
        local escape = text:sub(pos,pos)
        pos = pos + 1
        local escapes = {['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t'}
        assert(escapes[escape], "unsupported JSON escape")
        char = escapes[escape]
      end
      out[#out+1] = char
    end
    error("unterminated JSON string")
  end
  value = function()
    whitespace()
    local char = text:sub(pos,pos)
    if char == '"' then return string_value() end
    if char == '[' or char == '{' then
      local object, close = char == '{', char == '{' and '}' or ']'
      local result = {}
      pos = pos + 1
      whitespace()
      if text:sub(pos,pos) == close then pos=pos+1; return result end
      while true do
        if object then
          whitespace()
          local key = string_value()
          whitespace()
          assert(text:sub(pos,pos) == ':'); pos=pos+1
          result[key] = value()
        else
          result[#result+1] = value()
        end
        whitespace()
        local separator = text:sub(pos,pos); pos=pos+1
        if separator == close then return result end
        assert(separator == ',', "invalid JSON separator")
      end
    end
    local literals = {['true']=true, ['false']=false, ['null']=M.null}
    for literal, result in pairs(literals) do
      if text:sub(pos,pos+#literal-1) == literal then pos=pos+#literal; return result end
    end
    local number = text:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    assert(number and tonumber(number), "invalid JSON value at " .. pos)
    pos = pos + #number
    return tonumber(number)
  end
  local result = value()
  whitespace()
  assert(pos == #text+1, "trailing JSON input")
  return result
end

return M
