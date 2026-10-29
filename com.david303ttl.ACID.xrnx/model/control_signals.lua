-- SPDX-License-Identifier: GPL-3.0-only
-- Physical gate edges in 256 subdivisions per sequencer step.
local compiler=require("model.cycle_interpreter")
local policies=require("model.policies")
-- Articulation timeline units are independent of phrase-line resolution.
local M={UNITS_PER_STEP=256,DEFAULT_GATE_FRACTION=0.5}
local UNITS_PER_STEP=M.UNITS_PER_STEP
local ROUND_HALF_UP=0.5

local function plain(value,active)
  if type(value)~="table" then return type(value)~="function" and type(value)~="userdata" end
  active=active or {}
  if getmetatable(value) or active[value] then return false end
  active[value]=true
  for key,item in pairs(value) do
    if (type(key)~="string" and type(key)~="number") or not plain(item,active) then return false end
  end
  active[value]=nil
  return true
end

local function copy(value)
  if type(value)~="table" then return value end
  local result={}
  for key,item in pairs(value) do result[key]=copy(item) end
  return result
end

local function equal(a,b,semantic)
  if type(a)~=type(b) then return false end
  if type(a)~="table" then return a==b end
  for key,value in pairs(a) do
    if not (semantic and (key=="cycle" or key=="absolute_step" or key=="origin_cycle")) and
        not equal(value,b[key],semantic) then return false end
  end
  for key in pairs(b) do
    if not (semantic and (key=="cycle" or key=="absolute_step" or key=="origin_cycle")) and a[key]==nil then return false end
  end
  return true
end

local function complete(plan)
  if type(plan)~="table" or not plain(plan) or type(plan.steps)~="table" or
      not policies.is_integer(plan.length) or plan.length<1 or #plan.steps~=plan.length then return false end
  for step,event in ipairs(plan.steps) do
    if type(event)~="table" or event.step~=step or
      (event.kind~="note" and event.kind~="tie" and event.kind~="rest") then return false end
    if event.kind=="note" and not policies.in_integer_range(event.note,0,119) then return false end
    if event.cycle~=nil and (not policies.is_integer(event.cycle) or event.cycle<1) then return false end
  end
  if plan.cycle~=nil and (not policies.is_integer(plan.cycle) or plan.cycle<1) then return false end
  if plan.loop~=nil and (type(plan.loop)~="table" or not complete(plan.loop.cold) or
      not complete(plan.loop.steady) or not complete(plan.loop.verification)) then return false end
  return true
end

function M.validate_association(semantic,timeline)
  if not complete(semantic) or type(timeline)~="table" or
      not complete(timeline.semantic) or not plain(timeline) or timeline.steps~=semantic.length or
      not equal(semantic,timeline.semantic) or type(timeline.association)~="table" or
      not equal(timeline.semantic,timeline.association.semantic) or
      not equal(timeline.successor,timeline.association.successor) or
      not equal(timeline.events,timeline.association.events) then
    return nil,"gate timeline does not match the semantic plan"
  end
  if semantic.loop and not equal(semantic.loop.steady,timeline.successor) then
    return nil,"gate timeline does not match the successor cycle"
  end
  if timeline.output_policy=="repeat" and not complete(timeline.successor) then
    return nil,"gate timeline requires a complete successor cycle"
  end
  return true
end

local function add(out,at,kind,ev,more)
  local e={at=at,kind=kind,step=ev.source_step or ev.step,cycle=ev.cycle}
  if more then for k,v in pairs(more) do e[k]=v end end
  out[#out+1]=e
end

function M.compile(pattern,options)
  options=options or {}
  if type(options)~="table" then return nil,"gate scheduling options must be a table" end
  local fraction=options.gate_fraction or M.DEFAULT_GATE_FRACTION
  if type(fraction)~="number" or fraction<=0 or fraction>=1 or fraction~=fraction then
    return nil,"gate_fraction must be between 0 and 1"
  end
  local output_policy=options.output_policy or policies.DEFAULT_OUTPUT_POLICY
  if not policies.valid_output_policy(output_policy) then
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
  if not complete(plan) then
    return nil,"gate scheduling requires a complete semantic cycle"
  end
  if successor and not complete(successor) then
    return nil,"gate scheduling requires a complete successor cycle"
  end
  if plan.loop and not equal(plan.loop.steady,successor) then
    return nil,"gate scheduling successor does not match the semantic plan"
  end
  if successor then
    local tail=plan.steps[plan.length]
    local expected=compiler.compile_cycle(pattern,{cycle=(tail.cycle or plan.cycle or 1)+1,
      next_pitch=1,voice=tail.voice,hold_intent=tail.hold_intent})
    if not expected or not equal(expected.steps,successor.steps,true) then
      return nil,"gate scheduling successor does not follow the semantic plan"
    end
  end
  local first=plan.steps[1]
  -- A preceding fresh attack already received its midpoint release. Only
  -- connected transitions and held/rest boundaries inherit a physical gate.
  local gate=first.transition=="slide" or first.holds==true or first.releases==true
  local note=first.from_note or (gate and (first.note or first.released_note)) or nil
  local events={}
  local gap=math.floor(UNITS_PER_STEP*fraction+ROUND_HALF_UP)
  for step,ev in ipairs(plan.steps) do
    local start=(step-1)*UNITS_PER_STEP
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
  return {events=events,steps=plan.length,units_per_step=UNITS_PER_STEP,
    gate_fraction=fraction,boundary=plan.boundary,output_policy=output_policy,
    open_at_end=gate,final_note=note,semantic=copy(plan),successor=copy(successor),
    association={semantic=copy(plan),successor=copy(successor),events=copy(events)}}
end

-- Return exactly representable midpoint edges; REST edges belong to the
-- semantic renderer and remain in the timeline for merged-plan validation.
function M.release_lines(timeline,lines_per_step)
  if type(lines_per_step)~="number" or lines_per_step%1~=0 or lines_per_step<1
    or lines_per_step~=lines_per_step then
    return nil,"gate output requires a positive integer lines-per-step"
  end
  -- Every non-REST release sits a fixed gate width past a step start, so the
  -- width alone decides whether releases can land on phrase lines.
  local gap=math.floor(UNITS_PER_STEP*(timeline.gate_fraction or M.DEFAULT_GATE_FRACTION)+ROUND_HALF_UP)
  if (gap*lines_per_step)%UNITS_PER_STEP~=0 then
    return nil,"gate width is not representable on a phrase line at this resolution"
  end
  local lines={}
  for _,ev in ipairs(timeline.events) do
    if ev.kind=="gate_off" and ev.reason~="rest" then
      if ev.at<0 or ev.at>=timeline.steps*UNITS_PER_STEP then
        return nil,"gate edge is not representable inside the phrase"
      end
      if (ev.at*lines_per_step)%UNITS_PER_STEP~=0 then
        return nil,"gate edge is not representable on a phrase line at this resolution"
      end
      lines[#lines+1]=math.floor(ev.at*lines_per_step/UNITS_PER_STEP)+1
    end
  end
  return lines
end

return M
