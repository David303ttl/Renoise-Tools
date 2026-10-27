-- Pure projection of canonical ACID memories into the paged editor.
local seq = require("model.sequencer")
local interpreter = require("model.cycle_interpreter")
local M = { PAGE_SIZE=seq.PAGE_SIZE, MAX_PAGES=seq.MAX_STEPS/seq.PAGE_SIZE }

function M.page_for(index)
  assert(type(index)=="number" and index%1==0 and index>=1 and index<=64)
  return math.floor((index-1)/16)+1
end

function M.index_on_page(page, cell)
  assert(type(page)=="number" and page%1==0 and page>=1 and page<=4)
  assert(type(cell)=="number" and cell%1==0 and cell>=1 and cell<=16)
  return (page-1)*16+cell
end

local function missing_step(pattern)
  for step=1,pattern.length do
    if pattern.time_events[step]==nil then return step end
  end
end

function M.project(pattern)
  local out={length=type(pattern)=="table" and pattern.length or 0,
    mapping={},repeat_mapping={},used={},note_count=0,error=nil}
  if type(pattern)~="table" then
    out.error={message="pattern must be a table"}
    return out
  end
  local absent=type(pattern.time_events)=="table" and missing_step(pattern)
  if absent then
    out.error={step=absent,message=string.format(
      "TIME step %02d: choose NOTE, TIE or REST.",absent)}
    return out
  end
  local ok,err=seq.validate(pattern)
  if not ok then
    out.error={message=err}
    local entry=string.match(err,"pitch entry (%d+)") or
      string.match(err,"at entry (%d+)")
    local step=string.match(err,"step (%d+)")
    if entry then out.error.pitch_index=tonumber(entry) end
    if step then out.error.step=tonumber(step) end
    if err=="leading TIE must be entered as NOTE" then
      out.error.step=1
      out.error.message="TIME step 01: leading TIE is entered as NOTE."
    end
    return out
  end
  local plans,compile_error=interpreter.compile_cycles(pattern,2)
  if not plans then
    out.error={message=compile_error}
    local step=tonumber(tostring(compile_error):match("TIME step (%d+)"))
    if step then out.error.step=step end
    if tostring(compile_error):find("complete active pitch span",1,true) then
      for i,command in ipairs(pattern.time_events) do
        if command=="N" then
          out.error.step=i
          out.error.pitch_index=1
          out.error.message=string.format("TIME step %02d: active PITCH span is incomplete.",i)
          out.mapping[i]={kind="note",missing_pitch=true}
          break
        end
      end
    end
    return out
  end
  for cycle=1,2 do
    local mapping=cycle==1 and out.mapping or out.repeat_mapping
    for step,event in ipairs(plans[cycle].steps) do
      mapping[step]=event
      if cycle==1 and event.kind=="note" then
        out.note_count=out.note_count+1
        out.used[event.pitch_index]=true
      end
    end
  end
  return out
end

function M.step_text(projection, step, cycle)
  local mapping=cycle==2 and projection.repeat_mapping or projection.mapping
  local event=mapping and mapping[step]
  if not event then return "--" end
  if event.missing_pitch then return "NOTE !PITCH" end
  if event.kind=="rest" then return "REST --" end
  if event.kind=="tie" then
    return event.note and string.format("TIE P%02d",event.pitch_index) or "TIE (silent)"
  end
  local transition=event.transition=="attack" and " A" or
    event.transition=="slide" and " S" or " X"
  return string.format("NOTE P%02d:%d%s%s%s",event.pitch_index,event.note,
    event.accent and " ACC" or "",event.slide and " OUT" or "",transition)
end

return M
