-- SPDX-License-Identifier: GPL-3.0-only
-- Exact, song-local storage for canonical ACID sources and phrase render settings.
local policies=require("model.policies")
local sequencer = require("model.sequencer")
local interpreter = require("model.cycle_interpreter")
local ownership = require("renoise.phrase_ownership")
local M = {}
local MAGIC = "ACID-PITCH-TIME-2"
local MAX_ID = 2147483647
local candidates=setmetatable({}, {__mode="k"})
local function synchronous_guard()return true end

local function valid_id(id)
  return policies.in_integer_range(id,1,MAX_ID)
end

local function raw_data(song)
  local ok, value = pcall(function() return song.tool_data end)
  if not ok then return nil, "Cannot access Renoise song.tool_data" end
  if value == nil then return nil end
  if value == "" then return "" end
  if type(value) ~= "string" then return nil, "ACID song data is not text" end
  return value
end

local function encode_pitch(p)
  return string.format("%d:%d:%d:%d%d",p.note,p.key,p.octave,
    p.accent and 1 or 0,p.slide and 1 or 0)
end

local function decode_pitch(token, line)
  local note,key,octave,flags=token:match("^(%d+):(%d+):(-?%d+):([01][01])$")
  if not note then return nil,"Corrupt pitch at line "..line end
  return {note=tonumber(note),key=tonumber(key),octave=tonumber(octave),
    accent=flags:sub(1,1)=="1",slide=flags:sub(2,2)=="1"}
end

local function encode_text(value)
  return (tostring(value or ""):gsub(".",function(c) return string.format("%02X",string.byte(c)) end))
end

local function decode_text(value)
  if #value%2~=0 or value:find("[^0-9A-F]") then return nil end
  return (value:gsub("..",function(pair) return string.char(tonumber(pair,16)) end))
end

local function valid_label(label)
  if type(label)~="string" or #label<1 or #label>32 or
      not label:match("^[A-Za-z0-9][A-Za-z0-9 _%.%-]*$") then return false end
  return true
end
M.valid_label=valid_label

local function canonical_integer(token)
  local value=type(token)=="string" and tonumber(token)
  return value and tostring(value)==token and value or nil
end

