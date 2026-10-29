local control=require("model.control_signals")
local legato=require("model.legato")
local function copy(value)
  if type(value)~="table" then return value end
  local result={}
  for key,item in pairs(value) do result[key]=copy(item) end
  return result
end

return function(semantic,timeline,layout,options)
  if not timeline.semantic then
    local steps=semantic.steps or {}
    for step=1,timeline.steps do
      steps[step]=steps[step] or {kind="rest",step=step}
    end
    for _,event in ipairs(timeline.events) do
      if event.kind=="gate_on" or event.kind=="pitch_target" then
        local step=event.step
        if type(step)~="number" or not steps[step] then return nil,"invalid fixture step" end
        steps[step].kind="note"
        steps[step].note=event.note
        steps[step].accent=event.accent
      end
    end
    semantic.steps,semantic.length=steps,timeline.steps
    local compiled=assert(control.compile({}, {plan=semantic,output_policy="play_once"}))
    compiled.events=timeline.events
    compiled.association.events=copy(timeline.events)
    timeline=compiled
  end
  return legato.plan(semantic,timeline,layout,options)
end
