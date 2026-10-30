-- SPDX-License-Identifier: GPL-3.0-only
-- Native ViewBuilder PITCH/TIME editor.
local M = {}
local sequencer=require("model.sequencer")
local policies=require("model.policies")
local editor=require("model.editor_state")
local drafts=require("runtime.draft_cache")
local store=require("renoise.pattern_store")
local ownership=require("renoise.phrase_ownership")
local phrase_writer=require("writers.phrase_writer")
local inspector=require("renoise.selection_context")
local sampler=require("renoise.sampler_audit")
local dialog
local runtime_context=require("runtime.context")
local active_runtime
local active_live_checkbox
local attached_song
local dialog_session
local idle_observable
local idle_notifier
local selected_phrase_observable
local selected_phrase_notifier
local function detach_selected_phrase_watch()
  if selected_phrase_observable and selected_phrase_notifier then
    pcall(function()
      selected_phrase_observable:remove_notifier(selected_phrase_notifier)
    end)
  end
  selected_phrase_observable,selected_phrase_notifier=nil,nil
end
local function detach_dialog_watch()
  detach_selected_phrase_watch()
  if idle_observable and idle_notifier then
    pcall(function() idle_observable:remove_notifier(idle_notifier) end)
  end
  idle_observable,idle_notifier=nil,nil
end
local function stop_live_context()
  if active_runtime then
    active_runtime:transition("disarm")
    active_runtime:close_dialog()
  end
  if active_live_checkbox then active_live_checkbox.value=false end
  active_live_checkbox=nil
end
local function release_context()
  attached_song=nil
  if active_runtime then active_runtime:release_document() end
  detach_dialog_watch()
  stop_live_context()
  phrase_writer.release()
end
if renoise.tool().app_release_document_observable then
  renoise.tool().app_release_document_observable:add_notifier(function()
    local song=renoise.song()
    if song and drafts.has_volatile(song) then
      renoise.app():show_warning(
        "ACID has drafts that could not be saved with this song. They will be lost when it closes.")
    end
    release_context()
  end)
end
if renoise.tool().tool_will_unload_observable then
  renoise.tool().tool_will_unload_observable:add_notifier(release_context)
end
renoise.tool().app_new_document_observable:add_notifier(release_context)

