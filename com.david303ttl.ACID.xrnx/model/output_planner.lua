-- SPDX-License-Identifier: GPL-3.0-only
-- Pure phrase layout, articulation and complete expected output values.
local compiler=require("model.cycle_interpreter")
local timing=require("model.timing")
local sequencer=require("model.sequencer")
local control=require("model.control_signals")
local articulation=require("model.articulation")
local legato=require("model.legato")
local policies=require("model.policies")
local M={}
local UNITS_PER_STEP=control.UNITS_PER_STEP

function M.plan_output(pattern, output_policy, max_lines)
  local valid,err=sequencer.validate(pattern)
  if not valid then return nil,err end
  if type(max_lines)~="number" or max_lines%1~=0 or max_lines<1 then
    return nil,"native phrase line capacity is required"
  end
  output_policy=output_policy or policies.DEFAULT_OUTPUT_POLICY
  if not policies.valid_output_policy(output_policy) then
    return nil,"Invalid phrase output policy"
  end
  local layout,layout_error=timing.new(pattern.timing_mode,pattern.length,output_policy)
  if not layout then return nil,layout_error end
  if layout.number_of_lines>max_lines then
    return nil,"phrase output exceeds the native phrase line limit"
  end
  if output_policy == "play_once" then
    local plan, err=compiler.compile_cycle(pattern)
    if not plan then return nil,err end
    plan.source_length=plan.length
    return plan,layout
  end
  local loop,err=compiler.plan_loop(pattern)
  if not loop then return nil,err end
  local cycle_plans={loop.cold,loop.steady}
  if #cycle_plans~=layout.cycle_count then
    return nil,"repeat cycle count does not match phrase layout"
  end
  local length=pattern.length*#cycle_plans
  local steps={}
  for cycle,source in ipairs(cycle_plans) do
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
    layout
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

