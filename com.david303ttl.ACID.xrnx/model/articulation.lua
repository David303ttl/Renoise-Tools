-- SPDX-License-Identifier: GPL-3.0-only
-- Place note-column glide effects; sample voice continuity is not guaranteed.
local M = {}
M.DEFAULT_RATE = 0x20
local MIN_LINES_PER_STEP=2

local function integer(value, minimum, maximum)
  return type(value)=="number" and value%1==0 and value>=minimum and value<=maximum
end

function M.plan(plan, lines_per_step, rate)
  if type(plan) ~= "table" or type(plan.steps) ~= "table"
    or type(plan.length) ~= "number" or plan.length % 1 ~= 0
    or type(lines_per_step) ~= "number" or lines_per_step % 1 ~= 0
    or lines_per_step < MIN_LINES_PER_STEP then
    return nil, "invalid glide plan or step resolution"
  end
  rate=rate or M.DEFAULT_RATE
  if not integer(rate,1,255) then return nil,"glide rate must be 01..FF" end
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
      local span=rate==255 and 1 or math.max(1,math.ceil(math.abs(interval)*16/rate))
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

return M