local function decode_source(item,is_draft,line_number)
  if not policies.in_integer_range(item.length,1,sequencer.MAX_STEPS) or
      not policies.in_integer_range(item.pitch_length,1,sequencer.MAX_STEPS) or
      (item.timing_mode~="straight" and item.timing_mode~="triplet") or
      #item.mask~=12 or item.mask:find("[^01]") then
    return nil,"Invalid ACID "..(is_draft and "draft source" or "source").." at line "..line_number
  end
  local pattern=sequencer.new_pattern(item.length)
  pattern.pitch_length=item.pitch_length
  pattern.timing_mode=item.timing_mode
  pattern.scale_mask_enabled=item.mask_enabled
  for i=1,12 do pattern.scale_mask[i]=item.mask:sub(i,i)=="1" end
  pattern.pitch_events={}
  local tokens={}
  for token in item.pitch_data:gmatch("[^,]+") do
    tokens[#tokens+1]=token
    local pitch,err=decode_pitch(token,line_number)
    if not pitch then return nil,err end
    pattern.pitch_events[#pattern.pitch_events+1]=pitch
  end
  if table.concat(tokens,",")~=item.pitch_data then
    return nil,(is_draft and "Invalid ACID draft pitch data at line " or "Invalid pitch separators at line ")..line_number
  end
  if #pattern.pitch_events~=sequencer.MAX_STEPS then
    if is_draft then return nil,"Invalid ACID draft pitch data at line "..line_number end
    return nil,string.format("ACID source must store exactly %d pitches at line %d",sequencer.MAX_STEPS,line_number)
  end
  for step=1,sequencer.MAX_STEPS do pattern.time_events[step]=item.time:sub(step,step) end
  local ok,err=interpreter.validate_source(pattern)
  if not ok then return nil,(is_draft and "Invalid ACID draft source: " or "Invalid ACID source: ")..err end
  return pattern
end

local function encode_source(pattern)
  local pitches,time={},{}
  for index=1,sequencer.MAX_STEPS do pitches[index]=encode_pitch(pattern.pitch_events[index]) end
  for step=1,sequencer.MAX_STEPS do time[step]=pattern.time_events[step] or "N" end
  local mask={}
  for i=1,12 do mask[i]=pattern.scale_mask[i] and "1" or "0" end
  return table.concat({pattern.timing_mode,tostring(pattern.pitch_length),tostring(pattern.length),
    pattern.scale_mask_enabled and "1" or "0",table.concat(mask),
    table.concat(pitches,","),table.concat(time)},"|")
end

local function decode(raw)
  if raw=="" then return {},{} end
  if raw:sub(-1)~="\n" then return nil,"ACID song data is incomplete" end
  local lines={}
  for line in raw:gmatch("(.-)\n") do lines[#lines+1]=line end
  if lines[1]~=MAGIC then return nil,"Unrecognized ACID song data; refusing to replace it" end
  local entries,drafts,labels={},{},{}
  local phase=1
  local last_source_id,last_label_id,last_draft_instrument,last_draft_phrase=0,0,0,-1
  for line_number=2,#lines do
    local line=lines[line_number]
    if line=="" then return nil,"Unexpected blank ACID entry at line "..line_number end
    if line:match("^LABEL|") then
      if phase>2 then return nil,"Malformed ACID record order at line "..line_number end
      phase=2
      local id,custom,labelhex=line:match("^LABEL|(%d+)|([01])|([%x]+)$")
      id=canonical_integer(id)
      local label=labelhex and decode_text(labelhex)
      if not valid_id(id) or id<=last_label_id or labels[id] or not label or not valid_label(label) then
        return nil,"Invalid ACID label at line "..line_number
      end
      last_label_id=id
      labels[id]={label=label,label_custom=custom=="1"}
    elseif line:match("^DRAFT|") then
      phase=3
      local instrument,phrase,name,labelhex,custom,source=line:match(
        "^DRAFT|(%d+)|(%d+)|([%x]*)|([%x]+)|([01])|(.+)$")
      instrument,phrase=canonical_integer(instrument),canonical_integer(phrase)
      local label=labelhex and decode_text(labelhex)
      local policy,pb,timing,pitchlen,length,maskon,mask,pitchdata,time
      if source then policy,pb,timing,pitchlen,length,maskon,mask,pitchdata,time=
        source:match("^([%w_]+)|(%d+)|([%w_]+)|(%d+)|(%d+)|([01])|([01]+)|([%d,:%-]+)|([NTR]+)$") end
      pb,pitchlen,length=canonical_integer(pb),canonical_integer(pitchlen),canonical_integer(length)
      local key=instrument and tostring(instrument)..":"..tostring(phrase)
      if not instrument or instrument<1 or not phrase or phrase<0 or
          instrument<last_draft_instrument or (instrument==last_draft_instrument and phrase<=last_draft_phrase) or drafts[key] or
          not label or not valid_label(label) or not policy or type(mask)~="string" or #mask~=12 or
          type(time)~="string" or #time~=32 or
          not policies.valid_output_policy(policy) or not policies.valid_pb_range(pb) then
        return nil,"Invalid ACID draft header at line "..line_number
      end
      last_draft_instrument,last_draft_phrase=instrument,phrase
      local item={length=length,pitch_length=pitchlen,timing_mode=timing,
        mask_enabled=maskon=="1",mask=mask,pitch_data=pitchdata,time=time}
      local pattern,err=decode_source(item,true,line_number)
      if not pattern then return nil,err end
      local decoded_name=decode_text(name)
      if not decoded_name then return nil,"Invalid ACID draft instrument identity at line "..line_number end
      drafts[key]={pattern=pattern,output_policy=policy,pb_range=pb,instrument_name=decoded_name,
        instrument_index=instrument,phrase_id=phrase,label=label,label_custom=custom=="1"}
    else
      if phase>1 then return nil,"Malformed ACID record order at line "..line_number end
      local id,policy,pb,timing,pitchlen,length,maskon,mask,pitchdata,time=line:match(
        "^(%d+)|([%w_]+)|(%d+)|([%w_]+)|(%d+)|(%d+)|([01])|([01]+)|([%d,:%-]+)|([NTR]+)$")
      id,pb,pitchlen,length=canonical_integer(id),canonical_integer(pb),
        canonical_integer(pitchlen),canonical_integer(length)
      if not valid_id(id) or id<=last_source_id or entries[id] or not pb or not pitchlen or not length or
          type(mask)~="string" or #mask~=12 or
          type(time)~="string" or #time~=32 or
        not policies.valid_output_policy(policy) or not policies.valid_pb_range(pb) then
        return nil,"Invalid ACID snapshot header at line "..line_number
      end
      last_source_id=id
      local item={length=length,pitch_length=pitchlen,timing_mode=timing,
        mask_enabled=maskon=="1",mask=mask,pitch_data=pitchdata,time=time}
      local pattern,err=decode_source(item,false,line_number)
      if not pattern then return nil,err end
      entries[id]={pattern=pattern,output_policy=policy,pb_range=pb}
    end
  end
  for id,entry in pairs(entries) do
    local label=labels[id]
    if not label then return nil,"Missing ACID label for source ID "..id end
    entry.label,entry.label_custom=label.label,label.label_custom
  end
  for id in pairs(labels) do if not entries[id] then return nil,"Orphan ACID label ID "..id end end
  return entries,drafts
end

local decoded_raw,decoded_entries,decoded_drafts

local function read_decoded(raw)
  if decoded_entries and decoded_raw==raw then return decoded_entries,decoded_drafts end
  decoded_raw,decoded_entries,decoded_drafts=nil,nil,nil
  local entries,drafts=decode(raw)
  if not entries then return nil,drafts end
  decoded_raw,decoded_entries,decoded_drafts=raw,entries,drafts
  return entries,drafts
end

local function copy_entry(item)
  if not item then return nil end
  local pattern,err=sequencer.copy_source(item.pattern)
  if not pattern then return nil,err end
  return {pattern=pattern,output_policy=item.output_policy,pb_range=item.pb_range,
    label=item.label,label_custom=item.label_custom==true}
end

local function copy_entries(entries)
  local result={}
  for id,item in pairs(entries) do
    local copy,err=copy_entry(item)
    if not copy then return nil,err end
    result[id]=copy
  end
  return result
end

local function copy_map(source)
  local result={}
  for key,value in pairs(source) do result[key]=value end
  return result
end

local function encode_sources(entries)
  local lines={MAGIC}
  local ids={}
  for id in pairs(entries) do
    if not valid_id(id) then return nil,"invalid ACID phrase ID" end
    ids[#ids+1]=id
  end
  table.sort(ids)
  for _,id in ipairs(ids) do
    local item=entries[id]
    local pattern=item.pattern
    local ok,err=interpreter.validate_source(pattern)
    if not ok then return nil,"Invalid ACID source: "..err end
    if not policies.valid_output_policy(item.output_policy) then return nil,"invalid phrase output policy" end
    if not policies.valid_pb_range(item.pb_range) then return nil,"invalid PB range" end
    if not valid_label(item.label) or type(item.label_custom)~="boolean" then
      return nil,"invalid ACID phrase label metadata"
    end
    lines[#lines+1]=table.concat({tostring(id),item.output_policy,tostring(item.pb_range),
      encode_source(pattern)},"|")
  end
  for _,id in ipairs(ids) do
    local item=entries[id]
    lines[#lines+1]=table.concat({"LABEL",tostring(id),item.label_custom and "1" or "0",
      encode_text(item.label)},"|")
  end
  return table.concat(lines,"\n").."\n"
end

local function encode_drafts(drafts)
  local lines={}
  local records={}
  for key,item in pairs(drafts or {}) do
    local instrument,phrase=key:match("^(%d+):(%d+)$")
    instrument,phrase=tonumber(instrument),tonumber(phrase)
    if not instrument or instrument<1 or not phrase or phrase<0 then
      return nil,"invalid ACID draft destination"
    end
    records[#records+1]={key=key,item=item,instrument=instrument,phrase=phrase}
  end
  table.sort(records,function(a,b)
    if a.instrument~=b.instrument then return a.instrument<b.instrument end
    return a.phrase<b.phrase
  end)
  for _,record in ipairs(records) do
    local key,item=record.key,record.item
    local instrument,phrase=key:match("^(%d+):(%d+)$")
    local item=drafts[key]
    if not instrument or tonumber(instrument)<1 or tonumber(phrase)<0 then
      return nil,"invalid ACID draft destination"
    end
    local pattern=item.pattern
    local ok,err=interpreter.validate_source(pattern)
    if not ok then return nil,"Invalid ACID draft source: "..err end
    if not policies.valid_output_policy(item.output_policy) then return nil,"invalid ACID draft output policy" end
    if not policies.valid_pb_range(item.pb_range) then return nil,"invalid ACID draft PB range" end
    if not valid_label(item.label) or type(item.label_custom)~="boolean" then
      return nil,"invalid ACID draft label metadata"
    end
    lines[#lines+1]=table.concat({"DRAFT",instrument,phrase,encode_text(item.instrument_name),
      encode_text(item.label),item.label_custom and "1" or "0",item.output_policy,
      tostring(item.pb_range),encode_source(pattern)},"|")
  end
  return #lines>0 and table.concat(lines,"\n").."\n" or ""
end

local function append_drafts(encoded_sources,drafts)
  local encoded,error_message=encode_drafts(drafts)
  if not encoded then return nil,error_message end
  return encoded_sources..encoded
end

local function encode(entries,drafts)
  local encoded_sources,error_message=encode_sources(entries)
  if not encoded_sources then return nil,error_message end
  return append_drafts(encoded_sources,drafts)
end

function M.read(song)
  local raw,err=raw_data(song)
  if raw==nil and err then return nil,err end
  local entries,decode_error=read_decoded(raw or "")
  if not entries then return nil,decode_error end
  return copy_entries(entries)
end

local function draft_key(instrument_index,phrase_id)
  if not policies.is_integer(instrument_index) or instrument_index<1 or
      not policies.is_integer(phrase_id) or phrase_id<0 then
    return nil,"invalid ACID draft destination"
  end
  return tostring(instrument_index)..":"..tostring(phrase_id)
end

local function draft_target(song,instrument,phrase,entries)
  local index,err=ownership.membership(song,instrument,phrase)
  if not index then return nil,err end
  local ok,name=pcall(function() return instrument.name end)
  if not ok or type(name)~="string" then return nil,"Cannot inspect ACID draft instrument name" end
  if phrase~=nil then
    local id,identity_error=ownership.validate_identity(song,instrument,phrase)
    if not id then return nil,identity_error end
    if not entries[id] then return nil,"ACID source missing from song data" end
    return index,id,name
  end
  local matches=0
  local inspected=pcall(function()
    for _,candidate in ipairs(song.instruments) do
      if candidate.name==name then matches=matches+1 end
    end
  end)
  if not inspected then return nil,"Cannot inspect ACID draft instrument names" end
  if matches~=1 then return nil,"New phrase draft destination is ambiguous" end
  return index,0,name
end

local function saved_phrase_draft(drafts,id)
  local item,key
  for candidate_key,candidate in pairs(drafts) do
    if candidate.phrase_id==id then
      if item then return nil,nil,"Duplicate ACID draft phrase identity" end
      item,key=candidate,candidate_key
    end
  end
  return item,key
end

function M.read_draft(song,instrument,phrase,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  local raw,read_error=raw_data(song)
  if raw==nil and read_error then return nil,read_error end
  local entries,drafts=read_decoded(raw or "")
  if not entries then return nil,drafts end
  local instrument_index,phrase_id,instrument_name=draft_target(song,instrument,phrase,entries)
  if not instrument_index then return nil,phrase_id end
  local key,err=draft_key(instrument_index,phrase_id)
  if not key then return nil,err end
  local item=drafts[key]
  if phrase_id>0 then
    local stored_key,identity_error
    item,stored_key,identity_error=saved_phrase_draft(drafts,phrase_id)
    if identity_error then return nil,identity_error end
  elseif item then
    if item.instrument_name~=instrument_name then item=nil end
  end
  return item and sequencer.copy_source(item.pattern) or nil,item and item.output_policy or nil,
    item and item.pb_range or nil,item and item.label or nil,item and item.label_custom or false
end

local function write_draft(song,instrument,phrase,pattern,output_policy,pb_range,remove,label,label_custom)
  local previous,read_error=raw_data(song)
  if previous==nil and read_error then return nil,read_error end
  local entries,drafts=read_decoded(previous or "")
  if not entries then return nil,drafts end
  entries,drafts=copy_map(entries),copy_map(drafts)
  local instrument_index,phrase_id,instrument_name=draft_target(song,instrument,phrase,entries)
  if not instrument_index then return nil,phrase_id end
  local key,err=draft_key(instrument_index,phrase_id)
  if not key then return nil,err end
  local prior=drafts[key]
  if phrase_id==0 and drafts[key] and drafts[key].instrument_name~=instrument_name then
    return nil,"New phrase draft destination changed; preserved its stored draft"
  end
  local found=false
  if phrase_id>0 then
    local item,existing_key,identity_error=saved_phrase_draft(drafts,phrase_id)
    if identity_error then return nil,identity_error end
    if item then prior=item;drafts[existing_key]=nil;found=true end
  end
  if remove then
    if drafts[key] then found=true end
    if not found then return false end
    drafts[key]=nil
  else
    local valid,validation_error=interpreter.validate_source(pattern)
    if not valid then return nil,validation_error end
    output_policy=output_policy or policies.DEFAULT_OUTPUT_POLICY
    pb_range=pb_range==nil and policies.DEFAULT_PB_RANGE or pb_range
    if not policies.valid_output_policy(output_policy) then return nil,"invalid phrase output policy" end
    if not policies.valid_pb_range(pb_range) then return nil,"invalid PB range" end
    local stored_pattern,copy_error=sequencer.copy_source(pattern)
    if not stored_pattern then return nil,copy_error end
    local committed_label=phrase_id>0 and entries[phrase_id] or nil
    label=label or (prior and prior.label) or (committed_label and committed_label.label) or "Untitled"
    if label_custom==nil then
      label_custom=prior and prior.label_custom or (committed_label and committed_label.label_custom) or false
    end
    if not valid_label(label) or type(label_custom)~="boolean" then return nil,"invalid ACID draft label" end
    if phrase_id>0 then
      local committed=entries[phrase_id]
      if not committed then return nil,"ACID source missing from song data" end
      committed.label,committed.label_custom=label,label_custom
    end
    drafts[key]={pattern=stored_pattern,output_policy=output_policy,pb_range=pb_range,
      instrument_name=tostring(instrument_name or ""),instrument_index=instrument_index,
      phrase_id=phrase_id,label=label,label_custom=label_custom}
  end
  local next_raw,encode_error=encode(entries,drafts)
  if not next_raw then return nil,encode_error end
  local current,current_error=raw_data(song)
  if current==nil and current_error then return nil,current_error end
  if current~=previous then return nil,"ACID song data changed while saving draft" end
  local ok,write_error=pcall(function() song.tool_data=next_raw end)
  local written,verify_error=raw_data(song)
  if verify_error then
    return nil,"ACID draft write outcome is uncertain; readback failed: "..verify_error
  end
  if written==next_raw then
    decoded_raw,decoded_entries,decoded_drafts=next_raw,entries,drafts
    return true
  end
  if written==previous then
    if not ok then
      return nil,"Could not save ACID draft; stored data is unchanged: "..tostring(write_error)
    end
    return nil,"ACID draft write did not persist; stored data is unchanged"
  end
  return nil,"ACID draft write outcome is uncertain; stored data differs from both the previous and requested values"
end

function M.write_draft(song,instrument,phrase,pattern,output_policy,pb_range,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  return write_draft(song,instrument,phrase,pattern,output_policy,pb_range,false)
end

function M.write_draft_metadata(song,instrument,phrase,pattern,output_policy,pb_range,label,label_custom)
  return write_draft(song,instrument,phrase,pattern,output_policy,pb_range,false,label,label_custom)
end

function M.clear_draft(song,instrument,phrase,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  return write_draft(song,instrument,phrase,nil,nil,nil,true)
end

function M.update_label(song,instrument,phrase,label,label_custom,expected_raw,pattern,output_policy,pb_range)
  if not valid_label(label) or type(label_custom)~="boolean" then
    return nil,"invalid ACID phrase label"
  end
  local member,identity
  if phrase~=nil then
    identity=ownership.validate_identity(song,instrument,phrase)
    if not identity then return nil,"Phrase is not a live ACID identity" end
    member=ownership.membership(song,instrument,phrase)
    if not member then return nil,"Phrase is not in the captured instrument" end
  end
  local previous,read_error=raw_data(song)
  if previous==nil and read_error then return nil,read_error end
  if expected_raw~=nil and previous~=expected_raw then return nil,"ACID song data changed before label update" end
  local entries,drafts=read_decoded(previous or "")
  if not entries then return nil,drafts end
  entries,drafts=copy_map(entries),copy_map(drafts)
  local instrument_index,phrase_id,instrument_name=draft_target(song,instrument,phrase,entries)
  if not instrument_index then return nil,phrase_id end
  local pending_key,pending_error=draft_key(instrument_index,phrase_id)
  if not pending_key then return nil,pending_error end
  if phrase_id>0 then
    local entry=entries[phrase_id]
    if not entry then return nil,"ACID source missing from song data" end
    entry.label,entry.label_custom=label,label_custom
    local pending,key,err=saved_phrase_draft(drafts,phrase_id)
    if err then return nil,err end
    if not pending and pattern then
      local valid,source_error=interpreter.validate_source(pattern)
      if not valid then return nil,source_error end
      if not sequencer.same_source(pattern,entry.pattern) or output_policy~=entry.output_policy or pb_range~=entry.pb_range then
        pending={pattern=assert(sequencer.copy_source(pattern)),output_policy=output_policy,
          pb_range=pb_range,instrument_name=instrument_name,instrument_index=instrument_index,
          phrase_id=phrase_id}
        drafts[assert(draft_key(instrument_index,phrase_id))]=pending
      end
    end
    if pending then pending.label,pending.label_custom=label,label_custom end
  else
    local pending=drafts[pending_key]
    if pending and pending.instrument_name~=instrument_name then
      return nil,"New phrase draft destination changed"
    end
    if not pending then
      local valid,source_error=interpreter.validate_source(pattern)
      if not valid then return nil,source_error end
      output_policy=output_policy or policies.DEFAULT_OUTPUT_POLICY
      pb_range=pb_range==nil and policies.DEFAULT_PB_RANGE or pb_range
      if not policies.valid_output_policy(output_policy) or not policies.valid_pb_range(pb_range) then
        return nil,"Invalid pending New phrase source settings"
      end
      pending={pattern=assert(sequencer.copy_source(pattern)),output_policy=output_policy,
        pb_range=pb_range,instrument_name=instrument_name,instrument_index=instrument_index,
        phrase_id=0}
      drafts[pending_key]=pending
    end
    pending.label,pending.label_custom=label,label_custom
  end
  local candidate,encode_error=encode(entries,drafts)
  if not candidate then return nil,encode_error end
  local current,current_error=raw_data(song)
  if current==nil and current_error then return nil,current_error end
  if current~=previous then return nil,"ACID song data changed before label write" end
  local ok,write_error=pcall(function()song.tool_data=candidate end)
  local written,verify_error=raw_data(song)
  if verify_error then return nil,"ACID label write outcome is uncertain: "..verify_error end
  if written==candidate then
    if not ok then
      pcall(function()song.tool_data=previous end)
      local after=raw_data(song)
      if after==previous then
        return nil,"ACID label setter failed after mutation; exact candidate was restored: "..tostring(write_error)
      end
      return nil,"ACID label setter failed and candidate rollback is uncertain"
    end
    decoded_raw,decoded_entries,decoded_drafts=candidate,entries,drafts
    return true,candidate
  end
  if written==previous then return nil,not ok and tostring(write_error) or "ACID label write did not persist" end
  return nil,"ACID label write outcome is uncertain; preserved changed storage"
end

function M.has_drafts(song)
  local raw,err=raw_data(song)
  if raw==nil and err then return nil,err end
  local entries,drafts=read_decoded(raw or "")
  if not entries then return nil,drafts end
  return next(drafts)~=nil
end

local function copy_draft(item)
  if not item then return nil end
  return {pattern=sequencer.copy_source(item.pattern),output_policy=item.output_policy,
    pb_range=item.pb_range,instrument_name=item.instrument_name,
    instrument_index=item.instrument_index,phrase_id=item.phrase_id,
    label=item.label,label_custom=item.label_custom}
end

local function same_draft(left,right)
  return left and right and left.output_policy==right.output_policy and
    left.pb_range==right.pb_range and left.instrument_name==right.instrument_name and
    left.instrument_index==right.instrument_index and left.phrase_id==right.phrase_id and
    left.label==right.label and left.label_custom==right.label_custom and
    sequencer.same_source(left.pattern,right.pattern)
end

local function capture_removal(song,id,entries,drafts,descriptor,revision)
  if descriptor==nil then return nil end
  if type(descriptor)~="table" or getmetatable(descriptor)~=nil or
      (descriptor.kind~="new" and descriptor.kind~="existing") or
      (descriptor.kind=="existing" and descriptor.phrase==nil) or
      (descriptor.kind=="new" and descriptor.phrase~=nil) or descriptor.token==nil or
      not policies.is_integer(descriptor.revision) or descriptor.revision<0 then
    return nil,"Invalid captured ACID draft destination"
  end
  if descriptor.kind=="new" and descriptor.instrument_name_unique==false then
    local live,reason=ownership.membership(song,descriptor.instrument,nil)
    if not live then return nil,reason end
    -- This capture is session-only; preserve any older ambiguous durable scratch.
    return {kind="new",token=descriptor.token,revision=descriptor.revision,present=false}
  end
  local index,phrase_id,name=draft_target(song,descriptor.instrument,descriptor.phrase,entries)
  if not index then return nil,phrase_id end
  if descriptor.kind=="existing" and phrase_id~=id and not revision then
    return nil,"Draft removal must match the prepared source identity"
  end
  local item
  if phrase_id>0 then
    local key,err
    item,key,err=saved_phrase_draft(drafts,phrase_id)
    if err then return nil,err end
  else
    item=drafts[assert(draft_key(index,0))]
    if item and item.instrument_name~=name then item=nil end
  end
  return {kind=descriptor.kind,instrument=descriptor.instrument,phrase=descriptor.phrase,
    token=descriptor.token,revision=descriptor.revision,instrument_index=index,
    instrument_name=name,phrase_id=phrase_id,
    candidate_id=revision and descriptor.kind=="existing" and id or nil,
    draft=copy_draft(item),present=item~=nil}
end

local function prepare(song,id,pattern,output_policy,pb_range,guard,removal,revision,label,label_custom)
  if not valid_id(id) then return nil,"invalid ACID phrase ID" end
  if type(guard)~="function" then return nil,"An ACID request guard is required" end
  local current,current_error=ownership.is_current(song)
  if not current then return nil,current_error end
  output_policy=output_policy or policies.DEFAULT_OUTPUT_POLICY
  pb_range=pb_range==nil and policies.DEFAULT_PB_RANGE or pb_range
  if not policies.valid_output_policy(output_policy) then return nil,"invalid phrase output policy" end
  if not policies.valid_pb_range(pb_range) then return nil,"invalid PB range" end
  local copied,copy_error=sequencer.copy_source(pattern)
  if not copied then return nil,copy_error end
  local previous,err=raw_data(song)
  if previous==nil and err then return nil,err end
  local decoded_entries,decoded_drafts=read_decoded(previous or "")
  if not decoded_entries then return nil,decoded_drafts end
  local entries,drafts=copy_map(decoded_entries),copy_map(decoded_drafts)
  if revision and entries[id]~=nil then
    return nil,"ACID revision ID is already committed"
  end
  if revision then
    local inventory,inventory_error=ownership.inventory(song)
    if not inventory then return nil,inventory_error end
    if inventory[id] then return nil,"ACID revision ID is already used by a live phrase" end
  end
  local captured,removal_error=capture_removal(song,id,entries,drafts,removal,revision)
  if removal_error then return nil,removal_error end
  label=label or "Pattern "..tostring(id)
  if not valid_label(label) then return nil,"invalid ACID phrase label" end
  if label_custom==nil then label_custom=false end
  if type(label_custom)~="boolean" then return nil,"invalid ACID phrase label custom flag" end
  entries[id]={pattern=copied,output_policy=output_policy,pb_range=pb_range,
    label=label,label_custom=label_custom}
  local proposed_sources,proposed_error=encode_sources(entries)
  if not proposed_sources then return nil,proposed_error end
  local proposed,encode_error=append_drafts(proposed_sources,drafts)
  if not proposed then return nil,encode_error end
  local candidate={previous_raw=previous,raw=proposed,id=id}
  candidates[candidate]={song=song,previous_raw=previous,
    proposed_sources=proposed_sources,guard=guard,removal=captured,
    write_attempted=false,written_verified=false,restore_verified=false,integrity_uncertain=false}
  return candidate
end

function M.prepare(song,id,pattern,output_policy,pb_range,guard,removal,label,label_custom)
  return prepare(song,id,pattern,output_policy,pb_range,guard,removal,false,label,label_custom)
end

function M.prepare_revision(song,id,pattern,output_policy,pb_range,guard,removal,label,label_custom)
  return prepare(song,id,pattern,output_policy,pb_range,guard,removal,true,label,label_custom)
end

local function candidate_state(song,candidate)
  local state=type(candidate)=="table" and candidates[candidate]
  if not state then return nil,"invalid ACID store candidate" end
  if not rawequal(song,state.song) then return nil,"ACID store candidate belongs to another song" end
  local current,err=ownership.is_current(song)
  if not current then return nil,err end
  return state
end

function M.candidate_status(candidate)
  local state=type(candidate)=="table" and candidates[candidate]
  if not state then return nil,"invalid ACID store candidate" end
  return {write_attempted=state.write_attempted,written_verified=state.written_verified,
    restore_verified=state.restore_verified,integrity_uncertain=state.integrity_uncertain,
    error=state.error,previous_raw=state.previous_raw,written_raw=state.written_raw}
end

function M.release_candidate(candidate)
  if candidate then candidates[candidate]=nil end
end

local function remove_captured_draft(song,entries,drafts,removal)
  if not removal then return true end
  local index,id,name
  if removal.candidate_id then
    index=ownership.membership(song,removal.instrument,removal.phrase)
    if not index then return nil,"ACID revision target is no longer in its captured instrument" end
    local instrument_ok,instrument_name=pcall(function() return removal.instrument.name end)
    local identity_error
    id,identity_error=ownership.validate_identity(song,removal.instrument,removal.phrase)
    if not instrument_ok or instrument_name~=removal.instrument_name or
        index~=removal.instrument_index or id~=removal.candidate_id then
      return nil,"ACID revision target changed before source commit"
    end
    name=instrument_name
  else
    if not removal.present then return true end
    index,id,name=draft_target(song,removal.instrument,removal.phrase,entries)
  end
  if not removal.candidate_id and not removal.present then return true end
  if not removal.candidate_id and (not index or id~=removal.phrase_id) then return true end
  if removal.kind=="new" and
      (index~=removal.instrument_index or name~=removal.instrument_name) then return true end
  local item,key,err
  local draft_id=removal.candidate_id and removal.phrase_id or id
  if draft_id>0 then item,key,err=saved_phrase_draft(drafts,draft_id)
  else key=draft_key(index,0);item=drafts[key] end
  if not err and same_draft(item,removal.draft) then drafts[key]=nil end
  return true
end

function M.commit(song,candidate)
  local state,err=candidate_state(song,candidate)
  if not state then return nil,err end
  if state.write_attempted then return nil,"ACID store candidate was already attempted" end
  local removal=state.removal
  local guarded,valid=pcall(state.guard,removal and removal.token,removal and removal.revision)
  if not guarded or valid~=true then
    state.error=guarded and "ACID request changed before source commit" or
      "ACID request guard failed: "..tostring(valid)
    return nil,state.error
  end
  local current_song,current_song_error=ownership.is_current(song)
  if not current_song then return nil,current_song_error end
  local current,current_error=raw_data(song)
  if current==nil and current_error then return nil,current_error end
  local decoded_entries,decoded_drafts=read_decoded(current or "")
  if not decoded_entries then return nil,decoded_drafts end
  local entries,drafts=copy_map(decoded_entries),copy_map(decoded_drafts)
  if current~=state.previous_raw then
    return nil,"ACID song data changed during generation"
  end
  local removed,remove_error=remove_captured_draft(song,entries,drafts,removal)
  if not removed then return nil,remove_error end
  local next_raw,encode_error=append_drafts(state.proposed_sources,drafts)
  if not next_raw then return nil,encode_error end
  local latest,latest_error=raw_data(song)
  if latest==nil and latest_error then return nil,latest_error end
  if latest~=current then return nil,"ACID song data changed before source write" end
  state.previous_raw=current
  state.written_raw=next_raw
  state.write_attempted=true
  rawset(candidate,"previous_raw",current)
  rawset(candidate,"raw",next_raw)
  local ok,write_error=pcall(function() song.tool_data=next_raw end)
  local written,verify_error=raw_data(song)
  if verify_error or written~=next_raw then
    state.integrity_uncertain=true
    state.error=verify_error or "ACID song data write did not persist the prepared source"
    return nil,state.error
  end
  state.written_verified=true
  if not ok then
    state.error="Could not store ACID song data: "..tostring(write_error)
    return nil,state.error
  end
  state.error=nil
  return true
end

function M.restore(song,candidate)
  local state,err=candidate_state(song,candidate)
  if not state then return nil,err end
  local current,read_error=raw_data(song)
  if read_error then
    state.integrity_uncertain=state.write_attempted
    state.error=read_error
    return nil,read_error
  end
  if current==state.previous_raw then
    state.restore_verified=true;state.integrity_uncertain=false;state.error=nil
    return true
  end
  if not state.write_attempted or current~=state.written_raw then
    state.integrity_uncertain=state.write_attempted
    state.error="ACID song data changed before rollback; preserved newer data"
    return nil,state.error
  end
  local ok,write_error=pcall(function() song.tool_data=state.previous_raw end)
  local restored,verify_error=raw_data(song)
  if verify_error or restored~=state.previous_raw then
    state.integrity_uncertain=true
    state.error=verify_error or (not ok and "Could not restore ACID song data: "..tostring(write_error)) or
      "ACID song data rollback could not be verified"
    return nil,state.error
  end
  state.restore_verified=true;state.integrity_uncertain=false;state.error=nil
  return true
end

function M.save(song,id,pattern,output_policy,pb_range)
  local candidate,err=M.prepare(song,id,pattern,output_policy,pb_range,synchronous_guard)
  if not candidate then return nil,err end
  return M.commit(song,candidate)
end

function M.allocate(song)
  local current,current_error=ownership.is_current(song)
  if not current then return nil,current_error end
  local raw,err=raw_data(song)
  if err then return nil,err end
  local entries,drafts=read_decoded(raw or "")
  if not entries then return nil,drafts end
  local highest=0
  for id in pairs(entries) do if id>highest then highest=id end end
  -- Retained drafts must never become associated with a newly allocated owner.
  for _,draft in pairs(drafts) do
    if draft.phrase_id>highest then highest=draft.phrase_id end
  end
  local inspected,inspection_error=pcall(function()
    for _,instrument in ipairs(song.instruments) do
      for _,phrase in ipairs(instrument.phrases) do
        local id=ownership.id(phrase)
        if id and id>highest then highest=id end
      end
    end
  end)
  if not inspected then return nil,"Cannot inspect ACID phrase IDs: "..tostring(inspection_error) end
  if highest>=MAX_ID then return nil,"ACID phrase ID space exhausted" end
  return highest+1
end

function M.read_entry(song,id)
  if not valid_id(id) then return nil,"invalid ACID phrase ID" end
  local raw,read_error=raw_data(song)
  if raw==nil and read_error then return nil,read_error end
  local entries,err=read_decoded(raw or "")
  if not entries then return nil,err end
  local entry=entries[id]
  if not entry then return nil,"ACID source missing from song data" end
  local pattern,copy_error=sequencer.copy_source(entry.pattern)
  if not pattern then return nil,copy_error end
  return pattern,entry.output_policy,entry.pb_range,entry.label,entry.label_custom
end

function M.load(song,instrument,phrase,...)
  if select("#",...)>0 then return nil,"Ownership exclusions are not supported" end
  local id,err=ownership.validate_live(song,instrument,phrase)
  if not id then return nil,err end
  return M.read_entry(song,id)
end

return M
