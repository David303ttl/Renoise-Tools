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

local function make_song(file_name)
  local phrase = {name = "Phrase A", number_of_lines = 16}
  local instrument = {name = "Instrument A", phrases = {phrase}}
  local song = {
    file_name = file_name or "",
    instruments = {instrument},
    selected_instrument = instrument,
    selected_phrase = phrase,
    tool_data = "fixture-source"
  }
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
  local driver, original_dofile = load_driver_for_start()
  local ok, err = pcall(function() driver.start(config_path) end)
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
  local original_instrument_handle = snapshot.instruments[1].handle
  local original_phrase_handle = snapshot.instruments[1].phrases[1].handle

  send_request(host, client, "wait-selection", "wait.condition", {
    condition = "selection_equals_expected",
    instrument_handle = original_instrument_handle,
    phrase_handle = original_phrase_handle,
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
  assert(find_response(take_responses(client), "wait-inventory").ok)

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

  send_request(host, client, "load-fixture", "document.load_fixture", {root = "fixtures", name = "smoke.xrns"})
  fire_idle(host)
  assert_equal(#host.load_song_calls, 1)
  local expected_path = "C:\\Dev Workspace\\acid-test\\fixtures\\smoke.xrns"
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
  assert(second_snapshot.instruments[1].handle ~= original_instrument_handle, "host handle crossed document epochs")
  assert(second_snapshot.instruments[1].phrases[1].handle ~= original_phrase_handle, "phrase handle crossed document epochs")

  local weak_phrase
  do
    local transient_phrase = {name = "Transient", number_of_lines = 1}
    weak_phrase = setmetatable({transient_phrase}, {__mode = "v"})
    host.song.instruments[1].phrases = {transient_phrase}
    host.song.selected_phrase = transient_phrase
    send_request(host, client, "transient-snapshot", "song.snapshot")
    fire_idle(host)
    assert(find_response(take_responses(client), "transient-snapshot").ok)
  end
  local replacement_phrase = {name = "Replacement", number_of_lines = 1}
  host.song.instruments[1].phrases = {replacement_phrase}
  host.song.selected_phrase = replacement_phrase
  collectgarbage("collect")
  assert(weak_phrase[1] == nil, "object handle registry retained a deleted host phrase")

  send_request(host, client, "cancel-on-release", "wait.condition", {
    condition = "selection_equals_expected",
    instrument_handle = "missing-instrument",
    phrase_handle = "missing-phrase",
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
    fire_idle(host)
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
