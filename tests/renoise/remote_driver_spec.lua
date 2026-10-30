local script_directory = arg[0]:match("^(.*[/\\])") or ""
local driver_path = script_directory .. "driver/remote_driver.lua"
local codec_path = script_directory .. "driver/json.lua"
local codec = dofile(codec_path)
local token = string.rep("a", 64)
local nonce = string.rep("b", 64)
local fake_time = 1000
local original_time = os.time
os.time = function() return math.floor(fake_time) end

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function valid_configuration()
  return table.concat({
    "bind_address=127.0.0.1",
    "port=51234",
    "token=" .. token,
    "nonce=" .. nonce
  }, "\n")
end

local function write_configuration(contents)
  local path = os.tmpname()
  if path:match("^[/\\]") and not path:match("^[A-Za-z]:[/\\]") then
    -- Windows tmpnam may return a root-relative path such as "\\s123.".
    local directory = os.getenv("TEMP") or os.getenv("TMP") or "."
    local separator = package.config:sub(1, 1)
    path = directory:gsub("[/\\]+$", "") .. separator .. path:gsub("^[/\\]+", "")
  end
  local file, err = io.open(path, "wb")
  assert(file, err)
  assert(file:write(contents))
  file:close()
  return path
end

local function expect_bad_json(value)
  local ok = pcall(codec.decode, value)
  assert(not ok, "invalid JSON was accepted: " .. value)
end

local function test_json_codec()
  local value = codec.decode('{"name":"caf\\u00e9","array":[1,true,null,"line\\ntext"],"empty":{}}')
  assert(codec.is_object(value))
  assert(codec.is_array(value.array))
  assert_equal(value.name, "caf\195\169")
  assert_equal(value.array[3], codec.null)
  assert(codec.is_object(value.empty))
  local encoded = codec.encode(value)
  local round_trip = codec.decode(encoded)
  assert_equal(round_trip.array[4], "line\ntext")
  assert_equal(codec.encode(codec.array()), "[]")
  assert_equal(codec.encode(codec.null), "null")

  expect_bad_json('{"a":1,"a":2}')
  expect_bad_json("[1,]")
  expect_bad_json("01")
  expect_bad_json("1e")
  expect_bad_json('"\\uD800"')
  expect_bad_json('"\\uDC00"')
  expect_bad_json('{"a":1} trailing')
  expect_bad_json('"bad' .. string.char(255) .. 'utf8"')
  expect_bad_json('"control' .. string.char(1) .. 'byte"')
  local cyclic = {}
  cyclic.self = cyclic
  assert(not pcall(codec.encode, cyclic), "cyclic Lua table was encoded")
  assert(not pcall(codec.encode, 0 / 0), "non-finite number was encoded")
end

