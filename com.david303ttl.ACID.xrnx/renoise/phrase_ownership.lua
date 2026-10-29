-- SPDX-License-Identifier: GPL-3.0-only
-- Content seal for current ACID generated phrases; this is not a security token.
local M={}
local PREFIX="ACID 0.1 #"
local HASH_INITIAL = 5381
local HASH_MULTIPLIER = 33
local HASH_MODULUS = 2147483647
local HASH_FIELD_SEPARATOR = 124
local MAX_PHRASE_ID = 2147483647
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

function M.inventory(song,excluded)
  local current,current_error=M.is_current(song)
  if not current then return nil,current_error end
  local ok,result=pcall(function()
    local groups={}
    for instrument_index,instrument in ipairs(song.instruments) do
      for phrase_index,phrase in ipairs(instrument.phrases) do
        if not excluded or not excluded[phrase] then
          local id=M.id(phrase)
          if id then
            local group=groups[id] or {}
            groups[id]=group
            group[#group+1]={instrument=instrument,phrase=phrase,
              instrument_index=instrument_index,phrase_index=phrase_index}
          end
        end
      end
    end
    return groups
  end)
  if not ok then return nil,"Cannot inspect ACID phrase identities" end
  return result
end

function M.validate_identity(song,instrument,phrase,excluded)
  if phrase==nil then return nil,"An existing ACID phrase is required" end
  local instrument_index,phrase_index=M.membership(song,instrument,phrase)
  if not instrument_index then return nil,phrase_index end
  local groups,err=M.inventory(song,excluded)
  if not groups then return nil,err end
  local inspected,id=pcall(M.id,phrase)
  if not inspected then return nil,"Cannot inspect ACID phrase identity" end
  local holders=id and groups[id]
  if not holders or #holders~=1 or not rawequal(holders[1].phrase,phrase) then
    return nil,"Duplicate or missing ACID phrase ID; cannot choose safely"
  end
  return id,instrument_index,phrase_index
end

function M.validate_live(song,instrument,phrase,excluded)
  local id,instrument_index,phrase_index=M.validate_identity(song,instrument,phrase,excluded)
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

local function capture(phrase)
  local result={name=value(phrase,"name","string"),properties={},columns={},lines={}}
  for _,key in ipairs(numeric_properties) do result.properties[key]=value(phrase,key,"number") end
  for _,key in ipairs(boolean_properties) do result.properties[key]=value(phrase,key,"boolean") end
  for column=1,12 do
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
  for line_index=1,512 do
    local line=phrase:line(line_index)
    local captured={notes={},effects={}}
    for column=1,12 do
      local cell=line:note_column(column)
      captured.notes[column]=fields(cell,note_fields,"number")
      captured.notes[column].is_empty=value(cell,"is_empty","boolean")
    end
    for column=1,8 do
      local cell=line:effect_column(column)
      captured.effects[column]=fields(cell,effect_fields,"number")
      captured.effects[column].is_empty=value(cell,"is_empty","boolean")
    end
    result.lines[line_index]=captured
  end
  return result
end

-- Snapshots contain detached values, including hidden columns and inactive lines.
function M.snapshot(phrase)
  local ok,result=pcall(capture,phrase)
  if not ok then return nil,"Cannot inspect complete phrase: "..tostring(result) end
  return result
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
