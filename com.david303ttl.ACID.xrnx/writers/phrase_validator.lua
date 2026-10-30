-- SPDX-License-Identifier: GPL-3.0-only
-- Verify phrase note and OFF cells against the semantic event plan.
-- Native Renoise note_value: 0..119 = notes, 120 = OFF, 121 = empty.
local M = {}
local ownership=require("renoise.phrase_ownership")
local planner=require("model.output_planner")
local policies=require("model.policies")
local store=require("renoise.pattern_store")
local EMPTY, OFF = 121, 120

local function verify_fields(cell,has_note,line,column,delay,midi)
  if (cell.delay_value or 0)~=(delay or 0) or (cell.instrument_value or 255)~=(midi and midi.instrument_value or 255)
    or (midi and cell.panning_string~="M1") or (not midi and (cell.panning_value or 255)~=255) then
    return nil,string.format("Unexpected delay, instrument or panning at phrase line 0x%02X column %d",line-1,column)
  end
  local volume=cell.volume_value or 255
  if volume~=255 and (not has_note or type(volume)~="number" or volume<0
    or volume>128 or volume%1~=0) then
    return nil,string.format("Unexpected volume or cut command at phrase line 0x%02X column %d",line-1,column)
  end
  return true
end

function M.verify(phrase, plan, lines_per_step, layout, articulation)
  if type(plan) ~= "table" or type(plan.steps) ~= "table"
    or type(plan.length) ~= "number" or plan.length < 1
    or plan.length % 1 ~= 0 then
    return nil, "invalid semantic plan"
  end
  if type(lines_per_step) ~= "number" or lines_per_step < 1
    or lines_per_step % 1 ~= 0 then
    return nil, "invalid lines-per-step"
  end
  if layout and layout.lines_per_step and layout.lines_per_step~=lines_per_step then
    return nil,"lines-per-step layout mismatch"
  end
  local musical_lines = plan.length * lines_per_step
  local expected_lines = layout and layout.number_of_lines or musical_lines
  if type(expected_lines)~="number" or expected_lines<musical_lines or
      phrase.number_of_lines ~= expected_lines then
    return nil, string.format("Expected %d phrase lines, received %s",
      expected_lines or musical_lines, tostring(phrase.number_of_lines))
  end
  if layout then
    if layout.lpb and phrase.lpb~=layout.lpb then
      return nil,"phrase LPB mismatch"
    end
    if layout.lpb and phrase.shuffle~=0 then
      return nil,"phrase shuffle must be zero"
    end
    if type(layout.looping)~="boolean" then
      return nil,"invalid phrase loop layout"
    end
    if layout.looping then
      local sentinel_lines=layout.sentinel_lines
      if type(layout.loop_start)~="number" or type(layout.loop_end)~="number"
        or layout.loop_start%1~=0 or layout.loop_end%1~=0
        or layout.loop_start<1 or layout.loop_end<=layout.loop_start
        or layout.loop_end>expected_lines or type(sentinel_lines)~="number"
        or sentinel_lines%1~=0 or sentinel_lines<0 then
        return nil,"invalid phrase loop range"
      end
      if expected_lines~=musical_lines+sentinel_lines or layout.loop_end~=expected_lines
        or plan.length~=layout.physical_steps
        or layout.loop_start~=layout.length*lines_per_step+1 then
        return nil,"loop phrase requires one empty exclusive-end sentinel line"
      end
    end
    if phrase.looping~=layout.looping then return nil,"phrase loop enablement mismatch" end
    if phrase.loop_start~=layout.loop_start or phrase.loop_end~=layout.loop_end then
      return nil,"phrase loop endpoints mismatch"
    end
  end

  local note_count, off_count = 0, 0
  local columns = phrase.visible_note_columns or 1
  local release_lines=articulation and articulation.release_lines or {}
  local effects=articulation and articulation.effects or {}
  local volumes=articulation and articulation.volumes or {}
  local native=articulation and articulation.native_notes
  if native and columns<native.columns then return nil,"Legato column count mismatch" end
  local midi_commands=native and native.midi_commands
  if midi_commands and next(midi_commands) and (phrase.visible_effect_columns or 0)<1 then
    return nil,"Pitch-bend effect column count mismatch"
  end
  for step = 1, plan.length do
    local event = plan.steps[step]
    if not event or event.step ~= step then
      return nil, "missing semantic step " .. step
    end
    local expected = EMPTY
    if event.kind == "note" then
      expected = event.note
      if not native then note_count = note_count + 1 end
    elseif event.kind == "rest" then
      if event.releases then
        expected = OFF
        if not native then off_count = off_count + 1 end
      end
    elseif event.kind ~= "tie" then
      return nil, "unsupported semantic kind at step " .. step
    end

    for offset = 1, lines_per_step do
      local line_number = (step - 1) * lines_per_step + offset
      local line = phrase:line(line_number)
      if not line or not line.note_columns then
        return nil, "missing phrase note columns at line " .. (line_number-1)
      end
      for column = 1, columns do
        local cell = line.note_columns[column]
        if not cell then
          return nil, "missing note column at line " .. (line_number-1)
        end
        local wanted = (offset == 1 and column == 1) and expected or EMPTY
        local native_cell=native and native.cells[line_number] and native.cells[line_number][column]
        if native then
          wanted=native_cell and native_cell.note_value or EMPTY
          if wanted<OFF then note_count=note_count+1
          elseif wanted==OFF then off_count=off_count+1 end
        end
        if column==1 and release_lines[line_number] then
          if wanted~=EMPTY then
            return nil,string.format("Contradictory release at TIME step %02d, cycle %d, phrase line 0x%02X",
              event.source_step or event.step,event.cycle or 1,line_number-1)
          end
          wanted=OFF
          off_count=off_count+1
        end
        if cell.note_value ~= wanted then
          return nil, string.format(
            "Phrase mismatch at line %02X column %d: expected %d, got %s",
            line_number-1, column, wanted, tostring(cell.note_value))
        end
        local fields_ok,fields_error=verify_fields(cell,wanted<OFF,line_number,column,
          native_cell and native_cell.delay_value,
          column==(native and native.columns) and midi_commands and midi_commands[line_number])
        if not fields_ok then return nil,fields_error end
        local expected_volume=native and (native_cell and native_cell.volume_value or 255)
          or (volumes[line_number] and volumes[line_number][column])
        if expected_volume and expected_volume~=(cell.volume_value or 255) then
          return nil,string.format("Phrase volume mismatch at line 0x%02X column %d",line_number-1,column)
        end
        local effect=effects[line_number]
        if column==1 and effect then
          if cell.effect_number_string~="0G" or cell.effect_amount_value~=effect then
            return nil,"Phrase glide mismatch at line "..string.format("%02X",line_number-1)
          end
        elseif (cell.effect_number_value or 0)~=0 or
            (cell.effect_amount_value or 0)~=0 then
          return nil,"Unexpected note-column effect at line "..string.format("%02X",line_number-1)
        end
      end
    end
    for column=1,(phrase.visible_effect_columns or 0) do
      local line_number=(step-1)*lines_per_step+1
      for offset=0,lines_per_step-1 do
        local line=phrase:line(line_number+offset)
        local cell=line and line.effect_columns and line.effect_columns[column]
        if not cell then return nil,"missing effect column at line "..(line_number+offset-1) end
        local command=column==1 and midi_commands and midi_commands[line_number+offset]
        if command then
          if cell.number_string~=command.number_string or cell.amount_value~=command.amount_value then
            return nil,"Pitch-bend command mismatch at line "..(line_number+offset-1)
          end
        elseif (cell.number_value or 0)~=0 or (cell.amount_value or 0)~=0 then
          return nil,"Unexpected effect-column data at line "..(line_number+offset-1)
        end
      end
    end
  end
  if expected_lines>musical_lines then
    for line_number=musical_lines+1,expected_lines do
      local line=phrase:line(line_number)
      if not line or not line.note_columns then
        return nil,"missing exclusive-end sentinel line "..(line_number-1)
      end
      for column=1,columns do
        local cell=line.note_columns[column]
        if not cell or cell.note_value~=EMPTY or
            (cell.effect_number_value or 0)~=0 or
            (cell.effect_amount_value or 0)~=0 then
          return nil,"exclusive-end sentinel must be empty at line "..(line_number-1)
        end
        local fields_ok,fields_error=verify_fields(cell,false,line_number,column)
        if not fields_ok then return nil,fields_error end
        if volumes[line_number] and (volumes[line_number][column] or 255)~=(cell.volume_value or 255) then
          return nil,string.format("Phrase volume mismatch at line 0x%02X column %d",line_number-1,column)
        end
      end
      for column=1,(phrase.visible_effect_columns or 0) do
        local cell=line.effect_columns and line.effect_columns[column]
        if not cell or (cell.number_value or 0)~=0 or (cell.amount_value or 0)~=0 then
          return nil,"exclusive-end sentinel effect must be empty at line "..(line_number-1)
        end
      end
    end
  end
  return {notes=note_count, offs=off_count, lines=expected_lines}