local function new_observable()
  local observable = {notifiers = {}}
  function observable:add_notifier(notifier)
    assert(not self.notifiers[notifier], "duplicate notifier")
    self.notifiers[notifier] = true
  end
  function observable:has_notifier(notifier)
    return self.notifiers[notifier] == true
  end
  function observable:remove_notifier(notifier)
    assert(self.notifiers[notifier], "notifier was not attached")
    self.notifiers[notifier] = nil
  end
  function observable:fire()
    local callbacks = {}
    for notifier in pairs(self.notifiers) do callbacks[#callbacks + 1] = notifier end
    for _, notifier in ipairs(callbacks) do
      if self.notifiers[notifier] then notifier() end
    end
  end
  function observable:count()
    local count = 0
    for _ in pairs(self.notifiers) do count = count + 1 end
    return count
  end
  return observable
end

local function make_note_column()
  return {
    note_value = 121,
    instrument_value = 255,
    volume_value = 255,
    panning_value = 255,
    delay_value = 0,
    effect_number_value = 0,
    effect_amount_value = 0
  }
end

local function make_effect_column()
  return {number_value = 0, amount_value = 0}
end

local function make_line()
  return {
    note_columns = {make_note_column()},
    effect_columns = {make_effect_column()}
  }
end

local function make_phrase(name, number_of_lines)
  local lines = {}
  local phrase = {name = name, number_of_lines = number_of_lines}
  function phrase:line(index)
    local line = lines[index]
    if not line then
      line = make_line()
      lines[index] = line
    end
    return line
  end
  function phrase:column_name(index)
    return "Column " .. tostring(index)
  end
  function phrase:column_is_muted(index)
    return index == 3
  end
  return phrase
end

local function make_song(file_name)
  local phrase = make_phrase("Phrase A", 16)
  local instrument = {name = "Instrument A", phrases = {phrase}}
  local song = {
    file_name = file_name or "",
    instruments = {instrument},
    selected_instrument_index = 1,
    selected_phrase_index = 1,
    selected_instrument = instrument,
    selected_phrase = phrase,
    tool_data = "fixture-source"
  }
  function song:insert_instrument_at(index)
    local instrument = {name = "Instrument " .. tostring(index), phrases = {}}
    table.insert(self.instruments, index, instrument)
    return instrument
  end
  return song, instrument, phrase
end

local function install_host_stub(options)
  options = options or {}
  local state = {
    bind_calls = 0,
    stopped = 0,
    idle = new_observable(),
    release = new_observable(),
    new_document = new_observable(),
    unload = new_observable(),
    bundle_path = "C:\\Dev Workspace\\acid-test\\com.david303ttl.ACID.xrnx",
    song = nil,
    new_song_calls = 0,
    load_song_calls = {},
    callbacks = nil
  }
  state.song = make_song("")
  local tool = {
    bundle_path = state.bundle_path,
    app_idle_observable = state.idle,
    app_release_document_observable = state.release,
    app_new_document_observable = state.new_document,
    tool_will_unload_observable = state.unload
  }
  local app = {}
  function app:new_song_no_template()
    state.new_song_calls = state.new_song_calls + 1
    if options.new_song_error then error("host API failure") end
    if options.nested_idle then state.idle:fire() end
  end
  function app:load_song(path)
    state.load_song_calls[#state.load_song_calls + 1] = path
    if options.load_song_error then error("host API failure") end
  end

  local server = {}
  state.server = server
  function server:run(callbacks)
    state.callbacks = callbacks
  end
  function server:stop()
    state.stopped = state.stopped + 1
  end

  _G.renoise = {
    Socket = {
      PROTOCOL_TCP = 1,
      create_server = function(address, port, protocol)
        state.bind_calls = state.bind_calls + 1
        state.address = address
        state.port = port
        state.protocol = protocol
        if options.bind_error then return nil, options.bind_error end
        return server
      end
    },
    API_VERSION = 6.2,
    RENOISE_VERSION = "3.5.4 Demo",
    app = function() return app end,
    song = function() return state.song end,
    tool = function() return tool end
  }
  return state
end

local function load_driver_for_start()
  local original_dofile = dofile
  _G.dofile = function(path)
    local normalized = tostring(path):gsub("/", "\\")
    local suffix = "__dev\\json.lua"
    if normalized:sub(-#suffix) == suffix then return original_dofile(codec_path) end
    return original_dofile(path)
  end
  local ok, driver = pcall(original_dofile, driver_path)
  if not ok then
    _G.dofile = original_dofile
    error(driver, 0)
  end
  return driver, original_dofile
end

local function start_driver_attempt(options)
  local config_path = write_configuration(valid_configuration())
  local host = install_host_stub(options)
  host.config_path = config_path
  local driver, original_dofile = load_driver_for_start()
  local ok, err = pcall(function()
    driver.start(config_path, options and options.gui_state_reader, options and options.acceptance_runner)
  end)
  _G.dofile = original_dofile
  os.remove(config_path)
  return host, driver, ok, err
end

local function start_driver(options)
  local host, driver, ok, err = start_driver_attempt(options)
  assert(ok, tostring(err))
  return host, driver
end

local function new_client()
  local client = {is_open = true, sent = {}, closed = false, fail_send = false}
  function client:send(message)
    if self.fail_send then return false, "send failed" end
    self.sent[#self.sent + 1] = message
    return true
  end
  function client:close()
    self.is_open = false
    self.closed = true
  end
  return client
end

local function accept(host, client)
  host.callbacks.socket_accepted(client)
end

local function request(id, operation, args, supplied_token)
  return codec.encode({
    id = id,
    op = operation,
    args = args or codec.decode("{}"),
    token = supplied_token or token
  }) .. "\n"
end

local function send_request(host, client, id, operation, args, supplied_token)
  host.callbacks.socket_message(client, request(id, operation, args, supplied_token))
end

local function fire_idle(host, count)
  for _ = 1, count or 1 do host.idle:fire() end
end

local function with_fixture_file(path, available, callback)
  local original_open = io.open
  io.open = function(candidate, mode)
    if candidate == path then
      if available then return {close = function() return true end} end
      return nil, "fixture is unavailable"
    end
    return original_open(candidate, mode)
  end
  local ok, result = pcall(callback)
  io.open = original_open
  if not ok then error(result, 0) end
  return result
end

local function take_responses(client)
  local result = {}
  for _, frame in ipairs(client.sent) do
    assert(frame:sub(-1) == "\n", "response was not newline framed")
    result[#result + 1] = codec.decode(frame:sub(1, -2))
  end
  client.sent = {}
  return result
end

local function find_response(responses, id)
  for _, response in ipairs(responses) do
    if response.id == id then return response end
  end
  return nil
end

local function test_socket_callbacks_with_fresh_wrappers()
  local host,driver=start_driver()
  local client=new_client()
  client.peer_address,client.peer_port="127.0.0.1",52123
  client.local_address,client.local_port="127.0.0.1",51234
  accept(host,client)
  local wrapper=new_client()
  wrapper.peer_address,wrapper.peer_port=client.peer_address,client.peer_port
  wrapper.local_address,wrapper.local_port=client.local_address,client.local_port
  send_request(host,wrapper,"wrapped-ping","ping")
  local weak_wrapper=setmetatable({wrapper},{__mode="v"})
  wrapper=nil
  collectgarbage("collect")
  assert(weak_wrapper[1],"live callback wrapper was not retained")
  fire_idle(host)
  assert(find_response(take_responses(client),"wrapped-ping").ok)
  assert(not weak_wrapper[1].closed and not client.closed,"callback wrapper closed the live connection")
  local foreign=new_client()
  foreign.peer_address,foreign.peer_port=client.peer_address,client.peer_port+1
  foreign.local_address,foreign.local_port=client.local_address,client.local_port
  send_request(host,foreign,"foreign-ping","ping")
  assert(foreign.closed and not client.closed,"another connection was accepted as the active client")
  driver.stop()
  collectgarbage("collect")
  assert(not weak_wrapper[1],"stopped connection retained a callback wrapper")
end

local function test_configuration_and_admission()
  local invalid_configurations = {
    {"", "incomplete"},
    {valid_configuration():gsub("127%.0%.0%.1", "0.0.0.0"), "loopback"},
    {valid_configuration():gsub("token=" .. token, "token=invalid"), "test secrets"},
    {valid_configuration() .. "\nport=51235", "malformed"},
    {valid_configuration() .. "\nrunner_session_id=" .. string.rep("c", 32), "malformed"}
  }
  for _, invalid in ipairs(invalid_configurations) do
    local config_path = write_configuration(invalid[1])
    local rejected_host = install_host_stub()
    local driver = dofile(driver_path)
    local ok, err = pcall(function() driver.start(config_path) end)
    os.remove(config_path)
    assert(not ok and tostring(err):find(invalid[2], 1, true), tostring(err))
    assert_equal(rejected_host.bind_calls, 0, "invalid config reached the socket API")
  end

  local collision_path = write_configuration(valid_configuration())
  local collision_host = install_host_stub({bind_error = "address already in use"})
  local collision_driver, original_dofile = load_driver_for_start()
  local collision_ok, collision_error = pcall(function() collision_driver.start(collision_path) end)
  _G.dofile = original_dofile
  os.remove(collision_path)
  assert(not collision_ok and tostring(collision_error):find("address already in use", 1, true), tostring(collision_error))
  assert_equal(collision_host.bind_calls, 1)
  assert_equal(collision_host.idle:count(), 0, "bind collision attached observers")

  local host, running = start_driver()
  assert_equal(host.bind_calls, 1)
  assert_equal(host.address, "127.0.0.1")
  assert_equal(host.protocol, 1)
  assert(host.callbacks.socket_accepted and host.callbacks.socket_message and host.callbacks.socket_error)
  assert_equal(host.idle:count(), 1)
  assert_equal(host.release:count(), 1)
  assert_equal(host.new_document:count(), 1)
  assert_equal(host.unload:count(), 1)
  local duplicate_start, duplicate_start_error = pcall(function() running.start("unused") end)
  assert(not duplicate_start and tostring(duplicate_start_error):find("already been started", 1, true))
  assert_equal(host.bind_calls, 1, "one-shot start rebound the socket")

  local unauthenticated = new_client()
  accept(host, unauthenticated)
  host.callbacks.socket_message(unauthenticated, request("bad-token", "ping", {}, string.rep("c", 64)))
  assert_equal(#unauthenticated.sent, 0, "socket callback sent directly instead of queueing")
  fire_idle(host)
  local denied = take_responses(unauthenticated)
  assert_equal(find_response(denied, "bad-token").error.code, "unauthorized")
  assert(unauthenticated.closed, "wrong-token client was not closed")

  local client = new_client()
  accept(host, client)
  local ping = request("ping-1", "ping")
  host.callbacks.socket_message(client, ping:sub(1, 11))
  host.callbacks.socket_message(client, ping:sub(12))
  assert_equal(#client.sent, 0, "fragmented request completed before idle dispatch")
  fire_idle(host)
  local ping_responses = take_responses(client)
  local pong = find_response(ping_responses, "ping-1")
  assert(pong and pong.ok)
  assert_equal(pong.result.protocol_version, 1)
  assert_equal(pong.result.session, nonce)

  host.callbacks.socket_message(client, request("caps", "capabilities") .. request("diag", "diagnostics"))
  assert_equal(#client.sent, 0, "coalesced commands were processed in the socket callback")
  fire_idle(host)
  local combined = take_responses(client)
  assert(find_response(combined, "caps").ok)
  assert(find_response(combined, "diag").ok)
  assert_equal(find_response(combined, "caps").result.api_version, 6.2)

  local second = new_client()
  accept(host, second)
  assert(second.closed, "a second client was accepted during an authenticated session")

  local wrong_token = request("wrong-active", "ping", {}, string.rep("d", 64))
  host.callbacks.socket_message(client, wrong_token)
  fire_idle(host)
  local rejected = take_responses(client)
  assert_equal(find_response(rejected, "wrong-active").error.code, "unauthorized")
  assert(client.closed, "active session survived a wrong token")
  running.stop()
end

local function test_validation_framing_and_queue_limits()
  local host, driver = start_driver()
  local overlong = new_client()
  accept(host, overlong)
  host.callbacks.socket_message(overlong, string.rep("x", driver._limits().max_frame_bytes + 1))
  assert(overlong.closed, "overlong frame was retained")

  local malformed = new_client()
  accept(host, malformed)
  host.callbacks.socket_message(malformed, '{"id":}\n')
  assert(malformed.closed, "malformed JSON did not close the candidate")

  local client = new_client()
  accept(host, client)
  send_request(host, client, "unsupported", "eval", {})
  send_request(host, client, "bad-args", "ping", {unexpected = "value"})
  send_request(host, client, "path-traversal", "document.load_fixture", {root = "fixtures", name = "..\\secret.xrns"})
  fire_idle(host)
  local invalid = take_responses(client)
  assert_equal(find_response(invalid, "unsupported").error.code, "unsupported_operation")
  assert_equal(find_response(invalid, "bad-args").error.code, "invalid_arguments")
  assert_equal(find_response(invalid, "path-traversal").error.code, "invalid_arguments")
  assert_equal(#host.load_song_calls, 0, "invalid fixture path reached the host")

  local frames = {}
  for index = 1, driver._limits().max_live_ids + 2 do
    frames[#frames + 1] = request("queue-" .. tostring(index), "ping")
  end
  host.callbacks.socket_message(client, table.concat(frames))
  local responses = {}
  for _ = 1, 20 do
    fire_idle(host)
    local batch = take_responses(client)
    for _, response in ipairs(batch) do responses[#responses + 1] = response end
    if #responses == #frames then break end
  end
  assert_equal(#responses, #frames, "bounded queue did not settle all accepted/rejected commands")
  assert_equal(find_response(responses, "queue-33").error.code, "queue_full")
  assert_equal(find_response(responses, "queue-34").error.code, "queue_full")
  for index = 1, 32 do assert(find_response(responses, "queue-" .. tostring(index)).ok) end

  local phrases = {}
  for index = 1, driver._limits().max_snapshot_phrases + 1 do
    phrases[index] = {name = "Phrase", number_of_lines = 1}
  end
  host.song.instruments[1].phrases = phrases
  send_request(host, client, "snapshot-bound", "song.snapshot")
  fire_idle(host)
  local bounded = find_response(take_responses(client), "snapshot-bound")
  assert(bounded and not bounded.ok)
  assert_equal(bounded.error.code, "snapshot_limit")
  driver.stop()
end

local function test_snapshot_waits_and_document_transitions()
  local host, driver = start_driver()
  local client = new_client()
  accept(host, client)

  send_request(host, client, "snapshot-1", "song.snapshot")
  fire_idle(host)
  local snapshot_response = find_response(take_responses(client), "snapshot-1")
  assert(snapshot_response and snapshot_response.ok)
  local snapshot = snapshot_response.result
  assert_equal(snapshot.document_epoch, 1)
  assert_equal(snapshot.instrument_count, 1)
  assert_equal(snapshot.phrase_count, 1)
  assert_equal(snapshot.instruments[1].phrases[1].number_of_lines, 16)
  assert_equal(snapshot.selected_instrument_index, 1)
  assert_equal(snapshot.selected_phrase_index, 1)

  send_request(host, client, "wait-selection", "wait.condition", {
    condition = "selection_equals_expected",
    instrument_index = 1,
    phrase_index = 1,
    timeout_ms = 1000
  })
  fire_idle(host)
  assert(find_response(take_responses(client), "wait-selection").ok)

  send_request(host, client, "wait-inventory", "wait.condition", {
    condition = "native_inventory_matches",
    instrument_count = 1,
    phrase_count = 1,
    timeout_ms = 1000
  })
  fire_idle(host)
  assert_equal(#take_responses(client), 0, "inventory wait completed before a post-load idle observation")
  local phrase = host.song.instruments[1].phrases[1]
  host.song.instruments[1].phrases = {}
  fire_idle(host)
  assert_equal(#take_responses(client), 0, "inventory mismatch did not reset idle settlement")
  host.song.instruments[1].phrases = {phrase}
  fire_idle(host)
  assert_equal(#take_responses(client), 0, "inventory wait accepted one matching idle observation")
  fire_idle(host)
  local inventory_response = find_response(take_responses(client), "wait-inventory")
  assert(inventory_response and inventory_response.ok, "inventory wait did not settle after consecutive idle observations")
  assert_equal(inventory_response.result.matching_idle_cycles, 2)
  assert_equal(inventory_response.result.idle_settlement_observed, true)
  send_request(host, client, "inventory-diagnostics", "diagnostics")
  fire_idle(host)
  local inventory_diagnostics = find_response(take_responses(client), "inventory-diagnostics")
  assert(inventory_diagnostics and inventory_diagnostics.ok)
  assert_equal(inventory_diagnostics.result.native_inventory_settlement.document_epoch, 1)
  assert_equal(inventory_diagnostics.result.native_inventory_settlement.matching_idle_cycles, 2)
  assert_equal(inventory_diagnostics.result.native_inventory_settlement.idle_settlement_observed, true)

  send_request(host, client, "duplicate", "ping")
  send_request(host, client, "duplicate", "ping")
  assert_equal(#client.sent, 0, "duplicate request was answered in the socket callback")
  fire_idle(host)
  assert_equal(host.new_song_calls, 0, "duplicate request dispatched queued host work")
  local duplicate_response = find_response(take_responses(client), "duplicate")
  assert_equal(duplicate_response.error.code, "duplicate_id")
  assert(client.closed, "duplicate live id did not retire the ambiguous session")

  client = new_client()
  accept(host, client)
  send_request(host, client, "transition", "document.new")
  assert_equal(host.new_song_calls, 0, "document operation ran in socket callback")
  fire_idle(host)
  assert_equal(host.new_song_calls, 1)

  send_request(host, client, "epoch-wait", "wait.condition", {
    condition = "document_epoch_changed",
    after_epoch = 1,
    timeout_ms = 5000
  })
  fire_idle(host)
  local new_song = make_song("")
  host.release:fire()
  host.song = new_song
  host.new_document:fire()
  fire_idle(host)
  local new_responses = take_responses(client)
  local transition_response = find_response(new_responses, "transition")
  local epoch_response = find_response(new_responses, "epoch-wait")
  assert(transition_response and transition_response.ok)
  assert_equal(transition_response.result.document_epoch, 2)
  assert(epoch_response and epoch_response.ok)
  assert_equal(epoch_response.result.document_epoch, 2)

  send_request(host, client, "settled-wait", "wait.condition", {
    condition = "observed_operation_settled",
    command_id = "transition",
    timeout_ms = 1000
  })
  fire_idle(host)
  assert(find_response(take_responses(client), "settled-wait").ok)

  send_request(host, client, "transition", "ping")
  fire_idle(host)
  local reused = find_response(take_responses(client), "transition")
  assert(reused and not reused.ok)
  assert_equal(reused.error.code, "duplicate_id")

  local expected_path = "C:\\Dev Workspace\\acid-test\\fixtures\\smoke.xrns"
  send_request(host, client, "missing-fixture", "document.load_fixture", {root = "fixtures", name = "missing.xrns"})
  with_fixture_file("C:\\Dev Workspace\\acid-test\\fixtures\\missing.xrns", false, function()
    fire_idle(host)
  end)
  local missing_fixture = find_response(take_responses(client), "missing-fixture")
  assert(missing_fixture and not missing_fixture.ok)
  assert_equal(missing_fixture.error.code, "fixture_unavailable")
  assert_equal(#host.load_song_calls, 0, "missing fixture reached the native loader")

  send_request(host, client, "load-fixture", "document.load_fixture", {root = "fixtures", name = "smoke.xrns"})
  with_fixture_file(expected_path, true, function()
    fire_idle(host)
  end)
  assert_equal(#host.load_song_calls, 1)
  assert_equal(host.load_song_calls[1], expected_path)
  assert_equal(#client.sent, 0, "fixture load completed before a new-document observation")
  local loaded_song = make_song("c:/Dev Workspace/acid-test/fixtures/smoke.xrns")
  host.release:fire()
  host.song = loaded_song
  host.new_document:fire()
  fire_idle(host)
  local load_response = find_response(take_responses(client), "load-fixture")
  assert(load_response and load_response.ok)
  assert_equal(load_response.result.document_epoch, 3)

  send_request(host, client, "snapshot-2", "song.snapshot")
  fire_idle(host)
  local second_snapshot = find_response(take_responses(client), "snapshot-2").result
  assert_equal(second_snapshot.document_epoch, 3)

  local weak_phrase
  do
    local transient_phrase = make_phrase("Transient", 1)
    weak_phrase = setmetatable({transient_phrase}, {__mode = "v"})
    host.song.instruments[1].phrases = {transient_phrase}
    host.song.selected_phrase = transient_phrase
    send_request(host, client, "transient-snapshot", "song.snapshot")
    fire_idle(host)
    assert(find_response(take_responses(client), "transient-snapshot").ok)
  end
  local replacement_phrase = make_phrase("Replacement", 1)
  host.song.instruments[1].phrases = {replacement_phrase}
  host.song.selected_phrase = replacement_phrase
  send_request(host, client, "prune-deleted", "song.snapshot")
  fire_idle(host)
  take_responses(client)
  collectgarbage("collect")
  assert(weak_phrase[1] == nil, "snapshot retained a deleted host phrase")

  send_request(host, client, "cancel-on-release", "wait.condition", {
    condition = "selection_equals_expected",
    instrument_index = 999,
    phrase_index = 999,
    timeout_ms = 5000
  })
  fire_idle(host)
  local external_song = make_song("")
  host.release:fire()
  host.song = external_song
  host.new_document:fire()
  fire_idle(host)
  local canceled = find_response(take_responses(client), "cancel-on-release")
  assert(canceled and not canceled.ok)
  assert_equal(canceled.error.code, "canceled")
  driver.stop()
end

local function test_host_document_errors()
  local cases = {
    {option = "new_song_error", operation = "document.new", args = {}},
    {option = "load_song_error", operation = "document.load_fixture", args = {root = "fixtures", name = "smoke.xrns"}}
  }
  for _, case in ipairs(cases) do
    local options = {[case.option] = true}
    local host, driver = start_driver(options)
    local client = new_client()
    accept(host, client)
    local original_song = host.song

    send_request(host, client, "host-failure", case.operation, case.args)
    if case.operation == "document.load_fixture" then
      with_fixture_file("C:\\Dev Workspace\\acid-test\\fixtures\\smoke.xrns", true, function()
        fire_idle(host)
      end)
    else
      fire_idle(host)
    end
    local failed = find_response(take_responses(client), "host-failure")
    assert(failed and not failed.ok)
    assert_equal(failed.error.code, "host_error")
    assert(rawequal(host.song, original_song), "failed document command changed the current song")

    send_request(host, client, "failure-diagnostics", "diagnostics")
    send_request(host, client, "failure-ping", "ping")
    fire_idle(host, 2)
    local responses = take_responses(client)
    local diagnostics = find_response(responses, "failure-diagnostics")
    assert(diagnostics and diagnostics.ok)
    assert_equal(diagnostics.result.document_transition_uncertain, false)
    assert(find_response(responses, "failure-ping").ok, "driver stopped after a host command error")
    driver.stop()
  end
end

local function test_deadlines_and_late_document_events()
  fake_time = 1800
  local observed_host, observed_driver = start_driver()
  local observed_client = new_client()
  accept(observed_host, observed_client)
  send_request(observed_host, observed_client, "observed-before-deadline", "document.new", {timeout_ms = 1000})
  fire_idle(observed_host)
  assert_equal(observed_host.new_song_calls, 1)
  fake_time = 1801
  observed_host.release:fire()
  observed_host.song = make_song("")
  observed_host.new_document:fire()
  fake_time = 1803
  fire_idle(observed_host)
  local observed_result = find_response(take_responses(observed_client), "observed-before-deadline")
  assert(observed_result and observed_result.ok, "observed document transition expired before idle settlement")
  assert_equal(observed_result.result.document_epoch, 2)
  observed_driver.stop()

  fake_time = 1900
  local late_observed_host, late_observed_driver = start_driver()
  local late_observed_client = new_client()
  accept(late_observed_host, late_observed_client)
  send_request(late_observed_host, late_observed_client, "observed-after-deadline", "document.new", {timeout_ms = 1000})
  fire_idle(late_observed_host)
  fake_time = 1902
  late_observed_host.release:fire()
  late_observed_host.song = make_song("")
  late_observed_host.new_document:fire()
  fire_idle(late_observed_host)
  local late_observed_result = find_response(take_responses(late_observed_client), "observed-after-deadline")
  assert(late_observed_result and not late_observed_result.ok)
  assert_equal(late_observed_result.error.code, "timeout")
  send_request(late_observed_host, late_observed_client, "late-transition-diagnostics", "diagnostics")
  fire_idle(late_observed_host)
  local late_diagnostics = find_response(take_responses(late_observed_client), "late-transition-diagnostics")
  assert(late_diagnostics and late_diagnostics.ok)
  assert_equal(late_diagnostics.result.document_transition_uncertain, false)
  late_observed_driver.stop()

  fake_time = 2000.9
  local host, driver = start_driver()
  local client = new_client()
  accept(host, client)

  send_request(host, client, "wait-timeout", "wait.condition", {
    condition = "document_epoch_changed",
    after_epoch = 99,
    timeout_ms = 1000
  })
  fire_idle(host)
  assert_equal(#client.sent, 0)
  fake_time = fake_time + 0.2
  fire_idle(host)
  assert_equal(#client.sent, 0, "whole-second deadline expired before the requested duration")
  fake_time = fake_time + 1
  fire_idle(host)
  local timed_out = find_response(take_responses(client), "wait-timeout")
  assert(timed_out and not timed_out.ok)
  assert_equal(timed_out.error.code, "timeout")

  send_request(host, client, "old-document", "document.new", {timeout_ms = 1000})
  fire_idle(host)
  assert_equal(host.new_song_calls, 1)
  fake_time = fake_time + 2
  fire_idle(host)
  local old_result = find_response(take_responses(client), "old-document")
  assert(old_result and not old_result.ok)
  assert_equal(old_result.error.code, "timeout")

  send_request(host, client, "blocked-document", "document.new")
  fire_idle(host)
  local blocked = find_response(take_responses(client), "blocked-document")
  assert(blocked and not blocked.ok)
  assert_equal(blocked.error.code, "host_state_uncertain")
  assert_equal(host.new_song_calls, 1, "uncertain document transition dispatched another host action")

  local late_song = make_song("")
  host.release:fire()
  host.song = late_song
  host.new_document:fire()
  fire_idle(host)
  assert_equal(#take_responses(client), 0, "late document event completed an expired command")

  send_request(host, client, "new-after-settle", "document.new")
  fire_idle(host)
  assert_equal(host.new_song_calls, 2)
  local final_song = make_song("")
  host.release:fire()
  host.song = final_song
  host.new_document:fire()
  fire_idle(host)
  local final = find_response(take_responses(client), "new-after-settle")
  assert(final and final.ok)
  driver.stop()
end

local function test_disconnect_reconnect_cleanup_and_failures()
  local host, driver = start_driver({nested_idle = true})
  local client = new_client()
  accept(host, client)
  send_request(host, client, "disconnect", "disconnect")
  fire_idle(host)
  local disconnected = find_response(take_responses(client), "disconnect")
  assert(disconnected and disconnected.ok and disconnected.result.disconnected)
  assert(client.closed, "disconnect command left its socket open")

  local replacement = new_client()
  accept(host, replacement)
  send_request(host, replacement, "reconnect-ping", "ping")
  fire_idle(host)
  assert(find_response(take_responses(replacement), "reconnect-ping").ok)

  local callbacks = host.callbacks
  callbacks.socket_error("simulated server failure")
  fire_idle(host)
  local failure = find_response(take_responses(replacement), codec.null)
  assert(failure and not failure.ok)
  assert_equal(failure.error.code, "host_error")
  assert(replacement.closed, "server failure did not retire the active client")
  assert(host.stopped >= 1, "server failure did not stop listener")

  local final_client = new_client()
  accept(host, final_client)
  assert(final_client.closed, "server accepted a client after failure")
  driver.stop()
  assert_equal(host.idle:count(), 0)
  assert_equal(host.release:count(), 0)
  assert_equal(host.new_document:count(), 0)
  assert_equal(host.unload:count(), 0)
  assert(host.stopped >= 2, "unload/stop did not clean up server")
end

local function test_unload_cleans_pending_document_work()
  local host = start_driver()
  local client = new_client()
  accept(host, client)
  send_request(host, client, "pending", "document.new")
  fire_idle(host)
  assert_equal(host.new_song_calls, 1)
  host.unload:fire()
  assert(client.closed, "unload did not close active socket")
  assert_equal(host.idle:count(), 0)
  assert_equal(host.release:count(), 0)
  assert_equal(host.new_document:count(), 0)
  assert_equal(host.unload:count(), 0)
end

local function test_diagnostics_counts_other_commands()
  local host, driver = start_driver()
  local client = new_client()
  accept(host, client)
  send_request(host, client, "idle-diagnostics", "diagnostics")
  fire_idle(host)
  assert_equal(find_response(take_responses(client), "idle-diagnostics").result.pending_commands, 0)
  send_request(host, client, "pending-wait", "wait.condition", {
    condition = "document_epoch_changed", after_epoch = 99
  })
  send_request(host, client, "busy-diagnostics", "diagnostics")
  fire_idle(host)
  assert_equal(find_response(take_responses(client), "busy-diagnostics").result.pending_commands, 1)
  driver.stop()
end

local function test_gui_state_is_read_from_the_acid_adapter()
  local ui_state = {dialog_visible = false, show_invocations = 0, show_keybinding_registered = true}
  local host, driver = start_driver({gui_state_reader = function()
    return {
      dialog_visible = ui_state.dialog_visible,
      show_invocations = ui_state.show_invocations,
      show_keybinding_registered = ui_state.show_keybinding_registered
    }
  end})
  local client = new_client()
  accept(host, client)
  send_request(host, client, "gui-hidden", "gui.state")
  fire_idle(host)
  local hidden = find_response(take_responses(client), "gui-hidden")
  assert(hidden and hidden.ok)
  assert_equal(hidden.result.dialog_visible, false)
  assert_equal(hidden.result.show_invocations, 0)
  assert_equal(hidden.result.show_keybinding_registered, true)

  ui_state.dialog_visible = true
  ui_state.show_invocations = 1
  send_request(host, client, "gui-visible", "gui.state")
  fire_idle(host)
  local visible = find_response(take_responses(client), "gui-visible")
  assert(visible and visible.ok)
  assert_equal(visible.result.dialog_visible, true)
  assert_equal(visible.result.show_invocations, 1)
  assert_equal(visible.result.show_keybinding_registered, true)

  send_request(host, client, "gui-invalid-args", "gui.state", {visible = true})
  fire_idle(host)
  local invalid = find_response(take_responses(client), "gui-invalid-args")
  assert(invalid and not invalid.ok)
  assert_equal(invalid.error.code, "invalid_arguments")
  driver.stop()
end

local function test_gui_state_fails_closed_without_an_adapter()
  local host, driver = start_driver()
  local client = new_client()
  accept(host, client)
  send_request(host, client, "gui-no-adapter", "gui.state")
  fire_idle(host)
  local response = find_response(take_responses(client), "gui-no-adapter")
  assert(response and not response.ok)
  assert_equal(response.error.code, "gui_state_unavailable")
  driver.stop()
end

local function test_instrument_navigation_setup_inserts_only_when_needed()
  local host, driver = start_driver()
  local client = new_client()
  accept(host, client)
  send_request(host, client, "prepare-navigation", "song.prepare_instrument_navigation")
  fire_idle(host)
  local prepared = find_response(take_responses(client), "prepare-navigation")
  assert(prepared and prepared.ok)
  assert_equal(prepared.result.instrument_count, 2)
  assert_equal(prepared.result.selected_instrument_index, 1)
  assert_equal(#host.song.instruments, 2)

  send_request(host, client, "prepare-navigation-again", "song.prepare_instrument_navigation")
  fire_idle(host)
  local prepared_again = find_response(take_responses(client), "prepare-navigation-again")
  assert(prepared_again and prepared_again.ok)
  assert_equal(prepared_again.result.instrument_count, 2)
  assert_equal(#host.song.instruments, 2, "preparation inserted duplicate instruments")

  send_request(host, client, "prepare-navigation-invalid-args", "song.prepare_instrument_navigation", {index = 2})
  fire_idle(host)
  local invalid = find_response(take_responses(client), "prepare-navigation-invalid-args")
  assert(invalid and not invalid.ok)
  assert_equal(invalid.error.code, "invalid_arguments")
  driver.stop()
end

local function test_fixed_native_acceptance_command()
  local completion
  local host, driver = start_driver({
    acceptance_runner = function(case_name, done)
      assert(case_name == "make-independent" or case_name == "reopen-independent" or
        case_name == "integrity-observers" or case_name == "writer-recovery" or case_name == "editor-responsiveness",
        "fixed native acceptance case was not allowlisted")
      completion = done
      return true
    end
  })
  local client = new_client()
  accept(host, client)
  send_request(host, client, "acceptance-invalid-case", "acid.acceptance.run", {case = "execute"})
  send_request(host, client, "acceptance-invalid-args", "acid.acceptance.run", {case = "make-independent", command = "arbitrary"})
  fire_idle(host)
  local invalid = take_responses(client)
  assert_equal(find_response(invalid, "acceptance-invalid-case").error.code, "invalid_arguments")
  assert_equal(find_response(invalid, "acceptance-invalid-args").error.code, "invalid_arguments")
  assert_equal(completion, nil, "invalid acceptance command reached its runner")

  send_request(host, client, "acceptance-run", "acid.acceptance.run", {case = "make-independent"})
  fire_idle(host)
  assert_equal(find_response(take_responses(client), "acceptance-run"), nil,
    "asynchronous acceptance returned before its native operation settled")
  assert(completion, "fixed acceptance runner was not called")
  assert(completion({status = "PASS", case = "make-independent", new_id = 12}))
  fire_idle(host)
  local result = find_response(take_responses(client), "acceptance-run")
  assert(result and result.ok)
  assert_equal(result.result.status, "PASS")
  assert_equal(result.result.new_id, 12)
  send_request(host, client, "acceptance-reopen", "acid.acceptance.run", {case = "reopen-independent"})
  fire_idle(host)
  assert_equal(find_response(take_responses(client), "acceptance-reopen"), nil,
    "round-trip acceptance returned before its native operation settled")
  assert(completion, "round-trip acceptance runner was not called")
  assert(completion({status = "PASS", case = "reopen-independent", new_id = 12}))
  fire_idle(host)
  local reopened = find_response(take_responses(client), "acceptance-reopen")
  assert(reopened and reopened.ok)
  assert_equal(reopened.result.status, "PASS")
  send_request(host, client, "acceptance-integrity-observers", "acid.acceptance.run", {case = "integrity-observers"})
  fire_idle(host)
  assert_equal(find_response(take_responses(client), "acceptance-integrity-observers"), nil,
    "integrity observer acceptance returned before its native operation settled")
  assert(completion, "integrity observer acceptance runner was not called")
  assert(completion({status = "PASS", case = "integrity-observers", post_commit_blocked = true}))
  fire_idle(host)
  local integrity = find_response(take_responses(client), "acceptance-integrity-observers")
  assert(integrity and integrity.ok)
  assert_equal(integrity.result.status, "PASS")
  send_request(host, client, "acceptance-writer-recovery", "acid.acceptance.run", {case = "writer-recovery"})
  fire_idle(host)
  assert_equal(find_response(take_responses(client), "acceptance-writer-recovery"), nil)
  assert(completion, "writer recovery acceptance runner was not called")
  assert(completion({status = "PASS", case = "writer-recovery"}))
  fire_idle(host)
  local recovery = find_response(take_responses(client), "acceptance-writer-recovery")
  assert(recovery and recovery.ok)
  assert_equal(recovery.result.status, "PASS")
  send_request(host, client, "acceptance-editor-responsiveness", "acid.acceptance.run", {case = "editor-responsiveness"})
  fire_idle(host)
  assert_equal(find_response(take_responses(client), "acceptance-editor-responsiveness"), nil,
    "editor responsiveness acceptance returned before native rendering settled")
  assert(completion, "editor responsiveness acceptance runner was not called")
  assert(completion({status = "PASS", case = "editor-responsiveness", unchanged_snapshot_scans = 0}))
  fire_idle(host)
  local responsiveness = find_response(take_responses(client), "acceptance-editor-responsiveness")
  assert(responsiveness and responsiveness.ok)
  assert_equal(responsiveness.result.status, "PASS")
  driver.stop()
end

local function test_shutdown_records_completion_after_server_stop()
  local host = start_driver()
  local client = new_client()
  accept(host, client)
  -- Renoise stop invalidates accepted sockets, so acknowledge before stopping.
  local original_stop = host.server.stop
  function host.server:stop()
    client.is_open = false
    client.closed = true
    return original_stop(self)
  end
  local close_calls=0
  function client:close()
    close_calls=close_calls+1
    assert(self.is_open,"closed a socket already invalidated by server stop")
    self.is_open=false
    self.closed=true
  end
  local original_send = client.send
  function client:send(frame)
    assert(self.is_open, "sent after server stop invalidated the socket")
    return original_send(self, frame)
  end
  send_request(host, client, "stop-driver", "shutdown")
  fire_idle(host)
  local response = find_response(take_responses(client), "stop-driver")
  assert(response and response.ok and response.result.shutdown_requested)
  assert_equal(host.idle:count(), 0)
  assert_equal(host.release:count(), 0)
  assert_equal(host.new_document:count(), 0)
  assert_equal(host.unload:count(), 0)
  assert(host.stopped > 0)
  assert(client.closed)
  assert_equal(close_calls,0)
  assert_equal(host.new_song_calls, 0)
  local marker_path = host.config_path .. "." .. nonce .. ".stopped"
  local marker = assert(io.open(marker_path, "rb"))
  assert_equal(marker:read("*a"), nonce)
  marker:close()
  os.remove(marker_path)
end

local function test_snapshot_uses_values_with_fresh_host_wrappers()
  local host, driver = start_driver()
  local name = string.rep("Original", 18)
  host.song = setmetatable({}, {__index = function(_, key)
    if key == "instruments" then return {{name = name, phrases = {}}} end
    if key == "selected_instrument_index" then return 1 end
    if key == "selected_phrase_index" then return 0 end
  end})
  host.release:fire()
  host.new_document:fire()
  local client = new_client()
  accept(host, client)
  send_request(host, client, "first-values", "song.snapshot")
  fire_idle(host)
  local first = find_response(take_responses(client), "first-values").result
  collectgarbage("collect")
  send_request(host, client, "same-values", "song.snapshot")
  fire_idle(host)
  local second = find_response(take_responses(client), "same-values").result
  assert_equal(codec.encode(first), codec.encode(second), "host wrappers changed snapshot values")
  assert_equal(second.instruments[1].name, name, "instrument name was truncated")
  assert_equal(second.selected_instrument_index, 1)
  assert_equal(second.selected_phrase_index, 0)
  name = "Changed"
  send_request(host, client, "changed-values", "song.snapshot")
  fire_idle(host)
  local changed = find_response(take_responses(client), "changed-values").result
  assert(codec.encode(changed) ~= codec.encode(first), "native value change was hidden")
  driver.stop()
end

local function test_snapshot_captures_read_only_phrase_state_and_raw_song_bytes()
  local host, driver = start_driver()
  local empty_note = {
    note_value = 121,
    instrument_value = 255,
    volume_value = 255,
    panning_value = 255,
    delay_value = 0,
    effect_number_value = 0,
    effect_amount_value = 0
  }
  local empty_effect = {number_value = 0, amount_value = 0}
  local lines_read = 0
  local mapping = {
    key_tracking = 2,
    base_note = 48,
    note_range = {36, 60},
    looping = false,
    loop_start = 1,
    loop_end = 8
  }
  local lines = {}
  for line_index = 1, 512 do
    local note_columns = {
      empty_note,
      empty_note
    }
    local effect_columns = {empty_effect}
    if line_index == 512 then
      note_columns[2] = {
        note_value = 60,
        instrument_value = 7,
        volume_value = 96,
        panning_value = 255,
        delay_value = 12,
        effect_number_value = 0,
        effect_amount_value = 0
      }
      effect_columns[1] = {number_value = 0x0c, amount_value = 0x40}
    end
    lines[line_index] = {note_columns = note_columns, effect_columns = effect_columns}
  end
  local phrase = {
    name = string.rep("Mapped phrase", 12),
    number_of_lines = 16,
    playback_mode = 1,
    visible_note_columns = 1,
    visible_effect_columns = 0,
    key_tracking = 2,
    base_note = 48,
    looping = false,
    loop_start = 1,
    loop_end = 16,
    autoseek = false,
    lpb = 4,
    shuffle = 0,
    instrument_column_visible = false,
    volume_column_visible = true,
    panning_column_visible = false,
    delay_column_visible = false,
    sample_effects_column_visible = false,
    mapping = mapping
  }
  function phrase:line(index)
    lines_read = lines_read + 1
    return lines[index]
  end
  function phrase:column_name(index)
    return index == 1 and "Lead" or "Column " .. tostring(index)
  end
  function phrase:column_is_muted(index)
    return index == 2
  end
  local instrument = {
    name = "Instrument A",
    phrases = {phrase},
    phrase_mappings = {mapping}
  }
  local undo_reads, redo_reads, undoing_reads = 0, 0, 0
  host.song = {
    instruments = {instrument},
    selected_instrument_index = 1,
    selected_phrase_index = 1,
    tool_data = string.char(0, 10, 255, 65),
    can_undo = function()
      undo_reads = undo_reads + 1
      return true
    end,
    can_redo = function()
      redo_reads = redo_reads + 1
      return false
    end,
    is_undo_redoing = function()
      undoing_reads = undoing_reads + 1
      return false
    end
  }
  host.release:fire()
  host.new_document:fire()

  local client = new_client()
  accept(host, client)
  send_request(host, client, "rich-snapshot", "song.snapshot")
  fire_idle(host)
  local response = find_response(take_responses(client), "rich-snapshot")
  assert(response and response.ok, response and response.error and response.error.message)
  local snapshot = response.result
  local snapshot_phrase = snapshot.instruments[1].phrases[1]
  local tail_line = snapshot_phrase.lines[1]
  assert_equal(snapshot_phrase.captured_line_count, 512)
  assert_equal(snapshot_phrase.name, phrase.name, "phrase name was truncated")
  assert_equal(snapshot_phrase.number_of_lines, 16)
  assert_equal(#snapshot_phrase.lines, 1)
  assert_equal(tail_line.index, 512, "tail line was omitted")
  assert_equal(tail_line.note_column_count, 2, "hidden note column was omitted")
  assert_equal(tail_line.effect_column_count, 1, "hidden effect column was omitted")
  assert_equal(tail_line.note_columns[1].index, 2)
  assert_equal(tail_line.note_columns[1].note_value, 60)
  assert_equal(tail_line.note_columns[1].delay_value, 12)
  assert_equal(tail_line.effect_columns[1].number_value, 0x0c)
  assert_equal(tail_line.effect_columns[1].amount_value, 0x40)
  assert_equal(snapshot_phrase.properties.instrument_column_visible, false)
  assert_equal(snapshot_phrase.properties.autoseek, false)
  assert_equal(#snapshot_phrase.note_columns, 12, "hidden note-column metadata was omitted")
  assert_equal(snapshot_phrase.note_columns[1].name, "Lead")
  assert_equal(snapshot_phrase.note_columns[1].muted, false)
  assert_equal(snapshot_phrase.note_columns[2].muted, true)
  assert_equal(snapshot_phrase.note_columns[12].index, 12, "tail note-column metadata was omitted")
  assert_equal(snapshot_phrase.mapping.note_range[1], 36)
  assert_equal(snapshot_phrase.mapping.looping, false)
  assert_equal(snapshot.instruments[1].phrase_mappings[1].base_note, 48)
  assert_equal(snapshot.tool_data_present, true)
  assert_equal(snapshot.tool_data_length, 4)
  assert_equal(snapshot.tool_data_hex, "000aff41", "binary song data was not preserved byte-for-byte")
  assert_equal(snapshot.can_undo, true)
  assert_equal(snapshot.can_redo, false, "false undo state was collapsed into null")
  assert_equal(snapshot.is_undo_redoing, false)
  assert_equal(lines_read, 512, "not every native tail line was inspected")
  assert_equal(undo_reads, 1)
  assert_equal(redo_reads, 1)
  assert_equal(undoing_reads, 1)
  assert_equal(host.song.selected_instrument_index, 1, "snapshot changed selected instrument")
  assert_equal(host.song.selected_phrase_index, 1, "snapshot changed selected phrase")
  assert_equal(host.song.tool_data, string.char(0, 10, 255, 65), "snapshot changed tool data")
  driver.stop()
end

local function test_snapshot_encodes_optional_native_data_as_explicit_null()
  local host, driver = start_driver()
  local song = make_song("")
  song.tool_data = nil
  host.song = song
  host.release:fire()
  host.new_document:fire()
  local client = new_client()
  accept(host, client)
  send_request(host, client, "optional-state", "song.snapshot")
  fire_idle(host)
  local response = find_response(take_responses(client), "optional-state")
  assert(response and response.ok)
  local snapshot = response.result
  assert_equal(snapshot.tool_data_present, false)
  assert_equal(snapshot.tool_data_length, 0)
  assert_equal(snapshot.tool_data_hex, codec.null, "missing bytes were not represented by JSON null")
  assert_equal(snapshot.instruments[1].phrases[1].mapping, codec.null, "missing phrase mapping was not represented by JSON null")
  assert_equal(snapshot.can_undo, codec.null, "unavailable undo state was not represented by JSON null")
  assert_equal(snapshot.can_redo, codec.null, "unavailable redo state was not represented by JSON null")
  assert_equal(snapshot.is_undo_redoing, codec.null, "unavailable undo state was not represented by JSON null")

  song.tool_data = string.rep("x", 131073)
  send_request(host, client, "oversized-tool-data", "song.snapshot")
  fire_idle(host)
  local oversized = find_response(take_responses(client), "oversized-tool-data")
  assert(oversized and not oversized.ok)
  assert_equal(oversized.error.code, "snapshot_limit")

  song.tool_data = nil
  local phrases = {}
  for index = 1, 513 do phrases[index] = make_phrase("Phrase " .. tostring(index), 1) end
  song.instruments[1].phrases = phrases
  send_request(host, client, "oversized-inventory", "song.snapshot")
  fire_idle(host)
  local oversized_inventory = find_response(take_responses(client), "oversized-inventory")
  assert(oversized_inventory and not oversized_inventory.ok)
  assert_equal(oversized_inventory.error.code, "snapshot_limit")
  driver.stop()
end

local function test_new_document_requires_preceding_release()
  local host, driver = start_driver()
  local client = new_client()
  accept(host, client)
  send_request(host, client, "unreleased-document", "document.new")
  fire_idle(host)
  host.song = make_song("")
  host.new_document:fire()
  fire_idle(host)
  assert_equal(#take_responses(client), 0, "new song without release completed transition")
  driver.stop()
end
test_new_document_requires_preceding_release()
test_socket_callbacks_with_fresh_wrappers()
test_snapshot_encodes_optional_native_data_as_explicit_null()
test_snapshot_captures_read_only_phrase_state_and_raw_song_bytes()
test_snapshot_uses_values_with_fresh_host_wrappers()
test_gui_state_is_read_from_the_acid_adapter()
test_gui_state_fails_closed_without_an_adapter()
test_instrument_navigation_setup_inserts_only_when_needed()
test_fixed_native_acceptance_command()
test_diagnostics_counts_other_commands()
test_shutdown_records_completion_after_server_stop()
test_json_codec()
test_configuration_and_admission()
test_validation_framing_and_queue_limits()
test_snapshot_waits_and_document_transitions()
test_host_document_errors()
test_deadlines_and_late_document_events()
test_disconnect_reconnect_cleanup_and_failures()
test_unload_cleans_pending_document_work()

os.time = original_time
print("Renoise development transport checks passed")
