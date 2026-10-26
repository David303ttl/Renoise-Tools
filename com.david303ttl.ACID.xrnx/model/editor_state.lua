-- Pure Lua projection for ACID's paged, directly editable PITCH/TIME grids.
-- Projection NEVER mutates or reallocates either independent memory.
local seq = require("model.sequencer")
local M = {}
M.PAGE_SIZE = seq.PAGE_SIZE
M.MAX_PAGES = seq.MAX_STEPS / seq.PAGE_SIZE

function M.page_for(index)
  assert(type(index)=="number" and index%1==0 and index>=1 and index<=64)
  return math.floor((index-1)/16)+1
end

function M.index_on_page(page, cell)
  assert(type(page)=="number" and page%1==0 and page>=1 and page<=4)
  assert(type(cell)=="number" and cell%1==0 and cell>=1 and cell<=16)
  return (page-1)*16+cell
end

function M.project(pattern)
  local ok, err=seq.validate(pattern)
  local out={length=type(pattern)=="table" and pattern.length or 0,
    mapping={}, used={}, note_count=0, error=nil}
  if not ok then
    out.error={message=err}
    local entry=string.match(err,"pitch entry (%d+)") or
      string.match(err,"at entry (%d+)")
    local step=string.match(err,"step (%d+)")
    if entry then out.error.pitch_index=tonumber(entry) end
    if step then out.error.step=tonumber(step) end
    return out
  end
  local pitches=#pattern.pitch_events
  local current=nil
  for step=1,pattern.length do
    local command=pattern.time_events[step]
    if command=="N" then
      out.note_count=out.note_count+1
      if pitches==0 then
        out.mapping[step]={kind="note", missing_pitch=true}
        if not out.error then
          out.error={step=step, pitch_index=1,
            message=string.format("TIME step %02d: NOTE needs a PITCH entry (P01).",step)}
        end
      else
        local index=(out.note_count-1)%pitches+1
        local p=pattern.pitch_events[index]
        out.used[index]=true
        current={index=index,note=p.note}
        out.mapping[step]={kind="note",pitch_index=index,note=p.note,
          accent=p.accent==true,slide=p.slide==true}
      end
    elseif command=="T" then
      out.mapping[step]={kind="tie",pitch_index=current and current.index or nil,
        note=current and current.note or nil}
    elseif command=="R" then
      out.mapping[step]={kind="rest"}
      current=nil
    else
      out.mapping[step]={kind="missing"}
      if not out.error then
        out.error={step=step,message=string.format(
          "TIME step %02d: choose NOTE, TIE or REST.",step)}
      end
    end
  end
  return out
end

function M.step_text(p, step)
  local v=p.mapping[step]
  if not v then return "--" end
  if v.missing_pitch then return "NOTE !PITCH" end
  if v.kind=="missing" then return "?? SET TIME" end
  if v.kind=="rest" then return "REST --" end
  if v.kind=="tie" then
    return v.note and string.format("TIE P%02d",v.pitch_index) or "TIE (silent)"
  end
  return string.format("NOTE P%02d:%d%s%s",v.pitch_index,v.note,
    v.accent and " A" or "",v.slide and " S" or "")
end

return M
