-- SPDX-License-Identifier: GPL-3.0-only
local M={}

local PREVIEW_VOLUME=0.8
local RELEASE_INTERVAL_MS=120
local MIN_NOTE=24
local MAX_NOTE=60

local function member_index(objects,object)
  for index,candidate in ipairs(objects) do
    if rawequal(candidate,object) then return index end
  end
end

function M.new(options)
  local owner={}
  local tool=options.tool
  local current,last,closed,starting,releasing

  local function indices(state)
    if not rawequal(options.song(),state.song) then error("captured song is no longer current") end
    local instrument=member_index(state.song.instruments,state.instrument)
    local track=member_index(state.song.tracks,state.track)
    if not instrument or not track then error("captured instrument or track was removed") end
    local kind=state.track.type
    if kind==nil or (kind~=renoise.Track.TRACK_TYPE_SEQUENCER and kind~=renoise.Track.TRACK_TYPE_MASTER
        and kind~=renoise.Track.TRACK_TYPE_GROUP) then error("audition requires a non-send track") end
    return instrument,track
  end

  local function detach(state)
    local errors=state.outcome.cleanup_errors
    state.slot.state=nil
    local ok,err=pcall(function()
      if tool:has_timer(state.timer) then tool:remove_timer(state.timer) end
      if tool:has_timer(state.timer) then error("audition timer remained registered") end
    end)
    if not ok then errors[#errors+1]=tostring(err) end
    for index=#state.observers,1,-1 do
      local record=state.observers[index]
      ok,err=pcall(function()
        if record.observable:has_notifier(record.callback) then
          record.observable:remove_notifier(record.callback)
        end
        if record.observable:has_notifier(record.callback) then
          error("audition notifier remained registered")
        end
      end)
      if not ok then errors[#errors+1]=tostring(err) end
    end
  end

  function owner:release(reason)
    local state=current
    if not state then return true end
    releasing=true
    current=nil
    local outcome=state.outcome
    outcome.reason=reason or "release"
    detach(state)
    if outcome.onset_attempted then
      outcome.release_attempted=true
      local ok,err=pcall(function()
        local instrument,track=indices(state)
        state.song:trigger_instrument_note_off(instrument,track,state.note)
      end)
      outcome.release_ok=ok
      if not ok then outcome.release_error="Audition cleanup is best effort: "..tostring(err) end
    end
    last=outcome
    state.song=nil
    state.instrument=nil
    state.track=nil
    if options.on_outcome then pcall(options.on_outcome,outcome) end
    releasing=false
    local err=outcome.release_error or outcome.cleanup_errors[1]
    if err then return nil,err end
    return true
  end

  local function start(note)
    if closed then return nil,"audition owner is closed" end
    local released,release_error=owner:release("second audition")
    if not released then return nil,release_error end
    if closed then return nil,"audition owner is closed" end
    if type(note)~="number" or note~=math.floor(note) or note<MIN_NOTE or note>MAX_NOTE then
      return nil,"audition note must be an integer from 24 to 60"
    end
    local state={note=note,observers={},slot={},outcome={
      onset_attempted=false,onset_ok=false,release_attempted=false,release_ok=false,
      cleanup_errors={},
    }}
    local slot=state.slot
    slot.state=state
    state.timer=function()
      if slot.state then owner:release("timer") end
    end
    current=state
    local ok,err=pcall(function()
      state.song=options.song()
      state.instrument=state.song.selected_instrument
      state.track=state.song.selected_track
      indices(state)
      local function observe(observable,callback)
        local record={observable=observable,callback=callback}
        state.observers[#state.observers+1]=record
        observable:add_notifier(callback)
        if current~=state then error("audition context changed during observer registration") end
        if not observable:has_notifier(callback) then error("audition notifier was not registered") end
      end
      local function inventory_changed()
        local active=slot.state
        if active then
          local valid=pcall(indices,active)
          if not valid then owner:release("captured object removed") end
        end
      end
      local function document_changed()
        if slot.state then owner:release("document change") end
      end
      local function selection_changed()
        if slot.state then owner:release("selection change") end
      end
      observe(state.song.instruments_observable,inventory_changed)
      observe(state.song.tracks_observable,inventory_changed)
      observe(state.song.selected_instrument_observable,selection_changed)
      observe(state.song.selected_track_observable,selection_changed)
      observe(tool.app_release_document_observable,document_changed)
      observe(tool.app_new_document_observable,document_changed)
      local instrument,track=indices(state)
      state.outcome.onset_attempted=true
      state.song:trigger_instrument_note_on(instrument,track,note,PREVIEW_VOLUME)
      state.outcome.onset_ok=true
      if current~=state then error("audition context changed during onset") end
      tool:add_timer(state.timer,RELEASE_INTERVAL_MS)
      if current~=state then error("audition context changed during timer registration") end
      if not tool:has_timer(state.timer) then error("audition timer was not registered") end
    end)
    if not ok then
      state.outcome.onset_error=tostring(err)
      if current==state then owner:release("onset failure") else detach(state) end
      return nil,state.outcome.onset_error
    end
    return true
  end

  function owner:start(note)
    if starting or releasing then return nil,"audition lifecycle is already in progress" end
    starting=true
    local ok,result,err=pcall(start,note)
    starting=false
    if not ok then return nil,tostring(result) end
    return result,err
  end

  function owner:active() return current~=nil end
  function owner:last_outcome() return last end
  function owner:close()
    closed=true
    return self:release("close")
  end
  return owner
end

return M
