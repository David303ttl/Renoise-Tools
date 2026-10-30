-- SPDX-License-Identifier: GPL-3.0-only
-- Runtime generation delivery boundary.
--
-- context.new(options) -> context
--   options.writer  read-only occupancy source. writer.state() returns a
--                   detached status string and an opaque token:
--                   "idle", nil or "busy", <exact operation token>.
--                   No writer job table or writable busy flag is retained.
--   options.capture capture(trigger, token) -> request | nil, reason.
--                   Runtime-owned eligibility and request-capture seam. The
--                   returned request must carry the supplied token as
--                   request.token; the context does not write request values.
--   options.sink    sink(request, done) -> true | false, reason.
--                   true accepts and eventually calls done exactly once;
--                   false rejects and must not call done. done may run before
--                   the sink returns. The sink is fixed for this context.
--   options.issue_token issue_token() -> opaque token (optional).
--                   Overrides issuance for isolated conformance tests without
--                   exposing the delivery record. The default token exposes
--                   only token:is_current() -> boolean, failing closed on
--                   inspection errors.
--
-- Request contract:
--   Capture owns request values; this context passes them through unchanged
--   and does not synthesize eligibility, frozen values, mutation, blocker, or
--   independence behavior. The request shape reserves:
--     request.mutate(token, action) -> all action result values
--       Same operation token only. Depth-counted and non-yielding; unwinds on
--       success or exception, revokes authorization on exception, and
--       rethrows the original failure. No user callback, idle wait, or render
--       wait may run inside it.
--     request.record_blocker(token, evidence)
--       Verifies the matching live epoch/job, retains copied scalar/value
--       evidence and exact recovery references only while that song is
--       current, and records the evidence before a terminal result.
--   Musical generation enters only through request_generation and its sink.
--   Make Independent has a separate explicit eligibility/action entry and
--   never enters the musical sink.
--
-- context:request_generation(trigger) -> true | false, reason
--   Admission requires no request already starting or dispatching, no
--   installed delivery record, and an idle writer slot. Capture rejection
--   calls the sink zero times. The delivery record is installed before the
--   sink is invoked, so a reentrant request cannot start another generation
--   before the sink returns.
--
--   Duplicate completion, completion after rejection, completion followed by
--   rejection or an invalid return, and thrown starts are diagnosed at most
--   once per delivery record. They never settle twice. A later request may
--   clear a block only after any pending record has retired and a fresh
--   writer.state() inspection reports idle.
--
--   A thrown or non-boolean sink start whose exact issued token is still busy
--   is physically accepted with canceled/uncertain commit authorization:
--   token:is_current() and state.authorization report false, the pending
--   record is retained for its matching done, admission stays blocked, and the
--   call returns accepted-pending (true). It never fabricates a rejection or
--   releases the writer slot. A literal rejection while the writer reports
--   busy is a protocol violation, not a clean rejection.
--
-- Boundary obligations:
--   The sink may call done synchronously before returning acceptance. It calls
--   done only after terminal cleanup/evidence as its final host/GUI side effect;
--   the acceptance return may follow synchronous done.
--   A writer idle reading inside a delivery callback is not admission proof;
--   the adapter guards the full callback. Cancellation is normalized only from
--   verified settlement, never from a boolean acknowledgement alone. A revoked
--   or accepted-pending record stays pending until its matching done; a clean
--   cancellation without a terminal must be normalized to a terminal
--   settlement by the adapter. Diagnostics, blocks, revoke, and idle readings
--   never create a terminal result; an unresolved render remains pending or
--   tombstoned until its own terminal state retires it. Pending-token scrubbing
--   and native writer registry tombstoning remain writer cleanup work.
--
-- context:revoke(token, reason) -> true | false
--   Raw-identity revocation of the active request. A matching call makes the
--   token report false for is_current() and removes authorization while
--   retaining the delivery record and writer occupancy. A later matching done
--   retires that record without treating it as a deliverable result.
--   Mismatched, already-revoked, rejected, or settled requests return false.
--
-- context:state() -> detached scalar projection
--   {status="idle"|"pending"|"blocked", token, authorization, blocked,
--    blocked_reason, diagnostic_count, last_diagnostic={code,message} | nil}
--
-- Lifetime seam (optional until the GUI cutover):
--   attach_document(song) -> fresh epoch; replaces/releases an attached song.
--   open_dialog(gui_delivery) -> fresh session; delivery(result) is optional.
--   close_dialog() -> changed; revokes delivery and requests cancellation.
--   release_document() -> changed, volatile draft warning; invalidates before
--     cancel(token, reason), detach(song), and drafts.release(song), then
--     scrubs every retained delivery record. These optional dependency seams
--     never authorize occupancy retirement. Repeated close/release is inert.
--   lifetime_state() -> detached epoch/session/open/song_attached scalars.
-- Before first attach_document, the original delivery-only seam is supported.
-- After attachment, generation requires an attached song and open dialog.
-- Unresolved released records retain only token/scalars/diagnostic strings;
-- late completion can mark only its own terminal flags.
--
-- The returned context exposes generation, revocation, and lifetime methods.
-- Writer, capture, sink, delivery record, block, diagnostics, and dispatch
-- state remain closure-private.
local M = {}
local epoch_serial = 0

