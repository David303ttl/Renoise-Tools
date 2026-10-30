dofile("tests/bootstrap.lua")("acid")
local context = require("runtime.context")

local function fake_writer()
  local writer = {status = "idle", token = nil, fail = false, malformed = false,
    inspections = 0}
  function writer:state()
    self.inspections = self.inspections + 1
    if self.fail then error("writer inspection failed") end
    if self.malformed then return {status = "idle"} end
    return self.status, self.token
  end
  return writer
end

local function new_context(options)
  options = options or {}
  local log = {captures = 0, sink_calls = 0, tokens = {}}
  local writer = options.writer or fake_writer()
  local base_capture = options.capture
  local base_sink = options.sink
  local capture = function(trigger, token)
    log.captures = log.captures + 1
    log.token = token
    log.tokens[#log.tokens + 1] = token
    if base_capture then return base_capture(trigger, token) end
    return {kind = "fake", trigger = trigger, token = token}
  end
  local sink = function(request, done)
    log.sink_calls = log.sink_calls + 1
    log.request = request
    log.done = done
    if base_sink then return base_sink(request, done) end
    return true
  end
  local ctx = context.new{writer = writer, capture = capture, sink = sink,
    issue_token = options.issue_token}
  return ctx, writer, log
end

-- Admission rejects an occupied writer and never captures or dispatches.
do
  local writer = fake_writer()
  writer.status, writer.token = "busy", {}
  local ctx, _, log = new_context{writer = writer,
    sink = function() error("sink must not run") end}
  local accepted, reason = ctx:request_generation("trigger")
  assert(accepted == false and reason == "The writer slot is occupied")
  assert(log.captures == 0 and log.sink_calls == 0)
  assert(ctx:state().blocked == false and ctx:state().diagnostic_count == 0)
end

-- Fake tokens and request records can cross the same boundary for isolated
-- conformance checks. Token issuance receives no delivery record.
do
  local fake = {is_current = function() return true end}
  local ctx, _, log = new_context{issue_token = function(record)
    assert(record == nil, "issue_token must not receive the delivery record")
    return fake
  end}
  assert(ctx:request_generation("trigger") == true)
  assert(rawequal(log.token, fake))
  assert(rawequal(log.request.token, fake))
  assert(log.done({}) == true)
end

-- The context surface is a narrow method set; private mutable state stays in
-- closures and cannot be replaced or cleared from outside.
do
  local ctx = new_context{}
  local allowed = {request_generation = true, revoke = true, state = true,
    attach_document = true, open_dialog = true, close_dialog = true,
    release_document = true, lifetime_state = true, bind_new = true, bind_phrase = true,
    restore_editor_target = true,
    target_state = true, target_projection = true, refresh_inventory = true, instrument_choices = true,
    phrase_choices = true, draft_options = true, mutate = true, mark_dirty = true,
    matches_mutation_inventory = true,
    reconcile = true, mutation_state = true, occupancy_state = true,
    record_blocker = true, integrity_state = true, revalidation_status = true,
    revalidate = true, transition = true, revision_state = true, editor_state = true,
    musical_eligibility = true, independence_eligibility = true, independence_projection = true, editor_recovery = true,
    validate_checkpoint = true, flush_pending = true, generation_state = true,
    make_independent = true, recovery_entries = true,
    copy_recovery_to_new = true, discard_recovery = true, is_temporary = true}
  for key, value in pairs(ctx) do
    assert(allowed[key], "context exposes private field " .. tostring(key))
    assert(type(value) == "function")
  end
  assert(ctx.writer == nil and ctx.capture == nil and ctx.sink == nil)
  assert(ctx:is_temporary({}, {}) == false)
  assert(ctx.issue_token == nil and ctx.active == nil and ctx.dispatching == nil)
  assert(ctx.blocked == nil and ctx.blocked_reason == nil)
  assert(ctx.diagnostic_count == nil and ctx.last_diagnostic == nil)
end

-- External field assignment cannot replace the fixed writer/capture/sink or
-- issue a foreign token.
do
  local writer = fake_writer()
  local capture_calls, sink_calls = 0, 0
  local ctx = new_context{writer = writer,
    capture = function(_, token)
      capture_calls = capture_calls + 1
      return {kind = "fake", token = token}
    end,
    sink = function(_, done) sink_calls = sink_calls + 1; done({}); return true end}
  local replaced_capture, replaced_sink, replaced_issue = 0, 0, 0
  ctx.writer = {state = function() return "busy", {} end}
  ctx.capture = function()
    replaced_capture = replaced_capture + 1
    return {kind = "replacement"}
  end
  ctx.sink = function() replaced_sink = replaced_sink + 1; return true end
  ctx.issue_token = function() replaced_issue = replaced_issue + 1; return {} end
  assert(ctx:request_generation("trigger") == true)
  assert(capture_calls == 1 and sink_calls == 1)
  assert(replaced_capture == 0 and replaced_sink == 0 and replaced_issue == 0)
end

-- External assignment cannot retire the active record or clear a safety block.
do
  local ctx, _, log = new_context{}
  assert(ctx:request_generation("first") == true)
  ctx.active, ctx.dispatching, ctx.blocked = nil, false, false
  local accepted, reason = ctx:request_generation("second")
  assert(accepted == false and reason == "A generation is already in progress")
  assert(log.captures == 1)
  assert(log.done({}) == true)
end

do
  local writer = fake_writer()
  local ctx, _, log = new_context{writer = writer, sink = function(request, done)
    done({})
    writer.status, writer.token = "busy", request.token
    return false, "late rejection"
  end}
  assert(ctx:request_generation("first") == false)
  assert(ctx:state().blocked)
  local sink_calls = log.sink_calls
  ctx.writer = {state = function() return "idle", nil end}
  ctx.active, ctx.dispatching, ctx.blocked = nil, false, false
  ctx.blocked_reason, ctx.diagnostic_count = nil, 0
  local accepted, reason = ctx:request_generation("second")
  assert(accepted == false and type(reason) == "string")
  assert(log.sink_calls == sink_calls)
  assert(ctx:state().blocked and ctx:state().diagnostic_count == 1)
end

-- State projections are detached copies with no request or host references.
do
  local ctx, _, log = new_context{}
  assert(ctx:request_generation("trigger") == true)
  local first = ctx:state()
  local second = ctx:state()
  assert(first ~= second and first.last_diagnostic == nil)
  first.status, first.blocked, first.authorization = "blocked", true, false
  first.token = nil
  local current = ctx:state()
  assert(current.status == "pending" and current.blocked == false)
  assert(current.authorization == true and current.token ~= nil)
  assert(current.request == nil and current.writer == nil)
  assert(log.done({}) == true)
  assert(log.done({}) == false)
  local diagnostic = ctx:state()
  assert(diagnostic.last_diagnostic.code == "delivery.duplicate_completion")
  diagnostic.last_diagnostic.code = "tampered"
  diagnostic.last_diagnostic.message = "tampered"
  diagnostic.blocked = false
  local after = ctx:state()
  assert(after.last_diagnostic.code == "delivery.duplicate_completion")
  assert(after.last_diagnostic.message ~= "tampered")
  assert(after.blocked == true)
end

-- Token issuance failures reject before capture or dispatch.
do
  for _, value in ipairs({false, true}) do
    local ctx, _, log = new_context{issue_token = function()
      if value == true then return nil end
      return false
    end}
    local accepted, reason = ctx:request_generation("trigger")
    assert(accepted == false and reason == "Cannot issue a generation token")
    assert(log.captures == 0 and log.sink_calls == 0)
  end
end

-- Capture rejection calls the sink zero times and revokes its token.
do
  local ctx, _, log = new_context{
    capture = function() return nil, "missing source" end,
    sink = function() error("sink must not run") end}
  local accepted, reason = ctx:request_generation("trigger")
  assert(accepted == false and reason == "missing source")
  assert(log.captures == 1 and log.sink_calls == 0)
  assert(log.token:is_current() == false)
  assert(ctx:state().status == "idle" and ctx:state().diagnostic_count == 0)
end

-- A capture that reenters cannot start another generation before the outer
-- request has installed its own record.
do
  local ctx, _, log
  local inner_accepted, inner_reason
  local sink_calls = 0
  local capture = function(trigger, token)
    if trigger == "outer" then
      inner_accepted, inner_reason = ctx:request_generation("inner")
    end
    return {kind = "fake", token = token}
  end
  local sink = function(_, done)
    sink_calls = sink_calls + 1
    log.done = done
    return true
  end
  ctx, _, log = new_context{capture = capture, sink = sink}
  assert(ctx:request_generation("outer") == true)
  assert(inner_accepted == false)
  assert(inner_reason == "A generation request is already dispatching")
  assert(log.captures == 1 and sink_calls == 1)
  assert(log.done({}) == true)
end

-- A throwing capture clears the dispatch guard and leaves no authorization.
do
  local calls = 0
  local ctx, _, log = new_context{capture = function(_, token)
    calls = calls + 1
    if calls == 1 then error("capture failed") end
    return {kind = "fake", token = token}
  end}
  local accepted, reason = ctx:request_generation("first")
  assert(accepted == false and tostring(reason):find("capture failed", 1, true))
  assert(log.captures == 1 and log.sink_calls == 0)
  assert(log.tokens[1]:is_current() == false)
  assert(ctx:request_generation("second") == true)
  assert(log.captures == 2 and log.sink_calls == 1)
  assert(log.tokens[2]:is_current() == true)
  assert(log.done({}) == true)
end

-- Capture cannot substitute a token of its own.
do
  local issued
  local ctx = new_context{
    capture = function(_, token) issued = token; return {token = {}} end,
    sink = function() error("sink must not run") end}
  local accepted, reason = ctx:request_generation("trigger")
  assert(accepted == false and reason == "Generation capture returned a foreign token")
  assert(issued:is_current() == false)
end

-- Capture must return the issued token; a request proxy that errors on token
-- inspection is rejected without wedging later dispatch.
do
  local calls = 0
  local ctx, _, log = new_context{capture = function(_, token)
    calls = calls + 1
    if calls == 1 then
      return setmetatable({}, {__index = function() error("proxy read") end})
    end
    return {kind = "fake", token = token}
  end}
  local accepted, reason = ctx:request_generation("first")
  assert(accepted == false and tostring(reason):find("captured request token", 1, true))
  assert(ctx:state().status == "idle")
  assert(log.tokens[1]:is_current() == false)
  assert(ctx:request_generation("second") == true)
  assert(log.sink_calls == 1)
  assert(log.done({}) == true)
end

-- A capture that omits the issued token is rejected and does not wedge.
do
  local ctx, _, log = new_context{capture = function(trigger, token)
    if trigger == "missing" then return {kind = "fake"} end
    return {kind = "fake", token = token}
  end}
  local accepted, reason = ctx:request_generation("missing")
  assert(accepted == false and reason == "Generation capture did not return the issued token")
  assert(log.sink_calls == 0)
  assert(ctx:request_generation("retry") == true)
  assert(log.sink_calls == 1)
  assert(log.done({}) == true)
end

-- The context does not write captured request values: a request that rejects
-- new fields is accepted when it already carries the issued token.
do
  local ctx = new_context{capture = function(_, token)
    local request = {kind = "fake", token = token}
    return setmetatable(request, {__newindex = function() error("frozen request") end})
  end, sink = function(_, done) done({}); return true end}
  assert(ctx:request_generation("trigger") == true)
end

-- Terminal and rejected retirement release the captured request table.
local function collect_request(sink)
  local weak = setmetatable({}, {__mode = "v"})
  local ctx = context.new{writer = fake_writer(), capture = function(_, token)
    local request = {kind = "fake", token = token}
    weak.value = request
    return request
  end, sink = sink}
  local accepted = ctx:request_generation("trigger")
  assert(accepted == false or ctx:state().status == "idle")
  for _ = 1, 3 do collectgarbage("collect") end
  return weak.value
end
do
  assert(collect_request(function(_, done) done({}); return true end) == nil,
    "terminal delivery retained the captured request")
  assert(collect_request(function() return false, "rejected" end) == nil,
    "rejected retirement retained the captured request")
end

-- Explicit rejection settles without a completion and stays dispatchable.
do
  local ctx, _, log = new_context{sink = function()
    return false, "target is not eligible"
  end}
  local accepted, reason = ctx:request_generation("trigger")
  assert(accepted == false and reason == "target is not eligible")
  assert(log.captures == 1 and log.sink_calls == 1)
  assert(log.token:is_current() == false)
  assert(ctx:state().status == "idle" and ctx:state().diagnostic_count == 0)
end

-- A structured rejection reason is normalized to diagnostic text.
do
  local ctx = new_context{sink = function()
    return false, {message = "structured rejection"}
  end}
  local accepted, reason = ctx:request_generation("trigger")
  assert(accepted == false and reason == "structured rejection")
end

-- A literal rejection while the writer reports busy is a protocol violation,
-- not a clean rejection, even without a completion.
do
  local cases = {
    {name = "owned token", code = "delivery.reject_with_writer_ownership",
      setup = function(writer, token) writer.status, writer.token = "busy", token end},
    {name = "different token", code = "delivery.reject_with_writer_occupancy",
      setup = function(writer) writer.status, writer.token = "busy", {} end},
    {name = "legacy nil token", code = "delivery.reject_with_writer_occupancy",
      setup = function(writer) writer.status, writer.token = "busy", nil end},
    {name = "unreadable state", code = "delivery.reject_with_unverified_occupancy",
      setup = function(writer) writer.fail = true end},
  }
  for _, case in ipairs(cases) do
    local writer = fake_writer()
    local first = true
    local ctx, _, log = new_context{writer = writer, sink = function(request)
      if first then
        first = false
        case.setup(writer, request.token)
        return false, "rejected"
      end
      return false, "clean rejection"
    end}
    local accepted, reason = ctx:request_generation("first")
    assert(accepted == false and type(reason) == "string", case.name)
    assert(ctx:state().blocked, case.name .. " did not block")
    assert(ctx:state().diagnostic_count == 1, case.name)
    assert(ctx:state().last_diagnostic.code == case.code,
      case.name .. ": " .. tostring(ctx:state().last_diagnostic.code))
    assert(log.token:is_current() == false)
    assert(ctx:request_generation("blocked") == false)
    assert(log.sink_calls == 1)
    writer.fail, writer.status, writer.token = false, "idle", nil
    local accepted_again, reason_again = ctx:request_generation("second")
    assert(accepted_again == false and reason_again == "clean rejection", case.name)
    assert(ctx:state().blocked == false and ctx:state().diagnostic_count == 1, case.name)
  end
end

-- The delivery record is installed before the sink and synchronous completion
-- settles exactly once.
do
  local ctx, _, log
  ctx, _, log = new_context{sink = function(request, done)
    log.inside = ctx:state()
    log.request_token = request.token
    log.first = done({kind = "complete", status = "committed"})
    return true
  end}
  assert(ctx:request_generation("trigger") == true)
  assert(log.inside.status == "pending")
  assert(rawequal(log.inside.token, log.request_token))
  assert(log.first == true and log.request_token:is_current() == false)
  assert(ctx:state().status == "idle" and ctx:state().diagnostic_count == 0)
end

-- Asynchronous acceptance keeps the token current until the single completion.
do
  local ctx, _, log = new_context{}
  assert(ctx:request_generation("trigger") == true)
  assert(ctx:state().status == "pending" and ctx:state().token ~= nil)
  assert(log.token:is_current() == true)
  local impostor = setmetatable({}, {__eq = function() return true end})
  assert(log.token.is_current(impostor) == false, "token identity must be raw")
  assert(log.done({kind = "complete", status = "committed"}) == true)
  assert(ctx:state().status == "idle" and log.token:is_current() == false)
end

-- Revocation invalidates authorization by raw token identity but retains the
-- pending record and writer occupancy; a later completion retires it.
do
  local ctx, _, log = new_context{}
  assert(ctx:request_generation("first") == true)
  local token = log.token
  local pending = ctx:state()
  assert(pending.status == "pending" and pending.authorization == true)
  assert(token:is_current() == true)
  local equal = setmetatable({}, {__eq = function() return true end})
  assert(ctx:revoke(equal, "wrong token") == false)
  assert(token:is_current() == true)
  assert(ctx:revoke(token, "external revoke") == true)
  assert(token:is_current() == false)
  local revoked = ctx:state()
  assert(revoked.status == "pending" and revoked.authorization == false)
  assert(rawequal(revoked.token, token))
  local captures = log.captures
  local accepted, reason = ctx:request_generation("second")
  assert(accepted == false and reason == "A generation is already in progress")
  assert(log.captures == captures and log.sink_calls == 1)
  assert(ctx:revoke(token, "again") == false)
  assert(log.done({}) == true)
  assert(ctx:state().status == "idle" and token:is_current() == false)
  assert(ctx:state().diagnostic_count == 0)
  assert(ctx:revoke(token, "late") == false)
  assert(ctx:request_generation("third") == true)
  assert(log.done({}) == true)
end

-- An accepted asynchronous request owns admission until its completion.
do
  local ctx, _, log = new_context{}
  assert(ctx:request_generation("first") == true)
  local captures = log.captures
  local accepted, reason = ctx:request_generation("second")
  assert(accepted == false and reason == "A generation is already in progress")
  assert(log.captures == captures and log.sink_calls == 1)
  assert(log.done({}) == true)
end

-- Duplicate completion is ignored, diagnosed once, and blocks until a fresh
-- safe inspection on a later request.
do
  local ctx, writer, log = new_context{}
  assert(ctx:request_generation("first") == true)
  assert(log.done({}) == true)
  assert(log.done({}) == false)
  local blocked = ctx:state()
  assert(blocked.blocked and blocked.status == "blocked")
  assert(blocked.diagnostic_count == 1)
  assert(blocked.last_diagnostic.code == "delivery.duplicate_completion")
  assert(log.done({}) == false and ctx:state().diagnostic_count == 1)
  assert(writer.status == "idle")
  assert(ctx:request_generation("second") == true)
  assert(ctx:state().diagnostic_count == 1)
end

-- Completion followed by rejection is a protocol violation: one delivery,
-- one diagnosis, and no dispatch while the writer still owns the token.
do
  local writer = fake_writer()
  local violate = true
  local ctx, _, log = new_context{writer = writer, sink = function(request, done)
    if violate then
      violate = false
      done({kind = "complete", status = "committed"})
      writer.status, writer.token = "busy", request.token
      return false, "late rejection"
    end
    done({kind = "complete", status = "committed"})
    return true
  end}
  local accepted, reason = ctx:request_generation("first")
  assert(accepted == false and type(reason) == "string")
  assert(log.sink_calls == 1)
  local blocked = ctx:state()
  assert(blocked.blocked and blocked.status == "blocked")
  assert(blocked.diagnostic_count == 1)
  assert(blocked.last_diagnostic.code == "delivery.complete_then_reject")
  assert(ctx:request_generation("blocked") == false)
  assert(log.captures == 1 and log.sink_calls == 1)
  assert(ctx:state().diagnostic_count == 1)
  writer.status, writer.token = "idle", nil
  assert(ctx:request_generation("safe") == true)
  assert(log.captures == 2 and log.sink_calls == 2)
  assert(ctx:state().blocked == false and ctx:state().diagnostic_count == 1)
end

-- A completion delivered after an explicit rejection cannot settle the record
-- and blocks later dispatch.
do
  local ctx, _, log = new_context{sink = function()
    return false, "rejected"
  end}
  assert(ctx:request_generation("trigger") == false)
  assert(log.done({}) == false)
  local blocked = ctx:state()
  assert(blocked.blocked and blocked.diagnostic_count == 1)
  assert(blocked.last_diagnostic.code == "delivery.completion_after_rejection")
end

-- A stale rejected callback cannot settle a newer accepted request.
do
  local old_done, new_done
  local call = 0
  local ctx, _, log = new_context{sink = function(_, done)
    call = call + 1
    if call == 1 then
      old_done = done
      return false, "old request rejected"
    end
    new_done = done
    return true
  end}
  assert(ctx:request_generation("old") == false)
  assert(ctx:request_generation("new") == true)
  local newer_token = log.tokens[2]
  assert(newer_token:is_current() == true)
  assert(old_done({}) == false)
  assert(newer_token:is_current() == true, "old completion settled newer work")
  assert(ctx:state().blocked == true)
  assert(new_done({}) == true)
  assert(newer_token:is_current() == false)
end

-- A reentrant request during callback delivery cannot start another generation
-- before the sink returns, even after the callback has settled the record.
do
  local ctx
  local reentrant, reentrant_reason
  local sink = function(_, done)
    done({kind = "complete", status = "committed"})
    reentrant, reentrant_reason = ctx:request_generation("inner")
    return true
  end
  local _, _, log
  ctx, _, log = new_context{sink = sink}
  assert(ctx:request_generation("outer") == true)
  assert(reentrant == false)
  assert(reentrant_reason == "A generation request is already dispatching")
  assert(log.captures == 1 and log.sink_calls == 1)
end

-- A thrown sink with an idle writer is confirmed as a pre-acceptance failure.
do
  local ctx, _, log = new_context{sink = function()
    error("setup failed")
  end}
  local accepted, reason = ctx:request_generation("trigger")
  assert(accepted == false and tostring(reason):find("setup failed", 1, true))
  assert(log.token:is_current() == false)
  local state = ctx:state()
  assert(state.blocked == false and state.diagnostic_count == 1)
  assert(state.last_diagnostic.code == "delivery.sink_failed_before_acceptance")
end

-- A completion retained by a sink that threw before acceptance cannot settle
-- the rejected record later.
do
  local ctx, _, log
  local sink = function(_, done)
    log.held = done
    error("setup failed")
  end
  ctx, _, log = new_context{sink = sink}
  assert(ctx:request_generation("trigger") == false)
  assert(log.held({}) == false)
  local state = ctx:state()
  assert(state.blocked and state.diagnostic_count == 2)
  assert(state.last_diagnostic.code == "delivery.completion_after_rejection")
end

-- A thrown sink after the writer accepted the exact token returns
-- accepted-pending, revokes commit authorization, and keeps the record until
-- its matching done retires it without a result delivery.
do
  local writer = fake_writer()
  local call = 0
  local ctx, _, log = new_context{writer = writer, sink = function(request, done)
    call = call + 1
    if call == 1 then
      writer.status, writer.token = "busy", request.token
      error("started then failed")
    end
    done({})
    return true
  end}
  assert(ctx:request_generation("trigger") == true)
  local state = ctx:state()
  assert(state.status == "blocked" and state.blocked)
  assert(state.authorization == false and log.token:is_current() == false)
  assert(state.token ~= nil and state.diagnostic_count == 1)
  assert(state.last_diagnostic.code == "delivery.sink_failed_after_acceptance")
  writer.status, writer.token = "idle", nil
  local sink_calls = log.sink_calls
  assert(ctx:request_generation("blocked") == false)
  assert(log.sink_calls == sink_calls)
  assert(ctx:state().status == "blocked" and ctx:state().token ~= nil)
  local diagnostics = ctx:state().diagnostic_count
  assert(log.done({}) == true)
  local retired = ctx:state()
  assert(retired.token == nil and retired.status == "blocked")
  assert(retired.diagnostic_count == diagnostics)
  assert(ctx:request_generation("recovered") == true)
  assert(log.sink_calls == 2)
end

-- Occupied with a different or legacy-nil token is not proof of our
-- acceptance, even if a token claims equality, so dispatch fails closed.
do
  local cases = {
    {name = "different", token = setmetatable({}, {__eq = function() return true end})},
    {name = "legacy nil", token = nil},
  }
  for _, case in ipairs(cases) do
    local writer = fake_writer()
    local call = 0
    local ctx, _, log = new_context{writer = writer, sink = function()
      call = call + 1
      if call == 1 then
        writer.status, writer.token = "busy", case.token
        error("uncertain start")
      end
      return true
    end}
    local accepted, reason = ctx:request_generation("first")
    assert(accepted == false and type(reason) == "string")
    assert(ctx:state().blocked, case.name .. " occupancy did not block")
    assert(ctx:state().diagnostic_count == 1)
    assert(ctx:state().last_diagnostic.code == "delivery.start_unverified")
    assert(log.token:is_current() == false)
    assert(ctx:request_generation("blocked") == false)
    assert(log.sink_calls == 1)
    writer.status, writer.token = "idle", nil
    assert(ctx:request_generation("safe") == true)
  end
end

-- An idle status with a non-nil token is contradictory occupancy evidence.
do
  local writer = fake_writer()
  writer.status, writer.token = "idle", {}
  local ctx, _, log = new_context{writer = writer, sink = function(_, done)
    done({})
    return true
  end}
  assert(ctx:request_generation("trigger") == false)
  assert(log.sink_calls == 0)
  assert(ctx:state().blocked == true)
  assert(ctx:state().last_diagnostic.code == "admission.state_unavailable")
  writer.token = nil
  assert(ctx:request_generation("verified") == true)
  assert(log.sink_calls == 1)
end
do
  local writer = fake_writer()
  local ctx = new_context{writer = writer, sink = function()
    writer.status, writer.token = "idle", {}
    error("pre-acceptance failure")
  end}
  local ok, accepted = pcall(ctx.request_generation, ctx, "trigger")
  assert(ok and accepted == false)
  assert(ctx:state().blocked == true and ctx:state().diagnostic_count == 1)
  assert(ctx:state().last_diagnostic.code == "delivery.start_unverified")
end

-- A hostile thrown reason cannot escape diagnostics or wedge dispatch.
do
  local call = 0
  local hostile = setmetatable({}, {
    __index = function() error("hostile index") end,
    __tostring = function() error("hostile tostring") end,
  })
  local ctx, _, log = new_context{sink = function(_, done)
    call = call + 1
    if call == 1 then error(hostile) end
    done({})
    return true
  end}
  local ok, accepted, reason = pcall(ctx.request_generation, ctx, "first")
  assert(ok and accepted == false and type(reason) == "string")
  local state = ctx:state()
  assert(state.blocked == false and state.diagnostic_count == 1)
  assert(type(state.last_diagnostic.message) == "string")
  assert(state.last_diagnostic.code == "delivery.sink_failed_before_acceptance")
  assert(ctx:request_generation("recovered") == true)
  assert(log.sink_calls == 2)
end

-- An unreadable state inspector after a throw fails closed and stays blocked
-- until a later inspection succeeds.
do
  local writer = fake_writer()
  local call = 0
  local ctx, _, log = new_context{writer = writer, sink = function()
    call = call + 1
    if call == 1 then
      writer.fail = true
      error("uncertain start")
    end
    return true
  end}
  local accepted, reason = ctx:request_generation("first")
  assert(accepted == false and type(reason) == "string")
  assert(ctx:state().blocked and ctx:state().diagnostic_count == 1)
  assert(ctx:request_generation("still failing") == false)
  assert(log.sink_calls == 1)
  writer.fail = false
  assert(ctx:request_generation("recovered") == true)
  assert(ctx:state().blocked == false)
end

-- Malformed or throwing writer state blocks admission rather than guessing.
do
  local writer = fake_writer()
  writer.malformed = true
  local ctx, _, log = new_context{writer = writer}
  local accepted, reason = ctx:request_generation("first")
  assert(accepted == false and type(reason) == "string")
  assert(ctx:state().blocked and ctx:state().diagnostic_count == 1)
  assert(log.captures == 0 and log.sink_calls == 0)
  writer.malformed = false
  assert(ctx:request_generation("recovered") == true)
  assert(ctx:state().blocked == false and log.captures == 1)
end

-- A sink that completes and then returns a non-boolean result is a protocol
-- violation, not acceptance.
do
  local ctx, _, log = new_context{sink = function(_, done)
    done({kind = "complete", status = "committed"})
  end}
  local accepted = ctx:request_generation("trigger")
  assert(accepted == false)
  local state = ctx:state()
  assert(state.blocked and state.diagnostic_count == 1)
  assert(state.last_diagnostic.code == "delivery.invalid_acceptance")
end

-- A non-boolean return is a protocol violation even with an idle writer: it
-- is diagnosed, retired, and blocked until a fresh idle inspection.
do
  local call = 0
  local ctx, _, log = new_context{sink = function(_, done)
    call = call + 1
    if call == 1 then return nil end
    done({})
    return true
  end}
    local accepted = ctx:request_generation("trigger")
    assert(accepted == false)
    local state = ctx:state()
    assert(state.blocked and state.diagnostic_count == 1)
    assert(state.authorization == false)
    assert(state.last_diagnostic.code == "delivery.invalid_acceptance")
    assert(log.token:is_current() == false)
    assert(ctx:request_generation("recovered") == true)
  assert(log.sink_calls == 2)
end

-- A non-boolean return while the writer holds the exact token returns
-- accepted-pending with revoked commit authorization, retains the record until
-- its matching done, and keeps the block through writer-idle observations.
do
  local writer = fake_writer()
  local call = 0
  local ctx, _, log = new_context{writer = writer, sink = function(request, done)
    call = call + 1
    if call == 1 then
      writer.status, writer.token = "busy", request.token
      return nil
    end
    done({})
    return true
  end}
  local accepted = ctx:request_generation("first")
  assert(accepted == true)
  local state = ctx:state()
  assert(state.blocked and state.status == "blocked")
  assert(state.token ~= nil and state.authorization == false)
  assert(log.token:is_current() == false)
  assert(state.diagnostic_count == 1)
  assert(state.last_diagnostic.code == "delivery.invalid_acceptance")
  writer.status, writer.token = "idle", nil
  assert(ctx:request_generation("blocked") == false)
  assert(log.sink_calls == 1)
  assert(ctx:state().status == "blocked" and ctx:state().token ~= nil)
  assert(log.done({}) == true)
  assert(ctx:state().token == nil)
  assert(ctx:state().status == "blocked")
  assert(ctx:state().diagnostic_count == 1)
  assert(ctx:request_generation("recovered") == true)
  assert(log.sink_calls == 2)
end

-- A thrown sink after completion does not settle twice and does not get
-- mistaken for a rejection.
do
  local ctx, _, log = new_context{sink = function(_, done)
    done({kind = "complete", status = "committed"})
    error("delivery callback failed")
  end}
  assert(ctx:request_generation("trigger") == true)
  local state = ctx:state()
  assert(state.blocked == false and state.diagnostic_count == 1)
  assert(state.last_diagnostic.code == "delivery.sink_failed_after_completion")
end

-- The mutation inventory accepts exact native arrays and clears its proof on
-- identity/order mismatch, malformed inventory, or document lifecycle changes.
do
  local fixture=dofile("tests/acid/runtime_phrase_fixture.lua")
  local song,instrument,first,second,source=fixture.fixture()
  local equal_mapping={__eq=function()return true end}
  local first_mapping=setmetatable({phrase=first},equal_mapping)
  local second_mapping=setmetatable({phrase=second},equal_mapping)
  instrument.phrase_mappings={first_mapping,second_mapping}
  local other_instrument=fixture.instrument({})
  other_instrument.phrase_mappings={}
  song.instruments={instrument,other_instrument}

  local done
  local writer={state=function()return "idle",nil end,
    is_temporary=function()return false end}
  local ctx=context.new{writer=writer,
    capture=function(_,token)return {token=token}end,
    sink=function(_,completion)done=completion;return true end}
  ctx:attach_document(song)
  ctx:open_dialog()
  assert(ctx:request_generation("manual"))
  local token=ctx:state().token
  assert(ctx:mutate(token,function()return true end))

  local matched,reason=ctx:matches_mutation_inventory(song,"instruments")
  assert(matched,"an exact native instrument identity/order match was rejected: "..tostring(reason))
  assert(ctx:matches_mutation_inventory(instrument,"phrases"),
    "an exact native phrase identity/order match was rejected")
  assert(ctx:matches_mutation_inventory(instrument,"phrase_mappings"),
    "an exact native mapping identity/order match was rejected")

  local phrases=instrument.phrases
  instrument.phrases={second,first}
  assert(not ctx:matches_mutation_inventory(instrument,"phrases"),
    "phrase reorder matched the authorized inventory")
  instrument.phrases=phrases
  assert(not ctx:matches_mutation_inventory(instrument,"phrases"),
    "a mismatched inventory proof was not cleared")

  assert(ctx:mutate(token,function()return true end))
  local mappings=instrument.phrase_mappings
  instrument.phrase_mappings={second_mapping,first_mapping}
  assert(not ctx:matches_mutation_inventory(instrument,"phrase_mappings"),
    "mapping reorder matched the authorized inventory")
  instrument.phrase_mappings=mappings
  assert(not ctx:matches_mutation_inventory(instrument,"phrase_mappings"),
    "a mismatched mapping proof was not cleared")

  assert(ctx:mutate(token,function()return true end))
  phrases=instrument.phrases
  instrument.phrases=nil
  assert(not ctx:matches_mutation_inventory(instrument,"phrases"),
    "a malformed phrase inventory matched")
  instrument.phrases=phrases
  assert(not ctx:matches_mutation_inventory(instrument,"phrases"),
    "a malformed inventory proof was not cleared")

  assert(ctx:mutate(token,function()return true end))
  local other_song=fixture.fixture()
  assert(ctx:attach_document(other_song))
  assert(not ctx:matches_mutation_inventory(song,"instruments"),
    "document replacement retained the outgoing inventory proof")
  ctx:open_dialog()
  assert(ctx:release_document())
  assert(not ctx:matches_mutation_inventory(other_song,"instruments"),
    "document release retained its inventory proof")
  if done then done({kind="failure",status="cancelled"}) end
end

print("ACID runtime generation delivery boundary checks passed")
