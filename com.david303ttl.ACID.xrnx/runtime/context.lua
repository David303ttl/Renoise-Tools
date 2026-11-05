-- SPDX-License-Identifier: GPL-3.0-only
-- Runtime generation delivery boundary.
-- Attached contexts with an installed editor use runtime-owned frozen capture,
-- transition revisions, eligibility, mutation scopes and integrity evidence.
-- Generation capture and request checkpoints remain owned by runtime.requests.
--
-- context.new(options) -> context
--   options.writer  read-only occupancy source. writer.state() returns a
--                   detached status string and an opaque token: "idle", nil
--                   or "busy", <exact operation token>.
--                   No writer job table or writable busy flag is retained.
--   options.sink    sink(request, done) -> true | false, reason.
--                   true accepts and calls done exactly once before return;
--                   false rejects and must not call done. The sink is fixed
--                   for this context.
--
-- Request contract:
--   Capture owns request values; this context passes them through unchanged
--   and does not synthesize eligibility, frozen values, mutation, or blocker
--   behavior. The request shape reserves:
--     request:mutate(token, action) -> all action result values
--       Same operation token only. Depth-counted and non-yielding; unwinds on
--       success or exception, revokes authorization on exception, and
--       rethrows the original failure. No user callback, idle wait, or render
--       wait may run inside it.
--       Requires writer.is_temporary and captures exact pre-scope evidence.
--       A failed outer scope blocks further ACID mutations for that song.
--     request:record_blocker(token, evidence)
--       Verifies the matching live epoch/job, retains copied scalar/value
--       evidence and exact recovery references only while that song is
--       current, and records the evidence before a terminal result.
--   Musical generation enters only through request_generation and its sink.
--
-- context:request_generation(trigger) -> true | false, reason
--   Admission requires no request already starting or dispatching, no
--   installed delivery record, and an idle writer slot. Capture rejection
--   calls the sink zero times. The delivery record is installed before the
--   sink is invoked, so a reentrant request cannot start another generation
--   before the sink returns.
--
--   This is the single scheduler entry for manual and armed Live Edit requests.
--   While the writer slot is occupied, a later request replaces one pending
--   trigger; it is captured and dispatched after the slot becomes idle.
--   Disarm drops pending Live Edit but leaves an explicit manual intent queued.
--
--   Duplicate completion, completion after rejection, completion followed by
--   rejection or an invalid return, and thrown starts are diagnosed at most
--   once per delivery record. They never settle twice. A sink that violates
--   the synchronous contract blocks dispatch until a fresh writer.state()
--   inspection reports idle.
--
-- Boundary obligations:
--   The sink calls done only after terminal cleanup/evidence as its final
--   host/GUI side effect. The runtime guards the full callback even though the
--   writer reports idle before delivery. Cancellation is normalized only from
--   verified settlement, never from a boolean acknowledgement alone.
--
-- context:revoke(token, reason) -> true | false
--   Raw-identity revocation of the active request. A matching call makes the
--   token report false for is_current() and removes authorization while
--   retaining writer occupancy. The synchronous writer callback retires its
--   scalar record without treating it as a deliverable result.
--   Mismatched, already-revoked, rejected, or settled requests return false.
--
-- Lifetime:
--   attach_document(song) -> fresh epoch; replaces/releases an attached song.
--   open_dialog(gui_delivery) -> fresh session; delivery(result) is optional.
--   close_dialog() -> changed; revokes delivery and requests cancellation.
--   release_document() -> changed, volatile draft warning; invalidates before
--     cancel(token, reason), detach(song), and drafts.release(song), then
--     scrubs the active delivery record. These dependencies never authorize
--     occupancy retirement. Repeated close/release is inert.
--   lifetime_state() -> detached epoch/session/open/song_attached scalars.
-- Generation requires an attached song and open dialog. A writer callback
-- reentered during document release can only retire its scalar record.
--
-- The returned context exposes generation, revocation, and lifetime methods.
-- Writer, sink, delivery record, block, diagnostics, and dispatch
-- state remain closure-private.
local M = {}
local epoch_serial = 0
local OPERATION_SERIAL_INCREMENT = 1

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
  if status == "busy" then
    if token == nil or token == false then
      return nil, "busy writer state did not return an operation token"
    end
    return {status = "busy", token = token}
  end
  return nil, "writer state returned an unknown status"
end

