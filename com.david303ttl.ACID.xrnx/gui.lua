-- SPDX-License-Identifier: GPL-3.0-only
-- Native ViewBuilder PITCH/TIME editor.
local M = {}
local sequencer=require("model.sequencer")
local scales=require("model.scales")
local scale_preferences=require("runtime.scale_preferences")
local policies=require("model.policies")
local editor=require("model.editor_state")
local drafts=require("runtime.draft_cache")
local ownership=require("renoise.phrase_ownership")
local pattern_store=require("renoise.pattern_store")
local phrase_writer=require("writers.phrase_writer")
local audition=require("runtime.audition")
local active_audition
local active_label_dialog
local dialog
local runtime_context=require("runtime.context")
local native_observers=require("runtime.observers").new()
local active_runtime
local active_live_checkbox
local feedback_request_contexts=setmetatable({},{__mode="k"})
local attached_song
local dialog_session
local idle_observable
local idle_notifier
local idle_active=false
local lifecycle_enabled=true
local lifecycle_records={}
local function remove_exact_notifier(observable,handler)
  local has_ok,has_notifier=pcall(function() return observable:has_notifier(handler) end)
  if not has_ok then return false,tostring(has_notifier) end
  if type(has_notifier)~="boolean" then return false,"has_notifier must return a boolean" end
  if not has_notifier then return true end
  local removed,remove_error=pcall(function() observable:remove_notifier(handler) end)
  local checked,is_registered=pcall(function() return observable:has_notifier(handler) end)
  if not checked then return false,tostring(is_registered) end
  if type(is_registered)~="boolean" then return false,"has_notifier must return a boolean" end
  if not is_registered then return true end
  if not removed then return false,tostring(remove_error) end
  return false,"notifier remains registered after removal"
end
local function remove_lifecycle_watchers(keep_record)
  local complete=true
  for index=#lifecycle_records,1,-1 do
    local record=lifecycle_records[index]
    if not (keep_record and rawequal(record,keep_record)) then
      local removed,err=remove_exact_notifier(record.observable,record.handler)
      if removed then
        table.remove(lifecycle_records,index)
      else
        complete=false
        record.remove_error=tostring(err)
      end
    end
  end
  return complete
end
local function lifecycle_registration_failed(label,reason)
  lifecycle_enabled=false
  remove_lifecycle_watchers()
  error(label.." notifier registration failed: "..tostring(reason))
end
local function remove_idle_watch(observable,notifier)
  if observable==nil and notifier==nil then observable,notifier=idle_observable,idle_notifier end
  if observable==nil or notifier==nil then return true end
  local is_current=rawequal(idle_observable,observable) and rawequal(idle_notifier,notifier)
  if is_current then idle_active=false end
  local ok,err=remove_exact_notifier(observable,notifier)
  if not ok then return false,tostring(err) end
  if is_current and rawequal(idle_observable,observable) and rawequal(idle_notifier,notifier) then
    idle_observable,idle_notifier=nil,nil
    idle_active=false
  end
  return true
end
local function detach_dialog_watch()
  local observers_removed,observer_error=native_observers:detach()
  local idle_removed,idle_error=remove_idle_watch()
  if not observers_removed then return false,observer_error end
  if not idle_removed then return false,idle_error end
  return true
end
local function stop_live_context()
  if active_label_dialog then
    pcall(function() active_label_dialog:close() end)
    active_label_dialog=nil
  end
  if active_audition then
    local preview=active_audition
    active_audition=nil
    preview:close()
  end
  if active_runtime then
    active_runtime:transition("disarm")
    active_runtime:close_dialog()
  end
  local checkbox=active_live_checkbox
  active_live_checkbox=nil
  if checkbox then pcall(function() checkbox.value=false end) end
end
local function release_context()
  if not lifecycle_enabled then return true end
  if active_audition then
    local preview=active_audition
    active_audition=nil
    preview:close()
  end
  local song=attached_song or renoise.song()
  if song and drafts.has_volatile(song) then
    renoise.app():show_warning(
      "ACID has drafts that could not be saved with this song. They will be lost when it closes.")
  end
  attached_song=nil
  local listeners_removed=detach_dialog_watch()
  if active_runtime then active_runtime:release_document() end
  stop_live_context()
  if dialog then
    local stale=dialog
    dialog=nil
    dialog_session=nil
    pcall(function() stale:close() end)
  end
  local release_warning=phrase_writer.release()
  if release_warning then renoise.app():show_warning("The phrase update was interrupted.") end
  return listeners_removed
