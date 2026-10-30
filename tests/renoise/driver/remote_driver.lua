local driver = {}

local LIMITS = {
  max_frame_bytes = 32768,
  max_socket_data_bytes = 131072,
  max_command_queue = 32,
  max_response_queue = 64,
  max_live_ids = 32,
  max_session_ids = 4096,
  max_idle_commands = 2,
  max_idle_responses = 4,
  max_timeout_ms = 120000,
  default_timeout_ms = 30000,
  default_wait_timeout_ms = 10000,
  native_inventory_settlement_idle_cycles = 2,
  auth_timeout_seconds = 5,
  max_response_bytes = 262144,
  max_snapshot_phrases = 512
}

local allowed_operations = {
  ping = true,
  capabilities = true,
  ["document.new"] = true,
  ["document.load_fixture"] = true,
  ["song.snapshot"] = true,
  ["song.prepare_instrument_navigation"] = true,
  ["acid.acceptance.run"] = true,
  ["gui.state"] = true,
  ["wait.condition"] = true,
  diagnostics = true,
  disconnect = true,
  shutdown = true
}

local allowed_conditions = {
  document_epoch_changed = true,
  selection_equals_expected = true,
  native_inventory_matches = true,
  observed_operation_settled = true
}

local state = nil
local cleanup
local started = false

local function is_integer(value)
  return type(value) == "number" and value == value and value % 1 == 0 and
    value ~= math.huge and value ~= -math.huge
end

local function safe_close(client)
  if not client then return end
  pcall(function() if client.is_open then client:close() end end)
end

local function same_connection(left,right)
  if rawequal(left,right) then return true end
  if not left or not right then return false end
  local ok,same=pcall(function()
    return left.is_open and right.is_open and
      type(left.peer_address)=="string" and type(left.peer_port)=="number" and
      type(left.local_address)=="string" and type(left.local_port)=="number" and
      left.peer_address==right.peer_address and left.peer_port==right.peer_port and
      left.local_address==right.local_address and left.local_port==right.local_port
  end)
  return ok and same==true
end

local function join_path(base, relative)
  local clean_base = tostring(base or ""):gsub("[\\/]+$", "")
  local clean_relative = tostring(relative or ""):gsub("[/]", "\\")
  return clean_base .. "\\" .. clean_relative
end

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
    local key, value = line:match("^([a-z_]+)=(.*)$")
    if not key or not allowed[key] or values[key] or value == "" or value:find("%z") then
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

local function queue_depth(queue)
  if not queue or queue.tail < queue.head then return 0 end
  return queue.tail - queue.head + 1
end

local function has_queued_close(current, client)
  for index = current.outgoing.head, current.outgoing.tail do
    local item = current.outgoing.items[index]
    if item and item.close_after and rawequal(item.client, client) then return true end
  end
  return false
end

local function queue_push(queue, value)
  queue.tail = queue.tail + 1
  queue.items[queue.tail] = value
end

local function queue_pop(queue)
  if queue.head > queue.tail then return nil end
  local value = queue.items[queue.head]
  queue.items[queue.head] = nil
  queue.head = queue.head + 1
  if queue.head > queue.tail then
    queue.head = 1
    queue.tail = 0
  end
  return value
end

local function new_queue()
  return {items = {}, head = 1, tail = 0}
end

local function now()
  return os.time()
end

local function deadline_expired(deadline)
  -- os.time has whole-second precision, so expire after the boundary to avoid early timeouts.
  return now() > deadline
end

local function error_value(code, message)
  return {code = code, message = message}
end

local function remember_completion(current, record, ok, err)
  local id = record.id
  current.completed[id] = {
    ok = ok,
    operation = record.operation,
    error_code = err and err.code or nil
  }
end

local function clear_client_work(current, client)
  local commands = current.commands
  for id, record in pairs(commands) do
    if rawequal(record.client, client) then
      if current.transition and rawequal(current.transition.record, record) then
        current.transition.record = nil
        current.transition.uncertain = true
        current.document_transition_uncertain = true
      end
      commands[id] = nil
      current.live_ids[id] = nil
    end
  end
  current.command_queue = new_queue()
  current.outgoing = new_queue()
  current.pending = {}
  current.completed = {}
  current.used_ids = {}
  current.close_requested = false
  current.abort_requested = false
end

local function retire_client(current, client)
  if not client then return end
  local is_candidate = current.candidate and rawequal(current.candidate.client, client)
  local is_active = current.active_client and rawequal(current.active_client, client)
  if is_candidate then current.candidate = nil end
  if is_active then current.active_client = nil end
  current.buffers[client] = nil
  clear_client_work(current, client)
  safe_close(client)
  current.client_wrappers[client]=nil
end

local function queue_response(current, client, id, ok, result, err, options)
  if current.stopped or not client then return false end
  options = options or {}
  local response = {
    id = id or current.json.null,
    ok = ok,
    result = result == nil and current.json.null or result,
    error = err or current.json.null
  }
  local encoded_ok, encoded = pcall(current.json.encode, response)
  if not encoded_ok or #encoded + 1 > LIMITS.max_response_bytes then
    encoded = current.json.encode({
      id = id or current.json.null,
      ok = false,
      result = current.json.null,
      error = error_value("response_too_large", "response exceeded the transport limit")
    })
  end
  if queue_depth(current.outgoing) >= LIMITS.max_response_queue then
    retire_client(current, client)
    return false
  end
  queue_push(current.outgoing, {
    client = client,
    id = id,
    frame = encoded .. "\n",
    close_after = options.close_after == true,
    shutdown_after = options.shutdown_after == true,
    record = options.record
  })
  return true
end

local function finish_record(current, record, ok, result, err, options)
  if not record or record.done then return end
  record.done = true
  if current.pending[record.id] then current.pending[record.id] = nil end
  remember_completion(current, record, ok, err)
  local client = record.client
  record.args = nil
  record.expected_file = nil
  record.wait_spec = nil
  queue_response(current, client, record.id, ok, result, err, {
    close_after = options and options.close_after,
    shutdown_after = options and options.shutdown_after,
    record = record
  })
end

local function clear_transition(current)
  current.transition = nil
  current.document_transition_uncertain = false
end

