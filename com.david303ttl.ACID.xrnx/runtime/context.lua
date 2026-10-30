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
--     request.mutate(token, action) -> all action result values
--       Same operation token only. Depth-counted and non-yielding; unwinds on
--       success or exception, revokes authorization on exception, and
--       rethrows the original failure. No user callback, idle wait, or render
--       wait may run inside it.
--       Requires writer.is_temporary and captures exact pre-scope recovery
--       evidence. A failed outer scope records that evidence for explicit
--       revalidation after settlement and native restoration.
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
  local mutation_depth, mutation_token = 0, nil
  local mutation_evidence=nil
  local inventory_dirty, reconciliation_pending, mutation_failed = false, false, false
  local native_instrument, native_phrase = nil, nil
  local transitions=require("runtime.transitions").new()
  local editor=nil
  local editor_target=nil
  local editor_recovery={}
  local observed_target=nil
  local ownership=require("renoise.phrase_ownership")

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
      token = record and record.token or nil,
      authorization = record ~= nil and record.current == true and record.settled ~= true,
      blocked = blocked == true or integrity_state.blocked,
      blocked_reason = integrity_state.reason or blocked_reason,
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
    if mutation_depth>0 or mutation_failed then
      return false,"Synchronous mutation is active or requires recovery"
    end
    if releasing or (lifecycle and (current_song == nil or not opened)) then
      return false, "No current document dialog is open"
    end
    if editor then
      if trigger~="manual" and trigger~="live" then return false,"Invalid generation trigger" end
      if trigger=="live" and not transitions:revision_state().armed then return false,"Live Edit is not armed" end
      self:transition("request",{trigger=trigger})
      if not editor.valid then return false,editor.reason or "Invalid editor source or settings" end
      local destination=self:target_state()
      if not editor_target or not rawequal(destination.instrument,editor_target.instrument) or
          not rawequal(destination.phrase,editor_target.phrase) or destination.kind~=editor_target.kind then
        return false,"Editor source has not been loaded for this target"
      end
      local eligible,reason=self:musical_eligibility(active and active.token)
      if not eligible then return false,reason end
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
        if type(result)=="table" and result.kind=="success" and result.verified==true then
          inventory_dirty=true;reconciliation_pending=true
        end
        if rawequal(active, record) then active = nil end
        return true
      end
      record.settled = true
      record.current = false
      record.request = nil
      if rawequal(active, record) then active = nil end
      if record.revisions then
        local success=type(result)=="table" and result.kind=="success" and result.verified==true
        local effects=transitions:transition("completion",{success=success,
          operation_serial=record.revisions.operation_serial,target_revision=record.revisions.target_revision,
          edit_revision=record.revisions.edit_revision})
        if effects.reconcile then inventory_dirty=true;reconciliation_pending=true end
      end
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

  local function preserve_editor()
    if not editor or not inventory or not current_song then return end
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

  function context:transition(kind,values)
    values=values or {}
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    if not inventory then return nil,"No current document is attached" end
    if kind=="target" or kind=="native_target" then
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
      return target,effects
    elseif kind=="refresh" then
      local target=inventory:target_state()
      local changed=observed_target~=nil and not ownership.compare(observed_target,semantic(target))
      local effects=transitions:transition(kind,{semantic_changed=changed})
      apply_effects(effects,"Target eligibility changed")
      observed_target=semantic(target)
      return target,effects
    elseif kind=="edit" or kind=="programmatic" or kind=="reset" or kind=="recovery" then
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
      local destination=inventory:target_state()
      editor_target={instrument=destination.instrument,phrase=destination.phrase,kind=destination.kind}
      if changed then preserve_editor() end
      if effects.live_intent then effects.accepted,effects.reason=self:request_generation("live") end
      return self:editor_state(),effects
    end
    local effects=transitions:transition(kind,values)
    apply_effects(effects,"Runtime "..kind)
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
      apply_effects(transitions:transition("external"),reason or "External native change")
    end
  end

  function context:mutate(token,action)
    if type(action)~="function" or not active or not active.current or
        not rawequal(active.token,token) or not current_song or
        (mutation_depth>0 and not rawequal(mutation_token,token)) then
      error("Mutation requires the current operation token",0)
    end
    if mutation_depth==0 then
      if type(writer.is_temporary)~="function" then
        error("Mutation requires a temporary phrase registry",0)
      end
      local evidence,reason=integrity:capture_mutation()
      if not evidence then error(reason or "Cannot capture mutation recovery evidence",0) end
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
          for _,holders in pairs(groups) do
            assert(#holders==1,"Mutation left a duplicate ownership identity")
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
    editor_target=nil
    editor_recovery={}
    native_instrument,native_phrase=nil,nil
    mutation_depth,mutation_token=0,nil
    mutation_evidence=nil
    inventory_dirty,reconciliation_pending,mutation_failed=false,false,false
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