end
local function register_lifecycle(observable,label,handler)
  if observable==nil then lifecycle_registration_failed(label,"observable is required") end
  local add_ok,add_notifier=pcall(function() return observable.add_notifier end)
  local remove_ok,remove_notifier=pcall(function() return observable.remove_notifier end)
  local has_ok,has_notifier=pcall(function() return observable.has_notifier end)
  if not add_ok or type(add_notifier)~="function" or not remove_ok or type(remove_notifier)~="function" or
      not has_ok or type(has_notifier)~="function" then
    lifecycle_registration_failed(label,"observable must support add_notifier, has_notifier and remove_notifier")
  end
  local record={observable=observable,handler=handler}
  lifecycle_records[#lifecycle_records+1]=record
  local ok,err=pcall(function() observable:add_notifier(handler) end)
  if ok then
    local checked,registered=pcall(function() return observable:has_notifier(handler) end)
    if not checked or registered~=true then
      ok=false
      err=checked and "notifier is not registered after subscription" or registered
    end
  end
  if not ok then
    lifecycle_registration_failed(label,err)
  end
end
local tool=renoise.tool()
register_lifecycle(tool.app_release_document_observable,"Document release",release_context)
register_lifecycle(tool.app_new_document_observable,"New document",release_context)
local unload_record
local unload_notifier=function()
  local released_cleanly=true
  if lifecycle_enabled then
    released_cleanly=release_context()
    lifecycle_enabled=false
  end
  local idle_removed=remove_idle_watch()
  local observers_removed=native_observers:detach()
  local lifecycle_removed=remove_lifecycle_watchers(unload_record)
  if released_cleanly and idle_removed and observers_removed and lifecycle_removed then
    remove_lifecycle_watchers()
  end
end
register_lifecycle(tool.tool_will_unload_observable,"Tool unload",unload_notifier)
unload_record=lifecycle_records[#lifecycle_records]

local keys={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local RANDOM_SEED_MAX=2147483646
local RANDOM_WEIGHT_MAX=1000
local RANDOM_NOTE_MIN,RANDOM_NOTE_MAX=24,60
local RANDOM_FIELD_WIDTH=90
local RANDOM_LAST_SEED_WIDTH=200
local WORKSPACE_HEIGHT=248
local FEEDBACK_WIDTH,FEEDBACK_SPACING=820,2
local FEEDBACK_LINE_HEIGHT,FEEDBACK_PADDING=20,8
local FEEDBACK_EMPTY_HEIGHT=1
local FEEDBACK_ISSUE_ORDER={"save","destination","scale","audition","input","generation","approximation"}
local SCALE_UI={root_width=65,category_width=155,choice_width=255,
  search_width=165,detail_width=800,import_width=95}
local octave_names={"DOWN (-1)","NORMAL (0)","UP (+1)"}
local colors={selected={0xF0,0x70,0x70},used={0x55,0xAA,0x75},
  idle={0x49,0x4B,0x55},inactive={0x30,0x32,0x39},note={0xBD,0x5B,0x5B},
  tie={0x5D,0x88,0xB7},rest={0x4B,0x4D,0x56},
  warning={0xF2,0x77,0x77}}
local STAGE_ORIGIN_FIELDS={"song","epoch","session","edit_revision","target_revision",
  "operation_serial","instrument","phrase","kind","id","history_revision"}

function M.show()
  assert(lifecycle_enabled,"ACID lifecycle observers are unavailable")
  if dialog and dialog.visible then
    if active_runtime and active_runtime:lifetime_state().open and dialog_session==active_runtime:lifetime_state().session then dialog:show();return end
    detach_dialog_watch()
    stop_live_context()
    dialog:close(); dialog=nil
  elseif dialog then
    detach_dialog_watch()
    stop_live_context()
    dialog=nil
  end
  local idle_removed,idle_error=remove_idle_watch()
  assert(idle_removed,"ACID idle notifier removal failed: "..tostring(idle_error))
  local song=renoise.song()
  if not song then renoise.app():show_warning("Open a song first.");return end
  local vb=renoise.ViewBuilder()
  local pattern
  local pitch_page,time_page=1,1
  local selected_pitch,selected_step=1,1
  local workspace_tab=1
  local accepted_pitch_baseline
  local updating=false
  local scale_state={root=0,follow=false}
  local feedback={issues={},confirmation=nil,previous_save_warning=false,previous_save_context=nil}
  local builtin=scales.builtin()
  do
    local custom_text,load_error=scale_preferences.load(tool)
    local custom,parse_error=custom_text and scales.parse(custom_text) or nil
    scale_state.custom=custom or {}
    local catalog,catalog_error=scales.merge(builtin,scale_state.custom)
    scale_state.catalog=catalog or builtin
    scale_state.load_error=load_error or parse_error or catalog_error
  end
  local update
  local runtime
  local session
  local stage
  local label_ui={}
  local clipboard={scopes={"pitch","time","both"},names={pitch="PITCH",time="TIME",both="Both"}}
  local guard_stage,finish_stage
  local stage_status,stage_actions,entry_navigation
  local refresh_stage
  local function current_session()
    local state=runtime and runtime:lifetime_state()
    return state and state.open and state.session==session
  end
  local output_policy,pb_range
  local phrase_label,phrase_label_custom="Untitled",false
  local function reset_source(length)
    pattern=sequencer.new_pattern(length)
    output_policy=policies.DEFAULT_OUTPUT_POLICY
    pb_range=policies.DEFAULT_PB_RANGE
  end
  reset_source()
  accepted_pitch_baseline=assert(sequencer.copy_source(pattern))
  local history=editor.new_history(pattern,output_policy,pb_range,phrase_label,phrase_label_custom)
  local undo_button
  local redo_button
  local selected_instrument=math.min(song.selected_instrument_index,#song.instruments)
  local editor_view=1
  local function edit_source()
    return stage and editor_view==1 and stage.candidate or pattern
  end
  local labels={}
  local instrument_targets={}
  for i,instrument in ipairs(song.instruments) do
    local name=instrument.name~="" and instrument.name or "(unnamed)"
    instrument_targets[i]=instrument
    labels[i]=string.format("%02X: %s",i-1,name)
  end
  if #labels==0 then renoise.app():show_warning("No instruments in song.");return end
  feedback.status=vb:multiline_text{id="acid_status",width=FEEDBACK_WIDTH,
    height=FEEDBACK_EMPTY_HEIGHT,font="bold",visible=false,text=""}
  feedback.holder=vb:column{id="acid_feedback",spacing=FEEDBACK_SPACING,visible=false}
  feedback.status_attached=false
  feedback.message=function(issue)
    local args=issue.args or {}
    if issue.key=="save_failed" then return "Your latest edits could not be saved with the song." end
    if issue.key=="previous_save_failed" then
      if issue.context then return "Edits to the previous phrase could not be saved with the song." end
      return "Some edits could not be saved with this song."
    end
    if issue.key=="draft_load_failed" then return "Saved edits could not be loaded. Check the sequence before generating." end
    if issue.key=="destination_unavailable" then return "This phrase is unavailable for editing. Select another phrase." end
    if issue.key=="integrity_blocked" then return "ACID cannot safely update this song." end
    if issue.key=="document_changed" then return "The song changed. Reopen ACID." end
    if issue.key=="generation_failed" then return "Couldn't update the phrase. Try again." end
    if issue.key=="duplicate_failed" then return "Couldn't duplicate the phrase. Try again." end
    if issue.key=="missing_pitch" then return string.format("Cannot generate: choose a pitch for step %d.",args.position) end
    if issue.key=="missing_timing" then return string.format("Cannot generate: enter timing for step %d.",args.position) end
    if issue.key=="entry_unavailable" then return "This entry is no longer available." end
    if issue.key=="entry_destination_changed" then return "Entry was discarded because the destination changed." end
    if issue.key=="clipboard_scope_mismatch" then return "Select the copied scope before pasting." end
    if issue.key=="clipboard_empty" then return "Copy a scope before pasting." end
    if issue.key=="input_failed" then return "The edit could not be applied." end
    if issue.key=="operation_failed" then return "The operation could not be applied. Check its parameters." end
    if issue.key=="label_save_failed" then return "Phrase label could not be saved. Retry or discard the attempt." end
    if issue.key=="label_attempt_stale" then return "The editor changed. Discard this label attempt." end
    if issue.key=="label_editor_open" then return "Resolve the phrase label attempt before editing the source." end
    if issue.key=="audition_start_failed" then return "Could not start the audition." end
    if issue.key=="audition_release_failed" then return "Could not release the auditioned note. It may still be sounding." end
    if issue.key=="scale_load_failed" then return "Custom scales could not be loaded; import is disabled." end
    if issue.key=="scale_read_failed" then return "Could not read the scale file. Select a readable .txt file." end
    if issue.key=="scale_invalid" then return "Invalid scale file. Use Name = intervals with pitch classes 0 to 11, including 0." end
    if issue.key=="scale_empty" then return "The scale file is empty. Add a scale definition before importing." end
    if issue.key=="scale_merge_failed" then return "Scale names conflict. Rename conflicting definitions before importing." end
    if issue.key=="scale_too_large" then return "Use a smaller scale file." end
    if issue.key=="scale_save_failed" then return "Custom scales could not be saved. Import the file again to retry." end
    if issue.key=="scale_save_uncertain" then return "Custom scales could not be verified; import is disabled. Reopen ACID to reload them." end
    if issue.key=="scale_imported" then return string.format("Imported %d scale definitions.",args.count) end
    if issue.key=="phrase_duplicated" then return "Phrase duplicated." end
    if issue.key=="label_saved" then return "Phrase label saved." end
    if issue.key=="phrase_updated" then return "Phrase updated." end
    if issue.key=="phrase_approximate" then return "Phrase updated with a musical approximation." end
    return "The action could not be completed."
  end
  feedback.render=function()
    local messages,seen={},{}
    local function append(issue)
      if not issue then return end
      local message=feedback.message(issue)
      if not seen[message] then
        seen[message]=true
        messages[#messages+1]=message
      end
    end
    if feedback.previous_save_warning then
      append({key="previous_save_failed",context=feedback.previous_save_context})
    end
    for _,slot in ipairs(FEEDBACK_ISSUE_ORDER) do append(feedback.issues[slot]) end
    if #messages==0 and feedback.confirmation then append(feedback.confirmation) end
    feedback.status.text=table.concat(messages,"\n")
    feedback.status.height=#messages>0 and #messages*FEEDBACK_LINE_HEIGHT+FEEDBACK_PADDING or FEEDBACK_EMPTY_HEIGHT
    if #messages>0 and not feedback.status_attached then
      feedback.holder:add_view(feedback.status)
      feedback.status_attached=true
    elseif #messages==0 and feedback.status_attached then
      feedback.holder:remove_view(feedback.status)
      feedback.holder.height=FEEDBACK_EMPTY_HEIGHT
      feedback.status_attached=false
    end
    feedback.status.visible=#messages>0
    feedback.holder.visible=#messages>0
  end
  feedback.set_issue=function(slot,key,args,context)
    local safe_args={}
    if type(args)=="table" then
      for name,value in pairs(args) do
        if type(name)=="string" and type(value)=="number" then safe_args[name]=value end
      end
    end
    local issue_context
    if context~=false then issue_context=context or feedback.context() end
    feedback.issues[slot]={key=key,args=safe_args,context=issue_context}
    feedback.confirmation=nil
    feedback.render()
  end
  feedback.clear_issue=function(slot,context)
    local issue=feedback.issues[slot]
    if not issue then return false end
    if context==false then
      if issue.context~=nil then return false end
    elseif context~=nil and not feedback.same_context(issue.context,context) then
      return false
    end
    feedback.issues[slot]=nil
    feedback.render()
    return true
  end
  feedback.clear_input=function(...)
    local issue=feedback.issues.input
    if not issue then return end
    for _,key in ipairs({...}) do
      if issue.key==key then return feedback.clear_issue("input",feedback.context()) end
    end
  end
  feedback.confirm=function(key,args,context)
    local safe_args={}
    if type(args)=="table" then
      for name,value in pairs(args) do
        if type(name)=="string" and type(value)=="number" then safe_args[name]=value end
      end
    end
    local confirmation_context
    if context~=false then confirmation_context=context or feedback.context() end
    feedback.confirmation={key=key,args=safe_args,context=confirmation_context}
    feedback.render()
  end
  feedback.clear_confirmation=function()
    if not feedback.confirmation then return false end
    feedback.confirmation=nil
    feedback.render()
    return true
  end
  feedback.target_changed=function(before,after)
    if feedback.same_context(before,after) then return false end
    for _,slot in ipairs({"destination","input","generation","approximation"}) do
      local issue=feedback.issues[slot]
      if issue and feedback.same_context(issue.context,before) then feedback.issues[slot]=nil end
    end
    local save_issue=feedback.issues.save
    if save_issue and feedback.same_context(save_issue.context,before) then
      feedback.issues.save=nil
      if not feedback.previous_save_warning then
        feedback.previous_save_warning=true
        feedback.previous_save_context=before
      elseif not feedback.same_context(feedback.previous_save_context,before) then
        feedback.previous_save_context=nil
      end
    end
    feedback.confirmation=nil
    feedback.render()
    return true
  end
  feedback.clear_previous_save=function(context)
    if feedback.previous_save_warning and feedback.previous_save_context and
        feedback.same_context(feedback.previous_save_context,context) then
      feedback.previous_save_warning=false
      feedback.previous_save_context=nil
      feedback.render()
    end
  end
  feedback.request_failure=function(slot,is_duplicate)
    if not current_session() then
      feedback.set_issue("destination","document_changed",nil,feedback.song_context())
      return
    end
    local integrity=runtime:integrity_state()
    local generation=runtime:generation_state()
    if integrity.blocked or generation.blocked then
      feedback.set_issue("destination","integrity_blocked",nil,feedback.song_context())
      return
    end
    local target=runtime:target_projection()
    if target.kind~="owned" and target.kind~="new" then
      feedback.set_issue("destination","destination_unavailable")
      return
    end
    local key=is_duplicate and "duplicate_failed" or
      (slot=="input" and "input_failed" or "generation_failed")
    feedback.set_issue(slot,key)
  end
  feedback.destination_unavailable=function()
    if not current_session() then
      feedback.set_issue("destination","document_changed",nil,feedback.song_context())
      return
    end
    local integrity=runtime:integrity_state()
    local generation=runtime:generation_state()
    if integrity.blocked or generation.blocked then
      feedback.set_issue("destination","integrity_blocked",nil,feedback.song_context())
    else
      feedback.set_issue("destination","destination_unavailable")
    end
  end
  feedback.audition_failed=function(key)
    local issue=feedback.issues.audition
    if not issue or issue.key~="audition_release_failed" then
      feedback.set_issue("audition",key,nil,false)
    end
  end
  local preview=audition.new({song=function() return renoise.song() end,tool=tool,
    on_outcome=function(outcome)
      if outcome.release_error or #(outcome.cleanup_errors or {})>0 then
        feedback.audition_failed("audition_release_failed")
      elseif outcome.onset_error then
        feedback.audition_failed("audition_start_failed")
      elseif not feedback.issues.audition or feedback.issues.audition.key~="audition_release_failed" then
        feedback.clear_issue("audition",false)
      end
    end})
  active_audition=preview
  local function release_audition() preview:release("editor context changed") end
  local audition_button
  local length_items={}
  for n=1,sequencer.MAX_STEPS do length_items[n]=tostring(n) end
  local last_step_box=vb:valuebox{id="acid_last_step",width=78,min=1,max=sequencer.MAX_STEPS,steps={1,8},value=sequencer.PAGE_SIZE,
    tostring=function(value)return string.format("%d",math.floor(value+0.5))end,
    tonumber=function(value)return tonumber(value)end}
  local view_popup=vb:popup{id="acid_editor_view",items={"Program","Grid"},width=105,value=1,
    notifier=function(value)
      if updating then return end
      release_audition()
      editor_view=value
      if stage and value==1 then
        if stage.memory=="pitch" then
          selected_pitch=stage.cursor;pitch_page=editor.page_for(stage.cursor)
        else
          selected_step=stage.cursor;time_page=editor.page_for(stage.cursor)
        end
      end
      update()
    end}
  local view_heading=vb:text{text="PROGRAM VIEW",font="bold"}
  local program_panel,grid_panel
  local ui={program={pitch_selectors={},time_selectors={},pitch_pages={},time_pages={},
      key_buttons={},octave_buttons={}},
    grid={key_buttons={},octave_buttons={}},time_assignment={},time_names={N="Note",T="Tie",R="Rest"},
    workspace={panels={},tabs={}},mask={classes={}}}
  local program_pitch_summary,program_time_summary
  local program_accent,program_slide,program_c_plus,grid_c_plus
  local pitch_length_popup=vb:popup{items=length_items,width=78,value=sequencer.PAGE_SIZE}
  local timing_popup=vb:popup{id="acid_timing",items={"Straight","Triplet"},width=105,value=1}
  local playback_popup=vb:popup{id="acid_output_policy",items={"Play Once","Repeat"},width=105,value=2}
  local pb_range_values=policies.PB_CHOICES
  local pb_range_items={}
  for index,value in ipairs(pb_range_values) do
    pb_range_items[index]=value==0 and "Off" or string.format("±%d",value)
  end
  local pb_range_popup=vb:popup{id="acid_pb_range",items=pb_range_items,width=92,value=1}
  local step_division=vb:text{text="Straight 1/16"}
  local pitch_page_buttons,time_page_buttons={},{}
  local pitch_cells,pitch_headers,pitch_columns,time_cells,time_headers={},{},{},{},{}
  local accent=vb:checkbox{value=false}
  local slide=vb:checkbox{value=false}
  local phrase_choice,phrase_targets
  local apply_pending_selected_phrase_selection
  local native_projection_dirty=false
  local instrument_choice
  local live_checkbox
  local function destination() return runtime:target_projection() end
  local function bound_instrument() return destination().instrument end
  local function bound_phrase() return destination().phrase end
  feedback.context=function()
    local target=runtime and runtime:target_projection() or {}
    local life=runtime and runtime:lifetime_state() or {}
    return {scope="target",song=song,session=life.session,instrument=target.instrument,
      phrase=target.phrase,kind=target.kind,id=target.baseline and target.baseline.id}
  end
  feedback.song_context=function()
    local life=runtime and runtime:lifetime_state() or {}
    return {scope="song",song=song,session=life.session}
  end
  feedback.same_context=function(left,right)
    if not left or not right or left.scope~=right.scope or not rawequal(left.song,right.song) or
        not rawequal(left.session,right.session) then return false end
    if left.scope=="song" then return true end
    local same_object=rawequal(left.phrase,right.phrase)
    local same_phrase=same_object
    if not same_phrase and (left.phrase==nil or right.phrase==nil) then
      same_phrase=left.id~=nil and right.id~=nil and left.id==right.id
    end
    local same_target_kind=(same_object and left.phrase~=nil) or left.kind==right.kind
    return rawequal(left.instrument,right.instrument) and same_phrase and same_target_kind
  end
  local function revision() return runtime:revision_state().edit_revision end
  local function stage_origin()
    local life=runtime:lifetime_state()
    local revisions=runtime:revision_state()
    local target=destination()
    return {song=song,epoch=life.epoch,session=life.session,
      history_revision=history.revision,
      edit_revision=revisions.edit_revision,target_revision=revisions.target_revision,
      operation_serial=revisions.operation_serial,instrument=target.instrument,
      phrase=target.phrase,kind=target.kind,id=target.id}
  end
  local function valid_stage()
    if not stage then return false end
    local current=stage_origin()
    for _,key in ipairs(STAGE_ORIGIN_FIELDS) do
      if not rawequal(current[key],stage.origin[key]) then return false end
    end
    return current_session()
  end
  local function missing_positions()
    local missing={}
    if stage then for _,position in ipairs(stage.target_positions) do
      if not stage.entered[position] then
        missing[#missing+1]=string.format(stage.memory=="pitch" and "P%02d" or "T%02d",position)
      end
    end end
    return missing
  end
  local function first_missing_position()
    if stage then
      for _,position in ipairs(stage.target_positions) do
        if not stage.entered[position] then return position end
      end
    end
  end
  local function refresh_entry_issue()
    local issue=feedback.issues.input
    if not stage or not issue then return end
    local key=stage.memory=="pitch" and "missing_pitch" or "missing_timing"
    if issue.key~=key then return end
    local position=first_missing_position()
    if position then feedback.set_issue("input",key,{position=position})
    else feedback.clear_input(key) end
  end
  local function set_projection_issue(error_info)
    if type(error_info.pitch_index)=="number" then
      feedback.set_issue("input","missing_pitch",{position=error_info.pitch_index})
    elseif type(error_info.step)=="number" then
      feedback.set_issue("input","missing_timing",{position=error_info.step})
    else
      feedback.set_issue("input","input_failed")
    end
  end
  local projected_revision,cached_projection,projected_instrument,projected_phrase
  local function invalidate_projection()
    cached_projection=nil
  end
  local function project()
    if not cached_projection or projected_revision~=revision() or
        not rawequal(projected_instrument,bound_instrument()) or
        not rawequal(projected_phrase,bound_phrase()) then
      local snapshot=runtime:editor_state()
      cached_projection=editor.project(pattern,snapshot and snapshot.prepared_resolution)
      cached_projection.resolved_records=snapshot and snapshot.prepared_resolution and
        snapshot.prepared_resolution.resolved_records
      projected_revision=revision()
      projected_instrument,projected_phrase=bound_instrument(),bound_phrase()
    end
    return cached_projection
  end
  local function clear_resolved_input()
    if not stage and not project().error then
      feedback.clear_input("missing_pitch","missing_timing","entry_unavailable","entry_destination_changed")
    end
  end
  local function stage_resolution()
    if not stage.prepared_resolution then
      stage.prepared_resolution=assert(sequencer.prepare_resolution(stage.candidate))
    end
    return stage.prepared_resolution
  end
  local render
  local rendered=setmetatable({},{__mode="k"})
  local function same_render_value(left,right)
    local left_type,right_type=type(left),type(right)
    if left_type=="table" or left_type=="userdata" or
        right_type=="table" or right_type=="userdata" then
      if rawequal(left,right) then return true end
    elseif left==right then return true end
    if type(left)~="table" or type(right)~="table" then return false end
    local length=#right
    if #left~=length then return false end
    for index=1,length do if left[index]~=right[index] then return false end end
    local keys=0
    for key in pairs(left) do
      if type(key)~="number" or key<1 or key>length or key%1~=0 then return false end
      keys=keys+1
    end
    return keys==length
  end
  local function retain_render_value(value)
    if type(value)~="table" then return value end
    local copy={}
    for key,item in pairs(value) do copy[key]=item end
    return copy
  end
  local function save_draft(kind)
    local context=feedback.context()
    local state,effects=runtime:transition(kind or "edit",{
      source=pattern,output_policy=output_policy,pb_range=pb_range,
      label=phrase_label,label_custom=phrase_label_custom})
    if not state then
      feedback.set_issue("save","save_failed",nil,context)
      return false,effects or "Editor state transition failed"
    end
    if not bound_instrument() then return true,nil,effects end
    local saved=not state.draft_warning
    if saved then
      feedback.clear_issue("save",context)
      feedback.clear_previous_save(context)
    else
      feedback.set_issue("save","save_failed",nil,context)
    end
    return saved,state.draft_warning,effects
  end
  local loading=false
  local function default_pitch()
    return sequencer.new_pitch(0,0,false,false)
  end
  local function pitch_at(index)
    return edit_source().pitch_events[index] or default_pitch()
  end
  local function same_pitch(left,right)
    return left and right and left.note==right.note and left.key==right.key and
      left.octave==right.octave and left.accent==right.accent and left.slide==right.slide
  end
  local function pitch_indicator(index,projection)
    local pitch=pattern.pitch_events[index]
    local baseline=accepted_pitch_baseline and accepted_pitch_baseline.pitch_events[index]
    return "STORED"..(projection.used[index] and " | REFERENCED" or " | NOT REFERENCED")..
      (same_pitch(pitch,baseline) and " | UNMODIFIED" or " | MODIFIED")
  end
  local function view_label(index,p,projection)
    if index>#pattern.pitch_events then return string.format("P%02d --",index) end
    local _,octave=sequencer.pitch_controls(p)
    local pitch_name=p.note==60 and "C+" or keys[(p.note%12)+1]
    local markers="S"..(projection.used[index] and "R" or "-")..
      (accepted_pitch_baseline and not same_pitch(p,accepted_pitch_baseline.pitch_events[index]) and "M" or "-")
    return string.format("P%02d %s%d/%d%s%s %s%s",index,pitch_name,p.note,p.key,
      octave and ((octave<0 and "-" or "+")..math.abs(octave)) or "?",
      p.accent and " A" or "",p.slide and " S" or "",markers,
      index>pattern.pitch_length and " i" or "")
  end
  local function grid_pitch_header(index)
    return string.format("P%02d%s",index,index>pattern.pitch_length and " (inactive)" or "")
  end
  local function grid_pitch_value(index,p)
    if index>#pattern.pitch_events then return "--" end
    local records=project().resolved_records
    local note=records and records[index] and records[index].note
    return string.format("%s%s%s",note and
      (keys[note%12+1]..tostring(math.floor(note/12))) or "--",
      p.accent and " ACC" or "",p.slide and " SLD" or "")
  end
  render=function(view,property,value)
    if property~="value" and not (rawequal(view,feedback.status) and property=="text") then
      local cache=rendered[view]
      if cache then
        local previous=cache[property]
        if previous~=nil then
          if same_render_value(previous,value) then return end
          view[property]=value
          cache[property]=retain_render_value(value)
          return
        end
      else
        cache={};rendered[view]=cache
      end
    end
    local current=view[property]
    local equal=same_render_value(current,value)
    if not equal then view[property]=value end
    if property~="value" and not (rawequal(view,feedback.status) and property=="text") then
      local cache=rendered[view]
      if not cache then cache={};rendered[view]=cache end
      cache[property]=retain_render_value(value)
    end
  end
  refresh_stage=function()
    if label_ui.display then render(label_ui.display,"text",phrase_label) end
    if audition_button then render(audition_button,"active",current_session() and
      (not stage or (stage.memory=="pitch" and valid_stage()))) end
    if stage_status then
      render(stage_status,"visible",stage~=nil)
      render(entry_navigation,"visible",stage~=nil)
      local missing=missing_positions()
      render(stage_status,"text",stage and (editor_view==2 and
        "Program entry staged; return to Program to finish or discard" or
        string.upper(stage.memory).." CANDIDATE | "..(#missing==0 and "All positions entered" or
          "Missing: "..table.concat(missing,", "))) or "Edit One | canonical source")
      render(stage_actions.back,"active",stage~=nil)
      render(stage_actions.enter,"active",stage~=nil)
      render(stage_actions.restart,"active",stage~=nil)
      render(stage_actions.finish,"active",stage~=nil and #missing==0)
      render(stage_actions.discard,"active",stage~=nil)
    end
  end
  update=function()
    updating=true
    local projection=project()
    refresh_stage()
    if clipboard.choice then
      local scope=clipboard.scopes[clipboard.choice.value]
      render(clipboard.paste_button,"active",clipboard.payload~=nil and clipboard.scope==scope)
      render(clipboard.status,"text",clipboard.payload and string.format("Captured %s | %s%s%s",
        clipboard.names[clipboard.scope],
        clipboard.payload.pitch_length and ("PITCH span "..clipboard.payload.pitch_length) or "",
        clipboard.payload.pitch_length and clipboard.payload.length and " | " or "",
        clipboard.payload.length and ("LAST STEP "..clipboard.payload.length) or "") or "Clipboard empty")
    end
    render(view_heading,"text",editor_view==1 and "PROGRAM VIEW" or "GRID VIEW")
    if program_panel then render(program_panel,"visible",editor_view==1) end
    if grid_panel then render(grid_panel,"visible",editor_view==2) end
    render(pitch_length_popup,"value",pattern.pitch_length or sequencer.PAGE_SIZE)
    render(pitch_length_popup,"active",true)
    render(timing_popup,"value",pattern.timing_mode=="triplet" and 2 or 1)
    render(step_division,"text",pattern.timing_mode=="triplet" and
      string.format("1/8 triplet; cycle %d/3 beats",pattern.length) or
      string.format("1/16 straight; cycle %d/4 beats",pattern.length))
    render(playback_popup,"value",output_policy=="play_once" and 1 or 2)
    render(playback_popup,"active",true)
    for index,value in ipairs(pb_range_values) do
      if value==pb_range then render(pb_range_popup,"value",index);break end
    end
    render(pb_range_popup,"active",true)
    if undo_button then render(undo_button,"active",stage~=nil or history:can_undo()) end
    if redo_button then render(redo_button,"active",stage~=nil or history:can_redo()) end
    render(last_step_box,"value",pattern.length)
    render(last_step_box,"active",true)
    if editor_view==2 then
      for page=1,editor.MAX_PAGES do
        local first=(page-1)*sequencer.PAGE_SIZE+1
        render(pitch_page_buttons[page],"text",string.format("P %02d-%02d%s",
          first,page*sequencer.PAGE_SIZE,page==pitch_page and " [*]" or ""))
        render(time_page_buttons[page],"text",string.format("T %02d-%02d%s",
          first,page*sequencer.PAGE_SIZE,page==time_page and " [*]" or ""))
        render(time_page_buttons[page],"active",true)
      end
    end
    if editor_view==2 then for cell=1,sequencer.PAGE_SIZE do
      local i=editor.index_on_page(pitch_page,cell)
      local p=pitch_at(i)
      local b=pitch_cells[cell]
      render(b,"active",true)
      render(pitch_headers[cell],"text",grid_pitch_header(i))
      render(b,"text",grid_pitch_value(i,p))
      render(b,"tooltip",view_label(i,p,projection)..string.format(
        " | note=%d key=%d octave=%+d accent=%s slide=%s",p.note,p.key,p.octave,
        tostring(p.accent),tostring(p.slide)))
      render(b,"color",i==selected_pitch and colors.selected or
        (i>pattern.pitch_length and colors.inactive or
          (projection.used[i] and colors.used or colors.idle)))
      local step=editor.index_on_page(time_page,cell)
      local time=time_cells[cell]
      local time_header=time_headers[cell]
      local cmd=pattern.time_events[step]
      render(time,"active",true)
      render(time,"text",string.format("%02d %s%s",step,ui.time_names[cmd],
        step>pattern.length and " *" or ""))
      render(time,"color",projection.error and projection.error.step==step
        and colors.warning or (step==selected_step and colors.selected)
        or (cmd=="N" and colors.note or cmd=="T" and colors.tie or colors.rest))
      render(time_header,"text",step>pattern.length and "INACTIVE" or "TIME")
      render(time_header,"style",step>pattern.length and "disabled" or "strong")
    end end
    if editor_view==2 then
      render(accent,"active",stage==nil)
      render(slide,"active",stage==nil)
      for _,button in ipairs(ui.grid.key_buttons) do render(button,"active",stage==nil) end
      for _,button in ipairs(ui.grid.octave_buttons) do render(button,"active",stage==nil) end
    end
    local p=pitch_at(selected_pitch)
    local key,octave=sequencer.pitch_controls(p)
    local records=stage and editor_view==1 and stage_resolution().resolved_records or
      projection.resolved_records
    key=records and records[selected_pitch] and records[selected_pitch].note%12
    if editor_view==2 then
      for key_index,button in ipairs(ui.grid.key_buttons) do
        render(button,"color",key==key_index-1 and colors.selected or
          (pattern.scale_mask_enabled and pattern.scale_mask[key_index] and colors.used or colors.idle))
      end
      for octave_index,button in ipairs(ui.grid.octave_buttons) do
        render(button,"color",octave==octave_index-2 and colors.selected or colors.idle)
      end
      render(accent,"value",p.accent==true)
      render(slide,"value",p.slide==true)
    end
    if program_pitch_summary and editor_view==1 then
      for cell,button in ipairs(ui.program.pitch_selectors) do
        local index=editor.index_on_page(pitch_page,cell)
        render(button,"text",string.format("P%02d%s",index,
          stage and stage.memory=="pitch" and stage.entered[index] and " +" or ""))
        render(button,"active",not stage or stage.memory~="pitch" or index<=#stage.target_positions)
        render(button,"color",index==selected_pitch and colors.selected or colors.idle)
      end
      for cell,button in ipairs(ui.program.time_selectors) do
        local index=editor.index_on_page(time_page,cell)
        local command=(stage and stage.candidate or pattern).time_events[index]
        render(button,"text",string.format("%02d %s%s",index,ui.time_names[command],
          stage and stage.memory=="time" and stage.entered[index] and " +" or
          (index>pattern.length and " *" or "")))
        render(button,"active",not stage or stage.memory~="time" or index<=#stage.target_positions)
        render(button,"color",index==selected_step and colors.selected or
          (index>pattern.length and colors.inactive or
            (command=="N" and colors.note or command=="T" and colors.tie or colors.rest)))
      end
      for page=1,editor.MAX_PAGES do
        render(ui.program.pitch_pages[page],"color",page==pitch_page and colors.selected or colors.idle)
        render(ui.program.time_pages[page],"color",page==time_page and colors.selected or colors.idle)
      end
      render(program_pitch_summary,"text",string.format("P%02d: %s",selected_pitch,
        records and records[selected_pitch] and
          (keys[records[selected_pitch].note%12+1]..tostring(math.floor(records[selected_pitch].note/12))) or "Unavailable"))
      render(program_pitch_summary,"tooltip",view_label(selected_pitch,p,projection).." | "..
        pitch_indicator(selected_pitch,projection))
      render(program_time_summary,"text",string.format("TIME %02d: %s%s",
        selected_step,ui.time_names[(stage and stage.candidate or pattern).time_events[selected_step]],
        selected_step>pattern.length and " (inactive)" or ""))
      for key_index,button in ipairs(ui.program.key_buttons) do
        render(button,"color",key==key_index-1 and colors.selected or
          (pattern.scale_mask_enabled and pattern.scale_mask[key_index] and colors.used or colors.idle))
      end
      for octave_index,button in ipairs(ui.program.octave_buttons) do
        render(button,"color",octave==octave_index-2 and colors.selected or colors.idle)
      end
      render(program_accent,"value",p.accent==true)
      render(program_slide,"value",p.slide==true)
      render(program_c_plus,"active",p.octave==1)
      render(program_c_plus,"color",p.note==60 and colors.selected or colors.idle)
      local pitch_active=not stage or (stage.memory=="pitch" and selected_pitch<=#stage.target_positions)
      for _,button in ipairs(ui.program.key_buttons) do render(button,"active",pitch_active) end
      for _,button in ipairs(ui.program.octave_buttons) do render(button,"active",pitch_active) end
      render(program_accent,"active",pitch_active)
      render(program_slide,"active",pitch_active)
      render(program_c_plus,"active",pitch_active and p.octave==1)
    end
    if editor_view==2 then
      render(grid_c_plus,"active",stage==nil and p.octave==1)
      render(grid_c_plus,"color",p.note==60 and colors.selected or colors.idle)
    end
    for index,button in ipairs(ui.time_assignment) do
      render(button,"color",(stage and stage.candidate or pattern).time_events[selected_step]==({"N","T","R"})[index]
        and colors.selected or colors.idle)
      render(button,"active",selected_step<=pattern.length and (not stage or
        (editor_view==1 and stage.memory=="time" and selected_step<=#stage.target_positions)))
    end
    for tab,panel in ipairs(ui.workspace.panels) do
      render(panel,"visible",tab==workspace_tab)
      render(ui.workspace.tabs[tab],"color",tab==workspace_tab and colors.selected or colors.idle)
    end
    if ui.mask.enabled then
      render(ui.mask.enabled,"value",pattern.scale_mask_enabled)
      render(ui.mask.enabled,"active",stage==nil)
      for index,control in ipairs(ui.mask.classes) do
        render(control,"value",pattern.scale_mask[index]);render(control,"active",stage==nil)
      end
      for _,control in ipairs(ui.operation_controls) do render(control,"active",stage==nil) end
    end
    if scale_state.refresh then scale_state.refresh() end
    if ui.refresh_random then ui.refresh_random() end
    updating=false
  end
  local function choose_pitch(index)
    release_audition()
    if stage and not valid_stage() then return end
    if stage and editor_view==1 and stage.memory=="pitch" then
      if index>#stage.target_positions then return end
      stage.cursor=index
    end
    selected_pitch=index
    pitch_page=editor.page_for(index)
    update()
  end
  local function choose_time(index)
    release_audition()
    if stage and not valid_stage() then return end
    if stage and editor_view==1 and stage.memory=="time" then
      if index>#stage.target_positions then return end
      stage.cursor=index
    end
    selected_step=index
    time_page=editor.page_for(index)
    update()
  end
  local function changed(request_live)
    if not history:record(pattern,output_policy,pb_range,phrase_label,phrase_label_custom) then update();return end
    feedback.clear_confirmation()
    local _,_,effects=save_draft(request_live==false and "reset" or "edit")
    invalidate_projection()
    update()
    clear_resolved_input()
    if effects and effects.live_intent and current_session() then
      runtime:flush_pending()
    end
  end
  finish_stage=function()
    release_audition()
    if not stage then return false end
    if not valid_stage() then feedback.set_issue("input","entry_unavailable");return false end
    local eligible=runtime:musical_eligibility()
    if not eligible then feedback.request_failure("input",false);return false end
    local missing=missing_positions()
    if #missing>0 then
      feedback.set_issue("input",stage.memory=="pitch" and "missing_pitch" or "missing_timing",
        {position=first_missing_position()})
      return false
    end
    local valid=sequencer.validate(stage.candidate)
    if not valid then feedback.set_issue("input","input_failed");return false end
    local candidate=stage.candidate
    if sequencer.same_source(candidate,pattern) then
      stage=nil;clear_resolved_input();update();return true
    end
    pattern=assert(sequencer.copy_source(candidate))
    stage=nil
    feedback.clear_input("input_failed")
    changed()
    return true
  end
  guard_stage=function()
    release_audition()
    if label_ui.attempt or (label_ui.dialog and label_ui.dialog.visible) then
      feedback.set_issue("input","label_editor_open")
      if label_ui.dialog and label_ui.dialog.visible then label_ui.dialog:show()
      elseif label_ui.attempt then label_ui.show(label_ui.attempt) end
      return true
    end
    if not stage then return false end
    if not valid_stage() then
      stage=nil;update();feedback.set_issue("input","entry_unavailable");return true
    end
    local missing=missing_positions()
    if #missing>0 then
      feedback.set_issue("input",stage.memory=="pitch" and "missing_pitch" or "missing_timing",
        {position=first_missing_position()})
    end
    local buttons=#missing==0 and {"Stay","Discard","Finish"} or {"Stay","Discard"}
    local answer=renoise.app():show_prompt("Program entry staged",
      #missing==0 and "Resolve entry, then invoke the requested action again." or
        string.format("Complete %s step %d before continuing.",stage.memory=="pitch" and "pitch" or "timing",
          first_missing_position()),buttons)
    if answer=="Finish" and #missing==0 then finish_stage()
    elseif answer=="Discard" then stage=nil;clear_resolved_input();update() end
    update()
    return true
  end
  local function begin_stage(memory)
    if guard_stage() then return end
    local eligible=runtime:musical_eligibility()
    if not eligible then feedback.request_failure("input",false);return end
    local origin=stage_origin()
    local count=memory=="pitch" and pattern.pitch_length or pattern.length
    local positions={}
    for index=1,count do positions[index]=string.format(memory=="pitch" and "P%02d" or "T%02d",index) end
    local answer=renoise.app():show_prompt("Re-enter "..string.upper(memory),
      table.concat(positions,", ")..(memory=="pitch" and
        ": C/NORMAL, ACCENT off, SLIDE off. All other positions and TIME preserved." or
        ": NOTE. All other positions and PITCH flags preserved."),{"Cancel","Proceed"})
    if answer~="Proceed" then return end
    stage={memory=memory,candidate=assert(sequencer.copy_source(pattern)),
      target_positions={},entered={},cursor=1,origin=origin}
    if not valid_stage() then stage=nil;feedback.set_issue("input","entry_unavailable");return end
    for index=1,count do
      stage.target_positions[index]=index
      stage.entered[index]=false
      if memory=="pitch" then stage.candidate.pitch_events[index]=default_pitch()
      else stage.candidate.time_events[index]="N" end
    end
    if memory=="pitch" then choose_pitch(1) else choose_time(1) end
    update()
  end
  local function candidate_edit(memory,position)
    if label_ui.attempt or (label_ui.dialog and label_ui.dialog.visible) then
      feedback.set_issue("input","label_editor_open")
      return false
    end
    if not stage then return true end
    if not valid_stage() then feedback.set_issue("input","entry_unavailable");return false end
    return editor_view==1 and stage.memory==memory and position<=#stage.target_positions
  end
  timing_popup:add_notifier(function(value)
    if updating then return end
    if guard_stage() then update();return end
    pattern.timing_mode=value==2 and "triplet" or "straight"
    changed()
  end)
  playback_popup:add_notifier(function(value)
    if updating then return end
    if guard_stage() then update();return end
    output_policy=value==2 and "repeat" or "play_once"
    changed()
  end)
  pb_range_popup:add_notifier(function(value)
    if updating then return end
    if guard_stage() then update();return end
    pb_range=pb_range_values[value] or policies.DEFAULT_PB_RANGE
    changed()
  end)
  local function write_pitch(key,octave,is_accent,is_slide,note_entry)
    if updating then return end
    release_audition()
    if not candidate_edit("pitch",selected_pitch) then update();return end
    local current=pitch_at(selected_pitch)
    local candidate=sequencer.new_pitch(key,octave,is_accent,is_slide)
    if scale_state.follow and note_entry then
      candidate=assert(sequencer.constrain_pitch(edit_source(),candidate))
    end
    if same_pitch(current,candidate) then return end
    edit_source().pitch_events[selected_pitch]=candidate
    if stage then stage.prepared_resolution=nil;stage.entered[selected_pitch]=false;refresh_entry_issue();update() else changed() end
  end
  local function choose_key(key)
    local pitch=pitch_at(selected_pitch)
    write_pitch(key,pitch.octave,pitch.accent,pitch.slide,true)
  end
  local function choose_octave(octave)
    local pitch=pitch_at(selected_pitch)
    write_pitch(pitch.note%12,octave,pitch.accent,pitch.slide,true)
  end
  local function choose_c_plus()
    release_audition()
    if updating or not candidate_edit("pitch",selected_pitch) then return end
    local pitch=pitch_at(selected_pitch)
    if pitch.octave~=1 then return end
    local candidate=sequencer.new_pitch(12,1,pitch.accent,pitch.slide)
    if scale_state.follow then candidate=assert(sequencer.constrain_pitch(edit_source(),candidate)) end
    if same_pitch(pitch,candidate) then return end
    edit_source().pitch_events[selected_pitch]=candidate
    if stage then stage.prepared_resolution=nil;stage.entered[selected_pitch]=false;refresh_entry_issue();update() else changed() end
  end
  local function set_time_command(command)
    release_audition()
    if updating or not candidate_edit("time",selected_step) then return end
    if selected_step>pattern.length then return end
    local source=edit_source()
    local previous=source.time_events[selected_step]
    local result=sequencer.set_time(source,selected_step,command)
    if not result then feedback.set_issue("input","input_failed");return end
    if previous~=result then
      if stage then stage.prepared_resolution=nil;stage.entered[selected_step]=false;refresh_entry_issue();update() else changed() end
    else update() end
  end
  for index,key_name in ipairs(keys) do
    local key=index-1
    local program=vb:button{id=string.format("acid_program_key_%02d",index),
      text=key_name,width=38,notifier=function() choose_key(key) end}
    local grid=vb:button{id=string.format("acid_grid_key_%02d",index),text=key_name,width=38,
      notifier=function() choose_key(key) end}
    ui.program.key_buttons[index]=program
    ui.grid.key_buttons[index]=grid
  end
  for index=1,3 do
    local octave=index-2
    local label=({"DOWN","NORMAL","UP"})[index]
    local octave_id=octave==-1 and "down" or octave==0 and "normal" or "up"
    ui.program.octave_buttons[index]=vb:button{id="acid_program_octave_"..octave_id,
      text=label,width=64,notifier=function() choose_octave(octave) end}
    ui.grid.octave_buttons[index]=vb:button{id="acid_grid_octave_"..octave_id,
      text=label,width=64,notifier=function() choose_octave(octave) end}
  end
  program_accent=vb:checkbox{id="acid_program_accent",value=false,notifier=function(value)
    if updating then return end
    local pitch=pitch_at(selected_pitch)
    write_pitch(pitch.key,pitch.octave,value,pitch.slide)
  end}
  program_slide=vb:checkbox{id="acid_program_slide",value=false,notifier=function(value)
    if updating then return end
    local pitch=pitch_at(selected_pitch)
    write_pitch(pitch.key,pitch.octave,pitch.accent,value)
  end}
  accent:add_notifier(function(value)
    if updating then return end
    local pitch=pitch_at(selected_pitch)
    write_pitch(pitch.key,pitch.octave,value,pitch.slide)
  end)
  slide:add_notifier(function(value)
    if updating then return end
    local pitch=pitch_at(selected_pitch)
    write_pitch(pitch.key,pitch.octave,pitch.accent,value)
  end)
  for cell=1,sequencer.PAGE_SIZE do
    local position=cell
    ui.program.pitch_selectors[cell]=vb:button{id=string.format("acid_program_select_pitch_%02d",cell),width=45,text="P",notifier=function()
      choose_pitch(editor.index_on_page(pitch_page,position))
    end}
    ui.program.time_selectors[cell]=vb:button{id=string.format("acid_program_select_time_%02d",cell),width=94,text="TIME",notifier=function()
      choose_time(editor.index_on_page(time_page,position))
    end}
  end
  for page=1,editor.MAX_PAGES do
    local selected_page=page
    local page_start=(page-1)*sequencer.PAGE_SIZE+1
    ui.program.pitch_pages[page]=vb:button{id="acid_program_pitch_page_"..page,
      text=string.format("P %02d-%02d",page_start,page*sequencer.PAGE_SIZE),width=86,notifier=function()
      release_audition();pitch_page=selected_page
      update()
    end}
    ui.program.time_pages[page]=vb:button{id="acid_program_time_page_"..page,
      text=string.format("T %02d-%02d",page_start,page*sequencer.PAGE_SIZE),width=86,notifier=function()
      release_audition();time_page=selected_page
      update()
    end}
  end
  program_pitch_summary=vb:text{id="acid_program_pitch_summary",size={width=820,height=18},text="P01",font="bold"}
  program_time_summary=vb:text{id="acid_program_time_summary",size={width=820,height=18},text="TIME 01",font="bold"}
  program_c_plus=vb:button{id="acid_program_c_plus",text="C+ / MIDI 60",width=120,
    notifier=choose_c_plus}
  grid_c_plus=vb:button{text="C+ / MIDI 60",width=120,notifier=choose_c_plus}
  for choice,command in ipairs({"N","T","R"}) do
    local labels={"NOTE","TIE","REST"}
    ui.time_assignment[choice]=vb:button{text=labels[choice],width=76,notifier=function()
      set_time_command(command)
    end}
  end
  local pitch_grid=vb:column{spacing=4}
  local time_grid=vb:column{spacing=4}
  local pitch_pages=vb:row{spacing=6}
  local time_pages=vb:row{spacing=6}
  for p=1,editor.MAX_PAGES do
    local page=p
    pitch_page_buttons[p]=vb:button{id="acid_pitch_page_"..p,size={width=155,height=22},text="P",notifier=function()
      release_audition();pitch_page=page;update() end}
    time_page_buttons[p]=vb:button{id="acid_time_page_"..p,size={width=155,height=22},text="T",notifier=function()
      release_audition();time_page=page;update() end}
    pitch_pages:add_child(pitch_page_buttons[p])
    time_pages:add_child(time_page_buttons[p])
  end
  local grid_columns=sequencer.PAGE_SIZE/2
  for row=1,2 do
    local p_row=vb:row{spacing=4}
    local t_row=vb:row{spacing=4}
    for col=1,grid_columns do
      local cell=(row-1)*grid_columns+col
      pitch_headers[cell]=vb:text{id=string.format("acid_grid_pitch_header_%02d",cell),
        size={width=98,height=18},text="P"}
      pitch_cells[cell]=vb:button{id=string.format("acid_grid_pitch_%02d",cell),
        size={width=98,height=20},text="--",notifier=function()
        choose_pitch(editor.index_on_page(pitch_page,cell)) end}
      pitch_columns[cell]=vb:column{id=string.format("acid_grid_pitch_column_%02d",cell),
        size={width=98,height=38},spacing=0,pitch_headers[cell],pitch_cells[cell]}
      time_headers[cell]=vb:text{size={width=98,height=22},text="TIME"}
      time_cells[cell]=vb:button{id=string.format("acid_grid_select_time_%02d",cell),
        size={width=98,height=30},text="--",notifier=function()
          choose_time(editor.index_on_page(time_page,cell))
      end}
      p_row:add_child(pitch_columns[cell])
      t_row:add_child(vb:column{spacing=2,time_headers[cell],time_cells[cell]})
    end
    pitch_grid:add_child(p_row)
    time_grid:add_child(t_row)
  end
  last_step_box:add_notifier(function(n)
    if updating then return end
    if guard_stage() then update();return end
    n=tonumber(n)
    if not n then update();return end
    n=math.max(1,math.min(sequencer.MAX_STEPS,math.floor(n+0.5)))
    pattern.length=n
    changed()
  end)
  pitch_length_popup:add_notifier(function(value)
    if updating then return end
    if guard_stage() then update();return end
    local ok=sequencer.set_pitch_length(pattern,tonumber(value))
    if not ok then feedback.set_issue("input","input_failed") end
    if ok then changed() else update() end
  end)
  local deliver
  if not active_runtime then
    active_runtime=runtime_context.new({writer=phrase_writer,capture=function() return nil,"No editor source" end,
      sink=function(request,done)
        local origin=request.origin or {}
        local baseline=origin.baseline or {}
        feedback_request_contexts[request]={scope="target",song=request.song,session=request.session,
          instrument=request.instrument,phrase=request.operation=="duplicate" and nil or request.phrase,
          kind=request.operation=="duplicate" and "owned" or request.target_kind,
          id=request.operation=="duplicate" and baseline.id or request.id}
        if request.kind=="create" then
          if type(phrase_writer.create)~="function" then return false,"Explicit writer create is unavailable" end
          return phrase_writer.create(request,done)
        elseif request.kind=="regenerate" then
          if type(phrase_writer.regenerate)~="function" then return false,"Explicit writer regenerate is unavailable" end
          return phrase_writer.regenerate(request,done)
        end
        return false,"Request has no explicit writer operation"
      end,
      cancel=function(token,reason)
        if type(phrase_writer.cancel)~="function" then return false end
        return phrase_writer.cancel(token,reason)
      end,drafts=drafts})
  end
  runtime=active_runtime
  if not rawequal(attached_song,song) or not runtime:lifetime_state().song_attached then
    runtime:attach_document(song)
    attached_song=song
  end
  session=runtime:open_dialog(function(result) deliver(result.request,result) end)
  local function options_for_instrument()
    local instrument=instrument_targets[selected_instrument]
    local choices=runtime:phrase_choices(instrument) or {}
    local names,targets={},{}
    for _,choice in ipairs(choices) do
      if choice.kind~="new" then
        local ok,id=pcall(ownership.id,choice.phrase)
        local identity=ok and id and "tagged" or "foreign"
        names[#names+1]=string.format("%02d: %s (%s)",choice.phrase_index,
          choice.phrase_name,identity)
        targets[#targets+1]=choice.phrase
      end
    end
    names[#names+1]="NEW PHRASE (append)"
    targets[#targets+1]=false
    return names,targets
  end
  local function load_target(index,native_selection)
    release_audition()
    if label_ui.attempt or (label_ui.dialog and label_ui.dialog.visible) then return end
    if stage then
      if not native_selection then if guard_stage() then update();return end
      else stage=nil end
    end
    local instrument=instrument_targets[selected_instrument]
    local target=phrase_targets[index]
    if target==nil then return end
    local is_new=target==false
    local requested_phrase
    if not is_new then requested_phrase=target end
    local previous_context=feedback.context()
    local restored=runtime:restore_editor_target(instrument,requested_phrase,
      native_selection==true)
    feedback.target_changed(previous_context,feedback.context())
    local source_available=false
    if restored and type(restored.source)=="table" then
      pattern=restored.source
      output_policy=restored.output_policy
      pb_range=restored.pb_range or policies.DEFAULT_PB_RANGE
      phrase_label=restored.label or "Untitled"
      phrase_label_custom=restored.label_custom==true
      source_available=restored.source_available==true
      accepted_pitch_baseline=assert(sequencer.copy_source(pattern))
      selected_pitch=1;selected_step=1
      pitch_page=1;time_page=1
      if restored.draft_error then
        if runtime:integrity_state().blocked or runtime:generation_state().blocked then
          feedback.destination_unavailable()
        else
          feedback.set_issue("destination","draft_load_failed")
        end
      elseif not source_available and not is_new then
        feedback.destination_unavailable()
      elseif source_available then
        feedback.clear_issue("destination",feedback.context())
      end
    else
      reset_source()
      accepted_pitch_baseline=assert(sequencer.copy_source(pattern))
      feedback.destination_unavailable()
    end
    history:reset(pattern,output_policy,pb_range,phrase_label,phrase_label_custom)
    update()
  end
  local phrase_names
  phrase_names,phrase_targets=options_for_instrument()
  phrase_choice=vb:popup{width=360,items=phrase_names,
    value=#phrase_names,notifier=function(n)
      if not loading then
        if guard_stage() then
          loading=true
          for index,phrase in ipairs(phrase_targets) do
            if rawequal(phrase,bound_phrase()) or (phrase==false and not bound_phrase()) then
              render(phrase_choice,"value",index);break
            end
          end
          loading=false
          return
        end
        load_target(n)
      end
    end}
  local function select_instrument(n)
    if guard_stage() then loading=true;render(instrument_choice,"value",selected_instrument);loading=false;return end
    selected_instrument=n
    local options
    options,phrase_targets=options_for_instrument()
    loading=true
    render(phrase_choice,"items",options)
    local chosen=#options
    local instrument=instrument_targets[n]
    local current_phrase=rawequal(song.selected_instrument,instrument) and
      song.selected_phrase or nil
    if current_phrase then
      for index,phrase in ipairs(phrase_targets) do
        if rawequal(phrase,current_phrase) then
          chosen=index
          break
        end
      end
    end
    render(phrase_choice,"value",chosen)
    loading=false
    load_target(chosen)
  end
  local function refresh_phrase_choices(preferred_target)
    local options,targets=options_for_instrument()
    local wanted=preferred_target or bound_phrase()
    local chosen=#options
    local found=false
    if wanted then
      for index,candidate in ipairs(targets) do
        if rawequal(candidate,wanted) then chosen=index;found=true;break end
      end
      if not found then
        table.insert(options,#options,"Unavailable bound phrase")
        table.insert(targets,#targets,wanted)
        chosen=#options-1
      end
    end
    phrase_targets=targets
    loading=true
    render(phrase_choice,"items",options)
    render(phrase_choice,"value",math.min(chosen,#options))
    loading=false
  end
  local function refresh_native_choices()
    local choices=runtime:instrument_choices() or {}
    local names,targets={},{}
    local wanted=bound_instrument()
    local chosen
    for _,choice in ipairs(choices) do
      targets[#targets+1]=choice.instrument
      names[#names+1]=string.format("%02X: %s",choice.instrument_index-1,choice.instrument_name)
      if rawequal(choice.instrument,wanted) then chosen=#targets end
    end
    if not chosen then
      targets[#targets+1]=wanted or false
      names[#names+1]="Unavailable bound instrument"
      chosen=#targets
    end
    instrument_targets=targets
    selected_instrument=chosen
    loading=true
    render(instrument_choice,"items",names)
    render(instrument_choice,"value",chosen)
    loading=false
    refresh_phrase_choices(bound_phrase())
  end
  local function reconcile_selected_phrase_selection()
    if not current_session() then return false end
    if label_ui.attempt or (label_ui.dialog and label_ui.dialog.visible) then return false end
    if native_projection_dirty then native_observers:refresh() end
    local before=destination()
    local before_feedback=feedback.context()
    local target,effects=runtime:reconcile()
    feedback.target_changed(before_feedback,feedback.context())
    if stage and not valid_stage() then
      stage=nil
      update()
    end
    if native_projection_dirty then
      native_projection_dirty=false
      refresh_native_choices()
      invalidate_projection()
    end
    if target and effects and effects.native_revision_reconciled then
      if target.instrument and not rawequal(instrument_targets[selected_instrument],target.instrument) then
        for index,instrument in ipairs(instrument_targets) do
          if rawequal(instrument,target.instrument) then
            selected_instrument=index
            loading=true
            if instrument_choice then render(instrument_choice,"value",index) end
            loading=false
            break
          end
        end
      end
      if target.phrase then
        refresh_phrase_choices(target.phrase)
        for choice,phrase in ipairs(phrase_targets) do
          if rawequal(phrase,target.phrase) then load_target(choice,true);return true end
        end
      elseif target.kind=="new" then
        refresh_phrase_choices(nil)
        for choice,phrase in ipairs(phrase_targets) do
          if phrase==false then load_target(choice,true);return true end
        end
      end
      feedback.destination_unavailable()
      return false
    end
    if not target or (rawequal(before.instrument,target.instrument) and
        rawequal(before.phrase,target.phrase) and before.kind==target.kind) then return false end
    if target.kind~="owned" then
      if target.phrase then refresh_phrase_choices(target.phrase) end
      feedback.destination_unavailable()
      return false
    end
    if not rawequal(instrument_targets[selected_instrument],target.instrument) then
      for index,instrument in ipairs(instrument_targets) do
        if rawequal(instrument,target.instrument) then
          selected_instrument=index
          loading=true
          if instrument_choice then render(instrument_choice,"value",index) end
          loading=false
          refresh_phrase_choices(target.phrase)
          break
        end
      end
      if not rawequal(instrument_targets[selected_instrument],target.instrument) then
        feedback.destination_unavailable()
        return false
      end
    end
    if target.phrase then
      refresh_phrase_choices(target.phrase)
      for choice,phrase in ipairs(phrase_targets) do
        if rawequal(phrase,target.phrase) then load_target(choice,true);return true end
      end
    end
    feedback.destination_unavailable()
    return false
  end
  apply_pending_selected_phrase_selection=function()
    local staged=stage~=nil
    local changed=reconcile_selected_phrase_selection()
    if staged and not stage then
      feedback.set_issue("input","entry_destination_changed")
      if drafts.has_volatile(song) then
        if not feedback.previous_save_warning then
          feedback.previous_save_warning=true
          feedback.previous_save_context=nil
        end
        feedback.render()
      end
    end
    return changed
  end
  local target=vb:popup{width=290,items=labels,value=selected_instrument,
    notifier=function(n)if not loading then select_instrument(n) end end}
  instrument_choice=target
  deliver=function(request,result)
    if type(request)~="table" or not current_session() then return end
    local success=result.kind=="success" and result.verified==true
    local request_context=feedback_request_contexts[request] or feedback.context()
    feedback_request_contexts[request]=nil
    local context=feedback.context()
    local result_current=result.stale~=true and result.destination_current==true
    if success then
      if request.operation=="duplicate" then
        if result_current and rawequal(result.phrase,bound_phrase()) then
          local accepted=runtime:editor_state()
          if accepted then
            pattern=assert(sequencer.copy_source(accepted.source))
            output_policy,pb_range=accepted.output_policy,accepted.pb_range
            phrase_label,phrase_label_custom=accepted.label,accepted.label_custom
            history:reset(pattern,output_policy,pb_range,phrase_label,phrase_label_custom)
            selected_pitch,selected_step,pitch_page,time_page=1,1,1,1
            invalidate_projection()
          end
        else
          result_current=false
        end
      end
      local accepted=runtime:editor_state()
      if result_current and accepted and sequencer.same_source(accepted.source,pattern) and
          (phrase_label~=accepted.label or phrase_label_custom~=accepted.label_custom) then
        phrase_label=accepted.label or "Untitled"
        phrase_label_custom=accepted.label_custom==true
        history:record(pattern,output_policy,pb_range,phrase_label,phrase_label_custom)
      end
      if result_current and (not result.phrase or not rawequal(result.phrase,bound_phrase())) then
        result_current=false
      end
      if result_current then
        refresh_phrase_choices(result.phrase)
        local committed=runtime:editor_state()
        if committed and sequencer.same_source(committed.source,pattern) then
          accepted_pitch_baseline=assert(sequencer.copy_source(committed.source))
          update()
        end
      end
    end
    if not result_current then
      local eligible=runtime:musical_eligibility()
      local integrity=runtime:integrity_state()
      local generation=runtime:generation_state()
      local target=runtime:target_projection()
      if not eligible and (integrity.blocked or generation.blocked) then
        feedback.set_issue("destination","integrity_blocked",nil,feedback.song_context())
      elseif not eligible and target.kind~="owned" and target.kind~="new" then
        feedback.set_issue("destination","destination_unavailable",nil,feedback.context())
      end
    elseif success then
      if feedback.same_context(request_context,context) then
        local issue=feedback.issues.generation
        local failure_key=request.operation=="duplicate" and "duplicate_failed" or "generation_failed"
        if issue and issue.key==failure_key then
          feedback.clear_issue("generation",context)
        end
        feedback.clear_issue("approximation",context)
        local destination_issue=feedback.issues.destination
        if not destination_issue or destination_issue.key~="draft_load_failed" then
          feedback.clear_issue("destination",context)
        end
      else
        feedback.target_changed(request_context,context)
      end
      if request.operation=="duplicate" then
        feedback.confirm("phrase_duplicated",nil,context)
      elseif result.status=="approximate" or result.approximate==true or
          result.code=="capability.approximate" then
        feedback.set_issue("approximation","phrase_approximate",nil,context)
      elseif request.trigger=="manual" then
        feedback.confirm("phrase_updated",nil,context)
      end
    elseif result.status=="integrity_blocked" or result.integrity_blocked==true or
        result.category=="integrity" then
      feedback.set_issue("destination","integrity_blocked",nil,feedback.song_context())
    else
      feedback.request_failure("generation",request.operation=="duplicate")
    end
  end
  live_checkbox=vb:checkbox{id="acid_live_edit",value=false,notifier=function(value)
    if updating then return end
    if guard_stage() then
      updating=true;render(live_checkbox,"value",runtime:revision_state().armed==true);updating=false;return
    end
    if value then
      apply_pending_selected_phrase_selection()
      runtime:transition("arm")
    else
      runtime:transition("disarm")
    end
  end}
  active_live_checkbox=live_checkbox
  label_ui.close=function()
    if label_ui.dialog then label_ui.dialog:close() end
    label_ui.dialog=nil
    active_label_dialog=nil
  end
  label_ui.show=function(attempt)
    release_audition()
    label_ui.attempt=attempt
    local visible=label_ui.dialog and label_ui.dialog.visible
    if not visible then
      local label_vb=renoise.ViewBuilder()
      label_ui.field=label_vb:textfield{id="acid_label_field",width=330,value=phrase_label}
      label_ui.error=label_vb:text{id="acid_label_error",width=580,text=""}
      label_ui.save=label_vb:button{id="acid_label_save",text="Save",notifier=function()
        if not current_session() then return end
        label_ui.field.edit_mode=false
        label_ui.apply({label=label_ui.field.value,label_custom=true,revision=history.revision})
      end}
      label_ui.retry=label_vb:button{id="acid_label_retry",text="Retry",notifier=function()
        local pending=label_ui.attempt
        if not pending then return end
        label_ui.field.edit_mode=false
        if not pending.proposal then pending.label=label_ui.field.value end
        label_ui.apply(pending)
      end}
      label_ui.discard=label_vb:button{id="acid_label_discard",text="Discard Attempt",notifier=function()
        label_ui.attempt=nil
        label_ui.field.value=phrase_label
        label_ui.close()
        update()
        feedback.clear_input("label_save_failed","label_attempt_stale","label_editor_open")
      end}
      label_ui.content=label_vb:column{margin=12,spacing=8,
        label_vb:text{text="Phrase label: 1–32 ASCII letters, digits, spaces, _, . or -; start with a letter or digit."},
        label_ui.field,label_ui.error,label_vb:row{spacing=6,label_ui.save,label_ui.retry,label_ui.discard}}
    end
    label_ui.field.value=attempt and attempt.label or phrase_label
    label_ui.field.active=not (attempt and attempt.proposal)
    local error_key=attempt and attempt.error_key
    label_ui.error.text=error_key=="invalid_label" and "Use the label format shown above." or
      error_key=="history_changed" and "The editor changed. Discard this attempt." or
      error_key and "Label could not be saved. Retry or discard this attempt." or ""
    label_ui.save.active=attempt==nil
    label_ui.retry.active=attempt~=nil
    if visible then label_ui.dialog:show()
    else label_ui.dialog=renoise.app():show_custom_dialog("ACID - Phrase label",label_ui.content) end
    label_ui.field.edit_mode=label_ui.field.active
    active_label_dialog=label_ui.dialog
  end
  label_ui.apply=function(attempt)
    local function current()
      return current_session() and history.revision==attempt.revision and
        (not attempt.proposal or history:is_current(attempt.proposal))
    end
    if not current() then
      attempt.error_key="history_changed"
      feedback.set_issue("input","label_attempt_stale")
      label_ui.show(attempt)
      return
    end
    if not pattern_store.valid_label(attempt.label) then
      attempt.error_key="invalid_label"
      feedback.set_issue("input","label_save_failed")
      label_ui.show(attempt)
      return
    end
    label_ui.attempt=attempt
    local saved=runtime:rename_label(attempt.label,attempt.label_custom,current)
    if not saved then
      attempt.error_key="save_failed"
      if runtime:integrity_state().blocked then
        feedback.set_issue("destination","integrity_blocked",nil,feedback.song_context())
      else
        feedback.set_issue("input","label_save_failed")
      end
      label_ui.show(attempt)
      return
    end
    if attempt.proposal then assert(history:commit(attempt.proposal),"Label history proposal changed during persistence")
    else history:record(pattern,output_policy,pb_range,attempt.label,attempt.label_custom) end
    phrase_label,phrase_label_custom=attempt.label,attempt.label_custom
    label_ui.attempt=nil
    label_ui.close()
    feedback.clear_input("label_save_failed","label_attempt_stale","label_editor_open")
    update()
    feedback.confirm("label_saved")
  end
  local function move_history(direction)
    if guard_stage() then return end
    local proposal=history:propose(direction)
    if not proposal then return end
    local next_state=proposal.state
    local difference=editor.classify_difference({pattern=pattern,output_policy=output_policy,
      pb_range=pb_range,label=phrase_label,label_custom=phrase_label_custom},next_state)
    if difference=="label_only" then
      label_ui.apply({label=next_state.label,label_custom=next_state.label_custom,
        revision=history.revision,proposal=proposal})
      return
    end
    pattern=next_state.pattern
    output_policy=next_state.output_policy
    pb_range=next_state.pb_range
    phrase_label,phrase_label_custom=next_state.label,next_state.label_custom
    if not history:commit(proposal) then return end
    feedback.clear_confirmation()
    invalidate_projection()
    local _,_,effects=save_draft()
    update()
    clear_resolved_input()
    if effects and effects.live_intent and current_session() then runtime:flush_pending() end
  end
  undo_button=vb:button{text="Undo",active=false,notifier=function()
    move_history("undo")
  end}
  redo_button=vb:button{text="Redo",active=false,notifier=function()
    move_history("redo")
  end}
  local function selector_rows(selectors)
    local first,second=vb:row{spacing=3},vb:row{spacing=3}
    for index,button in ipairs(selectors) do
      local row=index<=8 and first or second
      row:add_child(button)
    end
    return vb:column{spacing=3,first,second}
  end
  local program_pitch_page_row=vb:row{spacing=5}
  local program_time_page_row=vb:row{spacing=5}
  for page=1,editor.MAX_PAGES do
    program_pitch_page_row:add_child(ui.program.pitch_pages[page])
    program_time_page_row:add_child(ui.program.time_pages[page])
  end
  local program_key_row_a,program_key_row_b=vb:row{spacing=3},vb:row{spacing=3}
  local grid_key_row_a,grid_key_row_b=vb:row{spacing=3},vb:row{spacing=3}
  for index=1,#keys do
    local program_row=index<=6 and program_key_row_a or program_key_row_b
    local grid_row=index<=6 and grid_key_row_a or grid_key_row_b
    program_row:add_child(ui.program.key_buttons[index])
    grid_row:add_child(ui.grid.key_buttons[index])
  end
  local program_keyboard=vb:column{spacing=3,program_key_row_a,program_key_row_b}
  local grid_keyboard=vb:column{spacing=3,grid_key_row_a,grid_key_row_b}
  local program_octave_row=vb:row{spacing=4}
  local grid_octave_row=vb:row{spacing=4}
  for index=1,3 do
    program_octave_row:add_child(ui.program.octave_buttons[index])
    grid_octave_row:add_child(ui.grid.octave_buttons[index])
  end
  stage_status=vb:text{id="acid_program_stage_status",size={width=820,height=18},text="Edit One",font="bold"}
  local function stage_navigation(action)
    if not stage or not valid_stage() then return end
    if action=="enter" then
      stage.entered[stage.cursor]=true
      stage.cursor=math.min(#stage.target_positions,stage.cursor+1)
      refresh_entry_issue()
    elseif action=="back" then stage.cursor=math.max(1,stage.cursor-1)
    else stage.cursor=1 end
    if stage.memory=="pitch" then choose_pitch(stage.cursor) else choose_time(stage.cursor) end
  end
  stage_actions={
    back=vb:button{id="acid_program_back",text="Back",notifier=function() stage_navigation("back") end},
    enter=vb:button{id="acid_program_enter",text="Enter and Advance",notifier=function() stage_navigation("enter") end},
    restart=vb:button{id="acid_program_restart",text="Restart Cursor",notifier=function() stage_navigation("restart") end},
    finish=vb:button{id="acid_program_finish",text="Finish",notifier=function() finish_stage() end},
    discard=vb:button{id="acid_program_discard",text="Discard",notifier=function()
      release_audition()
      if stage and renoise.app():show_prompt("Discard entry","Discard the detached candidate?",{"Stay","Discard"})=="Discard" then
        stage=nil;clear_resolved_input();update()
      end
    end}}
  local entry_controls=vb:row{spacing=4,
    vb:button{id="acid_program_edit_one",text="Edit One",notifier=function() guard_stage() end},
    vb:button{id="acid_program_reenter_pitch",text="Re-enter PITCH",notifier=function() begin_stage("pitch") end},
    vb:button{id="acid_program_reenter_time",text="Re-enter TIME",notifier=function() begin_stage("time") end}}
  entry_navigation=vb:row{spacing=4,stage_actions.back,stage_actions.enter,
    stage_actions.restart,stage_actions.finish,stage_actions.discard}
  audition_button=vb:button{id="acid_audition",text="Audition PITCH",notifier=function()
    if not current_session() or (stage and (stage.memory~="pitch" or not valid_stage())) then return end
    local records=stage and stage_resolution().resolved_records or project().resolved_records
    local record=records and records[selected_pitch]
    if not record then feedback.audition_failed("audition_start_failed");return end
    local started=preview:start(record.note)
    if not started then
      local outcome=preview:last_outcome()
      if outcome and (outcome.release_error or #(outcome.cleanup_errors or {})>0) then
        feedback.audition_failed("audition_release_failed")
      else
        feedback.audition_failed("audition_start_failed")
      end
    end
  end}
  program_panel=vb:column{id="acid_program_panel",spacing=4,
    entry_controls,entry_navigation,
    vb:text{text="PITCH",font="bold"},
    program_pitch_page_row,selector_rows(ui.program.pitch_selectors),program_pitch_summary,
    vb:row{spacing=4,vb:text{text="RESOLVED PITCH CLASS"},program_keyboard},
    vb:row{spacing=4,vb:text{text="OCTAVE"},program_octave_row,
      vb:text{text="ACCENT"},program_accent,vb:text{text="SLIDE"},program_slide,program_c_plus},
    vb:text{text="TIME",font="bold"},
    program_time_page_row,selector_rows(ui.program.time_selectors),program_time_summary}
  grid_panel=vb:column{id="acid_grid_panel",spacing=4,
    vb:text{text="PITCH",font="bold"},
    pitch_pages,pitch_grid,
    vb:row{spacing=4,vb:text{text="RESOLVED PITCH CLASS"},grid_keyboard},
    vb:row{spacing=4,vb:text{text="OCTAVE"},grid_octave_row,
      vb:text{text="ACCENT"},accent,vb:text{text="SLIDE"},slide,grid_c_plus},
    vb:text{text="TIME",font="bold"},
    time_pages,time_grid}
  clipboard.choice=vb:popup{id="acid_clipboard_scope",items={"PITCH","TIME","Both"},value=1,
    notifier=function() if not updating then release_audition();update() end end}
  clipboard.status=vb:text{id="acid_clipboard_status",text="Clipboard empty"}
  local copy_button=vb:button{id="acid_clipboard_copy",text="Copy",notifier=function()
    if guard_stage() then return end
    clipboard.scope=clipboard.scopes[clipboard.choice.value]
    clipboard.payload=sequencer.make_clipboard(pattern,clipboard.scope)
    update()
    if not clipboard.payload then feedback.set_issue("input","input_failed")
    else feedback.clear_input("clipboard_empty","clipboard_scope_mismatch","input_failed") end
  end}
  clipboard.paste_button=vb:button{id="acid_clipboard_paste",text="Paste",active=false,notifier=function()
    if guard_stage() then return end
    local scope=clipboard.scopes[clipboard.choice.value]
    if not clipboard.payload or clipboard.scope~=scope then
      feedback.set_issue("input",clipboard.payload and "clipboard_scope_mismatch" or "clipboard_empty")
      return
    end
    local eligible=runtime:musical_eligibility()
    if not eligible then feedback.request_failure("input",false);return end
    local candidate=sequencer.paste_candidate(pattern,clipboard.payload,scope)
    if not candidate then feedback.set_issue("input","input_failed");return end
    feedback.clear_input("clipboard_empty","clipboard_scope_mismatch","input_failed")
    if sequencer.same_source(candidate,pattern) then return end
    pattern=candidate
    changed()
  end}
  label_ui.display=vb:text{id="acid_label_accepted",width=300,text=phrase_label}
  local pattern_copy_panel=vb:column{id="acid_pattern_copy_panel",spacing=4,
    vb:text{text="PATTERN / COPY",font="bold"},
    vb:row{spacing=6,vb:text{text="Label"},label_ui.display,
      vb:button{id="acid_label_rename",text="Rename",notifier=function()
        if guard_stage() then return end
        label_ui.show()
      end}},
    vb:row{spacing=6,clipboard.choice,copy_button,clipboard.paste_button,
      vb:button{id="acid_pattern_duplicate",text="Duplicate",notifier=function()
        if guard_stage() then return end
        if not current_session() then feedback.request_failure("generation",true);return end
        apply_pending_selected_phrase_selection()
        local accepted=runtime:request_duplicate()
        if not accepted then feedback.request_failure("generation",true) end
      end}},clipboard.status}
  local extended_panel
  do
  local function admit_operation()
    if stage or label_ui.attempt or (label_ui.dialog and label_ui.dialog.visible) then
      if label_ui.attempt or (label_ui.dialog and label_ui.dialog.visible) then
        feedback.set_issue("input","label_editor_open")
      else
        feedback.set_issue("input","entry_unavailable")
      end
      return false
    end
    apply_pending_selected_phrase_selection()
    if not current_session() then return false end
    local eligible=runtime:musical_eligibility()
    if not eligible then feedback.request_failure("input",false);return false end
    return true
  end
  ui.admit_operation=admit_operation
  local function apply_candidate(candidate)
    if sequencer.same_source(candidate,pattern) then update();return end
    pattern=candidate
    changed()
  end
  local operation_ids={"clear_pitch","clear_time","clear_tie","clear_rest","clear_slide","clear_accent",
    "rest_to_note","tie_to_rest","randomize_pitch","randomize_time"}
  local operation_names={"Clear PITCH","Clear TIME","Clear TIE","Clear REST","Clear SLIDE","Clear ACCENT",
    "REST to NOTE","TIE to REST","Randomize PITCH","Randomize TIME"}
  local random_fields={}
  local function random_field(name,min,max,value)
    local control=vb:valuebox{id="acid_operation_"..name,min=min,max=max,value=value,
      width=RANDOM_FIELD_WIDTH,steps={1,10},
      tostring=function(number) return string.format("%.0f",number) end,tonumber=tonumber}
    random_fields[name]=control
    return control
  end
  local random_state={last={}}
  local pitch_parameters=vb:row{id="acid_random_pitch_parameters",spacing=4,visible=false,
    vb:text{text="Seed"},random_field("pitch_seed",1,RANDOM_SEED_MAX,1),
    vb:text{text="MIDI range"},random_field("min_note",RANDOM_NOTE_MIN,RANDOM_NOTE_MAX,RANDOM_NOTE_MIN),
    vb:text{text="to"},random_field("max_note",RANDOM_NOTE_MIN,RANDOM_NOTE_MAX,RANDOM_NOTE_MAX)}
  local time_parameters=vb:row{id="acid_random_time_parameters",spacing=4,visible=false,
    vb:text{text="Seed"},random_field("time_seed",1,RANDOM_SEED_MAX,1),
    vb:text{text="NOTE"},random_field("note_weight",0,RANDOM_WEIGHT_MAX,2),
    vb:text{text="TIE"},random_field("tie_weight",0,RANDOM_WEIGHT_MAX,1),
    vb:text{text="REST"},random_field("rest_weight",0,RANDOM_WEIGHT_MAX,1)}
  random_state.display=vb:text{id="acid_random_last_seed",text="",width=RANDOM_LAST_SEED_WIDTH}
  random_state.repeat_button=vb:button{id="acid_random_repeat",text="Repeat last",active=false,
    notifier=function() random_state.run(true) end}
  local parameter_row=vb:column{id="acid_random_parameters",spacing=4,visible=false,
    pitch_parameters,time_parameters,
    vb:row{spacing=8,random_state.display,random_state.repeat_button}}
  local operation_choice=vb:popup{id="acid_operation",items=operation_names,width=180,value=1,
    notifier=function(value)
      local operation=operation_ids[value]
      local pitch=operation=="randomize_pitch"
      local time=operation=="randomize_time"
      pitch_parameters.visible=pitch
      time_parameters.visible=time
      parameter_row.visible=pitch or time
      random_state.refresh()
    end}
  local operation_scope=vb:popup{id="acid_operation_scope",items={"Active memory","All 32 stored"},width=150,value=1}
  random_state.refresh=function()
    local last=random_state.last[operation_ids[operation_choice.value]]
    render(random_state.display,"text","Last used: "..(last and tostring(last) or "—"))
    render(random_state.repeat_button,"active",last~=nil and stage==nil)
  end
  ui.refresh_random=random_state.refresh
  random_state.run=function(repeat_last)
    if guard_stage() then return end
    if not admit_operation() then return end
    local choice=operation_choice.value
    local operation=operation_ids[choice]
    local scope=operation_scope.value==1 and "active" or "all"
    local parameters={}
    local seed_control
    if operation=="randomize_pitch" then
      seed_control=random_fields.pitch_seed
      parameters={min_note=random_fields.min_note.value,max_note=random_fields.max_note.value}
    elseif operation=="randomize_time" then
      seed_control=random_fields.time_seed
      parameters={note_weight=random_fields.note_weight.value,
        tie_weight=random_fields.tie_weight.value,rest_weight=random_fields.rest_weight.value}
    end
    if repeat_last and (not seed_control or not random_state.last[operation]) then return end
    if seed_control then parameters.seed=repeat_last and random_state.last[operation] or seed_control.value end
    local candidate=sequencer.operation_candidate(pattern,operation,scope,parameters)
    if not candidate then feedback.set_issue("input","operation_failed",{operation=choice});return end
    local issue=feedback.issues.input
    if issue and issue.key=="operation_failed" and issue.args.operation==choice then
      feedback.clear_input("operation_failed")
    end
    apply_candidate(candidate)
    if seed_control then
      random_state.last[operation]=parameters.seed
      random_state.refresh()
    end
  end
  local function edit_mask(index,value)
    if updating then return end
    if guard_stage() then update();return end
    if not admit_operation() then update();return end
    local bits={}
    for class,enabled in ipairs(pattern.scale_mask) do bits[class]=enabled end
    if index then bits[index]=value end
    local enabled=pattern.scale_mask_enabled
    if not index then enabled=value end
    local candidate=sequencer.mask_candidate(pattern,enabled,bits)
    if not candidate then update();feedback.set_issue("input","input_failed");return end
    apply_candidate(candidate)
  end
  ui.mask.enabled=vb:checkbox{id="acid_mask_enabled",value=false,notifier=function(value) edit_mask(nil,value) end}
  local mask_row=vb:row{spacing=4,vb:text{text="MASK"},ui.mask.enabled}
  for index,name in ipairs(keys) do
    local class=index
    local control=vb:checkbox{id=string.format("acid_mask_class_%02d",index),value=true,
      notifier=function(value) edit_mask(class,value) end}
    ui.mask.classes[index]=control
    mask_row:add_child(vb:text{text=name});mask_row:add_child(control)
  end
  local operation_button=vb:button{id="acid_operation_open",text="Apply",notifier=function() random_state.run(false) end}
  ui.scale_controls=(function()
    local scale_category="All"
    local scale_query=""
    local visible_scales={}
    local category_names={"All"}
    local root_choice,category_choice,scale_choice,scale_search,scale_detail
    local function rebuild_categories()
      local seen={}
      category_names={"All"}
      for _,entry in ipairs(scale_state.catalog) do seen[entry.category]=true end
      local sorted={}
      for name in pairs(seen) do if name~="All" then sorted[#sorted+1]=name end end
      table.sort(sorted)
      for _,name in ipairs(sorted) do category_names[#category_names+1]=name end
    end
    local function matching_mask(entry)
      local bits=scales.mask(entry,scale_state.root)
      for index=1,scales.PITCH_CLASSES do
        if bits[index]~=pattern.scale_mask[index] then return false end
      end
      return true
    end
    local function rebuild_scale_choices()
      visible_scales={}
      local names={"Custom / current mask"}
      for _,entry in ipairs(scale_state.catalog) do
        local searchable=entry.name.." "..table.concat(entry.aliases or {}," ")
        if (scale_category=="All" or entry.category==scale_category) and
            searchable:lower():find(scale_query:lower(),1,true) then
          visible_scales[#visible_scales+1]=entry
          names[#names+1]=entry.name
        end
      end
      local was_updating=updating
      updating=true
      scale_choice.value=1
      scale_choice.items=names
      updating=was_updating
    end
    local function admit_scale_edit()
      if guard_stage() then update();return false end
      if not admit_operation() then update();return false end
      return true
    end
    rebuild_categories()
    root_choice=vb:popup{id="acid_scale_root",items=keys,width=SCALE_UI.root_width,value=1,
      notifier=function(value)
        if updating then return end
        scale_state.root=value-1
        release_audition()
        update()
      end}
    category_choice=vb:popup{id="acid_scale_category",items=category_names,width=SCALE_UI.category_width,value=1,
      notifier=function(value)
        if updating then return end
        scale_category=category_names[value] or "All"
        rebuild_scale_choices();update()
      end}
    scale_choice=vb:popup{id="acid_scale_choice",items={"Custom / current mask"},width=SCALE_UI.choice_width,value=1,
      notifier=function(value)
        if updating then return end
        local entry=visible_scales[value-1]
        if not entry then update();return end
        if not admit_scale_edit() then return end
        local candidate=sequencer.mask_candidate(pattern,true,scales.mask(entry,scale_state.root))
        if not candidate then update();feedback.set_issue("input","input_failed");return end
        apply_candidate(candidate)
      end}
    scale_search=vb:textfield{id="acid_scale_search",text="",width=SCALE_UI.search_width,
      notifier=function(value)
        if updating then return end
        scale_query=value
        rebuild_scale_choices();update()
      end}
    local follow_choice=vb:checkbox{id="acid_scale_follow",value=false,
      notifier=function(value)
        if updating then return end
        scale_state.follow=value
        release_audition();update()
      end}
    scale_detail=vb:text{id="acid_scale_detail",text="",width=SCALE_UI.detail_width}
    local import_scales=vb:button{id="acid_scale_import",text="Import .txt",width=SCALE_UI.import_width,
      notifier=function()
        if guard_stage() then return end
        if scale_state.load_error then
          feedback.set_issue("scale","scale_load_failed",nil,false)
          return
        end
        local filename=renoise.app():prompt_for_filename_to_read({"txt"},"Import custom scales")
        if filename=="" then return end
        local file=io.open(filename,"rb")
        if not file then feedback.set_issue("scale","scale_read_failed",nil,false);return end
        local read_ok,text=pcall(function() return file:read(scales.MAX_TEXT_BYTES+1) end)
        file:close()
        if not read_ok or type(text)~="string" then feedback.set_issue("scale","scale_read_failed",nil,false);return end
        if #text>scales.MAX_TEXT_BYTES then feedback.set_issue("scale","scale_too_large",nil,false);return end
        local entries=scales.parse(text)
        if not entries then feedback.set_issue("scale","scale_invalid",nil,false);return end
        if #entries==0 then feedback.set_issue("scale","scale_empty",nil,false);return end
        local merged=scales.merge(scale_state.custom,entries)
        if not merged then feedback.set_issue("scale","scale_merge_failed",nil,false);return end
        local catalog=scales.merge(builtin,merged)
        if not catalog then feedback.set_issue("scale","scale_merge_failed",nil,false);return end
        local serialized=scales.encode(merged)
        if #serialized>scales.MAX_TEXT_BYTES then
          feedback.set_issue("scale","scale_too_large",nil,false);return
        end
        local saved,save_error,uncertain=scale_preferences.save(tool,serialized)
        if not saved then
          feedback.set_issue("scale",uncertain and "scale_save_uncertain" or "scale_save_failed",nil,false)
          if uncertain then scale_state.load_error=save_error or true;update() end
          return
        end
        scale_state.custom=merged
        scale_state.catalog=catalog
        scale_category,scale_query="All",""
        rebuild_categories()
        updating=true
        category_choice.value=1;category_choice.items=category_names;scale_search.text=""
        updating=false
        rebuild_scale_choices();update()
        feedback.clear_issue("scale",false)
        feedback.confirm("scale_imported",{count=#entries},false)
      end}
    scale_state.refresh=function()
      render(root_choice,"value",scale_state.root+1)
      render(root_choice,"active",true)
      render(scale_choice,"active",stage==nil)
      render(import_scales,"active",stage==nil and not scale_state.load_error)
      render(follow_choice,"value",scale_state.follow)
      local selected=1
      local matched
      if pattern.scale_mask_enabled then
        for index,entry in ipairs(visible_scales) do
          if matching_mask(entry) then selected=index+1;matched=entry;break end
        end
      end
      render(scale_choice,"value",selected)
      local detail=string.format("%d unique scales | %d shown | MASK %s | Follow scale %s",
        #scale_state.catalog,#visible_scales,pattern.scale_mask_enabled and "on" or "off",scale_state.follow and "on" or "off")
      render(scale_detail,"text",detail)
      render(scale_choice,"tooltip",matched and
        (matched.category.." | "..table.concat(matched.aliases or {},", ")) or "Choose a scale to enable MASK.")
    end
    rebuild_scale_choices()
    return {root=root_choice,category=category_choice,choice=scale_choice,
      search=scale_search,follow=follow_choice,import=import_scales,detail=scale_detail}
  end)()
  ui.operation_controls={operation_choice,operation_scope,operation_button}
  for _,control in pairs(random_fields) do ui.operation_controls[#ui.operation_controls+1]=control end
  extended_panel=vb:column{id="acid_extended_panel",spacing=4,
    vb:text{text="EXTENDED / CLEAR",font="bold"},
    vb:row{spacing=6,operation_choice,operation_scope,
      operation_button},parameter_row,
    vb:row{spacing=6,vb:text{text="Root"},ui.scale_controls.root,ui.scale_controls.category,ui.scale_controls.choice,
      vb:text{text="Follow scale"},ui.scale_controls.follow},
    vb:row{spacing=6,vb:text{text="Search"},ui.scale_controls.search,ui.scale_controls.import},ui.scale_controls.detail,mask_row,
    vb:text{text="Apply keeps the seed. Return to a seed and Apply with the same settings to recall its result."},
    vb:text{text="Root browses without editing; choose a scale to apply MASK. Follow snaps new notes."}}
  end
  local output_panel=vb:column{id="acid_output_panel",spacing=4,
    vb:text{text="OUTPUT",font="bold"},
    vb:row{spacing=8,vb:text{text="Phrase output"},playback_popup,
      vb:text{text="PB Range"},pb_range_popup},
    vb:text{text="Assumes the receiver's matching bend range; pitch bend is channel-wide. Use isolated monophonic routing."}}
  local tab_names={"Pattern / Copy","Extended / Clear","Output"}
  local tab_row=vb:row{spacing=4}
  for index,name in ipairs(tab_names) do
    local tab=index
    ui.workspace.tabs[index]=vb:button{width=150,text=name,notifier=function()
      release_audition();workspace_tab=tab
      update()
    end}
    tab_row:add_child(ui.workspace.tabs[index])
  end
  ui.workspace.panels={pattern_copy_panel,extended_panel,output_panel}
  local workspace=vb:column{spacing=4,tab_row,
    vb:stack{autosize=false,size={width=820,height=WORKSPACE_HEIGHT},views={
      pattern_copy_panel,extended_panel,output_panel}}
  }
  for _,panel in ipairs(ui.workspace.panels) do
    panel.origin={0,0}
    panel.size={width=820,height=WORKSPACE_HEIGHT}
  end
  local content=vb:column{margin=12,spacing=7,
    vb:text{text="ACID  |  PITCH / TIME EDITOR",font="big"},
    vb:row{spacing=6,vb:text{text="Target instrument"},target,
      vb:text{text="Destination phrase"},phrase_choice},
    vb:row{spacing=10,vb:text{text="LAST STEP"},last_step_box,
      vb:text{text="Timing"},timing_popup,step_division,
      vb:text{text="Active PITCH span"},pitch_length_popup},
    vb:row{spacing=8,
      vb:text{text="Editor"},view_popup,
      vb:button{id="acid_pattern_reset",text="Reset Pattern",notifier=function()
        if guard_stage() then return end
        if not ui.admit_operation() then return end
        reset_source(pattern.length)
        changed()
      end},
      undo_button,
      redo_button,audition_button},
    view_heading,stage_status,program_panel,grid_panel,
    vb:row{spacing=5,vb:text{text="Assign selected TIME"},
      ui.time_assignment[1],ui.time_assignment[2],ui.time_assignment[3]},
    workspace,
    vb:row{spacing=8,vb:text{text="Live Edit (automatic regeneration)"},live_checkbox,
      vb:button{text="Retry Live Edit",notifier=function()
        if guard_stage() then return end
        if runtime:revision_state().armed then
          local accepted=runtime:request_generation("live")
          if not accepted then feedback.request_failure("generation",false) end
        end
      end}},
    vb:row{spacing=8,
      vb:button{text="Generate / Regenerate ACID Phrase",notifier=function()
        if guard_stage() then return end
        if not current_session() then
          feedback.set_issue("destination","document_changed",nil,feedback.song_context());return
        end
        apply_pending_selected_phrase_selection()
        local projection=project()
        if projection.error then
          local e=projection.error
          if e.step then choose_time(e.step) end
          if e.pitch_index then choose_pitch(e.pitch_index) end
          set_projection_issue(e)
          return
        end
        clear_resolved_input()
        local accepted=runtime:request_generation("manual")
        if not accepted then feedback.request_failure("generation",false) end
      end}},
    feedback.holder}
  select_instrument(selected_instrument)
  if scale_state.load_error then
    feedback.set_issue("scale","scale_load_failed",nil,false)
  end
  native_observers:attach(song,runtime,function()
    release_audition()
    native_projection_dirty=true
    invalidate_projection()
  end)
  update()
  dialog=renoise.app():show_custom_dialog("ACID - PITCH/TIME",content)
  dialog_session=session
  local observed_dialog=dialog
  local observed_session=session
  local observed_checkbox=live_checkbox
  idle_observable=renoise.tool().app_idle_observable
  assert(idle_observable~=nil,"ACID idle observable is required")
  assert(type(idle_observable.has_notifier)=="function","ACID idle observable must support has_notifier")
  local observed_idle_observable=idle_observable
  local observed_notifier
  local closing=false
  observed_notifier=function()
    if closing or not lifecycle_enabled or not idle_active then return end
    local function detach_this_watch()
      closing=true
      remove_idle_watch(observed_idle_observable,observed_notifier)
    end
    if not rawequal(dialog,observed_dialog) or dialog_session~=observed_session then
      detach_this_watch()
      return
    end
    if observed_dialog.visible then
      apply_pending_selected_phrase_selection()
      runtime:flush_pending()
      return
    end
    detach_this_watch()
    label_ui.attempt=nil
    label_ui.close()
    preview:close()
    if rawequal(active_audition,preview) then active_audition=nil end
    stage=nil
    native_observers:detach()
    runtime:transition("disarm")
    runtime:close_dialog()
    observed_checkbox.value=false
    if rawequal(active_live_checkbox,observed_checkbox) then active_live_checkbox=nil end
    dialog=nil
    dialog_session=nil
  end
  idle_notifier=observed_notifier
  idle_active=true
  local idle_registered,idle_error=pcall(function()
    observed_idle_observable:add_notifier(observed_notifier)
    assert(observed_idle_observable:has_notifier(observed_notifier),
      "idle notifier registration was ineffective")
  end)
  if not idle_registered then
    preview:close()
    if rawequal(active_audition,preview) then active_audition=nil end
    idle_active=false
    runtime:set_observer_error("Native observer failure: idle notifier registration failed: "..tostring(idle_error))
    remove_idle_watch()
    native_observers:detach()
    runtime:transition("disarm")
    runtime:close_dialog()
    if rawequal(dialog,observed_dialog) then dialog=nil end
    if rawequal(dialog_session,observed_session) then dialog_session=nil end
    if rawequal(active_live_checkbox,observed_checkbox) then active_live_checkbox=nil end
    pcall(function() observed_dialog:close() end)
    pcall(function() observed_checkbox.value=false end)
    error("ACID idle notifier registration failed: "..tostring(idle_error))
  end
end

function M.get_ui_state()
  local visible=dialog and dialog.visible==true or false
  local observers=native_observers:state()
  return {dialog_visible=visible,native_observers_attached=observers.attached,
    native_listener_count=observers.listener_count,native_observer_error=observers.error,
    idle_listener_attached=idle_active}
end
return M
