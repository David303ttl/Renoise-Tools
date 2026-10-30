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
local NOTE_COLUMN_COUNT=12

local function read(object,key)
  local ok,value=pcall(function() return object[key] end)
  if ok then return value end
end

function M.new()
  local observer={}
  local song,runtime,on_change
  local root_records,nested_records={},{}
  local generation=0
  local pending_external,pending_undo=false,false

  local function remove(records)
    for index=#records,1,-1 do
      local record=records[index]
      record.slot.object=nil
      pcall(function()
        if record.remove then record.remove()
        else record.source:remove_notifier(record.handler) end
      end)
      records[index]=nil
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

  local function add(records,source,kind,object,list,current_generation,temporary_instrument)
    if source==nil then return end
    local add_notifier=read(source,"add_notifier")
    local remove_notifier=read(source,"remove_notifier")
    if type(add_notifier)~="function" or type(remove_notifier)~="function" then return end
    local slot={object=object}
    local handler=function()
      local subject=slot.object
      if subject==nil or generation~=current_generation or song==nil then return end
      if kind=="content" and is_render_temporary(temporary_instrument,subject) then return end
      local change_kind=classify_undo(song) and "undo" or kind
      local internal=false
      if runtime and type(runtime.mutation_state)=="function" then
        local ok,state=pcall(runtime.mutation_state,runtime)
        internal=ok and type(state)=="table" and state.depth>0
      end
      if not internal then
        pending_external=true
        pending_undo=pending_undo or change_kind=="undo"
      end
      if on_change then pcall(on_change,change_kind,subject,internal) end
    end
    local ok=pcall(function() source:add_notifier(handler) end)
    if ok then records[#records+1]={source=source,handler=handler,slot=slot,list=list==true} end
  end

  local function add_phrase(records,instrument,phrase,current_generation)
    add(records,read(phrase,"name_observable"),"rename",phrase,false,current_generation)
    for _,property in ipairs(PHRASE_PROPERTIES) do
      add(records,read(phrase,property.."_observable"),"content",phrase,false,current_generation,instrument)
    end
    for _,property in ipairs({"column_name_observable","column_is_muted_observable"}) do
      local observable_for_column=read(phrase,property)
      if type(observable_for_column)=="function" then
        for column=1,NOTE_COLUMN_COUNT do
          local ok,source=pcall(observable_for_column,phrase,column)
          if ok then add(records,source,"content",phrase,false,current_generation,instrument) end
        end
      end
    end
    local add_line_notifier=read(phrase,"add_line_notifier")
    local remove_line_notifier=read(phrase,"remove_line_notifier")
    if type(add_line_notifier)=="function" and type(remove_line_notifier)=="function" then
      local slot={object=phrase}
      local handler=function()
        local subject=slot.object
        if subject==nil or generation~=current_generation or song==nil then return end
        if is_render_temporary(instrument,subject) then return end
        local change_kind=classify_undo(song) and "undo" or "content"
        local internal=false
        if runtime and type(runtime.mutation_state)=="function" then
          local ok,state=pcall(runtime.mutation_state,runtime)
          internal=ok and type(state)=="table" and state.depth>0
        end
        if not internal then
          pending_external=true
          pending_undo=pending_undo or change_kind=="undo"
        end
        if on_change then pcall(on_change,change_kind,subject,internal) end
      end
      local ok=pcall(function() phrase:add_line_notifier(handler) end)
      if ok then
        nested_records[#nested_records+1]={source=phrase,handler=handler,slot=slot,
          remove=function() phrase:remove_line_notifier(handler) end}
      end
    end
    local mapping=read(phrase,"mapping")
    if mapping then
      for _,property in ipairs(MAPPING_PROPERTIES) do
        add(records,read(mapping,property.."_observable"),"content",phrase,false,current_generation,instrument)
      end
    end
  end

  local function add_instrument(records,instrument,current_generation)
    add(records,read(instrument,"name_observable"),"rename",instrument,false,current_generation)
    add(records,read(instrument,"phrases_observable"),"inventory",instrument,true,current_generation)
  add(records,read(instrument,"phrase_mappings_observable"),"inventory",instrument,true,current_generation)
    local phrases=read(instrument,"phrases")
    pcall(function()
      for _,phrase in ipairs(phrases) do add_phrase(records,instrument,phrase,current_generation) end
    end)
  end

  local function add_nested(current_song,current_generation)
    local instruments=read(current_song,"instruments")
    pcall(function()
      for _,instrument in ipairs(instruments) do add_instrument(nested_records,instrument,current_generation) end
    end)
  end

  function observer:attach(current_song,current_runtime,callback)
    assert(current_song~=nil,"A current song is required")
    assert(current_runtime==nil or type(current_runtime)=="table","Runtime must be a table")
    assert(callback==nil or type(callback)=="function","Change callback must be a function")
    self:detach()
    generation=generation+1
    song,runtime,on_change=current_song,current_runtime,callback
    local current_generation=generation
    add(root_records,read(song,"instruments_observable"),"inventory",song,true,current_generation)
    add(root_records,read(song,"selected_instrument_observable"),"selection",song,false,current_generation)
    add(root_records,read(song,"selected_phrase_observable"),"selection",song,false,current_generation)
    add_nested(song,current_generation)
    return true
  end

  function observer:refresh()
    if song==nil then return false end
    if pending_external and runtime and type(runtime.mark_dirty)=="function" then
      local reason=pending_undo and "Native undo or redo change" or "External native change"
      pcall(runtime.mark_dirty,runtime,reason)
    end
    pending_external,pending_undo=false,false
    remove(nested_records)
    generation=generation+1
    local current_generation=generation
    -- Root callbacks are rebuilt too so every listener shares the active token.
    remove(root_records)
    add(root_records,read(song,"instruments_observable"),"inventory",song,true,current_generation)
    add(root_records,read(song,"selected_instrument_observable"),"selection",song,false,current_generation)
    add(root_records,read(song,"selected_phrase_observable"),"selection",song,false,current_generation)
    add_nested(song,current_generation)
    return true
  end

  function observer:detach()
    generation=generation+1
    remove(nested_records)
    remove(root_records)
    song,runtime,on_change=nil,nil,nil
    pending_external,pending_undo=false,false
    return true
  end

  function observer:state()
    local count=0
    for _ in ipairs(root_records) do count=count+1 end
    for _ in ipairs(nested_records) do count=count+1 end
    return {attached=song~=nil,listener_count=count}
  end

  return observer
end

return M
