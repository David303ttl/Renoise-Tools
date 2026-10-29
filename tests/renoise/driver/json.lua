local json = {}

local ARRAY = {}
local OBJECT = {}

json.null = setmetatable({}, {__tostring = function() return "null" end})

function json.array(values)
  return setmetatable(values or {}, ARRAY)
end

function json.is_array(value)
  return type(value) == "table" and getmetatable(value) == ARRAY
end

function json.is_object(value)
  return type(value) == "table" and getmetatable(value) == OBJECT
end

local function fail(message)
  error("invalid JSON: " .. message, 0)
end

local function utf8_length(value, index)
  local first = value:byte(index)
  if first <= 0x7f then return 1 end

  local second = value:byte(index + 1)
  if first >= 0xc2 and first <= 0xdf then
    if second and second >= 0x80 and second <= 0xbf then return 2 end
  elseif first == 0xe0 then
    local third = value:byte(index + 2)
    if second and second >= 0xa0 and second <= 0xbf and third and third >= 0x80 and third <= 0xbf then return 3 end
  elseif (first >= 0xe1 and first <= 0xec) or (first >= 0xee and first <= 0xef) then
    local third = value:byte(index + 2)
    if second and second >= 0x80 and second <= 0xbf and third and third >= 0x80 and third <= 0xbf then return 3 end
  elseif first == 0xed then
    local third = value:byte(index + 2)
    if second and second >= 0x80 and second <= 0x9f and third and third >= 0x80 and third <= 0xbf then return 3 end
  elseif first == 0xf0 then
    local third = value:byte(index + 2)
    local fourth = value:byte(index + 3)
    if second and second >= 0x90 and second <= 0xbf and third and third >= 0x80 and third <= 0xbf and fourth and fourth >= 0x80 and fourth <= 0xbf then return 4 end
  elseif first >= 0xf1 and first <= 0xf3 then
    local third = value:byte(index + 2)
    local fourth = value:byte(index + 3)
    if second and second >= 0x80 and second <= 0xbf and third and third >= 0x80 and third <= 0xbf and fourth and fourth >= 0x80 and fourth <= 0xbf then return 4 end
  elseif first == 0xf4 then
    local third = value:byte(index + 2)
    local fourth = value:byte(index + 3)
    if second and second >= 0x80 and second <= 0x8f and third and third >= 0x80 and third <= 0xbf and fourth and fourth >= 0x80 and fourth <= 0xbf then return 4 end
  end
  return nil
end