local keys={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B","C+"}
local octave_names={"DOWN (-1)","NORMAL (0)","UP (+1)"}
local colors={selected={0xF0,0x70,0x70},used={0x55,0xAA,0x75},
  idle={0x49,0x4B,0x55},note={0xBD,0x5B,0x5B},
  tie={0x5D,0x88,0xB7},rest={0x4B,0x4D,0x56},
  warning={0xF2,0x77,0x77}}

function M.show()
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
  local song=renoise.song()
  if not song then renoise.app():show_warning("Open a song first.");return end
  local vb=renoise.ViewBuilder()
  local pattern
  local pitch_page,time_page=1,1
  local selected_pitch,selected_step=1,1
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
  local function reset_source(length)
    pattern=sequencer.new_pattern(length)
    output_policy=policies.DEFAULT_OUTPUT_POLICY
    pb_range=policies.DEFAULT_PB_RANGE
  end
  reset_source()
  local history=editor.new_history(pattern,output_policy,pb_range)
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
  local status=vb:multiline_textfield{width=820,height=80,active=true,
    font="bold",text="Draft ready: edit PITCH and TIME memories or generate a phrase."}
  local live_state_view=vb:multiline_text{id="acid_live_edit_state",width=820,height=48,font="bold",
    text="LIVE EDIT DISABLED"}
  local source_state=vb:text{id="acid_source_state",width=820,font="bold",text=""}
  local diagnostic=vb:text{id="acid_source_diagnostic",width=820,font="bold",text=""}
  local navigate_diagnostic
  local diagnostic_jump=vb:button{text="Go to source error",active=false,notifier=function()
    if navigate_diagnostic then navigate_diagnostic() end
  end}
  local summary=vb:text{id="acid_source_summary",width=820,font="bold",text=""}
  local map_text=vb:text{id="acid_preview_summary",width=820,font="bold",text=""}
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
  local program_pitch_popup,program_time_popup,program_time_command
  local program_pitch_summary,program_time_summary
  local program_key_popup,program_octave_popup,program_accent,program_slide
  local pitch_length_popup=vb:popup{items=length_items,width=78,value=sequencer.PAGE_SIZE}
  local timing_popup=vb:popup{id="acid_timing",items={"Straight","Triplet"},width=105,value=1}
  local playback_popup=vb:popup{items={"Play Once","Repeat"},width=105,value=2}
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
  local pitch_cells,time_cells,time_headers,preview_cells={}, {}, {}, {}
  local key_popup=vb:popup{items=keys,width=95,value=1}
  local octave_popup=vb:popup{items=octave_names,width=135,value=2}
  local accent=vb:checkbox{value=false}
  local slide=vb:checkbox{value=false}
  local phrase_choice,phrase_targets
  local bind_selected_phrase_watch
  local apply_pending_selected_phrase_selection
  local instrument_choice
  local live_checkbox
  local function destination() return runtime:target_state() end
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
      cached_projection=editor.project(pattern)
      projected_revision=revision()
      projected_instrument,projected_phrase=bound_instrument(),bound_phrase()
    end
    return cached_projection
  end
  local update_live_state
  local function save_draft(kind)
    runtime:transition(kind or "edit",{source=pattern,output_policy=output_policy,pb_range=pb_range})
    source_state.text="SOURCE DIRTY: Generate to apply this draft."
    if not bound_instrument() then return true end
    local state=runtime:editor_state()
    return state and not state.draft_warning,state and state.draft_warning
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
  local function view_label(index,p,projection)
    if index>#pattern.pitch_events then return string.format("P%02d --",index) end
    local key,octave=sequencer.pitch_controls(p)
    local suffix=key and string.format("%s %s",keys[key+1],
      ({"-1"," 0","+1"})[octave+2]) or tostring(p.note)
    return string.format("P%02d %s%s%s%s",index,suffix,
      index>pattern.pitch_length and " [inactive]" or "",
      p.accent and " A" or "",p.slide and " S" or "")
  end
  update=function()
    updating=true
    local projection=project()
    view_heading.text=editor_view==1 and "PROGRAM VIEW" or "GRID VIEW"
    view_hint.text=editor_view==1 and
      "Select one PITCH entry and TIME step; the source and preview are shared with Grid." or
      "Edit sixteen PITCH positions and TIME steps directly across two pages (01–32)."
    if program_panel then program_panel.visible=editor_view==1 end
    if grid_panel then grid_panel.visible=editor_view==2 end
    pitch_length_popup.value=pattern.pitch_length or sequencer.PAGE_SIZE
    pitch_length_popup.active=true
    timing_popup.value=pattern.timing_mode=="triplet" and 2 or 1
    step_division.text=pattern.timing_mode=="triplet" and
      string.format("1/8 triplet; cycle %d/3 beats",pattern.length) or
      string.format("1/16 straight; cycle %d/4 beats",pattern.length)
    playback_popup.value=output_policy=="play_once" and 1 or 2
    playback_popup.active=true
    for index,value in ipairs(pb_range_values) do
      if value==pb_range then pb_range_popup.value=index;break end
    end
    pb_range_popup.active=true
    if undo_button then undo_button.active=history:can_undo() end
    if redo_button then redo_button.active=history:can_redo() end
    preview_popup.value=preview_cycle
    preview_popup.active=true
    last_step_box.value=pattern.length
    last_step_box.active=true
    for page=1,editor.MAX_PAGES do
      local first=(page-1)*sequencer.PAGE_SIZE+1
      local last=math.min(page*sequencer.PAGE_SIZE,pattern.length)
      pitch_page_buttons[page].text=string.format("P %02d-%02d%s",
        first,page*sequencer.PAGE_SIZE,page==pitch_page and " [*]" or "")
      time_page_buttons[page].text=string.format("T %02d-%02d%s",
        first,page*sequencer.PAGE_SIZE,page==time_page and " [*]" or "")
      time_page_buttons[page].active=first<=pattern.length
    end
    for cell=1,sequencer.PAGE_SIZE do
      local i=editor.index_on_page(pitch_page,cell)
      local p=pitch_at(i)
      local b=pitch_cells[cell]
      b.active=true
      b.text=view_label(i,p,projection)
      b.color=i==selected_pitch and colors.selected
        or (projection.used[i] and colors.used or colors.idle)
      local step=editor.index_on_page(time_page,cell)
      local time=time_cells[cell]
      local time_header=time_headers[cell]
      local preview=preview_cells[cell]
      if step<=pattern.length then
        local cmd=pattern.time_events[step]
        time.active=true
        time.value=cmd=="N" and 1 or cmd=="T" and 2 or 3
        time_header.active=true
        time_header.text=string.format("STEP %02d",step)
        time_header.color=projection.error and projection.error.step==step
          and colors.warning or (step==selected_step and colors.selected)
          or (cmd=="N" and colors.note or cmd=="T" and colors.tie or colors.rest)
        preview.text=string.format("%02d %s",step,editor.step_text(projection,step,preview_cycle))
        preview.color=projection.error and projection.error.step==step
          and colors.warning or (step==selected_step and colors.selected)
          or colors.idle
      else
        time.active=false
        time.value=3
        time_header.active=false
        time_header.text="--"
        time_header.color=colors.idle
        preview.text=""
        preview.color=colors.idle
      end
    end
    key_popup.active=true
    octave_popup.active=true
    accent.active=true
    slide.active=true
    local p=pitch_at(selected_pitch)
    local key,octave=sequencer.pitch_controls(p)
    key_popup.value=(key or 0)+1
    octave_popup.value=(octave or 0)+2
    accent.value=p.accent==true
    slide.value=p.slide==true
    if program_pitch_popup then
      program_pitch_popup.value=selected_pitch
      program_time_popup.value=selected_step
      local command=pattern.time_events[selected_step]
      program_time_command.value=command=="N" and 1 or command=="T" and 2 or 3
      program_time_command.active=selected_step<=pattern.length
      program_pitch_summary.text=view_label(selected_pitch,p,projection)
      program_time_summary.text=string.format("%s  %s",
        selected_step<=pattern.length and "ACTIVE" or "OUTSIDE LAST STEP",
        editor.step_text(projection,selected_step,preview_cycle))
      program_key_popup.value=(key or 0)+1
      program_octave_popup.value=(octave or 0)+2
      program_accent.value=p.accent==true
      program_slide.value=p.slide==true
    end
    local count=0
    for _ in pairs(projection.used) do count=count+1 end
    summary.text=string.format(
      "STEPS %d/32   |   NOTE triggers %d   |   PITCH active %d, stored %d, used %d",
      pattern.length,projection.note_count,pattern.pitch_length,#pattern.pitch_events,count)
    local pitch_usage=projection.used[selected_pitch] and "USED" or "UNUSED"
    map_text.text=string.format("TIME %02d Start: %s  |  Repeating: %s  |  PITCH P%02d: %s",
      selected_step,editor.step_text(projection,selected_step,1),
      editor.step_text(projection,selected_step,2),
      selected_pitch,pitch_usage)
    local plan=projection.plan
    local error_info=projection.error
    if error_info then
      diagnostic.text="ERROR: "..error_info.message..
        (error_info.step and "  [TIME "..error_info.step.."]" or "")..
        (error_info.pitch_index and "  [PITCH "..error_info.pitch_index.."]" or "")
      if diagnostic_jump then diagnostic_jump.active=true end
    else
      diagnostic.text=string.format("VALID: %d NOTE triggers; %s; Start and Repeating previews resolved.",
        plan.note_count,step_division.text)
      if diagnostic_jump then diagnostic_jump.active=false end
    end
    updating=false
  end
  local function choose_pitch(index)
    selected_pitch=index
    pitch_page=editor.page_for(index)
    local projection=project()
    local mapping=preview_cycle==2 and projection.repeat_mapping or projection.mapping
    -- Highlight the earliest NOTE that consumes this pitch position;
    -- TIE holds do not consume another pitch.
    for step=1,pattern.length do
      local event=mapping[step]
      if event and event.kind=="note" and event.pitch_index==index then
        selected_step=step
        time_page=editor.page_for(step)
        break
      end
    end
    update()
  end
  local function choose_time(index)
    selected_step=index
    time_page=editor.page_for(index)
    local projection=project()
    local mapping=preview_cycle==2 and projection.repeat_mapping or projection.mapping
    local event=mapping[index]
    if event and event.pitch_index then
      selected_pitch=event.pitch_index
      pitch_page=editor.page_for(selected_pitch)
    end
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
    if not history:record(pattern,output_policy,pb_range) then update();return end
    local saved,save_error=save_draft(request_live==false and "reset" or "edit")
    update()
    update_live_state()
    local state=runtime:generation_state()
    if state.armed and request_live~=false then
      if state.pending or state.busy then
        status.text=state.pending and "LIVE EDIT RENDERING: applying the latest edit next."
          or "LIVE EDIT RENDERING: applying edits."
      end
      if not saved then status.text=status.text.."\nDRAFT WARNING: "..tostring(save_error) end
    else
      status.text=saved and "Draft saved; Generate applies it, or enable Live Edit for subsequent edits."
        or ("DRAFT SAVE ERROR: session recovery only: "..tostring(save_error))
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
    pattern.pitch_events[selected_pitch]=sequencer.new_pitch(
      key,octave,is_accent,is_slide)
    changed()
  end
  local function change_pitch()
    write_pitch(key_popup.value-1,octave_popup.value-2,accent.value,slide.value)
  end
  key_popup:add_notifier(change_pitch)
  octave_popup:add_notifier(change_pitch)
  accent:add_notifier(change_pitch)
  slide:add_notifier(change_pitch)
  local pitch_items,time_items={},{}
  for index=1,sequencer.MAX_STEPS do
    pitch_items[index]=string.format("P%02d",index)
    time_items[index]=string.format("TIME %02d",index)
  end
  program_pitch_popup=vb:popup{id="acid_program_pitch_position",items=pitch_items,width=100,value=1,
    notifier=function(value)
      if not updating then choose_pitch(value) end
    end}
  program_time_popup=vb:popup{id="acid_program_time_position",items=time_items,width=110,value=1,
    notifier=function(value)
      if not updating then choose_time(value) end
    end}
  program_time_command=vb:popup{id="acid_program_time_command",items={"NOTE","TIE","REST"},width=100,value=1,
    notifier=function(choice)
      if updating or selected_step>pattern.length then return end
      local command,reason=sequencer.set_time(pattern,selected_step,
        ({"N","T","R"})[choice])
      if not command then status.text=reason;return end
      changed()
    end}
  program_key_popup=vb:popup{id="acid_program_key_popup",items=keys,width=95,value=1,
    notifier=function(value)
      if not updating then
        write_pitch(value-1,program_octave_popup.value-2,
          program_accent.value,program_slide.value)
      end
    end}
  program_octave_popup=vb:popup{id="acid_program_octave_popup",items=octave_names,width=135,value=2,
    notifier=function(value)
      if not updating then
        write_pitch(program_key_popup.value-1,value-2,
          program_accent.value,program_slide.value)
      end
    end}
  program_accent=vb:checkbox{id="acid_program_accent",value=false,notifier=function(value)
    if not updating then
      write_pitch(program_key_popup.value-1,program_octave_popup.value-2,
        value,program_slide.value)
    end
  end}
  program_slide=vb:checkbox{id="acid_program_slide",value=false,notifier=function(value)
    if not updating then
      write_pitch(program_key_popup.value-1,program_octave_popup.value-2,
        program_accent.value,value)
    end
  end}
  program_pitch_summary=vb:text{id="acid_program_pitch_summary",text="P01",font="bold"}
  program_time_summary=vb:text{id="acid_program_time_summary",text="TIME 01",font="bold"}
  local pitch_grid=vb:column{spacing=4}
  local time_grid=vb:column{spacing=4}
  local preview_grid=vb:column{spacing=4}
  local pitch_pages=vb:row{spacing=6}
  local time_pages=vb:row{spacing=6}
  for p=1,editor.MAX_PAGES do
    local page=p
    pitch_page_buttons[p]=vb:button{width=155,text="P",notifier=function()
      pitch_page=page;update() end}
    time_page_buttons[p]=vb:button{width=155,text="T",notifier=function()
      time_page=page;update() end}
    pitch_pages:add_child(pitch_page_buttons[p])
    time_pages:add_child(time_page_buttons[p])
  end
  local grid_columns=sequencer.PAGE_SIZE/2
  for row=1,2 do
    local p_row=vb:row{spacing=4}
    local t_row=vb:row{spacing=4}
    local v_row=vb:row{spacing=4}
    for col=1,grid_columns do
      local cell=(row-1)*grid_columns+col
      pitch_cells[cell]=vb:button{id=string.format("acid_grid_pitch_%02d",cell),width=98,height=38,text="--",notifier=function()
        choose_pitch(editor.index_on_page(pitch_page,cell)) end}
      time_headers[cell]=vb:button{width=98,height=22,text="--",
        notifier=function()
          local step=editor.index_on_page(time_page,cell)
          if step<=pattern.length then choose_time(step) end
        end}
      time_cells[cell]=vb:popup{id=string.format("acid_grid_time_%02d",cell),width=98,
        items={"NOTE","TIE","REST"},value=3,notifier=function(choice)
          if updating then return end
          local step=editor.index_on_page(time_page,cell)
          if step<=pattern.length then
            local command,reason=sequencer.set_time(pattern,step,( {"N","T","R"})[choice])
            if not command then status.text=reason end
            changed()
            choose_time(step)
          end
        end}
      preview_cells[cell]=vb:button{width=98,height=32,text="--",notifier=function()
        local step=editor.index_on_page(time_page,cell)
        if step<=pattern.length then choose_time(step) end
      end}
      p_row:add_child(pitch_cells[cell])
      t_row:add_child(vb:column{spacing=2,
        time_headers[cell],time_cells[cell]})
      v_row:add_child(preview_cells[cell])
    end
    pitch_grid:add_child(p_row)
    time_grid:add_child(t_row)
    preview_grid:add_child(v_row)
  end
  last_step_box:add_notifier(function(n)
    if updating then return end
    n=tonumber(n)
    if not n then update();return end
    n=math.max(1,math.min(sequencer.MAX_STEPS,math.floor(n+0.5)))
    pattern.length=n
    if selected_step>n then selected_step=n end
    if editor.page_for(selected_step)~=time_page then
      time_page=editor.page_for(selected_step)
    end
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
        names[#names+1]=string.format("%02d: %s (%s)",choice.phrase_index,
          choice.phrase_name,ownership.status(choice.phrase))
        targets[#targets+1]=choice.phrase
      end
    end
    names[#names+1]="NEW PHRASE (append)"
    targets[#targets+1]=false
    return names,targets
  end
  local function load_target(index)
    local instrument=instrument_targets[selected_instrument]
    local target=phrase_targets[index]
    if target then runtime:bind_phrase(instrument,target)
    else runtime:bind_new(instrument) end
    local target_index=destination().phrase_index
    local source_available=false
    if target and target_index then
      local source,output_policy_or_error,stored_pb_range=
        store.load(song,instrument,target)
      if source then
        source_available=true
        pattern=source
        output_policy=output_policy_or_error
        pb_range=stored_pb_range or policies.DEFAULT_PB_RANGE
        selected_pitch=1;selected_step=1
        pitch_page=1;time_page=1
        status.text=string.format("Restored ACID source for phrase %02d.",target_index)
      else
        reset_source()
        status.text="Source unavailable: "..tostring(output_policy_or_error)..
          " | choose a new phrase; existing audio is protected."
      end
    else
      reset_source()
      status.text="New phrase draft ready: all stored PITCH entries are C and TIME steps are NOTE."
    end
    local draft,policy,draft_pb_range=drafts.get(song,bound_instrument(),bound_phrase())
    source_state.text=draft and "SOURCE DIRTY: Generate to apply this draft." or
      (not bound_phrase() and "SOURCE DIRTY: Generate to apply this draft." or
        (source_available and "SOURCE COMMITTED" or "SOURCE UNAVAILABLE"))
    if draft then
      pattern,output_policy=draft,policy
      pb_range=draft_pb_range or policies.DEFAULT_PB_RANGE
      status.text="Recovered saved draft. Generate or edit the source to apply it."
    elseif policy then
      status.text="DRAFT RECOVERY ERROR: "..tostring(policy).."; existing phrase output is protected."
    end
    runtime:transition("programmatic",{source=pattern,output_policy=output_policy,pb_range=pb_range,restore=true})
    history:reset(pattern,output_policy,pb_range)
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
    phrase_choice.items=options
    local chosen=#options
    local instrument=instrument_targets[n]
    local current_phrase=rawequal(song.selected_instrument,instrument) and
      song.selected_phrase or nil
    if current_phrase then
      for index,phrase in ipairs(phrase_targets) do
        if rawequal(phrase,current_phrase) and ownership.status(phrase)=="owned" then
          chosen=index
          break
        end
      end
    end
    phrase_choice.value=chosen
    loading=false
    load_target(chosen)
    if bind_selected_phrase_watch then
      bind_selected_phrase_watch()
    end
  end
  local function refresh_phrase_choices(preferred_target)
    local chosen=phrase_choice.value
    local options,targets=options_for_instrument()
    phrase_targets=targets
    if preferred_target then
      for index,target in ipairs(targets) do
        if rawequal(target,preferred_target) or (type(preferred_target)=="number" and rawequal(target,instrument_targets[selected_instrument].phrases[preferred_target])) then chosen=index;break end
      end
    end
    loading=true
    phrase_choice.items=options
    phrase_choice.value=math.min(chosen,#options)
    loading=false
  end
  bind_selected_phrase_watch=function()
    detach_selected_phrase_watch()
    local observable=song.selected_phrase_observable
    if not observable or type(observable.add_notifier)~="function" or
        type(observable.remove_notifier)~="function" then
      return
    end
    local notifier=function()
      if not current_session() or loading or runtime:mutation_state().depth>0 then
        return
      end
      invalidate_projection()
      runtime:mark_dirty("Native selection changed")
    end
    local ok=pcall(function() observable:add_notifier(notifier) end)
    if ok then
      selected_phrase_observable=observable
      selected_phrase_notifier=notifier
    end
  end
  apply_pending_selected_phrase_selection=function()
    if not current_session() then return false end
    local before=destination()
    local target=runtime:reconcile()
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
          if instrument_choice then instrument_choice.value=index end
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
        if rawequal(phrase,target.phrase) then load_target(choice);return true end
      end
    end
    status.text="Native destination is unavailable; select the destination again."
    return false
  end
  local target=vb:popup{width=290,items=labels,value=selected_instrument,
    notifier=function(n)select_instrument(n) end}
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
  update_live_state=function()
    local state=runtime:generation_state()
    if not state.armed then
      live_state_view.text="LIVE EDIT DISABLED"
      return
    end
    live_state_view.text="LIVE EDIT "..state.status
    if state.last_commit then
      local commit=state.last_commit
      live_state_view.text=live_state_view.text.."\nLAST COMMIT: "..
        string.upper(tostring(commit.status or "committed")).." | "..
        tostring(state.last_commit_label or "Verified destination")
    end
  end
  deliver=function(request,result)
    if type(request)~="table" or not current_session() then return end
    local success=result.kind=="success" and result.verified==true
    local prefix=request.trigger=="manual" and "GENERATION " or "LIVE EDIT "
    if success then
      if result.destination_current~=false and result.phrase then
        refresh_phrase_choices(result.phrase)
      end
      if result.stale==true then
        update_live_state()
        return
      end
      if not result.phrase then
        source_state.text="SOURCE UNAVAILABLE"
        status.text=prefix.."ERROR: destination identity could not be verified; select the destination again."
        update_live_state()
        return
      end
      source_state.text="SOURCE COMMITTED"
    end
    status.text=describe_result(result,prefix)
    update_live_state()
  end
  live_checkbox=vb:checkbox{value=false,notifier=function(value)
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
  undo_button=vb:button{text="Undo",active=false,notifier=function()
    local source,policy,source_pb_range=history:undo()
    if source then
      pattern=source
      output_policy=policy
      pb_range=source_pb_range or policies.DEFAULT_PB_RANGE
      local saved,save_error=save_draft()
      status.text=saved and "Edit undone and saved with the song." or
        "Edit undone; session recovery only: "..tostring(save_error)
      update();update_live_state()
    end
  end}
  redo_button=vb:button{text="Redo",active=false,notifier=function()
    local source,policy,source_pb_range=history:redo()
    if source then
      pattern=source
      output_policy=policy
      pb_range=source_pb_range or policies.DEFAULT_PB_RANGE
      local saved,save_error=save_draft()
      status.text=saved and "Edit redone and saved with the song." or
        "Edit redone; session recovery only: "..tostring(save_error)
      update();update_live_state()
    end
  end}
  program_panel=vb:column{id="acid_program_panel",spacing=5,
    vb:text{text="PROGRAM ENTRY | choose one shared PITCH position and TIME step",font="bold"},
    vb:row{spacing=8,vb:text{text="PITCH POSITION"},program_pitch_popup,
      program_pitch_summary},
    vb:row{spacing=8,vb:text{text="KEY"},program_key_popup,
      vb:text{text="OCTAVE"},program_octave_popup,
      vb:text{text="ACCENT"},program_accent,
      vb:text{text="SLIDE"},program_slide},
    vb:row{spacing=8,vb:text{text="TIME STEP"},program_time_popup,
      vb:text{text="COMMAND"},program_time_command,
      program_time_summary},
    vb:row{spacing=8,
      vb:button{text="Previous TIME",notifier=function()
        if selected_step>1 then choose_time(selected_step-1) end
      end},
      vb:button{text="Next TIME",notifier=function()
        if selected_step<pattern.length then choose_time(selected_step+1) end
      end}},
    vb:text{text="Set LAST STEP to reach TIME positions beyond the active sequence."}}
  grid_panel=vb:column{id="acid_grid_panel",spacing=5,
    vb:text{text="PITCH MEMORY | select a position, then edit its controls",font="bold"},
    pitch_pages,pitch_grid,
    vb:row{spacing=10,vb:text{text="Keyboard"},key_popup,
      vb:text{text="Octave"},octave_popup,
      vb:text{text="ACCENT"},accent,vb:text{text="SLIDE"},slide},
    vb:text{text="TIME MEMORY | select NOTE, TIE or REST directly for each step",font="bold"},
    time_pages,time_grid,
    vb:text{text="DECODED SEQUENCE | compare Start and Repeating transitions",font="bold"},
    preview_grid}
  local content=vb:column{margin=12,spacing=7,
    vb:text{text="ACID  |  PITCH / TIME EDITOR",font="big"},
    vb:row{spacing=10,vb:text{text="LAST STEP"},last_step_box,
      vb:text{text="Timing"},timing_popup,step_division},
    vb:row{spacing=8,vb:text{text="Editor view"},view_popup,
      vb:text{text="Active PITCH span"},pitch_length_popup,
      vb:text{text="Program and Grid edit the same source."}},
    vb:row{spacing=8,vb:text{text="Phrase output"},playback_popup,
      vb:text{text="Preview"},preview_popup},
    vb:row{spacing=8,
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
    summary,map_text,diagnostic,diagnostic_jump,
    vb:row{spacing=6,vb:text{text="Target instrument"},target,
      vb:text{text="PB Range"},pb_range_popup},
    vb:text{text="Assumes the receiver's matching bend range; pitch bend is channel-wide. Use isolated monophonic routing."},
    vb:row{spacing=6,vb:text{text="Destination phrase"},phrase_choice},
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
  update()
  dialog=renoise.app():show_custom_dialog("ACID - PITCH/TIME",content)
  dialog_session=session
  local observed_dialog=dialog
  local observed_checkbox=live_checkbox
  idle_observable=renoise.tool().app_idle_observable
  local observed_idle_observable=idle_observable
  local observed_notifier
  observed_notifier=function()
    local function detach_this_watch()
      pcall(function() observed_idle_observable:remove_notifier(observed_notifier) end)
    if rawequal(idle_observable,observed_idle_observable) and
        rawequal(idle_notifier,observed_notifier) then
        idle_observable,idle_notifier=nil,nil
      end
    end
    if not rawequal(dialog,observed_dialog) then
      detach_this_watch()
      return
    end
    if observed_dialog.visible then
      apply_pending_selected_phrase_selection()
      runtime:flush_pending()
      return
    end
    detach_this_watch()
    detach_selected_phrase_watch()
    runtime:transition("disarm")
    runtime:close_dialog()
    observed_checkbox.value=false
    dialog=nil
    dialog_session=nil
    runtime:close_dialog()
  end
  idle_notifier=observed_notifier
  observed_idle_observable:add_notifier(observed_notifier)
end

function M.get_ui_state()
  local visible=dialog and dialog.visible==true or false
  return {dialog_visible=visible}
end
return M
