-- Exact, song-local storage for canonical ACID sources and phrase output policy.
local sequencer = require("model.sequencer")
local interpreter = require("model.cycle_interpreter")
local ownership = require("writers.phrase_ownership")
local M = {}
local MAGIC = "ACID-PITCH-TIME-3"
local OUTPUT_POLICIES = {["repeat"]=true, play_once=true}
local MAX_ID = 2147483647

local function valid_id(id)
  return type(id)=="number" and id%1==0 and id>=1 and id<=MAX_ID
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
    local draft_instrument,draft_phrase,draft_name,draft_policy,draft_pitch_length,draft_length,
      draft_pitch_data,draft_time=line:match("^DRAFT|(%d+)|(%d+)|([%x]*)|([%w_]+)|(%d+)|(%d+)|([%d,:%-]+)|([NTR]+)$")
    if draft_instrument then
      draft_instrument,draft_phrase=tonumber(draft_instrument),tonumber(draft_phrase)
      draft_pitch_length,draft_length=tonumber(draft_pitch_length),tonumber(draft_length)
      local key=tostring(draft_instrument)..":"..tostring(draft_phrase)
      if draft_instrument<1 or draft_phrase<0 or drafts[key] or not OUTPUT_POLICIES[draft_policy] or
          not draft_pitch_length or draft_pitch_length<1 or draft_pitch_length>64 or
          not draft_length or draft_length<1 or draft_length>64 or #draft_time~=64 then
        return nil,"Invalid ACID draft header at line "..line_number
      end
      local pattern=sequencer.new_pattern(draft_length)
      pattern.pitch_length=draft_pitch_length
      pattern.pitch_events={}
      local normalized_tokens={}
      for token in draft_pitch_data:gmatch("[^,]+") do
        normalized_tokens[#normalized_tokens+1]=token
        local pitch,err=decode_pitch(token,line_number)
        if not pitch then return nil,err end
        pattern.pitch_events[#pattern.pitch_events+1]=pitch
      end
      if table.concat(normalized_tokens,",")~=draft_pitch_data or #pattern.pitch_events~=64 then
        return nil,"Invalid ACID draft pitch data at line "..line_number
      end
      for step=1,64 do pattern.time_events[step]=draft_time:sub(step,step) end
      local ok,err=interpreter.compile_cycle(pattern)
      if not ok then return nil,"Invalid ACID draft source: "..err end
      local instrument_name=decode_text(draft_name)
      if not instrument_name then return nil,"Invalid ACID draft instrument identity at line "..line_number end
      drafts[key]={pattern=pattern,output_policy=draft_policy,instrument_name=instrument_name,
        instrument_index=draft_instrument,phrase_id=draft_phrase}
    else
    local id,output_policy,pitch_length,length,pitch_data,time=
      line:match("^(%d+)|([%w_]+)|(%d+)|(%d+)|([%d,:%-]+)|([NTR]+)$")
    id,pitch_length,length=tonumber(id),tonumber(pitch_length),tonumber(length)
    if not id or not valid_id(id) or entries[id] or not OUTPUT_POLICIES[output_policy] or
        not pitch_length or pitch_length<1 or pitch_length>64 or
        not length or length<1 or length>64 or not time or #time~=64 then
      return nil,"Invalid ACID snapshot header at line "..line_number
    end
    local pattern=sequencer.new_pattern(length)
    pattern.pitch_length=pitch_length
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
    if #pattern.pitch_events~=64 then return nil,"ACID source must store exactly 64 pitches at line "..line_number end
    for step=1,64 do pattern.time_events[step]=time:sub(step,step) end
    local ok,err=interpreter.compile_cycle(pattern)
    if not ok then return nil,"Invalid ACID source: "..err end
    entries[id]={pattern=pattern,output_policy=output_policy}
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
    if not OUTPUT_POLICIES[item.output_policy] then return nil,"invalid phrase output policy" end
    local pitches={}
    for index=1,64 do pitches[index]=encode_pitch(pattern.pitch_events[index]) end
    local time={}
    for step=1,64 do time[step]=pattern.time_events[step] or "N" end
    lines[#lines+1]=table.concat({tostring(id),item.output_policy,
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
    if not OUTPUT_POLICIES[item.output_policy] then return nil,"invalid ACID draft output policy" end
    local pitches,time={},{}
    for index=1,64 do pitches[index]=encode_pitch(pattern.pitch_events[index]) end
    for step=1,64 do time[step]=pattern.time_events[step] or "N" end
    lines[#lines+1]=table.concat({"DRAFT",instrument,phrase,encode_text(item.instrument_name),item.output_policy,
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

function M.prepare(song,id,pattern,output_policy)
  if not valid_id(id) then return nil,"invalid ACID phrase ID" end
  output_policy=output_policy or "repeat"
  local previous,err=raw_data(song)
  if previous==nil and err then return nil,err end
  local entries,drafts=decode(previous or "")
  local decode_error=drafts
  if not entries then return nil,decode_error end
  entries[id]={pattern=pattern,output_policy=output_policy}
  local next_raw,encode_error=encode(entries,drafts)
  if not next_raw then return nil,encode_error end
  return {previous_raw=previous,raw=next_raw,id=id}
end

local function draft_key(instrument_index,phrase_id)
  if type(instrument_index)~="number" or instrument_index%1~=0 or instrument_index<1 or
      type(phrase_id)~="number" or phrase_id%1~=0 or phrase_id<0 then
    return nil,"invalid ACID draft destination"
  end
  return tostring(instrument_index)..":"..tostring(phrase_id)
end

function M.read_draft(song,instrument_index,phrase_id,instrument_name)
  local key,err=draft_key(instrument_index,phrase_id)
  if not key then return nil,err end
  local raw,read_error=raw_data(song)
  if raw==nil and read_error then return nil,read_error end
  local entries,drafts=decode(raw or "")
  if not entries then return nil,drafts end
  local item=drafts[key]
  if phrase_id>0 then
    local matches=0
    for _,candidate in pairs(drafts) do
      if candidate.phrase_id==phrase_id then item=candidate;matches=matches+1 end
    end
    if matches>1 then return nil,"Duplicate ACID draft phrase identity" end
  elseif item then
    local name=tostring(instrument_name or "")
    local matches=0
    for _,instrument in ipairs(song.instruments or {}) do
      if tostring(instrument.name or "")==name then matches=matches+1 end
    end
    if item.instrument_name~=name or matches~=1 then item=nil end
  end
  return item and item.pattern or nil,item and item.output_policy or nil
end

local function write_draft(song,instrument_index,phrase_id,instrument_name,pattern,output_policy,remove)
  local key,err=draft_key(instrument_index,phrase_id)
  if not key then return nil,err end
  local previous,read_error=raw_data(song)
  if previous==nil and read_error then return nil,read_error end
  local entries,drafts=decode(previous or "")
  if not entries then return nil,drafts end
  local found=false
  if phrase_id>0 then
    for existing_key,item in pairs(drafts) do
      if item.phrase_id==phrase_id then drafts[existing_key]=nil;found=true end
    end
  end
  if remove then
    if drafts[key] then found=true end
    if not found then return false end
    drafts[key]=nil
  else
    local valid,validation_error=interpreter.compile_cycle(pattern)
    if not valid then return nil,validation_error end
    output_policy=output_policy or "repeat"
    if not OUTPUT_POLICIES[output_policy] then return nil,"invalid phrase output policy" end
    drafts[key]={pattern=pattern,output_policy=output_policy,
      instrument_name=tostring(instrument_name or ""),instrument_index=instrument_index,
      phrase_id=phrase_id}
  end
  local next_raw,encode_error=encode(entries,drafts)
  if not next_raw then return nil,encode_error end
  local current,current_error=raw_data(song)
  if current==nil and current_error then return nil,current_error end
  if current~=previous then return nil,"ACID song data changed while saving draft" end
  local ok,write_error=pcall(function() song.tool_data=next_raw end)
  if not ok then return nil,"Could not save ACID draft: "..tostring(write_error) end
  local written,verify_error=raw_data(song)
  if not written then return nil,verify_error end
  if written~=next_raw then return nil,"ACID draft write did not persist" end
  return true
end

function M.write_draft(song,instrument_index,phrase_id,instrument_name,pattern,output_policy)
  return write_draft(song,instrument_index,phrase_id,instrument_name,pattern,output_policy,false)
end

function M.clear_draft(song,instrument_index,phrase_id,instrument_name)
  return write_draft(song,instrument_index,phrase_id,instrument_name,nil,nil,true)
end

function M.has_drafts(song)
  local raw,err=raw_data(song)
  if raw==nil and err then return nil,err end
  local entries,drafts=decode(raw or "")
  if not entries then return nil,drafts end
  return next(drafts)~=nil
end

function M.commit(song,candidate)
  if type(candidate)~="table" or type(candidate.raw)~="string" then return nil,"invalid ACID store candidate" end
  local current,err=raw_data(song)
  if current==nil and err then return nil,err end
  if current~=candidate.previous_raw then return nil,"ACID song data changed during generation" end
  local ok,write_error=pcall(function() song.tool_data=candidate.raw end)
  if not ok then return nil,"Could not store ACID song data: "..tostring(write_error) end
  local written,verify_error=raw_data(song)
  if not written then return nil,verify_error end
  if written~=candidate.raw then return nil,"ACID song data write did not persist the prepared source" end
  return true
end

function M.restore(song,candidate)
  if type(candidate)~="table" or type(candidate.raw)~="string" then return nil,"invalid ACID store candidate" end
  local current,read_error=raw_data(song)
  if current==nil and read_error then return nil,read_error end
  if current==candidate.previous_raw then return true end
  if current~=candidate.raw then return nil,"ACID song data changed before rollback; preserved newer data" end
  local ok,write_error=pcall(function() song.tool_data=candidate.previous_raw end)
  if not ok then return nil,"Could not restore ACID song data: "..tostring(write_error) end
  local restored,verify_error=raw_data(song)
  if restored==nil and verify_error then return nil,verify_error end
  if restored~=candidate.previous_raw then return nil,"ACID song data rollback could not be verified" end
  return true
end

function M.save(song,id,pattern,output_policy)
  local candidate,err=M.prepare(song,id,pattern,output_policy)
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

function M.load(song,phrase)
  if ownership.status(phrase)~="owned" then return nil,"Phrase is not an unchanged ACID-owned phrase" end
  local id=ownership.id(phrase)
  if not id then return nil,"ACID phrase has no current-format source snapshot" end
  local count=0
  for _,instrument in ipairs(song.instruments or {}) do
    for _,existing in ipairs(instrument.phrases or {}) do
      if ownership.id(existing)==id then count=count+1 end
    end
  end
  if count~=1 then return nil,"Duplicate or missing ACID phrase ID; cannot choose safely" end
  local entries,err=M.read(song)
  if not entries then return nil,err end
  local entry=entries[id]
  if not entry then return nil,"ACID source missing from song data" end
  local raw=assert(encode({[id]=entry}))
  local copied=assert(decode(raw))
  return copied[id].pattern,copied[id].output_policy
end

return M