local function append_codepoint(parts, codepoint)
  if codepoint <= 0x7f then
    parts[#parts + 1] = string.char(codepoint)
  elseif codepoint <= 0x7ff then
    parts[#parts + 1] = string.char(
      0xc0 + math.floor(codepoint / 0x40),
      0x80 + (codepoint % 0x40)
    )
  elseif codepoint <= 0xffff then
    parts[#parts + 1] = string.char(
      0xe0 + math.floor(codepoint / 0x1000),
      0x80 + (math.floor(codepoint / 0x40) % 0x40),
      0x80 + (codepoint % 0x40)
    )
  else
    parts[#parts + 1] = string.char(
      0xf0 + math.floor(codepoint / 0x40000),
      0x80 + (math.floor(codepoint / 0x1000) % 0x40),
      0x80 + (math.floor(codepoint / 0x40) % 0x40),
      0x80 + (codepoint % 0x40)
    )
  end
end

function json.decode(text)
  if type(text) ~= "string" then fail("input must be a string") end

  local length = #text
  local position = 1
  local node_count = 0

  local function skip_space()
    while position <= length do
      local byte = text:byte(position)
      if byte == 0x20 or byte == 0x09 or byte == 0x0a or byte == 0x0d then
        position = position + 1
      else
        break
      end
    end
  end

  local function parse_string()
    if text:byte(position) ~= 0x22 then fail("expected string") end
    position = position + 1
    local parts = {}
    local segment_start = position
    while position <= length do
      local byte = text:byte(position)
      if byte == 0x22 then
        if position > segment_start then
          parts[#parts + 1] = text:sub(segment_start, position - 1)
        end
        position = position + 1
        return table.concat(parts)
      elseif byte == 0x5c then
        if position > segment_start then
          parts[#parts + 1] = text:sub(segment_start, position - 1)
        end
        position = position + 1
        local escape = text:sub(position, position)
        if escape == '"' or escape == "\\" or escape == "/" then
          parts[#parts + 1] = escape
          position = position + 1
        elseif escape == "b" then
          parts[#parts + 1] = string.char(8)
          position = position + 1
        elseif escape == "f" then
          parts[#parts + 1] = string.char(12)
          position = position + 1
        elseif escape == "n" then
          parts[#parts + 1] = "\n"
          position = position + 1
        elseif escape == "r" then
          parts[#parts + 1] = "\r"
          position = position + 1
        elseif escape == "t" then
          parts[#parts + 1] = "\t"
          position = position + 1
        elseif escape == "u" then
          local digits = text:sub(position + 1, position + 4)
          if #digits ~= 4 or not digits:match("^%x%x%x%x$") then fail("bad unicode escape") end
          local codepoint = tonumber(digits, 16)
          position = position + 5
          if codepoint >= 0xd800 and codepoint <= 0xdbff then
            if text:sub(position, position + 1) ~= "\\u" then fail("unpaired high surrogate") end
            local low_digits = text:sub(position + 2, position + 5)
            if #low_digits ~= 4 or not low_digits:match("^%x%x%x%x$") then fail("bad low surrogate") end
            local low = tonumber(low_digits, 16)
            if low < 0xdc00 or low > 0xdfff then fail("bad low surrogate") end
            codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
            position = position + 6
          elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
            fail("unpaired low surrogate")
          end
          append_codepoint(parts, codepoint)
        else
          fail("bad string escape")
        end
        segment_start = position
      elseif byte < 0x20 then
        fail("unescaped control character")
      elseif byte >= 0x80 then
        local sequence_length = utf8_length(text, position)
        if not sequence_length then fail("invalid UTF-8") end
        position = position + sequence_length
      else
        position = position + 1
      end
    end
    fail("unterminated string")
  end

  local parse_value
  parse_value = function(depth)
    if depth > 32 then fail("nesting limit exceeded") end
    node_count = node_count + 1
    if node_count > 10000 then fail("value limit exceeded") end
    skip_space()

    local byte = text:byte(position)
    if byte == 0x22 then
      return parse_string()
    elseif byte == 0x7b then
      position = position + 1
      skip_space()
      local object = setmetatable({}, OBJECT)
      local seen = {}
      if text:byte(position) == 0x7d then
        position = position + 1
        return object
      end
      while true do
        skip_space()
        if text:byte(position) ~= 0x22 then fail("object key must be a string") end
        local key = parse_string()
        if seen[key] then fail("duplicate object key") end
        seen[key] = true
        skip_space()
        if text:byte(position) ~= 0x3a then fail("expected colon") end
        position = position + 1
        object[key] = parse_value(depth + 1)
        skip_space()
        local delimiter = text:byte(position)
        if delimiter == 0x7d then
          position = position + 1
          return object
        elseif delimiter == 0x2c then
          position = position + 1
        else
          fail("expected comma or closing brace")
        end
      end
    elseif byte == 0x5b then
      position = position + 1
      skip_space()
      local array = setmetatable({}, ARRAY)
      if text:byte(position) == 0x5d then
        position = position + 1
        return array
      end
      while true do
        array[#array + 1] = parse_value(depth + 1)
        skip_space()
        local delimiter = text:byte(position)
        if delimiter == 0x5d then
          position = position + 1
          return array
        elseif delimiter == 0x2c then
          position = position + 1
        else
          fail("expected comma or closing bracket")
        end
      end
    elseif byte == 0x74 and text:sub(position, position + 3) == "true" then
      position = position + 4
      return true
    elseif byte == 0x66 and text:sub(position, position + 4) == "false" then
      position = position + 5
      return false
    elseif byte == 0x6e and text:sub(position, position + 3) == "null" then
      position = position + 4
      return json.null
    elseif byte == 0x2d or (byte and byte >= 0x30 and byte <= 0x39) then
      local start = position
      if text:byte(position) == 0x2d then position = position + 1 end
      local integer_byte = text:byte(position)
      if integer_byte == 0x30 then
        position = position + 1
        local next_byte = text:byte(position)
        if next_byte and next_byte >= 0x30 and next_byte <= 0x39 then fail("leading zero in number") end
      elseif integer_byte and integer_byte >= 0x31 and integer_byte <= 0x39 then
        repeat position = position + 1 until not (text:byte(position) and text:byte(position) >= 0x30 and text:byte(position) <= 0x39)
      else
        fail("bad number")
      end
      if text:byte(position) == 0x2e then
        position = position + 1
        local fraction_byte = text:byte(position)
        if not (fraction_byte and fraction_byte >= 0x30 and fraction_byte <= 0x39) then fail("bad fraction") end
        repeat position = position + 1 until not (text:byte(position) and text:byte(position) >= 0x30 and text:byte(position) <= 0x39)
      end
      local exponent_byte = text:byte(position)
      if exponent_byte == 0x65 or exponent_byte == 0x45 then
        position = position + 1
        local sign_byte = text:byte(position)
        if sign_byte == 0x2b or sign_byte == 0x2d then position = position + 1 end
        local digit = text:byte(position)
        if not (digit and digit >= 0x30 and digit <= 0x39) then fail("bad exponent") end
        repeat position = position + 1 until not (text:byte(position) and text:byte(position) >= 0x30 and text:byte(position) <= 0x39)
      end
      local number = tonumber(text:sub(start, position - 1))
      if not number or number ~= number or number == math.huge or number == -math.huge then fail("number is out of range") end
      return number
    end
    fail("unexpected value")
  end

  local value = parse_value(0)
  skip_space()
  if position <= length then fail("trailing data") end
  return value
end

local function encode_string(value)
  local parts = {'"'}
  local index = 1
  while index <= #value do
    local byte = value:byte(index)
    if byte == 0x22 then
      parts[#parts + 1] = '\\"'
      index = index + 1
    elseif byte == 0x5c then
      parts[#parts + 1] = "\\\\"
      index = index + 1
    elseif byte == 8 then
      parts[#parts + 1] = "\\b"
      index = index + 1
    elseif byte == 12 then
      parts[#parts + 1] = "\\f"
      index = index + 1
    elseif byte == 10 then
      parts[#parts + 1] = "\\n"
      index = index + 1
    elseif byte == 13 then
      parts[#parts + 1] = "\\r"
      index = index + 1
    elseif byte == 9 then
      parts[#parts + 1] = "\\t"
      index = index + 1
    elseif byte < 0x20 then
      parts[#parts + 1] = string.format("\\u%04x", byte)
      index = index + 1
    elseif byte >= 0x80 then
      local sequence_length = utf8_length(value, index)
      if not sequence_length then error("cannot encode invalid UTF-8", 0) end
      parts[#parts + 1] = value:sub(index, index + sequence_length - 1)
      index = index + sequence_length
    else
      parts[#parts + 1] = string.char(byte)
      index = index + 1
    end
  end
  parts[#parts + 1] = '"'
  return table.concat(parts)
end

function json.encode(value)
  local active = {}
  local nodes = 0

  local function encode_value(item, depth)
    if depth > 32 then error("JSON nesting limit exceeded", 0) end
    nodes = nodes + 1
    if nodes > 10000 then error("JSON value limit exceeded", 0) end
    local kind = type(item)
    if item == json.null then
      return "null"
    elseif kind == "nil" then
      error("cannot encode nil as JSON", 0)
    elseif kind == "boolean" then
      return item and "true" or "false"
    elseif kind == "number" then
      if item ~= item or item == math.huge or item == -math.huge then error("cannot encode non-finite number", 0) end
      return string.format("%.17g", item)
    elseif kind == "string" then
      return encode_string(item)
    elseif kind ~= "table" then
      error("cannot encode " .. kind, 0)
    end

    if active[item] then error("cannot encode cyclic table", 0) end
    active[item] = true
    local result
    if getmetatable(item) == ARRAY then
      local count = #item
      local parts = {}
      for index = 1, count do
        if item[index] == nil then error("JSON array has a hole", 0) end
        parts[index] = encode_value(item[index], depth + 1)
      end
      for key in pairs(item) do
        if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
          error("JSON array has a non-sequence key", 0)
        end
      end
      result = "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for key in pairs(item) do
        if type(key) ~= "string" then error("JSON object keys must be strings", 0) end
        keys[#keys + 1] = key
      end
      table.sort(keys)
      local parts = {}
      for index, key in ipairs(keys) do
        parts[index] = encode_string(key) .. ":" .. encode_value(item[key], depth + 1)
      end
      result = "{" .. table.concat(parts, ",") .. "}"
    end
    active[item] = nil
    return result
  end

  return encode_value(value, 0)
end

return json