function M.new(options)
  assert(type(options) == "table", "runtime context options are required")
  assert(type(options.writer) == "table" and type(options.writer.state) == "function",
    "runtime context requires writer.state")
  assert(type(options.sink) == "function", "runtime context requires a sink")

  local writer = options.writer
  local sink = options.sink
  local current_song = nil
  local inventory = nil
  local requests = nil
  local integrity = nil
  local detached_integrity = nil
  local adoption_blocked_reason = nil
  local observer_error = nil
  local context = {}
  local epoch = 0
  local session = 0
  local opened = false
  local gui_delivery = nil
  local cancel = options.cancel
  local detach = options.detach
  local drafts = options.drafts or require("runtime.draft_cache")
  local releasing = false
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
  local mutation_finalizing=false
  local mutation_recording_failed_reason=nil
  local mutation_recording_failed_song=nil
  local mutation_evidence=nil
  local mutation_group_membership=nil
  local expected_mutation_inventory=nil
  local expected_mutation_inventory_reason="missing-proof"
  local inventory_dirty, external_inventory_dirty, reconciliation_pending, mutation_failed = false, false, false, false
  local native_revision_pending,editor_revision_pending=false,false
  local compute_musical_eligibility
  local draft_options_for_target

  local function invalidate_target_projection()
    if inventory then inventory:invalidate_projection() end
  end
  local invalidate
  local native_instrument, native_phrase = nil, nil
  local transitions=require("runtime.transitions").new()
  local editor=nil
  local editor_dirty=false
  local editor_draft=false
  local preserve_editor
  local install_editor
  local editor_target=nil
  local editor_recovery={}
  local observed_target=nil
  local ownership=require("renoise.phrase_ownership")
  local policies=require("model.policies")
  local store=require("renoise.pattern_store")
  local sequencer=require("model.sequencer")

  local function native_array(object,key)
    local list=object[key]
    local count=#list
    local copy={}
    for index=1,count do copy[index]=list[index] end
    return copy
  end

  local function same_native_array(left,right)
    if type(left)~="table" or type(right)~="table" or #left~=#right then return false end
    for index=1,#left do if not rawequal(left[index],right[index]) then return false end end
    return true
  end

  local function capture_mutation_inventory()
    local ok,proof=pcall(function()
      local instruments=native_array(current_song,"instruments")
      local by_instrument={}
      for _,instrument in ipairs(instruments) do
        by_instrument[#by_instrument+1]={instrument=instrument,
          phrases=native_array(instrument,"phrases"),
          phrase_mappings=native_array(instrument,"phrase_mappings")}
      end
      return {instruments=instruments,by_instrument=by_instrument}
    end)
    expected_mutation_inventory=ok and proof or nil
    expected_mutation_inventory_reason=ok and "captured" or
      ("capture-error: "..tostring(proof):gsub("[%c]"," "):sub(1,160))
  end

  local function semantic(target)
    return {kind=target.kind,reason=target.reason,baseline=target.baseline}
  end

  local function same_semantic(left,right)
    if left.kind~=right.kind or left.reason~=right.reason then return false end
    if rawequal(left.baseline,right.baseline) then return true end
    return ownership.compare(left.baseline,right.baseline)==true
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
    invalidate_target_projection()
    diagnose(record, code, message)
    if not blocked then
      blocked = true
      blocked_reason = reason_text(message, code)
    end
  end

  local function retire(record)
    invalidate_target_projection()
    record.revoked = true
    record.current = false
    record.request = nil
    record.gui_delivery = nil
    record.finish = nil
    if rawequal(active, record) then active = nil end
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
    if copy.kind=="success" and copy.integrity_blocked==true then
      success=false
      copy.status="integrity_blocked"
      copy.reason="Writer success included contradictory integrity evidence"
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

  local function adopt_success(record,result,destination_current,apply_success)
    if not inventory then return false,"No current destination inventory" end
    if not host_object(result.phrase) then return false,"Committed destination phrase is unavailable" end
    local request=record.request
    if not request then return false,"Request values are unavailable" end
    local phrase=result.phrase
    local transfer_new_draft=destination_current and request.kind=="create" and not apply_success and
      (editor_dirty or editor_draft) and editor and editor_target and
      editor_target.kind=="new" and rawequal(editor_target.instrument,request.instrument)
    local new_draft_capture
    if transfer_new_draft and type(drafts.capture)=="function" then
      local captured,descriptor=pcall(drafts.capture,current_song,request.instrument,nil,
        draft_options_for_target(nil))
      if captured then new_draft_capture=descriptor end
    end
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
    -- A closed dialog may retain committed evidence without changing its editor or target.
    if not destination_current then return true end
    if request.operation=="duplicate" then
      inventory:bind_phrase(request.instrument,phrase)
      transitions:transition("target",{instrument=request.instrument,phrase=phrase,kind="owned"})
      local installed,install_error=install_editor({source=result.baseline.source,
        output_policy=result.baseline.settings.output_policy,pb_range=result.baseline.settings.pb_range,
        label=request.label,label_custom=request.label_custom},inventory:editor_target_state(),false,true)
      return installed~=nil,install_error
    end
    if request.kind=="create" and not rawequal(request.phrase,phrase) then
      inventory:bind_phrase(request.instrument,phrase)
      transitions:transition("target",{instrument=request.instrument,phrase=phrase,kind="owned"})
      editor_target={instrument=request.instrument,phrase=phrase,kind="owned"}
      observed_target=semantic(inventory:editor_target_state())
      if transfer_new_draft then
        local prior_warning=editor.draft_warning
        preserve_editor(true)
        editor.draft_warning=prior_warning or editor.draft_warning
        local matches_ok,matches_destination=pcall(drafts.matches_values,current_song,
          request.instrument,phrase,editor.source,editor.output_policy,editor.pb_range,
          editor.label,editor.label_custom)
        if matches_ok and matches_destination and new_draft_capture and
            type(drafts.compare_and_clear)=="function" then
          local cleared,clear_error=pcall(drafts.compare_and_clear,current_song,
            new_draft_capture,false)
          if not cleared or not clear_error then
            diagnose(record,"completion.draft_transfer",cleared and
              "New Phrase draft changed before transfer cleanup" or clear_error)
          end
        end
      end
    elseif request.kind=="regenerate" then
      observed_target=semantic(inventory:editor_target_state())
    end
    if apply_success then
      if request.kind=="create" and request.target_kind=="new" and editor and
          sequencer.same_source(editor.source,request.source) and result.baseline and result.baseline.id then
        local _,_,_,committed_label,committed_custom=
          require("renoise.pattern_store").read_entry(current_song,result.baseline.id)
        if committed_label and (editor.label~=committed_label or
            editor.label_custom~=(committed_custom==true)) then
          editor.label,editor.label_custom=committed_label,committed_custom==true
          transitions:transition("metadata",{changed=true})
        end
      end
      editor_dirty=false
      editor_draft=false
    elseif request.kind=="regenerate" and request.baseline and (editor_dirty or editor_draft) and editor and
        not ownership.compare(request.baseline,result.baseline) and editor_target and
        rawequal(editor_target.instrument,request.instrument) and
        rawequal(editor_target.phrase,phrase) then
      local draft_ok,draft_matches,metadata=pcall(drafts.matches_values,current_song,
        request.instrument,phrase,editor.source,editor.output_policy,editor.pb_range,
        editor.label,editor.label_custom)
      if draft_ok and draft_matches and type(metadata)=="table" then
        local target=inventory:edit_target_state()
        local rebound_ok,rebound,rebind_warning=pcall(drafts.rebind,current_song,
          request.instrument,phrase,editor.source,editor.output_policy,editor.pb_range,
          metadata,draft_options_for_target(target))
        local warning=(not rebound_ok and rebound) or rebind_warning
        editor.draft_warning=editor.draft_warning or warning
      end
    end
    return true
  end


  local function fail_sink_contract(record, code, message)
    record.rejected = true
    retire(record)
    block(record, code, message)
    return false, blocked_reason
  end

  local function uncertain_start(record, failure)
    local state, inspection_error = inspect_writer(writer)
    local detail = reason_text(failure, "the sink failed")
    local occupancy
    if not state then
      occupancy="writer state unavailable: "..tostring(inspection_error)
    elseif state.status=="busy" and rawequal(state.token,record.token) then
      occupancy="the issued operation still owns the writer slot"
    elseif state.status=="busy" then
      occupancy="another operation owns the writer slot"
    else
      occupancy="the writer reports idle"
    end
    local phase=record.settled and "after delivering completion" or "before delivering completion"
    return fail_sink_contract(record,"delivery.sink_failed",
      "Sink failed "..phase..": "..detail..
      "; "..occupancy..". Dispatch is blocked until writer state is safe")
  end

  local function invalid_acceptance(record)
    local state, state_error = inspect_writer(writer)
    local occupancy
    if state and state.status == "idle" then
      occupancy="the writer reports idle"
    elseif state and state.status=="busy" and rawequal(state.token,record.token) then
      occupancy="the issued operation still owns the writer slot"
    elseif state and state.status=="busy" then
      occupancy="another operation owns the writer slot"
    else
      occupancy="writer state unavailable"..(state_error and (": "..tostring(state_error)) or "")
    end
    return fail_sink_contract(record,"delivery.invalid_acceptance",
      "Sink returned an invalid acceptance result for the synchronous completion contract; "..
      occupancy..". Dispatch is blocked until writer state is safe")
  end

  local function flush_pending()
    if flushing or not pending_trigger then return false end
    if dispatching or (active and not active.settled) then return false end
    if releasing or current_song == nil or not opened then
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

  function context:request_duplicate()
    return self:request_generation("manual","duplicate")
  end

  local function preserve_duplicate_draft(destination)
    local baseline=destination.baseline
    if sequencer.same_source(editor.source,baseline.source) and
        editor.output_policy==baseline.settings.output_policy and editor.pb_range==baseline.settings.pb_range then
      return true
    end
    local matches,metadata=drafts.matches_values(current_song,destination.instrument,destination.phrase,
      editor.source,editor.output_policy,editor.pb_range,editor.label,editor.label_custom)
    if not matches then return false,"Duplicate requires the current session draft" end
    local descriptor,reason=drafts.capture(current_song,destination.instrument,destination.phrase,
      draft_options_for_target(destination))
    if not descriptor then return false,reason end
    local read,raw=pcall(function()return current_song.tool_data end)
    if not read then return false,"Cannot read the duplicate draft preimage" end
    local evidence,capture_error=integrity:capture_metadata(raw)
    if not evidence then return false,capture_error end
    local saved,result,save_error=pcall(drafts.put,current_song,destination.instrument,destination.phrase,
      editor.source,editor.output_policy,editor.pb_range,draft_options_for_target(destination),
      editor.label,editor.label_custom)
    local verified,valid=pcall(function()
      if not saved or result~=true or not drafts.is_current(current_song,descriptor) then return false end
      local matches,current=drafts.matches_values(current_song,destination.instrument,destination.phrase,
        editor.source,editor.output_policy,editor.pb_range,editor.label,editor.label_custom)
      if not matches or current.token~=metadata.token or current.revision~=metadata.revision or
          not current.persistent then return false end
      local captured_raw=current_song.tool_data
      local source,policy,pb,label,custom=require("renoise.pattern_store").read_draft(
        current_song,destination.instrument,destination.phrase)
      return source~=nil and sequencer.same_source(source,editor.source) and policy==editor.output_policy and
        pb==editor.pb_range and label==editor.label and custom==editor.label_custom and
        current_song.tool_data==captured_raw and drafts.is_current(current_song,descriptor)
    end)
    if not verified or not valid then
      local readable,current=pcall(function()return current_song.tool_data end)
      if not readable or current~=raw then
        local recorded,value=pcall(integrity.record,integrity,evidence)
        if not recorded or value~=true then
          mutation_recording_failed_reason="Duplicate draft recovery evidence could not be recorded"
          mutation_recording_failed_song=current_song
        end
        transitions:transition("blocker")
        invalidate("ACID cannot safely update this song")
      end
      return false,saved and save_error or "Duplicate draft could not be durably verified"
    end
    editor.draft_warning=nil
    return true
  end

  function context:request_generation(trigger,operation)
    if operation~=nil and operation~="duplicate" then return false,"Invalid request operation" end
    if operation and (not editor or trigger~="manual") then return false,"Invalid duplicate admission" end
    local destination
    if observer_error then return false,observer_error end
    if mutation_depth>0 or mutation_failed then
      return false,"Synchronous mutation is active or requires recovery"
    end
    if adoption_blocked_reason then return false,adoption_blocked_reason end
    if releasing or current_song == nil or not opened then
      return false, "No current document dialog is open"
    end
    if dispatching then
      return false, "A generation request is already dispatching"
    end
    if editor then
      if trigger~="manual" and trigger~="live" then return false,"Invalid generation trigger" end
      if trigger=="live" and not transitions:revision_state().armed then return false,"Live Edit is not armed" end
      if not editor.valid then return false,editor.reason or "Invalid editor source or settings" end
      destination=inventory:edit_target_state()
      if operation=="duplicate" and destination.kind~="owned" then
        return false,"Duplicate requires a committed owned phrase"
      end
      if not editor_target or not rawequal(destination.instrument,editor_target.instrument) or
          not rawequal(destination.phrase,editor_target.phrase) or destination.kind~=editor_target.kind then
        return false,"Editor source has not been loaded for this target"
      end
      local eligible,reason=compute_musical_eligibility(self,active and active.token,destination)
      if not eligible then return false,reason end
      local occupied, inspection_error=inspect_writer(writer)
      if not occupied then
        block(nil,"admission.state_unavailable",
          "Cannot inspect writer occupancy: "..tostring(inspection_error)..
          "; dispatch is blocked until writer state is safe")
        return false,blocked_reason
      end
      if active and not active.settled or occupied.status~="idle" then
        if operation=="duplicate" then return false,"The writer has not settled" end
        if blocked then return false,blocked_reason or "Generation dispatch is blocked" end
        pending_trigger=trigger
        preserve_editor(destination.kind=="new",destination)
        return true,"Generation queued for the current writer job"
      end
      if operation=="duplicate" then
        local preserved,preserve_error=preserve_duplicate_draft(destination)
        if not preserved then return false,preserve_error end
      end
      self:transition("request",{trigger=trigger})
    end
    if integrity and integrity:state().blocked then return false,integrity:state().reason end
    if mutation_failed then return false,"ACID cannot safely update this song after a failed synchronous mutation" end
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

    if trigger=="manual" and pending_trigger=="live" then pending_trigger=nil end
    if editor and operation~="duplicate" then preserve_editor(editor_target and editor_target.kind=="new",destination) end

    dispatching = true
    invalidate_target_projection()
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
    local token = new_token(record)
    record.token = token

    local captured, request, capture_reason = pcall(function()
      return requests:capture(trigger,token,operation)
    end)
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

    if record.released or current_song == nil or not opened or
        epoch ~= record.epoch or session ~= record.session then
      dispatching = false
      retire(record)
      return false, "Generation context changed during capture"
    end
    record.current = true
    record.request = request
    active = record
    if editor then
      local valid,validation_error=requests:validate_authorization_checkpoint(request)
      if not valid then
        record.rejected=true
        retire(record)
        dispatching=false
        return false,validation_error
      end
    end
    record.finish = function(result)
      local terminal_current=current_song~=nil and opened and not record.released and
        record.epoch==epoch and record.session==session
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
      local baseline_current=record.session==session and not record.released and
        record.revisions~=nil and revisions.target_revision==record.revisions.target_revision
      local destination_current=terminal_current and baseline_current
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
      if record.request and record.request.operation=="duplicate" and
          (not apply_success or revisions.metadata_revision~=record.revisions.metadata_revision) then
        destination_current=false
        terminal.stale=true
      end
      if success and baseline_current then
        local adopted,adopt_reason=adopt_success(record,terminal,destination_current,apply_success)
        if not adopted then
          diagnose(record,"completion.baseline",adopt_reason)
          success=false
          apply_success=false
          terminal.kind="failure"
          terminal.status="integrity_blocked"
          terminal.verified=false
          terminal.reason=adopt_reason or "Committed baseline could not be adopted"
          if terminal_current and integrity and record.request then
            local request=record.request
            local evidence={operation=request.kind,committed=true,
              instrument=request.instrument,phrase=terminal.phrase,
              committed_baseline=terminal.baseline,reason=terminal.reason}
            local recorded,record_error=integrity:record(evidence)
            if recorded then
              record.blocker_pending=true
              transitions:transition("blocker")
              invalidate("ACID cannot safely update this song")
            else
              adoption_blocked_reason=terminal.reason
              block(record,"completion.baseline_blocker",
                record_error or "ACID cannot safely update this song")
            end
          elseif terminal_current then
            adoption_blocked_reason=terminal.reason
            block(record,"completion.baseline_blocker",
              "ACID cannot safely update this song")
          end
        end
      end
      if not success and terminal.status=="integrity_blocked" and terminal_current then
        pending_trigger=nil
        if not record.blocker_pending then
          local request=record.request
          local evidence={operation=request and request.kind or "regenerate",
            committed=terminal.committed==true,
            instrument=request and request.instrument or nil,
            phrase=terminal.phrase or request and request.phrase or nil,
            baseline=request and request.baseline or nil,
            committed_baseline=terminal.baseline,
            recovery=terminal.recovery or {},reason=terminal.reason or terminal.message}
          local recorded_ok,recorded,record_error=pcall(function()
            return integrity and integrity:record(evidence)
          end)
          if recorded_ok and recorded then
            record.blocker_pending=true
            transitions:transition("blocker")
            invalidate("ACID cannot safely update this song")
          else
            adoption_blocked_reason=terminal.reason or
              record_error or "Integrity recovery evidence could not be recorded"
            block(record,"completion.integrity_blocker",
              record_error or adoption_blocked_reason)
          end
        end
      end
      local request=record.request
      if success and destination_current and request and request.draft_capture and
          type(drafts.compare_and_clear)=="function" then
        local clear_ok,cleared,clear_error
        if request.kind=="regenerate" and type(drafts.compare_and_clear_revision)=="function" and
            type(terminal.baseline)=="table" then
          clear_ok,cleared,clear_error=pcall(drafts.compare_and_clear_revision,request.song,
            request.draft_capture,terminal.baseline.id)
        else
          clear_ok,cleared,clear_error=pcall(drafts.compare_and_clear,request.song,
            request.draft_capture,request.kind=="create")
        end
        if not clear_ok or cleared~=true then
          diagnose(record,"completion.draft_clear",clear_ok and
            "Captured draft changed before completion cleanup" or clear_error)
        end
      end
      if terminal_current and success then
        inventory_dirty=true;reconciliation_pending=true
        invalidate_target_projection()
      end
      if terminal_current and effects and effects.reconcile then
        inventory_dirty=true;reconciliation_pending=true
        invalidate_target_projection()
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
      if not record.settled then
        return invalid_acceptance(record)
      end
      if record.diagnosed["delivery.duplicate_completion"] or
          record.diagnosed["delivery.completion_after_rejection"] then
        return fail_sink_contract(record,"delivery.duplicate_completion",
          "Sink invoked the terminal callback more than once; dispatch is blocked until writer state is safe")
      end
      record.finish=nil
      return true
    end

    if accepted == false then
      if record.settled then
        return fail_sink_contract(record,"delivery.complete_then_reject",
          "Sink completed the request and then rejected it; dispatch is blocked until writer state is safe")
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
      local rejected_request=record.request
      record.rejected = true
      retire(record)
      if type(rejection)=="table" and (rejection.status=="integrity_blocked" or
          rejection.integrity_blocked==true or rejection.category=="integrity") then
        local rejection_current=not record.released and record.epoch==epoch and record.session==session and
          current_song~=nil and type(rejected_request)=="table" and
          rawequal(rejected_request.song,current_song)
        if rejection_current then
          local evidence={operation=rejected_request.kind,
            committed=rejection.committed==true,reason=rejection.reason or rejection.message,
            recovery=rejection.recovery or {}}
          local recorded_ok,recorded=pcall(function()
            return integrity and integrity:record(evidence)
          end)
          if recorded_ok and recorded then
            transitions:transition("blocker")
            invalidate("ACID cannot safely update this song")
          else
            mutation_recording_failed_reason="ACID cannot safely update this song because writer integrity evidence could not be recorded"
            mutation_recording_failed_song=current_song
          end
        end
      end
      return false, reason_text(rejection, "Generation request rejected")
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

  invalidate=function(reason)
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

  preserve_editor=function(force,verified_target)
    if (not editor_dirty and not force) or not editor or not inventory or not current_song then return end
    local state=context:integrity_state()
    if state.blocked then editor.draft_warning=state.reason;return end
    local target=verified_target or inventory:target_state()
    if not target.instrument then return end
    if not editor_target or not rawequal(target.instrument,editor_target.instrument) or
        not rawequal(target.phrase,editor_target.phrase) then return end
    local match_ok,matches_current=pcall(drafts.matches_values,current_song,target.instrument,
      target.phrase,editor.source,editor.output_policy,editor.pb_range,editor.label,editor.label_custom)
    if match_ok and matches_current then
      editor.draft_warning=nil
      editor_dirty=false
      return
    end
    local ok,saved,reason=pcall(drafts.put,current_song,target.instrument,target.phrase,
      editor.source,editor.output_policy,editor.pb_range,
      verified_target and draft_options_for_target(target) or context:draft_options(),
      editor.label,editor.label_custom)
    editor.draft_warning=not ok and "Cannot preserve session draft" or (not saved and reason or nil)
    if ok and saved then editor_dirty=false end
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
    if editor_revision_pending then return nil end
    if not editor then return nil end
    local result=ownership.copy_snapshot(editor)
    if result and editor.prepared_resolution then
      result.prepared_resolution=require("model.sequencer").detach_prepared(
        editor.prepared_resolution,editor.source)
    end
    return result
  end

  function context:rename_label(label,label_custom,history_guard)
    local store=require("renoise.pattern_store")
    if type(label_custom)~="boolean" or not store.valid_label(label) then
      return false,"Phrase label must be 1..32 valid ASCII bytes"
    end
    if not current_song or not opened or not editor or not editor.valid then
      return false,"No valid editor source is installed"
    end
    local integrity_state=self:integrity_state()
    if integrity_state.blocked then return false,integrity_state.reason end
    if editor.label==label and editor.label_custom==label_custom then return true end
    local target=inventory and inventory:edit_target_state()
    if not target or not editor_target or not rawequal(target.instrument,editor_target.instrument) or
        not rawequal(target.phrase,editor_target.phrase) then
      return false,"Current phrase ownership or source association is unavailable"
    end
    if target.kind=="owned" then
      local baseline=target.baseline
      if type(baseline)~="table" or not baseline.source or not baseline.settings then
        return false,"Committed source association is unavailable"
      end
    elseif target.kind~="new" then return false,"Current destination is not writable" end
    local song,action_epoch,action_session,accepted_editor=current_song,epoch,session,editor
    local revisions=transitions:revision_state()
    local draft_guard,draft_error=drafts.capture_label(song,target.instrument,target.phrase)
    if not draft_guard then return false,draft_error end
    local function guard()
      if not rawequal(current_song,song) or not opened or epoch~=action_epoch or session~=action_session or
          not rawequal(editor,accepted_editor) or mutation_depth>0 or mutation_failed then return false end
      local current=transitions:revision_state()
      if current.target_revision~=revisions.target_revision or current.edit_revision~=revisions.edit_revision or
          current.metadata_revision~=revisions.metadata_revision or current.operation_serial~=revisions.operation_serial or
          current.armed~=revisions.armed or self:integrity_state().blocked then return false end
      if history_guard and history_guard()~=true then return false end
      local live=inventory and inventory:edit_target_state()
      return live~=nil and live.kind==target.kind and rawequal(live.instrument,target.instrument) and
        rawequal(live.phrase,target.phrase) and draft_guard()
    end
    local raw
    local ok,value=pcall(function()return current_song.tool_data end)
    if not ok then return false,"Cannot read song metadata: "..tostring(value) end
    raw=value
    local evidence,capture_error=integrity:capture_metadata(raw)
    if not evidence then return false,capture_error end
    local pending_source=(target.kind=="new" or editor_dirty) and editor.source or nil
    local stored,write_result,detail,outcome=pcall(store.update_label,
      current_song,target.instrument,target.phrase,label,label_custom,raw,
      pending_source,editor.output_policy,editor.pb_range,guard,function()
        return drafts.accept_label(song,target.instrument,target.phrase,label,label_custom,guard)
      end)
    if not stored or write_result~=true then
      if not stored or outcome==store.LABEL_WRITE_UNCERTAIN then
        local recorded,result=pcall(integrity.record,integrity,evidence)
        if not recorded or result~=true then
          mutation_recording_failed_reason="Label persistence recovery evidence could not be recorded"
          mutation_recording_failed_song=current_song
        end
        transitions:transition("blocker")
        invalidate("ACID cannot safely update this song")
      end
      return false,stored and detail or write_result or "Phrase label was not saved"
    end
    editor.label,editor.label_custom=label,label_custom
    editor.draft_warning=nil
    transitions:transition("metadata",{changed=true})
    return true
  end

  compute_musical_eligibility=function(self,token,known_target)
    if not current_song or not opened then return nil,"No current document dialog is open" end
    if editor_revision_pending then return nil,"Native phrase revision is being restored" end
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    if adoption_blocked_reason then return nil,adoption_blocked_reason end
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
    local target=known_target or self:target_state()
    if target.kind~="new" and target.kind~="owned" then return nil,target.reason or "Target is not writable" end
    return target
  end

  function context:musical_eligibility(token)
    return compute_musical_eligibility(self,token)
  end

  local function transition_target(kind,values,for_restore)
      values=values or {}
      local state=context:integrity_state()
      if state.blocked and editor_dirty then
        return {kind="unavailable",reason=state.reason}
      end
      pending_trigger=nil
      local before
      local changed
      if for_restore then
        local projection=inventory:target_projection()
        changed=not rawequal(projection.instrument,values.instrument) or not rawequal(projection.phrase,values.phrase)
          or (kind=="target" and values.kind=="new")~=(projection.kind=="new")
        if not changed or editor_dirty then before=inventory:edit_target_state()
        else before=projection end
      else
        before=inventory:target_state()
        changed=not rawequal(before.instrument,values.instrument) or not rawequal(before.phrase,values.phrase)
          or (kind=="target" and values.kind=="new")~=(before.kind=="new")
      end
      if changed then preserve_editor(false,before);retain_invalid_editor()
      elseif for_restore then preserve_editor(false,before) end
      local target
      if for_restore and not changed then
        target=before
      elseif for_restore then
        if kind=="target" and values.kind=="new" then target=inventory:bind_new_for_restore(values.instrument)
        else target=inventory:bind_phrase_for_restore(values.instrument,values.phrase) end
      elseif kind=="target" and values.kind=="new" then target=inventory:bind_new(values.instrument)
      else target=inventory:bind_phrase(values.instrument,values.phrase) end
      local effects=transitions:transition(kind,{instrument=target.instrument,phrase=target.phrase,kind=target.kind,
        semantic_changed=not changed and observed_target~=nil and not same_semantic(observed_target,semantic(target))})
      apply_effects(effects,"Target changed")
      observed_target=semantic(target)
      if kind=="target" then
        local read,instrument,phrase=pcall(function()
          return current_song.selected_instrument,current_song.selected_phrase
        end)
        if read then native_instrument,native_phrase=instrument,phrase end
      end
      return target,effects
  end

  install_editor=function(values,destination,is_draft,completion)
      local buffer,copy_error=ownership.copy_snapshot({source=values.source,output_policy=values.output_policy,pb_range=values.pb_range})
      if not buffer then return nil,copy_error end
      buffer.label=values.label or (editor and editor.label) or "Untitled"
      buffer.label_custom=values.label_custom==true or
        (values.label==nil and editor and editor.label_custom==true) or false
      local prepared,prepared_error
      if editor and require("model.sequencer").same_source(editor.source,buffer.source) then
        prepared=editor.prepared_resolution
      elseif require("model.sequencer").validate(buffer.source) then
        prepared,prepared_error=require("model.sequencer").prepare_resolution(buffer.source)
      end
      buffer.prepared_resolution=prepared
      local current_values={source=buffer.source,output_policy=buffer.output_policy,pb_range=buffer.pb_range}
      local changed=not editor or not ownership.compare(
        {source=editor.source,output_policy=editor.output_policy,pb_range=editor.pb_range},current_values)
      local policies=require("model.policies")
      local source_valid,source_error=require("model.sequencer").validate(buffer.source)
      buffer.valid=source_valid and policies.valid_output_policy(buffer.output_policy) and policies.valid_pb_range(buffer.pb_range)
      buffer.reason=not buffer.valid and (source_error or "Invalid source settings") or nil
      local eligible=compute_musical_eligibility(context,active and active.token,destination)
      local effects=transitions:transition("programmatic",{changed=changed,valid=buffer.valid,eligible=eligible~=nil})
      if not completion then apply_effects(effects,"Editor source or settings changed") end
      if changed then retain_invalid_editor() end
      editor=buffer
      editor_dirty=false
      editor_draft=is_draft==true
      editor_target={instrument=destination.instrument,phrase=destination.phrase,kind=destination.kind}
      observed_target=semantic(destination)
      return context:editor_state(),effects
  end

  function context:restore_editor_target(instrument,phrase,native_selection)
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    local state=self:integrity_state()
    if state.blocked and editor_dirty then return nil,state.reason end
    if not inventory or not current_song then return nil,"No current document is attached" end
    local kind=native_selection==true and "native_target" or "target"
    local target,target_effects=transition_target(kind,{instrument=instrument,phrase=phrase,
      kind=phrase==nil and "new" or "existing"},true)
    local result={target=inventory:target_projection(),source=nil,output_policy=nil,pb_range=nil,
      draft=false,draft_error=nil,source_available=false}
    local policies=require("model.policies")
    local sequencer=require("model.sequencer")
    if target.kind=="owned" then
      local baseline=target.baseline
      if type(baseline)=="table" and type(baseline.source)=="table" and type(baseline.settings)=="table" then
        result.source=sequencer.copy_source(baseline.source)
        result.output_policy=baseline.settings.output_policy
        result.pb_range=baseline.settings.pb_range
        result.source_available=result.source~=nil
      else
        result.reason="Verified destination source is unavailable"
      end
    elseif target.kind=="new" then
      result.source=sequencer.new_pattern()
      result.output_policy=policies.DEFAULT_OUTPUT_POLICY
      result.pb_range=policies.DEFAULT_PB_RANGE
    else
      result.reason=target.reason or "Source unavailable"
    end
    if result.source and (target.kind=="owned" or target.kind=="new") then
      local restored,restore_error,restored_pb,metadata,restored_label,restored_custom
      local options=target.kind=="owned" and draft_options_for_target(target) or self:draft_options()
      restored,restore_error,restored_pb,metadata,restored_label,restored_custom=
        drafts.restore(current_song,instrument,phrase,options)
      if restored then
        result.source=restored
        result.output_policy=restore_error
        result.pb_range=restored_pb
        result.draft=metadata and metadata.origin~="committed" or false
        result.label=restored_label or "Untitled"
        result.label_custom=restored_custom==true
      elseif restore_error then
        result.draft_error=restore_error
      end
    end
    if not result.source then
      result.source=sequencer.new_pattern()
      result.output_policy=policies.DEFAULT_OUTPUT_POLICY
      result.pb_range=policies.DEFAULT_PB_RANGE
      result.label=result.label or "Untitled"
      result.label_custom=result.label_custom==true
    end
    editor_revision_pending=false
    local installed,install_effects=install_editor({source=result.source,
      output_policy=result.output_policy,pb_range=result.pb_range,label=result.label,
      label_custom=result.label_custom},target,result.draft)
    if not installed then return nil,install_effects end
    result.editor=installed
    result.effects=install_effects
    result.target_effects=target_effects
    return result
  end

  function context:transition(kind,values)
    values=values or {}
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    if not inventory then return nil,"No current document is attached" end
    if kind=="target" or kind=="native_target" then
      return transition_target(kind,values,false)
    elseif kind=="refresh" then
      local target=inventory:target_state()
      inventory_dirty=false
      external_inventory_dirty=false
      local changed=observed_target~=nil and not same_semantic(observed_target,semantic(target))
      if changed then pending_trigger=nil end
      local effects=transitions:transition(kind,{semantic_changed=changed})
      apply_effects(effects,"Target eligibility changed")
      observed_target=semantic(target)
      return target,effects
    elseif kind=="edit" or kind=="programmatic" or kind=="reset" then
      if kind~="edit" then pending_trigger=nil end
      local buffer,copy_error=ownership.copy_snapshot({source=values.source,output_policy=values.output_policy,pb_range=values.pb_range})
      if not buffer then return nil,copy_error end
      buffer.label=values.label or (editor and editor.label) or "Untitled"
      buffer.label_custom=values.label_custom==true or
        (values.label==nil and editor and editor.label_custom==true) or false
      local current_values={source=buffer.source,output_policy=buffer.output_policy,pb_range=buffer.pb_range}
      local changed=not editor or not ownership.compare(
        {source=editor.source,output_policy=editor.output_policy,pb_range=editor.pb_range},current_values)
      if editor and require("model.sequencer").same_source(editor.source,buffer.source) then
        buffer.prepared_resolution=editor.prepared_resolution
      elseif require("model.sequencer").validate(buffer.source) then
        local prepared,prepared_error=require("model.sequencer").prepare_resolution(buffer.source)
        if not prepared then return nil,prepared_error end
        buffer.prepared_resolution=prepared
      end
      local policies=require("model.policies")
      local source_valid,source_error=require("model.sequencer").validate(buffer.source)
      buffer.valid=source_valid and policies.valid_output_policy(buffer.output_policy) and policies.valid_pb_range(buffer.pb_range)
      buffer.reason=not buffer.valid and (source_error or "Invalid source settings") or nil
      local writer_state=inspect_writer(writer)
      local force_full=external_inventory_dirty and writer_state and writer_state.status=="idle"
      local destination=inventory:editor_target_state(force_full)
      local eligible=compute_musical_eligibility(self,active and active.token,destination)
      local effects=transitions:transition(kind,{changed=changed,valid=buffer.valid,eligible=eligible~=nil})
      apply_effects(effects,"Editor source or settings changed")
      if changed then retain_invalid_editor() end
      editor=buffer
      if kind=="programmatic" and values.restore==true then
        editor_dirty=false;editor_draft=values.draft==true
      elseif changed then editor_dirty=true;editor_draft=true end
      editor_target={instrument=destination.instrument,phrase=destination.phrase,kind=destination.kind}
      if changed and not (kind=="programmatic" and values.restore==true) then preserve_editor(false,destination) end
      if effects.live_intent then
        pending_trigger="live"
        effects.accepted=true
        effects.reason="Generation queued for the next idle update"
      end
      return self:editor_state(),effects
    end
    local effects=transitions:transition(kind,values)
    apply_effects(effects,"Runtime "..kind)
    if kind=="disarm" and pending_trigger=="live" then pending_trigger=nil end
    if kind=="request" or kind=="external" or kind=="undo"
        or kind=="close" or kind=="blocker" then pending_trigger=nil end
    if effects.reconcile then
      inventory_dirty=true;external_inventory_dirty=true;reconciliation_pending=true
      invalidate_target_projection()
    end
    return effects
  end

  function context:mutation_state()
    return {depth=mutation_depth+(mutation_finalizing and 1 or 0),dirty=inventory_dirty,
      pending=reconciliation_pending,failed=mutation_failed}
  end

  function context:matches_mutation_inventory(subject,inventory_kind)
    local expected=expected_mutation_inventory
    if not current_song then return false,"no-current-song" end
    if not expected then return false,expected_mutation_inventory_reason or "missing-proof" end
    local matches=false
    local source_kind
    local ok=pcall(function()
      if rawequal(subject,current_song) and inventory_kind=="instruments" then
        source_kind=true
        matches=same_native_array(expected.instruments,native_array(current_song,"instruments"))
        return
      end
      local saved
      for _,candidate in ipairs(expected.by_instrument) do
        if rawequal(candidate.instrument,subject) then saved=candidate;break end
      end
      if not saved then return end
      if inventory_kind=="phrases" then
        source_kind=true
        matches=same_native_array(saved.phrases,native_array(subject,"phrases"))
      elseif inventory_kind=="phrase_mappings" then
        source_kind=true
        matches=same_native_array(saved.phrase_mappings,native_array(subject,"phrase_mappings"))
      end
    end)
    if not ok then
      expected_mutation_inventory=nil
      expected_mutation_inventory_reason="read-error"
      return false,"read-error"
    end
    if not source_kind then
      local captured_count=#expected.instruments
      local record_count=#expected.by_instrument
      local expected_index=0
      for index,candidate in ipairs(expected.instruments) do
        if rawequal(candidate,subject) then expected_index=index;break end
      end
      local member_ok,member_index=pcall(function()
        local index=ownership.membership(current_song,subject,nil)
        return index
      end)
      return false,string.format("source-kind-mismatch:captured=%d:records=%d:expected_index=%d:membership_index=%s:kind=%s",
        captured_count,record_count,expected_index,
        member_ok and tostring(member_index or 0) or "error",tostring(inventory_kind))
    end
    if not matches then
      expected_mutation_inventory=nil
      expected_mutation_inventory_reason="membership-mismatch"
      return false,"membership-mismatch"
    end
    return true,"matched"
  end

  function context:mark_dirty(reason)
    inventory_dirty=true
    external_inventory_dirty=true
    reconciliation_pending=true
    invalidate_target_projection()
    if mutation_depth==0 then
      pending_trigger=nil
      apply_effects(transitions:transition("external"),reason or "External native change")
    end
  end

  function context:notify_native_change(kind,subject)
    if kind=="selection" then
      if not current_song then return false end
      local ok,instrument,phrase=pcall(function()
        return current_song.selected_instrument,current_song.selected_phrase
      end)
      if not ok then
        self:mark_dirty("Cannot inspect native selection")
        return false
      end
      if rawequal(instrument,native_instrument) and rawequal(phrase,native_phrase) then return false end
      local writer_state=inspect_writer(writer)
      if writer_state and writer_state.status=="busy" and self:is_temporary(instrument,phrase) then return false end
      self:mark_dirty("Native selection changed")
      return true
    end
    if kind=="undo" then
      native_revision_pending=true
      inventory_dirty=true
      external_inventory_dirty=true
      reconciliation_pending=true
      invalidate_target_projection()
      pending_trigger=nil
      local affects_editor=false
      local affected_phrase=nil
      if editor_target and subject then
        if rawequal(editor_target.phrase,subject) then
          affects_editor=true
          affected_phrase=editor_target.phrase
        elseif rawequal(editor_target.instrument,subject) then
          affects_editor=true
          affected_phrase=editor_target.phrase
        end
      end
      if drafts and type(drafts.detach_for_native_revision)=="function" and affected_phrase then
        local target_instrument,target_phrase,source,policy,pb=nil,nil,nil,nil,nil
        if affects_editor then
          target_instrument=editor_target.instrument
          target_phrase=affected_phrase
          if editor_dirty or editor_draft then
            source=editor and editor.source or nil
            policy=editor and editor.output_policy or nil
            pb=editor and editor.pb_range or nil
          end
        end
        pcall(drafts.detach_for_native_revision,current_song,target_phrase,"Native phrase revision changed",
          target_instrument,source,policy,pb)
      end
      if affects_editor then
        editor_revision_pending=true
        editor_dirty=false
        editor_draft=false
        editor_target=nil
      end
      apply_effects(transitions:transition("undo"),"Native undo or redo change")
      return true
    end
    self:mark_dirty("External native change")
    return true
  end

  function context:set_observer_error(reason)
    observer_error=reason
    invalidate_target_projection()
    if reason then self:mark_dirty(reason) end
  end

  local function run_mutation(token,action)
    local operation_scope=active and active.current and rawequal(active.token,token)
    if type(action)~="function" or not operation_scope or not current_song or
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
    if mutation_depth==1 then mutation_finalizing=true end
    mutation_depth=mutation_depth-1
    if mutation_depth==0 then
      local finalized,finalization_error=pcall(function()
        if not ok then
          mutation_failed=true
          transitions:transition("external")
          invalidate("Synchronous mutation failed")
        end
        mutation_token=nil
        inventory_dirty=true
        reconciliation_pending=true
        invalidate_target_projection()
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
          local final_instrument,final_phrase=current_song.selected_instrument,current_song.selected_phrase
          assert(not writer.is_temporary(current_song,final_instrument,final_phrase),
            "ACID temporary phrase remains the native selection at mutation finalization")
          native_instrument=final_instrument
          native_phrase=final_phrase
          end)
          if not neutral then
            mutation_failed=true
            ok,failure=false,reason
            transitions:transition("external")
            invalidate("Temporary neutrality could not be verified")
          end
        end
        if mutation_failed then
          local recorded,record_result=pcall(integrity.record,integrity,mutation_evidence)
          if not recorded or record_result~=true then
            mutation_recording_failed_reason="ACID cannot safely update this song because mutation evidence could not be recorded"
            mutation_recording_failed_song=current_song
          end
          local transitioned=pcall(transitions.transition,transitions,"blocker")
          if not transitioned then
            mutation_recording_failed_reason=mutation_recording_failed_reason or
              "ACID cannot safely update this song because mutation state could not be finalized"
            mutation_recording_failed_song=mutation_recording_failed_song or current_song
          end
        elseif ok then
          capture_mutation_inventory()
        end
      end)
      if not finalized then
        mutation_failed=true
        mutation_recording_failed_reason=mutation_recording_failed_reason or
          "ACID cannot safely update this song because mutation finalization failed"
        mutation_recording_failed_song=mutation_recording_failed_song or current_song
        ok,failure=false,finalization_error
      end
      mutation_evidence=nil
      mutation_group_membership=nil
      mutation_finalizing=false
    end
    if not ok then error(failure,0) end
    return (unpack or table.unpack)(values,1,values.n)
  end

  function context:mutate(token,action)
    return run_mutation(token,action)
  end

  function context:reconcile()
    if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
    reconciliation_pending=false
    local revision_reconciled=false
    local function decorated(target,effects)
      if revision_reconciled then
        effects=effects or {}
        effects.native_revision_reconciled=true
      end
      return target,effects
    end
    if native_revision_pending then
      local occupied=inspect_writer(writer)
      if not occupied or occupied.status~="idle" then
        reconciliation_pending=true
        return inventory:target_projection()
      end
      local ok,undo=pcall(function() return current_song:is_undo_redoing() end)
      if not ok or type(undo)~="boolean" or undo then
        reconciliation_pending=true
        return inventory:target_projection()
      end
      native_revision_pending=false
      revision_reconciled=true
      inventory:invalidate_native_revisions()
    end
    local function refresh_or_defer()
      local occupied=inspect_writer(writer)
      if not occupied or occupied.status~="idle" then
        reconciliation_pending=true
        return inventory:target_projection()
      end
      local target,effects=self:refresh_inventory()
      return decorated(target,effects)
    end
    local ok,instrument,phrase=pcall(function() return current_song.selected_instrument,current_song.selected_phrase end)
    if not ok then return nil,"Cannot inspect native selection" end
    if not rawequal(instrument,native_instrument) or not rawequal(phrase,native_phrase) then
      local projection=inventory:target_projection()
      if rawequal(instrument,projection.instrument) and rawequal(phrase,projection.phrase) then
        native_instrument,native_phrase=instrument,phrase
        if inventory_dirty then return refresh_or_defer() end
        return decorated(projection)
      end
      local occupied=inspect_writer(writer)
      if occupied and occupied.status=="busy" and context:is_temporary(instrument,phrase) then
        reconciliation_pending=true
        return projection
      end
      native_instrument,native_phrase=instrument,phrase
      local target,effects=self:transition("native_target",{instrument=instrument,phrase=phrase,kind="existing"})
      inventory_dirty=false
      return decorated(target,effects)
    end
    if inventory_dirty then return refresh_or_defer() end
    return decorated(inventory:target_projection())
  end

  function context:close_dialog()
    if not opened then return false end
    invalidate_target_projection()
    opened = false
    pending_trigger=nil
    transitions:transition("close")
    gui_delivery = nil
    if active then active.gui_delivery=nil end
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
    local draft_release_token
    if integrity and type(integrity.prepare_draft_release)=="function" then
      local prepared,token,reason=pcall(integrity.prepare_draft_release,integrity)
      if prepared and token then draft_release_token=token
      else
        warning="Recovery draft evidence could not be preserved: "..
          reason_text(prepared and reason or token,"draft preconditions changed")
      end
    end
    if drafts and type(drafts.release) == "function" then
      local ok, released, message = pcall(drafts.release, song)
      if ok and released then
        warning = warning or message
        if draft_release_token and integrity then
          pcall(integrity.complete_draft_release,integrity,draft_release_token)
        end
      else
        warning = "Session-only ACID draft release failed"
        diagnose(nil, "lifetime.drafts_failed", warning)
      end
    end
    current_song = nil
    transitions:release()
    editor,observed_target=nil,nil
    editor_dirty=false
    editor_draft=false
    editor_target=nil
    editor_recovery={}
    native_instrument,native_phrase=nil,nil
    mutation_depth,mutation_token=0,nil
    mutation_finalizing=false
    mutation_evidence=nil
    expected_mutation_inventory=nil
    expected_mutation_inventory_reason="missing-proof"
    inventory_dirty,external_inventory_dirty,reconciliation_pending,mutation_failed=false,false,false,false
    native_revision_pending,editor_revision_pending=false,false
    pending_trigger=nil
    last_result,last_commit,last_commit_label=nil,nil,nil
    if inventory then inventory:release() end
    inventory = nil
    if integrity then
      integrity:suspend()
      detached_integrity=integrity
    end
    integrity = nil
    adoption_blocked_reason=nil
    if requests then requests:release() end
    requests = nil
    if active then
      active.request = nil
      active.gui_delivery = nil
      active.finish = nil
      active.released = true
    end
    -- The native writer owns occupancy through synchronous rollback/settlement.
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
    if mutation_recording_failed_song and not rawequal(mutation_recording_failed_song,song) then
      mutation_recording_failed_reason=nil
      mutation_recording_failed_song=nil
    end
    epoch_serial = epoch_serial + 1
    epoch = epoch_serial
    current_song = song
    native_revision_pending,editor_revision_pending=false,false
    observer_error=nil
    expected_mutation_inventory=nil
    expected_mutation_inventory_reason="missing-proof"
    adoption_blocked_reason=nil
    local selection_ok,selected_instrument,selected_phrase=pcall(function() return song.selected_instrument,song.selected_phrase end)
    if selection_ok then native_instrument,native_phrase=selected_instrument,selected_phrase end
    inventory = require("runtime.inventory").new(song,writer)
    if detached_integrity then
      local resumed=detached_integrity:resume(song,drafts)
      if resumed then integrity=detached_integrity
      else detached_integrity:release();detached_integrity=nil end
    end
    integrity = integrity or require("runtime.integrity").new(song,drafts)
    requests=require("runtime.requests").new({
      current=function(include_target,include_editor,full_target)
        local revisions=transitions:revision_state()
        local target
        if include_target and inventory then
          if full_target==false then target=inventory:editor_target_state()
          else target=inventory:edit_target_state() end
        end
        return {song=current_song,epoch=epoch,session=session,open=opened,
          target_revision=revisions.target_revision,edit_revision=revisions.edit_revision,
          metadata_revision=revisions.metadata_revision,operation_serial=revisions.operation_serial,
          editor=include_target and include_editor~=false and context:editor_state() or nil,
          target=target}
      end,
      occupancy=function(token) return context:occupancy_state(token) end,
      revoke=function(token,reason) return context:revoke(token,reason) end,
      blocked=function(token)
        if mutation_failed or (mutation_depth>0 and not rawequal(mutation_token,token)) then
          return true,"Synchronous mutation is active or requires recovery"
        end
        local state=context:integrity_state()
        return state.blocked,state.reason
      end,
      baseline_reference=function(instrument,phrase,snapshot)
        if not inventory then return nil,"No current destination inventory" end
        return inventory:retained_baseline_reference(instrument,phrase,snapshot)
      end,
      drafts=drafts,
      draft_options=function(target)
        if target then return draft_options_for_target(target) end
        return context:draft_options()
      end,
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
    invalidate_target_projection()
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

  function context:record_blocker(token,evidence)
    local record=active
    if not integrity or not record or record.settled or record.rejected or
        record.released or record.epoch~=epoch or not rawequal(record.token,token) then
      return false,"Recovery evidence does not belong to the current operation"
    end
    if type(evidence)~="table" or getmetatable(evidence)~=nil then
      return false,"Recovery evidence is invalid"
    end
    local normalized={}
    for key,value in pairs(evidence) do normalized[key]=value end
    local validator=require("writers.phrase_validator")
    local function verified_baseline(value,allow_live,instrument,phrase)
      if type(value)~="table" or type(value.snapshot)~="table" then
        return nil,"Recovery baseline proof is unavailable"
      end
      local snapshot,_,identity=validator.retained_baseline(value.snapshot)
      if not snapshot and allow_live and inventory then
        local selected=inventory:target_projection()
        local current=inventory:edit_target_state()
        local candidate=current and current.baseline
        if rawequal(instrument,selected.instrument) and rawequal(phrase,selected.phrase) and
            current and current.kind=="owned" and candidate and
            ownership.compare(value.snapshot,candidate.snapshot)==true and
            value.id==candidate.id and ownership.compare(value.source,candidate.source)==true and
            ownership.compare(value.settings,candidate.settings)==true and
            ownership.compare(value.planning_inputs,candidate.planning_inputs)==true then
          snapshot=candidate.snapshot
          identity=validator.retained_baseline_identity(snapshot)
        end
      end
      if not snapshot or not identity or not validator.is_retained_baseline_identity(identity,snapshot) then
        return nil,"Recovery baseline proof is unavailable"
      end
      local copy,copy_error=ownership.copy_snapshot({id=value.id,source=value.source,
        settings=value.settings,planning_inputs=value.planning_inputs})
      if not copy then return nil,copy_error end
      copy.snapshot=snapshot
      return copy
    end
    for _,field in ipairs({"baseline","committed_baseline"}) do
      if evidence[field]~=nil then
        local value,baseline_error=verified_baseline(evidence[field],field=="baseline",
          evidence.instrument,evidence.phrase)
        if not value then return false,baseline_error end
        normalized[field]=value
      end
    end
    local recorded,reason=integrity:record(normalized)
    if recorded then
      record.blocker_pending=true
      transitions:transition("blocker")
      invalidate("ACID cannot safely update this song")
    end
    return recorded,reason
  end

  function context:integrity_state()
    local state=integrity and integrity:state() or {blocked=false,serial=0,recovery={}}
    if observer_error then
      state.blocked=true
      state.reason=observer_error
    end
    if mutation_recording_failed_reason then
      state.blocked=true
      state.reason=mutation_recording_failed_reason
    end
    if adoption_blocked_reason then
      state.blocked=true
      state.reason=state.reason or adoption_blocked_reason
    end
    return state
  end

  function context:target_state()
    if mutation_depth>0 or mutation_failed then return {kind="unavailable",reason="Synchronous mutation is active or requires recovery"} end
    if not inventory then return {kind="unavailable",reason="No current document is attached"} end
    return inventory:target_state()
  end

  function context:target_projection()
    if mutation_depth>0 or mutation_failed then return {kind="unavailable",reason="Synchronous mutation is active or requires recovery"} end
    if not inventory then return {kind="unavailable",reason="No current document is attached"} end
    return inventory:target_projection()
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

  draft_options_for_target=function(verified_target)
    local verified_baseline=verified_target and verified_target.baseline
    local validation_used=false
    local validator=require("writers.phrase_validator")
    local baseline_snapshot=verified_baseline and verified_baseline.snapshot
    local baseline_identity=baseline_snapshot and validator.retained_baseline_identity(baseline_snapshot)
    local retained_baseline=baseline_snapshot and
      validator.is_retained_baseline_identity(baseline_identity,baseline_snapshot)
    if baseline_snapshot and not retained_baseline then
      local resolved_ok,resolved,_,resolved_identity=pcall(validator.retained_baseline,baseline_snapshot)
      if resolved_ok and resolved and
          validator.is_retained_baseline_identity(resolved_identity,resolved) then
        baseline_snapshot=resolved
        baseline_identity=resolved_identity
        retained_baseline=true
      end
    end
    return {validate=function(song,instrument,phrase)
      if mutation_depth>0 or mutation_failed then return nil,"Synchronous mutation is active or requires recovery" end
      if not inventory then return nil,"No current document is attached" end
      if verified_target and verified_baseline then
        if validation_used then return nil,"Fresh target proof was already consumed" end
        validation_used=true
        if not rawequal(song,current_song) or
            not rawequal(instrument,verified_target.instrument) or
            not rawequal(phrase,verified_target.phrase) or verified_target.kind~="owned" or
            not verified_baseline.id then
          return nil,"Fresh target proof does not match the draft destination"
        end
        if retained_baseline then
          return {source=verified_baseline.source,settings=verified_baseline.settings,
            baseline=baseline_snapshot,planning_inputs=verified_baseline.planning_inputs,
            baseline_identity=baseline_identity}
        end
      end
      return inventory:draft_options().validate(song,instrument,phrase)
    end}
  end

  function context:draft_options()
    return draft_options_for_target(nil)
  end

  return context
end

return M
