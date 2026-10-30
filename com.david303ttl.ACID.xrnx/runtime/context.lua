-- SPDX-License-Identifier: GPL-3.0-only
-- Runtime generation delivery boundary.
-- Attached contexts with an installed editor use runtime-owned frozen capture,
-- transition revisions, eligibility, mutation scopes and integrity evidence.
-- The injected capture remains the delivery-conformance seam until an editor
-- is installed. GUI authority cutover uses the same public context methods.
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
--     request:mutate(token, action) -> all action result values
--       Same operation token only. Depth-counted and non-yielding; unwinds on
--       success or exception, revokes authorization on exception, and
--       rethrows the original failure. No user callback, idle wait, or render
--       wait may run inside it.
--       Requires writer.is_temporary and captures exact pre-scope recovery
--       evidence. A failed outer scope records that evidence for explicit
--       revalidation after settlement and native restoration.
--     request:record_blocker(token, evidence)
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
--   This is the single scheduler entry for manual and armed Live Edit requests.
--   While an accepted request is active, a later request replaces one pending
--   trigger; it is captured and dispatched only after terminal completion.
--   Disarm drops pending Live Edit but leaves an explicit manual intent queued.
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
  local inventory = nil
  local requests = nil
  local integrity = nil
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
  local pending_trigger = nil
  local flushing = false
  local last_result = nil
  local last_commit = nil
  local last_commit_label = nil
  local mutation_depth, mutation_token = 0, nil
  local identity_token={}
  local identity_running=false
  local mutation_evidence=nil
  local mutation_group_membership=nil
  local inventory_dirty, reconciliation_pending, mutation_failed = false, false, false
  local native_instrument, native_phrase = nil, nil
  local transitions=require("runtime.transitions").new()
  local editor=nil
  local editor_dirty=false
  local preserve_editor
  local editor_target=nil
  local editor_recovery={}
  local observed_target=nil
  local ownership=require("renoise.phrase_ownership")
  local policies=require("model.policies")
  local store=require("renoise.pattern_store")
  local sequencer=require("model.sequencer")

  local function semantic(target)
    return {kind=target.kind,reason=target.reason,baseline=target.baseline}
  end

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
    local integrity_state=integrity and integrity:state() or {blocked=false}
    local record = active
    if record and record.settled then record = nil end
    local status = "idle"
    if blocked or integrity_state.blocked then
      status = "blocked"
    elseif record and not record.settled then
      status = "pending"
    end
    local last = last_diagnostic
    return {
      status = status,
      pending = pending_trigger ~= nil,
      token = record and record.token or nil,
      authorization = record ~= nil and record.current == true and record.settled ~= true,
      blocked = blocked == true or integrity_state.blocked,
      blocked_reason = integrity_state.reason or blocked_reason,
      diagnostic_count = diagnostic_count,
      last_diagnostic = last and {code = last.code, message = last.message} or nil,
    }
  end

  local function summary(result)
    if type(result)~="table" then return nil end
    return {kind=result.kind,status=result.status,verified=result.verified==true,
      approximate=result.approximate==true,reason=result.reason,
      message=result.message,code=result.code,category=result.category}
  end

  local function target_label(record,phrase)
    local instrument=record and record.instrument
    local instrument_name="(unknown instrument)"
    local phrase_name="(unknown phrase)"
    pcall(function()
      if instrument and type(instrument.name)=="string" and instrument.name~="" then
        instrument_name=instrument.name
      end
      if phrase and type(phrase.name)=="string" and phrase.name~="" then
        phrase_name=phrase.name
      end
    end)
    local index=0
    if phrase and record then
      local member,position=ownership.membership(record.song,instrument,phrase)
      if member and type(position)=="number" then index=position end
    end
    return string.format("%s / %02d %s",instrument_name,index,phrase_name)
  end

  local function host_object(value)
    if value==nil then return false end
    local kind=type(value)
    return kind=="table" or kind=="userdata" or kind=="InstrumentPhrase"
  end

  local function normalize_result(record,result)
    local copy={}
    if type(result)=="table" then
      for key,value in pairs(result) do copy[key]=value end
    end
    copy.token=copy.token==nil and record.token or copy.token
    copy.epoch=copy.epoch==nil and record.epoch or copy.epoch
    copy.request=copy.request==nil and (record.request or nil) or copy.request
    local valid_token=copy.token~=nil and rawequal(copy.token,record.token)
    local success=copy.kind=="success" and copy.verified==true and valid_token
    if success and copy.integrity_blocked==true then
      success=false
      copy.status="integrity_blocked"
      copy.reason=copy.reason or copy.message or
        "Committed output retained recovery material and requires revalidation"
    elseif success and not host_object(copy.phrase) then
      success=false
      copy.status="failed"
      copy.reason="Writer success did not include its destination phrase"
    elseif success and type(copy.baseline)~="table" then
      success=false
      copy.status="failed"
      copy.reason="Writer success did not include a verified committed baseline"
    end
    if copy.kind=="success" and not success then
      copy.kind="failure"
      copy.status=copy.status or "failed"
      copy.verified=false
      copy.reason=copy.reason or (valid_token and "Writer returned an unverified success" or
        "Writer returned a foreign completion token")
    end
    if copy.kind==nil then
      copy.kind="failure"
      copy.status=copy.status or "failed"
      copy.verified=false
      copy.reason=copy.reason or copy.message or "Writer returned no terminal result"
    end
    return copy,success
  end

  local function adopt_success(record,result,destination_current)
    if not destination_current or not inventory then return false,"No current destination inventory" end
    if not host_object(result.phrase) then return false,"Committed destination phrase is unavailable" end
    local request=record.request
    if not request then return false,"Request values are unavailable" end
    local phrase=result.phrase
    if request.kind=="regenerate" then
      if not rawequal(phrase,request.phrase) then return false,"Returned destination changed" end
    elseif request.kind~="create" then
      return false,"Request has no committed destination"
    end
    local copied,reason=inventory:adopt(request.instrument,phrase,result.baseline)
    if not copied then
      pending_trigger=nil
      return false,reason or "Cannot adopt committed baseline"
    end
    if request.kind=="create" and not rawequal(request.phrase,phrase) then
      inventory:bind_phrase(request.instrument,phrase)
      transitions:transition("target",{instrument=request.instrument,phrase=phrase,kind="owned"})
      editor_target={instrument=request.instrument,phrase=phrase,kind="owned"}
      observed_target=semantic(inventory:target_state())
      -- A pending edit was preserved under the previous New target. Move that
      -- session draft to the destination returned by the committed create so
      -- the queued request can capture it after adoption.
      if pending_trigger then preserve_editor(true) end
    end
    editor_dirty=false
    return true
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

  local function flush_pending()
    if flushing or not pending_trigger then return false end
    if dispatching or (active and not active.settled) then return false end
    if releasing or (lifecycle and (current_song == nil or not opened)) then
      pending_trigger=nil
      return false
    end
    if pending_trigger=="live" and not transitions:revision_state().armed then
      pending_trigger=nil
      return false
    end
    if (blocked or (integrity and integrity:state().blocked)) then
      pending_trigger=nil
      return false
    end
    local occupied,reason=inspect_writer(writer)
    if not occupied or occupied.status~="idle" then return false end
    local trigger=pending_trigger
    pending_trigger=nil
    flushing=true
    local accepted,detail=context:request_generation(trigger)
    flushing=false
    if not accepted and detail~=nil then
      diagnose(nil,"scheduler.dispatch",reason_text(detail,"Unable to dispatch the pending request"))
    end
    return accepted,detail
  end

  function context:request_generation(trigger)
    if mutation_depth>0 or mutation_failed then
      return false,"Synchronous mutation is active or requires recovery"
    end
    if releasing or (lifecycle and (current_song == nil or not opened)) then
      return false, "No current document dialog is open"
    end
    if dispatching then
      return false, "A generation request is already dispatching"
    end
    if editor then
      if trigger~="manual" and trigger~="live" then return false,"Invalid generation trigger" end
      if trigger=="live" and not transitions:revision_state().armed then return false,"Live Edit is not armed" end
      if not editor.valid then return false,editor.reason or "Invalid editor source or settings" end
      local destination=self:target_state()
      if not editor_target or not rawequal(destination.instrument,editor_target.instrument) or
          not rawequal(destination.phrase,editor_target.phrase) or destination.kind~=editor_target.kind then
        return false,"Editor source has not been loaded for this target"
      end
      local eligible,reason=self:musical_eligibility(active and active.token)
      if not eligible then return false,reason end
      local occupied, inspection_error=inspect_writer(writer)
      if not occupied then
        block(nil,"admission.state_unavailable",
          "Cannot inspect writer occupancy: "..tostring(inspection_error)..
          "; dispatch is blocked until writer state is safe")
        return false,blocked_reason
      end
      if active and not active.settled or occupied.status~="idle" then
        if blocked then return false,blocked_reason or "Generation dispatch is blocked" end
        pending_trigger=trigger
        preserve_editor(destination.kind=="new")
        return true,"Generation queued for the current writer job"
      end
      self:transition("request",{trigger=trigger})
    end
    if integrity and integrity:state().blocked then return false,integrity:state().reason end
    if mutation_failed then return false,"Synchronous mutation failed; recovery must be verified" end
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

    if editor then preserve_editor(editor_target and editor_target.kind=="new") end

    dispatching = true
    local record = {
      current = false,
      settled = false,
      rejected = false,
      revoked = false,
      diagnosed = {},
      epoch = epoch,
      session = session,
      trigger = trigger,
      revisions = editor and transitions:revision_state() or nil,
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

    local capture_action=capture
    if editor then capture_action=function(kind,operation_token) return requests:capture(kind,operation_token) end end
    local captured, request, capture_reason = pcall(capture_action, trigger, token)
    if not captured then
      dispatching = false
      retire(record)
      return false, reason_text(request, "Generation capture failed")
    end
    if request == nil then
      dispatching = false
      retire(record)
      return false, reason_text(capture_reason, "Generation request rejected")
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
    if editor then
      local valid,validation_error=requests:validate_checkpoint(request)
      if not valid then
        record.rejected=true
        retire(record)
        dispatching=false
        return false,validation_error
      end
    end
    record.finish = function(result)
      local terminal_current=not lifecycle or (current_song~=nil and opened and
        not record.released and record.epoch==epoch and record.session==session)
      if record.rejected then
        if terminal_current then
          block(record, "delivery.completion_after_rejection",
            "Sink completed a rejected request; dispatch is blocked until writer state is safe")
        end
        return false
      end
      if record.settled then
        if terminal_current then
          block(record, "delivery.duplicate_completion",
            "Sink completed the request more than once; dispatch is blocked until writer state is safe")
        end
        return false
      end
      local terminal,success=normalize_result(record,result)
      local revisions=transitions:revision_state()
      local destination_current=record.session==session and not record.released and
        record.revisions~=nil and revisions.target_revision==record.revisions.target_revision
      record.settled = true
      record.current = false
      local effects
      if record.revisions then
        effects=transitions:transition("completion",{success=success,
          operation_serial=record.revisions.operation_serial,
          target_revision=record.revisions.target_revision,
          edit_revision=record.revisions.edit_revision})
      end
      local apply_success=effects and effects.apply_success==true or false
      if success and destination_current then
        local adopted,adopt_reason=adopt_success(record,terminal,destination_current)
        if not adopted then
          diagnose(record,"completion.baseline",adopt_reason)
          success=false
          apply_success=false
          terminal.kind="failure"
          terminal.status="integrity_blocked"
          terminal.verified=false
          terminal.reason=adopt_reason or "Committed baseline could not be adopted"
        end
      end
      if not success and terminal.status=="integrity_blocked" and terminal_current then
        pending_trigger=nil
      end
      local request=record.request
      if success and destination_current and request and request.draft_capture and
          type(drafts.compare_and_clear)=="function" then
        local cleared,clear_error=pcall(drafts.compare_and_clear,request.song,
          request.draft_capture,request.kind=="create")
        if not cleared then
          diagnose(record,"completion.draft_clear",clear_error)
        end
      end
      if terminal_current and success then inventory_dirty=true;reconciliation_pending=true end
      if terminal_current and effects and effects.reconcile then
        inventory_dirty=true;reconciliation_pending=true
      end
      if terminal_current and (not record.revoked or record.blocker_pending) then
        last_result=summary(terminal)
        if success and apply_success then
          last_commit=summary(terminal)
          last_commit_label=target_label(record.request or record,terminal.phrase)
        end
      elseif success and destination_current then
        terminal.stale=true
      end
      terminal.apply_success=apply_success
      terminal.destination_current=destination_current
      local delivery = record.gui_delivery
      record.gui_delivery = nil
      if terminal_current and delivery and (not record.revoked or
          (success and destination_current) or (record.blocker_pending and not success)) then
        local delivered, failure = pcall(delivery, terminal)
        if not delivered then diagnose(record, "delivery.gui_failed", failure) end
      end
      record.request=nil
      if rawequal(active, record) then active = nil end
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
      return false, reason_text(rejection, "Generation request rejected")
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
    if not record.blocker_pending then record.gui_delivery = nil end
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

  preserve_editor=function(force)
    if (not editor_dirty and not force) or not editor or not inventory or not current_song then return end
    local target=inventory:target_state()
    if not target.instrument then return end
    if not editor_target or not rawequal(target.instrument,editor_target.instrument) or
        not rawequal(target.phrase,editor_target.phrase) then return end
    local ok,saved,reason=pcall(drafts.put,current_song,target.instrument,target.phrase,
      editor.source,editor.output_policy,editor.pb_range,context:draft_options())
    editor.draft_warning=not ok and "Cannot preserve session draft" or (not saved and reason or nil)
  end

  local function retain_invalid_editor()
    if editor and not editor.valid then
      local copy=ownership.copy_snapshot(editor)
      if copy then editor_recovery[#editor_recovery+1]=copy end
    end
  end

  local function apply_effects(effects,reason)
    if effects.revoke=="all" or (effects.revoke=="live" and active and active.trigger=="live") then
      invalidate(reason or "Runtime state changed")
    end
    if effects.detach_draft and inventory and current_song then
      local target=inventory:target_state()
      if target.instrument and drafts.detach then
        pcall(drafts.detach,current_song,target.instrument,target.phrase,reason or "Target eligibility changed")
      end
    end
  end

  function context:revision_state() return transitions:revision_state() end

  function context:flush_pending() return flush_pending() end

  function context:generation_state()
    local revisions=transitions:revision_state()
    local state,reason=inspect_writer(writer)
    local busy=state~=nil and state.status=="busy"
    local status="CLEAN"
    if pending_trigger or busy or (active and not active.settled) then
      status=pending_trigger and "DIRTY" or "RENDERING"
    elseif last_result and last_result.kind=="failure" then
      status="ERROR"
    elseif last_commit then
      status=last_commit.approximate and "APPROXIMATE" or "COMMITTED"
    end
    return {armed=revisions.armed,busy=busy,pending=pending_trigger~=nil,
      status=status,last_result=last_result and summary(last_result) or nil,
      last_commit=last_commit and summary(last_commit) or nil,
      last_commit_label=last_commit_label,occupancy_reason=reason}
  end

  function context:is_temporary(instrument,phrase)
    if not current_song or type(writer.is_temporary)~="function" then return false end
    local ok,temporary=pcall(writer.is_temporary,current_song,instrument,phrase)
    return ok and temporary==true
  end

  function context:editor_state()
    return editor and ownership.copy_snapshot(editor) or nil
  end

  function context:editor_recovery()
    return ownership.copy_snapshot(editor_recovery)
  end

  function context:musical_eligibility(token)
    if not current_song or not opened then return nil,"No current document dialog is open" end
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    local blocked_state=self:integrity_state()
    if blocked_state.blocked then return nil,blocked_state.reason end
    local occupancy=self:occupancy_state(token)
    if not occupancy.available then return nil,occupancy.reason end
    if active and not active.settled and not rawequal(active.token,token) then return nil,"An accepted operation has not settled" end
    local ok,undo=pcall(function()
      if type(current_song.is_undo_redoing)~="function" then error("Undo state is unavailable") end
      local undo=current_song:is_undo_redoing()
      assert(type(undo)=="boolean","Undo state is unavailable")
      return undo
    end)
    if not ok or undo then return nil,"Native undo or redo is processing or unavailable" end
    local target=self:target_state()
    if target.kind~="new" and target.kind~="owned" then return nil,target.reason or "Target is not writable" end
    return target
  end

  function context:independence_eligibility()
    if not current_song or not opened then return nil,"No current document dialog is open" end
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    local state=self:integrity_state()
    if state.blocked then return nil,state.reason end
    if not self:occupancy_state().available or (active and not active.settled) then return nil,"The writer has not settled" end
    local ok,undo=pcall(function()
      if type(current_song.is_undo_redoing)~="function" then error("Undo state is unavailable") end
      local undo=current_song:is_undo_redoing()
      assert(type(undo)=="boolean","Undo state is unavailable")
      return undo
    end)
    if not ok or undo then return nil,"Native undo or redo is processing or unavailable" end
    return require("runtime.eligibility").independence(current_song,self:target_state())
  end

  function context:make_independent()
    if not current_song or not opened then return false,"No current document dialog is open" end
    if identity_running then return false,"Make Independent is already running" end
    local target=self:target_state()
    local initial,reason=self:independence_eligibility()
    if not initial then return false,reason end
    local carry_draft
    if editor_dirty and editor and editor.valid and editor_target and
        rawequal(editor_target.instrument,target.instrument) and
        rawequal(editor_target.phrase,target.phrase) then
      local committed,committed_policy,committed_pb=store.read_entry(current_song,initial.id)
      if committed and (not sequencer.same_source(editor.source,committed) or
          editor.output_policy~=committed_policy or editor.pb_range~=committed_pb) then
        carry_draft=ownership.copy_snapshot({source=editor.source,
          output_policy=editor.output_policy,pb_range=editor.pb_range})
      end
    end
    preserve_editor()
    self:transition("independence")
    initial,reason=self:independence_eligibility()
    if not initial then return false,reason end
    local song=current_song
    local function guard()
      if not rawequal(current_song,song) or not opened then return false,"Document session changed" end
      if mutation_failed or (mutation_depth>0 and not identity_running) then
        return false,"Synchronous mutation is active or requires recovery"
      end
      local integrity_state=self:integrity_state()
      if integrity_state.blocked then return false,integrity_state.reason end
      local occupancy=self:occupancy_state()
      if not occupancy.available or (active and not active.settled) then
        return false,occupancy.reason or "The writer has not settled"
      end
      local undo_ok,undo=pcall(function() return song:is_undo_redoing() end)
      if not undo_ok or type(undo)~="boolean" or undo then
        return false,"Native undo or redo is processing or unavailable"
      end
      local current_target=inventory and inventory:target_state()
      if not current_target or not rawequal(current_target.instrument,target.instrument) or
          not rawequal(current_target.phrase,target.phrase) then
        return false,"Selected phrase changed before resolution"
      end
      local proof,proof_error=require("runtime.eligibility").independence(song,current_target)
      if not proof then return false,proof_error end
      if proof.id~=initial.id or proof.holders~=initial.holders then
        return false,"Collision group changed before resolution"
      end
      return true
    end
    identity_running=true
    local called,changed,result=pcall(function()
      return require("runtime.independence").run(song,target,{
        guard=guard,
        mutate=function(action) return self:mutate(identity_token,action) end,
      })
    end)
    identity_running=false
    if not called then return false,changed end
    if not changed then return false,result end
    local adopted,adopt_error=inventory:adopt(target.instrument,target.phrase,result.baseline)
    if not adopted then return false,adopt_error or "Cannot adopt the independent phrase baseline" end
    self:transition("refresh")
    local restored_source,restored_policy,restored_pb=result.source,result.output_policy,result.pb_range
    local draft_persisted=true
    local draft_warning
    if carry_draft then
      local saved_ok,saved,save_error=pcall(drafts.put,current_song,target.instrument,target.phrase,
        carry_draft.source,carry_draft.output_policy,carry_draft.pb_range,self:draft_options())
      draft_persisted=saved_ok and saved==true
      draft_warning=(saved_ok and not saved) and save_error or (not saved_ok and saved) or nil
      restored_source,restored_policy,restored_pb=carry_draft.source,
        carry_draft.output_policy,carry_draft.pb_range
    end
    local restored,restore_error=self:transition("programmatic",{source=restored_source,
      output_policy=restored_policy,pb_range=restored_pb,restore=true})
    if not restored then return false,restore_error end
    if carry_draft and not draft_persisted then
      editor_dirty=true
      if editor then editor.draft_warning=draft_warning or "Cannot preserve matching object-local draft" end
    end
    return true,result
  end

  function context:recovery_entries()
    if not current_song then return {} end
    local entries,reason=drafts.list(current_song)
    if not entries then return nil,reason end
    local result={}
    for _,entry in ipairs(entries) do
      result[#result+1]={token=entry.token,revision=entry.revision,
        labels={instrument=entry.labels and entry.labels.instrument or "Unavailable instrument",
          phrase=entry.labels and entry.labels.phrase or "Unavailable phrase"},
        reason=entry.reason or "Draft target changed",session_only=entry.session_only==true}
    end
    return result
  end

  function context:discard_recovery(token,revision)
    if not current_song then return false,"No current document is attached" end
    if not policies.is_integer(token) or not policies.is_integer(revision) then
      return false,"Invalid recovery selection"
    end
    return drafts.discard(current_song,token,revision)
  end

  function context:copy_recovery_to_new(token,revision)
    if not current_song or not opened then return false,"No current document dialog is open" end
    if mutation_depth>0 or mutation_failed then return false,"Synchronous mutation is active or requires recovery" end
    if not policies.is_integer(token) or not policies.is_integer(revision) then
      return false,"Invalid recovery selection"
    end
    local function selected_entry_is_current()
      local rows=drafts.list(current_song)
      if type(rows)~="table" then return false end
      for _,entry in ipairs(rows) do
        if entry.token==token and entry.revision==revision then return true end
      end
      return false
    end
    if not selected_entry_is_current() then return false,"Recovery entry is unavailable or has changed" end
    local bound=self:target_state()
    local instrument=bound.instrument
    if not instrument then return false,bound.reason or "Select an instrument first" end
    if bound.kind~="new" then
      local scratch=self:bind_new(instrument)
      if not scratch or scratch.kind~="new" then return false,scratch and scratch.reason or "Cannot bind New Phrase" end
    else
      preserve_editor()
    end
    if not selected_entry_is_current() then return false,"Recovery entry changed while preserving the current editor" end
    local source,output_policy,pb_range,metadata=drafts.copy_to_new(current_song,instrument,
      token,revision,self:draft_options())
    if not source then return false,output_policy end
    local restored,restore_error=self:transition("programmatic",{source=source,
      output_policy=output_policy,pb_range=pb_range,restore=true})
    if not restored then return false,restore_error end
    return true,{instrument=instrument,token=token,revision=revision,metadata=metadata,
      warning=metadata and metadata.warning}
  end

  function context:transition(kind,values)
    values=values or {}
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    if not inventory then return nil,"No current document is attached" end
    if kind=="target" or kind=="native_target" then
      pending_trigger=nil
      local before=inventory:target_state()
      local changed=not rawequal(before.instrument,values.instrument) or not rawequal(before.phrase,values.phrase)
        or (kind=="target" and values.kind=="new")~=(before.kind=="new")
      if changed then preserve_editor();retain_invalid_editor() end
      local target
      if kind=="target" and values.kind=="new" then target=inventory:bind_new(values.instrument)
      else target=inventory:bind_phrase(values.instrument,values.phrase) end
      local effects=transitions:transition(kind,{instrument=target.instrument,phrase=target.phrase,kind=target.kind,
        semantic_changed=not changed and observed_target~=nil and not ownership.compare(observed_target,semantic(target))})
      apply_effects(effects,"Target changed")
      observed_target=semantic(target)
      if kind=="target" then
        local read,instrument,phrase=pcall(function()
          return current_song.selected_instrument,current_song.selected_phrase
        end)
        if read then native_instrument,native_phrase=instrument,phrase end
      end
      return target,effects
    elseif kind=="refresh" then
      local target=inventory:target_state()
      local changed=observed_target~=nil and not ownership.compare(observed_target,semantic(target))
      if changed then pending_trigger=nil end
      local effects=transitions:transition(kind,{semantic_changed=changed})
      apply_effects(effects,"Target eligibility changed")
      observed_target=semantic(target)
      return target,effects
    elseif kind=="edit" or kind=="programmatic" or kind=="reset" or kind=="recovery" then
      if kind~="edit" then pending_trigger=nil end
      local buffer,copy_error=ownership.copy_snapshot({source=values.source,output_policy=values.output_policy,pb_range=values.pb_range})
      if not buffer then return nil,copy_error end
      local changed=not editor or not ownership.compare({source=editor.source,output_policy=editor.output_policy,pb_range=editor.pb_range},buffer)
      local policies=require("model.policies")
      local source,source_error=require("model.sequencer").copy_source(buffer.source)
      buffer.valid=source~=nil and policies.valid_output_policy(buffer.output_policy) and policies.valid_pb_range(buffer.pb_range)
      buffer.reason=not buffer.valid and (source_error or "Invalid source settings") or nil
      local eligible=self:musical_eligibility(active and active.token)
      local effects=transitions:transition(kind,{changed=changed,valid=buffer.valid,eligible=eligible~=nil})
      apply_effects(effects,"Editor source or settings changed")
      if changed then retain_invalid_editor() end
      editor=buffer
      if kind=="programmatic" and values.restore==true then editor_dirty=false
      elseif changed then editor_dirty=true end
      local destination=inventory:target_state()
      editor_target={instrument=destination.instrument,phrase=destination.phrase,kind=destination.kind}
      if changed and not (kind=="programmatic" and values.restore==true) then preserve_editor() end
      if effects.live_intent then
        effects.accepted,effects.reason=self:request_generation("live")
      end
      return self:editor_state(),effects
    end
    local effects=transitions:transition(kind,values)
    apply_effects(effects,"Runtime "..kind)
    if kind=="disarm" and pending_trigger=="live" then pending_trigger=nil end
    if kind=="request" or kind=="independence" or kind=="external" or kind=="undo"
        or kind=="close" or kind=="blocker" then pending_trigger=nil end
    if effects.reconcile then inventory_dirty=true;reconciliation_pending=true end
    if kind=="independence" then
      local proof,reason=self:independence_eligibility()
      return proof,reason
    end
    return effects
  end

  function context:mutation_state()
    return {depth=mutation_depth,dirty=inventory_dirty,pending=reconciliation_pending,failed=mutation_failed}
  end

  function context:mark_dirty(reason)
    inventory_dirty=true
    reconciliation_pending=true
    if mutation_depth==0 then
      pending_trigger=nil
      apply_effects(transitions:transition("external"),reason or "External native change")
    end
  end

  function context:mutate(token,action)
    local identity_scope=identity_running and rawequal(token,identity_token)
    if type(action)~="function" or (not identity_scope and (not active or not active.current or
        not rawequal(active.token,token))) or not current_song or
        (mutation_depth>0 and not rawequal(mutation_token,token)) then
      error("Mutation requires the current operation token",0)
    end
    if mutation_depth==0 then
      if type(writer.is_temporary)~="function" then
        error("Mutation requires a temporary phrase registry",0)
      end
      local groups,inventory_error=ownership.inventory(current_song)
      if not groups then error(inventory_error or "Cannot capture ownership groups",0) end
      mutation_group_membership={}
      for id,holders in pairs(groups) do
        local members={}
        for _,holder in ipairs(holders) do
          members[#members+1]={instrument=holder.instrument,phrase=holder.phrase}
        end
        mutation_group_membership[id]=members
      end
      local evidence,reason=integrity:capture_mutation()
      if not evidence then mutation_group_membership=nil;error(reason or "Cannot capture mutation recovery evidence",0) end
      mutation_evidence=evidence
    end
    mutation_depth=mutation_depth+1
    mutation_token=token
    local scope_song,scope_epoch=current_song,epoch
    local values
    local function packed(...) return {n=select("#",...),...} end
    local ok,failure=pcall(function() values=packed(action()) end)
    if not rawequal(scope_song,current_song) or scope_epoch~=epoch then
      error("Document changed during synchronous mutation",0)
    end
    mutation_depth=mutation_depth-1
    if not ok then
      mutation_failed=true
      transitions:transition("external")
      invalidate("Synchronous mutation failed")
    end
    if mutation_depth==0 then
      mutation_token=nil
      inventory_dirty=true
      reconciliation_pending=true
      if ok and not mutation_failed then
        local neutral,reason=pcall(function()
          local ownership=require("renoise.phrase_ownership")
          assert(type(writer.is_temporary)=="function","Temporary phrase registry is unavailable")
          for _,instrument in ipairs(current_song.instruments) do
            for _,phrase in ipairs(instrument.phrases) do
              local temporary=writer.is_temporary(current_song,instrument,phrase)
              assert(type(temporary)=="boolean","Invalid temporary registry result")
              assert(not temporary or not ownership.id(phrase),"Writer temporary retains an ownership identity")
            end
          end
          local groups,inventory_error=ownership.inventory(current_song)
          assert(groups,inventory_error)
          for id,holders in pairs(groups) do
            if #holders>1 then
              local before=mutation_group_membership and mutation_group_membership[id]
              assert(before,"Mutation introduced a duplicate ownership identity")
              for _,holder in ipairs(holders) do
                local existed=false
                for _,member in ipairs(before) do
                  if rawequal(member.instrument,holder.instrument) and
                      rawequal(member.phrase,holder.phrase) then existed=true;break end
                end
                assert(existed,"Mutation added a holder to a duplicate ownership identity")
              end
            end
          end
          native_instrument=current_song.selected_instrument
          native_phrase=current_song.selected_phrase
        end)
        if not neutral then
          mutation_failed=true
          transitions:transition("external")
          invalidate("Temporary neutrality could not be verified")
          ok,failure=false,reason
        end
      end
      if mutation_failed then
        integrity:record(mutation_evidence)
        transitions:transition("blocker")
      end
      mutation_evidence=nil
      mutation_group_membership=nil
    end
    if not ok then error(failure,0) end
    return (unpack or table.unpack)(values,1,values.n)
  end

  function context:reconcile()
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    reconciliation_pending=false
    inventory_dirty=false
    local ok,instrument,phrase=pcall(function() return current_song.selected_instrument,current_song.selected_phrase end)
    if not ok then return nil,"Cannot inspect native selection" end
    if not rawequal(instrument,native_instrument) or not rawequal(phrase,native_phrase) then
      native_instrument,native_phrase=instrument,phrase
      return self:transition("native_target",{instrument=instrument,phrase=phrase,kind="existing"})
    end
    return self:refresh_inventory()
  end

  function context:close_dialog()
    if not opened then return false end
    opened = false
    pending_trigger=nil
    transitions:transition("close")
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
    pending_trigger=nil
    invalidate("Document released")
    if detach then
      local ok, failure = pcall(detach, song)
      if not ok then diagnose(nil, "lifetime.detach_failed", failure) end
    end
    local warning
    if #editor_recovery>0 or (editor and not editor.valid) then
      warning="Invalid ACID editor buffers are session-only and were released"
    end
    if drafts and type(drafts.release) == "function" then
      local ok, _, message = pcall(drafts.release, song)
      if ok then warning = message or warning
      else
        warning = "Session-only ACID draft release failed"
        diagnose(nil, "lifetime.drafts_failed", warning)
      end
    end
    current_song = nil
    transitions:release()
    editor,observed_target=nil,nil
    editor_dirty=false
    editor_target=nil
    editor_recovery={}
    native_instrument,native_phrase=nil,nil
    mutation_depth,mutation_token=0,nil
    mutation_evidence=nil
    inventory_dirty,reconciliation_pending,mutation_failed=false,false,false
    pending_trigger=nil
    last_result,last_commit,last_commit_label=nil,nil,nil
    if inventory then inventory:release() end
    inventory = nil
    if integrity then integrity:release() end
    integrity = nil
    if requests then requests:release() end
    requests = nil
    for record in pairs(records) do
      record.request = nil
      record.gui_delivery = nil
      record.finish = nil
      record.released = true
    end
    records = setmetatable({}, {__mode = "k"})
    -- Released delivery is detached; native occupancy remains writer-owned.
    active = nil
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
    local selection_ok,selected_instrument,selected_phrase=pcall(function() return song.selected_instrument,song.selected_phrase end)
    if selection_ok then native_instrument,native_phrase=selected_instrument,selected_phrase end
    inventory = require("runtime.inventory").new(song,writer)
    integrity = require("runtime.integrity").new(song,drafts,function()
      local state,reason=inspect_writer(writer)
      if not state then return false,reason end
      if state.status~="idle" then return false,"The writer slot is occupied" end
      if dispatching or (active and not active.settled) then return false,"An accepted operation has not settled" end
      if mutation_depth>0 then return false,"Synchronous mutation is active" end
      return true
    end)
    requests=require("runtime.requests").new({
      current=function(include_target)
        local revisions=transitions:revision_state()
        return {song=current_song,epoch=epoch,session=session,open=opened,
          target_revision=revisions.target_revision,edit_revision=revisions.edit_revision,
          operation_serial=revisions.operation_serial,
          editor=include_target and context:editor_state() or nil,
          target=include_target and context:target_state() or nil}
      end,
      occupancy=function(token) return context:occupancy_state(token) end,
      revoke=function(token,reason) return context:revoke(token,reason) end,
      cleanup_allowed=function(token)
        return active~=nil and not active.settled and not active.rejected and not active.released
          and active.epoch==epoch and rawequal(active.token,token)
      end,
      blocked=function()
        if mutation_depth>0 or mutation_failed then return true,"Synchronous mutation is active or requires recovery" end
        local state=context:integrity_state()
        return state.blocked,state.reason
      end,
      drafts=drafts,
      draft_options=function() return context:draft_options() end,
      mutate=function(token,action) return context:mutate(token,action) end,
      record_blocker=function(token,evidence) return context:record_blocker(token,evidence) end,
    })
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

  function context:occupancy_state(token)
    local state,reason=inspect_writer(writer)
    if not state then return {status="unavailable",available=false,reason=reason} end
    local own=state.status=="busy" and token~=nil and rawequal(state.token,token)
    return {status=state.status,own=own,available=state.status=="idle" or own,
      reason=state.status~="idle" and not own and "The writer slot is occupied" or nil}
  end

  function context:validate_checkpoint(request)
    if not requests then return false,"No current request runtime is attached" end
    return requests:validate_checkpoint(request)
  end

  function context:record_blocker(token,evidence)
    local record=active
    if not integrity or not record or record.settled or record.rejected or
        record.released or record.epoch~=epoch or not rawequal(record.token,token) then
      return false,"Recovery evidence does not belong to the current operation"
    end
    local recorded,reason=integrity:record(evidence)
    if recorded then
      record.blocker_pending=true
      transitions:transition("blocker")
      invalidate("Song integrity requires revalidation")
    end
    return recorded,reason
  end

  function context:integrity_state()
    if not integrity then return {blocked=false,serial=0,recovery={}} end
    return integrity:state()
  end

  function context:revalidation_status()
    if not integrity then return {verified=false,blocked=false,reason="No current document is attached"} end
    return integrity:status()
  end

  function context:revalidate(proof)
    if not integrity then return false,"No current document is attached" end
    local cleared,reason=integrity:clear(proof)
    if cleared then mutation_failed=false end
    return cleared,reason
  end

  function context:bind_new(instrument)
    if mutation_depth>0 or mutation_failed then return {kind="unavailable",reason="Synchronous mutation is active or requires recovery"} end
    if not inventory then return {kind="unavailable",reason="No current document is attached"} end
    return self:transition("target",{instrument=instrument,kind="new"})
  end

  function context:bind_phrase(instrument,phrase)
    if mutation_depth>0 or mutation_failed then return {kind="unavailable",reason="Synchronous mutation is active or requires recovery"} end
    if not inventory then return {kind="unavailable",reason="No current document is attached"} end
    return self:transition("target",{instrument=instrument,phrase=phrase,kind="existing"})
  end

  function context:target_state()
    if mutation_depth>0 or mutation_failed then return {kind="unavailable",reason="Synchronous mutation is active or requires recovery"} end
    if not inventory then return {kind="unavailable",reason="No current document is attached"} end
    return inventory:target_state()
  end

  function context:refresh_inventory() return self:transition("refresh") end

  function context:instrument_choices()
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    if not inventory then return nil,"No current document is attached" end
    return inventory:instrument_choices()
  end

  function context:phrase_choices(instrument)
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    if not inventory then return nil,"No current document is attached" end
    return inventory:phrase_choices(instrument)
  end

  function context:draft_options()
    return {validate=function(song,instrument,phrase)
      if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
      if not inventory then return nil,"No current document is attached" end
      return inventory:draft_options().validate(song,instrument,phrase)
    end}
  end

  function context:state()
    return context_state()
  end

  return context
end

return M
