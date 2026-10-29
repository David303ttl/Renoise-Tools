-- SPDX-License-Identifier: GPL-3.0-only
-- Render native phrases with guarded replacement and source persistence.
local pattrns = require("writers.pattrns_writer")
local validator = require("writers.phrase_validator")
local gates = require("writers.gate_writer")
local ownership = require("renoise.phrase_ownership")
local store = require("renoise.pattern_store")
local target_capabilities = require("renoise.target_capabilities")
local sequencer = require("model.sequencer")
local legato_writer = require("writers.legato_writer")
local phrase_pitch_bend = require("writers.phrase_pitch_bend")
local script_runner = require("writers.script_runner")
local output_planner=require("model.output_planner")
local M = {}

M.PHRASE_NAME = "ACID 0.1 TEST"
local busy = false
local current = nil
local MAX_PHRASE_LINES = 512
local policies = require("model.policies")

local function failure(code, category, message, status)
  message=tostring(message or "Phrase generation failed")
  return {kind="complete",status=status or "error",code=code,category=category,
    message=message,diagnostics={message}}
end

function M.plan_output(pattern,output_policy)
  return output_planner.plan_output(pattern,output_policy,MAX_PHRASE_LINES)
end

local patterns_equal=sequencer.same_source

local function notify(job, message, force)
  if (force or not job.cancelled) and job.callback then
    local ok, err = pcall(job.callback, message)
    if not ok then print("[ACID] Status callback error: " .. tostring(err)) end
  end
end

local function token_current(job)
  if not job.token then return true end
  local ok, value=pcall(function()return job.token:is_current() end)
  return ok and value==true
end

local function lpb_timing(song)
  local ok,valid=pcall(function()
    local expected=renoise.Transport.TIMING_MODEL_LPB
    return expected~=nil and song.transport.timing_model==expected
  end)
  return ok and valid
end

local function phrase_index(instrument, phrase)
  local found
  for index,item in ipairs(instrument.phrases) do
    if rawequal(item,phrase) then
      if found then return nil end
      found=index
    end
  end
  return found
end

local function mutate_phrases(job,action)
  if job.phrase_mutation then return job.phrase_mutation(action) end
  return action()
end

local function remove_phrase(job, phrase)
  local ok,removed=pcall(function()
    local instrument=job.instrument
    local index=phrase_index(instrument,phrase)
    if not index then return false end
    mutate_phrases(job,function() instrument:delete_phrase_at(index) end)
    return phrase_index(instrument,phrase)==nil
  end)
  return ok and removed
end

local function phrase_id_count(song,id)
  local count=0
  for _,instrument in ipairs(song.instruments) do
    for _,phrase in ipairs(instrument.phrases) do
      if ownership.id(phrase)==id then count=count+1 end
    end
  end
  return count
end

local function context_valid(job)
  if current~=job or not token_current(job) then return false,"generation was invalidated" end
  local ok,song=pcall(renoise.song)
  if not ok or not rawequal(song,job.song) then return false,"song changed during generation" end
  if not lpb_timing(song) then
    return false,"transport changed to unsupported timing during generation"
  end
  local instrument_found=false
  for index,instrument in ipairs(song.instruments) do
    if rawequal(instrument,job.instrument) then
      if job.native_notes and next(job.native_notes.midi_commands or {}) and
          index~=job.instrument_index then
        return false,"pitch-bend target instrument moved during generation"
      end
      instrument_found=true
      job.instrument_index=index
      break
    end
  end
  if not instrument_found then return false,"target instrument changed during generation" end
  local capabilities,capability_error=target_capabilities.inspect(job.instrument)
  if not capabilities then return false,capability_error end
  if capabilities.signature~=job.capabilities.signature then
    return false,"target output capabilities changed during generation"
  end
  if not phrase_index(job.instrument,job.phrase) then
    return false,"staging phrase was removed during generation"
  end
  if job.target_phrase then
    local index=phrase_index(job.instrument,job.target_phrase)
    if not index then return false,"target phrase was removed or duplicated during generation" end
    job.target_index=index
    if job.target_phrase.name~=job.target_name or ownership.status(job.target_phrase)~="owned" then
      return false,"target phrase changed during generation"
    end
    if phrase_id_count(song,job.snapshot_id)~=1 then
      return false,"duplicate ACID phrase ID appeared during generation"
    end
  end
  return true
