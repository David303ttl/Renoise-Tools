-- SPDX-License-Identifier: GPL-3.0-only
-- Synchronously writes and verifies generated phrase content.
local ownership=require("renoise.phrase_ownership")

local M={}
local verified_outputs=setmetatable({},{__mode="k"})
local generated_properties={"number_of_lines","lpb","shuffle","looping",
  "loop_start","loop_end","playback_mode","key_tracking"}
local other_properties={"lpb","shuffle","playback_mode","key_tracking"}
local visibility_numbers={"visible_note_columns","visible_effect_columns"}
local visibility_booleans={"instrument_column_visible","volume_column_visible",
  "panning_column_visible","delay_column_visible","sample_effects_column_visible"}
local note_fields={"note_value","instrument_value","volume_value","panning_value",
  "delay_value","effect_number_value","effect_amount_value"}
local effect_fields={"number_value","amount_value"}
local snapshot_numeric_properties={"number_of_lines","lpb","shuffle","loop_start","loop_end",
  "playback_mode","key_tracking","base_note","visible_note_columns","visible_effect_columns"}
local snapshot_boolean_properties={"looping","autoseek","instrument_column_visible",
  "volume_column_visible","panning_column_visible","delay_column_visible","sample_effects_column_visible"}

local function integer(value,minimum)
  return type(value)=="number" and value==value and value~=math.huge and
    value~=-math.huge and value%1==0 and value>=minimum
end

local function valid_limits(limits)
  if type(limits)~="table" or getmetatable(limits)~=nil or
      not integer(rawget(limits,"max_lines"),2) or
      not integer(rawget(limits,"max_note_columns"),1) or
      not integer(rawget(limits,"max_effect_columns"),0) then
    return nil,"Invalid phrase materializer capacities"
  end
  return true
end

local function valid_visibility(visibility)
  if type(visibility)~="table" or getmetatable(visibility)~=nil then
    return nil,"Invalid required phrase visibility"
  end
  for _,key in ipairs(visibility_numbers) do
    local value=rawget(visibility,key)
    if not integer(value, key=="visible_note_columns" and 1 or 0) then
      return nil,"Invalid required phrase visibility: "..key
    end
  end
  for _,key in ipairs(visibility_booleans) do
    if type(rawget(visibility,key))~="boolean" then
      return nil,"Invalid required phrase visibility: "..key
    end
  end
  return true
end

local function note_is_empty(cell)
  return cell.note_value==121 and cell.instrument_value==255 and cell.volume_value==255 and
    cell.panning_value==255 and cell.delay_value==0 and cell.effect_number_value==0 and
    cell.effect_amount_value==0
end

local function effect_is_empty(cell)
  return cell.number_value==0 and cell.amount_value==0
end

local function finite_number(value)
  return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
end

local function exact_keys(value,keys)
  if type(value)~="table" or getmetatable(value)~=nil then return false end
  local count=0
  for key in pairs(value) do
    count=count+1
    local found=false
    for _,allowed in ipairs(keys) do if key==allowed then found=true;break end end
    if not found then return false end
  end
  if count~=#keys then return false end
  for _,key in ipairs(keys) do if rawget(value,key)==nil then return false end end
  return true
end

local function exact_array(value,length)
  if type(value)~="table" or getmetatable(value)~=nil or #value~=length then return false end
  local count=0
  for key in pairs(value) do
    if not integer(key,1) or key>length then return false end
    count=count+1
  end
  return count==length
end

