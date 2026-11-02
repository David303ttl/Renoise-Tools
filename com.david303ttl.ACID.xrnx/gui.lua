-- SPDX-License-Identifier: GPL-3.0-only
-- Native ViewBuilder PITCH/TIME editor.
local M = {}
local sequencer=require("model.sequencer")
local policies=require("model.policies")
local editor=require("model.editor_state")
local drafts=require("runtime.draft_cache")
local ownership=require("renoise.phrase_ownership")
local phrase_writer=require("writers.phrase_writer")
local inspector=require("renoise.selection_context")
local sampler=require("renoise.sampler_audit")
local dialog
local runtime_context=require("runtime.context")
local native_observers=require("runtime.observers").new()
local active_runtime
local active_live_checkbox
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
  local recovery_warning=phrase_writer.release()
  if recovery_warning then renoise.app():show_warning(recovery_warning) end
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
local octave_names={"DOWN (-1)","NORMAL (0)","UP (+1)"}
local colors={selected={0xF0,0x70,0x70},used={0x55,0xAA,0x75},
  idle={0x49,0x4B,0x55},inactive={0x30,0x32,0x39},note={0xBD,0x5B,0x5B},
  tie={0x5D,0x88,0xB7},rest={0x4B,0x4D,0x56},
  warning={0xF2,0x77,0x77}}

