-- SPDX-License-Identifier: GPL-3.0-only
-- Sparse plugin/MIDI NOTE/OFF plan for connected phrase transitions.
local M = { MAX_COLUMNS=3, EMPTY=121, OFF=120 }
local control=require("model.control_signals")
M.IMMEDIATE_DELAY = 0
-- Minimum positive note-column delay; Renoise quantizes playback to ticks.
M.ORDER_DELAY = 1
M.PITCH_BEND_CENTER = 8192
M.PITCH_BEND_MAX = 16383
local TIMELINE_UNITS_PER_STEP=control.UNITS_PER_STEP
local HALF_STEP_UNITS=TIMELINE_UNITS_PER_STEP/2
local BEND_VALUES_PER_BYTE=128
local HALF_STEP_INTERPOLATION_DIVISOR=2
local ROUND_HALF_UP=0.5
local FIRST_PHRASE_LINE=1

local function resolution(layout)
  local lines_per_step=type(layout)=="table" and layout.lines_per_step
  if type(lines_per_step)~="number" or lines_per_step%1~=0 or lines_per_step<1
    or lines_per_step~=lines_per_step then
    return nil,"legato planning requires a positive integer lines-per-step"
  end
  return lines_per_step
end

local function source_step(event)
  return event.source_step or event.step
end

