-- SPDX-License-Identifier: GPL-3.0-only
-- Revision and arming decisions; callers perform the returned effects.
local M={}

function M.new()
  local target_revision,edit_revision,operation_serial=0,0,0
  local armed=false
  local instrument,phrase,target_kind=nil,nil,nil
  local active_trigger=nil
  local engine={}

  local function state()
    return {target_revision=target_revision,edit_revision=edit_revision,
      operation_serial=operation_serial,armed=armed}
  end

  local function invalidate(effects,scope)
    effects.revoke=scope or "all"
    if scope~="live" or active_trigger=="live" then
      operation_serial=operation_serial+1
      active_trigger=nil
    end
  end

  -- Target/native events carry exact objects and an explicit kind. Refresh
  -- carries semantic_changed after fresh classification. Editor events carry
  -- changed, valid and eligible booleans; no callback or sink runs here.
  function engine:transition(kind,values)
    values=values or {}
    assert(type(values)=="table","Transition values must be a table")
    local effects={}
    if kind=="target" or kind=="native_target" then
      local changed=not rawequal(instrument,values.instrument)
        or not rawequal(phrase,values.phrase) or target_kind~=values.kind
        or values.semantic_changed==true
      if changed then
        effects.preserve_draft=true
        invalidate(effects)
        target_revision=target_revision+1
        instrument,phrase,target_kind=values.instrument,values.phrase,values.kind
        effects.bind=true
      end
      effects.refresh=true
    elseif kind=="refresh" then
      effects.refresh=true
      if values.semantic_changed==true then
        target_revision=target_revision+1
        invalidate(effects)
        effects.detach_draft=true
      end
    elseif kind=="edit" then
      if values.changed==true then
        edit_revision=edit_revision+1
        invalidate(effects)
        effects.preserve_draft=true
        effects.live_intent=armed and values.valid==true and values.eligible==true
      end
    elseif kind=="programmatic" or kind=="reset" or kind=="recovery" then
      invalidate(effects)
      if values.changed==true then edit_revision=edit_revision+1 end
      effects.preserve_draft=true
    elseif kind=="arm" then
      armed=true
    elseif kind=="disarm" then
      armed=false
      invalidate(effects,"live")
    elseif kind=="request" then
      assert(values.trigger=="manual" or values.trigger=="live","Invalid generation trigger")
      effects.request=values.trigger=="manual" or armed
      if effects.request then
        invalidate(effects)
        active_trigger=values.trigger
      end
    elseif kind=="independence" then
      invalidate(effects)
      effects.independence_intent=true
    elseif kind=="external" or kind=="undo" then
      invalidate(effects)
      effects.reconcile=true
      if values.semantic_changed==true then target_revision=target_revision+1 end
      effects.detach_draft=values.semantic_changed==true
    elseif kind=="close" or kind=="blocker" then
      invalidate(effects)
    elseif kind=="completion" then
      local matching=active_trigger~=nil and values.operation_serial==operation_serial
      effects.apply_success=matching and values.success==true
        and values.target_revision==target_revision and values.edit_revision==edit_revision
      effects.reconcile=values.success==true
      if matching then active_trigger=nil end
    else
      error("Unknown runtime transition: "..tostring(kind),0)
    end
    effects.revisions=state()
    return effects
  end

  function engine:revision_state() return state() end

  function engine:release()
    instrument,phrase,target_kind=nil,nil,nil
    armed=false
    active_trigger=nil
    target_revision,edit_revision,operation_serial=0,0,0
  end

  return engine
end

return M