local function reason_text(value, fallback)
  if type(value) == "string" then return value end
  if type(value) == "table" then
    local message_ok, message = pcall(function() return value.message end)
    if message_ok and type(message) == "string" then return message end
    local text_ok, text = pcall(tostring, value)
    if text_ok and type(text) == "string" then return text end
    return fallback
  end
  if value ~= nil and value ~= false then
    local ok, text = pcall(tostring, value)
    if ok and type(text) == "string" then return text end
  end
  return fallback
end

local function new_token(record)
  local token = {}
  function token:is_current()
    local ok, current = pcall(function()
      return rawequal(self, token) and record.current == true
    end)
    return ok and current == true
  end
  return token
end

-- This callback retains only the scrub-able delivery record.
local function completion(record)
  return function(result)
    if record.finish then return record.finish(result) end
    if record.settled or record.rejected then return false end
    record.settled = true
    record.current = false
    return true
  end
end

local function inspect_writer(writer)
  local ok, status, token = pcall(writer.state, writer)
  if not ok then return nil, "writer state is unavailable" end
  if type(status) ~= "string" then
    return nil, "writer state did not return a status string"
  end
  if status == "idle" then
    if token ~= nil then return nil, "idle writer state returned an operation token" end
    return {status = "idle", token = nil}
  end
  if status == "busy" then return {status = "busy", token = token} end
  return nil, "writer state returned an unknown status"
end

