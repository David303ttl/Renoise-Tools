-- ACID M1 native ViewBuilder PITCH/TIME grid.
local M = {}
local sequencer=require("model.sequencer")
local editor=require("model.editor_state")
local compiler=require("model.compiler")
local phrase_writer=require("writers.phrase_writer")
local inspector=require("renoise.selection_context")
local sampler=require("renoise.sampler_audit")
local dialog
local generation=0
local dialog_generation=-1
renoise.tool().app_new_document_observable:add_notifier(function()
  generation=generation+1
  phrase_writer.cancel()
end)

local keys={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B","C+"}
local octave_names={"DOWN (-1)","NORMAL (0)","UP (+1)"}
local colors={selected={0xF0,0x70,0x70},used={0x55,0xAA,0x75},
  idle={0x49,0x4B,0x55},note={0xBD,0x5B,0x5B},
  tie={0x5D,0x88,0xB7},rest={0x4B,0x4D,0x56},
  warning={0xF2,0x77,0x77}}

function M.show()
  if dialog and dialog.visible then
    if dialog_generation==generation then dialog:show();return end
    dialog:close(); dialog=nil
  end
  local song=renoise.song()
  if not song then renoise.app():show_warning("Open a song first.");return end
  local vb=renoise.ViewBuilder()
  local pattern=phrase_writer.fixture()
  local pitch_page,time_page=1,1
  local selected_pitch,selected_step=1,1
  local updating=false
  local opened=generation
  local mode_values={"baseline","retrigger","slide"}
  local selected_instrument=math.min(song.selected_instrument_index,#song.instruments)
  local mode_choice=1
  local labels={}
  for i,instrument in ipairs(song.instruments) do
    local name=instrument.name~="" and instrument.name or "(unnamed)"
    labels[i]=string.format("%02X: %s",i-1,name)
  end
  if #labels==0 then renoise.app():show_warning("No instruments in song.");return end
  local status=vb:multiline_textfield{width=820,height=88,active=false,
    font="bold",text="Set LAST STEP, then edit PITCH and TIME memories."}
  local diagnostic=vb:text{width=820,font="bold",text=""}
  local summary=vb:text{width=820,text=""}
  local map_text=vb:text{width=820,text=""}
  local length_popup=vb:popup{items={},width=78,value=1}
  local length_items={}
  for n=1,64 do length_items[n]=tostring(n) end
  length_popup.items=length_items
  length_popup.value=pattern.length
  local step_division=vb:text{text="Straight 1/16 (triplet renderer not yet implemented)"}
  local pitch_page_buttons,time_page_buttons={},{}
  local pitch_cells,time_cells,preview_cells={}, {}, {}
  local key_popup=vb:popup{items=keys,width=95,value=1}
  local octave_popup=vb:popup{items=octave_names,width=135,value=2}
  local accent=vb:checkbox{value=false}
  local slide=vb:checkbox{value=false}
  local adopt=vb:checkbox{value=false}
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
    return string.format("P%02d %s%s%s",index,suffix,
      p.accent and " A" or "",p.slide and " S" or "")
  end
  local function update()
    updating=true
    local projection=editor.project(pattern)
    for page=1,4 do
      local first=(page-1)*16+1
      local last=math.min(page*16,pattern.length)
      pitch_page_buttons[page].text=string.format("P %02d-%02d%s",
        first,page*16,page==pitch_page and " [*]" or "")
      time_page_buttons[page].text=string.format("T %02d-%02d%s",
        first,page*16,page==time_page and " [*]" or "")
      time_page_buttons[page].active=first<=pattern.length
    end
    for cell=1,16 do
      local i=editor.index_on_page(pitch_page,cell)
      local p=pitch_at(i)
      local b=pitch_cells[cell]
      b.text=view_label(i,p,projection)
      b.color=i==selected_pitch and colors.selected
        or (projection.used[i] and colors.used or colors.idle)
      local step=editor.index_on_page(time_page,cell)
      local time=time_cells[cell]
      local preview=preview_cells[cell]
      if step<=pattern.length then
        local cmd=pattern.time_events[step]
        time.active=true
        time.text=string.format("%02d  %s",step,
          cmd=="N" and "NOTE" or cmd=="T" and "TIE"
          or cmd=="R" and "REST" or "?")
        time.color=projection.error and projection.error.step==step
          and colors.warning or (step==selected_step and colors.selected)
          or (cmd=="N" and colors.note or cmd=="T" and colors.tie or colors.rest)
        preview.text=string.format("%02d %s",step,editor.step_text(projection,step))
        preview.color=projection.error and projection.error.step==step
          and colors.warning or colors.idle
      else
        time.active=false;time.text="--";time.color=colors.idle
        preview.text="";preview.color=colors.idle
      end
    end
    local p=pitch_at(selected_pitch)
    local key,octave=sequencer.pitch_controls(p)
    key_popup.value=(key or 0)+1
    octave_popup.value=(octave or 0)+2
    accent.value=p.accent==true
    slide.value=p.slide==true
    local count=0
    for _ in pairs(projection.used) do count=count+1 end
    summary.text=string.format("LAST STEP %02d / 64   |   %d NOTE events   |   %d PITCH positions stored   |   %d used   |   %d unused",
      pattern.length,projection.note_count,#pattern.pitch_events,count,
      #pattern.pitch_events-count)
    local mapping=projection.mapping[selected_step]
    map_text.text=string.format("Selected TIME %02d -> %s   |   Selected PITCH P%02d",
      selected_step,editor.step_text(projection,selected_step),selected_pitch)
    local plan,err=compiler.compile(pattern)
    local error_info=projection.error
    if error_info then
      diagnostic.text="ERROR: "..error_info.message..
        (error_info.step and "  [TIME "..error_info.step.."]" or "")..
        (error_info.pitch_index and "  [PITCH "..error_info.pitch_index.."]" or "")
    elseif not plan then
      diagnostic.text="NOT READY: "..tostring(err)
    else
      diagnostic.text="VALID: "..plan.note_count.." NOTE triggers; separate PITCH/TIME memories intact."
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
    local projection=editor.project(pattern)
    local mapping=projection.mapping[index]
    if mapping and mapping.pitch_index then
      selected_pitch=mapping.pitch_index
      pitch_page=editor.page_for(selected_pitch)
    end
    update()
  end
  local function change_pitch()
    if updating then return end
    fill_to(selected_pitch)
    pattern.pitch_events[selected_pitch]=sequencer.new_pitch(
      key_popup.value-1,octave_popup.value-2,accent.value,slide.value)
    update()
  end
  key_popup:add_notifier(change_pitch)
  octave_popup:add_notifier(change_pitch)
  accent:add_notifier(change_pitch)
  slide:add_notifier(change_pitch)
  local pitch_grid=vb:column{spacing=4}
  local time_grid=vb:column{spacing=4}
  local preview_grid=vb:column{spacing=4}
  local pitch_pages=vb:row{spacing=6}
  local time_pages=vb:row{spacing=6}
  for p=1,4 do
    local page=p
    pitch_page_buttons[p]=vb:button{width=155,text="P",notifier=function()
      pitch_page=page;update() end}
    time_page_buttons[p]=vb:button{width=155,text="T",notifier=function()
      time_page=page;update() end}
    pitch_pages:add_child(pitch_page_buttons[p])
    time_pages:add_child(time_page_buttons[p])
  end
  for row=1,2 do
    local p_row=vb:row{spacing=4}
    local t_row=vb:row{spacing=4}
    local v_row=vb:row{spacing=4}
    for col=1,8 do
      local cell=(row-1)*8+col
      pitch_cells[cell]=vb:button{width=98,height=38,text="--",notifier=function()
        choose_pitch(editor.index_on_page(pitch_page,cell)) end}
      time_cells[cell]=vb:button{width=98,height=36,text="--",notifier=function()
        local step=editor.index_on_page(time_page,cell)
        if step<=pattern.length then
          -- Direct editing: repeated clicks cycle NOTE -> TIE -> REST.
          selected_step=step
          local old=pattern.time_events[step]
          pattern.time_events[step]=old=="N" and "T" or old=="T" and "R" or "N"
          choose_time(step)
        end
      end}
      preview_cells[cell]=vb:button{width=98,height=32,text="--",notifier=function()
        local step=editor.index_on_page(time_page,cell)
        if step<=pattern.length then choose_time(step) end
      end}
      p_row:add_child(pitch_cells[cell])
      t_row:add_child(time_cells[cell])
      v_row:add_child(preview_cells[cell])
    end
    pitch_grid:add_child(p_row)
    time_grid:add_child(t_row)
    preview_grid:add_child(v_row)
  end
  length_popup:add_notifier(function(n)
    if updating then return end
    pattern.length=n
    for i=#pattern.time_events+1,n do pattern.time_events[i]="R" end
    for i=n+1,64 do pattern.time_events[i]=nil end
    if selected_step>n then selected_step=n end
    if editor.page_for(selected_step)~=time_page then
      time_page=editor.page_for(selected_step)
    end
    update()
  end)
  local inspect=vb:button{text="Inspect selected Renoise pattern (read only)",
    notifier=function()
      local message,err=inspector.inspect_selection()
      status.text=message or err
    end}
  local target=vb:popup{width=290,items=labels,value=selected_instrument,
    notifier=function(n)selected_instrument=n end}
  local mode=vb:popup{width=210,items={"Baseline","Retrigger + Gate","Selective Slide + Gate"},
    value=mode_choice,notifier=function(n)mode_choice=n end}
  local content=vb:column{margin=12,spacing=7,
    vb:text{text="ACID 0.1  |  M1 PITCH / TIME EDITOR",font="big"},
    vb:row{spacing=10,vb:text{text="LAST STEP (1-64)"},length_popup,
      step_division},
    vb:text{text="64-step extension: four continuous pages of 16. Roland PITCH/TIME semantics remain separate."},
    vb:text{text="PITCH MEMORY | select position, then edit keyboard, octave, accent and slide",font="bold"},
    pitch_pages,pitch_grid,
    vb:row{spacing=10,vb:text{text="Keyboard"},key_popup,
      vb:text{text="Octave"},octave_popup,
      vb:text{text="ACCENT"},accent,vb:text{text="SLIDE"},slide},
    vb:text{text="TIME MEMORY | click step to cycle NOTE -> TIE -> REST",font="bold"},
    time_pages,time_grid,
    vb:text{text="DECODED SEQUENCE | click a cell to inspect its pitch",font="bold"},
    preview_grid,summary,map_text,diagnostic,
    vb:row{spacing=6,vb:text{text="Target instrument"},target,
      vb:text{text="Audio test"},mode},
    vb:row{spacing=8,
      vb:button{text="Generate / Regenerate ACID Phrase",notifier=function()
        if opened~=generation then
          status.text="Song changed. Close and reopen ACID.";return
        end
        local projection=editor.project(pattern)
        if projection.error then
          local e=projection.error
          if e.step then choose_time(e.step) end
          if e.pitch_index then choose_pitch(e.pitch_index) end
          status.text="Cannot generate: "..e.message
          return
        end
        local ok,generated,err=pcall(phrase_writer.generate,
          selected_instrument,function(message)
            if opened==generation then status.text=message end
          end,mode_values[mode_choice],pattern,adopt.value)
        if not ok then status.text="ACID error: "..tostring(generated)
        elseif not generated then status.text=err or "Generation refused" end
      end},
      vb:text{text="Adopt legacy once"},adopt,
      vb:button{text="Sampler audit",notifier=function()
        status.text=sampler.describe(song.instruments[selected_instrument])
      end}},
    inspect,status}
  update()
  dialog=renoise.app():show_custom_dialog("ACID - PITCH/TIME",content)
  dialog_generation=opened
end
return M
