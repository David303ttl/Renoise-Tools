-- Exact, song-local storage for the current ACID source contract.
local sequencer = require("model.sequencer")
local interpreter = require("model.cycle_interpreter")
local ownership = require("writers.phrase_ownership")
local M = {}
local MAGIC = "ACID-PITCH-TIME-2"
local AUDIO_MODES = {baseline=true, retrigger=true, slide=true, mono=true}
local ENTRY_MODES = {original=true, extended=true}
local PLAYBACK = {loop=true, one_shot=true}
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
  return string.format("%d:%s:%s:%d%d",p.note,
    p.key==nil and "-" or tostring(p.key),
    p.octave==nil and "-" or tostring(p.octave),
    p.accent and 1 or 0,p.slide and 1 or 0)
end

local function decode_pitch(token, line)
  local note,key,octave,flags=token:match("^(%d+):([%d%-]+):([%d%-]+):([01][01])$")
  if not note then return nil,"Corrupt pitch at line "..line end
  local p={note=tonumber(note),accent=flags:sub(1,1)=="1",slide=flags:sub(2,2)=="1"}
  if key~="-" and octave~="-" then
    p.key,p.octave=tonumber(key),tonumber(octave)
  elseif key~="-" or octave~="-" then
    return nil,"Incomplete octave at line "..line
  end
  return p
end

local function decode(raw)
  if raw=="" then return {} end
  if raw:sub(-1)~="\n" then return nil,"ACID song data is incomplete" end
  local lines={}
  for line in raw:gmatch("(.-)\n") do lines[#lines+1]=line end
  if lines[1]~=MAGIC then return nil,"Unrecognized ACID song data; refusing to replace it" end
  local entries={}
  for line_number=2,#lines do
    local line=lines[line_number]
    if line=="" then return nil,"Unexpected blank ACID entry at line "..line_number end
      local id,audio,entry_mode,pitch_length,playback,length,pitch_data,time=
        line:match("^(%d+)|([%w_]+)|([%w_]+)|(%d+)|([%w_]+)|(%d+)|([%d,:%-]+)|([NTR]+)$")
      id,audio=tonumber(id),audio
      pitch_length,length=tonumber(pitch_length),tonumber(length)
      if not id or not valid_id(id) or entries[id] or not AUDIO_MODES[audio] or
          not ENTRY_MODES[entry_mode] or not PLAYBACK[playback] or
          not pitch_length or pitch_length<1 or pitch_length>64 or
          not length or length<1 or length>64 or #time~=length then
        return nil,"Invalid ACID snapshot header at line "..line_number
      end
      if entry_mode=="original" and (length>16 or pitch_length~=16) then
        return nil,"Invalid Original ACID source bounds at line "..line_number
      end
      local pattern=sequencer.new_pattern(length,entry_mode)
      pattern.entry_mode,pattern.pitch_length,pattern.playback=entry_mode,pitch_length,playback
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
      for step=1,length do pattern.time_events[step]=time:sub(step,step) end
      local ok,err=interpreter.compile_cycle(pattern)
      if not ok then return nil,"Invalid ACID source: "..err end
      entries[id]={pattern=pattern,audio_mode=audio}
  end
  return entries
end

local function encode(entries)
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
    if not AUDIO_MODES[item.audio_mode] then return nil,"invalid audio mode" end
    local pitches={}
    for index=1,64 do pitches[index]=encode_pitch(pattern.pitch_events[index]) end
    lines[#lines+1]=table.concat({tostring(id),item.audio_mode,pattern.entry_mode,
      tostring(pattern.pitch_length),pattern.playback,tostring(pattern.length),
      table.concat(pitches,","),table.concat(pattern.time_events)},"|")
  end
  return table.concat(lines,"\n").."\n"
end

function M.read(song)
  local raw,err=raw_data(song)
  if raw==nil and err then return nil,err end
  return decode(raw or "")
end

function M.prepare(song,id,pattern,audio_mode)
  if not valid_id(id) then return nil,"invalid ACID phrase ID" end
  local previous,err=raw_data(song)
  if previous==nil and err then return nil,err end
  local entries,decode_error=decode(previous or "")
  if not entries then return nil,decode_error end
  entries[id]={pattern=pattern,audio_mode=audio_mode}
  local next_raw,encode_error=encode(entries)
  if not next_raw then return nil,encode_error end
  return {previous_raw=previous,raw=next_raw,id=id}
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

function M.save(song,id,pattern,audio_mode)
  local candidate,err=M.prepare(song,id,pattern,audio_mode)
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
  return copied[id].pattern,copied[id].audio_mode
end

return M