end

local function unlink(job)
  if job.runner then job.runner:detach() end
  if job.idle_observer and job.on_idle then
    pcall(function() job.idle_observer:remove_notifier(job.on_idle) end)
  end
  job.idle_observer, job.on_idle = nil, nil
end

local function complete(job, error_message, rendered_events, failure_status)
  if current ~= job then return end
  unlink(job)
  busy = false
  current = nil
  if error_message then
    if job.temporary and not remove_phrase(job,job.phrase) then
      job.keep_recovery=true
      pcall(function()job.phrase.name="ACID RECOVERY STAGING"end)
    end
    if job.backup and not job.keep_recovery then remove_phrase(job,job.backup) end
    local message=tostring(error_message) ..
      ((job.swapped or job.keep_recovery) and "; phrase output or recovery state may have changed; inspect the destination before retrying" or
        "; previous ACID phrase remains unchanged")
    local code=job.failure_code or
      (failure_status=="suspended" and "safety.target_changed" or "transaction.render")
    local category=job.failure_category or
      (failure_status=="suspended" and "safety" or "transaction")
    notify(job, {kind="complete",status=failure_status or "error",code=code,
      category=category,message=message,
      diagnostics={message},reason=failure_status=="suspended" and tostring(error_message) or nil,
      target={instrument_index=job.instrument_index,
        phrase_index=job.target_index}},true)
    return
  end
  local message=string.format(
    "Phrase %02d generated (%d notes, %d OFF; %d raw events). Instrument %02X.",
    job.target_index, rendered_events.notes, rendered_events.offs,
    rendered_events.raw_events, job.instrument_index - 1) ..
    (job.target_warning and "\n"..job.target_warning or "") ..
    (job.approximations and #job.approximations>0 and
      "\nArticulation approximation: "..table.concat(job.approximations,"; ") or "") ..
    (job.cleanup_warning and "\n"..job.cleanup_warning or "")
  local diagnostics={}
  if job.target_warning then diagnostics[#diagnostics+1]=job.target_warning end
  for _,item in ipairs(job.approximations or {}) do diagnostics[#diagnostics+1]=item end
  if job.cleanup_warning then diagnostics[#diagnostics+1]=job.cleanup_warning end
  notify(job, {kind="complete",status=#diagnostics>0 and "approximate" or "committed",
    code=#diagnostics>0 and "capability.approximate" or "phrase.committed",
    category=#diagnostics>0 and "capability" or "transaction",
    message=message,diagnostics=diagnostics,target={instrument_index=job.instrument_index,
      phrase_index=job.target_index},counts=rendered_events},true)
end

local function finalize(job, event_count, skipped)
  if current ~= job then return end
  local context_ok,context_error=context_valid(job)
  if not context_ok then complete(job,context_error,nil,"suspended");return end
  if skipped ~= 0 then
    complete(job, "Renoise skipped " .. tostring(skipped) .. " event(s)")
    return
  end
  -- Pattrns may count no-output pulses among its raw rendered events.
  -- Inspect the *actual phrase cells* to validate musical note/off events.
  if type(event_count) ~= "number" or event_count < job.expected_events then
    job.failure_code="phrase.render_count"
    job.failure_category="phrase"
    complete(job, string.format(
      "Too few raw events: expected at least %d, received %s",
      job.expected_events, tostring(event_count)))
    return
  end
  local layout_ok,layout_error=pcall(function()
    job.phrase.number_of_lines=job.layout.number_of_lines
    job.phrase.lpb=job.layout.lpb
    job.phrase.shuffle=0
    job.phrase.looping=job.layout.looping
    job.phrase.loop_end=job.layout.loop_end
    job.phrase.loop_start=job.layout.loop_start
  end)
  if not layout_ok then complete(job,layout_error);return end
  local volumes=job.volumes
  local result, validation_error = validator.verify(job.phrase, job.plan, job.layout.lines_per_step,job.layout,
    {volumes=volumes})
  if not result then
    job.failure_code="phrase.validation"
    job.failure_category="phrase"
    complete(job, validation_error)
    return
  end
  local expected_articulation=job.operations or {effects={},release_lines={}}
  expected_articulation.volumes=volumes
  if job.native_notes then
    local applied,apply_error=legato_writer.apply(job.phrase,job.native_notes)
    if not applied then complete(job,apply_error);return end
    expected_articulation={native_notes=job.native_notes}
  elseif job.operations then
    local applied,apply_error=gates.apply_plan(job.phrase,job.operations)
    if not applied then complete(job,apply_error);return end
  end
  local final_result,final_validation_error=validator.verify(job.phrase,job.plan,job.layout.lines_per_step,job.layout,expected_articulation)
  if not final_result then
    job.failure_code="phrase.validation"
    job.failure_category="phrase"
    complete(job,final_validation_error)
    return
  end
  result=final_result
  local ok, error_message = pcall(function()
    -- Rendered lines are normal native phrase data (not a running script).
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    job.phrase.lpb = job.layout.lpb
    job.phrase.shuffle = 0
    job.phrase.number_of_lines = job.layout.number_of_lines
    job.phrase.name = M.PHRASE_NAME
    job.phrase.key_tracking = renoise.InstrumentPhrase.KEY_TRACKING_NONE
    job.phrase.looping = job.layout.looping
    job.phrase.loop_end = job.layout.loop_end
    job.phrase.loop_start = job.layout.loop_start
  end)
  if not ok then
    complete(job, error_message)
    return
  end
  if job.phrase.lpb~=job.layout.lpb or job.phrase.shuffle~=0 then
    complete(job,"Phrase timing metadata verification failed");return
  end
  local final_verified,final_error=validator.verify(job.phrase,job.plan,job.layout.lines_per_step,job.layout,expected_articulation)
  if not final_verified then complete(job,final_error);return end
  if not token_current(job) then
    complete(job,job.invalid_reason or "generation was invalidated before commit",nil,"suspended")
    return
  end
  local safe,swap_err=pcall(function()
    local valid,why=context_valid(job)
    if not valid then job.suspended_reason=why;error(why) end
    local backup
    if job.replace then
      backup=mutate_phrases(job,function() return job.instrument:insert_phrase_at(#job.instrument.phrases+1) end)
      job.backup=backup
      local backup_ok,backup_error=pcall(function()backup:copy_from(job.target_phrase)end)
      if not backup_ok then
        if not remove_phrase(job,backup) then
          backup.name="ACID RECOVERY BACKUP"
          job.keep_recovery=true
        else job.backup=nil end
        error("Could not create destination backup: "..tostring(backup_error))
      end
      backup.name="ACID TRANSACTION BACKUP"
      local copied,copy_error=pcall(function()
        job.target_phrase:copy_from(job.phrase)
        local valid,validation_error=validator.verify(job.target_phrase,job.plan,job.layout.lines_per_step,job.layout,expected_articulation)
        if not valid then error("Copied phrase validation failed: "..tostring(validation_error)) end
        local name,name_error=ownership.make_name(job.target_phrase,job.snapshot_id)
        if not name then error(name_error) end
        job.target_phrase.name=name
      end)
      if not copied then
        local restored,restore_error=pcall(function()
          job.target_phrase:copy_from(backup)
          job.target_phrase.name=job.target_name
        end)
        if not restored or job.target_phrase.name~=job.target_name or
            ownership.status(job.target_phrase)~="owned" then
          job.keep_recovery=true
          job.swapped=true
          backup.name="ACID RECOVERY BACKUP"
          error("Phrase replacement failed and rollback failed; recovery phrase retained: "..tostring(restore_error))
        end
        if remove_phrase(job,backup) then job.backup=nil
        else backup.name="ACID RECOVERY BACKUP";job.keep_recovery=true end
        error("Phrase replacement rolled back: "..tostring(copy_error))
      end
    else
      local name,name_error=ownership.make_name(job.phrase,job.snapshot_id)
      if not name then error(name_error) end
      job.phrase.name=name
    end
    local function rollback_phrase()
      if job.replace then
        local restored,restore_error=pcall(function()
          job.target_phrase:copy_from(backup)
          job.target_phrase.name=job.target_name
        end)
        if not restored or job.target_phrase.name~=job.target_name or
            ownership.status(job.target_phrase)~="owned" then
          job.keep_recovery=true
          job.swapped=true
          backup.name="ACID RECOVERY BACKUP"
          return nil,"destination rollback failed: "..tostring(restore_error)
        end
        if remove_phrase(job,backup) then job.backup=nil
        else backup.name="ACID RECOVERY BACKUP";job.keep_recovery=true end
        return true
      end
      if remove_phrase(job,job.phrase) then job.temporary=false;return true end
      job.keep_recovery=true
      pcall(function()job.phrase.name="ACID RECOVERY STAGING"end)
      return nil,"append rollback failed; recovery phrase retained"
    end
    local function rollback_store()
      local called,restored,restore_error=pcall(store.restore,job.song,job.store_candidate)
      if not called then return nil,tostring(restored) end
      if not restored then return nil,tostring(restore_error) end
      return true
    end
    if not token_current(job) then
      local restored,restore_error=rollback_phrase()
      if not restored then error("generation was invalidated; "..restore_error) end
      error("generation was invalidated before source commit")
    end
    local commit_called,committed,store_error=pcall(store.commit,job.song,job.store_candidate)
    if not commit_called then store_error=committed;committed=nil end
    if not committed then
      local restored_store,store_restore_error=rollback_store()
      local restored_phrase,phrase_restore_error=rollback_phrase()
      if not restored_store or not restored_phrase then
        error("Source commit failed; "..tostring(store_error).."; "..
          tostring(store_restore_error).."; "..tostring(phrase_restore_error))
      end
      error("Source commit failed; phrase change rolled back: "..tostring(store_error))
    end
    job.swapped=job.replace
    local verified,verify_error=pcall(function()
      local status=job.replace and ownership.status(job.target_phrase) or ownership.status(job.phrase)
      local phrase=job.replace and job.target_phrase or job.phrase
      if status~="owned" or ownership.id(phrase)~=job.snapshot_id then
        error("final phrase seal verification failed")
      end
      local saved,saved_policy,saved_pb_range=store.load(job.song,job.instrument,phrase)
      if not saved then error("final phrase source association verification failed: "..tostring(saved_policy)) end
      if saved_policy~=job.output_policy then error("final phrase output policy verification failed") end
      if saved_pb_range~=job.pb_range then error("final phrase PB range verification failed") end
      if not patterns_equal(saved,job.pattern) then error("final phrase source snapshot differs from frozen input") end
    end)
    if not verified then
      local restored_store,store_restore_error=rollback_store()
      local restored_phrase,phrase_restore_error=rollback_phrase()
      if not restored_store or not restored_phrase then
        error("Final verification failed; "..tostring(verify_error).."; "..
          tostring(store_restore_error).."; "..tostring(phrase_restore_error))
      end
      error("Final phrase/source verification failed; changes rolled back: "..tostring(verify_error))
    end
    if backup then
      if not remove_phrase(job,backup) then
        backup.name="ACID RECOVERY BACKUP"
        job.cleanup_warning="Committed output; recovery backup remains in the instrument."
      end
      job.backup=nil
    end
    if job.replace then
      if remove_phrase(job,job.phrase) then job.temporary=false
      else
        job.phrase.name="ACID RECOVERY STAGING"
        job.cleanup_warning="Committed output; staging phrase remains in the instrument."
      end
    else
      job.temporary=false
    end
  end)
  if not safe then
    complete(job,job.suspended_reason or swap_err,nil,
      job.suspended_reason and "suspended" or nil)
    return
  end
  result.raw_events = event_count
  complete(job, nil, result)
end

local function begin_wait(job)
  job.ticks=0
  job.on_idle=function()
    if current~=job then return end
    if not token_current(job) and not job.cancelled then M.cancel(job.token) end
    if current~=job then return end
    job.ticks=job.ticks+1
    if job.ticks~=500 then return end
    if job.render_started then
      notify(job,{kind="status",status="rendering",code="transaction.render_pending",
        message=(job.runner.error and job.runner.error..". " or "")..
          "Native phrase rendering has not completed. New writes are blocked; restart Renoise if its callback never arrives."},true)
    else
      job.runner:cancel()
      complete(job,"Timed out waiting for script commitment")
    end
  end
  job.idle_observer=renoise.tool().app_idle_observable
  job.idle_observer:add_notifier(job.on_idle)
end

function M.cancel(token)
  if not current or (token and current.token~=token) then return false end
  local job=current
  job.cancelled=true
  if job.render_started then
    local result={kind="status",status="rendering",code="transaction.cancel_pending",
      message="Cancellation pending native render completion; new writes are blocked."}
    notify(job,result,true)
    return false,result
  end
  if job.runner then job.runner:cancel() end
  local cleanup_error
  if job.temporary then
    if not remove_phrase(job,job.phrase) then
      job.keep_recovery=true
      cleanup_error="staging phrase cleanup failed"
      pcall(function()job.phrase.name="ACID RECOVERY STAGING"end)
    else
      job.temporary=false
    end
  end
  if job.backup and not remove_phrase(job,job.backup) then
    job.keep_recovery=true
    cleanup_error=(cleanup_error and cleanup_error.." and " or "").."backup cleanup failed"
    pcall(function()job.backup.name="ACID RECOVERY BACKUP"end)
  elseif job.backup then
    job.backup=nil
  end
  unlink(job)
  current=nil
  busy=false
  if cleanup_error then
    local message="Generation cancelled; "..cleanup_error.." and recovery material was retained."
    local result={kind="complete",status="error",message=message,
      diagnostics={message},recovery={staging=job.keep_recovery==true}}
    notify(job,result,true)
    return true,result
  end
  return true
end

function M.release()
  local job=current
  if not job then return end
  if not job.render_started then M.cancel();return end
  unlink(job)
  for key in pairs(job) do job[key]=nil end
  job.released=true
  job.render_started=true
  job.cancelled=true
end

local function generate_impl(instrument_index, callback, custom_pattern, target_index, options)
  if busy then
    return nil,failure("transaction.busy","transaction",current and current.released and
      "Native phrase rendering is still pending; restart Renoise if its callback never arrives." or
      "ACID is already generating a phrase")
  end
  options=options or {}
  if type(options)~="table" then return nil,failure("source.options","source","Invalid generation options") end
  local output_policy=options.output_policy or policies.DEFAULT_OUTPUT_POLICY
  if not policies.valid_output_policy(output_policy) then
    return nil,failure("source.output_policy","source","Invalid phrase output policy")
  end
  local pb_range=options.pb_range==nil and policies.DEFAULT_PB_RANGE or options.pb_range
  if not policies.valid_pb_range(pb_range) then
    return nil,failure("source.pb_range","source","Invalid PB range")
  end
  if type(callback) ~= "function" then
    return nil,failure("source.callback","source","Status callback required")
  end
  if type(custom_pattern)~="table" then
    return nil,failure("source.missing","source","A canonical ACID source is required")
  end
  local source_valid,source_error=sequencer.validate(custom_pattern)
  if not source_valid then
    return nil,failure("source.invalid","source",source_error)
  end
  local song = renoise.song()
  if not song then return nil,failure("safety.no_song","safety","Open a song first") end
  if not lpb_timing(song) then
    return nil,failure("safety.timing_model","safety",
      "Phrase generation requires LPB transport timing")
  end
  if type(instrument_index) ~= "number" or instrument_index % 1 ~= 0
    or instrument_index < 1 or instrument_index > #song.instruments then
    return nil,failure("safety.instrument_missing","safety","Choose a valid instrument slot")
  end
  local instrument = song.instruments[instrument_index]
  local replace=false
  target_index=target_index or (#instrument.phrases>0 and 1 or #instrument.phrases+1)
  if type(target_index)~="number" or target_index%1~=0 or
      target_index<1 or target_index>#instrument.phrases+1 then
    return nil,failure("safety.phrase_missing","safety","Choose a valid existing phrase or New Phrase")
  end
  local snapshot_id
  if target_index<=#instrument.phrases then
    local target=instrument.phrases[target_index]
    local status=ownership.status(target)
    if status=="owned" then
      replace=true
      snapshot_id=ownership.id(target)
    else
      return nil,failure("safety.ownership","safety","Selected phrase is not safely ACID-owned or was manually edited")
    end
  end
  if not snapshot_id then
    local id,err=store.allocate(song)
    if not id then return nil,failure("transaction.id_allocation","transaction",err) end
    snapshot_id=id
  end
  local records,record_err=store.read(song)
  if not records then return nil,failure("transaction.persistence_invalid","transaction",record_err) end
  if replace and ownership.id(instrument.phrases[target_index]) and
      not records[snapshot_id] then
    return nil,failure("safety.source_missing","safety","Selected ACID phrase has no saved source; cannot safely regenerate")
  end
  if replace and phrase_id_count(song,snapshot_id)~=1 then
    return nil,failure("safety.duplicate_id","safety","Selected ACID phrase ID is duplicated; cannot regenerate safely")
  end
  local capacity=renoise.Instrument.MAX_NUMBER_OF_PHRASES or 126
  local required_slots=replace and 2 or 1
  if #instrument.phrases+required_slots>capacity then
    return nil,failure("safety.phrase_capacity","safety","Not enough phrase slots for staging and rollback backup")
  end
  local capabilities,capability_error=target_capabilities.inspect(instrument)
  if not capabilities then return nil,failure("capability.inspect","capability",capability_error) end
  local phrase_api=renoise.InstrumentPhrase
  local planned,planning_error=output_planner.plan(custom_pattern,output_policy,pb_range,{
    max_lines=phrase_api.MAX_NUMBER_OF_LINES or MAX_PHRASE_LINES,
    max_note_columns=phrase_api.MAX_NUMBER_OF_NOTE_COLUMNS or 12,
    max_effect_columns=phrase_api.MAX_NUMBER_OF_EFFECT_COLUMNS or 8,
    play_pattern=phrase_api.PLAY_PATTERN,key_tracking_none=phrase_api.KEY_TRACKING_NONE
  },capabilities,{pitch_bend_delivery=phrase_pitch_bend.delivery_enabled})
  if not planned then return nil,failure("phrase.unrepresentable","phrase",planning_error) end
  local fixture,plan,layout=planned.source,planned.plan,planned.layout
  local native_notes,operations,approximations=planned.native_notes,planned.operations,planned.approximations
  local source,meta=pattrns.emit(plan,{unit=layout.unit,resolution=layout.resolution})
  if not source then return nil,failure("phrase.unrepresentable","phrase",meta) end
  if song.transport.groove_enabled then
    approximations[#approximations+1]="Song groove is active; its effect on phrase timing is unverified."
  end
  local request_token=options.token
  local store_candidate,prepare_error=store.prepare(song,snapshot_id,fixture,output_policy,pb_range,function()
    return request_token==nil or request_token:is_current()==true
  end)
  if not store_candidate then return nil,failure("transaction.persistence_prepare","transaction",prepare_error) end
  local target_phrase=replace and instrument.phrases[target_index] or nil
  local job = {
    instrument = instrument, instrument_index = instrument_index, song=song,
    snapshot_id=snapshot_id,
    store_candidate=store_candidate,target_phrase=target_phrase,
    target_name=target_phrase and target_phrase.name or nil,
    expected_events = meta.note_count + meta.off_count,
    plan = plan, layout=layout, pattern=fixture, output_policy=output_policy,
    volumes=planned.volumes,
    pb_range=pb_range,
    operations=operations,approximations=approximations,native_notes=native_notes,
    target_warning=capabilities.diagnostic,
    capabilities=capabilities,
    replace=replace,target_index=target_index,temporary=true,token=options.token,
    phrase_mutation=options.phrase_mutation,
    callback = callback,
    cancelled = false
  }

  local ok, error_message = pcall(function()
    -- Render into an append-only temporary phrase, never a user phrase.
    job.phrase = mutate_phrases(job,function() return instrument:insert_phrase_at(#instrument.phrases+1) end)
    job.phrase.name = M.PHRASE_NAME
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_SCRIPT
    local script = job.phrase.script
    script.paragraphs = {source}
    job.runner=script_runner.new(script,{
      lpb=job.layout.lpb,max_events=job.plan.length+8
    },{
      rendering=function()
        local valid,context_error=context_valid(job)
        if not valid then job.suspended_reason=context_error;error(context_error) end
        job.render_started=true
        job.ticks=0
        notify(job,{kind="status",status="rendering",message="Rendering native phrase...",
          target={instrument_index=job.instrument_index,phrase_index=job.target_index}})
      end,
      done=function(render_error,rendered_events,skipped_events)
        if current~=job then return end
        if job.released then current=nil;busy=false;return end
        job.render_started=false
        local safe,callback_error=pcall(function()
          if job.cancelled or not token_current(job) then
            complete(job,"Generation cancelled")
          elseif render_error and render_error~="" then
            complete(job,"Phrase rendering: "..tostring(render_error),nil,
              job.suspended_reason and "suspended" or nil)
          else
            finalize(job,rendered_events,skipped_events)
          end
        end)
        if not safe then complete(job,"Phrase render completion failed: "..tostring(callback_error)) end
      end
    })
    current=job
    busy=true
    begin_wait(job)
    if not token_current(job) then error("generation was invalidated before commit") end
    notify(job,{kind="status",status="rendering",message="Committing phrase...",
      target={instrument_index=job.instrument_index,phrase_index=job.target_index}})
    local started,start_error=job.runner:start()
    if not started then error(start_error) end
  end)
  if not ok then
    if current == job then
      complete(job, error_message)
    else
      pcall(function()
        if job.phrase and rawequal(instrument.phrases[#instrument.phrases],job.phrase) then
          mutate_phrases(job,function() instrument:delete_phrase_at(#instrument.phrases) end)
        end
      end)
    end
    return nil, tostring(error_message)
  end
  return true
end

function M.generate(instrument_index, callback, custom_pattern, target_index, options)
  local started,detail,extra=generate_impl(instrument_index,callback,custom_pattern,
    target_index,options)
  if not started and type(detail)~="table" then
    return nil,failure("transaction.render","transaction",detail)
  elseif not started and detail.kind~="complete" then
    return nil,failure("transaction.render","transaction",detail.message)
  end
  return started,detail,extra
end

return M
