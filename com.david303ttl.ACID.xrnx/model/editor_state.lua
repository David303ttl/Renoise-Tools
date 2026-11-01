-- SPDX-License-Identifier: GPL-3.0-only
-- Pure projection of canonical ACID memories into the paged editor.
local seq = require("model.sequencer")
local interpreter = require("model.cycle_interpreter")
local policies = require("model.policies")
local M = { PAGE_SIZE=seq.PAGE_SIZE, MAX_PAGES=seq.MAX_STEPS/seq.PAGE_SIZE }

local function checked_pb_range(value)
  value=value==nil and policies.DEFAULT_PB_RANGE or value
  assert(policies.valid_pb_range(value),"invalid PB range")
  return value
end

function M.page_for(index)
  assert(policies.in_integer_range(index,1,seq.MAX_STEPS))
  return math.floor((index-1)/seq.PAGE_SIZE)+1
end

function M.index_on_page(page, cell)
  assert(policies.in_integer_range(page,1,M.MAX_PAGES))
  assert(policies.in_integer_range(cell,1,seq.PAGE_SIZE))
  return (page-1)*seq.PAGE_SIZE+cell
end

local function missing_step(pattern)
  for step=1,pattern.length do
    if pattern.time_events[step]==nil then return step end
  end
end

function M.project(pattern,prepared)
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
  local plans,compile_error=interpreter.compile_cycles(pattern,2,nil,prepared)
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
  out.plan=plans[1]
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

local copy_source=seq.copy_source

local function same_state(a,b)
  return a.output_policy==b.output_policy and a.pb_range==b.pb_range and
    a.label==b.label and a.label_custom==b.label_custom and seq.same_source(a.pattern,b.pattern)
end

local function snapshot(pattern,output_policy,pb_range,label,label_custom)
  return {pattern=copy_source(pattern),output_policy=output_policy,
    pb_range=checked_pb_range(pb_range),label=label or "Untitled",label_custom=label_custom==true}
end

function M.classify_difference(left,right)
  if type(left)~="table" or type(right)~="table" then return "mixed" end
  local musical=not seq.same_source(left.pattern or left.source,right.pattern or right.source) or
    left.output_policy~=right.output_policy or left.pb_range~=right.pb_range
  local metadata=(left.label or "Untitled")~=(right.label or "Untitled") or
    (left.label_custom==true)~=(right.label_custom==true)
  if musical and metadata then return "mixed" end
  if musical then return "musical_or_output" end
  if metadata then return "label_only" end
  return "unchanged"
end

function M.new_history(pattern,output_policy,pb_range,label,label_custom)
  local history={states={snapshot(pattern,output_policy,pb_range,label,label_custom)},position=1,revision=0}
  local proposals=setmetatable({},{__mode="k"})
  function history:record(next_pattern,next_policy,next_pb_range,next_label,next_custom)
    local next_state=snapshot(next_pattern,next_policy,next_pb_range,next_label,next_custom)
    if same_state(self.states[self.position],next_state) then return false end
    for i=#self.states,self.position+1,-1 do self.states[i]=nil end
    self.states[#self.states+1]=next_state
    self.position=#self.states
    self.revision=self.revision+1
    return true
  end
  function history:propose(direction)
    local position=self.position+(direction=="undo" and -1 or direction=="redo" and 1 or 0)
    if position<1 or position>#self.states or position==self.position then return nil end
    local proposal={position=position,revision=self.revision,state=snapshot(
      self.states[position].pattern,self.states[position].output_policy,
      self.states[position].pb_range,self.states[position].label,self.states[position].label_custom)}
    proposals[proposal]={position=position,revision=self.revision}
    return proposal
  end
  function history:commit(proposal)
    local captured=type(proposal)=="table" and proposals[proposal]
    if not captured or proposal.revision~=self.revision or captured.revision~=self.revision or
        proposal.position~=captured.position or captured.position<1 or
        captured.position>#self.states then return false end
    self.position=captured.position
    proposals[proposal]=nil
    self.revision=self.revision+1
    return true
  end
  function history:undo()
    if self.position<=1 then return nil end
    self.position=self.position-1
    local state=self.states[self.position]
    self.revision=self.revision+1
    return copy_source(state.pattern),state.output_policy,state.pb_range,state.label,state.label_custom
  end
  function history:redo()
    if self.position>=#self.states then return nil end
    self.position=self.position+1
    local state=self.states[self.position]
    self.revision=self.revision+1
    return copy_source(state.pattern),state.output_policy,state.pb_range,state.label,state.label_custom
  end
  function history:can_undo() return self.position>1 end
  function history:can_redo() return self.position<#self.states end
  function history:reset(current_pattern,current_policy,current_pb_range,current_label,current_custom)
    self.states={snapshot(current_pattern,current_policy,current_pb_range,current_label,current_custom)}
    self.position=1
    self.revision=self.revision+1
  end
  return history
end

return M
