-- SPDX-License-Identifier: GPL-3.0-only
-- Song-scoped native change observers. Call refresh from the existing idle path.
local M={}

local PHRASE_PROPERTIES={
  "playback_mode","is_empty","number_of_lines","visible_note_columns",
  "visible_effect_columns","key_tracking","base_note","looping",
  "loop_start","loop_end","autoseek","lpb","shuffle",
  "instrument_column_visible","volume_column_visible","panning_column_visible",
  "delay_column_visible","sample_effects_column_visible",
}
local MAPPING_PROPERTIES={"key_tracking","base_note","note_range","looping","loop_start","loop_end"}
local INSTRUMENT_PHRASE_PROPERTIES={"phrase_playback_mode","phrase_program"}
local SCRIPT_PROPERTIES={
  "editor_visible","parameters","paragraphs","paragraphs_assignment",
  "pending_changes","committed",
}
local NOTE_COLUMN_COUNT=12

local function read_result(object,key)
  return pcall(function() return object[key] end)
end

local function read(object,key)
  local ok,value=read_result(object,key)
  if ok then return value end
end

function M.new()
  local observer={}
  local song,runtime,on_change,last_error
  local root_records,nested_records={},{ }
  local attachment_serial=0
  local pending_inventory_rebind=false
  local is_current_member

  local function remove(records,expected_serial,live_song)
    local complete=true
    for index=#records,1,-1 do
      local record=records[index]
      record.slot.object=nil
      if record.active then
        local ok,err=pcall(record.remove)
        if attachment_serial~=expected_serial then return false end
        if ok then
          record.active=false
        else
          local getter_ok=read_result(record.source,record.remove_key)
          if attachment_serial~=expected_serial then return false end
          local probe_ok,registered=true,true
          if record.probe then probe_ok,registered=pcall(record.probe) end
          if attachment_serial~=expected_serial then return false end
          -- Retire inaccessible host sources only after proving their owner was removed.
          local owner_state=nil
          if not getter_ok or not probe_ok then owner_state=is_current_member(record,live_song) end
          if attachment_serial~=expected_serial then return false end
          if (probe_ok and registered==false) or
              ((not getter_ok or not probe_ok) and owner_state==false) then
            record.active=false
          else
            complete=false
            record.remove_error=tostring(err)
          end
        end
      end
      if not record.active then table.remove(records,index) end
    end
    return complete
  end

  local function all_removed()
    return #root_records==0 and #nested_records==0
  end

  local function removal_error()
    for _,records in ipairs({nested_records,root_records}) do
      for _,record in ipairs(records) do
        if record.remove_error then return record.remove_error end
      end
    end
    return "unknown notifier removal error"
  end

  is_current_member=function(record,live_song)
    local owner_song=record.owner_song
    if owner_song==nil or live_song==nil then return nil end
    if not rawequal(live_song,owner_song) then return false end
    if record.owner_instrument==nil then return true end
    local instruments_ok,instruments=read_result(live_song,"instruments")
    if not instruments_ok or type(instruments)~="table" then return nil end
    local instrument_is_live=false
    for _,instrument in ipairs(instruments) do
      if rawequal(instrument,record.owner_instrument) then instrument_is_live=true;break end
    end
    if not instrument_is_live then return false end
    if record.owner_phrase==nil then return true end
    local phrases_ok,phrases=read_result(record.owner_instrument,"phrases")
    if not phrases_ok or type(phrases)~="table" then return nil end
    local phrase_is_live=false
    for _,phrase in ipairs(phrases) do
      if rawequal(phrase,record.owner_phrase) then phrase_is_live=true;break end
    end
    if not phrase_is_live then return false end
    if record.owner_mapping==nil then return true end
    local mappings_ok,mappings=read_result(record.owner_instrument,"phrase_mappings")
    if not mappings_ok or type(mappings)~="table" then return nil end
    for _,mapping in ipairs(mappings) do
      if rawequal(mapping,record.owner_mapping) then return true end
    end
    return false
  end

  local function register(records,record,subscribe,has_notifier)
    local registration_serial=attachment_serial
    record.probe=has_notifier
    record.active=false
    records[#records+1]=record
    local ok,err=pcall(subscribe)
    local function forget()
      for index=#records,1,-1 do
        if rawequal(records[index],record) then table.remove(records,index);return end
      end
    end
    local function retain()
      for _,candidate in ipairs(records) do
        if rawequal(candidate,record) then return end
      end
      records[#records+1]=record
    end
    local function cleanup()
      record.slot.object=nil
      local registered
      if has_notifier then
        local checked,result=pcall(has_notifier)
        if checked and type(result)=="boolean" then registered=result end
      end
      if registered==false then forget();return true end
      record.active=true
      local removed,remove_error=pcall(record.remove)
      if removed then forget();return true end
      record.remove_error=tostring(remove_error)
      retain()
      return false
    end
    if not ok then
      cleanup()
      return false,"notifier registration failed: "..tostring(err)
    end
    record.active=true
    if registration_serial~=attachment_serial or record.slot.object==nil or song==nil then
      if not cleanup() then return false,"attachment superseded and notifier cleanup failed" end
      return false,"attachment superseded during notifier registration"
    end
    return true
  end

  local function invalidate(reason)
    last_error=reason
    local target=runtime
    if target and type(target.set_observer_error)=="function" then
      pcall(target.set_observer_error,target,"Native observer failure: "..tostring(reason))
    end
  end

  local function classify_undo(current_song)
    local method=read(current_song,"is_undo_redoing")
    if type(method)~="function" then return false end
    local ok,result=pcall(method,current_song)
    return ok and result==true
  end

  local function is_render_temporary(instrument,phrase)
    if instrument==nil or phrase==nil or not runtime or
        type(runtime.occupancy_state)~="function" or type(runtime.is_temporary)~="function" then
      return false
    end
    local ok,state=pcall(runtime.occupancy_state,runtime)
    if not ok or type(state)~="table" or state.status~="busy" then return false end
    local checked,temporary=pcall(runtime.is_temporary,runtime,instrument,phrase)
    return checked and temporary==true
  end

  local function invalidate_external(change_kind,subject,inventory_kind,expected_serial,expected_runtime)
    if not expected_runtime then return false end
    if type(expected_runtime.notify_native_change)~="function" then
      if attachment_serial~=expected_serial or not rawequal(runtime,expected_runtime) then return false end
      invalidate("Runtime native change invalidation is unavailable")
      return false
    end
    local ok,err=pcall(expected_runtime.notify_native_change,expected_runtime,change_kind,subject,inventory_kind)
    if not ok then
      if attachment_serial~=expected_serial or not rawequal(runtime,expected_runtime) then return false end
      invalidate("Runtime native change invalidation failed: "..tostring(err))
      return false
    end
    return true
  end

  local function make_handler(slot,kind,temporary_instrument,inventory_kind)
    local registered_song,registered_runtime,registered_callback,registered_serial=song,runtime,on_change,attachment_serial
    return function()
      local subject=slot.object
      if subject==nil or song==nil or attachment_serial~=registered_serial or
          not rawequal(song,registered_song) or not rawequal(runtime,registered_runtime) then return end
      if kind=="content" and is_render_temporary(temporary_instrument,subject) then return end
      if kind=="rename" and temporary_instrument and is_render_temporary(temporary_instrument,subject) then return end

      local change_kind=classify_undo(registered_song) and "undo" or kind
      local internal=false
      if registered_runtime and type(registered_runtime.mutation_state)=="function" then
        local ok,state=pcall(registered_runtime.mutation_state,registered_runtime)
        internal=ok and type(state)=="table" and state.depth>0
      end
      local own_inventory=false
      if not internal and change_kind=="inventory" and inventory_kind and registered_runtime and
          type(registered_runtime.matches_mutation_inventory)=="function" then
        local ok,result=pcall(registered_runtime.matches_mutation_inventory,registered_runtime,subject,inventory_kind)
        own_inventory=ok and result==true
      end
      if kind=="inventory" then pending_inventory_rebind=true end
      if not internal and not own_inventory then
        invalidate_external(change_kind,subject,inventory_kind,registered_serial,registered_runtime)
      end
      if attachment_serial~=registered_serial or not rawequal(song,registered_song) or
          not rawequal(runtime,registered_runtime) or not rawequal(on_change,registered_callback) then return end
      if registered_callback then pcall(registered_callback,change_kind,subject,internal,inventory_kind) end
    end
  end

  local function add(records,source,kind,object,temporary_instrument,inventory_kind,owner_mapping)
    if source==nil then return false,"missing required observable" end
    local add_notifier=read(source,"add_notifier")
    local remove_notifier=read(source,"remove_notifier")
    if type(add_notifier)~="function" or type(remove_notifier)~="function" then
      return false,"observable is missing add_notifier or remove_notifier"
    end
    local slot={object=object}
    local handler=make_handler(slot,kind,temporary_instrument,inventory_kind)
    local owner_instrument=temporary_instrument
    local owner_phrase=temporary_instrument and object or nil
    if owner_instrument==nil and not rawequal(object,song) then owner_instrument=object end
    local record={source=source,handler=handler,slot=slot,remove_key="remove_notifier",
      owner_song=song,owner_instrument=owner_instrument,owner_phrase=owner_phrase,
      owner_mapping=owner_mapping,
      remove=function() source:remove_notifier(handler) end}
    local has_notifier=read(source,"has_notifier")
    local ok,err=register(records,record,function() source:add_notifier(handler) end,
      type(has_notifier)=="function" and function()
        return has_notifier(source,handler)
      end or nil)
    if not ok then return false,err end
    return true
  end

  local function add_required(records,source,kind,object,temporary_instrument,inventory_kind,label,owner_mapping)
    local ok,err=add(records,source,kind,object,temporary_instrument,inventory_kind,owner_mapping)
    if not ok then return false,(label or kind)..": "..tostring(err) end
    return true
  end

  local function add_phrase(records,instrument,phrase)
    local ok,err=add_required(records,read(phrase,"name_observable"),"rename",phrase,instrument,nil,"phrase name")
    if not ok then return false,err end
    for _,property in ipairs(PHRASE_PROPERTIES) do
      ok,err=add_required(records,read(phrase,property.."_observable"),"content",phrase,instrument,nil,
        "phrase "..property)
      if not ok then return false,err end
    end
    for _,property in ipairs({"column_name_observable","column_is_muted_observable"}) do
      local observable_for_column=read(phrase,property)
      if type(observable_for_column)~="function" then return false,"phrase is missing "..property end
      for column=1,NOTE_COLUMN_COUNT do
        local called,source=pcall(observable_for_column,phrase,column)
        if not called then return false,property.." failed for column "..column..": "..tostring(source) end
        ok,err=add_required(records,source,"content",phrase,instrument,nil,property)
        if not ok then return false,err end
      end
    end
    local add_line_notifier=read(phrase,"add_line_notifier")
    local remove_line_notifier=read(phrase,"remove_line_notifier")
    if type(add_line_notifier)~="function" or type(remove_line_notifier)~="function" then
      return false,"phrase is missing line notifier methods"
    end
    local slot={object=phrase}
    local handler=make_handler(slot,"content",instrument,nil)
    local record={source=phrase,handler=handler,slot=slot,remove_key="remove_line_notifier",
      owner_song=song,owner_instrument=instrument,owner_phrase=phrase,
      remove=function() phrase:remove_line_notifier(handler) end}
    local has_line_notifier=read(phrase,"has_line_notifier")
    local registered,line_error=register(nested_records,record,
      function() phrase:add_line_notifier(handler) end,
      type(has_line_notifier)=="function" and function()
        return has_line_notifier(phrase,handler)
      end or nil)
    if not registered then return false,"phrase line notifier: "..tostring(line_error) end

    local mapping_read,mapping=read_result(phrase,"mapping")
    if not mapping_read then return false,"phrase mapping read failed: "..tostring(mapping) end
    if mapping~=nil then
      for _,property in ipairs(MAPPING_PROPERTIES) do
        ok,err=add_required(records,read(mapping,property.."_observable"),"content",phrase,instrument,nil,
          "phrase mapping "..property,mapping)
        if not ok then return false,err end
      end
    end
    local script_read,script=read_result(phrase,"script")
    if not script_read then return false,"phrase script read failed: "..tostring(script) end
    if script~=nil then
      for _,property in ipairs(SCRIPT_PROPERTIES) do
        ok,err=add_required(records,read(script,property.."_observable"),"content",phrase,instrument,nil,
          "phrase script "..property)
        if not ok then return false,err end
      end
    end
    return true
  end

  local function add_instrument(records,instrument)
    local ok,err=add_required(records,read(instrument,"name_observable"),"rename",instrument,nil,nil,"instrument name")
    if not ok then return false,err end
    for _,property in ipairs(INSTRUMENT_PHRASE_PROPERTIES) do
      ok,err=add_required(records,read(instrument,property.."_observable"),"content",instrument,nil,nil,
        "instrument "..property)
      if not ok then return false,err end
    end
    ok,err=add_required(records,read(instrument,"phrases_observable"),"inventory",instrument,nil,"phrases",
      "instrument phrases")
    if not ok then return false,err end
    ok,err=add_required(records,read(instrument,"phrase_mappings_observable"),"inventory",instrument,nil,
      "phrase_mappings","instrument phrase mappings")
    if not ok then return false,err end
    local phrases_read,phrases=read_result(instrument,"phrases")
    if not phrases_read then return false,"instrument phrases list read failed: "..tostring(phrases) end
    if phrases==nil then return false,"instrument phrases list is unavailable" end
    local enumerated,enumeration_error=pcall(function()
      for _,phrase in ipairs(phrases) do
        local added,add_error=add_phrase(records,instrument,phrase)
        if not added then error(add_error) end
      end
    end)
    if not enumerated then return false,"instrument phrase enumeration failed: "..tostring(enumeration_error) end
    return true
  end

  local function add_nested(current_song)
    local instruments_read,instruments=read_result(current_song,"instruments")
    if not instruments_read then return false,"song instruments list read failed: "..tostring(instruments) end
    if instruments==nil then return false,"song instruments list is unavailable" end
    local enumerated,enumeration_error=pcall(function()
      for _,instrument in ipairs(instruments) do
        local added,add_error=add_instrument(nested_records,instrument)
        if not added then error(add_error) end
      end
    end)
    if not enumerated then return false,"song instrument enumeration failed: "..tostring(enumeration_error) end
    return true
  end

  local function detach(live_song)
    attachment_serial=attachment_serial+1
    local detaching_serial=attachment_serial
    local detached_runtime=runtime
    local nested_removed=remove(nested_records,detaching_serial,live_song)
    if attachment_serial~=detaching_serial then
      if song~=nil or all_removed() then return true end
      return false,last_error or ("native notifier removal failed: "..removal_error())
    end
    local root_removed=remove(root_records,detaching_serial,live_song)
    if attachment_serial~=detaching_serial then
      if song~=nil or all_removed() then return true end
      return false,last_error or ("native notifier removal failed: "..removal_error())
    end
    song,runtime,on_change=nil,nil,nil
    pending_inventory_rebind=false
    if not nested_removed or not root_removed then
      last_error="native notifier removal failed: "..removal_error()
      if detached_runtime and type(detached_runtime.set_observer_error)=="function" then
        pcall(detached_runtime.set_observer_error,detached_runtime,"Native observer failure: "..last_error)
      end
      return false,last_error
    end
    return true
  end

  function observer:attach(current_song,current_runtime,callback)
    assert(current_song~=nil,"A current song is required")
    assert(current_runtime==nil or type(current_runtime)=="table","Runtime must be a table")
    assert(callback==nil or type(callback)=="function","Change callback must be a function")
    local detach_serial=attachment_serial+1
    local detached,detach_error=detach(current_song)
    if attachment_serial~=detach_serial then return false,"attachment superseded during previous cleanup" end
    if not detached then
      local reason=detach_error or "previous native listeners could not be removed"
      if current_runtime and type(current_runtime.set_observer_error)=="function" then
        pcall(current_runtime.set_observer_error,current_runtime,"Native observer failure: "..tostring(reason))
      end
      return false,reason
    end
    if not all_removed() then
      last_error="previous native listeners could not be removed"
      if current_runtime and type(current_runtime.set_observer_error)=="function" then
        pcall(current_runtime.set_observer_error,current_runtime,"Native observer failure: "..last_error)
      end
      return false,last_error
    end
    attachment_serial=attachment_serial+1
    song,runtime,on_change=current_song,current_runtime,callback
    local attaching_serial=attachment_serial
    last_error=nil
    local ok,err=add_required(root_records,read(song,"instruments_observable"),"inventory",song,nil,"instruments",
      "song instruments")
    if ok then ok,err=add_required(root_records,read(song,"selected_instrument_observable"),"selection",song,nil,nil,
      "selected instrument") end
    if ok then ok,err=add_required(root_records,read(song,"selected_phrase_observable"),"selection",song,nil,nil,
      "selected phrase") end
    if ok then ok,err=add_nested(song) end
    if not ok then
      if attachment_serial~=attaching_serial then return false,err end
      invalidate(err)
      if attachment_serial==attaching_serial then self:detach() end
      return false,err
    end
    if runtime and type(runtime.set_observer_error)=="function" then
      local cleared,clear_error=pcall(runtime.set_observer_error,runtime,nil)
      if attachment_serial~=attaching_serial or not rawequal(song,current_song) or
          not rawequal(runtime,current_runtime) then
        return false,"attachment superseded during readiness update"
      end
      if not cleared then
        invalidate("runtime rejected observer readiness: "..tostring(clear_error))
        self:detach()
        return false,last_error
      end
    end
    if attachment_serial~=attaching_serial or not rawequal(song,current_song) or
        not rawequal(runtime,current_runtime) then
      return false,"attachment superseded during readiness update"
    end
    last_error=nil
    return true
  end

  function observer:refresh()
    if song==nil then return false end
    local attached_serial=attachment_serial
    if pending_inventory_rebind then
      pending_inventory_rebind=false
      local live_song=song
      local removed=remove(nested_records,attached_serial,live_song)
      if attachment_serial~=attached_serial then return false end
      if not removed then
        invalidate("nested native listeners could not be removed for inventory rebind")
        return false
      end
      local ok,err=add_nested(song)
      if not ok then
        if attachment_serial~=attached_serial then return false end
        invalidate(err)
        if attachment_serial==attached_serial then self:detach() end
        return false
      end
    end
    return true
  end

  function observer:detach() return detach(song) end

  function observer:state()
    return {attached=song~=nil,listener_count=#root_records+#nested_records,error=last_error}
  end

  return observer
end

return M