local function transition_timed_out(current, record)
  local transition = current.transition
  if transition and rawequal(transition.record, record) then
    transition.record = nil
    transition.uncertain = true
    current.document_transition_uncertain = true
  end
end

local function set_error(current, message)
  local value = tostring(message or "driver error")
  value = value:gsub("[%c]", " ")
  if #value > 256 then value = value:sub(1, 256) end
  current.last_error = value
end

local function is_safe_id(value)
  return type(value) == "string" and #value >= 1 and #value <= 64 and
    value:match("^[%w_.:-]+$") ~= nil
end

local function object_has_only_keys(value, allowed, required)
  if not state or not state.json.is_object(value) then return false end
  for key in pairs(value) do
    if not allowed[key] then return false end
  end
  for _, key in ipairs(required or {}) do
    if value[key] == nil then return false end
  end
  return true
end

local function validate_timeout(args, default_ms)
  local timeout_ms = args.timeout_ms
  if timeout_ms == nil then return default_ms / 1000 end
  if not is_integer(timeout_ms) or timeout_ms < 100 or timeout_ms > LIMITS.max_timeout_ms then
    return nil
  end
  return math.ceil(timeout_ms / 1000)
end

local function valid_fixture_name(name)
  if type(name) ~= "string" or #name < 1 or #name > 128 then return false end
  if name == "." or name == ".." or name:find("..", 1, true) then return false end
  if name:find("[/\\:%z%c]") or name:match("[%. ]$") then return false end
  local extension = name:match("%.([^%.]+)$")
  return extension ~= nil and extension:lower() == "xrns"
end

