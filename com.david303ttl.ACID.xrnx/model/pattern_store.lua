-- ACID song-local PITCH/TIME snapshots. No Lua evaluation or global preferences.
-- renoise.song().tool_data is an XRNX-bundle-scoped string persisted in XRNS.
local sequencer=require("model.sequencer")
local ownership=require("writers.phrase_ownership")
local M={}
local MAGIC="ACID-PITCH-TIME-1"
local MODES={baseline=true,retrigger=true,slide=true,mono=true}

local function decode(raw)
  if raw==nil or raw=="" then return {} end
  if type(raw)~="string" then return nil,"ACID song data is not text" end
  local lines={}
  for line in (raw.."\n"):gmatch("(.-)\n") do lines[#lines+1]=line end
  if lines[1]~=MAGIC then return nil,"Unrecognized ACID song data; refusing to replace it" end
  local entries={}
  for i=2,#lines do
    if lines[i]~="" then
      local id,mode,n,pitches,time=lines[i]:match("^(%d+)|([%w_]+)|(%d+)|([%w,:%-]+)|([NTR]+)$")
      if not id or not MODES[mode] then return nil,"Corrupt ACID entry at line "..i end
      id,n=tonumber(id),tonumber(n)
      if not id or id<1 or id>2147483647 or id%1~=0 or entries[id]
        or not n or n<1 or n>64 or #time~=n then
        return nil,"Invalid ACID snapshot header at line "..i
      end
      local p=sequencer.new_pattern(n)
      p.pitch_events={}
      for token in pitches:gmatch("[^,]+") do
        local note,key,oct,flags=token:match("^(%d+):([%d%-]+):([%d%-]+):([01][01])$")
        if not note then return nil,"Corrupt pitch at line "..i end
        local value={note=tonumber(note),accent=flags:sub(1,1)=="1",
          slide=flags:sub(2,2)=="1"}
        if key~="-" and oct~="-" then
          value.key=tonumber(key);value.octave=tonumber(oct)
        elseif key~="-" or oct~="-" then
          return nil,"Incomplete octave at line "..i
        end
        p.pitch_events[#p.pitch_events+1]=value
      end
      for step=1,n do p.time_events[step]=time:sub(step,step) end
      local ok,err=sequencer.validate(p)
      if not ok then return nil,"Invalid ACID memory: "..err end
      entries[id]={pattern=p,mode=mode}
    end
  end
  return entries
end

local function encode(entries)
  local lines={MAGIC}
  local ids={}
  for id in pairs(entries) do ids[#ids+1]=id end
  table.sort(ids)
  for _,id in ipairs(ids) do
    local item=entries[id]
    local p=item.pattern
    local ok,err=sequencer.validate(p)
    if not ok then return nil,err end
    if #p.time_events~=p.length or not MODES[item.mode] then
      return nil,"ACID snapshot requires complete TIME and valid audio mode"
    end
    local pitches={}
    for _,v in ipairs(p.pitch_events) do
      pitches[#pitches+1]=string.format("%d:%s:%s:%d%d",v.note,
        v.key==nil and "-" or tostring(v.key),
        v.octave==nil and "-" or tostring(v.octave),
        v.accent and 1 or 0,v.slide and 1 or 0)
    end
    lines[#lines+1]=table.concat({
      tostring(id),item.mode,tostring(p.length),
      table.concat(pitches,","),table.concat(p.time_events)
    },"|")
  end
  return table.concat(lines,"\n").."\n"
end

function M.read(song)
  local ok,value=pcall(function()return song.tool_data end)
  if not ok then return nil,"Cannot access Renoise song.tool_data" end
  return decode(value)
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
  if highest>=2147483647 then return nil,"ACID phrase ID space exhausted" end
  return highest+1
end

function M.save(song,id,pattern,mode)
  if type(id)~="number" or id%1~=0 or id<1 or id>2147483647 then
    return nil,"invalid ACID phrase ID"
  end
  local entries,err=M.read(song)
  if not entries then return nil,err end
  entries[id]={pattern=pattern,mode=mode}
  local raw,encode_error=encode(entries)
  if not raw then return nil,encode_error end
  local ok,write_error=pcall(function()song.tool_data=raw end)
  if not ok then return nil,"Could not store ACID song data: "..tostring(write_error) end
  return true
end

function M.load(song,phrase)
  if ownership.status(phrase)~="owned" then
    return nil,"Phrase is not an unchanged ACID-owned phrase"
  end
  local id=ownership.id(phrase)
  if not id then
    return nil,"Older ACID phrase has no saved PITCH/TIME snapshot; do not reverse-engineer rendered notes"
  end
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
  if not entry then return nil,"ACID pitch/time source missing from song data" end
  -- Return a fresh copy: UI edits must not mutate an on-disk snapshot.
  local raw=assert(encode({[id]=entry}))
  local copied=assert(decode(raw))
  return copied[id].pattern,copied[id].mode
end

return M