local function wrap_lines(text,width)
  local lines,current={},""
  for word in tostring(text or ""):gmatch("%S+") do
    while #word>width do
      if current~="" then lines[#lines+1]=current;current="" end
      lines[#lines+1]=word:sub(1,width)
      word=word:sub(width+1)
    end
    if current=="" then current=word
    elseif #current+#word+1<=width then current=current.." "..word
    else lines[#lines+1]=current;current=word end
  end
  if current~="" then lines[#lines+1]=current end
  if #lines==0 then lines[1]="" end
  return lines
end

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
  local decoded_page=1
  local workspace_tab=1
  local accepted_pitch_baseline
  local updating=false
  local preview_cycle=1
  local update
  local runtime
  local session
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
  local labels={}
  local instrument_targets={}
  for i,instrument in ipairs(song.instruments) do
    local name=instrument.name~="" and instrument.name or "(unnamed)"
    instrument_targets[i]=instrument
    labels[i]=string.format("%02X: %s",i-1,name)
  end
  if #labels==0 then renoise.app():show_warning("No instruments in song.");return end
  local status=vb:multiline_textfield{id="acid_status",size={width=820,height=80},active=true,
    font="bold",text="Draft ready: edit PITCH and TIME memories or generate a phrase."}
  local live_state_view=vb:multiline_text{id="acid_live_edit_state",size={width=820,height=48},font="bold",
    text="LIVE EDIT DISABLED"}
  local source_state=vb:text{id="acid_source_state",size={width=820,height=18},font="bold",text=""}
  local diagnostic=vb:text{id="acid_source_diagnostic",size={width=820,height=18},font="bold",text=""}
  local navigate_diagnostic
  local diagnostic_jump=vb:button{text="Go to source error",active=false,notifier=function()
    if navigate_diagnostic then navigate_diagnostic() end
  end}
  local summary=vb:text{id="acid_source_summary",size={width=820,height=18},font="bold",text=""}
  local map_text=vb:text{id="acid_preview_summary",size={width=820,height=18},font="bold",text=""}
  local length_items={}
  for n=1,sequencer.MAX_STEPS do length_items[n]=tostring(n) end
  local last_step_box=vb:valuebox{width=78,min=1,max=sequencer.MAX_STEPS,steps={1,8},value=sequencer.PAGE_SIZE,
    tostring=function(value)return string.format("%d",math.floor(value+0.5))end,
    tonumber=function(value)return tonumber(value)end}
  local view_popup=vb:popup{id="acid_editor_view",items={"Program","Grid"},width=105,value=1,
    notifier=function(value)
      if updating then return end
      editor_view=value
      status.text=value==1 and "Program view: edit selected PITCH and TIME positions."
        or "Grid view: edit PITCH and TIME memory pages directly."
      update()
    end}
  local view_heading=vb:text{text="PROGRAM VIEW",font="bold"}
  local view_hint=vb:text{text="Select one PITCH entry and TIME step to edit the shared source."}
  local program_panel,grid_panel
  local ui={program={pitch_selectors={},time_selectors={},pitch_pages={},time_pages={},
      key_buttons={},octave_buttons={}},
    grid={key_buttons={},octave_buttons={}},time_assignment={},
    workspace={panels={},tabs={}},decoded={}}
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
  local preview_popup=vb:popup{items={"Start","Repeating"},width=105,value=1,
    notifier=function(value)
      if updating then return end
      preview_cycle=value
      update()
    end}
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
  local function revision() return runtime:revision_state().edit_revision end
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
      projected_revision=revision()
      projected_instrument,projected_phrase=bound_instrument(),bound_phrase()
    end
    return cached_projection
  end
  local update_live_state
  local update_actions
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
    local state,effects=runtime:transition(kind or "edit",{
      source=pattern,output_policy=output_policy,pb_range=pb_range,
      label=phrase_label,label_custom=phrase_label_custom})
    if not state then
      return false,effects or "Editor state transition failed"
    end
    render(source_state,"text","SOURCE DIRTY: Generate to apply this draft.")
    if not bound_instrument() then return true,nil,effects end
    return not state.draft_warning,state.draft_warning,effects
  end
  local loading=false
  local function default_pitch()
    return sequencer.new_pitch(0,0,false,false)
  end
  local function pitch_at(index)
    return pattern.pitch_events[index] or default_pitch()
  end
  local function fill_to(index)
    for i=#pattern.pitch_events+1,index do pattern.pitch_events[i]=default_pitch() end
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
  local function grid_pitch_header(index,p,projection)
    if index>#pattern.pitch_events then return string.format("P%02d ---",index) end
    local markers="S"..(projection.used[index] and "R" or "-")..
      (accepted_pitch_baseline and not same_pitch(p,accepted_pitch_baseline.pitch_events[index]) and "M" or "-")
    return string.format("P%02d %s",index,markers)
  end
  local function grid_pitch_value(index,p)
    if index>#pattern.pitch_events then return "--" end
    return string.format("%d/%d%+d A%sS%s",p.note,p.key,p.octave,
      p.accent and "+" or "-",p.slide and "+" or "-")
  end
  render=function(view,property,value)
    if property~="value" and not (rawequal(view,status) and property=="text") then
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
    if property~="value" and not (rawequal(view,status) and property=="text") then
      local cache=rendered[view]
      if not cache then cache={};rendered[view]=cache end
      cache[property]=retain_render_value(value)
    end
  end
  update=function()
    updating=true
    local projection=project()
    render(view_heading,"text",editor_view==1 and "PROGRAM VIEW" or "GRID VIEW")
    render(view_hint,"text",editor_view==1 and
      "Select one PITCH entry and TIME step; the source and preview are shared with Grid." or
      "Edit sixteen PITCH positions and TIME steps directly across two pages (01–32).")
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
    if undo_button then render(undo_button,"active",history:can_undo()) end
    if redo_button then render(redo_button,"active",history:can_redo()) end
    render(preview_popup,"value",preview_cycle)
    render(preview_popup,"active",true)
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
      render(pitch_headers[cell],"text",grid_pitch_header(i,p,projection))
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
      render(time,"text",string.format("%02d %s%s",step,cmd,
        step>pattern.length and " *" or ""))
      render(time,"color",projection.error and projection.error.step==step
        and colors.warning or (step==selected_step and colors.selected)
        or (cmd=="N" and colors.note or cmd=="T" and colors.tie or colors.rest))
      render(time_header,"text",step>pattern.length and "INACTIVE" or "TIME")
      render(time_header,"style",step>pattern.length and "disabled" or "strong")
    end end
    if editor_view==2 then
      render(accent,"active",true)
      render(slide,"active",true)
    end
    local p=pitch_at(selected_pitch)
    local key,octave=sequencer.pitch_controls(p)
    if editor_view==2 then
      for key_index,button in ipairs(ui.grid.key_buttons) do
        render(button,"color",key==key_index-1 and colors.selected or colors.idle)
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
        render(button,"text",string.format("P%02d",index))
        render(button,"color",index==selected_pitch and colors.selected or colors.idle)
      end
      for cell,button in ipairs(ui.program.time_selectors) do
        local index=editor.index_on_page(time_page,cell)
        render(button,"text",string.format("T%02d%s",index,index>pattern.length and " *" or ""))
        render(button,"color",index==selected_step and colors.selected or
          (index>pattern.length and colors.idle or colors.note))
      end
      for page=1,editor.MAX_PAGES do
        render(ui.program.pitch_pages[page],"color",page==pitch_page and colors.selected or colors.idle)
        render(ui.program.time_pages[page],"color",page==time_page and colors.selected or colors.idle)
      end
      render(program_pitch_summary,"text",view_label(selected_pitch,p,projection).." | "..
        pitch_indicator(selected_pitch,projection))
      render(program_time_summary,"text",string.format("TIME %02d = %s | %s",
        selected_step,pattern.time_events[selected_step],
        selected_step<=pattern.length and editor.step_text(projection,selected_step,preview_cycle)
          or "OUTSIDE LAST STEP | READ ONLY"))
      for key_index,button in ipairs(ui.program.key_buttons) do
        render(button,"color",key==key_index-1 and colors.selected or colors.idle)
      end
      for octave_index,button in ipairs(ui.program.octave_buttons) do
        render(button,"color",octave==octave_index-2 and colors.selected or colors.idle)
      end
      render(program_accent,"value",p.accent==true)
      render(program_slide,"value",p.slide==true)
      render(program_c_plus,"active",p.octave==1)
      render(program_c_plus,"color",p.note==60 and colors.selected or colors.idle)
    end
    if editor_view==2 then
      render(grid_c_plus,"active",p.octave==1)
      render(grid_c_plus,"color",p.note==60 and colors.selected or colors.idle)
    end
    for _,button in ipairs(ui.time_assignment) do
      render(button,"active",selected_step<=pattern.length)
    end
    for tab,panel in ipairs(ui.workspace.panels) do
      render(panel,"visible",tab==workspace_tab)
      render(ui.workspace.tabs[tab],"color",tab==workspace_tab and colors.selected or colors.idle)
    end
    if ui.decoded.text then
      local first=(decoded_page-1)*4+1
      local lines={}
      for step=first,math.min(first+3,sequencer.MAX_STEPS) do
        lines[#lines+1]=string.format("%02d%s  %s",step,
          step>pattern.length and " *" or "",editor.step_text(projection,step,preview_cycle))
      end
      render(ui.decoded.text,"text",table.concat(lines,"\n"))
      render(ui.decoded.page_label,"text",string.format("TIME %02d-%02d / 32",first,math.min(first+3,32)))
      render(ui.decoded.previous,"active",decoded_page>1)
      render(ui.decoded.next,"active",decoded_page<8)
    end
    local count=0
    for _ in pairs(projection.used) do count=count+1 end
    render(summary,"text",string.format(
      "STEPS %d/32   |   NOTE triggers %d   |   PITCH active %d, stored %d, used %d",
      pattern.length,projection.note_count,pattern.pitch_length,#pattern.pitch_events,count))
    render(map_text,"text",string.format("PITCH P%02d %s | TIME %02d%s | Start: %s | Repeating: %s",
      selected_pitch,pitch_indicator(selected_pitch,projection),
      selected_step,selected_step>pattern.length and " OUTSIDE LAST STEP" or "",
      editor.step_text(projection,selected_step,1),
      editor.step_text(projection,selected_step,2)))
    local plan=projection.plan
    local error_info=projection.error
    if error_info then
      render(diagnostic,"text","ERROR: "..error_info.message..
        (error_info.step and "  [TIME "..error_info.step.."]" or "")..
        (error_info.pitch_index and "  [PITCH "..error_info.pitch_index.."]" or ""))
      if diagnostic_jump then render(diagnostic_jump,"active",true) end
    else
      render(diagnostic,"text",string.format("VALID: %d NOTE triggers; %s; Start and Repeating previews resolved.",
        plan.note_count,step_division.text))
      if diagnostic_jump then render(diagnostic_jump,"active",false) end
    end
    updating=false
  end
  local function choose_pitch(index)
    selected_pitch=index
    pitch_page=editor.page_for(index)
    update()
  end
  local function choose_time(index)
    selected_step=index
    time_page=editor.page_for(index)
    update()
  end
  navigate_diagnostic=function()
    local error_info=project().error
    if not error_info then return end
    if error_info.pitch_index then
      selected_pitch=error_info.pitch_index
      pitch_page=editor.page_for(selected_pitch)
    end
    if error_info.step then
      selected_step=error_info.step
      time_page=editor.page_for(selected_step)
    end
    update()
  end
  local function changed(request_live)
    if not history:record(pattern,output_policy,pb_range,phrase_label,phrase_label_custom) then update();return end
    local saved,save_error,effects=save_draft(request_live==false and "reset" or "edit")
    invalidate_projection()
    update()
    update_live_state(saved==true)
    local state=runtime:generation_state()
    if state.armed and request_live~=false then
      if state.pending or state.busy then
        render(status,"text",state.pending and "LIVE EDIT RENDERING: applying the latest edit next."
          or "LIVE EDIT RENDERING: applying edits.")
      end
      if not saved then render(status,"text",status.text.."\nDRAFT WARNING: "..tostring(save_error)) end
    else
      render(status,"text",saved and "Draft saved; Generate applies it, or enable Live Edit for subsequent edits."
        or ("DRAFT SAVE ERROR: session recovery only: "..tostring(save_error)))
    end
    if effects and effects.live_intent and current_session() then
      runtime:flush_pending()
    end
  end
  timing_popup:add_notifier(function(value)
    if updating then return end
    pattern.timing_mode=value==2 and "triplet" or "straight"
    changed()
  end)
  playback_popup:add_notifier(function(value)
    if updating then return end
    output_policy=value==2 and "repeat" or "play_once"
    status.text=output_policy=="repeat" and "Repeat output selected for this phrase."
      or "Play Once output selected for this phrase."
    changed()
  end)
  pb_range_popup:add_notifier(function(value)
    if updating then return end
    pb_range=pb_range_values[value] or policies.DEFAULT_PB_RANGE
    status.text=pb_range==0 and
      "Pitch bend off; connected plugin/MIDI SLIDE uses overlapping notes." or
      string.format("PB Range ±%d assumed; set the receiver to match.",pb_range)
    changed()
  end)
  local function write_pitch(key,octave,is_accent,is_slide)
    if updating then return end
    fill_to(selected_pitch)
    local current=pitch_at(selected_pitch)
    local candidate=sequencer.new_pitch(key,octave,is_accent,is_slide)
    if same_pitch(current,candidate) then return end
    pattern.pitch_events[selected_pitch]=candidate
    changed()
  end
  local function choose_key(key)
    local pitch=pitch_at(selected_pitch)
    write_pitch(key,pitch.octave,pitch.accent,pitch.slide)
  end
  local function choose_octave(octave)
    local pitch=pitch_at(selected_pitch)
    write_pitch(pitch.note%12,octave,pitch.accent,pitch.slide)
  end
  local function choose_c_plus()
    local pitch=pitch_at(selected_pitch)
    if pitch.octave~=1 then return end
    fill_to(selected_pitch)
    local candidate=sequencer.new_pitch(12,1,pitch.accent,pitch.slide)
    if same_pitch(pitch,candidate) then return end
    pattern.pitch_events[selected_pitch]=candidate
    changed()
  end
  local function set_time_command(command)
    if selected_step>pattern.length then return end
    local previous=pattern.time_events[selected_step]
    local result,reason=sequencer.set_time(pattern,selected_step,command)
    if not result then status.text=reason;return end
    if previous~=result then changed() else update() end
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
    ui.program.pitch_selectors[cell]=vb:button{width=45,text="P",notifier=function()
      choose_pitch(editor.index_on_page(pitch_page,position))
    end}
    ui.program.time_selectors[cell]=vb:button{width=45,text="T",notifier=function()
      choose_time(editor.index_on_page(time_page,position))
    end}
  end
  for page=1,editor.MAX_PAGES do
    local selected_page=page
    local page_start=(page-1)*sequencer.PAGE_SIZE+1
    ui.program.pitch_pages[page]=vb:button{id="acid_program_pitch_page_"..page,
      text=string.format("P %02d-%02d",page_start,page*sequencer.PAGE_SIZE),width=86,notifier=function()
      pitch_page=selected_page
      update()
    end}
    ui.program.time_pages[page]=vb:button{id="acid_program_time_page_"..page,
      text=string.format("T %02d-%02d",page_start,page*sequencer.PAGE_SIZE),width=86,notifier=function()
      time_page=selected_page
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
      pitch_page=page;update() end}
    time_page_buttons[p]=vb:button{id="acid_time_page_"..p,size={width=155,height=22},text="T",notifier=function()
      time_page=page;update() end}
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
    n=tonumber(n)
    if not n then update();return end
    n=math.max(1,math.min(sequencer.MAX_STEPS,math.floor(n+0.5)))
    pattern.length=n
    changed()
  end)
  pitch_length_popup:add_notifier(function(value)
    if updating then return end
    local ok,reason=sequencer.set_pitch_length(pattern,tonumber(value))
    if not ok then status.text=reason end
    if ok then changed() else update() end
  end)
  local inspect=vb:button{text="Inspect selected Renoise pattern (read only)",
    notifier=function()
      local message,err=inspector.inspect_selection()
      status.text=message or err
    end}
  local deliver
  if not active_runtime then
    active_runtime=runtime_context.new({writer=phrase_writer,capture=function() return nil,"No editor source" end,
      sink=function(request,done)
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
    local instrument=instrument_targets[selected_instrument]
    local target=phrase_targets[index]
    if target==nil then return end
    local is_new=target==false
    local requested_phrase
    if not is_new then requested_phrase=target end
    local restored,restore_error=runtime:restore_editor_target(instrument,requested_phrase,
      native_selection==true)
    local target_state=restored and restored.target or nil
    local target_index=target_state and target_state.phrase_index
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
      if restored.draft then
        status.text="Recovered saved draft. Generate or edit the source to apply it."
      elseif restored.draft_error then
        status.text="DRAFT RECOVERY ERROR: "..tostring(restored.draft_error)..
          "; existing phrase output is protected."
      elseif is_new then
        status.text="New phrase draft ready: all stored PITCH entries are C and TIME steps are NOTE."
      elseif source_available and target_index then
        status.text=string.format("Restored ACID source for phrase %02d.",target_index)
      else
        status.text="Source unavailable: "..tostring(restored.reason or "No verified source")..
          " | choose a new phrase; existing audio is protected."
      end
      render(source_state,"text",(restored.draft or is_new) and
        "SOURCE DIRTY: Generate to apply this draft." or
        (source_available and "SOURCE COMMITTED" or "SOURCE UNAVAILABLE"))
    else
      reset_source()
      accepted_pitch_baseline=assert(sequencer.copy_source(pattern))
      status.text="Source unavailable: "..tostring(restore_error or "Cannot restore editor target")..
        " | choose a new phrase; existing audio is protected."
      render(source_state,"text",is_new and "SOURCE DIRTY: Generate to apply this draft." or
        "SOURCE UNAVAILABLE")
    end
    history:reset(pattern,output_policy,pb_range,phrase_label,phrase_label_custom)
    update()
    if update_live_state then update_live_state() end
  end
  local phrase_names
  phrase_names,phrase_targets=options_for_instrument()
  phrase_choice=vb:popup{width=360,items=phrase_names,
    value=#phrase_names,notifier=function(n)
      if not loading then
        load_target(n)
      end
    end}
  local function select_instrument(n)
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
  apply_pending_selected_phrase_selection=function()
    if not current_session() then return false end
    if native_projection_dirty then native_observers:refresh() end
    local before=destination()
    local target,effects=runtime:reconcile()
    if native_projection_dirty then
      native_projection_dirty=false
      refresh_native_choices()
      invalidate_projection()
      if update_actions then update_actions() end
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
      status.text=target.reason or "Native destination is unavailable; select the destination again."
      return false
    end
    if not target or (rawequal(before.instrument,target.instrument) and
        rawequal(before.phrase,target.phrase) and before.kind==target.kind) then return false end
    if target.kind~="owned" then
      if target.phrase then refresh_phrase_choices(target.phrase) end
      status.text=target.reason or "Native destination is unavailable; select the destination again."
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
        status.text="Native destination is unavailable; select the destination again."
        return false
      end
    end
    if target.phrase then
      refresh_phrase_choices(target.phrase)
      for choice,phrase in ipairs(phrase_targets) do
        if rawequal(phrase,target.phrase) then load_target(choice,true);return true end
      end
    end
    status.text="Native destination is unavailable; select the destination again."
    return false
  end
  local target=vb:popup{width=290,items=labels,value=selected_instrument,
    notifier=function(n)if not loading then select_instrument(n) end end}
  instrument_choice=target
  local function result_status(result)
    if result.kind=="success" then
      return (result.status=="approximate" or result.approximate==true) and "APPROXIMATE" or "COMMITTED"
    end
    local status=tostring(result.status or "error")
    if status=="failed" or status=="error" then return "ERROR" end
    return string.upper(status)
  end
  local function describe_result(result,prefix)
    local message=prefix..result_status(result)..": "..
      tostring(result.reason or result.message or result.code or "Phrase generation ended")
    if type(result.diagnostics)=="table" and #result.diagnostics>0 then
      local details={}
      for _,detail in ipairs(result.diagnostics) do
        if not message:find(tostring(detail),1,true) then
          details[#details+1]=tostring(detail)
        end
      end
      if #details>0 then message=message.."\n"..table.concat(details,"\n") end
    end
    return message
  end
  update_live_state=function(skip_actions)
    if update_actions and not skip_actions then update_actions() end
    local state=runtime:generation_state()
    if not state.armed then
      render(live_state_view,"text","LIVE EDIT DISABLED")
      return
    end
    local text="LIVE EDIT "..state.status
    if state.last_commit then
      local commit=state.last_commit
      text=text.."\nLAST COMMIT: "..
        string.upper(tostring(commit.status or "committed")).." | "..
        tostring(state.last_commit_label or "Verified destination")
    end
    render(live_state_view,"text",text)
  end
  deliver=function(request,result)
    if type(request)~="table" or not current_session() then return end
    local success=result.kind=="success" and result.verified==true
    local prefix=request.trigger=="manual" and "GENERATION " or "LIVE EDIT "
    if success then
      local accepted=runtime:editor_state()
      if accepted and sequencer.same_source(accepted.source,pattern) and
          (phrase_label~=accepted.label or phrase_label_custom~=accepted.label_custom) then
        phrase_label=accepted.label or "Untitled"
        phrase_label_custom=accepted.label_custom==true
        history:record(pattern,output_policy,pb_range,phrase_label,phrase_label_custom)
      end
      if result.stale==true or result.destination_current~=true or not result.phrase or
          not rawequal(result.phrase,bound_phrase()) then
        render(source_state,"text","SOURCE UNAVAILABLE")
        status.text=prefix.."ERROR: destination identity could not be verified; select the destination again."
        update_live_state()
        return
      end
      refresh_phrase_choices(result.phrase)
      local committed=runtime:editor_state()
      if committed and sequencer.same_source(committed.source,pattern) then
        accepted_pitch_baseline=assert(sequencer.copy_source(committed.source))
        update()
      end
      render(source_state,"text","SOURCE COMMITTED")
    end
    status.text=describe_result(result,prefix)
    update_live_state()
  end
  live_checkbox=vb:checkbox{id="acid_live_edit",value=false,notifier=function(value)
    if value then
      apply_pending_selected_phrase_selection()
      runtime:transition("arm")
      status.text="Live Edit enabled; the next source edit will be applied."
      update_live_state()
    else
      runtime:transition("disarm")
      update_live_state()
      status.text="Live Edit disabled; manual Generate/Regenerate is available."
    end
  end}
  active_live_checkbox=live_checkbox
  local function move_history(direction)
    local proposal=history:propose(direction)
    if not proposal then return end
    local next_state=proposal.state
    local difference=editor.classify_difference({pattern=pattern,output_policy=output_policy,
      pb_range=pb_range,label=phrase_label,label_custom=phrase_label_custom},next_state)
    if difference=="label_only" then
      local saved,reason=runtime:rename_label(next_state.label,next_state.label_custom)
      if not saved then status.text="Label history change was not saved: "..tostring(reason);return end
      if not history:commit(proposal) then return end
      phrase_label,phrase_label_custom=next_state.label,next_state.label_custom
      status.text=direction=="undo" and "Label change undone and saved." or "Label change redone and saved."
      update();update_live_state()
      return
    end
    pattern=next_state.pattern
    output_policy=next_state.output_policy
    pb_range=next_state.pb_range
    phrase_label,phrase_label_custom=next_state.label,next_state.label_custom
    if not history:commit(proposal) then return end
    invalidate_projection()
    local saved,save_error=save_draft()
    status.text=saved and (direction=="undo" and "Edit undone and saved with the song." or
      "Edit redone and saved with the song.") or
      (direction=="undo" and "Edit undone; session recovery only: " or
      "Edit redone; session recovery only: ")..tostring(save_error)
    update();update_live_state()
  end
  undo_button=vb:button{text="Undo",active=false,notifier=function()
    move_history("undo")
  end}
  redo_button=vb:button{text="Redo",active=false,notifier=function()
    move_history("redo")
  end}
  local recovery_entries={}
  local recovery_choice
  local copy_recovery,discard_recovery,independent,revalidate
  local recovery_detail=vb:multiline_text{id="acid_recovery_detail",size={width=820,height=56},text=""}
  ui.recovery={page=1,lines={""},detail=recovery_detail}
  local render_recovery_page
  ui.recovery.previous=vb:button{id="acid_recovery_previous",text="Previous",width=90,
    notifier=function()
      if ui.recovery.page>1 then ui.recovery.page=ui.recovery.page-1;render_recovery_page() end
    end}
  ui.recovery.next=vb:button{id="acid_recovery_next",text="Next",width=90,
    notifier=function()
      local pages=math.max(1,math.ceil(#ui.recovery.lines/4))
      if ui.recovery.page<pages then ui.recovery.page=ui.recovery.page+1;render_recovery_page() end
    end}
  ui.recovery.page_label=vb:text{id="acid_recovery_page_label",text="1 / 1",font="bold"}
  local function selected_recovery()
    return recovery_choice and recovery_entries[recovery_choice.value]
  end
  render_recovery_page=function()
    local page_size=4
    local pages=math.max(1,math.ceil(#ui.recovery.lines/page_size))
    ui.recovery.page=math.max(1,math.min(pages,ui.recovery.page))
    local first=(ui.recovery.page-1)*page_size+1
    local visible={}
    for index=first,math.min(first+page_size-1,#ui.recovery.lines) do
      visible[#visible+1]=ui.recovery.lines[index]
    end
    render(ui.recovery.detail,"text",table.concat(visible,"\n"))
    render(ui.recovery.page_label,"text",string.format("%d / %d",ui.recovery.page,pages))
    render(ui.recovery.previous,"active",ui.recovery.page>1)
    render(ui.recovery.next,"active",ui.recovery.page<pages)
  end
  local function project_runtime_editor()
    local state=runtime:editor_state()
    if not state then return end
    pattern,output_policy,pb_range=state.source,state.output_policy,state.pb_range
    phrase_label,phrase_label_custom=state.label or "Untitled",state.label_custom==true
    accepted_pitch_baseline=assert(sequencer.copy_source(pattern))
    selected_pitch,selected_step,pitch_page,time_page=1,1,1,1
    invalidate_projection()
    history:reset(pattern,output_policy,pb_range,phrase_label,phrase_label_custom)
    update()
  end
  recovery_choice=vb:popup{id="acid_recovery_choice",width=420,items={"No detached drafts"},value=1,
    notifier=function() if not loading and update_actions then update_actions() end end}
  copy_recovery=vb:button{id="acid_recovery_copy",text="Copy to New",active=false,notifier=function()
    if not current_session() then return end
    local entry=selected_recovery()
    if not entry then return end
    local copied,reason=runtime:copy_recovery_to_new(entry.token,entry.revision)
    if copied then
      refresh_phrase_choices()
      project_runtime_editor()
      render(source_state,"text","SOURCE DIRTY: Generate to apply this recovered draft.")
      status.text="Draft copied to New. The original recovery entry stays until this revision is generated or discarded."
      if type(reason)=="table" and reason.warning then
        status.text=status.text.."\nDRAFT WARNING: "..tostring(reason.warning)
      end
    else status.text="Cannot recover draft: "..tostring(reason) end
    update_live_state()
  end}
  discard_recovery=vb:button{id="acid_recovery_discard",text="Discard",active=false,notifier=function()
    if not current_session() then return end
    local entry=selected_recovery()
    if not entry then return end
    local discarded,reason=runtime:discard_recovery(entry.token,entry.revision)
    status.text=discarded and "Selected recovery entry discarded." or ("Cannot discard draft: "..tostring(reason))
    update_live_state()
  end}
  independent=vb:button{id="acid_make_independent",text="Make Independent",active=false,notifier=function()
    if not current_session() then return end
    local changed,result=runtime:make_independent()
    if changed then
      refresh_phrase_choices(result.phrase)
      project_runtime_editor()
      local state=runtime:editor_state()
      local dirty=state and (not sequencer.same_source(state.source,result.source) or
        state.output_policy~=result.output_policy or state.pb_range~=result.pb_range)
      render(source_state,"text",dirty and "SOURCE DIRTY: Generate to apply this draft." or "SOURCE COMMITTED")
      status.text="Selected phrase is independent. Its musical content is unchanged."
      if result.warning then status.text=status.text.."\n"..tostring(result.warning) end
      if state and state.draft_warning then
        status.text=status.text.."\nDRAFT WARNING: "..tostring(state.draft_warning)
      end
    else status.text="Cannot make independent: "..tostring(result) end
    update_live_state()
  end}
  revalidate=vb:button{id="acid_revalidate",text="Revalidate",active=false,notifier=function()
    if not current_session() then return end
    local state,proof=runtime:revalidation_status()
    if not state.verified then status.text=state.reason or "Recovery consistency could not be verified."
    else
      local cleared,reason=runtime:revalidate(proof)
      status.text=cleared and "Recovery verified. Generate or edit explicitly to continue." or tostring(reason)
    end
    update_live_state()
  end}
  update_actions=function()
    local previous=selected_recovery()
    recovery_entries=runtime:recovery_entries() or {}
    local items,chosen={},1
    for index,entry in ipairs(recovery_entries) do
      local names=entry.labels or {}
      items[index]=(names.instrument or "Unavailable instrument").." / "..(names.phrase or "Draft")
      if previous and previous.token==entry.token and previous.revision==entry.revision then chosen=index end
    end
    if #items==0 then items[1]="No detached drafts" end
    loading=true
    render(recovery_choice,"items",items)
    render(recovery_choice,"value",chosen)
    loading=false
    local entry=selected_recovery()
    render(recovery_choice,"active",entry~=nil)
    render(copy_recovery,"active",entry~=nil and current_session() and bound_instrument()~=nil)
    render(discard_recovery,"active",entry~=nil and current_session())
    local recovery_reason=entry and ("Session only: "..tostring(entry.reason or "Detached draft"))
      or "No detached recovery draft is selected."
    local eligible,reason=runtime:independence_projection()
    render(independent,"active",eligible~=nil and current_session())
    local detail=eligible and "Resolve this copied-ID collision without changing the music."
      or tostring(reason or "Select a colliding phrase to make it independent.")
    local integrity=runtime:integrity_state()
    render(revalidate,"active",integrity.blocked and current_session())
    if integrity.blocked then detail=integrity.reason or "Recovery consistency requires revalidation." end
    local combined="RECOVERY: "..recovery_reason.."\nOWNERSHIP: "..detail
    ui.recovery.lines=wrap_lines(combined,100)
    render_recovery_page()
  end
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
  program_panel=vb:column{id="acid_program_panel",spacing=4,
    vb:text{text="PITCH POSITION | page and position selection are independent of TIME",font="bold"},
    program_pitch_page_row,selector_rows(ui.program.pitch_selectors),program_pitch_summary,
    vb:row{spacing=4,vb:text{text="PITCH CLASS"},program_keyboard},
    vb:row{spacing=4,vb:text{text="OCTAVE"},program_octave_row,
      vb:text{text="ACCENT"},program_accent,vb:text{text="SLIDE"},program_slide,program_c_plus},
    vb:text{text="TIME POSITION | inactive positions remain inspectable",font="bold"},
    program_time_page_row,selector_rows(ui.program.time_selectors),program_time_summary}
  grid_panel=vb:column{id="acid_grid_panel",spacing=4,
    vb:text{text="PITCH MEMORY | S stored, R referenced, M modified; dim entries are outside active span",font="bold"},
    pitch_pages,pitch_grid,
    vb:row{spacing=4,vb:text{text="PITCH CLASS"},grid_keyboard},
    vb:row{spacing=4,vb:text{text="OCTAVE"},grid_octave_row,
      vb:text{text="ACCENT"},accent,vb:text{text="SLIDE"},slide,grid_c_plus},
    vb:text{text="TIME MEMORY | choose a step, then use shared assignment controls",font="bold"},
    time_pages,time_grid}
  local decoded_previous_button=vb:button{id="acid_decoded_previous",text="Previous 4",width=100,notifier=function()
    if decoded_page>1 then decoded_page=decoded_page-1;update() end
  end}
  local decoded_next_button=vb:button{id="acid_decoded_next",text="Next 4",width=100,notifier=function()
    if decoded_page<8 then decoded_page=decoded_page+1;update() end
  end}
  ui.decoded.previous,ui.decoded.next=decoded_previous_button,decoded_next_button
  ui.decoded.page_label=vb:text{id="acid_decoded_page_label",text="TIME 01-04 / 32",font="bold"}
  ui.decoded.text=vb:multiline_text{id="acid_decoded_rows",size={width=820,height=76},text=""}
  local decoded_panel=vb:column{id="acid_decoded_panel",spacing=4,
    vb:row{spacing=6,vb:text{text="Decoded view"},preview_popup,decoded_previous_button,
      ui.decoded.page_label,decoded_next_button},ui.decoded.text}
  local pattern_copy_panel=vb:column{id="acid_pattern_copy_panel",spacing=4,
    vb:text{text="PATTERN / COPY",font="bold"},
    vb:text{text="Session copy and paste controls are not available in this editor build."}}
  local extended_panel=vb:column{id="acid_extended_panel",spacing=4,
    vb:text{text="EXTENDED / CLEAR",font="bold"},
    vb:text{text="Extended transformations and scoped clear controls are not available here."}}
  local output_panel=vb:column{id="acid_output_panel",spacing=4,
    vb:text{text="OUTPUT",font="bold"},
    vb:row{spacing=8,vb:text{text="Phrase output"},playback_popup,
      vb:text{text="PB Range"},pb_range_popup},
    vb:text{text="Assumes the receiver's matching bend range; pitch bend is channel-wide. Use isolated monophonic routing."}}
  local recovery_panel=vb:column{id="acid_recovery_panel",spacing=3,
    vb:row{spacing=8,independent,revalidate},
    vb:row{spacing=6,vb:text{text="Recover Draft"},recovery_choice,copy_recovery,discard_recovery},
    recovery_detail,
    vb:row{spacing=6,ui.recovery.previous,ui.recovery.page_label,ui.recovery.next}}
  local tab_names={"Decoded","Pattern / Copy","Extended / Clear","Output","Recovery"}
  local tab_row=vb:row{spacing=4}
  for index,name in ipairs(tab_names) do
    local tab=index
    ui.workspace.tabs[index]=vb:button{width=150,text=name,notifier=function()
      workspace_tab=tab
      update()
    end}
    tab_row:add_child(ui.workspace.tabs[index])
  end
  ui.workspace.panels={decoded_panel,pattern_copy_panel,extended_panel,output_panel,recovery_panel}
  local workspace=vb:column{spacing=4,tab_row,
    vb:stack{autosize=false,size={width=820,height=132},views={
      decoded_panel,pattern_copy_panel,extended_panel,output_panel,recovery_panel}}
  }
  for _,panel in ipairs(ui.workspace.panels) do
    panel.origin={0,0}
    panel.size={width=820,height=132}
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
      vb:button{text="Reset Source",notifier=function()
        reset_source(last_step_box.value)
        selected_pitch=1;selected_step=1;pitch_page=1;time_page=1
        status.text="Source reset: all PITCH entries are C and active TIME steps are NOTE."
        changed(false)
      end},
      undo_button,
      redo_button,
      vb:text{text="Undo and Redo include source, phrase output, and PB Range."}},
    view_heading,view_hint,program_panel,grid_panel,
    vb:row{spacing=5,vb:text{text="Assign selected TIME"},
      ui.time_assignment[1],ui.time_assignment[2],ui.time_assignment[3]},
    workspace,
    summary,map_text,diagnostic,diagnostic_jump,
    vb:row{spacing=8,vb:text{text="Live Edit (automatic regeneration)"},live_checkbox,
      vb:button{text="Retry Live Edit",notifier=function()
        if runtime:revision_state().armed then
          local accepted,reason=runtime:request_generation("live")
          if not accepted then status.text=describe_result({kind="failure",status="error",reason=reason},"LIVE EDIT ") end
        end
        update_live_state()
      end}},
    vb:row{spacing=8,
      vb:button{text="Generate / Regenerate ACID Phrase",notifier=function()
        if not current_session() then
          status.text="Song changed. Close and reopen ACID.";return
        end
        apply_pending_selected_phrase_selection()
        local projection=project()
        if projection.error then
          local e=projection.error
          if e.step then choose_time(e.step) end
          if e.pitch_index then choose_pitch(e.pitch_index) end
          status.text="Cannot generate: "..e.message
          return
        end
        local accepted,reason=runtime:request_generation("manual")
        if not accepted then status.text="Cannot generate: "..tostring(reason)
        elseif reason then status.text=tostring(reason) end
      end},
      vb:button{text="Sampler audit",notifier=function()
        status.text=sampler.describe(instrument_targets[selected_instrument])
      end}},
    vb:text{text="Live Edit applies changes automatically. With Live Edit off, Generate applies the saved draft."},
    source_state,live_state_view,inspect,status}
  select_instrument(selected_instrument)
  native_observers:attach(song,runtime,function()
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
