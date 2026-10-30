dofile("tests/bootstrap.lua")("acid")

local listeners={}
local function observable()
  local value={}
  listeners[value]={}
  function value:add_notifier(handler) listeners[self][handler]=true end
  function value:remove_notifier(handler)
    assert(listeners[self][handler],"removing an unattached listener")
    listeners[self][handler]=nil
  end
  function value:has_notifier(handler) return listeners[self][handler]==true end
  function value:count_notifiers()
    local count=0
    for _ in pairs(listeners[self]) do count=count+1 end
    return count
  end
  function value:fire()
    local copy={}
    for handler in pairs(listeners[self]) do copy[#copy+1]=handler end
    for _,handler in ipairs(copy) do handler({type="insert",index=1}) end
  end
  return value
end

local function listener_total()
  local count=0
  for _,handlers in pairs(listeners) do for _ in pairs(handlers) do count=count+1 end end
  return count
end

local function phrase(name)
  local result={name=name,mapping=nil}
  result._line_changes=observable()
  function result:add_line_notifier(handler) self._line_changes:add_notifier(handler) end
  function result:remove_line_notifier(handler) self._line_changes:remove_notifier(handler) end
  for _,property in ipairs({"name","playback_mode","is_empty","number_of_lines",
      "visible_note_columns","visible_effect_columns","key_tracking","base_note",
      "looping","loop_start","loop_end","autoseek","lpb","shuffle",
      "instrument_column_visible","volume_column_visible","panning_column_visible",
      "delay_column_visible","sample_effects_column_visible"}) do
    result[property.."_observable"]=observable()
  end
  result._column_name_changes={}
  result._column_mute_changes={}
  function result:column_name_observable(column)
    self._column_name_changes[column]=self._column_name_changes[column] or observable()
    return self._column_name_changes[column]
  end
  function result:column_is_muted_observable(column)
    self._column_mute_changes[column]=self._column_mute_changes[column] or observable()
    return self._column_mute_changes[column]
  end
  return result
end

local function instrument(name,phrases)
  return {name=name,name_observable=observable(),phrases=phrases,
    phrases_observable=observable(),phrase_mappings_observable=observable()}
end

local p1,p2=phrase("one"),phrase("two")
local i1=instrument("first",{p1,p2})
local song={instruments={i1},instruments_observable=observable(),
  selected_instrument_observable=observable(),selected_phrase_observable=observable(),
  undoing=false}
function song:is_undo_redoing() return self.undoing end

local depth=0
local changes,dirty={},{}
local runtime={busy=false,temporaries={}}
function runtime:mutation_state() return {depth=depth} end
function runtime:mark_dirty(reason) dirty[#dirty+1]=reason end
function runtime:occupancy_state() return {status=self.busy and "busy" or "idle"} end
function runtime:is_temporary(owner,phrase) return self.temporaries[phrase]==owner end
local observer=require("runtime.observers").new()
observer:attach(song,runtime,function(kind,object,internal)
  changes[#changes+1]={kind=kind,object=object,internal=internal}
end)

assert(observer:state().attached and observer:state().listener_count==listener_total())
assert(listener_total()>20,"expected nested phrase property observers")
for column=1,12 do
  assert(p1:column_name_observable(column):count_notifiers()==1 and
    p1:column_is_muted_observable(column):count_notifiers()==1,
    "note-column metadata observables must be attached for every column")
end

depth=1
p1.lpb_observable:fire()
assert(changes[#changes].kind=="content" and changes[#changes].object==p1 and changes[#changes].internal)
assert(#dirty==0,"notifier callbacks should defer runtime work")
p1._line_changes:fire()
assert(changes[#changes].kind=="content" and changes[#changes].object==p1 and changes[#changes].internal,
  "phrase line edits must be observed inside mutation scopes")
assert(#dirty==0,"line notifier callbacks should defer runtime work")
p1:column_name_observable(1):fire()
assert(changes[#changes].kind=="content" and changes[#changes].object==p1 and changes[#changes].internal,
  "column renames must participate in native change observation")
p1:column_is_muted_observable(12):fire()
assert(changes[#changes].kind=="content" and changes[#changes].object==p1 and changes[#changes].internal,
  "column mute changes must participate in native change observation")
observer:refresh()
assert(#dirty==0,"internal mutations should be reconciled by the owning mutation scope")
depth=0

-- Native async rendering edits its registered staging phrase outside the
-- synchronous mutation scope. Those exact content events must not invalidate
-- the render, while edits to any other phrase remain external.
runtime.busy=true
runtime.temporaries[p1]=i1
observer:refresh()
local before_render_events=#changes
p1.lpb_observable:fire()
p1._line_changes:fire()
p1:column_name_observable(1):fire()
p1:column_is_muted_observable(12):fire()
assert(#changes==before_render_events,"busy writer staging phrase content must be filtered")
assert(#dirty==0,"writer-owned async content must not invalidate its operation")
p2._line_changes:fire()
assert(#changes==before_render_events+1 and changes[#changes].object==p2,
  "content events from non-temporary phrases must remain observable")
p2:column_name_observable(2):fire()
assert(#changes==before_render_events+2 and changes[#changes].object==p2,
  "column metadata edits on other phrases must remain observable during generation")
p2:column_is_muted_observable(12):fire()
assert(#changes==before_render_events+3 and changes[#changes].object==p2 and not changes[#changes].internal,
  "column mute edits must remain external during generation")
observer:refresh()
assert(#dirty==1,"external phrase content must invalidate during a busy render")
runtime.busy=false
runtime.temporaries={}
observer:refresh()

local before_metadata_events=#changes
p2:column_name_observable(1):fire()
p2:column_is_muted_observable(12):fire()
assert(#changes==before_metadata_events+2 and changes[#changes].object==p2 and not changes[#changes].internal,
  "idle column metadata edits must notify external content changes")
i1.name_observable:fire()
assert(changes[#changes].kind=="rename" and changes[#changes].object==i1 and not changes[#changes].internal)
assert(#dirty==1,"native changes should coalesce until idle")
observer:refresh()
assert(#dirty==2,"coalesced native changes should dirty the runtime once at idle")
song.selected_phrase_observable:fire()
assert(changes[#changes].kind=="selection" and changes[#changes].object==song)
i1.phrase_mappings_observable:fire()
assert(changes[#changes].kind=="inventory" and changes[#changes].object==i1,
  "mapping list edits must dirty the native inventory")

song.undoing=true
p2.looping_observable:fire()
assert(changes[#changes].kind=="undo","undo changes must be identified")
p2._line_changes:fire()
assert(changes[#changes].kind=="undo","line edits during undo must be identified")
assert(#dirty==2,"undo notifier callbacks should defer runtime work")
observer:refresh()
assert(#dirty==3,"undo changes should be coalesced into one dirty transition")
song.undoing=false

local old_count=listener_total()
local i2=instrument("second",{phrase("three")})
song.instruments={i2}
song.instruments_observable:fire()
assert(i2.name_observable:count_notifiers()==0,"list callbacks must defer nested rebind")
observer:refresh()
assert(i1.name_observable:count_notifiers()==0 and observer:state().listener_count==listener_total())
for column=1,12 do
  assert(p1:column_name_observable(column):count_notifiers()==0 and
    p1:column_is_muted_observable(column):count_notifiers()==0,
    "refresh must detach removed phrase metadata observers")
end
assert(listener_total()<old_count,"refresh must detach removed nested objects")
local before=#changes
i1.name_observable:fire()
assert(#changes==before,"removed instrument callbacks must be detached")
p1._line_changes:fire()
assert(#changes==before,"removed phrase line callbacks must be detached")
i2.name_observable:fire()
assert(#changes==before+1 and changes[#changes].object==i2)
local p3,p4=i2.phrases[1],phrase("four")
i2.phrases={p3,p4}
i2.phrases_observable:fire()
assert(p4.name_observable:count_notifiers()==0,"phrase list callbacks must defer nested rebind")
observer:refresh()
assert(p4.name_observable:count_notifiers()==1,"refresh must attach new phrase observers")
local stable_count=listener_total()
observer:refresh()
assert(listener_total()==stable_count,"repeated refresh must not leak listeners")

local old_song_instruments=song.instruments_observable
observer:detach()
assert(not observer:state().attached and observer:state().listener_count==0 and listener_total()==0)
before=#changes
old_song_instruments:fire()
assert(#changes==before,"released song callbacks must not reach the runtime")

observer:attach(song,runtime,function(kind) changes[#changes+1]={kind=kind} end)
local attached_count=listener_total()
observer:attach(song,runtime,function(kind) changes[#changes+1]={kind=kind} end)
assert(listener_total()==attached_count,"repeated attach must not leak listeners")
observer:detach()
assert(listener_total()==0)

print("ACID runtime native observer lifecycle checks passed")
