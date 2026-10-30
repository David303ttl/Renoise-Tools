-- SPDX-License-Identifier: GPL-3.0-only
-- Content seal for current ACID generated phrases; this is not a security token.
local M={}
local PREFIX="ACID 0.1 #"
local HASH_INITIAL = 5381
local HASH_MULTIPLIER = 33
local HASH_MODULUS = 2147483647
local HASH_FIELD_SEPARATOR = 124
local MAX_PHRASE_ID = 2147483647
-- API 6.2 values used only when no host phrase API is available, such as
-- detached snapshot checks. A live host always supplies the actual caps.
local PINNED_MAX_LINES = 512
local PINNED_NOTE_COLUMNS = 12
local PINNED_EFFECT_COLUMNS = 8
local indexed_snapshots=setmetatable({},{__mode="k"})
local function hash(phrase)
  local acc=HASH_INITIAL
  local function feed(value)
    local text=tostring(value==nil and "_" or value)
    for i=1,#text do acc=(acc*HASH_MULTIPLIER+text:byte(i))%HASH_MODULUS end
    acc=(acc*HASH_MULTIPLIER+HASH_FIELD_SEPARATOR)%HASH_MODULUS
  end
  feed(phrase.number_of_lines)
  feed(phrase.lpb)
  feed(phrase.looping)
  feed(phrase.loop_start)
  feed(phrase.loop_end)
  feed(phrase.playback_mode)
  feed(phrase.key_tracking)
  feed(phrase.base_note)
  feed(phrase.shuffle)
  feed(phrase.autoseek)
  local notes,effects=phrase.visible_note_columns or 1,phrase.visible_effect_columns or 0
  feed(notes);feed(effects)
  feed(phrase.instrument_column_visible)
  feed(phrase.volume_column_visible)
  feed(phrase.panning_column_visible)
  feed(phrase.delay_column_visible)
  feed(phrase.sample_effects_column_visible)
  for column=1,12 do feed(phrase:column_is_muted(column)) end
  for line_index=1,phrase.number_of_lines do
    local line=phrase:line(line_index)
    if not line then return nil,"missing phrase line "..line_index end
    for column=1,notes do
      local note=line.note_columns and line.note_columns[column]
      if not note then return nil,"missing note column at "..line_index end
      feed(note.note_value);feed(note.instrument_value);feed(note.volume_value)
      feed(note.panning_value);feed(note.delay_value)
      feed(note.effect_number_value);feed(note.effect_amount_value)
    end
    for column=1,effects do
      local effect=line.effect_columns and line.effect_columns[column]
      if not effect then return nil,"missing effect column at "..line_index end
      feed(effect.number_value);feed(effect.amount_value)
    end
  end
  return string.format("%08X",acc)
end

local function parse_name(name)
  if type(name)~="string" then return nil end
  local id,seal=name:match("^ACID 0%.1 #(%d+) %[v3:(%x%x%x%x%x%x%x%x)%]$")
  if not id then return nil end
  local numeric=tonumber(id)
  if not numeric or numeric<1 or numeric>MAX_PHRASE_ID then return nil end
  return numeric,seal
end

function M.id(phrase)
  local id=parse_name(phrase.name or "")
  return id
end

function M.make_name(phrase,id)
  if type(id)~="number" or id%1~=0 or id<1 or id>MAX_PHRASE_ID then
    return nil,"invalid ACID phrase ID"
  end
  local seal,err=hash(phrase)
  if not seal then return nil,err end
  return string.format("%s%d [v3:%s]",PREFIX,id,seal)
end

function M.status(phrase)
  local id,seal=parse_name(phrase.name or "")
  if not id then return "foreign" end
  local actual,err=hash(phrase)
  if not actual then return "modified",err end
  if seal~=actual then return "modified","ACID phrase was edited after generation" end
  return "owned"
end

function M.is_current(song)
  if song==nil then return nil,"An ACID song is required" end
  local host=rawget(_G,"renoise")
  if host then
    local ok,available,current=pcall(function()
      if type(host.song)=="function" then return true,host.song() end
      return false
    end)
    if not ok or (available and not rawequal(song,current)) then
      return nil,"ACID target song is no longer current"
    end
  end
  return true