local function articulation_plan(plan,capabilities,timeline,lines_per_step)
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
    return {},approximations,1
  end
  local early_releases,release_error=control.release_lines(timeline,lines_per_step)
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
      local available=(held+1)*lines_per_step
      local first_line=(event.step-1)*lines_per_step+1
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
  if not has_slide then return {},{},1 end
  local minimum_rate=rate
  if rate>254 then rate=255 end
  local commands,err=articulation.plan(plan,lines_per_step,rate)
  if not commands then return nil,err end
  local places={}
  for _,step in ipairs(slides) do places[#places+1]=string.format("%02d",step) end
  local approximations={"TIME steps "..table.concat(places,",")..
    ": native slide continuity and envelope response depend on the target instrument"}
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
  if rate==255 then
    local places={}
    for _,step in ipairs(slides) do places[#places+1]=string.format("%02d",step) end
    approximations[#approximations+1]="TIME steps "..table.concat(places,",")..
      ": native glide duration exceeded the 01..FE command range; 0G FF instant transitions were emitted"
  end
  return commands,approximations,minimum_rate
end

local MIN_LINES_PER_STEP=1
local function location(op)
  return string.format("TIME step %02d, cycle %d, phrase line 0x%02X",
    op.time_step or op.step or 1,op.cycle or 1,op.line-1)
end
M.location=location

function M.plan_gates(timeline,semantic,commands,lines_per_step)
  if type(lines_per_step)~="number" or lines_per_step%1~=0 or lines_per_step<MIN_LINES_PER_STEP
    or lines_per_step~=lines_per_step then
    return nil,"gate output requires a positive integer lines-per-step"
  end
  local lines,err=control.release_lines(timeline,lines_per_step)
  if not lines then
    local edge
    for _,event in ipairs(timeline.events or {}) do
      if event.kind=="gate_off" and event.reason~="rest" then edge=event;break end
    end
    return nil,location({line=edge and math.floor(edge.at*lines_per_step/UNITS_PER_STEP)+1 or 1,
      time_step=edge and edge.step,cycle=edge and edge.cycle})..": "..err
  end
  local merged={operations={},release_lines={},effects={}}
  local occupied={}
  local function append(op)
    local event=semantic and semantic.steps[math.floor((op.line-1)/lines_per_step)+1]
    op.time_step=op.time_step or (event and (event.source_step or event.step))
    op.cycle=op.cycle or (event and event.cycle) or 1
    if op.line<1 or op.line%1~=0 or op.line>timeline.steps*lines_per_step then
      return nil,location(op)..": operation outside musical phrase lines"
    end
    if op.kind=="release" and event and (op.line-1)%lines_per_step==0
      and (event.kind=="note" or (event.kind=="rest" and event.releases)) then
      return nil,location(op)..": OFF conflicts with semantic note or release"
    end
    if occupied[op.line] then
      return nil,location(op)..": contradictory gate/glide operations; required command cannot be omitted"
    end
    occupied[op.line]=true
    merged.operations[#merged.operations+1]=op
    return true
  end
  for _,line in ipairs(lines) do
    local ok,why=append({line=line,kind="release"})
    if not ok then return nil,why end
    merged.release_lines[line]=true
  end
  for _,command in ipairs(commands or {}) do
    local op={}
    for key,value in pairs(command) do op[key]=value end
    local ok,why=append(op)
    if not ok then return nil,why end
    merged.effects[op.line]=op.amount
  end
  return merged
end

-- Derive native volume expectations from source events, never rendered cells.
-- Renoise's pattrns renderer truncates sub-unity volume * 128, and emits
-- the empty/full-volume sentinel 255 for unity volume.
function M.expected_volumes(plan, lines_per_step, number_of_lines, columns, options)
  options = options or {}
  local normal = options.normal_volume or policies.NORMAL_VOLUME
  local accent = options.accent_volume or policies.ACCENT_VOLUME
  if not policies.valid_volume(normal) or not policies.valid_volume(accent) then
    return nil, 'volumes must be numbers between 0 and 1'
  end
  if type(plan) ~= 'table' or type(plan.steps) ~= 'table'
    or type(plan.length) ~= 'number' or plan.length < 1 or plan.length % 1 ~= 0
    or type(lines_per_step) ~= 'number' or lines_per_step < 1 or lines_per_step % 1 ~= 0
    or type(number_of_lines) ~= 'number' or number_of_lines < plan.length * lines_per_step
    or number_of_lines % 1 ~= 0 or type(columns) ~= 'number'
    or columns < 1 or columns % 1 ~= 0 then
    return nil, 'invalid volume expectation layout'
  end
  local volumes = {}
  for line = 1, number_of_lines do
    volumes[line] = {}
    for column = 1, columns do volumes[line][column] = 255 end
  end
  for step = 1, plan.length do
    local event = plan.steps[step]
    if type(event) ~= 'table' or event.step ~= step then
      return nil, 'missing or out-of-order semantic step ' .. step
    end
    if event.kind == 'note' then
      -- Match the emitter's six-decimal volume before native quantization.
      local volume = policies.note_volume(event.accent, normal, accent)
      volumes[(step - 1) * lines_per_step + 1][1] = policies.quantize_volume(volume)
    elseif event.kind ~= 'rest' and event.kind ~= 'tie' then
      return nil, 'invalid semantic kind at step ' .. step
    end
  end
  return volumes
end

local function positive_integer(value)
  return policies.is_integer(value) and value>=1
end

function M.empty_note()
  return {note_value=121,instrument_value=255,volume_value=255,panning_value=255,
    delay_value=0,effect_number_value=0,effect_amount_value=0,is_empty=true}
end

function M.empty_effect()
  return {number_value=0,amount_value=0,is_empty=true}
end

local function command_value(text)
  if type(text)~="string" or #text~=2 then return nil end
  local digits="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local first=digits:find(text:sub(1,1),1,true)
  local second=digits:find(text:sub(2,2),1,true)
  if not first or not second then return nil end
  return (first-1)*256+second-1
end
M.command_value=command_value

local function expected_output(plan,layout,native,operations,capacities,volumes)
  local expected={properties={number_of_lines=layout.number_of_lines,lpb=layout.lpb,
    shuffle=0,looping=layout.looping,loop_start=layout.loop_start,loop_end=layout.loop_end,
    playback_mode=capacities.play_pattern,key_tracking=capacities.key_tracking_none},
    lines={},empty_note=M.empty_note(),empty_effect=M.empty_effect()}
  for index=1,capacities.max_lines do
    local line={note_columns={},effect_columns={}}
    expected.lines[index]=line
    for column=1,capacities.max_note_columns do line.note_columns[column]=M.empty_note() end
    for column=1,capacities.max_effect_columns do line.effect_columns[column]=M.empty_effect() end
  end
  if native then
    for line,columns in pairs(native.cells) do
      for column,values in pairs(columns) do
        local cell=expected.lines[line].note_columns[column]
        for field,value in pairs(values) do cell[field]=value end
      end
    end
    for line,command in pairs(native.midi_commands or {}) do
      local carrier=expected.lines[line].note_columns[native.columns]
      carrier.panning_value=command_value("M1")
      carrier.instrument_value=command.instrument_value
      local effect=expected.lines[line].effect_columns[1]
      effect.number_value=command_value(command.number_string)
      effect.amount_value=command.amount_value
    end
  else
    for step,event in ipairs(plan.steps) do
      local line=(step-1)*layout.lines_per_step+1
      local cell=expected.lines[line].note_columns[1]
      if event.kind=="note" then cell.note_value=event.note
      elseif event.kind=="rest" and event.releases then cell.note_value=120 end
      cell.volume_value=volumes[line][1]
    end
    for _,op in ipairs(operations.operations) do
      local cell=expected.lines[op.line].note_columns[1]
      if op.kind=="release" then cell.note_value=120
      else
        cell.effect_number_value=command_value(op.command)
        cell.effect_amount_value=op.amount
      end
    end
  end
  local visibility={visible_note_columns=1,visible_effect_columns=0,
    instrument_column_visible=false,volume_column_visible=false,panning_column_visible=false,
    delay_column_visible=false,sample_effects_column_visible=false}
  for _,line in ipairs(expected.lines) do
    for column,cell in ipairs(line.note_columns) do
      cell.is_empty=cell.note_value==121 and cell.instrument_value==255 and
        cell.volume_value==255 and cell.panning_value==255 and cell.delay_value==0 and
        cell.effect_number_value==0 and cell.effect_amount_value==0
      if not cell.is_empty then visibility.visible_note_columns=math.max(visibility.visible_note_columns,column) end
      if cell.instrument_value~=255 then visibility.instrument_column_visible=true end
      if cell.volume_value~=255 then visibility.volume_column_visible=true end
      if cell.panning_value~=255 then visibility.panning_column_visible=true end
      if cell.delay_value~=0 then visibility.delay_column_visible=true end
      if cell.effect_number_value~=0 or cell.effect_amount_value~=0 then
        visibility.sample_effects_column_visible=true
      end
    end
    for column,cell in ipairs(line.effect_columns) do
      cell.is_empty=cell.number_value==0 and cell.amount_value==0
      if not cell.is_empty then visibility.visible_effect_columns=math.max(visibility.visible_effect_columns,column) end
    end
  end
  if native and next(native.midi_commands or {}) then
    visibility.visible_effect_columns=math.max(visibility.visible_effect_columns,1)
    visibility.instrument_column_visible=true
    visibility.panning_column_visible=true
  end
  return expected,visibility
end

function M.plan(source,output_policy,pb_range,capacities,capabilities,options)
  local fixture,source_error=sequencer.copy_source(source)
  if not fixture then return nil,source_error end
  output_policy=output_policy or policies.DEFAULT_OUTPUT_POLICY
  pb_range=pb_range==nil and policies.DEFAULT_PB_RANGE or pb_range
  if not policies.valid_pb_range(pb_range) then return nil,"invalid PB range" end
  if type(capacities)~="table" or not positive_integer(capacities.max_lines) or
      not positive_integer(capacities.max_note_columns) or
      type(capacities.max_effect_columns)~="number" or capacities.max_effect_columns%1~=0 or
      capacities.max_effect_columns<0 or not positive_integer(capacities.play_pattern) or
      not positive_integer(capacities.key_tracking_none) then
    return nil,"explicit native phrase capacities and playback constants are required"
  end
  options=options or {}
  if type(options)~="table" then return nil,"invalid planner options" end
  local plan,layout=M.plan_output(fixture,output_policy,capacities.max_lines)
  if not plan then return nil,layout end
  local timeline,timeline_error=control.compile(fixture,{gate_fraction=control.DEFAULT_GATE_FRACTION,
    plan=plan,output_policy=output_policy,successor=plan.loop and plan.loop.steady})
  if not timeline then return nil,timeline_error end
  if capabilities~=nil and (type(capabilities)~="table" or getmetatable(capabilities)~=nil) then
    return nil,"a receiver capability value profile is required"
  end
  capabilities=capabilities or {}
  local slides=slide_steps(plan)
  local receiver_needed=#slides>0 or pb_range>0
  local receiver=capabilities.plugin==true or capabilities.midi==true or capabilities.alias==true
  local receiver_known=receiver or (capabilities.plugin==false and capabilities.midi==false and
    capabilities.alias==false)
  if receiver_needed and (not receiver_known or (#slides>0 and not receiver and
      type(capabilities.sample)~="boolean")) then
    return nil,"receiver capability is unknown"..
      (type(capabilities.read_error)=="string" and ": "..capabilities.read_error or "")
  end
  local native_notes
  if receiver and receiver_needed then
    if pb_range>0 and type(options.pitch_bend_delivery)~="boolean" then
      return nil,"pitch-bend delivery capability is required"
    end
    local native_error
    native_notes,native_error=legato.plan(plan,timeline,layout,
      {pb_range=options.pitch_bend_delivery and pb_range or 0,instrument_value=255})
    if not native_notes then return nil,native_error end
    if pb_range>0 and not options.pitch_bend_delivery then
      native_notes.diagnostics[#native_notes.diagnostics+1]=
        "Phrase pitch-bend delivery is unavailable; NOTE overlap is retained for the whole phrase."
    end
  end
  if native_notes and (native_notes.columns>capacities.max_note_columns or
      (next(native_notes.midi_commands or {}) and capacities.max_effect_columns<1)) then
    return nil,"host phrase column capacity is insufficient for articulation"
  end
  local commands,approximations,minimum_rate
  if native_notes then
    commands,approximations,minimum_rate={},native_notes.diagnostics,1
    if capabilities.sample then
      approximations[#approximations+1]=next(native_notes.midi_commands or {}) and
        "Hybrid sample layers may respond differently to receiver pitch bend; samples and routing are unchanged." or
        "Hybrid sample layers receive overlapping notes; their envelopes and glide can differ from the plugin/MIDI receiver."
    end
  else
    commands,approximations,minimum_rate=articulation_plan(plan,capabilities,timeline,layout.lines_per_step)
    if commands and pb_range>0 and #slides>0 then
      approximations[#approximations+1]="PB Range requires a plugin or MIDI receiver; the existing sample/note articulation is retained."
    end
  end
  if not commands then return nil,approximations end
  local operations,operation_error=M.plan_gates(timeline,plan,commands,layout.lines_per_step)
  if not operations and #commands>0 then
    local collision_error=operation_error
    for candidate_rate=math.max(1,minimum_rate+1),255 do
      local candidate_commands=articulation.plan(plan,layout.lines_per_step,candidate_rate)
      if candidate_commands then
        local candidate_operations=M.plan_gates(timeline,plan,candidate_commands,layout.lines_per_step)
        if candidate_operations then
          commands,operations=candidate_commands,candidate_operations
          if candidate_rate==255 then
            approximations[#approximations+1]="native glide placement required 0G FF instant transitions; continuity is approximate"
          end
          break
        end
      end
    end
    if not operations then
      operations,operation_error=M.plan_gates(timeline,plan,{},layout.lines_per_step)
      if operations then
        local places={}
        for _,step in ipairs(slides) do places[#places+1]=string.format("%02d",step) end
        approximations[#approximations+1]=tostring(collision_error)..
          "; TIME steps "..table.concat(places,",")..
          " glide commands conflicted with gate timing at all rates, and ordered pitch events were retained"
        commands={}
      end
    end
  end
  if not operations then return nil,operation_error end
  local volumes,volume_error=M.expected_volumes(plan,layout.lines_per_step,
    layout.number_of_lines,capacities.max_note_columns)
  if not volumes then return nil,volume_error end
  local expected,visibility=expected_output(plan,layout,native_notes,operations,capacities,volumes)
  return {source=fixture,settings={output_policy=output_policy,pb_range=pb_range},plan=plan,
    layout=layout,timeline=timeline,operations=operations,native_notes=native_notes,
    approximations=approximations,volumes=volumes,expected=expected,required_visibility=visibility}
end

return M
