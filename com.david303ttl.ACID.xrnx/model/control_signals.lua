-- Physical gate edges in 256 subdivisions per sequencer step.
local compiler=require("model.cycle_interpreter")
local M={}

local function add(out,at,kind,ev,more)
  local e={at=at,kind=kind,step=ev.source_step or ev.step,cycle=ev.cycle}
  if more then for k,v in pairs(more) do e[k]=v end end
  out[#out+1]=e
end

function M.compile(pattern,options)
  options=options or {}
  local fraction=options.gate_fraction or 0.5
  if type(fraction)~="number" or fraction<=0 or fraction>=1 or fraction~=fraction then
    return nil,"gate_fraction must be between 0 and 1"
  end
  local output_policy=options.output_policy or "repeat"
  if output_policy~="repeat" and output_policy~="play_once" then
    return nil,"output_policy must be repeat or play_once"
  end
  local plan,successor=options.plan,options.successor
  if not plan then
    local exit
    plan,exit=compiler.compile_cycle(pattern)
    if not plan then return nil,exit end
    successor=compiler.compile_cycle(pattern,exit)
  end
  if output_policy=="repeat" and not successor then
    return nil,"Repeat gate scheduling requires an explicit successor cycle"
  end
  if not plan.steps or not plan.steps[1] or #plan.steps~=plan.length then
    return nil,"gate scheduling requires a complete semantic cycle"
  end
  if successor and (not successor.steps or not successor.steps[1]) then
    return nil,"gate scheduling requires a complete successor cycle"
  end
  local first=plan.steps[1]
  -- A preceding fresh attack already received its midpoint release. Only
  -- connected transitions and held/rest boundaries inherit a physical gate.
  local gate=first.transition=="slide" or first.holds==true or first.releases==true
  local note=first.from_note or (gate and (first.note or first.released_note)) or nil
  local events={}
  local gap=math.floor(256*fraction+0.5)
  for step,ev in ipairs(plan.steps) do
    local start=(step-1)*256
    if ev.kind=="note" then
      if gate and ev.transition=="slide" then
        add(events,start,"pitch_target",ev,{note=ev.note,from_note=note,
          accent=ev.accent,slide=true})
      else
        add(events,start,"gate_on",ev,{note=ev.note,accent=ev.accent})
      end
      gate,note=true,ev.note
    elseif ev.kind=="tie" then
      if gate then add(events,start,"tie",ev,{note=note}) end
    elseif ev.kind=="rest" then
      if gate then
        add(events,start,"gate_off",ev,{reason="rest",note=note})
      end
      gate,note=false,nil
      add(events,start,"rest",ev)
    end
    local next_ev=plan.steps[step+1]
    if not next_ev and output_policy=="repeat" then next_ev=successor.steps[1] end
    if gate and (not next_ev or (next_ev.kind=="note" and next_ev.transition~="slide")) then
      add(events,start+gap,"gate_off",ev,
        {reason=next_ev and "retrigger" or "tail",note=note})
      gate,note=false,nil
    end
  end
  return {events=events,steps=plan.length,units_per_step=256,
    gate_fraction=fraction,boundary=plan.boundary,output_policy=output_policy,
    open_at_end=gate,final_note=note,semantic=plan,successor=successor}
end

-- Return exactly representable midpoint edges; REST edges belong to the
-- semantic renderer and remain in the timeline for merged-plan validation.
function M.release_lines(timeline,lines_per_step)
  if lines_per_step~=2 or timeline.gate_fraction~=0.5 then
    return nil,"gate output requires 2 lines per step and 50% gate"
  end
  local lines={}
  for _,ev in ipairs(timeline.events) do
    if ev.kind=="gate_off" and ev.reason~="rest" then
      if ev.at%128~=0 or ev.at<0 or ev.at>=timeline.steps*256 then
        return nil,"gate edge is not representable inside the phrase"
      end
      lines[#lines+1]=ev.at/128+1
    end
  end
  return lines
end

return M