local function validate_wait_args(args)
  local name = args.condition
  if type(name) ~= "string" or not allowed_conditions[name] then return nil end
  local allowed = {condition = true, timeout_ms = true}
  local required = {"condition"}
  if name == "document_epoch_changed" then
    allowed.after_epoch = true
    required[#required + 1] = "after_epoch"
    if not is_integer(args.after_epoch) or args.after_epoch < 0 then return nil end
  elseif name == "selection_equals_expected" then
    allowed.instrument_index = true
    allowed.phrase_index = true
    required[#required + 1] = "instrument_index"
    required[#required + 1] = "phrase_index"
    if not is_integer(args.instrument_index) or args.instrument_index < 1 then return nil end
    if not is_integer(args.phrase_index) or args.phrase_index < 0 then return nil end
  elseif name == "native_inventory_matches" then
    allowed.instrument_count = true
    allowed.phrase_count = true
    required[#required + 1] = "instrument_count"
    required[#required + 1] = "phrase_count"
    if not is_integer(args.instrument_count) or args.instrument_count < 0 or
        not is_integer(args.phrase_count) or args.phrase_count < 0 then return nil end
  elseif name == "observed_operation_settled" then
    allowed.command_id = true
    required[#required + 1] = "command_id"
    if not is_safe_id(args.command_id) then return nil end
  end
  if not object_has_only_keys(args, allowed, required) then return nil end
  local timeout_seconds = validate_timeout(args, LIMITS.default_wait_timeout_ms)
  if not timeout_seconds then return nil end
  return {condition = name, timeout_seconds = timeout_seconds}
end

local function validate_request(current, request)
  if not current.json.is_object(request) then return nil, "malformed_request" end
  local allowed = {id = true, op = true, args = true, token = true}
  if not object_has_only_keys(request, allowed, {"id", "op", "args", "token"}) then
    return nil, "malformed_request"
  end
  if not is_safe_id(request.id) then return nil, "invalid_id" end
  if type(request.token) ~= "string" then return nil, "unauthorized" end
  if type(request.op) ~= "string" then return nil, "invalid_operation" end
  if not current.json.is_object(request.args) then return nil, "invalid_arguments" end
  return true
end

local function valid_args_for_operation(current, request)
  local args = request.args
  local operation = request.op
  if operation == "ping" or operation == "capabilities" or operation == "song.snapshot" or
      operation == "song.prepare_instrument_navigation" or operation == "gui.state" or
      operation == "diagnostics" or operation == "disconnect" or operation == "shutdown" then
    return object_has_only_keys(args, {}, {})
  elseif operation == "document.new" then
    if not object_has_only_keys(args, {timeout_ms = true}, {}) then return false end
    return validate_timeout(args, LIMITS.default_timeout_ms) ~= nil
  elseif operation == "document.load_fixture" then
    if not object_has_only_keys(args, {root = true, name = true, timeout_ms = true}, {"root", "name"}) then return false end
    if (args.root ~= "fixtures" and args.root ~= "temp") or not valid_fixture_name(args.name) then return false end
    return validate_timeout(args, LIMITS.default_timeout_ms) ~= nil
  elseif operation == "acid.acceptance.run" then
    return object_has_only_keys(args, {case = true}, {"case"}) and
      (args.case == "make-independent" or args.case == "draft-recovery" or
        args.case == "reopen-independent" or args.case == "api-probe" or
        args.case == "integrity-observers" or args.case == "editor-responsiveness")
  elseif operation == "wait.condition" then
    return validate_wait_args(args) ~= nil
  end
  return false
end

local function finish_error(current, record, code, message, options)
  finish_record(current, record, false, nil, error_value(code, message), options)
end

local function count_inventory(song)
  local instrument_count = #song.instruments
  local phrase_count = 0
  for instrument_index = 1, instrument_count do
    phrase_count = phrase_count + #song.instruments[instrument_index].phrases
  end
  return instrument_count, phrase_count
end

local function copy_integer_range(current, values)
  local result = current.json.array()
  for index, value in ipairs(values) do result[index] = value end
  return result
end

local function nullable_value(current, value)
  if value == nil then return current.json.null end
  return value
end

local function read_boolean_method(current, song, method_name)
  local method = song[method_name]
  if type(method) ~= "function" then return current.json.null end
  local value = method(song)
  return nullable_value(current, value)
end

local function snapshot_phrase_mapping(current, mapping)
  if not mapping then return current.json.null end
  return {
    key_tracking = mapping.key_tracking,
    base_note = mapping.base_note,
    note_range = copy_integer_range(current, mapping.note_range),
    looping = mapping.looping,
    loop_start = mapping.loop_start,
    loop_end = mapping.loop_end
  }
end

local function snapshot_phrase_columns(current, phrase, max_columns)
  local result = current.json.array()
  for column_index = 1, max_columns do
    result[column_index] = {
      index = column_index,
      name = nullable_value(current, phrase:column_name(column_index)),
      muted = nullable_value(current, phrase:column_is_muted(column_index))
    }
  end
  return result
end

local function snapshot_note_column(current, column, index)
  local note_value = column.note_value
  local instrument_value = column.instrument_value
  local volume_value = column.volume_value
  local panning_value = column.panning_value
  local delay_value = column.delay_value
  local effect_number_value = column.effect_number_value
  local effect_amount_value = column.effect_amount_value
  if note_value == 121 and instrument_value == 255 and volume_value == 255 and
      panning_value == 255 and delay_value == 0 and effect_number_value == 0 and
      effect_amount_value == 0 then
    return nil
  end
  return {
    index = index,
    note_value = note_value,
    instrument_value = instrument_value,
    volume_value = volume_value,
    panning_value = panning_value,
    delay_value = delay_value,
    effect_number_value = effect_number_value,
    effect_amount_value = effect_amount_value
  }
end

local function snapshot_effect_column(current, column, index)
  local number_value = column.number_value
  local amount_value = column.amount_value
  if number_value == 0 and amount_value == 0 then return nil end
  return {index = index, number_value = number_value, amount_value = amount_value}
end

local function ordered_entries(values)
  local result = {}
  for index, value in pairs(values) do
    result[#result + 1] = {index = index, value = value}
  end
  table.sort(result, function(left, right) return left.index < right.index end)
  return result
end

local function snapshot_phrase_lines(current, phrase, max_lines)
  local result = current.json.array()
  for line_index = 1, max_lines do
    local line = phrase:line(line_index)
    local note_columns = current.json.array()
    local effect_columns = current.json.array()
    local note_column_count = 0
    local effect_column_count = 0
    local native_note_columns = ordered_entries(line.note_columns)
    for _, entry in ipairs(native_note_columns) do
      local column_index, column = entry.index, entry.value
      note_column_count = column_index
      local snapshot = snapshot_note_column(current, column, column_index)
      if snapshot then note_columns[#note_columns + 1] = snapshot end
    end
    local native_effect_columns = ordered_entries(line.effect_columns)
    for _, entry in ipairs(native_effect_columns) do
      local column_index, column = entry.index, entry.value
      effect_column_count = column_index
      local snapshot = snapshot_effect_column(current, column, column_index)
      if snapshot then effect_columns[#effect_columns + 1] = snapshot end
    end
    if #note_columns > 0 or #effect_columns > 0 then
      result[#result + 1] = {
        index = line_index,
        note_column_count = note_column_count,
        effect_column_count = effect_column_count,
        note_columns = note_columns,
        effect_columns = effect_columns
      }
    end
  end
  return result
end

local function hex_bytes(value)
  if value == nil then return nil end
  local parts = {}
  for index = 1, #value do
    parts[index] = string.format("%02x", value:byte(index))
  end
  return table.concat(parts)
end

local function build_snapshot(current)
  local song = current.current_song
  if not current.document_ready or not song then
    return nil, error_value("document_unavailable", "no current song document is available")
  end

  local instrument_count, phrase_count = count_inventory(song)
  if phrase_count > LIMITS.max_snapshot_phrases then
    return nil, error_value("snapshot_limit", "song inventory exceeds the snapshot bound")
  end

  local max_lines = (renoise.InstrumentPhrase and renoise.InstrumentPhrase.MAX_NUMBER_OF_LINES) or 512
  local max_note_columns = (renoise.InstrumentPhrase and renoise.InstrumentPhrase.MAX_NUMBER_OF_NOTE_COLUMNS) or 12
  local tool_data = song.tool_data
  if tool_data ~= nil and type(tool_data) ~= "string" then
    return nil, error_value("snapshot_unavailable", "song tool data is not a byte string")
  end
  if tool_data and #tool_data > LIMITS.max_response_bytes / 2 then
    return nil, error_value("snapshot_limit", "song tool data exceeds the snapshot bound")
  end

  local instruments = current.json.array()
  for instrument_index, instrument in ipairs(song.instruments) do
    local phrases = current.json.array()
    for phrase_index, phrase in ipairs(instrument.phrases) do
      local properties = {
        playback_mode = nullable_value(current, phrase.playback_mode),
        visible_note_columns = nullable_value(current, phrase.visible_note_columns),
        visible_effect_columns = nullable_value(current, phrase.visible_effect_columns),
        key_tracking = nullable_value(current, phrase.key_tracking),
        base_note = nullable_value(current, phrase.base_note),
        looping = nullable_value(current, phrase.looping),
        loop_start = nullable_value(current, phrase.loop_start),
        loop_end = nullable_value(current, phrase.loop_end),
        autoseek = nullable_value(current, phrase.autoseek),
        lpb = nullable_value(current, phrase.lpb),
        shuffle = nullable_value(current, phrase.shuffle),
        instrument_column_visible = nullable_value(current, phrase.instrument_column_visible),
        volume_column_visible = nullable_value(current, phrase.volume_column_visible),
        panning_column_visible = nullable_value(current, phrase.panning_column_visible),
        delay_column_visible = nullable_value(current, phrase.delay_column_visible),
        sample_effects_column_visible = nullable_value(current, phrase.sample_effects_column_visible)
      }
      local lines_ok, lines = pcall(snapshot_phrase_lines, current, phrase, max_lines)
      if not lines_ok then
        return nil, error_value("snapshot_unavailable", "phrase line data could not be read")
      end
      local columns_ok, columns = pcall(snapshot_phrase_columns, current, phrase, max_note_columns)
      if not columns_ok then
        return nil, error_value("snapshot_unavailable", "phrase column metadata could not be read")
      end
      phrases[#phrases + 1] = {
        index = phrase_index,
        name = phrase.name,
        number_of_lines = phrase.number_of_lines,
        properties = properties,
        note_columns = columns,
        mapping = snapshot_phrase_mapping(current, phrase.mapping),
        captured_line_count = max_lines,
        lines = lines
      }
    end

    local mappings = current.json.array()
    for mapping_index, mapping in ipairs(instrument.phrase_mappings or {}) do
      mappings[#mappings + 1] = {
        index = mapping_index,
        key_tracking = mapping.key_tracking,
        base_note = mapping.base_note,
        note_range = copy_integer_range(current, mapping.note_range),
        looping = mapping.looping,
        loop_start = mapping.loop_start,
        loop_end = mapping.loop_end
      }
    end
    instruments[#instruments + 1] = {
      index = instrument_index,
      name = instrument.name,
      phrases = phrases,
      phrase_mappings = mappings
    }
  end

  local snapshot = {
    document_epoch = current.document_epoch,
    instrument_count = instrument_count,
    phrase_count = phrase_count,
    selected_instrument_index = song.selected_instrument_index,
    selected_phrase_index = song.selected_phrase_index,
    can_undo = read_boolean_method(current, song, "can_undo"),
    can_redo = read_boolean_method(current, song, "can_redo"),
    is_undo_redoing = read_boolean_method(current, song, "is_undo_redoing"),
    tool_data_present = tool_data ~= nil,
    tool_data_length = tool_data and #tool_data or 0,
    tool_data_hex = nullable_value(current, hex_bytes(tool_data)),
    instruments = instruments
  }
  local encode_ok, encoded = pcall(current.json.encode, snapshot)
  if not encode_ok or #encoded > LIMITS.max_response_bytes - 2048 then
    return nil, error_value("snapshot_limit", "song snapshot exceeds the response bound")
  end
  return snapshot
end

local function canonical_path(path)
  local value = tostring(path or ""):gsub("/", "\\")
  local is_unc = value:sub(1, 2) == "\\\\"
  local drive, rest
  local prefix = ""
  local absolute = is_unc
  local root_depth = is_unc and 2 or 0

  if is_unc then
    rest = value:sub(3)
  else
    drive, rest = value:match("^([%a]:)(.*)$")
    if drive then
      absolute = rest:sub(1, 1) == "\\"
      prefix = drive .. (absolute and "\\" or "")
      if absolute then rest = rest:sub(2) end
    else
      rest = value
    end
  end

  local parts = {}
  for segment in rest:gmatch("[^\\]+") do
    if segment == "." or segment == "" then
      -- Skip empty and current-directory segments.
    elseif segment == ".." then
      if #parts > root_depth and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif not absolute then
        parts[#parts + 1] = segment
      end
    else
      parts[#parts + 1] = segment
    end
  end

  if is_unc then return "\\\\" .. table.concat(parts, "\\") end
  return prefix .. table.concat(parts, "\\")
end

local function normalized_path(path)
  return canonical_path(path):lower()
end

local function expected_fixture_path(current, root, name)
  local bundle_path = current.tool.bundle_path
  local root_name = root == "fixtures" and "..\\fixtures" or "..\\temp"
  return canonical_path(join_path(bundle_path, root_name .. "\\" .. name))
end

local function fixture_is_accessible(path)
  local open_ok, file = pcall(io.open, path, "rb")
  if not open_ok or not file then return false end
  pcall(function() file:close() end)
  return true
end

local function selection_indices(current)
  local song = current.current_song
  if not current.document_ready or not song then return current.json.null, current.json.null end
  return song.selected_instrument_index, song.selected_phrase_index
end

local function evaluate_condition(current, record)
  local spec = record.wait_spec
  local args = record.args
  if spec.condition == "document_epoch_changed" then
    local matched = current.document_ready and current.document_epoch > args.after_epoch
    return matched, {condition = spec.condition, document_epoch = current.document_epoch, document_ready = current.document_ready}
  elseif spec.condition == "selection_equals_expected" then
    local instrument_index, phrase_index = selection_indices(current)
    local matched = instrument_index == args.instrument_index and phrase_index == args.phrase_index
    return matched, {
      condition = spec.condition,
      instrument_index = instrument_index,
      phrase_index = phrase_index
    }
  elseif spec.condition == "native_inventory_matches" then
    if not current.document_ready or not current.current_song then
      record.matching_idle_cycles = 0
      return false, {
        condition = spec.condition,
        document_ready = false,
        matching_idle_cycles = 0,
        idle_settlement_observed = false
      }
    end
    local instrument_count, phrase_count = count_inventory(current.current_song)
    local inventory_matches = instrument_count == args.instrument_count and phrase_count == args.phrase_count
    if inventory_matches then
      record.matching_idle_cycles = (record.matching_idle_cycles or 0) + 1
    else
      record.matching_idle_cycles = 0
    end
    local idle_settlement_observed = record.matching_idle_cycles >= LIMITS.native_inventory_settlement_idle_cycles
    return idle_settlement_observed, {
      condition = spec.condition,
      instrument_count = instrument_count,
      phrase_count = phrase_count,
      matching_idle_cycles = record.matching_idle_cycles,
      idle_settlement_observed = idle_settlement_observed
    }
  elseif spec.condition == "observed_operation_settled" then
    local completion = current.completed[args.command_id]
    return completion ~= nil, {
      condition = spec.condition,
      command_id = args.command_id,
      operation_ok = completion and completion.ok or false,
      error_code = completion and completion.error_code or current.json.null
    }
  end
  return false, nil
end

local function clear_record_payload(record)
  record.args = nil
  record.expected_file = nil
  record.wait_spec = nil
end

local function settle_transition(current)
  local transition = current.transition
  if not transition or not transition.release_seen or not transition.observed_epoch or
      transition.observed_epoch <= transition.expected_epoch then return end
  local record = transition.record
  if not record or record.done then
    clear_transition(current)
    return
  end
  if transition.observed_at and transition.observed_at > transition.deadline then return end

  local song = current.current_song
  local matches = false
  if song and transition.kind == "new" then
    matches = song.file_name == ""
  elseif song and transition.kind == "load" then
    matches = normalized_path(song.file_name) == normalized_path(record.expected_file)
  end

  if matches then
    finish_record(current, record, true, {
      document_epoch = current.document_epoch,
      operation = record.operation
    })
  else
    finish_error(current, record, "canceled", "a different document change was observed")
  end
  clear_transition(current)
end

local function cancel_document_scoped_commands(current, old_epoch)
  local to_cancel = {}
  for _, record in pairs(current.pending) do
    local is_active_transition = current.transition and rawequal(current.transition.record, record)
    local condition = record.args and record.args.condition
    local is_cross_epoch_wait = record.operation == "wait.condition" and
      (condition == "document_epoch_changed" or condition == "observed_operation_settled")
    if record.document_epoch == old_epoch and not is_active_transition and not is_cross_epoch_wait then
      to_cancel[#to_cancel + 1] = record
    end
  end
  for _, record in ipairs(to_cancel) do
    finish_error(current, record, "canceled", "document epoch changed")
  end
end

local function on_document_release(current)
  if not current.document_ready then return end
  local old_epoch = current.document_epoch
  current.document_epoch = old_epoch + 1
  current.document_ready = false
  current.current_song = nil
  current.last_native_inventory_settlement = nil
  if current.transition and current.transition.expected_epoch == old_epoch then
    current.transition.release_seen = true
  end
  cancel_document_scoped_commands(current, old_epoch)
end

local function on_new_document(current)
  local song_ok, song = pcall(function() return renoise.song() end)
  if not song_ok or not song then
    set_error(current, "new document notification did not expose a song")
    return
  end

  local was_ready = current.document_ready
  if was_ready and not rawequal(current.current_song, song) then
    current.document_epoch = current.document_epoch + 1
    cancel_document_scoped_commands(current, current.document_epoch - 1)
  end
  if not was_ready or not rawequal(current.current_song, song) then
    current.last_native_inventory_settlement = nil
  end
  current.current_song = song
  current.document_ready = true
  local transition = current.transition
  if transition and transition.expected_epoch < current.document_epoch and
      transition.observed_epoch ~= current.document_epoch then
    transition.observed_epoch = current.document_epoch
    transition.observed_at = now()
  end
end

local function make_diagnostics(current, request)
  local pending_count = 0
  for _, pending in pairs(current.pending) do if not rawequal(pending, request) then pending_count = pending_count + 1 end end
  return {
    document_epoch = current.document_epoch,
    document_ready = current.document_ready,
    pending_commands = pending_count,
    queued_commands = queue_depth(current.command_queue),
    queued_responses = queue_depth(current.outgoing),
    authenticated = current.active_client ~= nil,
    document_transition_uncertain = current.document_transition_uncertain,
    native_inventory_settlement = current.last_native_inventory_settlement or current.json.null,
    last_error = current.last_error or current.json.null
  }
end

local function process_record(current, record)
  if record.done then return end
  record.state = "running"

  if record.operation == "ping" then
    finish_record(current, record, true, {protocol_version = 1, session = current.configuration.nonce})
  elseif record.operation == "capabilities" then
    local operations = current.json.array()
    for operation in pairs(allowed_operations) do operations[#operations + 1] = operation end
    table.sort(operations)
    local conditions = current.json.array()
    for condition in pairs(allowed_conditions) do conditions[#conditions + 1] = condition end
    table.sort(conditions)
    finish_record(current, record, true, {
      protocol_version = 1,
      api_version = renoise.API_VERSION,
      renoise_version = renoise.RENOISE_VERSION,
      operations = operations,
      wait_conditions = conditions,
      limits = {
        max_frame_bytes = LIMITS.max_frame_bytes,
        max_command_queue = LIMITS.max_command_queue,
        max_live_ids = LIMITS.max_live_ids,
        max_session_ids = LIMITS.max_session_ids,
        max_response_bytes = LIMITS.max_response_bytes,
        max_snapshot_phrases = LIMITS.max_snapshot_phrases
      }
    })
  elseif record.operation == "document.new" or record.operation == "document.load_fixture" then
    if not current.document_ready or not current.current_song then
      finish_error(current, record, "document_unavailable", "no current song document is available")
      return
    end
    if current.document_transition_uncertain then
      finish_error(current, record, "host_state_uncertain", "a previous document transition has not settled")
      return
    end
    if current.transition then
      finish_error(current, record, "operation_busy", "another document transition is still active")
      return
    end

    local kind = record.operation == "document.new" and "new" or "load"
    if kind == "load" then
      record.expected_file = expected_fixture_path(current, record.args.root, record.args.name)
      if not fixture_is_accessible(record.expected_file) then
        finish_error(current, record, "fixture_unavailable", "fixture file is unavailable")
        return
      end
    end
    current.transition = {
      kind = kind,
      record = record,
      expected_epoch = record.document_epoch,
      deadline = record.deadline,
      release_seen = false,
      uncertain = false
    }
    record.state = "waiting_document"
    local call_ok, call_error = pcall(function()
      local app = renoise.app()
      if kind == "new" then
        app:new_song_no_template()
      else
        app:load_song(record.expected_file)
      end
    end)
    if not call_ok then
      set_error(current, "native document command raised an error")
      if current.transition and not current.transition.observed_epoch then
        clear_transition(current)
        finish_error(current, record, "host_error", "native document command failed")
      end
    else
      -- The effect is completed only by app_new_document_observable.
      record.state = "waiting_document"
    end
  elseif record.operation == "song.snapshot" then
    local snapshot, snapshot_error = build_snapshot(current)
    if not snapshot then
      finish_record(current, record, false, nil, snapshot_error)
      return
    end
    finish_record(current, record, true, snapshot)
  elseif record.operation == "song.prepare_instrument_navigation" then
    local prepare_ok, result = pcall(function()
      local song = renoise.song()
      if #song.instruments < 2 then
        song:insert_instrument_at(2)
      end
      return {
        instrument_count = #song.instruments,
        selected_instrument_index = song.selected_instrument_index
      }
    end)
    if not prepare_ok or type(result) ~= "table" or result.instrument_count < 2 then
      finish_error(current, record, "host_error", "instrument navigation setup failed")
      return
    end
    finish_record(current, record, true, result)
  elseif record.operation == "acid.acceptance.run" then
    if type(current.acceptance_runner) ~= "function" then
      finish_error(current, record, "acceptance_unavailable", "native acceptance cases are unavailable")
      return
    end
    local callback_used = false
    local function complete(result)
      if callback_used or record.done then return false end
      callback_used = true
      if type(result) ~= "table" or
          (result.status ~= "PASS" and result.status ~= "FAIL" and result.status ~= "ERROR") or
          result.case ~= record.args.case then
        finish_error(current, record, "acceptance_result_invalid", "native acceptance returned an invalid result")
        return false
      end
      finish_record(current, record, true, result)
      return true
    end
    local call_ok, accepted, detail = pcall(current.acceptance_runner, record.args.case, complete)
    if not call_ok then
      finish_error(current, record, "acceptance_error",
        "native acceptance case raised an error: " .. tostring(accepted))
    elseif accepted == false then
      finish_error(current, record, "acceptance_unavailable", tostring(detail or "native acceptance case did not start"))
    elseif type(accepted) == "table" then
      complete(accepted)
    else
      record.state = "waiting_acceptance"
    end
  elseif record.operation == "gui.state" then
    if type(current.gui_state_reader) ~= "function" then
      finish_error(current, record, "gui_state_unavailable", "ACID UI state is unavailable in this driver")
      return
    end
    local read_ok, ui_state = pcall(current.gui_state_reader)
    if not read_ok or type(ui_state) ~= "table" or type(ui_state.dialog_visible) ~= "boolean" then
      finish_error(current, record, "gui_state_unavailable", "ACID UI state could not be read")
      return
    end
    local result = {
      dialog_visible = ui_state.dialog_visible
    }
    if is_integer(ui_state.show_invocations) and ui_state.show_invocations >= 0 then
      result.show_invocations = ui_state.show_invocations
    end
    if type(ui_state.show_keybinding_registered) == "boolean" then
      result.show_keybinding_registered = ui_state.show_keybinding_registered
    end
    finish_record(current, record, true, result)
  elseif record.operation == "wait.condition" then
    local spec = validate_wait_args(record.args)
    if not spec then
      finish_error(current, record, "invalid_arguments", "wait condition arguments are invalid")
      return
    end
    record.wait_spec = spec
    record.state = "waiting_condition"
  elseif record.operation == "diagnostics" then
    finish_record(current, record, true, make_diagnostics(current, record))
  elseif record.operation == "shutdown" then
    finish_record(current, record, true, {shutdown_requested = true}, nil, {shutdown_after = true})
  elseif record.operation == "disconnect" then
    finish_record(current, record, true, {disconnected = true}, nil, {close_after = true})
  else
    finish_error(current, record, "unsupported_operation", "operation is not supported")
  end
end

local function enqueue_request(current, client, request)
  local valid, validation_error = validate_request(current, request)
  if not valid then
    if is_safe_id(request.id) then
      queue_response(current, client, request.id, false, nil,
        error_value(validation_error, "request envelope is invalid"), {close_after = true})
      current.abort_requested = true
    else
      retire_client(current, client)
    end
    return false
  end

  if request.token ~= current.configuration.token then
    queue_response(current, client, request.id, false, nil,
      error_value("unauthorized", "session token was rejected"), {close_after = true})
    current.abort_requested = true
    return false
  end

  if current.candidate and rawequal(current.candidate.client, client) then
    current.candidate = nil
    current.active_client = client
  elseif not current.active_client or not rawequal(current.active_client, client) then
    retire_client(current, client)
    return false
  end

  if current.live_ids[request.id] then
    queue_response(current, client, request.id, false, nil,
      error_value("duplicate_id", "request id is already live"), {close_after = true})
    current.abort_requested = true
    return false
  elseif current.used_ids[request.id] then
    queue_response(current, client, request.id, false, nil,
      error_value("duplicate_id", "request id was already used in this connection"))
    return false
  end
  if not allowed_operations[request.op] then
    queue_response(current, client, request.id, false, nil,
      error_value("unsupported_operation", "operation is not supported"))
    return false
  end
  if not valid_args_for_operation(current, request) then
    queue_response(current, client, request.id, false, nil,
      error_value("invalid_arguments", "operation arguments are invalid"))
    return false
  end
  if current.close_requested then return false end
  if current.document_transition_uncertain and
      (request.op == "document.new" or request.op == "document.load_fixture") then
    queue_response(current, client, request.id, false, nil,
      error_value("host_state_uncertain", "a previous document transition has not settled"))
    return false
  end
  if queue_depth(current.command_queue) >= LIMITS.max_command_queue or
      (function()
        local count = 0
        for _ in pairs(current.live_ids) do count = count + 1 end
        return count >= LIMITS.max_live_ids
      end)() then
    queue_response(current, client, request.id, false, nil,
      error_value("queue_full", "command queue limit was reached"))
    return false
  end
  local used_id_count = 0
  for _ in pairs(current.used_ids) do used_id_count = used_id_count + 1 end
  if used_id_count >= LIMITS.max_session_ids then
    queue_response(current, client, request.id, false, nil,
      error_value("session_limit", "per-connection command id limit was reached"), {close_after = true})
    current.abort_requested = true
    return false
  end

  local default_ms = request.op == "wait.condition" and LIMITS.default_wait_timeout_ms or LIMITS.default_timeout_ms
  local timeout_seconds = validate_timeout(request.args, default_ms)
  local record = {
    id = request.id,
    operation = request.op,
    args = request.args,
    client = client,
    state = "queued",
    deadline = now() + timeout_seconds,
    document_epoch = current.document_epoch,
    done = false
  }
  current.live_ids[request.id] = true
  current.used_ids[request.id] = true
  current.commands[request.id] = record
  current.pending[request.id] = record
  queue_push(current.command_queue, record)
  if request.op == "disconnect" or request.op == "shutdown" then current.close_requested = true end
  return true
end

local function process_frame(current, client, frame)
  local decode_ok, request = pcall(current.json.decode, frame)
  if not decode_ok then
    retire_client(current, client)
    return false
  end
  if not current.json.is_object(request) then
    retire_client(current, client)
    return false
  end
  return enqueue_request(current, client, request)
end

local function receive_message(current, client, message)
  if current.close_requested then return end
  local candidate = current.candidate and rawequal(current.candidate.client, client)
  local active = current.active_client and rawequal(current.active_client, client)
  if not candidate and not active then
    safe_close(client)
    return
  end
  if type(message) ~= "string" or #message > LIMITS.max_socket_data_bytes then
    retire_client(current, client)
    return
  end

  local buffer = (current.buffers[client] or "") .. message
  if #buffer > LIMITS.max_socket_data_bytes then
    retire_client(current, client)
    return
  end
  local position = 1
  while true do
    local newline = buffer:find("\n", position, true)
    if not newline then break end
    local frame = buffer:sub(position, newline - 1)
    if #frame > LIMITS.max_frame_bytes then
      retire_client(current, client)
      return
    end
    if frame:sub(-1) == "\r" then frame = frame:sub(1, -2) end
    if frame == "" then
      retire_client(current, client)
      return
    end
    local accepted = process_frame(current, client, frame)
    if not accepted and (current.close_requested or has_queued_close(current, client) or
        (not (current.active_client and rawequal(current.active_client, client)) and
          not (current.candidate and rawequal(current.candidate.client, client)))) then
      return
    end
    if current.active_client and not rawequal(current.active_client, client) then return end
    if not (current.active_client and rawequal(current.active_client, client)) and
        not (current.candidate and rawequal(current.candidate.client, client)) then return end
    position = newline + 1
  end
  local remainder = buffer:sub(position)
  if #remainder > LIMITS.max_frame_bytes then
    retire_client(current, client)
    return
  end
  current.buffers[client] = remainder
end

local function flush_responses(current)
  local sent = 0
  while sent < LIMITS.max_idle_responses and queue_depth(current.outgoing) > 0 do
    local item = queue_pop(current.outgoing)
    local send_ok, result, send_error = pcall(function()
      return item.client:send(item.frame)
    end)
    if not send_ok or result ~= true then
      set_error(current, "socket response could not be sent")
      retire_client(current, item.client)
      return
    end
    if item.shutdown_after then
      -- Stopping the server closes accepted sockets; completion uses a sidecar.
      local marker_path = current.shutdown_marker_path
      local nonce = current.configuration.nonce
      cleanup(current)
      local marker, marker_error = io.open(marker_path, "wb")
      if not marker then error(marker_error) end
      local written, write_error = marker:write(nonce)
      local closed, close_error = marker:close()
      if not written or not closed then error(write_error or close_error) end
      return
    end
    if item.record and current.commands[item.id] == item.record then
      current.commands[item.id] = nil
      current.live_ids[item.id] = nil
    end
    if item.close_after then retire_client(current, item.client) end
    sent = sent + 1
  end
end

local function process_commands(current)
  if current.abort_requested then return end
  local processed = 0
  while processed < LIMITS.max_idle_commands and queue_depth(current.command_queue) > 0 do
    local record = queue_pop(current.command_queue)
    if record and not record.done then
      if deadline_expired(record.deadline) then
        if record.operation == "document.new" or record.operation == "document.load_fixture" then
          transition_timed_out(current, record)
        end
        finish_error(current, record, "timeout", "command deadline expired")
      elseif record.document_epoch ~= current.document_epoch and
          not (record.operation == "wait.condition" and
            (record.args.condition == "document_epoch_changed" or record.args.condition == "observed_operation_settled")) and
          not (current.transition and rawequal(current.transition.record, record)) then
        finish_error(current, record, "canceled", "document epoch changed before dispatch")
      else
        local run_ok, run_error = pcall(process_record, current, record)
        if not run_ok then
          set_error(current, "driver command raised an error")
          if record.operation == "document.new" or record.operation == "document.load_fixture" then
            transition_timed_out(current, record)
          end
          finish_error(current, record, "host_error", "driver command failed")
        end
      end
      processed = processed + 1
    end
  end
end

local function evaluate_pending(current)
  local current_time = now()
  settle_transition(current)
  local pending = {}
  for _, record in pairs(current.pending) do pending[#pending + 1] = record end
  for _, record in ipairs(pending) do
    if not record.done then
      if current_time > record.deadline then
        if record.operation == "document.new" or record.operation == "document.load_fixture" then
          transition_timed_out(current, record)
        end
        finish_error(current, record, "timeout", "command deadline expired")
      elseif record.operation == "wait.condition" and record.wait_spec then
        local condition_ok, matched, result = pcall(evaluate_condition, current, record)
        if not condition_ok then
          set_error(current, "wait condition inspection failed")
          finish_error(current, record, "host_error", "condition inspection failed")
        elseif matched then
          if record.wait_spec.condition == "native_inventory_matches" then
            current.last_native_inventory_settlement = {
              document_epoch = current.document_epoch,
              instrument_count = result.instrument_count,
              phrase_count = result.phrase_count,
              matching_idle_cycles = result.matching_idle_cycles,
              idle_settlement_observed = result.idle_settlement_observed
            }
          end
          finish_record(current, record, true, result)
        end
      end
    end
  end
  settle_transition(current)
end

local function retire_expired_candidate(current)
  local candidate = current.candidate
  if not candidate then return end
  local open_ok, is_open = pcall(function() return candidate.client.is_open end)
  if not open_ok or is_open ~= true or deadline_expired(candidate.deadline) then
    retire_client(current, candidate.client)
  end
end

local function retire_closed_active(current)
  local client = current.active_client
  if not client then return end
  local open_ok, is_open = pcall(function() return client.is_open end)
  if not open_ok or is_open ~= true then retire_client(current, client) end
end

local function handle_server_error(current)
  if not current.server_error then return end
  current.server_error = false
  set_error(current, "socket server reported an error")
  local pending = {}
  for _, record in pairs(current.pending) do pending[#pending + 1] = record end
  for index, record in ipairs(pending) do
    finish_error(current, record, "host_error", "socket server failed", {
      close_after = index == #pending
    })
  end
  current.server_failed = true
  if current.server then pcall(function() current.server:stop() end) end
  if #pending == 0 and current.active_client then
    queue_response(current, current.active_client, current.json.null, false, nil,
      error_value("host_error", "socket server failed"), {close_after = true})
  end
end

local function on_idle(current)
  if current.stopped or current.processing_idle then return end
  current.processing_idle = true
  local ok, err = pcall(function()
    retire_expired_candidate(current)
    retire_closed_active(current)
    handle_server_error(current)
    process_commands(current)
    evaluate_pending(current)
    flush_responses(current)
  end)
  if not ok then
    set_error(current, "idle transport handler raised an error")
    local pending = {}
    for _, record in pairs(current.pending) do pending[#pending + 1] = record end
    for _, record in ipairs(pending) do
      finish_error(current, record, "host_error", "transport processing failed")
    end
    flush_responses(current)
  end
  current.processing_idle = false
end

local function detach_observable(observable, notifier)
  if observable and notifier then
    pcall(function()
      if observable:has_notifier(notifier) then observable:remove_notifier(notifier) end
    end)
  end
end

cleanup = function(current)
  if not current or current.stopped then return end
  current.stopped = true
  detach_observable(current.idle_observable, current.idle_notifier)
  detach_observable(current.release_observable, current.release_notifier)
  detach_observable(current.new_document_observable, current.new_document_notifier)
  detach_observable(current.unload_observable, current.unload_notifier)
  if current.server then pcall(function() current.server:stop() end) end
  safe_close(current.candidate and current.candidate.client)
  safe_close(current.active_client)
  current.server = nil
  current.callbacks = nil
  current.tool = nil
  current.candidate = nil
  current.active_client = nil
  current.current_song = nil
  current.idle_observable = nil
  current.release_observable = nil
  current.new_document_observable = nil
  current.unload_observable = nil
  current.idle_notifier = nil
  current.release_notifier = nil
  current.new_document_notifier = nil
  current.unload_notifier = nil
  current.command_queue = new_queue()
  current.outgoing = new_queue()
  current.commands = {}
  current.pending = {}
  current.live_ids = {}
  current.completed = {}
  current.used_ids = {}
  current.buffers = {}
  current.client_wrappers = {}
  current.transition = nil
  current.document_ready = false
  current.document_transition_uncertain = false
  current.last_error = nil
  current.configuration = nil
  current.json = nil
  if rawequal(state, current) then state = nil end
end

local function initialize_observers(current)
  local tool = current.tool
  current.idle_observable = tool.app_idle_observable
  current.release_observable = tool.app_release_document_observable
  current.new_document_observable = tool.app_new_document_observable
  current.unload_observable = tool.tool_will_unload_observable

  current.idle_notifier = function() on_idle(current) end
  current.release_notifier = function() on_document_release(current) end
  current.new_document_notifier = function() on_new_document(current) end
  current.unload_notifier = function() cleanup(current) end

  current.idle_observable:add_notifier(current.idle_notifier)
  current.release_observable:add_notifier(current.release_notifier)
  current.new_document_observable:add_notifier(current.new_document_notifier)
  current.unload_observable:add_notifier(current.unload_notifier)

  local song_ok, song = pcall(function() return renoise.song() end)
  if song_ok and song then
    current.document_epoch = 1
    current.document_ready = true
    current.current_song = song
  end
end

function driver.start(configuration_path, gui_state_reader, acceptance_runner)
  if started then
    error("ACID development driver has already been started")
  end
  local configuration = read_configuration(configuration_path)
  local host_tool = renoise.tool()
  local json_path = join_path(host_tool.bundle_path, "__dev\\json.lua")
  local codec = dofile(json_path)
  local server, server_error = renoise.Socket.create_server(
    "127.0.0.1",
    configuration.port,
    renoise.Socket.PROTOCOL_TCP
  )
  if not server then
    error("ACID development listener could not bind its reserved port: " .. tostring(server_error))
  end

  local current = {
    configuration = configuration,
    shutdown_marker_path = configuration_path .. "." .. configuration.nonce .. ".stopped",
    json = codec,
    server = server,
    tool = host_tool,
    server_error = false,
    server_failed = false,
    stopped = false,
    processing_idle = false,
    document_epoch = 0,
    document_ready = false,
    document_transition_uncertain = false,
    current_song = nil,
    gui_state_reader = gui_state_reader,
    acceptance_runner = acceptance_runner,
    last_native_inventory_settlement = nil,
    candidate = nil,
    active_client = nil,
    buffers = {},
    client_wrappers = {},
    command_queue = new_queue(),
    outgoing = new_queue(),
    commands = {},
    pending = {},
    live_ids = {},
    completed = {},
    used_ids = {},
    transition = nil,
    last_error = nil,
    abort_requested = false
  }
  state = current

  local callbacks = {
    socket_error = function(message)
      if current.stopped then return end
      current.server_error = true
      set_error(current, message)
    end,
    socket_accepted = function(client)
      if current.stopped or current.server_failed or current.candidate or current.active_client then
        safe_close(client)
        return
      end
      current.candidate = {client = client, deadline = now() + LIMITS.auth_timeout_seconds}
      current.client_wrappers[client]={[client]=true}
      current.buffers[client] = ""
    end,
    socket_message = function(client, message)
      if current.stopped then return end
      local connected=current.active_client or (current.candidate and current.candidate.client)
      if connected and same_connection(connected,client) then
        -- Keep callback wrappers alive until their native connection closes.
        local wrappers=current.client_wrappers[connected]
        if not wrappers then wrappers={};current.client_wrappers[connected]=wrappers end
        wrappers[client]=true
        client=connected
      end
      local ok, callback_error = pcall(receive_message, current, client, message)
      if not ok then
        set_error(current, "socket request callback raised an error")
        current.abort_requested = true
        queue_response(current, client, codec.null, false, nil,
          error_value("host_error", "transport request processing failed"), {close_after = true})
      end
    end
  }

  current.callbacks = callbacks
  local run_ok, run_error = pcall(function() server:run(callbacks) end)
  if not run_ok then
    pcall(function() server:stop() end)
    state = nil
    error("ACID development listener failed to start: " .. tostring(run_error))
  end

  local observers_ok, observers_error = pcall(initialize_observers, current)
  if not observers_ok then
    cleanup(current)
    state = nil
    error("ACID development driver could not attach lifecycle observers: " .. tostring(observers_error))
  end
  started = true
  state = current
  return true
end

function driver.stop()
  cleanup(state)
end

function driver._limits()
  local copy = {}
  for key, value in pairs(LIMITS) do copy[key] = value end
  return copy
end

return driver