local function valid_snapshot(snapshot,limits)
  if not exact_keys(snapshot,{"name","properties","columns","mapping","script","lines"}) or
      type(snapshot.name)~="string" or
      not exact_keys(snapshot.properties,{"number_of_lines","lpb","shuffle","loop_start","loop_end",
        "playback_mode","key_tracking","base_note","visible_note_columns","visible_effect_columns",
        "looping","autoseek","instrument_column_visible","volume_column_visible",
        "panning_column_visible","delay_column_visible","sample_effects_column_visible"}) then
    return nil,"Invalid restore snapshot shape"
  end
  for _,key in ipairs(snapshot_numeric_properties) do
    if not finite_number(snapshot.properties[key]) then return nil,"Invalid restore snapshot property: "..key end
  end
  for _,key in ipairs(snapshot_boolean_properties) do
    if type(snapshot.properties[key])~="boolean" then return nil,"Invalid restore snapshot property: "..key end
  end
  if snapshot.properties.number_of_lines<1 or snapshot.properties.number_of_lines>limits.max_lines or
      not integer(snapshot.properties.visible_note_columns,1) or
      snapshot.properties.visible_note_columns>limits.max_note_columns or
      not integer(snapshot.properties.visible_effect_columns,0) or
      snapshot.properties.visible_effect_columns>limits.max_effect_columns then
    return nil,"Invalid restore snapshot property range"
  end
  local columns=snapshot.columns
  if not exact_array(columns,limits.max_note_columns) then
    return nil,"Invalid restore snapshot columns"
  end
  for index=1,limits.max_note_columns do
    local column=columns[index]
    if not exact_keys(column,{"name","muted"}) or type(column.name)~="string" or type(column.muted)~="boolean" then
      return nil,"Invalid restore snapshot column: "..index
    end
  end
  local mapping=snapshot.mapping
  if type(mapping)~="table" or getmetatable(mapping)~=nil or type(mapping.present)~="boolean" then
    return nil,"Invalid restore snapshot mapping"
  end
  if mapping.present then
    if not exact_keys(mapping,{"present","key_tracking","base_note","loop_start","loop_end","looping","note_range"}) or
        not finite_number(mapping.key_tracking) or not finite_number(mapping.base_note) or
        not finite_number(mapping.loop_start) or not finite_number(mapping.loop_end) or
        type(mapping.looping)~="boolean" or not exact_array(mapping.note_range,2) or
        not finite_number(mapping.note_range[1]) or not finite_number(mapping.note_range[2]) then
      return nil,"Invalid restore snapshot mapping"
    end
  elseif not exact_keys(mapping,{"present"}) then
    return nil,"Invalid restore snapshot mapping"
  end
  local script=snapshot.script
  if not exact_keys(script,{"paragraphs","parameters","pending_changes","editor_visible"}) or
      type(script.paragraphs)~="table" or getmetatable(script.paragraphs)~=nil or
      type(script.parameters)~="table" or getmetatable(script.parameters)~=nil or
      not finite_number(script.pending_changes) or type(script.editor_visible)~="boolean" then
    return nil,"Invalid restore snapshot script"
  end
  if not exact_array(script.paragraphs,#script.paragraphs) or
      not exact_array(script.parameters,#script.parameters) then
    return nil,"Invalid restore snapshot script arrays"
  end
  for index=1,#script.paragraphs do
    if type(script.paragraphs[index])~="string" then return nil,"Invalid restore snapshot script paragraph" end
  end
  for index=1,#script.parameters do
    local parameter=script.parameters[index]
    if not exact_keys(parameter,{"name","value"}) or type(parameter.name)~="string" or
        not finite_number(parameter.value) then return nil,"Invalid restore snapshot script parameter" end
  end
  if not exact_array(snapshot.lines,limits.max_lines) then return nil,"Invalid restore snapshot lines" end
  for index=1,limits.max_lines do
    local line=snapshot.lines[index]
    if not exact_keys(line,{"notes","effects"}) or not exact_array(line.notes,limits.max_note_columns) or
        not exact_array(line.effects,limits.max_effect_columns) then
      return nil,"Invalid restore snapshot line: "..index end
    for column=1,limits.max_note_columns do
      local cell=line.notes[column]
      if not exact_keys(cell,{"note_value","instrument_value","volume_value","panning_value",
          "delay_value","effect_number_value","effect_amount_value","is_empty"}) or
          type(cell.is_empty)~="boolean" then return nil,"Invalid restore note cell" end
      for _,field in ipairs(note_fields) do
        if not finite_number(cell[field]) then return nil,"Invalid restore note field: "..field end
      end
      if cell.is_empty~=note_is_empty(cell) then return nil,"Invalid restore note emptiness" end
    end
    for column=1,limits.max_effect_columns do
      local cell=line.effects[column]
      if not exact_keys(cell,{"number_value","amount_value","is_empty"}) or
          type(cell.is_empty)~="boolean" or not finite_number(cell.number_value) or
          not finite_number(cell.amount_value) then return nil,"Invalid restore effect cell" end
      if cell.is_empty~=effect_is_empty(cell) then return nil,"Invalid restore effect emptiness" end
    end
  end
  return true
end

local function valid_expected(expected,limits)
  if type(expected)~="table" or getmetatable(expected)~=nil or
      type(expected.properties)~="table" or getmetatable(expected.properties)~=nil or
      type(expected.lines)~="table" or getmetatable(expected.lines)~=nil or
      #expected.lines~=limits.max_lines then
    return nil,"Invalid expected phrase output"
  end
  for _,key in ipairs(generated_properties) do
    local value=rawget(expected.properties,key)
    local kind=key=="looping" and "boolean" or "number"
    if type(value)~=kind or (kind=="number" and not integer(value,0)) then
      return nil,"Invalid expected phrase property: "..key
    end
  end
  local line_one=expected.lines[1]
  local line_two=expected.lines[2]
  if expected.properties.number_of_lines<2 or expected.properties.number_of_lines>limits.max_lines or
      expected.properties.loop_start<1 or expected.properties.loop_start>expected.properties.number_of_lines or
      expected.properties.loop_end<expected.properties.loop_start or
      expected.properties.loop_end>expected.properties.number_of_lines or
      not line_one or not line_two then
    return nil,"Invalid expected phrase loop layout"
  end
  if type(expected.empty_note)~="table" or type(expected.empty_effect)~="table" then
    return nil,"Expected phrase output has no empty cell templates"
  end
  local checked_notes,checked_effects,checked_lines={},{},{}
  for index=1,limits.max_lines do
    local line=expected.lines[index]
    if type(line)~="table" or getmetatable(line)~=nil then
      return nil,"Invalid expected phrase line: "..index
    end
    if not checked_lines[line] then
      if type(line.note_columns)~="table" or getmetatable(line.note_columns)~=nil or
          #line.note_columns~=limits.max_note_columns or
          type(line.effect_columns)~="table" or getmetatable(line.effect_columns)~=nil or
          #line.effect_columns~=limits.max_effect_columns then
        return nil,"Invalid expected phrase line: "..index
      end
      for column=1,limits.max_note_columns do
        local cell=line.note_columns[column]
        if type(cell)~="table" then return nil,"Invalid expected note cell: "..index.."/"..column end
        if not checked_notes[cell] then
          if getmetatable(cell)~=nil or type(cell.is_empty)~="boolean" then
            return nil,"Invalid expected note cell: "..index.."/"..column
          end
          for _,field in ipairs(note_fields) do
            if not integer(rawget(cell,field),0) then
              return nil,"Invalid expected note field: "..index.."/"..column.."/"..field
            end
          end
          if cell.is_empty~=note_is_empty(cell) then
            return nil,"Invalid expected note emptiness: "..index.."/"..column
          end
          checked_notes[cell]=true
        end
      end
      for column=1,limits.max_effect_columns do
        local cell=line.effect_columns[column]
        if type(cell)~="table" then return nil,"Invalid expected effect cell: "..index.."/"..column end
        if not checked_effects[cell] then
          if getmetatable(cell)~=nil or type(cell.is_empty)~="boolean" then
            return nil,"Invalid expected effect cell: "..index.."/"..column
          end
          for _,field in ipairs(effect_fields) do
            if not integer(rawget(cell,field),0) then
              return nil,"Invalid expected effect field: "..index.."/"..column.."/"..field
            end
          end
          if cell.is_empty~=effect_is_empty(cell) then
            return nil,"Invalid expected effect emptiness: "..index.."/"..column
          end
          checked_effects[cell]=true
        end
      end
      checked_lines[line]=true
    end
  end
  return true
end

local function snapshots(phrase,limits)
  local snapshot,error_message=ownership.snapshot(phrase,limits)
  if not snapshot then return nil,error_message end
  return snapshot
end

local function seal_columns(phrase,snapshot,limits)
  local values={}
  for column=1,12 do
    local ok,muted=pcall(function() return phrase:column_is_muted(column) end)
    if not ok or type(muted)~="boolean" then
      return nil,"Cannot inspect phrase seal column metadata"
    end
    values[column]=muted
    if column<=limits.max_note_columns and snapshot.columns[column].muted~=muted then
      return nil,"Phrase seal column metadata changed during materialization"
    end
  end
  return values
end

local function preserved(before,after,required_visibility)
  if not before then return true end
  local adjusted={name=before.name,columns=before.columns,mapping=before.mapping,
    script=before.script,lines=before.lines,properties={}}
  for key,value in pairs(before.properties) do adjusted.properties[key]=value end
  for _,key in ipairs(visibility_numbers) do
    local wanted=math.max(before.properties[key],required_visibility[key])
    if after.properties[key]~=wanted then
      return nil,"Phrase visibility changed outside the required expansion: "..key
    end
    adjusted.properties[key]=wanted
  end
  for _,key in ipairs(visibility_booleans) do
    local wanted=before.properties[key] or required_visibility[key]
    if after.properties[key]~=wanted then
      return nil,"Phrase visibility changed outside the required expansion: "..key
    end
    adjusted.properties[key]=wanted
  end
  local same,reason=ownership.compare(adjusted,after,"generated")
  if not same then return nil,"Phrase metadata changed during materialization: "..tostring(reason) end
  return true
end

local function expected_matches(actual,expected,required_visibility,before,private_postimage)
  local props=actual.properties
  local matched_private_rows=private_postimage and {} or nil
  local matched_empty_notes,matched_empty_effects
  if private_postimage then matched_empty_notes,matched_empty_effects={},{} end
  for _,key in ipairs(generated_properties) do
    if props[key]~=expected.properties[key] then
      return nil,"Generated phrase property differs: "..key
    end
  end
  for index=1,#expected.lines do
    local wanted,got=expected.lines[index],actual.lines[index]
    local row_pairs=matched_private_rows and matched_private_rows[wanted]
    if not (row_pairs and row_pairs[got]) then
      for column=1,#wanted.note_columns do
        local expected_cell,actual_cell=wanted.note_columns[column],got.notes[column]
        local memoized=private_postimage and rawequal(expected_cell,expected.empty_note) and
          matched_empty_notes[actual_cell]==expected_cell
        if not memoized then
          for _,field in ipairs(note_fields) do
            if actual_cell[field]~=expected_cell[field] then
              return nil,"Generated note cell differs: "..index.."/"..column.."/"..field
            end
          end
          if actual_cell.is_empty~=expected_cell.is_empty then
            return nil,"Generated note emptiness differs: "..index.."/"..column
          end
          if private_postimage and rawequal(expected_cell,expected.empty_note) and
              type(actual_cell)=="table" then
            matched_empty_notes[actual_cell]=expected_cell
          end
        end
      end
      for column=1,#wanted.effect_columns do
        local expected_cell,actual_cell=wanted.effect_columns[column],got.effects[column]
        local memoized=private_postimage and rawequal(expected_cell,expected.empty_effect) and
          matched_empty_effects[actual_cell]==expected_cell
        if not memoized then
          for _,field in ipairs(effect_fields) do
            if actual_cell[field]~=expected_cell[field] then
              return nil,"Generated effect cell differs: "..index.."/"..column.."/"..field
            end
          end
          if actual_cell.is_empty~=expected_cell.is_empty then
            return nil,"Generated effect emptiness differs: "..index.."/"..column
          end
          if private_postimage and rawequal(expected_cell,expected.empty_effect) and
              type(actual_cell)=="table" then
            matched_empty_effects[actual_cell]=expected_cell
          end
        end
      end
      if matched_private_rows then
        row_pairs=row_pairs or {}
        row_pairs[got]=true
        matched_private_rows[wanted]=row_pairs
      end
    end
  end
  local floor=required_visibility
  for _,key in ipairs(visibility_numbers) do
    local minimum=floor[key]
    if before then minimum=math.max(minimum,before.properties[key]) end
    if props[key]<minimum then return nil,"Phrase visibility is below required floor: "..key end
  end
  for _,key in ipairs(visibility_booleans) do
    local minimum=floor[key] or (before and before.properties[key])
    if minimum and not props[key] then return nil,"Phrase visibility is below required floor: "..key end
  end
  return true
end

local function verify_snapshot(phrase,expected,required_visibility,before,limits,private_postimage)
  local actual,error_message
  if private_postimage then
    actual,error_message=ownership.snapshot_for_verification(phrase,limits)
  else
    actual,error_message=snapshots(phrase,limits)
  end
  if not actual then return nil,error_message end
  local same,preserve_error=preserved(before,actual,required_visibility)
  if not same then return nil,preserve_error,actual end
  local matches,match_error=expected_matches(actual,expected,required_visibility,before,
    private_postimage==true)
  if not matches then return nil,match_error,actual end
  return true,actual
end

function M.verify(phrase,expected,required_visibility,before,limits)
  local valid,error_message=valid_limits(limits)
  if not valid then return nil,error_message end
  valid,error_message=valid_expected(expected,limits)
  if not valid then return nil,error_message end
  valid,error_message=valid_visibility(required_visibility)
  if not valid then return nil,error_message end
  return verify_snapshot(phrase,expected,required_visibility,before,limits)
end

local function set_if_different(object,key,value,current)
  if current==nil or current[key]~=value then object[key]=value end
end

local function set_cell(line,column,wanted,current,is_note)
  local cell=is_note and line:note_column(column) or line:effect_column(column)
  local saved=is_note and current.notes[column] or current.effects[column]
  local fields=is_note and note_fields or effect_fields
  for _,field in ipairs(fields) do set_if_different(cell,field,wanted[field],saved) end
end

local function same_cell(left,right,fields)
  if type(left)~="table" or type(right)~="table" or left.is_empty~=right.is_empty then return false end
  if rawequal(fields,note_fields) then
    return left.note_value==right.note_value and left.instrument_value==right.instrument_value and
      left.volume_value==right.volume_value and left.panning_value==right.panning_value and
      left.delay_value==right.delay_value and left.effect_number_value==right.effect_number_value and
      left.effect_amount_value==right.effect_amount_value
  end
  return left.number_value==right.number_value and left.amount_value==right.amount_value
end

local function write_output(phrase,expected,visibility,before,limits)
  local p=expected.properties
  local previous=before.properties
  local geometry_changed=previous.number_of_lines~=p.number_of_lines or
    previous.loop_start~=p.loop_start or previous.loop_end~=p.loop_end
  if geometry_changed then
    if phrase.looping then phrase.looping=false end
    local lines=phrase.number_of_lines
    if lines<2 then
      lines=2
      phrase.number_of_lines=lines
    end
    if p.number_of_lines>lines then
      lines=p.number_of_lines
      phrase.number_of_lines=lines
    end
    local loop_start=phrase.loop_start
    if p.loop_start<loop_start then
      loop_start=p.loop_start
      phrase.loop_start=loop_start
    end
    if phrase.loop_end~=p.loop_end then phrase.loop_end=p.loop_end end
    if loop_start~=p.loop_start then phrase.loop_start=p.loop_start end
    if p.number_of_lines<lines then phrase.number_of_lines=p.number_of_lines end
    if phrase.looping~=p.looping then phrase.looping=p.looping end
  elseif previous.looping~=p.looping then
    phrase.looping=p.looping
  end
  for _,key in ipairs(other_properties) do
    if previous[key]~=p[key] then phrase[key]=p[key] end
  end

  for _,key in ipairs(visibility_numbers) do
    local current=phrase[key]
    local wanted=math.max(current,visibility[key])
    if current~=wanted then phrase[key]=wanted end
  end
  for _,key in ipairs(visibility_booleans) do
    local current=phrase[key]
    local wanted=current or visibility[key]
    if current~=wanted then phrase[key]=wanted end
  end

  local compared_rows,unchanged={},{}
  for index=1,limits.max_lines do
    local previous=before and before.lines[index]
    local wanted=expected.lines[index]
    local row_cache=compared_rows[wanted]
    local changes
    if row_cache then
      if row_cache.previous==previous then
        changes=row_cache.changes
      elseif row_cache.pairs then
        changes=row_cache.pairs[previous]
      end
    end
    if not changes then
      local changed_notes,changed_effects
      for column=1,limits.max_note_columns do
        if not same_cell(wanted.note_columns[column],previous.notes[column],note_fields) then
          changed_notes=changed_notes or {}
          changed_notes[#changed_notes+1]=column
        end
      end
      for column=1,limits.max_effect_columns do
        if not same_cell(wanted.effect_columns[column],previous.effects[column],effect_fields) then
          changed_effects=changed_effects or {}
          changed_effects[#changed_effects+1]=column
        end
      end
      changes=(changed_notes or changed_effects) and
        {notes=changed_notes,effects=changed_effects} or unchanged
      if not row_cache then
        compared_rows[wanted]={previous=previous,changes=changes}
      elseif not row_cache.pairs then
        row_cache.pairs={[row_cache.previous]=row_cache.changes,[previous]=changes}
      else
        row_cache.pairs[previous]=changes
      end
    end
    if changes~=unchanged then
      local line=phrase:line(index)
      for _,column in ipairs(changes.notes or {}) do
        set_cell(line,column,wanted.note_columns[column],previous,true)
      end
      for _,column in ipairs(changes.effects or {}) do
        set_cell(line,column,wanted.effect_columns[column],previous,false)
      end
    end
  end
end

-- The third result reports whether phrase output mutation was attempted.
function M.apply(phrase,expected,required_visibility,before,limits,planned_output,planning_inputs,before_index)
  local function reject(error_message)
    return nil,error_message,false
  end
  local valid,error_message=valid_limits(limits)
  if not valid then return reject(error_message) end
  valid,error_message=valid_expected(expected,limits)
  if not valid then return reject(error_message) end
  valid,error_message=valid_visibility(required_visibility)
  if not valid then return reject(error_message) end
  if before==nil and before_index~=nil then
    return reject("Preimage phrase index was supplied without a preimage snapshot")
  end
  local canonical_plan
  if planned_output~=nil or planning_inputs~=nil then
    if type(planned_output)~="table" or getmetatable(planned_output)~=nil or
        type(planned_output.source)~="table" or type(planned_output.settings)~="table" or
        type(planned_output.required_visibility)~="table" or
        getmetatable(planned_output.required_visibility)~=nil or
        type(planning_inputs)~="table" or getmetatable(planning_inputs)~=nil then
      return reject("Invalid verified output planning inputs")
    end
    if not rawequal(planned_output.expected,expected) then
      return reject("Verified output expectation differs from its plan")
    end
    if ownership.compare(planned_output.required_visibility,required_visibility)~=true then
      return reject("Verified output visibility differs from its plan")
    end
    canonical_plan,error_message=ownership.copy_snapshot({source=planned_output.source,
      settings=planned_output.settings,planning_inputs=planning_inputs,
      required_visibility=planned_output.required_visibility})
    if not canonical_plan then return reject("Cannot retain output planning inputs: "..tostring(error_message)) end
  end
  local current
  if before~=nil then
    local index,index_error=before_index
    if index==nil then index,index_error=ownership.snapshot_index(before,limits) end
    if not index then return reject("Invalid preimage phrase snapshot: "..tostring(index_error)) end
    local unchanged,reason=ownership.matches_snapshot(phrase,before,limits,index)
    if unchanged~=true then
      return reject("Phrase no longer matches its preimage: "..tostring(reason))
    end
    current=before
  else
    before,error_message=snapshots(phrase,limits)
    if not before then return reject(error_message) end
    current=before
  end
  local ok,write_error=pcall(write_output,phrase,expected,required_visibility,current,limits)
  if not ok then
    return nil,"Phrase materialization failed: "..tostring(write_error),true
  end
  local success,actual,verify_error=verify_snapshot(phrase,expected,required_visibility,before,limits,true)
  if not success then return nil,actual,true end
  local columns,column_error=seal_columns(phrase,actual,limits)
  if not columns then return nil,column_error,true end
  local index,index_error=ownership.snapshot_index(actual,limits)
  if not index then return nil,"Cannot index verified phrase output: "..tostring(index_error),true end
  local token={}
  local rollback_state={snapshot=actual,original_name=actual.name}
  verified_outputs[token]={
    max_lines=limits.max_lines,max_note_columns=limits.max_note_columns,
    max_effect_columns=limits.max_effect_columns,snapshot=actual,index=index,
    planned_output=planned_output,canonical_plan=canonical_plan,seal_columns=columns,
    rollback_state=rollback_state}
  return true,token,true
end

local function valid_token(token)
  if type(token)~="table" or getmetatable(token)~=nil or next(token)~=nil then return false end
  return verified_outputs[token]~=nil
end

-- Derive the authorized phrase seal from the private image without exposing it.
function M.name_for_verified_output(token,id)
  if not valid_token(token) then return nil,"Verified phrase output token is unavailable" end
  local proof=verified_outputs[token]
  if proof.authorized_id~=nil and proof.authorized_id~=id then
    return nil,"Verified phrase output already has a different authorized ID"
  end
  local name,error_message=ownership.make_name_from_verified_snapshot(proof.snapshot,id,proof.seal_columns)
  if not name then return nil,error_message end
  if proof.authorized_name and proof.authorized_name~=name then
    return nil,"Verified phrase output name changed"
  end
  proof.authorized_id,proof.authorized_name=id,name
  proof.rollback_state.authorized_name=name
  return name
end

-- Keep a writer-local predicate for the rare rollback path after output writes.
function M.rollback_guard(token)
  if not valid_token(token) then return nil,"Verified phrase output token is unavailable" end
  local state=verified_outputs[token].rollback_state
  return function(phrase,limits)
    local current,error_message=ownership.snapshot_for_verification(phrase,limits)
    if not current then return false,error_message end
    if current.name~=state.original_name and current.name~=state.authorized_name then
      return false,"Phrase name changed after verified materialization"
    end
    return ownership.compare(state.snapshot,current,"name")
  end
end

-- Consume the writer's single-use handoff after source commit and name assignment.
function M.consume_verified_output(token,expected_id,expected_name,limits,planned_output,planning_inputs)
  if not valid_token(token) then return nil,"Verified phrase output token is unavailable" end
  local proof=verified_outputs[token]
  if proof.authorized_id~=expected_id or proof.authorized_name~=expected_name then
    return nil,"Verified output receipt does not match its authorized phrase name"
  end
  local valid,error_message=valid_limits(limits)
  if not valid then return nil,error_message end
  if proof.max_lines~=limits.max_lines or proof.max_note_columns~=limits.max_note_columns or
      proof.max_effect_columns~=limits.max_effect_columns or
      not rawequal(proof.planned_output,planned_output) then
    return nil,"Verified output receipt does not match its writer request"
  end
  local canonical=proof.canonical_plan
  if canonical then
    if type(planned_output)~="table" or type(planning_inputs)~="table" or
        ownership.compare(canonical.source,planned_output.source)~=true or
        ownership.compare(canonical.settings,planned_output.settings)~=true or
        ownership.compare(canonical.planning_inputs,planning_inputs)~=true or
        ownership.compare(canonical.required_visibility,planned_output.required_visibility)~=true then
      return nil,"Verified output planning inputs changed after materialization"
    end
  elseif planning_inputs~=nil then
    return nil,"Verified output receipt has no planning input proof"
  end
  verified_outputs[token]=nil
  local snapshot,index,canonical_plan=proof.snapshot,proof.index,proof.canonical_plan
  proof.snapshot,proof.index,proof.canonical_plan,proof.planned_output,proof.seal_columns=nil,nil,nil,nil,nil
  return snapshot,index,canonical_plan
end

local function write_snapshot(phrase,snapshot,limits,current)
  local p=snapshot.properties
  phrase.name=snapshot.name
  phrase.looping=false
  if phrase.number_of_lines<2 then phrase.number_of_lines=2 end
  phrase.loop_start=1
  phrase.loop_end=2
  phrase.number_of_lines=math.max(2,p.number_of_lines)
  for _,key in ipairs(other_properties) do phrase[key]=p[key] end
  for _,key in ipairs(visibility_numbers) do phrase[key]=p[key] end
  for _,key in ipairs(visibility_booleans) do phrase[key]=p[key] end
  for index=1,limits.max_lines do
    local previous=current and current.lines[index]
    local changed_notes,changed_effects
    for column=1,limits.max_note_columns do
      if not same_cell(snapshot.lines[index].notes[column],previous.notes[column],note_fields) then
        changed_notes=changed_notes or {}
        changed_notes[#changed_notes+1]=column
      end
    end
    for column=1,limits.max_effect_columns do
      if not same_cell(snapshot.lines[index].effects[column],previous.effects[column],effect_fields) then
        changed_effects=changed_effects or {}
        changed_effects[#changed_effects+1]=column
      end
    end
    if changed_notes or changed_effects then
      local line=phrase:line(index)
      for _,column in ipairs(changed_notes or {}) do
        set_cell(line,column,snapshot.lines[index].notes[column],previous,true)
      end
      for _,column in ipairs(changed_effects or {}) do
        set_cell(line,column,snapshot.lines[index].effects[column],previous,false)
      end
    end
  end
  phrase.number_of_lines=p.number_of_lines
  phrase.loop_end=p.loop_end
  phrase.loop_start=p.loop_start
  phrase.looping=p.looping
end

function M.restore(phrase,detached_snapshot,limits)
  local valid,error_message=valid_limits(limits)
  if not valid then return nil,error_message end
  valid,error_message=valid_snapshot(detached_snapshot,limits)
  if not valid then return nil,error_message end
  local current,inspection_error=snapshots(phrase,limits)
  if not current then return nil,"Cannot inspect phrase before restore: "..tostring(inspection_error) end
  local ok,write_error=pcall(write_snapshot,phrase,detached_snapshot,limits,current)
  if not ok then
    local partial=snapshots(phrase,limits)
    return nil,"Phrase restore failed: "..tostring(write_error),partial
  end
  local restored,actual=snapshots(phrase,limits)
  if not restored then return nil,actual end
  local same,reason=ownership.compare(detached_snapshot,restored)
  if not same then return nil,"Phrase restore did not reproduce the preimage: "..tostring(reason),restored end
  return true,restored
end

return M
