-- Place note-column glide effects; sample voice continuity is not guaranteed.
local M = {}
M.DEFAULT_RATE = 0x20

local function integer(value, minimum, maximum)
  return type(value)=="number" and value%1==0 and value>=minimum and value<=maximum
end

function M.plan(plan, lines_per_step, rate)
  if type(plan) ~= "table" or type(plan.steps) ~= "table"
    or type(plan.length) ~= "number" or plan.length % 1 ~= 0
    or type(lines_per_step) ~= "number" or lines_per_step % 1 ~= 0
    or lines_per_step < 2 then
    return nil, "invalid glide plan or step resolution"
  end
  rate=rate or M.DEFAULT_RATE
  if not integer(rate,1,254) then return nil,"glide rate must be 01..FE" end
  local commands = {}
  for step=1,plan.length do
    local event = plan.steps[step]
    if not event or event.step ~= step then
      return nil, "missing semantic step " .. step
    end
    if event.kind == "note" and event.transition == "slide" then
      if not integer(event.from_note,0,119)
        or not integer(event.note,0,119) then
        return nil, "slide requires explicit source and target"
      end
      local target_line = (step-1) * lines_per_step + 1
      local locator=string.format("TIME step %02d, cycle %d, phrase line 0x%02X",
        event.source_step or event.step,event.cycle or 1,target_line-1)
      local interval=event.note-event.from_note
      -- Native Gxx advances xx sixteenths of a semitone per command line.
      -- This determines command coverage, not acoustic settling or continuity.
      local span=math.max(1,math.ceil(math.abs(interval)*16/rate))
      local available=lines_per_step
      for successor=step+1,plan.length do
        local held=plan.steps[successor]
        if not held or held.kind~="tie" or not held.holds then break end
        available=available+lines_per_step
      end
      if span>available then
        return nil,locator..": glide interval "..interval.." requires "..span..
          " command lines, only "..available.." before next NOTE/REST or phrase end"
      end
      for offset=0,span-1 do
        -- G00 continues the last rate; it does not cancel glide.
        commands[#commands+1] = {
        line=target_line+offset, note=offset==0 and event.note or nil,
        command="0G", amount=offset==0 and rate or 0,
        step=step, time_step=event.source_step or event.step or step,
        cycle=event.cycle, pitch_index=event.pitch_index,
        kind=offset==0 and "glide" or "continuation"
        }
      end
    end
  end
  return commands
end

function M.apply(phrase, plan, lines_per_step, rate, options)
  if lines_per_step~=2 then return nil,"articulation output requires 2 lines per step" end
  options=options or {}
  if type(options)~="table" then return nil,"invalid articulation output options" end
  local commands,err=M.plan(plan,lines_per_step,rate)
  if not commands then return nil,err end
  local control=require("model.control_signals")
  local gates=require("writers.gate_writer")
  local timeline
  timeline,err=control.compile({}, {plan=plan,successor=options.successor,
    output_policy=options.output_policy or "repeat",gate_fraction=0.5})
  if not timeline then return nil,err end
  local merged
  merged,err=gates.plan(timeline,plan,commands)
  if not merged then return nil,err end
  local applied
  applied,err=gates.apply_plan(phrase,merged)
  if not applied then return nil,err end
  local count=0
  for _,command in ipairs(commands) do if command.kind=="glide" then count=count+1 end end
  return {slide_count=count,early_releases=applied.early_releases,
    commands=#merged.operations,rate=rate or M.DEFAULT_RATE,skipped_continuations={}}
end

return M
