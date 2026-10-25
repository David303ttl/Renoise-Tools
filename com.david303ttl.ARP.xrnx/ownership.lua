-- ARP v0.5 ownership: snapshots keyed by pattern line AND note column.
-- Reads ARP04 single-column records and writes ARP05 records. Tool data
-- is scoped to this XRNX bundle by Renoise (not shared with other tools).
local M={}
local fields={
  "note_value","instrument_value","volume_value","panning_value",
  "delay_value","effect_number_value","effect_amount_value"
}
function M.key(line,column)
  return tostring(line)..":"..tostring(column)
end
function M.capture(cell)
  local values={}
  for i,name in ipairs(fields) do values[i]=cell[name] end
  return values
end
function M.matches(cell,expected)
  if expected==nil then return cell.is_empty end
  for i,name in ipairs(fields) do
    if cell[name]~=expected[i] then return false end
  end
  return true
end
function M.restore(cell,snapshot)
  cell:clear()
  if snapshot then
    for i,name in ipairs(fields) do cell[name]=snapshot[i] end
  end
end
function M.encode_name(s)
  local out={}
  for i=1,#s do out[i]=string.format("%02X",s:byte(i)) end
  return table.concat(out)
end
function M.find(records,pattern,destination)
  for i,r in ipairs(records) do
    if r.pattern==pattern and r.destination==destination then return r,i end
  end
end
local function number(s,min,max)
  if type(s)~="string" then return nil end
  local n=tonumber(s)
  if not n or n%1~=0 or n<min or n>max then return nil end
  return n
end
local function split(s,sep)
  local out={}
  for word in (s..sep):gmatch("(.-)"..sep) do out[#out+1]=word end
  return out
end
function M.load(data)
  if data==nil or data=="" then return {} end
  if type(data)~="string" then return nil,"ARP tool data is not text" end
  local legacy=data:sub(1,6)=="ARP04\n"
  if not legacy and data:sub(1,6)~="ARP05\n" then
    return nil,"Unknown ARP ownership format; no changes made"
  end
  local records={}
  for line in data:sub(7):gmatch("([^\n]+)") do
    local p=split(line,"|")
    if p[1]~="R" or #p~=(legacy and 9 or 10) then
      return nil,"Malformed ARP ownership record"
    end
    local pattern=number(p[2],1,65535)
    local dest=number(p[3],1,65535)
    local source=number(p[4],1,65535)
    local length=number(p[5],1,65535)
    local columns=legacy and 1 or number(p[9],1,12)
    if not pattern or not dest or not source or not length or not columns then
      return nil,"Invalid ARP ownership header"
    end
    for i=6,8 do
      if not p[i]:match("^[0-9A-F]*$") then
        return nil,"Invalid ARP name metadata"
      end
    end
    local record={
      pattern=pattern,destination=dest,source=source,length=length,
      columns=columns,pattern_name=p[6],dest_name=p[7],
      source_name=p[8],events={}
    }
    local series=legacy and p[9] or p[10]
    for item in series:gmatch("[^;]+") do
      local raw=split(item,",")
      if #raw~=(legacy and 8 or 9) then
        return nil,"Invalid ARP event record size"
      end
      local lineno=number(raw[1],1,length)
      local col=legacy and 1 or number(raw[2],1,columns)
      if not lineno or not col then return nil,"Invalid ARP event address" end
      local key=M.key(lineno,col)
      if record.events[key] then return nil,"Duplicate ARP event address" end
      local offset=legacy and 1 or 2
      local snapshot={}
      for i=1,7 do
        local value=number(raw[i+offset],0,65535)
        if not value then return nil,"Invalid ARP event snapshot" end
        snapshot[i]=value
      end
      record.events[key]=snapshot
    end
    if M.find(records,pattern,dest) then
      return nil,"Duplicate ARP output ownership"
    end
    records[#records+1]=record
  end
  return records
end
function M.save(records)
  local out={"ARP05"}
  for _,r in ipairs(records) do
    local cells={}
    for line=1,r.length do
      for col=1,r.columns do
        local snapshot=r.events[M.key(line,col)]
        if snapshot then
          local item={line,col}
          for _,v in ipairs(snapshot) do item[#item+1]=v end
          cells[#cells+1]=table.concat(item,",")
        end
      end
    end
    out[#out+1]=table.concat({
      "R",r.pattern,r.destination,r.source,r.length,
      r.pattern_name,r.dest_name,r.source_name,r.columns,
      table.concat(cells,";")
    },"|")
  end
  return table.concat(out,"\n").."\n"
end
return M