function M.new(options)
  assert(type(options) == "table", "runtime context options are required")
  assert(type(options.writer) == "table" and type(options.writer.state) == "function",
    "runtime context requires writer.state")
  assert(type(options.capture) == "function", "runtime context requires request capture")
  assert(type(options.sink) == "function", "runtime context requires a sink")
  assert(options.issue_token == nil or type(options.issue_token) == "function",
    "runtime context issue_token must be a function")

  local writer = options.writer
  local capture = options.capture
  local sink = options.sink
  local issue_token = options.issue_token
  local current_song = nil
  local epoch = 0
  local session = 0
  local opened = false
  local lifecycle = false
  local gui_delivery = nil
  local cancel = options.cancel
  local detach = options.detach
  local drafts = options.drafts or require("runtime.draft_cache")
  local releasing = false
  local records = setmetatable({}, {__mode = "k"})
  local active = nil
  local dispatching = false
  local blocked = false
  local blocked_reason = nil
  local diagnostic_count = 0
  local last_diagnostic = nil
  local diagnosed_context = {}

  local function diagnose(record, code, message)
    local seen = record and record.diagnosed or diagnosed_context
    if seen[code] then return false end
    seen[code] = true
    diagnostic_count = diagnostic_count + 1
    last_diagnostic = {code = code, message = reason_text(message, code)}
    return true
  end

  local function block(record, code, message)
    diagnose(record, code, message)
    if not blocked then
      blocked = true
      blocked_reason = reason_text(message, code)
    end
  end

  local function retire(record)
    record.revoked = true
    record.current = false
    record.request = nil
    record.gui_delivery = nil
    if rawequal(active, record) then active = nil end
  end

  local function context_state()
    local record = active
    if record and record.settled then record = nil end
    local status = "idle"
    if blocked then
      status = "blocked"
    elseif record and not record.settled then
      status = "pending"
    end
    local last = last_diagnostic
    return {
      status = status,
      token = record and record.token or nil,
      authorization = record ~= nil and record.current == true and record.settled ~= true,
      blocked = blocked == true,
      blocked_reason = blocked_reason,
      diagnostic_count = diagnostic_count,
      last_diagnostic = last and {code = last.code, message = last.message} or nil,
    }
  end

  local function uncertain_start(record, failure)
    local state, inspection_error = inspect_writer(writer)
    local detail = reason_text(failure, "the sink failed")
    if not state then
      record.rejected = true
      retire(record)
      block(record, "delivery.start_unverified",
        "Cannot verify writer acceptance after the sink failed: " .. detail ..
        " (" .. tostring(inspection_error) .. "); dispatch is blocked until writer state is safe")
      return false, blocked_reason
    end
    if state.status == "busy" and record.token ~= nil and rawequal(state.token, record.token) then
      if record.settled then
        block(record, "delivery.sink_failed_after_completion",
          "Sink failed after completing the accepted request: " .. detail ..
          "; dispatch is blocked until writer state is safe")
        return true
      end
      record.revoked = true
      record.current = false
      block(record, "delivery.sink_failed_after_acceptance",
        "Sink failed after starting the accepted request: " .. detail ..
        "; commit authorization is revoked and dispatch is blocked until the matching completion retires it")
      return true
    end
    if state.status == "idle" then
      if record.settled then
        diagnose(record, "delivery.sink_failed_after_completion",
          "Sink failed after completing the request: " .. detail)
        return true
      end
      record.rejected = true
      retire(record)
      diagnose(record, "delivery.sink_failed_before_acceptance",
        "Sink failed before acceptance: " .. detail)
      return false, detail
    end
    record.rejected = true
    retire(record)
    block(record, "delivery.start_unverified",
      "Cannot verify writer acceptance after the sink failed: " .. detail ..
      "; dispatch is blocked until writer state is safe")
    return false, blocked_reason
  end

  local function invalid_acceptance(record)
    local state, state_error = inspect_writer(writer)
    if state and state.status == "busy" and record.token ~= nil and
        rawequal(state.token, record.token) then
      record.revoked = true
      record.current = false
      block(record, "delivery.invalid_acceptance",
        "Sink returned an invalid acceptance result while the writer held the issued token; " ..
        "commit authorization is revoked and dispatch is blocked until the matching completion retires it")
      return true
    end
    record.rejected = true
    retire(record)
    if state and state.status == "idle" then
      block(record, "delivery.invalid_acceptance",
        "Sink returned an invalid acceptance result before acceptance; " ..
        "dispatch is blocked until writer state is safe")
    else
      block(record, "delivery.invalid_acceptance",
        "Sink returned an invalid acceptance result and writer occupancy could not be verified" ..
        (state_error and (": " .. tostring(state_error)) or "") ..
        "; dispatch is blocked until writer state is safe")
    end
    return false, blocked_reason
  end

  local context = {}

  function context:request_generation(trigger)
    if releasing or (lifecycle and (current_song == nil or not opened)) then
      return false, "No current document dialog is open"
    end
    if dispatching then
      return false, "A generation request is already dispatching"
    end

    if blocked then
      if active and not active.settled then
        return false, blocked_reason or "Generation dispatch is blocked"
      end
      local state = inspect_writer(writer)
      if not state or state.status ~= "idle" then
        return false, blocked_reason or "Generation dispatch is blocked"
      end
      blocked = false
      blocked_reason = nil
    end

    if active and not active.settled then
      return false, "A generation is already in progress"
    end

    local occupied, inspection_error = inspect_writer(writer)
    if not occupied then
      block(nil, "admission.state_unavailable",
        "Cannot inspect writer occupancy: " .. tostring(inspection_error) ..
        "; dispatch is blocked until writer state is safe")
      return false, blocked_reason
    end
    if occupied.status ~= "idle" then
      return false, "The writer slot is occupied"
    end

    dispatching = true
    local record = {
      current = false,
      settled = false,
      rejected = false,
      revoked = false,
      diagnosed = {},
      epoch = epoch,
      session = session,
      gui_delivery = gui_delivery,
    }
    records[record] = true
    local issue_ok, issued_token
    if issue_token then
      issue_ok, issued_token = pcall(issue_token)
    else
      issue_ok, issued_token = true, new_token(record)
    end
    if not issue_ok or issued_token == nil or issued_token == false then
      dispatching = false
      retire(record)
      return false, issue_ok and "Cannot issue a generation token" or
        reason_text(issued_token, "Cannot issue a generation token")
    end
    local token = issued_token
    record.token = token

    local captured, request, capture_reason = pcall(capture, trigger, token)
    if not captured then
      dispatching = false
      retire(record)
      return false, reason_text(request, "Generation capture failed")
    end
    if request == nil then
      dispatching = false
      retire(record)
      return false, capture_reason or "Generation request rejected"
    end
    if type(request) ~= "table" then
      dispatching = false
      retire(record)
      return false, "Generation capture returned an invalid request"
    end
    local token_ok, request_token = pcall(function() return request.token end)
    if not token_ok then
      dispatching = false
      retire(record)
      return false, "Cannot inspect the captured request token"
    end
    if request_token == nil then
      dispatching = false
      retire(record)
      return false, "Generation capture did not return the issued token"
    end
    if not rawequal(request_token, token) then
      dispatching = false
      retire(record)
      return false, "Generation capture returned a foreign token"
    end

    if record.released or (lifecycle and
        (current_song == nil or not opened or epoch ~= record.epoch or session ~= record.session)) then
      dispatching = false
      retire(record)
      return false, "Generation context changed during capture"
    end
    record.current = true
    record.request = request
    active = record
    record.finish = function(result)
      if record.rejected then
        block(record, "delivery.completion_after_rejection",
          "Sink completed a rejected request; dispatch is blocked until writer state is safe")
        return false
      end
      if record.settled then
        block(record, "delivery.duplicate_completion",
          "Sink completed the request more than once; dispatch is blocked until writer state is safe")
        return false
      end
      if record.revoked then
        -- Revoked authorization retires its own bookkeeping without a result
        -- delivery; writer occupancy remains the writer's to retire.
        record.settled = true
        record.current = false
        record.revoked_completion = true
        record.request = nil
        if rawequal(active, record) then active = nil end
        return true
      end
      record.settled = true
      record.current = false
      record.request = nil
      if rawequal(active, record) then active = nil end
      local delivery = record.gui_delivery
      record.gui_delivery = nil
      if delivery then
        local delivered, failure = pcall(delivery, result)
        if not delivered then diagnose(record, "delivery.gui_failed", failure) end
      end
      return true
    end
    local done = completion(record)

    local called, accepted, rejection = pcall(sink, request, done)
    dispatching = false

    if not called then
      return uncertain_start(record, accepted)
    end

    if accepted == true then
      return true
    end

    if accepted == false then
      if record.settled then
        block(record, "delivery.complete_then_reject",
          "Sink completed the request and then rejected it; dispatch is blocked until writer state is safe")
        return false, blocked_reason
      end
      local state, state_error = inspect_writer(writer)
      if not state then
        record.rejected = true
        retire(record)
        block(record, "delivery.reject_with_unverified_occupancy",
          "Sink rejected the request but writer occupancy could not be verified: " ..
          tostring(state_error) .. "; dispatch is blocked until writer state is safe")
        return false, blocked_reason
      end
      if state.status == "busy" then
        record.rejected = true
        retire(record)
        if rawequal(state.token, record.token) then
          block(record, "delivery.reject_with_writer_ownership",
            "Sink rejected the request while the writer held its issued token; dispatch is blocked until writer state is safe")
        else
          block(record, "delivery.reject_with_writer_occupancy",
            "Sink rejected the request while the writer slot was occupied; dispatch is blocked until writer state is safe")
        end
        return false, blocked_reason
      end
      record.rejected = true
      retire(record)
      return false, rejection
    end

    if record.settled then
      block(record, "delivery.invalid_acceptance",
        "Sink completed the request and returned an invalid acceptance result; dispatch is blocked until writer state is safe")
      return false, blocked_reason
    end
    return invalid_acceptance(record)
  end

  function context:revoke(token, reason)
    local record = active
    if not record or record.settled or record.rejected or record.revoked then
      return false
    end
    if not rawequal(record.token, token) then return false end
    record.revoked = true
    record.current = false
    record.revoke_reason = reason_text(reason, "Generation request revoked")
    return true
  end

  local function invalidate(reason)
    local record = active
    if not record then return end
    record.gui_delivery = nil
    if record.settled or record.rejected then return end
    record.current = false
    record.revoked = true
    record.revoke_reason = reason
    if cancel then
      local ok, failure = pcall(cancel, record.token, reason)
      if not ok then
        diagnose(record, "lifetime.cancel_failed", reason_text(failure, "Writer cancellation failed"))
      end
    end
  end

  function context:close_dialog()
    if not opened then return false end
    opened = false
    gui_delivery = nil
    for record in pairs(records) do record.gui_delivery = nil end
    invalidate("Dialog closed")
    return true
  end

  function context:release_document()
    if current_song == nil or releasing then return false end
    releasing = true
    local song = current_song
    opened = false
    gui_delivery = nil
    invalidate("Document released")
    if detach then
      local ok, failure = pcall(detach, song)
      if not ok then diagnose(nil, "lifetime.detach_failed", failure) end
    end
    local warning
    if drafts and type(drafts.release) == "function" then
      local ok, _, message = pcall(drafts.release, song)
      if ok then warning = message
      else
        warning = "Session-only ACID draft release failed"
        diagnose(nil, "lifetime.drafts_failed", warning)
      end
    end
    current_song = nil
    for record in pairs(records) do
      record.request = nil
      record.gui_delivery = nil
      record.finish = nil
      record.released = true
    end
    records = setmetatable({}, {__mode = "k"})
    blocked = false
    blocked_reason = nil
    releasing = false
    return true, warning
  end

  function context:attach_document(song)
    assert(song ~= nil, "A current document is required")
    assert(not releasing, "Document release is in progress")
    if current_song ~= nil then self:release_document() end
    lifecycle = true
    epoch_serial = epoch_serial + 1
    epoch = epoch_serial
    current_song = song
    opened = false
    gui_delivery = nil
    return epoch
  end

  function context:open_dialog(delivery)
    assert(current_song ~= nil and not releasing, "A current document is required")
    assert(delivery == nil or type(delivery) == "function", "GUI delivery must be a function")
    if opened then self:close_dialog() end
    session = session + 1
    opened = true
    gui_delivery = delivery
    return session
  end

  function context:lifetime_state()
    return {epoch = epoch, session = session, open = opened,
      song_attached = current_song ~= nil}
  end

  function context:state()
    return context_state()
  end

  return context
end

return M
