-- SPDX-License-Identifier: GPL-3.0-only
-- Exact, song-local storage for canonical ACID sources and phrase render settings.
local policies=require("model.policies")
local sequencer = require("model.sequencer")
local interpreter = require("model.cycle_interpreter")
local ownership = require("renoise.phrase_ownership")
local M = {}
local MAGIC = "ACID-PITCH-TIME-1"
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
  if #value%2~=0 or value:find("[^%x]") then return nil end
  return (value:gsub("..",function(pair) return string.char(tonumber(pair,16)) end))
end

local function decode(raw)
  if raw=="" then return {},{} end
  if raw:sub(-1)~="\n" then return nil,"ACID song data is incomplete" end
  local lines={}
  for line in raw:gmatch("(.-)\n") do lines[#lines+1]=line end
  if lines[1]~=MAGIC then return nil,"Unrecognized ACID song data; refusing to replace it" end
  local entries,drafts={},{}
  for line_number=2,#lines do
    local line=lines[line_number]
    if line=="" then return nil,"Unexpected blank ACID entry at line "..line_number end
    local draft_instrument,draft_phrase,draft_name,draft_policy,draft_pb_range,
      draft_mode,draft_pitch_length,draft_length,draft_pitch_data,draft_time=
      line:match("^DRAFT|(%d+)|(%d+)|([%x]*)|([%w_]+)|(%d+)|([%w_]+)|(%d+)|(%d+)|([%d,:%-]+)|([NTR]+)$")
    if draft_instrument then
      draft_instrument,draft_phrase=tonumber(draft_instrument),tonumber(draft_phrase)
      draft_pb_range=tonumber(draft_pb_range)
      draft_pitch_length,draft_length=tonumber(draft_pitch_length),tonumber(draft_length)
      local key=tostring(draft_instrument)..":"..tostring(draft_phrase)
      if draft_instrument<1 or draft_phrase<0 or drafts[key] or not policies.valid_output_policy(draft_policy) or
          not policies.valid_pb_range(draft_pb_range) or
          not draft_pitch_length or draft_pitch_length<1 or draft_pitch_length>sequencer.MAX_STEPS or
          not draft_length or draft_length<1 or draft_length>sequencer.MAX_STEPS or #draft_time~=sequencer.MAX_STEPS then
        return nil,"Invalid ACID draft header at line "..line_number
      end
      local pattern=sequencer.new_pattern(draft_length)
      pattern.pitch_length=draft_pitch_length
      pattern.timing_mode=draft_mode
      pattern.pitch_events={}
      local normalized_tokens={}
      for token in draft_pitch_data:gmatch("[^,]+") do
        normalized_tokens[#normalized_tokens+1]=token
        local pitch,err=decode_pitch(token,line_number)
        if not pitch then return nil,err end
        pattern.pitch_events[#pattern.pitch_events+1]=pitch
      end
      if table.concat(normalized_tokens,",")~=draft_pitch_data or #pattern.pitch_events~=sequencer.MAX_STEPS then
        return nil,"Invalid ACID draft pitch data at line "..line_number
      end
      for step=1,sequencer.MAX_STEPS do pattern.time_events[step]=draft_time:sub(step,step) end
      local ok,err=interpreter.compile_cycle(pattern)
      if not ok then return nil,"Invalid ACID draft source: "..err end
      local instrument_name=decode_text(draft_name)
      if not instrument_name then return nil,"Invalid ACID draft instrument identity at line "..line_number end
      drafts[key]={pattern=pattern,output_policy=draft_policy,pb_range=draft_pb_range,
        instrument_name=instrument_name,
        instrument_index=draft_instrument,phrase_id=draft_phrase}
    else
    local id,output_policy,pb_range,timing_mode,pitch_length,length,pitch_data,time=
      line:match("^(%d+)|([%w_]+)|(%d+)|([%w_]+)|(%d+)|(%d+)|([%d,:%-]+)|([NTR]+)$")
    pb_range=tonumber(pb_range)
    id,pitch_length,length=tonumber(id),tonumber(pitch_length),tonumber(length)
    if not id or not valid_id(id) or entries[id] or not policies.valid_output_policy(output_policy) or
        not policies.valid_pb_range(pb_range) or
        not pitch_length or pitch_length<1 or pitch_length>sequencer.MAX_STEPS or
        not length or length<1 or length>sequencer.MAX_STEPS or not time or #time~=sequencer.MAX_STEPS then
      return nil,"Invalid ACID snapshot header at line "..line_number
    end
    local pattern=sequencer.new_pattern(length)
    pattern.pitch_length=pitch_length
    pattern.timing_mode=timing_mode
    pattern.pitch_events={}
    local normalized_tokens={}
    for token in pitch_data:gmatch("[^,]+") do
      normalized_tokens[#normalized_tokens+1]=token
      local pitch,err=decode_pitch(token,line_number)
      if not pitch then return nil,err end
      pattern.pitch_events[#pattern.pitch_events+1]=pitch
    end
    if table.concat(normalized_tokens,",")~=pitch_data then
      return nil,"Invalid pitch separators at line "..line_number
    end
    if #pattern.pitch_events~=sequencer.MAX_STEPS then
      return nil,string.format("ACID source must store exactly %d pitches at line %d",
        sequencer.MAX_STEPS,line_number)
    end
    for step=1,sequencer.MAX_STEPS do pattern.time_events[step]=time:sub(step,step) end
    local ok,err=interpreter.compile_cycle(pattern)
    if not ok then return nil,"Invalid ACID source: "..err end
    entries[id]={pattern=pattern,output_policy=output_policy,pb_range=pb_range}
    end
  end
  return entries,drafts
end

local function encode(entries,drafts)
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
    local ok,err=interpreter.compile_cycle(pattern)
    if not ok then return nil,"Invalid ACID source: "..err end
    if not policies.valid_output_policy(item.output_policy) then return nil,"invalid phrase output policy" end
    if not policies.valid_pb_range(item.pb_range) then return nil,"invalid PB range" end
    local pitches={}
    for index=1,sequencer.MAX_STEPS do pitches[index]=encode_pitch(pattern.pitch_events[index]) end
    local time={}
    for step=1,sequencer.MAX_STEPS do time[step]=pattern.time_events[step] or "N" end
    lines[#lines+1]=table.concat({tostring(id),item.output_policy,tostring(item.pb_range),pattern.timing_mode,
      tostring(pattern.pitch_length),tostring(pattern.length),
      table.concat(pitches,","),table.concat(time)},"|")
  end
  local draft_keys={}
  for key in pairs(drafts or {}) do draft_keys[#draft_keys+1]=key end
  table.sort(draft_keys)
  for _,key in ipairs(draft_keys) do
    local instrument,phrase=key:match("^(%d+):(%d+)$")
    local item=drafts[key]
    if not instrument or tonumber(instrument)<1 or tonumber(phrase)<0 then
      return nil,"invalid ACID draft destination"
    end
    local pattern=item.pattern
    local ok,err=interpreter.compile_cycle(pattern)
    if not ok then return nil,"Invalid ACID draft source: "..err end
    if not policies.valid_output_policy(item.output_policy) then return nil,"invalid ACID draft output policy" end
    if not policies.valid_pb_range(item.pb_range) then return nil,"invalid ACID draft PB range" end
    local pitches,time={},{}
    for index=1,sequencer.MAX_STEPS do pitches[index]=encode_pitch(pattern.pitch_events[index]) end
    for step=1,sequencer.MAX_STEPS do time[step]=pattern.time_events[step] or "N" end
    lines[#lines+1]=table.concat({"DRAFT",instrument,phrase,encode_text(item.instrument_name),
      item.output_policy,tostring(item.pb_range),pattern.timing_mode,
      tostring(pattern.pitch_length),tostring(pattern.length),
      table.concat(pitches,","),table.concat(time)},"|")
  end
  return table.concat(lines,"\n").."\n"
end

function M.read(song)
  local raw,err=raw_data(song)
  if raw==nil and err then return nil,err end
  local entries,decode_error=decode(raw or "")
  if not entries then return nil,decode_error end
  return entries
end

local function draft_key(instrument_index,phrase_id)
  if not policies.is_integer(instrument_index) or instrument_index<1 or
      not policies.is_integer(phrase_id) or phrase_id<0 then
    return nil,"invalid ACID draft destination"
  end
  return tostring(instrument_index)..":"..tostring(phrase_id)
end

local function draft_target(song,instrument,phrase,entries,excluded)
  local index,err=ownership.membership(song,instrument,phrase)
  if not index then return nil,err end
  local ok,name=pcall(function() return instrument.name end)
  if not ok or type(name)~="string" then return nil,"Cannot inspect ACID draft instrument name" end
  if phrase~=nil then
    local id,identity_error=ownership.validate_live(song,instrument,phrase,excluded)
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

function M.read_draft(song,instrument,phrase,excluded)
  local raw,read_error=raw_data(song)
  if raw==nil and read_error then return nil,read_error end
  local entries,drafts=decode(raw or "")
  if not entries then return nil,drafts end
  local instrument_index,phrase_id,instrument_name=draft_target(song,instrument,phrase,entries,excluded)
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
    item and item.pb_range or nil
end

local function write_draft(song,instrument,phrase,pattern,output_policy,pb_range,remove,excluded)
  local previous,read_error=raw_data(song)
  if previous==nil and read_error then return nil,read_error end
  local entries,drafts=decode(previous or "")
  if not entries then return nil,drafts end
  local instrument_index,phrase_id,instrument_name=draft_target(song,instrument,phrase,entries,excluded)
  if not instrument_index then return nil,phrase_id end
  local key,err=draft_key(instrument_index,phrase_id)
  if not key then return nil,err end
  if phrase_id==0 and drafts[key] and drafts[key].instrument_name~=instrument_name then
    return nil,"New phrase draft destination changed; preserved its stored draft"
  end
  local found=false
  if phrase_id>0 then
    local item,existing_key,identity_error=saved_phrase_draft(drafts,phrase_id)
    if identity_error then return nil,identity_error end
    if item then drafts[existing_key]=nil;found=true end
  end
  if remove then
    if drafts[key] then found=true end
    if not found then return false end
    drafts[key]=nil
  else
    local valid,validation_error=interpreter.compile_cycle(pattern)
    if not valid then return nil,validation_error end
    output_policy=output_policy or policies.DEFAULT_OUTPUT_POLICY
    pb_range=pb_range==nil and policies.DEFAULT_PB_RANGE or pb_range
    if not policies.valid_output_policy(output_policy) then return nil,"invalid phrase output policy" end
    if not policies.valid_pb_range(pb_range) then return nil,"invalid PB range" end
    drafts[key]={pattern=pattern,output_policy=output_policy,pb_range=pb_range,
      instrument_name=tostring(instrument_name or ""),instrument_index=instrument_index,
      phrase_id=phrase_id}
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
  if written==next_raw then return true end
  if written==previous then
    if not ok then
      return nil,"Could not save ACID draft; stored data is unchanged: "..tostring(write_error)
    end
    return nil,"ACID draft write did not persist; stored data is unchanged"
  end
  return nil,"ACID draft write outcome is uncertain; stored data differs from both the previous and requested values"
end

function M.write_draft(song,instrument,phrase,pattern,output_policy,pb_range,excluded)
  return write_draft(song,instrument,phrase,pattern,output_policy,pb_range,false,excluded)
end

function M.clear_draft(song,instrument,phrase,excluded)
  return write_draft(song,instrument,phrase,nil,nil,nil,true,excluded)
end

function M.has_drafts(song)
  local raw,err=raw_data(song)
  if raw==nil and err then return nil,err end
  local entries,drafts=decode(raw or "")
  if not entries then return nil,drafts end
  return next(drafts)~=nil
end

local function copy_draft(item)
  if not item then return nil end
  return {pattern=sequencer.copy_source(item.pattern),output_policy=item.output_policy,
    pb_range=item.pb_range,instrument_name=item.instrument_name,
    instrument_index=item.instrument_index,phrase_id=item.phrase_id}
end

local function same_draft(left,right)
  return left and right and left.output_policy==right.output_policy and
    left.pb_range==right.pb_range and left.instrument_name==right.instrument_name and
    left.instrument_index==right.instrument_index and left.phrase_id==right.phrase_id and
    sequencer.same_source(left.pattern,right.pattern)
end

local function capture_removal(song,id,entries,drafts,descriptor)
  if descriptor==nil then return nil end
  if type(descriptor)~="table" or getmetatable(descriptor)~=nil or
      (descriptor.kind~="new" and descriptor.kind~="existing") or
      (descriptor.kind=="existing" and descriptor.phrase==nil) or
      (descriptor.kind=="new" and descriptor.phrase~=nil) or descriptor.token==nil or
      not policies.is_integer(descriptor.revision) or descriptor.revision<0 then
    return nil,"Invalid captured ACID draft destination"
  end
  local index,phrase_id,name=draft_target(song,descriptor.instrument,descriptor.phrase,entries)
  if not index then return nil,phrase_id end
  if descriptor.kind=="existing" and phrase_id~=id then
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
    instrument_name=name,phrase_id=phrase_id,draft=copy_draft(item),present=item~=nil}
end

function M.prepare(song,id,pattern,output_policy,pb_range,guard,removal)
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
  local entries,drafts=decode(previous or "")
  if not entries then return nil,drafts end
  local captured,removal_error=capture_removal(song,id,entries,drafts,removal)
  if removal_error then return nil,removal_error end
  local captured_sources,source_error=encode(entries,{})
  if not captured_sources then return nil,source_error end
  entries[id]={pattern=copied,output_policy=output_policy,pb_range=pb_range}
  local proposed_sources,proposed_error=encode(entries,{})
  if not proposed_sources then return nil,proposed_error end
  local proposed,encode_error=encode(entries,drafts)
  if not proposed then return nil,encode_error end
  local candidate={previous_raw=previous,raw=proposed,id=id}
  candidates[candidate]={song=song,previous_raw=previous,captured_sources=captured_sources,
    proposed_sources=proposed_sources,guard=guard,removal=captured,
    write_attempted=false,written_verified=false,restore_verified=false,integrity_uncertain=false}
  return candidate
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

local function remove_captured_draft(song,entries,drafts,removal)
  if not removal or not removal.present then return end
  local index,id,name=draft_target(song,removal.instrument,removal.phrase,entries)
  if not index or id~=removal.phrase_id then return end
  if removal.kind=="new" and
      (index~=removal.instrument_index or name~=removal.instrument_name) then return end
  local item,key,err
  if id>0 then item,key,err=saved_phrase_draft(drafts,id)
  else key=draft_key(index,0);item=drafts[key] end
  if not err and same_draft(item,removal.draft) then drafts[key]=nil end
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
  local entries,drafts=decode(current or "")
  if not entries then return nil,drafts end
  local sources,source_error=encode(entries,{})
  if not sources then return nil,source_error end
  if sources~=state.captured_sources then return nil,"ACID song data changed during generation" end
  local proposed,decode_error=decode(state.proposed_sources)
  if not proposed then return nil,decode_error end
  remove_captured_draft(song,entries,drafts,removal)
  local next_raw,encode_error=encode(proposed,drafts)
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
  local entries,err=M.read(song)
  if not entries then return nil,err end
  local highest=0
  for id in pairs(entries) do if id>highest then highest=id end end
  for _,instrument in ipairs(song.instruments or {}) do
    for _,phrase in ipairs(instrument.phrases or {}) do
      local id=ownership.id(phrase)
      if id and id>highest then highest=id end
    end
  end
  if highest>=MAX_ID then return nil,"ACID phrase ID space exhausted" end
  return highest+1
end

function M.read_entry(song,id)
  if not valid_id(id) then return nil,"invalid ACID phrase ID" end
  local entries,err=M.read(song)
  if not entries then return nil,err end
  local entry=entries[id]
  if not entry then return nil,"ACID source missing from song data" end
  return sequencer.copy_source(entry.pattern),entry.output_policy,entry.pb_range
end

function M.load(song,instrument,phrase,excluded)
  local id,err=ownership.validate_live(song,instrument,phrase,excluded)
  if not id then return nil,err end
  return M.read_entry(song,id)
end

return M