end

function M.membership(song,instrument,phrase)
  local current,current_error=M.is_current(song)
  if not current then return nil,current_error end
  local ok,instrument_index,phrase_index=pcall(function()
    if song==nil or instrument==nil then return nil end
    for index,candidate in ipairs(song.instruments) do
      if rawequal(candidate,instrument) then
        if phrase==nil then return index end
        for position,existing in ipairs(candidate.phrases) do
          if rawequal(existing,phrase) then return index,position end
        end
        return nil
      end
    end
  end)
  if not ok then return nil,"Cannot inspect ACID target membership" end
  if not instrument_index then return nil,"ACID target is no longer in this song and instrument" end
  return instrument_index,phrase_index
end

function M.inventory(song,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  local current,current_error=M.is_current(song)
  if not current then return nil,current_error end
  local ok,result=pcall(function()
    local groups={}
    for instrument_index,instrument in ipairs(song.instruments) do
      for phrase_index,phrase in ipairs(instrument.phrases) do
        local id=M.id(phrase)
        if id then
          local group=groups[id] or {}
          groups[id]=group
          group[#group+1]={instrument=instrument,phrase=phrase,
            instrument_index=instrument_index,phrase_index=phrase_index}
        end
      end
    end
    return groups
  end)
  if not ok then return nil,"Cannot inspect ACID phrase identities" end
  return result
end

function M.validate_identity(song,instrument,phrase,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  if phrase==nil then return nil,"An existing ACID phrase is required" end
  local instrument_index,phrase_index=M.membership(song,instrument,phrase)
  if not instrument_index then return nil,phrase_index end
  local groups,err=M.inventory(song)
  if not groups then return nil,err end
  local inspected,id=pcall(M.id,phrase)
  if not inspected then return nil,"Cannot inspect ACID phrase identity" end
  local holders=id and groups[id]
  if not holders or #holders~=1 or not rawequal(holders[1].phrase,phrase) then
    return nil,"Duplicate or missing ACID phrase ID; cannot choose safely"
  end
  return id,instrument_index,phrase_index
end

function M.validate_live(song,instrument,phrase,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  local id,instrument_index,phrase_index=M.validate_identity(song,instrument,phrase)
  if not id then return nil,instrument_index end
  local ok,status=pcall(M.status,phrase)
  if not ok or status~="owned" then return nil,"Phrase is not an unchanged ACID-owned phrase" end
  return id,instrument_index,phrase_index
end

local numeric_properties={"number_of_lines","lpb","shuffle","loop_start","loop_end",
  "playback_mode","key_tracking","base_note","visible_note_columns","visible_effect_columns"}
local boolean_properties={"looping","autoseek","instrument_column_visible",
  "volume_column_visible","panning_column_visible","delay_column_visible","sample_effects_column_visible"}
local note_fields={"note_value","instrument_value","volume_value","panning_value",
  "delay_value","effect_number_value","effect_amount_value"}
local effect_fields={"number_value","amount_value"}
local generated_properties={number_of_lines=true,lpb=true,shuffle=true,looping=true,
  loop_start=true,loop_end=true,playback_mode=true,key_tracking=true}

local function value(object,key,expected)
  local result=object[key]
  if type(result)~=expected or (expected=="number" and
      (result~=result or result==math.huge or result==-math.huge)) then
    error("unreadable "..key,0)
  end
  return result
end

local function fields(object,names,kind)
  local result={}
  for _,key in ipairs(names) do result[key]=value(object,key,kind) end
  return result
end

local function empty_column_defaults()
  local ok, defaults=pcall(function()
    local api=rawget(_G,"renoise")
    local line=api and api.PatternLine
    if not line then return nil end
    return {
      note={note_value=line.EMPTY_NOTE,instrument_value=line.EMPTY_INSTRUMENT,
        volume_value=line.EMPTY_VOLUME,panning_value=line.EMPTY_PANNING,
        delay_value=line.EMPTY_DELAY,effect_number_value=line.EMPTY_EFFECT_NUMBER,
        effect_amount_value=line.EMPTY_EFFECT_AMOUNT,is_empty=true},
      effect={number_value=line.EMPTY_EFFECT_NUMBER,amount_value=line.EMPTY_EFFECT_AMOUNT,
        is_empty=true},
    }
  end)
  if not ok or type(defaults)~="table" then return nil end
  for _,key in ipairs(note_fields) do
    if type(defaults.note[key])~="number" then return nil end
  end
  for _,key in ipairs(effect_fields) do
    if type(defaults.effect[key])~="number" then return nil end
  end
  return defaults
end

local function positive_integer(input)
  return type(input)=="number" and input%1==0 and input>0
end

local function nonnegative_integer(input)
  return type(input)=="number" and input%1==0 and input>=0
end

local function valid_capacities(max_lines,note_columns,effect_columns)
  return positive_integer(max_lines) and positive_integer(note_columns) and
    nonnegative_integer(effect_columns)
end

-- Callers with a validated workspace pass its capacities so bounded mocks do
-- not inspect native maximums. Without a host, detached checks use the pinned
-- API 6.2 phrase bounds.
local function snapshot_capacities(limits)
  if limits~=nil then
    if type(limits)~="table" or getmetatable(limits)~=nil then
      return nil,"Invalid phrase snapshot capacities"
    end
    local max_lines=rawget(limits,"max_lines")
    local note_columns=rawget(limits,"max_note_columns")
    local effect_columns=rawget(limits,"max_effect_columns")
    if not valid_capacities(max_lines,note_columns,effect_columns) then
      return nil,"Invalid phrase snapshot capacities"
    end
    return {max_lines=max_lines,note_columns=note_columns,effect_columns=effect_columns}
  end
  local api_ok,api=pcall(function()
    local host=rawget(_G,"renoise")
    return host and host.InstrumentPhrase
  end)
  if not api_ok or api==nil then
    return {max_lines=PINNED_MAX_LINES,note_columns=PINNED_NOTE_COLUMNS,
      effect_columns=PINNED_EFFECT_COLUMNS}
  end
  local function read(key)
    local ok,value=pcall(function()return api[key]end)
    if not ok then return nil,false end
    return value,true
  end
  local max_lines,lines_ok=read("MAX_NUMBER_OF_LINES")
  local note_columns,notes_ok=read("MAX_NUMBER_OF_NOTE_COLUMNS")
  local effect_columns,effects_ok=read("MAX_NUMBER_OF_EFFECT_COLUMNS")
  if not lines_ok or not notes_ok or not effects_ok then
    return nil,"Cannot inspect native phrase snapshot capacities"
  end
  if max_lines==nil then max_lines=PINNED_MAX_LINES end
  if note_columns==nil then note_columns=PINNED_NOTE_COLUMNS end
  if effect_columns==nil then effect_columns=PINNED_EFFECT_COLUMNS end
  if not valid_capacities(max_lines,note_columns,effect_columns) then
    return nil,"Native phrase snapshot capacities are invalid"
  end
  return {max_lines=max_lines,note_columns=note_columns,effect_columns=effect_columns}
end

local function capture(phrase,capacities)
  local result={name=value(phrase,"name","string"),properties={},columns={},lines={}}
  local empty_defaults=empty_column_defaults()
  for _,key in ipairs(numeric_properties) do result.properties[key]=value(phrase,key,"number") end
  for _,key in ipairs(boolean_properties) do result.properties[key]=value(phrase,key,"boolean") end
  if result.properties.number_of_lines>capacities.max_lines then
    error("phrase length exceeds snapshot capacity",0)
  end
  for column=1,capacities.note_columns do
    local name,muted=phrase:column_name(column),phrase:column_is_muted(column)
    if type(name)~="string" or type(muted)~="boolean" then error("unreadable column metadata",0) end
    result.columns[column]={name=name,muted=muted}
  end
  local mapping=phrase.mapping
  result.mapping={present=mapping~=nil}
  if mapping~=nil then
    for _,key in ipairs({"key_tracking","base_note","loop_start","loop_end"}) do
      result.mapping[key]=value(mapping,key,"number")
    end
    result.mapping.looping=value(mapping,"looping","boolean")
    local range=mapping.note_range
    result.mapping.note_range={value(range,1,"number"),value(range,2,"number")}
  end
  local script=phrase.script
  result.script={paragraphs={},parameters={},pending_changes=value(script,"pending_changes","number"),
    editor_visible=value(script,"editor_visible","boolean")}
  local paragraphs=script.paragraphs
  for index=1,#paragraphs do result.script.paragraphs[index]=value(paragraphs,index,"string") end
  local parameters=script.parameters
  for index=1,#parameters do
    local parameter=parameters[index]
    result.script.parameters[index]={name=value(parameter,"name","string"),value=value(parameter,"value","number")}
  end
  for line_index=1,capacities.max_lines do
    local line=phrase:line(line_index)
    local captured={notes={},effects={}}
    local empty_ok,is_empty=pcall(function()return line.is_empty end)
    local defaults=empty_defaults
    if empty_ok and is_empty==true and defaults then
      for column=1,capacities.note_columns do
        captured.notes[column]={}
        for _,key in ipairs(note_fields) do captured.notes[column][key]=defaults.note[key] end
        captured.notes[column].is_empty=true
      end
      for column=1,capacities.effect_columns do
        captured.effects[column]={}
        for _,key in ipairs(effect_fields) do captured.effects[column][key]=defaults.effect[key] end
        captured.effects[column].is_empty=true
      end
    else
      for column=1,capacities.note_columns do
        local cell=line:note_column(column)
        local empty_ok,cell_empty=pcall(function()return cell.is_empty end)
        if empty_ok and cell_empty==true and defaults then
          captured.notes[column]={}
          for _,key in ipairs(note_fields) do captured.notes[column][key]=defaults.note[key] end
          captured.notes[column].is_empty=true
        else
          captured.notes[column]=fields(cell,note_fields,"number")
          captured.notes[column].is_empty=value(cell,"is_empty","boolean")
        end
      end
      for column=1,capacities.effect_columns do
        local cell=line:effect_column(column)
        local empty_ok,cell_empty=pcall(function()return cell.is_empty end)
        if empty_ok and cell_empty==true and defaults then
          captured.effects[column]={}
          for _,key in ipairs(effect_fields) do captured.effects[column][key]=defaults.effect[key] end
          captured.effects[column].is_empty=true
        else
          captured.effects[column]=fields(cell,effect_fields,"number")
          captured.effects[column].is_empty=value(cell,"is_empty","boolean")
        end
      end
    end
    result.lines[line_index]=captured
  end
  return result
end

-- Snapshots contain detached values, including hidden columns and inactive lines.
-- Optional limits are a validated workspace {max_lines,max_note_columns,
-- max_effect_columns}; omitted limits use the live host phrase API when present.
function M.snapshot(phrase,limits)
  local capacities,capacity_error=snapshot_capacities(limits)
  if not capacities then return nil,capacity_error end
  local ok,result=pcall(capture,phrase,capacities)
  if not ok then return nil,"Cannot inspect complete phrase: "..tostring(result) end
  return result
end

local function cell_is_default(snapshot,defaults,fields)
  if type(snapshot)~="table" or type(defaults)~="table" or getmetatable(snapshot)~=nil then return false end
  for _,key in ipairs(fields) do
    if rawget(snapshot,key)~=defaults[key] then return false end
  end
  return rawget(snapshot,"is_empty")==true
end

-- Cache which cells in a trusted snapshot are canonical empty cells. Native
-- matching can then use Renoise's read-only emptiness flags to avoid reading
-- each field in those cells on every fresh proof.
function M.snapshot_index(snapshot,limits)
  local capacities,capacity_error=snapshot_capacities(limits)
  if not capacities then return nil,capacity_error end
  if type(snapshot)~="table" or type(snapshot.lines)~="table" or
      #snapshot.lines~=capacities.max_lines then
    return nil,"Invalid phrase snapshot for native matching"
  end
  local defaults=empty_column_defaults()
  local index={}
  local masks={max_lines=capacities.max_lines,note_columns=capacities.note_columns,
    effect_columns=capacities.effect_columns,empty_lines={},expected_empty_lines={},
    empty_notes={},empty_effects={}}
  for line_index=1,capacities.max_lines do
    local line=snapshot.lines[line_index]
    if type(line)~="table" or type(line.notes)~="table" or type(line.effects)~="table" or
        #line.notes~=capacities.note_columns or #line.effects~=capacities.effect_columns then
      return nil,"Invalid phrase snapshot line for native matching"
    end
    local empty=defaults~=nil
    local expected_empty=true
    masks.empty_notes[line_index]={}
    masks.empty_effects[line_index]={}
    for column=1,capacities.note_columns do
      local is_empty=defaults~=nil and cell_is_default(line.notes[column],defaults.note,note_fields)
      masks.empty_notes[line_index][column]=is_empty
      empty=empty and is_empty
      expected_empty=expected_empty and type(line.notes[column])=="table" and
        rawget(line.notes[column],"is_empty")==true
    end
    for column=1,capacities.effect_columns do
      local is_empty=defaults~=nil and cell_is_default(line.effects[column],defaults.effect,effect_fields)
      masks.empty_effects[line_index][column]=is_empty
      empty=empty and is_empty
      expected_empty=expected_empty and type(line.effects[column])=="table" and
        rawget(line.effects[column],"is_empty")==true
    end
    masks.empty_lines[line_index]=empty
    masks.expected_empty_lines[line_index]=expected_empty
  end
  indexed_snapshots[index]={snapshot=snapshot,masks=masks}
  return index
end

local function matches_field(object,key,expected,kind)
  if type(expected)~=kind or (kind=="number" and
      (expected~=expected or expected==math.huge or expected==-math.huge)) then
    return false
  end
  return value(object,key,kind)==expected
end

local function matches_cell(cell,expected,fields,known_empty)
  if type(expected)~="table" or getmetatable(expected)~=nil then return false end
  local empty_ok,is_empty=pcall(function() return cell.is_empty end)
  if known_empty and empty_ok and type(is_empty)=="boolean" then return is_empty end
  if empty_ok and type(is_empty)=="boolean" and is_empty~=expected.is_empty then return false end
  if type(expected.is_empty)~="boolean" then return false end
  for _,key in ipairs(fields) do
    if not matches_field(cell,key,rawget(expected,key),"number") then return false end
  end
  if not empty_ok or type(is_empty)~="boolean" then
    return value(cell,"is_empty","boolean")==expected.is_empty
  end
  return true
end

local function matches_snapshot(phrase,snapshot,capacities,index)
  local retained=indexed_snapshots[index]
  if type(snapshot)~="table" or getmetatable(snapshot)~=nil or
      type(index)~="table" or not retained or not rawequal(retained.snapshot,snapshot) then
    return false,"Missing trusted phrase snapshot index"
  end
  local masks=retained.masks
  if capacities.max_lines~=masks.max_lines or capacities.note_columns~=masks.note_columns or
      capacities.effect_columns~=masks.effect_columns then
    return false,"Native phrase snapshot capacities changed"
  end
  if type(snapshot.properties)~="table" or type(snapshot.columns)~="table" or
      type(snapshot.mapping)~="table" or type(snapshot.script)~="table" or
      type(snapshot.lines)~="table" or #snapshot.lines~=capacities.max_lines then
    return false,"Invalid phrase snapshot shape"
  end
  if not matches_field(phrase,"name",snapshot.name,"string") then return false,"Phrase name changed" end
  for _,key in ipairs(numeric_properties) do
    if not matches_field(phrase,key,snapshot.properties[key],"number") then return false,"Phrase property changed: "..key end
  end
  for _,key in ipairs(boolean_properties) do
    if not matches_field(phrase,key,snapshot.properties[key],"boolean") then return false,"Phrase property changed: "..key end
  end
  if capacities.max_lines~=snapshot.properties.number_of_lines then
    if type(snapshot.properties.number_of_lines)~="number" or
        snapshot.properties.number_of_lines>capacities.max_lines then
      return false,"Phrase line capacity changed"
    end
  end
  for column=1,capacities.note_columns do
    local expected=snapshot.columns[column]
    local ok,name,muted=pcall(function() return phrase:column_name(column),phrase:column_is_muted(column) end)
    if not ok or type(expected)~="table" or getmetatable(expected)~=nil or
        type(expected.name)~="string" or type(expected.muted)~="boolean" or
        name~=expected.name or muted~=expected.muted then
      return false,"Phrase column metadata changed"
    end
  end
  local mapping=phrase.mapping
  if type(snapshot.mapping.present)~="boolean" or snapshot.mapping.present~=(mapping~=nil) then
    return false,"Phrase mapping changed"
  end
  if mapping then
    for _,key in ipairs({"key_tracking","base_note","loop_start","loop_end"}) do
      if not matches_field(mapping,key,snapshot.mapping[key],"number") then return false,"Phrase mapping changed" end
    end
    if not matches_field(mapping,"looping",snapshot.mapping.looping,"boolean") then return false,"Phrase mapping changed" end
    local range=snapshot.mapping.note_range
    if type(range)~="table" or not matches_field(mapping.note_range,1,range[1],"number") or
        not matches_field(mapping.note_range,2,range[2],"number") then return false,"Phrase mapping changed" end
  end
  local script=phrase.script
  local saved_script=snapshot.script
  if not matches_field(script,"pending_changes",saved_script.pending_changes,"number") or
      not matches_field(script,"editor_visible",saved_script.editor_visible,"boolean") then
    return false,"Phrase script state changed"
  end
  local paragraphs=script.paragraphs
  local paragraphs_ok,paragraph_count=pcall(function()return #paragraphs end)
  if not paragraphs_ok or paragraph_count~=#saved_script.paragraphs then return false,"Phrase script changed" end
  for position=1,#paragraphs do
    if type(saved_script.paragraphs[position])~="string" or paragraphs[position]~=saved_script.paragraphs[position] then
      return false,"Phrase script changed"
    end
  end
  local parameters=script.parameters
  local parameters_ok,parameter_count=pcall(function()return #parameters end)
  if not parameters_ok or parameter_count~=#saved_script.parameters then return false,"Phrase script parameters changed" end
  for position=1,#parameters do
    local saved=saved_script.parameters[position]
    local parameter=parameters[position]
    if type(saved)~="table" or not matches_field(parameter,"name",saved.name,"string") or
        not matches_field(parameter,"value",saved.value,"number") then return false,"Phrase script parameters changed" end
  end

  for line_index=1,capacities.max_lines do
    local line=phrase:line(line_index)
    local saved=snapshot.lines[line_index]
    local line_empty_ok,line_empty=pcall(function() return line.is_empty end)
    if masks.expected_empty_lines[line_index] and line_empty_ok and
        type(line_empty)=="boolean" and not line_empty then
      return false,"Phrase line changed"
    elseif not masks.expected_empty_lines[line_index] and line_empty_ok and
        type(line_empty)=="boolean" and line_empty then
      return false,"Phrase line changed"
    else
      if not (masks.empty_lines[line_index] and line_empty_ok and line_empty==true) then
        for column=1,capacities.note_columns do
          if not matches_cell(line:note_column(column),saved.notes[column],note_fields,
              masks.empty_notes[line_index][column]) then return false,"Phrase note cell changed" end
        end
        for column=1,capacities.effect_columns do
          if not matches_cell(line:effect_column(column),saved.effects[column],effect_fields,
              masks.empty_effects[line_index][column]) then return false,"Phrase effect cell changed" end
        end
      end
    end
  end
  return true
end

function M.matches_snapshot(phrase,snapshot,limits,index)
  local capacities,capacity_error=snapshot_capacities(limits)
  if not capacities then return nil,capacity_error end
  local ok,matches,reason=pcall(matches_snapshot,phrase,snapshot,capacities,index)
  if not ok then return nil,"Cannot compare native phrase to its verified snapshot" end
  return matches,reason
end

local function copy_value(input,active)
  local kind=type(input)
  if kind=="string" or kind=="boolean" then return input end
  if kind=="number" and input==input and input~=math.huge and input~=-math.huge then return input end
  if kind~="table" or getmetatable(input)~=nil or active[input] then error("Snapshot contains a non-value",0) end
  active[input]=true
  local result={}
  for key,item in pairs(input) do
    if type(key)~="string" and type(key)~="number" then error("Snapshot contains an invalid key",0) end
    result[key]=copy_value(item,active)
  end
  active[input]=nil
  return result
end

function M.copy_snapshot(snapshot)
  if type(snapshot)~="table" then return nil,"Missing phrase snapshot" end
  local ok,result=pcall(copy_value,snapshot,{})
  if not ok then return nil,"Cannot copy phrase snapshot: "..tostring(result) end
  return result
end

local function ordered_keys(value)
  local result={}
  for key in pairs(value) do result[#result+1]=key end
  table.sort(result,function(a,b)
    if type(a)==type(b) then return a<b end
    return type(a)<type(b)
  end)
  return result
end

local function valid_snapshot_tree(value,active)
  local kind=type(value)
  if kind=="nil" or kind=="string" or kind=="boolean" then return true end
  if kind=="number" then
    return value==value and value~=math.huge and value~=-math.huge
  end
  if kind~="table" or getmetatable(value)~=nil or active[value] then return false end
  active[value]=true
  for key,item in pairs(value) do
    local key_type=type(key)
    if (key_type~="string" and key_type~="number") or
        (key_type=="number" and (key~=key or key==math.huge or key==-math.huge)) or
        not valid_snapshot_tree(item,active) then
      active[value]=nil
      return false
    end
  end
  active[value]=nil
  return true
end

local note_snapshot_fields={"note_value","instrument_value","volume_value","panning_value",
  "delay_value","effect_number_value","effect_amount_value","is_empty"}
local effect_snapshot_fields={"number_value","amount_value","is_empty"}

local function cell_snapshot_kind(value,fields)
  if getmetatable(value)~=nil then return false end
  local count=0
  for key in pairs(value) do
    count=count+1
    if count>#fields then return false end
  end
  if count~=#fields then return false end
  for _,field in ipairs(fields) do
    local item=rawget(value,field)
    if field=="is_empty" then
      if type(item)~="boolean" then return false end
    elseif type(item)=="number" then
      if item~=item or item==math.huge or item==-math.huge then return nil end
    else
      return false
    end
  end
  return true
end

local function same_cell_snapshot(left,right,fields)
  local left_kind=cell_snapshot_kind(left,fields)
  local right_kind=cell_snapshot_kind(right,fields)
  if left_kind==nil or right_kind==nil then return nil end
  if left_kind~=true or right_kind~=true then
    if valid_snapshot_tree(left,{}) and valid_snapshot_tree(right,{}) then return false end
    return nil
  end
  for _,field in ipairs(fields) do
    if rawget(left,field)~=rawget(right,field) then return false end
  end
  return true
end

local function fast_exact_equal(left,right,active_left,active_right)
  local left_type,right_type=type(left),type(right)
  if left_type~=right_type then
    if valid_snapshot_tree(left,{}) and valid_snapshot_tree(right,{}) then return false end
    return nil
  end
  if left_type=="nil" or left_type=="string" or left_type=="boolean" then
    return left==right
  end
  if left_type=="number" then
    if left~=left or right~=right or left==math.huge or left==-math.huge or
        right==math.huge or right==-math.huge then return nil end
    return left==right
  end
  if left_type~="table" or getmetatable(left)~=nil or getmetatable(right)~=nil then
    return nil
  end
  if rawget(left,"note_value")~=nil or rawget(right,"note_value")~=nil then
    return same_cell_snapshot(left,right,note_snapshot_fields)
  end
  if rawget(left,"number_value")~=nil or rawget(right,"number_value")~=nil then
    return same_cell_snapshot(left,right,effect_snapshot_fields)
  end
  if active_left[left] or active_right[right] then return nil end
  active_left[left],active_right[right]=true,true
  local equal=true
  for key,left_value in pairs(left) do
    local key_type=type(key)
    if key_type~="string" and key_type~="number" then
      active_left[left],active_right[right]=nil,nil
      return nil
    end
    if key_type=="number" and
        (key~=key or key==math.huge or key==-math.huge) then
      active_left[left],active_right[right]=nil,nil
      return nil
    end
    local right_value=right[key]
    if right_value==nil then
      if not valid_snapshot_tree(left_value,{}) then
        active_left[left],active_right[right]=nil,nil
        return nil
      end
      equal=false
    else
      local same=fast_exact_equal(left_value,right_value,active_left,active_right)
      if same==nil then
        active_left[left],active_right[right]=nil,nil
        return nil
      elseif same==false then
        equal=false
      end
    end
  end
  for key in pairs(right) do
    if left[key]==nil then
      if not valid_snapshot_tree(right[key],{}) then
        active_left[left],active_right[right]=nil,nil
        return nil
      end
      equal=false
    end
  end
  active_left[left],active_right[right]=nil,nil
  return equal
end

local function difference(left,right,path,allowed)
  if allowed(path) then return nil end
  if type(left)~=type(right) then return path end
  if type(left)~="table" then
    local kind=type(left)
    if kind~="nil" and kind~="string" and kind~="number" and kind~="boolean" then return path end
    if left~=right then return path end
    return nil
  end
  if getmetatable(left)~=nil or getmetatable(right)~=nil then return path end
  for _,key in ipairs(ordered_keys(left)) do
    local found=difference(left[key],right[key],path=="" and tostring(key) or path.."."..tostring(key),allowed)
    if found then return found end
  end
  for _,key in ipairs(ordered_keys(right)) do
    if left[key]==nil then
      local extra=path=="" and tostring(key) or path.."."..tostring(key)
      if not allowed(extra) then return extra end
    end
  end
end

-- Policies permit only the fields owned by the requested operation.
-- The generated policy checks preserved metadata only. Publication also requires
-- complete output validation, including unused, hidden and inactive cells.
function M.compare(left,right,policy)
  policy=policy or "exact"
  if policy~="exact" and policy~="name" and policy~="generated" then return false,"Unknown phrase comparison policy" end
  if type(left)~="table" or type(right)~="table" then return false,"Missing phrase snapshot" end
  if policy=="exact" then
    local equal=fast_exact_equal(left,right,{},{})
    if equal==true then return true end
    if equal==nil then return false,"Invalid phrase snapshot value" end
  end
  local function allowed(path)
    if policy=="exact" then return false end
    if path=="name" then return true end
    if policy=="generated" then
      if path=="lines" then return true end
      local property=path:match("^properties%.([^%.]+)$")
      return property and generated_properties[property] or false
    end
    return false
  end
  local changed=difference(left,right,"",allowed)
  if changed then return false,"Phrase differs at "..changed end
  return true
end

-- Native destination-to-backup copies omit phrase mappings. Verify everything
-- else exactly, require the backup mapping to be absent, and compare the
-- destination's own mapping separately after replacement.
function M.compare_backup(destination, backup)
  if type(destination) ~= "table" or type(backup) ~= "table" then
    return false, "Missing phrase snapshot"
  end
  if type(backup.mapping) ~= "table" or backup.mapping.present ~= false then
    return false, "Backup unexpectedly contains a phrase mapping"
  end
  local function allowed(path)
    if path == "name" then return true end
    if path == "mapping" or path:match("^mapping%.") then return true end
    return false
  end
  local changed = difference(destination, backup, "", allowed)
  if changed then return false, "Phrase differs at " .. changed end
  return true
end

function M.empty_script(snapshot)
  local script=type(snapshot)=="table" and snapshot.script
  if type(script)~="table" or type(script.paragraphs)~="table" or type(script.parameters)~="table"
      or next(script.paragraphs)~=nil or next(script.parameters)~=nil
      or script.pending_changes~=0 or script.editor_visible~=true then
    return false,"Phrase has unsupported script state"
  end
  return true
end

return M