end

local function protected(check,...)
  local ok,result,err=pcall(check,...)
  if not ok then return nil,"Cannot validate phrase: "..tostring(result) end
  return result,err
end

local function visibility(snapshot,output)
  local properties,required=snapshot.properties,output.required_visibility
  for _,key in ipairs({"visible_note_columns","visible_effect_columns"}) do
    if properties[key]<required[key] then return nil,"Insufficient phrase visibility: "..key end
  end
  for _,key in ipairs({"instrument_column_visible","volume_column_visible",
      "panning_column_visible","delay_column_visible","sample_effects_column_visible"}) do
    if required[key] and not properties[key] then return nil,"Insufficient phrase visibility: "..key end
  end
  return true
end

local function preflight(snapshot,output)
  local empty,script_error=ownership.empty_script(snapshot)
  if not empty then return nil,script_error end
  local visible,visibility_error=visibility(snapshot,output)
  if not visible then return nil,visibility_error end
  local properties=snapshot.properties
  if snapshot.mapping.present and properties.number_of_lines~=output.expected.properties.number_of_lines then
    return nil,"Mapped phrase length changes are unsupported"
  end
  for line_index=1,512 do
    local line=snapshot.lines[line_index]
    for column=1,12 do
      if (line_index>properties.number_of_lines or column>properties.visible_note_columns)
          and not line.notes[column].is_empty then
        return nil,"Phrase contains hidden or inactive note data"
      end
    end
    for column=1,8 do
      if (line_index>properties.number_of_lines or column>properties.visible_effect_columns)
          and not line.effects[column].is_empty then
        return nil,"Phrase contains hidden or inactive effect data"
      end
    end
  end
  return true
