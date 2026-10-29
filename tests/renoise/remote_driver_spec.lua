local script_directory = arg[0]:match("^(.*[/\\])") or ""
local driver_path = script_directory .. "driver/remote_driver.lua"

local function valid_configuration()
  return table.concat({
    "bind_address=127.0.0.1",
    "port=51234",
    "token=" .. string.rep("a", 64),
    "nonce=" .. string.rep("b", 64)
  }, "\n")
end

local function write_configuration(contents)
  local path = os.tmpname()
  local file, err = io.open(path, "wb")
  assert(file, err)
  assert(file:write(contents))
  file:close()
  return path
end

local function install_renoise_stub(options)
  options = options or {}
  local state = {
    bind_calls = 0,
    callbacks = nil,
    stopped = 0,
    notifier = nil,
    removals = 0
  }
  local observable = {}
  function observable:add_notifier(notifier)
    self.notifier = notifier
    state.notifier = notifier
  end
  function observable:has_notifier(notifier)
    return self.notifier == notifier
  end
  function observable:remove_notifier(notifier)
    assert(self.notifier == notifier)
    self.notifier = nil
    state.removals = state.removals + 1
  end
  _G.renoise = {
    Socket = {
      PROTOCOL_TCP = 1,
      create_server = function(address, port, protocol)
        state.bind_calls = state.bind_calls + 1
        state.address = address
        state.port = port
        state.protocol = protocol
        if options.bind_error then
          return nil, options.bind_error
        end
        return {
          run = function(_, callbacks)
            state.callbacks = callbacks
          end,
          stop = function()
            state.stopped = state.stopped + 1
          end
        }
      end
    },
    tool = function()
      return {tool_will_unload_observable = observable}
    end
  }
  return state
end

local function expect_rejected(contents, expected_fragment)
  local path = write_configuration(contents)
  local state = install_renoise_stub()
  local driver = dofile(driver_path)
  local ok, err = pcall(function() driver.start(path) end)
  os.remove(path)
  assert(not ok, "invalid driver configuration was accepted")
  assert(tostring(err):find(expected_fragment, 1, true), tostring(err))
  assert(state.bind_calls == 0, "invalid configuration reached the socket API")
end

expect_rejected("", "incomplete")
expect_rejected(valid_configuration():gsub("127%.0%.0%.1", "0.0.0.0"), "loopback")
expect_rejected(valid_configuration():gsub("token=" .. string.rep("a", 64), "token=missing"), "test secrets")
expect_rejected(valid_configuration() .. "\nport=51235", "malformed")
expect_rejected(valid_configuration() .. "\nwindows_session_id=7", "malformed")
expect_rejected(valid_configuration() .. "\nrunner_session_id=" .. string.rep("c", 32), "malformed")

local collision_path = write_configuration(valid_configuration())
local collision_state = install_renoise_stub({bind_error = "address already in use"})
local collision_driver = dofile(driver_path)
local collision_ok, collision_error = pcall(function() collision_driver.start(collision_path) end)
os.remove(collision_path)
assert(not collision_ok, "driver accepted a port collision")
assert(tostring(collision_error):find("address already in use", 1, true), tostring(collision_error))
assert(collision_state.bind_calls == 1, "valid configuration did not attempt exactly one bind")
assert(collision_state.callbacks == nil, "driver started callbacks after a failed bind")
assert(collision_state.notifier == nil, "driver installed unload handling after a failed bind")

local path = write_configuration(valid_configuration())
local state = install_renoise_stub()
local driver = dofile(driver_path)
assert(driver.start(path) == true)
assert(state.bind_calls == 1)
assert(state.address == "127.0.0.1")
assert(state.port == 51234)
assert(state.protocol == 1)
assert(type(state.callbacks.socket_accepted) == "function")
local client_closed = false
state.callbacks.socket_accepted({close = function() client_closed = true end})
assert(client_closed, "unauthenticated client was not closed")

local duplicate_ok = pcall(function() driver.start(path) end)
assert(not duplicate_ok, "driver start was not one-shot")
assert(state.bind_calls == 1)

state.notifier()
assert(state.stopped == 1)
assert(state.removals == 1)
os.remove(path)

print("Renoise development driver admission checks passed")
