-- Render native phrases with guarded replacement and source persistence.
local pattrns = require("writers.pattrns_writer")
local compiler = require("model.cycle_interpreter")
local validator = require("writers.phrase_validator")
local articulation = require("model.articulation")
local control = require("model.control_signals")
local gates = require("writers.gate_writer")
local ownership = require("writers.phrase_ownership")
local store = require("model.pattern_store")
local M = {}

M.LPB = 8
M.PHRASE_NAME = "ACID 0.1 TEST"
local busy = false
local current = nil
local MAX_PHRASE_LINES = 512

local function physical_plan(pattern, output_policy)
  output_policy=output_policy or "repeat"
  if output_policy~="repeat" and output_policy~="play_once" then
    return nil,"Invalid phrase output policy"
  end
  if output_policy == "play_once" then
    local plan, err=compiler.compile_cycle(pattern)
    if not plan then return nil,err end
    plan.source_length=plan.length
    return plan,{looping=false,loop_start=1,loop_end=plan.length*2,
      number_of_lines=plan.length*2}
  end
  local loop,err=compiler.plan_loop(pattern)
  if not loop then return nil,err end
  local length=pattern.length*2
  if length*2>MAX_PHRASE_LINES then
    return nil,"intro plus repeating cycle exceeds the native phrase line limit"
  end
  local steps={}
  for cycle,source in ipairs({loop.cold,loop.steady}) do
    for step,event in ipairs(source.steps) do
      local copy={}
      for key,value in pairs(event) do copy[key]=value end
      copy.source_step=step
      copy.step=(cycle-1)*pattern.length+step
      copy.absolute_step=copy.step
      steps[#steps+1]=copy
    end
  end
  return {length=length,steps=steps,note_count=loop.cold.note_count+loop.steady.note_count,
    pitch_length=pattern.pitch_length,loop=loop,source_length=pattern.length},
    {looping=true,loop_start=pattern.length*2+1,loop_end=length*2+1,
      number_of_lines=length*2+1}
end
M.plan_output=physical_plan

local function target_capabilities(instrument)
  local sample=false
  for _,item in ipairs(instrument.samples or {}) do
    if item.sample_buffer and item.sample_buffer.has_sample_data then
      sample=true
      break
    end
  end
  local plugin=instrument.plugin_properties and
    instrument.plugin_properties.plugin_loaded==true or false
  local midi_device=instrument.midi_output_properties and
    instrument.midi_output_properties.device_name or ""
  local midi=midi_device~=""
  return {sample=sample,plugin=plugin,midi=midi}
end

local function slide_steps(plan)
  local steps,seen={},{}
  for _,event in ipairs(plan.steps) do
    if event.kind=="note" and event.transition=="slide" then
      local step=event.source_step or event.step
      if not seen[step] then
        seen[step]=true
        steps[#steps+1]=step
      end
    end
  end
  return steps
end

local function articulation_plan(plan,capabilities,timeline)
  local has_slide=false
  local slides=slide_steps(plan)
  has_slide=#slides>0
  if has_slide and not capabilities.sample then
    local places={}
    for _,step in ipairs(slides) do places[#places+1]=string.format("%02d",step) end
    local approximations={"TIME steps "..table.concat(places,",")..
      ": target has no sample glide operator; ordered note events are retained and slide continuity is approximate"}
    for index,event in ipairs(plan.steps) do
      if event.kind=="note" and event.transition=="slide" then
        local previous
        for cursor=index-1,1,-1 do
          local candidate=plan.steps[cursor]
          if candidate.kind=="rest" then break end
          if candidate.kind=="note" then previous=candidate;break end
        end
        if event.accent or (previous and previous.accent) then
          approximations[#approximations+1]=string.format(
            "TIME step %02d: connected ACCENT change is represented by NOTE velocity; continuous dynamics depend on the target",
            event.source_step or event.step)
        end
      end
    end
    return {},approximations
  end
  local early_releases,release_error=control.release_lines(timeline,2)
  if not early_releases then return nil,release_error end
  local release_at={}
  for _,line in ipairs(early_releases) do release_at[line]=true end
  local rate=1
  for _,event in ipairs(plan.steps) do
    if event.kind=="note" and event.transition=="slide" then
      local held=0
      local index=event.step+1
      while plan.steps[index] and plan.steps[index].kind=="tie"
        and plan.steps[index].holds do
        held=held+1
        index=index+1
      end
      local available=(held+1)*2
      local first_line=(event.step-1)*2+1
      for line=first_line+1,first_line+available-1 do
        if release_at[line] then
          available=line-first_line
          break
        end
      end
      local interval=math.abs(event.note-event.from_note)
      rate=math.max(rate,math.ceil(interval*16/available))
    end
  end
  if not has_slide then return {},{} end
  if rate>254 then
    local places={}
    for _,step in ipairs(slides) do places[#places+1]=string.format("%02d",step) end
    return {},{"TIME steps "..table.concat(places,",")..
      ": slide interval exceeds native glide command capacity; ordered pitch events were retained"}
  end
  local commands,err=articulation.plan(plan,2,rate)
  if not commands then return nil,err end
  local approximations={"native slide continuity and envelope response depend on the target instrument"}
  for index,event in ipairs(plan.steps) do
    if event.kind=="note" and event.transition=="slide" then
      local previous
      for cursor=index-1,1,-1 do
        local candidate=plan.steps[cursor]
        if candidate.kind=="rest" then break end
        if candidate.kind=="note" then previous=candidate;break end
      end
      if event.accent or (previous and previous.accent) then
        approximations[#approximations+1]=string.format(
          "connected accent change at TIME step %02d may not be reproduced",
          event.source_step or event.step)
      end
    end
  end
  return commands,approximations
end

local function copy_pattern(pattern)
  local copy={length=pattern.length,
    pitch_length=pattern.pitch_length,
    pitch_events={},time_events={}}
  for i,pitch in ipairs(pattern.pitch_events) do
    local item={}
    for key,value in pairs(pitch) do item[key]=value end
    copy.pitch_events[i]=item
  end
  for i,command in ipairs(pattern.time_events) do copy.time_events[i]=command end
  return copy
end

local function patterns_equal(a,b)
  if type(a)~="table" or type(b)~="table" then return false end
  for _,key in ipairs({"length","pitch_length"}) do
    if a[key]~=b[key] then return false end
  end
  for i=1,64 do
    local x,y=a.pitch_events[i],b.pitch_events[i]
    if not x or not y then return false end
    for _,key in ipairs({"note","key","octave","accent","slide"}) do
      if x[key]~=y[key] then return false end
    end
  end
  for i=1,64 do if a.time_events[i]~=b.time_events[i] then return false end end
  return true
end

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

local function remove_phrase(instrument, phrase)
  local index=phrase_index(instrument,phrase)
  if not index then return false end
  local ok=pcall(function()instrument:delete_phrase_at(index)end)
  return ok and phrase_index(instrument,phrase)==nil
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
  local instrument_found=false
  for index,instrument in ipairs(song.instruments) do
    if rawequal(instrument,job.instrument) then
      instrument_found=true
      job.instrument_index=index
      break
    end
  end
  if not instrument_found then return false,"target instrument changed during generation" end
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
  if job.commit_observer and job.on_commit then
    pcall(function() job.commit_observer:remove_notifier(job.on_commit) end)
  end
  if job.idle_observer and job.on_idle then
    pcall(function() job.idle_observer:remove_notifier(job.on_idle) end)
  end
  job.on_commit, job.on_idle = nil, nil
end

local function complete(job, error_message, rendered_events)
  if current ~= job then return end
  unlink(job)
  busy = false
  current = nil
  if error_message then
    if job.temporary and not remove_phrase(job.instrument,job.phrase) then
      job.keep_recovery=true
      pcall(function()job.phrase.name="ACID RECOVERY STAGING"end)
    end
    if job.backup and not job.keep_recovery then remove_phrase(job.instrument,job.backup) end
    notify(job, "GENERATION FAILED\n" .. tostring(error_message) ..
      ((job.swapped or job.keep_recovery) and "\nPhrase output or recovery state may have changed; inspect the destination before retrying." or
        "\nPrevious ACID phrase remains unchanged."),true)
    return
  end
  notify(job, string.format(
    "Phrase %02d generated (%d notes, %d OFF; %d raw events). Instrument %02X.",
    job.target_index, rendered_events.notes, rendered_events.offs,
    rendered_events.raw_events, job.instrument_index - 1) ..
    (job.target_warning and "\n"..job.target_warning or "") ..
    (job.approximations and #job.approximations>0 and
      "\nArticulation approximation: "..table.concat(job.approximations,"; ") or "") ..
    (job.cleanup_warning and "\n"..job.cleanup_warning or ""))
end

local function finalize(job, event_count, skipped)
  if current ~= job then return end
  local context_ok,context_error=context_valid(job)
  if not context_ok then complete(job,context_error);return end
  if skipped ~= 0 then
    complete(job, "Renoise skipped " .. tostring(skipped) .. " event(s)")
    return
  end
  -- Pattrns may count no-output pulses among its raw rendered events.
  -- Inspect the *actual phrase cells* to validate musical note/off events.
  if type(event_count) ~= "number" or event_count < job.expected_events then
    complete(job, string.format(
      "Too few raw events: expected at least %d, received %s",
      job.expected_events, tostring(event_count)))
    return
  end
  local layout_ok,layout_error=pcall(function()
    job.phrase.number_of_lines=job.layout.number_of_lines
    job.phrase.looping=job.layout.looping
    job.phrase.loop_end=job.layout.loop_end
    job.phrase.loop_start=job.layout.loop_start
  end)
  if not layout_ok then complete(job,layout_error);return end
  local volumes, volume_error = pattrns.expected_volumes(job.plan, 2,
    job.layout.number_of_lines, job.phrase.visible_note_columns or 1)
  if not volumes then complete(job, volume_error);return end
  local result, validation_error = validator.verify(job.phrase, job.plan, 2,job.layout,
    {volumes=volumes})
  if not result then
    complete(job, validation_error)
    return
  end
  local expected_articulation=job.operations or {effects={},release_lines={}}
  expected_articulation.volumes=volumes
  if job.operations then
    local applied,apply_error=gates.apply_plan(job.phrase,job.operations)
    if not applied then complete(job,apply_error);return end
  end
  local final_result,final_validation_error=validator.verify(job.phrase,job.plan,2,job.layout,expected_articulation)
  if not final_result then complete(job,final_validation_error);return end
  local ok, error_message = pcall(function()
    -- Rendered lines are normal native phrase data (not a running script).
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_PATTERN
    job.phrase.lpb = M.LPB
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
  if not token_current(job) then complete(job,"generation was invalidated before commit");return end
  local safe,swap_err=pcall(function()
    local valid,why=context_valid(job)
    if not valid then error(why) end
    local backup
    if job.replace then
      backup=job.instrument:insert_phrase_at(#job.instrument.phrases+1)
      job.backup=backup
      local backup_ok,backup_error=pcall(function()backup:copy_from(job.target_phrase)end)
      if not backup_ok then
        if not remove_phrase(job.instrument,backup) then
          backup.name="ACID RECOVERY BACKUP"
          job.keep_recovery=true
        else job.backup=nil end
        error("Could not create destination backup: "..tostring(backup_error))
      end
      backup.name="ACID TRANSACTION BACKUP"
      local copied,copy_error=pcall(function()
        job.target_phrase:copy_from(job.phrase)
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
        if remove_phrase(job.instrument,backup) then job.backup=nil
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
        if remove_phrase(job.instrument,backup) then job.backup=nil
        else backup.name="ACID RECOVERY BACKUP";job.keep_recovery=true end
        return true
      end
      if remove_phrase(job.instrument,job.phrase) then job.temporary=false;return true end
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
      local saved,saved_policy=store.load(job.song,phrase)
      if not saved then error("final phrase source association verification failed: "..tostring(saved_policy)) end
      if saved_policy~=job.output_policy then error("final phrase output policy verification failed") end
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
      if not remove_phrase(job.instrument,backup) then
        backup.name="ACID RECOVERY BACKUP"
        job.cleanup_warning="Committed output; recovery backup remains in the instrument."
      end
      job.backup=nil
    end
    if job.replace then
      if remove_phrase(job.instrument,job.phrase) then job.temporary=false
      else
        job.phrase.name="ACID RECOVERY STAGING"
        job.cleanup_warning="Committed output; staging phrase remains in the instrument."
      end
    else
      job.temporary=false
    end
  end)
  if not safe then complete(job,swap_err);return end
  result.raw_events = event_count
  complete(job, nil, result)
end

local function render(job)
  if current ~= job or not token_current(job) then return end
  if job.render_started then return end
  local script = job.phrase.script
  if script.compile_error and script.compile_error ~= "" then
    complete(job, "Script compilation: " .. script.compile_error)
    return
  end
  if script.runtime_error and script.runtime_error ~= "" then
    complete(job, "Script runtime: " .. script.runtime_error)
    return
  end
  job.render_started=true
  notify(job, "ACID: rendering pattrns to native phrase...")
  local ok, error_message = pcall(function()
    local started, start_error = script:render_to_pattern({
      lpb = M.LPB,
      max_events = job.plan.length + 8
    }, function(render_error, rendered_events, skipped_events)
      if current ~= job then return end
      local safe,callback_error=pcall(function()
        if render_error and render_error ~= "" then
          complete(job, "Phrase rendering: " .. tostring(render_error))
        else
          finalize(job, rendered_events, skipped_events)
        end
      end)
      if not safe then
        pcall(complete,job,"Phrase render completion failed: "..tostring(callback_error))
      end
    end)
    if started == false then
      complete(job, "Phrase rendering could not start: " .. tostring(start_error or "unknown error"))
    end
  end)
  if not ok then complete(job, error_message) end
end

local function begin_wait(job)
  local ticks = 0
  -- committed_observable may fire before the compile error is updated.
  -- Wait for idle after commit before reading compile/runtime errors.
  job.on_idle = function()
    if current ~= job then return end
    if not token_current(job) then
      complete(job,job.cancel_error or "generation was invalidated")
      return
    end
    ticks = ticks + 1
    if ticks > 500 then
      complete(job, "Timed out waiting for script compilation")
      return
    end
    if not job.committed or ticks < job.commit_tick + 2 then return end
    local ok, err = pcall(render, job)
    if not ok then complete(job, err) end
  end
  job.idle_observer = renoise.tool().app_idle_observable
  job.idle_observer:add_notifier(job.on_idle)
end

function M.cancel(token)
  if not current or (token and current.token~=token) then return false end
  local job=current
  job.cancelled=true
  local cleanup_error
  if job.temporary then
    if not remove_phrase(job.instrument,job.phrase) then
      job.keep_recovery=true
      cleanup_error="staging phrase cleanup failed"
      pcall(function()job.phrase.name="ACID RECOVERY STAGING"end)
    else
      job.temporary=false
    end
  end
  if job.backup and not remove_phrase(job.instrument,job.backup) then
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
    notify(job,"Generation cancelled; "..cleanup_error.." and recovery material was retained.",true)
    return false
  end
  return true
end

function M.generate(instrument_index, callback, custom_pattern, target_index, options)
  if busy then return nil, "ACID is already generating a phrase" end
  options=options or {}
  if type(options)~="table" then return nil,"Invalid generation options" end
  local output_policy=options.output_policy or "repeat"
  if output_policy~="repeat" and output_policy~="play_once" then
    return nil,"Invalid phrase output policy"
  end
  if type(callback) ~= "function" then
    return nil, "Status callback required"
  end
  if type(custom_pattern)~="table" then
    return nil,"A canonical ACID source is required"
  end
  local song = renoise.song()
  if not song then return nil, "Open a song first" end
  if type(instrument_index) ~= "number" or instrument_index % 1 ~= 0
    or instrument_index < 1 or instrument_index > #song.instruments then
    return nil, "Choose a valid instrument slot"
  end
  local instrument = song.instruments[instrument_index]
  local replace=false
  target_index=target_index or (#instrument.phrases>0 and 1 or #instrument.phrases+1)
  if type(target_index)~="number" or target_index%1~=0 or
      target_index<1 or target_index>#instrument.phrases+1 then
    return nil,"Choose a valid existing phrase or New Phrase"
  end
  local snapshot_id
  if target_index<=#instrument.phrases then
    local target=instrument.phrases[target_index]
    local status=ownership.status(target)
    if status=="owned" then
      replace=true
      snapshot_id=ownership.id(target)
    else
      return nil,"Selected phrase is not safely ACID-owned (or was manually edited)"
    end
  end
  if not snapshot_id then
    local id,err=store.allocate(song)
    if not id then return nil,err end
    snapshot_id=id
  end
  local records,record_err=store.read(song)
  if not records then return nil,record_err end
  if replace and ownership.id(instrument.phrases[target_index]) and
      not records[snapshot_id] then
    return nil,"Selected ACID phrase has no saved source; cannot safely regenerate"
  end
  if replace and phrase_id_count(song,snapshot_id)~=1 then
    return nil,"Selected ACID phrase ID is duplicated; cannot regenerate safely"
  end
  local capacity=renoise.Instrument.MAX_NUMBER_OF_PHRASES or 126
  local required_slots=replace and 2 or 1
  if #instrument.phrases+required_slots>capacity then
    return nil,"Not enough phrase slots for staging and rollback backup"
  end
  local capabilities=target_capabilities(instrument)
  local fixture=copy_pattern(custom_pattern)
  local plan,layout_or_error=physical_plan(fixture,output_policy)
  if not plan then return nil,layout_or_error end
  local layout=layout_or_error
  if layout.number_of_lines>MAX_PHRASE_LINES then return nil,"Rendered phrase exceeds Renoise's line limit" end
  local meta
  local source
  source,meta=pattrns.emit(plan)
  if not source then return nil,meta end
  local timeline,timeline_error=control.compile(fixture,{gate_fraction=0.5,plan=plan,
    output_policy=output_policy,successor=plan.loop and plan.loop.steady})
  if not timeline then return nil,timeline_error end
  local commands,approximations=articulation_plan(plan,capabilities,timeline)
  if not commands then return nil,approximations end
  local operations,operation_error=gates.plan(timeline,plan,commands)
  if not operations and #commands>0 then
    operations,operation_error=gates.plan(timeline,plan,{})
    if operations then
      approximations[#approximations+1]=tostring(operation_error)..
        "; native glide commands conflicted with gate timing, and ordered pitch events were retained"
      commands={}
    end
  end
  if not operations then return nil,operation_error end
  local store_candidate,prepare_error=store.prepare(song,snapshot_id,fixture,output_policy)
  if not store_candidate then return nil,prepare_error end
  local target_phrase=replace and instrument.phrases[target_index] or nil
  local job = {
    instrument = instrument, instrument_index = instrument_index, song=song,
    snapshot_id=snapshot_id,
    store_candidate=store_candidate,target_phrase=target_phrase,
    target_name=target_phrase and target_phrase.name or nil,
    expected_events = meta.note_count + meta.off_count,
    plan = plan, layout=layout, pattern=fixture, output_policy=output_policy,
    operations=operations,approximations=approximations,
    target_warning=not capabilities.sample and not capabilities.plugin and not capabilities.midi and
      "Target has no loaded sample, plugin, or MIDI output; the committed phrase will be silent until a generator is configured." or nil,
    replace=replace,target_index=target_index,temporary=true,token=options.token,
    callback = callback, committed = false, commit_tick = 0,
    cancelled = false
  }

  local ok, error_message = pcall(function()
    -- Render into an append-only temporary phrase, never a user phrase.
    job.phrase = instrument:insert_phrase_at(#instrument.phrases+1)
    job.phrase.name = M.PHRASE_NAME
    job.phrase.playback_mode = renoise.InstrumentPhrase.PLAY_SCRIPT
    local script = job.phrase.script
    script.paragraphs = {source}
    job.commit_observer = script.committed_observable
    job.on_commit = function()
      job.committed = true
      -- Recorded from idle tick counter below; next idle is sufficient
      -- to check result after the asynchronous commit notification.
      job.commit_tick = job.tick or 0
    end
    job.commit_observer:add_notifier(job.on_commit)
    current = job
    busy = true
    local old_begin_wait = begin_wait
    old_begin_wait(job)
    -- Track idle ticks for post-commit settle.
    local idle = job.on_idle
    job.on_idle = function()
      job.tick = (job.tick or 0) + 1
      idle()
    end
    -- Existing notifier must be changed to point at the wrapper.
    job.idle_observer:remove_notifier(idle)
    job.idle_observer:add_notifier(job.on_idle)
    if not token_current(job) then error("generation was invalidated before compile") end
    script:commit()
  end)
  if not ok then
    if current == job then
      complete(job, error_message)
    else
      pcall(function()
        if job.phrase and rawequal(instrument.phrases[#instrument.phrases],job.phrase) then
          instrument:delete_phrase_at(#instrument.phrases)
        end
      end)
    end
    return nil, tostring(error_message)
  end
  notify(job, "ACID: compiling phrase...")
  return true
end

return M
