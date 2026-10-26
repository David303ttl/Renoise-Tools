-- Readable independent pitch/time memory usage for ACID 0.1.
local M={}
function M.inspect(pattern)
  local length=pattern.length
  local notes,ties,rests=0,0,0
  local used={}
  local time={}
  for i=1,length do
    local t=pattern.time_events[i]
    if t=="N" then notes=notes+1
    elseif t=="T" then ties=ties+1
    elseif t=="R" then rests=rests+1 end
    time[i]=t or "?"
  end
  local pitch_count=#pattern.pitch_events
  local next_pitch= pitch_count>0 and ((notes%pitch_count)+1) or 1
  for i,p in ipairs(pattern.pitch_events) do
    local name=string.format("%02d:%d%s%s",i,p.note,p.accent and "!" or "",
      p.slide and "~" or "")
    used[#used+1]=name
  end
  return {
    notes=notes,ties=ties,rests=rests,length=length,
    pitch_count=pitch_count,next_pitch=next_pitch,
    missing_time=length-#pattern.time_events,
    pitch_text=table.concat(used,"  "),
    time_text=table.concat(time," ")
  }
end
return M