end

-- Preflight consumes a detached baseline and a plan derived from the proposed source.
function M.preflight(snapshot,output)
  return protected(preflight,snapshot,output)
end

local function expected_output(snapshot,output)
  local generated={}
  for key in pairs(output.expected.properties) do generated[key]=snapshot.properties[key] end
  local same,reason=ownership.compare(generated,output.expected.properties)
  if not same then return nil,"Committed output differs: "..reason end
  for line_index=1,512 do
    local actual=snapshot.lines[line_index]
    local expected=output.expected.lines[line_index]
    for column=1,12 do
      local wanted=expected and expected.note_columns[column] or output.expected.empty_note
      local same,reason=ownership.compare(actual.notes[column],wanted)
      if not same then return nil,"Committed note output differs at line "..line_index.." column "..column..": "..reason end
    end
    for column=1,8 do
      local wanted=expected and expected.effect_columns[column] or output.expected.empty_effect
      local same,reason=ownership.compare(actual.effects[column],wanted)
      if not same then return nil,"Committed effect output differs at line "..line_index.." column "..column..": "..reason end
    end
  end
  return true
end

local function compatibility(phrase,committed,capabilities,capacities,options)
  if options~=nil and (type(options)~="table" or getmetatable(options)~=nil) then
    return nil,"Invalid compatibility options"
  end
  if options and rawget(options,"excluded")~=nil then
    return nil,"Ownership exclusions are not supported"
  end
  if type(capacities)~="table" or getmetatable(capacities)~=nil then return nil,"Invalid native capacities" end
  if type(committed)~="table" or
      not policies.valid_output_policy(committed.output_policy) or
      type(committed.pb_range)~="number" then return nil,"Invalid committed source settings" end
  local baseline,snapshot_error=ownership.snapshot(phrase)
  if not baseline then return nil,snapshot_error end
  local status=ownership.status(phrase)
  if status~="owned" then return nil,"Phrase is not an unchanged ACID-owned phrase" end
  local output,planning_error=planner.plan(committed.pattern,committed.output_policy,
    committed.pb_range,capacities,capabilities,options)
  if not output then return nil,planning_error end
  local safe,preflight_error=preflight(baseline,output)
  if not safe then return nil,preflight_error end
  local matches,output_error=expected_output(baseline,output)
  if not matches then return nil,output_error end
  local profile,limits={},{}
  for _,key in ipairs({"sample","plugin","midi","alias","read_error"}) do
    profile[key]=capabilities and capabilities[key]
  end
  for _,key in ipairs({"max_lines","max_note_columns","max_effect_columns","play_pattern","key_tracking_none"}) do
    limits[key]=capacities[key]
  end
  local inputs,input_error=ownership.copy_snapshot({capabilities=profile,capacities=limits,
    options={pitch_bend_delivery=options and options.pitch_bend_delivery}})
  if not inputs then return nil,input_error end
  return {kind="owned",baseline=baseline,output=output,source=output.source,settings=output.settings,
    planning_inputs=inputs}
end

-- Complete compatibility authorizes only the saved source/output association.
-- verify() checks an intermediate renderer payload; it is not ownership permission.
function M.compatibility(phrase,committed,capabilities,capacities,options,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  return protected(compatibility,phrase,committed,capabilities,capacities,options)
end

function M.classify(song,instrument,phrase,capabilities,capacities,options,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported","unavailable" end
  if options~=nil and (type(options)~="table" or getmetatable(options)~=nil) then
    return nil,"Invalid classification options","unavailable"
  end
  if options and rawget(options,"excluded")~=nil then
    return nil,"Ownership exclusions are not supported","unavailable"
  end
  local member,membership_error=ownership.membership(song,instrument,phrase)
  if not member or phrase==nil then return nil,membership_error or "An existing phrase is required","unavailable" end
  local readable,id=pcall(ownership.id,phrase)
  if not readable then return nil,"Cannot inspect phrase identity","unavailable" end
  if not id then return nil,"Phrase has no recognized ACID identity","foreign" end
  local ok,source,policy,pb_range=pcall(store.load,song,instrument,phrase)
  if not ok then return nil,"Cannot read committed source: "..tostring(source),"unavailable" end
  if not source then return nil,policy,"unavailable" end
  local candidate,err=M.compatibility(phrase,{pattern=source,output_policy=policy,pb_range=pb_range},
    capabilities,capacities,options)
  if not candidate then return nil,err,"unavailable" end
  return candidate
end

return M