local function semantic_plans(semantic)
  if type(semantic)~="table" then return nil,"semantic plan is required" end
  if semantic.loop and semantic.loop.cold and semantic.loop.steady then
    local plans={semantic.loop.cold,semantic.loop.steady}
    if semantic.loop.verification then plans[#plans+1]=semantic.loop.verification end
    return plans
  end
  if semantic.cold and semantic.steady then
    local plans={semantic.cold,semantic.steady}
    if semantic.verification then plans[#plans+1]=semantic.verification end
    return plans
  end
  if type(semantic.steps)=="table" then return {semantic} end
  return nil,"semantic plan must contain cycle steps"
end

local function graph_from(plans)
  local neighbors,parent,nodes,edges,same_edges={},{},{},{},{}
  local function node(step)
    if type(step)~="number" or step%1~=0 or step<1 then
      return nil,"semantic NOTE has an invalid source TIME step"
    end
    if not parent[step] then
      parent[step]=step
      neighbors[step]={}
      nodes[#nodes+1]=step
    end
    return step
  end
  local function find(step)
    if parent[step]~=step then parent[step]=find(parent[step]) end
    return parent[step]
  end
  local function connect(a,b)
    if not a or not b or a==b then return end
    edges[#edges+1]={a,b}
  end
  local function join(a,b)
    if not a or not b then return end
    same_edges[#same_edges+1]={a,b}
  end
  for _,plan in ipairs(plans) do
    if type(plan)~="table" or type(plan.steps)~="table" or #plan.steps==0 then
      return nil,"semantic cycle is empty"
    end
    local active_step,active_note
    if plan.entry_kind=="repeat" then
      local exit_voice=plan.steps[#plan.steps].voice
      if exit_voice then
        active_step=exit_voice.origin_step
        active_note=exit_voice.note
        local _,err=node(active_step)
        if err then return nil,err end
      end
    end
    for _,event in ipairs(plan.steps) do
      if event.kind=="note" then
        local step=source_step(event)
        local _,err=node(step)
        if err then return nil,err end
        if event.transition=="slide" and active_step then
          if event.note==active_note then join(active_step,step)
          else connect(active_step,step) end
        end
        active_step,active_note=step,event.note
      elseif event.kind=="rest" then
        active_step,active_note=nil,nil
      end
    end
  end
  table.sort(nodes)
  for _,pair in ipairs(same_edges) do
    local a,b=find(pair[1]),find(pair[2])
    if a~=b then parent[b]=a end
  end
  local components,component_order={},{}
  for _,step in ipairs(nodes) do
    local root=find(step)
    if not components[root] then components[root]={};component_order[#component_order+1]=root end
    components[root][#components[root]+1]=step
  end
  table.sort(component_order,function(a,b)
    return components[a][1]<components[b][1]
  end)
  local quotient={}
  for _,root in ipairs(component_order) do quotient[root]={} end
  for _,pair in ipairs(edges) do
    local a,b=find(pair[1]),find(pair[2])
    if a~=b then quotient[a][b]=true;quotient[b][a]=true end
  end
  return {neighbors=quotient,nodes=component_order,components=components}
end

local function accent_map(plans)
  local accents={}
  for _,plan in ipairs(plans) do
    for _,event in ipairs(plan.steps) do
      if event.kind=="note" then accents[source_step(event)]=event.accent==true end
    end
  end
  return accents
end

local function color_graph(graph)
  local colors,max_color={},0
  for _,component in ipairs(graph.nodes) do
    local used={}
    for neighbor in pairs(graph.neighbors[component]) do
      if colors[neighbor] then used[colors[neighbor]]=true end
    end
    local color=1
    while used[color] do color=color+1 end
    if color>M.MAX_COLUMNS then return nil,"connected slide cycle requires more than three phrase columns" end
    colors[component]=color
    if color>max_color then max_color=color end
  end
  local source_colors={}
  for component,steps in pairs(graph.components) do
    for _,step in ipairs(steps) do source_colors[step]=colors[component] end
  end
  return source_colors,math.max(max_color,1)
end

local function add_cell(cells,line,column,values)
  local row=cells[line]
  if not row then row={};cells[line]=row end
  local cell=row[column]
  if not cell then
    cell={}
    row[column]=cell
  end
  for key,value in pairs(values) do
    if cell[key]~=nil and cell[key]~=value then
      return nil,string.format("legato plan collision at phrase line %d, column %d",line,column)
    end
    cell[key]=value
  end
  return true
end

local function bend_plan(semantic,timeline,layout,options,lines_per_step)
  local range=options.pb_range
  if range~=2 and range~=12 and range~=24 and range~=48 then return nil,"invalid pitch-bend range" end
  local target=options.instrument_value
  if type(target)~="number" or target%1~=0 or target<0 or target>255 then
    return nil,"pitch bend requires a valid phrase channel field"
  end
  if type(timeline)~="table" or type(timeline.events)~="table" then return nil,"gate timeline is incomplete" end
  local cells,commands,diagnostics={},{},{
    "Pitch bend delivery depends on the receiver and routing; set the selected range and use isolated monophonic routing. PB Off retains NOTE overlap."}
  local anchor,pitch,accent,column
  local centered=false
  local collision
  local function put(line,col,values)
    local ok,err=add_cell(cells,line,col,values)
    if not ok then collision=err end
  end
  local function bend(line,offset)
    local negative_span=M.PITCH_BEND_CENTER
    local positive_span=M.PITCH_BEND_MAX-M.PITCH_BEND_CENTER
    local value=offset<0 and M.PITCH_BEND_CENTER+offset/range*negative_span
      or M.PITCH_BEND_CENTER+offset/range*positive_span
    value=math.floor(value+ROUND_HALF_UP)
    commands[line]={value=value,instrument_value=target,
      number_string=string.format("%02X",math.floor(value/BEND_VALUES_PER_BYTE)),
      amount_value=value%BEND_VALUES_PER_BYTE}
    centered=value==M.PITCH_BEND_CENTER
  end
  local events={}
  for i,event in ipairs(timeline.events) do
    if type(event.at)~="number" or event.at<0 or event.at%1~=0
      or (event.at*lines_per_step)%TIMELINE_UNITS_PER_STEP~=0 then
      return nil,"pitch-bend timeline position is not representable"
    end
    events[i]=event
  end
  table.sort(events,function(a,b)
    if a.at~=b.at then return a.at<b.at end
    local order={gate_off=1,pitch_target=2,gate_on=3,rest=4,tie=5}
    return (order[a.kind] or 9)<(order[b.kind] or 9)
  end)
  local entry_state
  local function state() return table.concat({anchor or "empty",pitch or "empty",column or "empty",tostring(accent),tostring(centered)},":") end
  for index,event in ipairs(events) do
    local line=math.floor(event.at*lines_per_step/TIMELINE_UNITS_PER_STEP)+FIRST_PHRASE_LINE
    if layout.looping and not entry_state and line>=layout.loop_start then entry_state=state() end
    if event.kind=="gate_on" then
      column=1
      put(line,column,{note_value=event.note,volume_value=event.accent and 255 or 89,
        delay_value=centered and M.IMMEDIATE_DELAY or M.ORDER_DELAY})
      anchor,pitch,accent=event.note,event.note,event.accent
      if not centered then bend(line,M.IMMEDIATE_DELAY) end
    elseif event.kind=="pitch_target" then
      if not anchor then return nil,"pitch bend requires a cold-entry voice anchor" end
      local offset=event.note-anchor
      if math.abs(offset)>range then
        put(line,column,{note_value=M.OFF,delay_value=M.IMMEDIATE_DELAY})
        column=3-column
        put(line,column,{note_value=event.note,volume_value=event.accent and 255 or 89,
          delay_value=M.ORDER_DELAY})
        bend(line,M.IMMEDIATE_DELAY)
        anchor,pitch,accent=event.note,event.note,event.accent
        diagnostics[#diagnostics+1]=string.format("TIME step %02d: SLIDE approximated: bend range exceeded",source_step(event))
      else
        if pitch~=event.note then
          -- Glide into the target across the preceding connected half-step.
          local previous_event=events[index-1]
          local half_step_lines=layout.half_step_lines
          local midpoint_line=type(half_step_lines)=="number" and half_step_lines%1==0
            and (line-half_step_lines) or nil
          local room=midpoint_line and midpoint_line>=1 and previous_event
            and previous_event.at<event.at-HALF_STEP_UNITS
            and not commands[midpoint_line]
          if room then
            bend(midpoint_line,((pitch-anchor)+offset)/HALF_STEP_INTERPOLATION_DIVISOR)
          end
          bend(line,offset)
          if not room then
            diagnostics[#diagnostics+1]=string.format("TIME step %02d: SLIDE approximated: phrase timing leaves no free intermediate bend line.",source_step(event))
          end
        end
        if event.accent~=accent then
          diagnostics[#diagnostics+1]=string.format("TIME step %02d: accent change is omitted while the connected voice is held.",source_step(event))
        end
        pitch=event.note
      end
    elseif event.kind=="gate_off" then
      if anchor then
        put(line,column,{note_value=M.OFF,delay_value=M.IMMEDIATE_DELAY})
        bend(line,M.IMMEDIATE_DELAY)
        anchor,pitch,accent,column=nil,nil,nil,nil
      end
    end
  end
  if collision then return nil,collision end
  if layout.looping and entry_state and entry_state~=state() then
    local fallback,err=M.plan(semantic,timeline,layout)
    if not fallback then return nil,err end
    for _,diagnostic in ipairs(diagnostics) do fallback.diagnostics[#fallback.diagnostics+1]=diagnostic end
    fallback.diagnostics[#fallback.diagnostics+1]="SLIDE approximated: pitch-bend voice anchor cannot repeat safely at the loop seam; receiver-controlled NOTE overlap is used."
    return fallback
  end
  -- The carrier is always rightmost and never replaces NOTE/OFF data.
  return {cells=cells,columns=3,diagnostics=diagnostics,lines_per_step=lines_per_step,
    midi_commands=commands,pb_range=range}
end

function M.plan(semantic,timeline,layout,options)
  layout=layout or {}
  local lines_per_step,layout_error=resolution(layout)
  if not lines_per_step then return nil,layout_error end
  if options and options.pb_range and options.pb_range~=0 then
    return bend_plan(semantic,timeline,layout,options,lines_per_step)
  end
  if type(timeline)~="table" or type(timeline.events)~="table" or
      type(timeline.steps)~="number" or timeline.steps<1 then
    return nil,"gate timeline is incomplete"
  end
  local plans,err=semantic_plans(semantic)
  if not plans then return nil,err end
  local graph
  graph,err=graph_from(plans)
  if not graph then return nil,err end
  local accents=accent_map(plans)
  local colors,columns=color_graph(graph)
  if not colors then return nil,columns end
  local maximum=layout.max_columns or M.MAX_COLUMNS
  if type(maximum)~="number" or maximum%1~=0 or maximum<1 or maximum>M.MAX_COLUMNS then
    return nil,"layout max_columns must be 1..3"
  end
  if columns>maximum then return nil,"connected slide plan exceeds available phrase columns" end

  local events={}
  for index,event in ipairs(timeline.events) do events[index]=event end
  table.sort(events,function(a,b)
    if a.at~=b.at then return a.at<b.at end
    local order={gate_off=1,pitch_target=2,gate_on=3,rest=4,tie=5}
    return (order[a.kind] or 9)<(order[b.kind] or 9)
  end)

  local cells={}
  local diagnostics={"Connected slides use overlapping NOTE/OFF ordering; enable mono-legato/portamento on the receiving instrument for continuous glide."}
  local active_step,active_note=nil,nil
  local cycle=timeline.semantic
  if cycle and cycle.entry_kind=="repeat" then
    local voice=cycle.steps and cycle.steps[#cycle.steps] and cycle.steps[#cycle.steps].voice
    if voice then active_step,active_note=voice.origin_step,voice.note end
  elseif semantic.loop and semantic.loop.steady then
    local first_event=events[1]
    if first_event and first_event.kind=="pitch_target" and first_event.at==0 then
      local steps=semantic.loop.steady.steps
      local voice=steps and steps[#steps] and steps[#steps].voice
      if voice then active_step,active_note=voice.origin_step,voice.note end
    end
  end
  for _,event in ipairs(events) do
    if type(event.at)~="number" or event.at<0 or event.at%1~=0 then
      return nil,"timeline event has an invalid position"
    end
    local line=math.floor(event.at*lines_per_step/TIMELINE_UNITS_PER_STEP)+FIRST_PHRASE_LINE
    if event.kind=="gate_on" then
      local step=source_step(event)
      local column=colors[step]
      if not column then return nil,"gate NOTE has no semantic source TIME step" end
      local velocity=event.accent and 255 or 89
      local ok,cell_error=add_cell(cells,line,column,{note_value=event.note,
        volume_value=velocity,delay_value=M.IMMEDIATE_DELAY})
      if not ok then return nil,cell_error end
      active_step,active_note=step,event.note
    elseif event.kind=="pitch_target" then
      local step=source_step(event)
      if not active_step then
        return nil,"connected NOTE has no active source voice"
      end
      if event.note==active_note then
        if event.accent~=(accents[active_step] or false) then
          diagnostics[#diagnostics+1]=string.format(
            "TIME step %02d: accent change is omitted while the connected voice is held.",step)
        end
      else
        local column=colors[step]
        local previous_column=colors[active_step]
        if not column or not previous_column or column==previous_column then
          return nil,"connected NOTE columns are not isolated"
        end
        local ok,cell_error=add_cell(cells,line,column,{note_value=event.note,
          volume_value=event.accent and 255 or 89,delay_value=M.IMMEDIATE_DELAY})
        if not ok then return nil,cell_error end
        ok,cell_error=add_cell(cells,line,previous_column,
          {note_value=M.OFF,delay_value=M.ORDER_DELAY})
        if not ok then return nil,cell_error end
        active_step,active_note=step,event.note
      end
    elseif event.kind=="gate_off" then
      if active_step then
        local column=colors[active_step]
        local delay=(event.at*lines_per_step)%TIMELINE_UNITS_PER_STEP
        local ok,cell_error=add_cell(cells,line,column,{note_value=M.OFF,delay_value=delay})
        if not ok then return nil,cell_error end
        active_step,active_note=nil,nil
      end
    end
  end
  return {cells=cells,columns=columns,diagnostics=diagnostics,
    lines_per_step=lines_per_step,source_columns=colors}
end

return M
