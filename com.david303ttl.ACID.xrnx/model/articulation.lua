-- Place note-column glide effects; sample voice continuity is not guaranteed.
local M = {}

function M.plan(plan, lines_per_step, rate)
  if type(plan) ~= "table" or type(plan.steps) ~= "table"
    or type(plan.length) ~= "number" or plan.length % 1 ~= 0
    or type(lines_per_step) ~= "number" or lines_per_step % 1 ~= 0
    or lines_per_step < 2 then
    return nil, "invalid glide plan or step resolution"
  end
  rate = rate or 0x20
  if type(rate) ~= "number" or rate % 1 ~= 0
    or rate < 1 or rate > 254 then
    return nil, "glide rate must be 01..FE"
  end
  local commands = {}
  for step=1,plan.length do
    local event = plan.steps[step]
    if not event or event.step ~= step then
      return nil, "missing semantic step " .. step
    end
    if event.kind == "note" and event.transition == "slide" then
      if type(event.from_note) ~= "number"
        or type(event.note) ~= "number" then
        return nil, "slide requires explicit source and target"
      end
      local target_line = (step-1) * lines_per_step + 1
      -- Apply Gxx at the target pitch and G00 on the following line.
      commands[#commands+1] = {
        line=target_line, note=event.note, command="0G", amount=rate,
        step=step, time_step=event.source_step or event.step or step,
        cycle=event.cycle, pitch_index=event.pitch_index, kind="glide"
      }
      commands[#commands+1] = {
        line=target_line+1, note=nil, command="0G", amount=0,
        step=step, time_step=event.source_step or event.step or step,
        cycle=event.cycle, pitch_index=event.pitch_index, kind="continuation"
      }
    end
  end
  return commands
end

function M.apply(phrase, plan, lines_per_step, rate, early_release)
  if lines_per_step~=2 then return nil,"articulation output requires 2 lines per step" end
  local commands,err=M.plan(plan,lines_per_step,rate)
  if not commands then return nil,err end
  local control=require("model.control_signals")
  local gates=require("writers.gate_writer")
  local timeline={events={},steps=plan.length,gate_fraction=0.5}
  if early_release then
    timeline,err=control.compile({}, {plan=plan,playback="one_shot",gate_fraction=0.5})
    if not timeline then return nil,err end
  end
  local merged
  merged,err=gates.plan(timeline,plan,commands)
  if not merged then return nil,err end
  local applied
  applied,err=gates.apply_plan(phrase,merged)
  if not applied then return nil,err end
  return {slide_count=#commands/2,early_releases=applied.early_releases,
    commands=#merged.operations,rate=rate or 0x20,skipped_continuations={}}
end

return M
