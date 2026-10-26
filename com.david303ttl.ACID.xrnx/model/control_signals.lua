-- ACID 0.1 experimental control-signal timeline, independent of Renoise.
-- Units: 256 subdivisions per sixteenth step. Gate fraction is a test
-- parameter, NOT a claim about original hardware timing.
local compiler=require("model.compiler")
local M={}

local function add(out,at,kind,more)
  local e={at=at,kind=kind}
  if more then for k,v in pairs(more) do e[k]=v end end
  out[#out+1]=e
end

function M.compile(pattern,options)
  options=options or {}
  local fraction=options.gate_fraction or 0.5
  if type(fraction)~="number" or fraction<=0 or fraction>=1
    or fraction~=fraction then
    return nil,"gate_fraction must be between 0 and 1"
  end
  local plan,err=compiler.compile(pattern)
  if not plan then return nil,err end
  local events={}
  local gate=false
  local note=nil
  local last_sustained_step=nil
  local gap=math.floor(256*fraction+0.5)
  for step,ev in ipairs(plan.steps) do
    local start=(step-1)*256
    if ev.kind=="note" then
      if gate and ev.transition~="slide" then
        -- Release in the latter part of the preceding NOTE/TIE step,
        -- leaving a gap before a fresh attack.
        add(events,(last_sustained_step-1)*256+gap,"gate_off",
          {reason="retrigger",note=note})
        gate=false
      end
      if not gate then
        add(events,start,"gate_on",{note=ev.note,accent=ev.accent,
          step=step})
        gate=true
      else
        add(events,start,"pitch_target",{note=ev.note,from_note=note,
          accent=ev.accent,slide=true,step=step})
      end
      note=ev.note
      last_sustained_step=step
    elseif ev.kind=="tie" then
      if gate then
        add(events,start,"tie",{note=note,step=step})
        last_sustained_step=step
      end
    elseif ev.kind=="rest" then
      if gate then
        add(events,start,"gate_off",{reason="rest",note=note,step=step})
        gate=false
        note=nil
      end
      add(events,start,"rest",{step=step})
    end
  end
  table.sort(events,function(a,b)
    if a.at~=b.at then return a.at<b.at end
    return a.kind<b.kind
  end)
  return {
    events=events,steps=plan.length,units_per_step=256,
    gate_fraction=fraction,boundary=plan.boundary,
    open_at_end=gate,final_note=note,semantic=plan
  }
end

-- Output positions for a two-lines-per-step Renoise phrase. Exact
-- fractional placement is intentionally not approximated: reject until
-- note-delay gate scheduling is supported.
function M.release_lines(timeline,lines_per_step)
  if lines_per_step~=2 or timeline.gate_fraction~=0.5 then
    return nil,"only 2 lines per step and 50% gate supported for test output"
  end
  local lines={}
  for _,ev in ipairs(timeline.events) do
    if ev.kind=="gate_off" and ev.reason=="retrigger" then
      -- Gate ends halfway through the last held step.
      local step=math.floor(ev.at/256)
      local line=step*2+2
      lines[#lines+1]=line
    end
  end
  return lines
end

return M
