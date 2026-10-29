local driver = {}
local server = nil
local started = false
local tool = nil
local unload_observable = nil
local unload_notifier = nil

local function read_configuration(path)
  if type(path) ~= "string" or path == "" then
    error("ACID development driver requires a session configuration path")
  end

  local file, open_error = io.open(path, "rb")
  if not file then
    error("ACID development session configuration is unavailable: " .. tostring(open_error))
  end
  local contents = file:read("*a")
  file:close()

  local allowed = {
    bind_address = true,
    port = true,
    token = true,
    nonce = true
  }
  local values = {}
  for line in contents:gmatch("[^\r\n]+") do
    local key, value = line:match("^([a-z_]+)=([^%s]+)$")
    if not key or not allowed[key] or values[key] then
      error("ACID development session configuration is malformed")
    end
    values[key] = value
  end

  for key in pairs(allowed) do
    if not values[key] then
      error("ACID development session configuration is incomplete")
    end
  end
  if values.bind_address ~= "127.0.0.1" then
    error("ACID development driver only accepts the IPv4 loopback address")
  end
  if not values.port:match("^%d+$") then
    error("ACID development session port is invalid")
  end
  values.port = tonumber(values.port)
  if not values.port or values.port < 1024 or values.port > 65535 then
    error("ACID development session port is out of range")
  end
  if not values.token:match("^[0-9a-f]+$") or #values.token ~= 64 or
      not values.nonce:match("^[0-9a-f]+$") or #values.nonce ~= 64 then
    error("ACID development session test secrets are missing or invalid")
  end
  return values
end

function driver.start(configuration_path)
  if started then
    error("ACID development driver has already been started")
  end
  local configuration = read_configuration(configuration_path)
  local error_message
  server, error_message = renoise.Socket.create_server(
    "127.0.0.1",
    configuration.port,
    renoise.Socket.PROTOCOL_TCP
  )
  if not server then
    error("ACID development listener could not bind its reserved port: " .. tostring(error_message))
  end

  local callbacks = {
    socket_error = function(message)
      print("ACID development listener error: " .. tostring(message))
    end,
    socket_accepted = function(client)
      client:close()
    end
  }
  local ok, run_error = pcall(function()
    server:run(callbacks)
  end)
  if not ok then
    server:stop()
    server = nil
    error("ACID development listener failed to start: " .. tostring(run_error))
  end

  tool = renoise.tool()
  unload_observable = tool.tool_will_unload_observable
  unload_notifier = function()
    if server then
      server:stop()
      server = nil
    end
    if unload_observable and unload_notifier and unload_observable:has_notifier(unload_notifier) then
      unload_observable:remove_notifier(unload_notifier)
    end
    unload_observable = nil
    unload_notifier = nil
    tool = nil
  end
  unload_observable:add_notifier(unload_notifier)
  started = true
  return true
end

return driver
