dofile("tests/bootstrap.lua")("acid")

local UNCHANGED_IDLE_REFRESH_COUNT=8
local MAPPING_PROPERTY_COUNT=6
local listeners={}
local notifier_adds,notifier_removes=0,0
local function observable()
  local value={}
  listeners[value]={}
  function value:add_notifier(handler)
    notifier_adds=notifier_adds+1
    listeners[self][handler]=true
  end
  function value:remove_notifier(handler)
    assert(listeners[self][handler],"removing an unattached listener")
    notifier_removes=notifier_removes+1
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
  function result:has_line_notifier(handler) return self._line_changes:has_notifier(handler) end
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
  result.script={}
  for _,property in ipairs({"editor_visible","parameters","paragraphs",
      "paragraphs_assignment","pending_changes","committed"}) do
    result.script[property.."_observable"]=observable()
  end
  return result
end

local function instrument(name,phrases)
  return {name=name,name_observable=observable(),phrases=phrases,
    phrases_observable=observable(),phrase_mappings_observable=observable(),
    phrase_mappings={},
    phrase_playback_mode_observable=observable(),phrase_program_observable=observable()}
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
runtime.inventory_proof=nil
function runtime:mutation_state() return {depth=depth} end
function runtime:mark_dirty(reason) dirty[#dirty+1]=reason end
function runtime:notify_native_change(kind,subject)
  if kind~="selection" then self:mark_dirty(kind) end
end
function runtime:occupancy_state() return {status=self.busy and "busy" or "idle"} end
function runtime:is_temporary(owner,phrase) return self.temporaries[phrase]==owner end
function runtime:matches_mutation_inventory(subject,kind)
  local proof=self.inventory_proof
  return proof~=nil and proof.subject==subject and proof.kind==kind
end
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
for _,property in ipairs({"editor_visible","parameters","paragraphs",
    "paragraphs_assignment","pending_changes","committed"}) do
  assert(p1.script[property.."_observable"]:count_notifiers()==1,
    "phrase script state observers must attach for "..property)
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
p1.script.paragraphs_assignment_observable:fire()
assert(changes[#changes].kind=="content" and changes[#changes].object==p1 and changes[#changes].internal,
  "script paragraph assignment must participate in native change observation")
i1.phrase_playback_mode_observable:fire()
assert(changes[#changes].kind=="content" and changes[#changes].object==i1 and changes[#changes].internal,
  "instrument phrase playback changes must participate in native change observation")
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
p1.script.paragraphs_observable:fire()
p1.script.committed_observable:fire()
p1.name_observable:fire()
assert(#changes==before_render_events,
  "busy writer staging phrase content, script and rename events must be filtered")
assert(#dirty==0,"writer-owned async content and rename must not invalidate its operation")
p2._line_changes:fire()
assert(#changes==before_render_events+1 and changes[#changes].object==p2,
  "content events from non-temporary phrases must remain observable")
p2:column_name_observable(2):fire()
assert(#changes==before_render_events+2 and changes[#changes].object==p2,
  "column metadata edits on other phrases must remain observable during generation")
p2:column_is_muted_observable(12):fire()
assert(#changes==before_render_events+3 and changes[#changes].object==p2 and not changes[#changes].internal,
  "column mute edits must remain external during generation")
p2.script.parameters_observable:fire()
assert(#changes==before_render_events+4 and changes[#changes].object==p2 and not changes[#changes].internal,
  "script parameter inventory edits must remain external during generation")
i1.phrase_program_observable:fire()
assert(#changes==before_render_events+5 and changes[#changes].object==i1 and not changes[#changes].internal,
  "instrument phrase program changes must remain external during generation")
observer:refresh()
assert(#dirty==5,"external phrase content must invalidate immediately during a busy render")
runtime.busy=false
runtime.temporaries={}
observer:refresh()

local before_metadata_events=#changes
p2:column_name_observable(1):fire()
p2:column_is_muted_observable(12):fire()
p2.script.editor_visible_observable:fire()
p2.script.pending_changes_observable:fire()
i1.phrase_playback_mode_observable:fire()
assert(#changes==before_metadata_events+5 and changes[#changes].object==i1 and not changes[#changes].internal,
  "idle column metadata edits must notify external content changes")
i1.name_observable:fire()
assert(changes[#changes].kind=="rename" and changes[#changes].object==i1 and not changes[#changes].internal)
assert(#dirty==11,"external metadata and rename notifications must invalidate immediately")
observer:refresh()
assert(#dirty==11,"idle refresh must not defer or repeat external invalidation")
song.selected_phrase_observable:fire()
assert(changes[#changes].kind=="selection" and changes[#changes].object==song)
observer:refresh()
assert(#dirty==11,"selection notifications with an unchanged pair must not dirty")
p2.lpb_observable:fire()
observer:refresh()
assert(#dirty==12,"content changes adjacent to selection must invalidate immediately")
runtime.inventory_proof={subject=i1,kind="phrase_mappings"}
i1.phrase_mappings_observable:fire()
assert(changes[#changes].kind=="inventory" and changes[#changes].object==i1,
  "mapping list edits must report the native inventory change")
observer:refresh()
assert(#dirty==12,"an exact writer-owned mapping inventory notification must not dirty")
runtime.inventory_proof={subject=i1,kind="phrases"}
i1.phrase_mappings_observable:fire()
observer:refresh()
assert(#dirty==13,"an unmatched mapping inventory notification must invalidate immediately")
runtime.inventory_proof=nil

song.undoing=true
p2.looping_observable:fire()
assert(changes[#changes].kind=="undo","undo changes must be identified")
p2._line_changes:fire()
assert(changes[#changes].kind=="undo","line edits during undo must be identified")
assert(#dirty==15,"undo notifier callbacks must invalidate immediately")
observer:refresh()
assert(#dirty==15,"idle refresh must not repeat undo invalidation")
song.undoing=false

local old_count=listener_total()
local i2=instrument("second",{phrase("three")})
song.instruments={i2}
song.instruments_observable:fire()
assert(i2.name_observable:count_notifiers()==0,"list callbacks must defer nested rebind")
observer:refresh()
assert(i1.name_observable:count_notifiers()==0 and observer:state().listener_count==listener_total())
assert(i1.phrase_playback_mode_observable:count_notifiers()==0 and
  p1.script.paragraphs_observable:count_notifiers()==0 and
  p1.script.parameters_observable:count_notifiers()==0,
  "removed instruments must detach instrument and phrase script observers")
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
local stable_adds,stable_removes=notifier_adds,notifier_removes
for _=1,UNCHANGED_IDLE_REFRESH_COUNT do observer:refresh() end
assert(notifier_adds==stable_adds and notifier_removes==stable_removes,
  "unchanged idle refreshes must retain observer bindings")

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

-- Dirty reconciliation can close/release the observer reentrantly. The idle
-- callback must not recreate nested listeners after that attachment ended.
do
  local reentrant_song={instruments={i2},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local reentrant= require("runtime.observers").new()
  local reentrant_runtime={}
  function reentrant_runtime:mark_dirty()
    reentrant:detach()
  end
  function reentrant_runtime:notify_native_change(kind) if kind~="selection" then self:mark_dirty() end end
  local listeners_before_attach=listener_total()
  reentrant:attach(reentrant_song,reentrant_runtime)
  assert(listener_total()>listeners_before_attach)
  i2.name_observable:fire()
  assert(not reentrant:refresh())
  assert(not reentrant:state().attached and listener_total()==listeners_before_attach,
    "reentrant detach during dirty delivery must leave no song listeners")
  reentrant_song.instruments_observable:fire()
  assert(not reentrant:state().attached,
    "released root callback reached a reentrantly detached observer")
end

-- Replacing an attachment from a native remove callback must not let the
-- outgoing detach remove listeners or clear state owned by the replacement.
do
  local outgoing_instrument=instrument("outgoing remove",{})
  local incoming_instrument=instrument("incoming remove",{})
  local outgoing_song={instruments={outgoing_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local incoming_song={instruments={incoming_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local events=require("runtime.observers").new()
  local runtime={}
  function runtime:notify_native_change() end
  function runtime:set_observer_error(reason) self.observer_error=reason end
  local outgoing_callbacks,incoming_callbacks=0,0
  assert(events:attach(outgoing_song,runtime,function() outgoing_callbacks=outgoing_callbacks+1 end))
  local source=outgoing_instrument.name_observable
  local remove=source.remove_notifier
  local replaced=false
  function source:remove_notifier(handler)
    if not replaced then
      replaced=true
      assert(events:attach(incoming_song,runtime,function() incoming_callbacks=incoming_callbacks+1 end))
    end
    return remove(self,handler)
  end
  assert(events:detach())
  assert(events:state().attached and incoming_instrument.name_observable:count_notifiers()==1,
    "outgoing detach removed or cleared the replacement attachment")
  incoming_instrument.name_observable:fire()
  assert(incoming_callbacks==1 and outgoing_callbacks==0,
    "replacement attachment callbacks must remain live after outgoing detach")
  events:detach()
end

-- A readiness callback that replaces the attachment must not let the older
-- attach report success over the replacement.
do
  local first_instrument=instrument("first readiness",{})
  local second_instrument=instrument("second readiness",{})
  local final_instrument=instrument("final readiness",{})
  local first_song={instruments={first_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local second_song={instruments={second_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local final_song={instruments={final_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local events=require("runtime.observers").new()
  local runtime={replace_on_clear=false}
  function runtime:notify_native_change() end
  function runtime:set_observer_error(reason)
    if reason==nil and self.replace_on_clear then
      self.replace_on_clear=false
      assert(events:attach(final_song,self))
    end
  end
  assert(events:attach(first_song,runtime))
  runtime.replace_on_clear=true
  local attached=events:attach(second_song,runtime)
  assert(not attached and events:state().attached and
    second_instrument.name_observable:count_notifiers()==0 and
    final_instrument.name_observable:count_notifiers()==1,
    "readiness reentry must preserve the replacement and reject the older attach")
  events:detach()
end

-- Inventory refresh must stop when removing old nested listeners replaces the
-- attachment, leaving the new song's listeners untouched.
do
  local outgoing_instrument=instrument("refresh outgoing",{})
  local incoming_instrument=instrument("refresh incoming",{})
  local outgoing_song={instruments={outgoing_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local incoming_song={instruments={incoming_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local events=require("runtime.observers").new()
  local runtime={}
  function runtime:notify_native_change() end
  function runtime:set_observer_error(reason) self.observer_error=reason end
  assert(events:attach(outgoing_song,runtime))
  outgoing_song.instruments_observable:fire()
  local source=outgoing_instrument.name_observable
  local remove=source.remove_notifier
  local replaced=false
  function source:remove_notifier(handler)
    if not replaced then
      replaced=true
      assert(events:attach(incoming_song,runtime))
    end
    return remove(self,handler)
  end
  assert(not events:refresh())
  assert(events:state().attached and incoming_instrument.name_observable:count_notifiers()==1,
    "inventory refresh removed or rebuilt listeners on the replacement song")
  events:detach()
end

-- A notification that replaces the attachment cannot deliver its old
-- callback or leave rebind work on the new attachment.
do
  local old_instrument=instrument("old callback",{})
  local new_instrument=instrument("new callback",{})
  local old_song={instruments={old_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local new_song={instruments={new_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local events=require("runtime.observers").new()
  local old_callbacks,new_callbacks=0,0
  local runtime={}
  function runtime:notify_native_change(kind,subject)
    if kind=="inventory" and rawequal(subject,old_song) then
      assert(events:attach(new_song,self,function() new_callbacks=new_callbacks+1 end))
    end
  end
  assert(events:attach(old_song,runtime,function() old_callbacks=old_callbacks+1 end))
  old_song.instruments_observable:fire()
  assert(old_callbacks==0 and events:state().attached and
    new_instrument.name_observable:count_notifiers()==1,
    "old inventory callback continued after replacing the attachment")
  new_instrument.name_observable:fire()
  assert(old_callbacks==0 and new_callbacks==1,
    "old callback delivery leaked into the replacement attachment")
  events:detach()
end

-- A replacement attachment created by mark_dirty keeps its own queued list
-- notification for the next refresh.
do
  local replacement=instrument("replacement",{phrase("replacement phrase")})
  local final_replacement=instrument("final replacement",{phrase("final phrase")})
  local replacement_song={instruments={i2},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local replacement_observer=require("runtime.observers").new()
  local replacement_runtime={reentered=false}
  function replacement_runtime:mark_dirty()
    if self.reentered then return end
    self.reentered=true
    replacement_song.instruments={replacement}
    replacement_observer:attach(replacement_song,replacement_runtime)
    replacement_song.instruments={final_replacement}
    replacement_song.instruments_observable:fire()
  end
  function replacement_runtime:notify_native_change(kind) if kind~="selection" then self:mark_dirty() end end
  replacement_observer:attach(replacement_song,replacement_runtime)
  i2.name_observable:fire()
  replacement_observer:refresh()
  assert(replacement.phrases[1].name_observable:count_notifiers()==0 and
    final_replacement.phrases[1].name_observable:count_notifiers()==1,
    "replacement attachment lost its pending inventory notification")
  replacement_observer:refresh()
  replacement_observer:detach()
end

-- Replacing the attachment from inside notifier registration must leave the
-- replacement intact and remove the late registration from the old song.
do
  local old_instrument=instrument("old registration",{})
  local new_instrument=instrument("new registration",{})
  local old_song={instruments={old_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local new_song={instruments={new_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local replacing=require("runtime.observers").new()
  local replacing_runtime={}
  function replacing_runtime:mark_dirty() end
  function replacing_runtime:notify_native_change(kind) if kind~="selection" then self:mark_dirty() end end
  function replacing_runtime:set_observer_error(reason) self.observer_error=reason end
  local add=old_instrument.name_observable.add_notifier
  local replaced=false
  function old_instrument.name_observable:add_notifier(handler)
    if not replaced then
      replaced=true
      assert(replacing:attach(new_song,replacing_runtime))
    end
    return add(self,handler)
  end
  assert(not replacing:attach(old_song,replacing_runtime),
    "the superseded attach should report that it lost attachment ownership")
  assert(replacing:state().attached and new_instrument.name_observable:count_notifiers()==1 and
    old_instrument.name_observable:count_notifiers()==0,
    "reentrant registration must not leak old listeners or detach the replacement")
  replacing:detach()
end

-- A line notifier registered after a reentrant replacement is unwound from
-- the old phrase even when its add method completes after replacement.
do
  local old_phrase=phrase("old line registration")
  local old_instrument=instrument("old line",{old_phrase})
  local new_phrase=phrase("new line registration")
  local new_instrument=instrument("new line",{new_phrase})
  local old_song={instruments={old_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local new_song={instruments={new_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local replacing=require("runtime.observers").new()
  local replacing_runtime={}
  function replacing_runtime:mark_dirty() end
  function replacing_runtime:notify_native_change(kind) if kind~="selection" then self:mark_dirty() end end
  function replacing_runtime:set_observer_error(reason) self.observer_error=reason end
  local line_add=old_phrase.add_line_notifier
  local replaced=false
  function old_phrase:add_line_notifier(handler)
    if not replaced then
      replaced=true
      assert(replacing:attach(new_song,replacing_runtime))
    end
    return line_add(self,handler)
  end
  assert(not replacing:attach(old_song,replacing_runtime),
    "the superseded line registration should report lost attachment ownership")
  assert(replacing:state().attached and new_phrase._line_changes:count_notifiers()==1 and
    old_phrase._line_changes:count_notifiers()==0,
    "line registration re-entry must not leak the old callback or detach replacement")
  replacing:detach()
end

-- Undo classification must not hide the structural change needed to rebuild
-- nested observers.
do
  local undo_old=instrument("undo old",{phrase("undo phrase")})
  local undo_new=instrument("undo new",{phrase("restored phrase")})
  local undo_song={instruments={undo_old},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable(),undoing=true}
  function undo_song:is_undo_redoing() return self.undoing end
  local undo_runtime={}
  function undo_runtime:mark_dirty(reason) self.reason=reason end
  function undo_runtime:notify_native_change(kind)
    if kind~="selection" then
      self:mark_dirty(kind=="undo" and "Native undo or redo change" or "External native change")
    end
  end
  local undo_observer=require("runtime.observers").new()
  undo_observer:attach(undo_song,undo_runtime)
  undo_song.instruments={undo_new}
  undo_song.instruments_observable:fire()
  undo_song.undoing=false
  undo_observer:refresh()
  assert(undo_runtime.reason=="Native undo or redo change",
    "structural undo must retain undo classification")
  assert(undo_old.name_observable:count_notifiers()==0 and
    undo_new.name_observable:count_notifiers()==1,
    "undo inventory change did not rebind nested observers")
  undo_observer:detach()
end

-- Raw selection changes invalidate immediately while leaving the observed
-- pair untouched for idle reconciliation.
do
  local helper=dofile("tests/acid/runtime_phrase_fixture.lua")
  local song,native_instrument,native_phrase=helper.fixture("existing")
  dofile("tests/acid/observer_host_fixture.lua").attach(song,observable)
  local alternate=instrument("alternate",{})
  song.instruments[#song.instruments+1]=alternate
  local changes={}
  local runtime={}
  function runtime:mutation_state() return {depth=0} end
  function runtime:notify_native_change(kind,subject)
    changes[#changes+1]={kind=kind,subject=subject}
  end
  local events=require("runtime.observers").new()
  assert(events:attach(song,runtime))
  song.selected_instrument=native_instrument
  song.selected_phrase=native_phrase
  events:refresh()
  changes={}
  song.selected_instrument=alternate
  song.selected_instrument_observable:fire()
  assert(#changes==1 and changes[1].kind=="selection" and changes[1].subject==song,
    "native selection must invalidate at notification time")
  song.selected_instrument=native_instrument
  song.selected_instrument_observable:fire()
  assert(#changes==2,"A to B to A selection must notify both raw pair changes")
  events:refresh()
  events:detach()
end

-- Required native protection failures must reject attachment and invalidate
-- the runtime instead of silently accepting a partially observed document.
do
  local invalidations=0
  local failed_runtime={}
  function failed_runtime:set_observer_error(reason) self.observer_error=reason end
  function failed_runtime:mark_dirty() invalidations=invalidations+1 end
  local missing_root={instruments={}}
  local missing_root_observer=require("runtime.observers").new()
  local attached=missing_root_observer:attach(missing_root,failed_runtime)
  assert(attached==false and not missing_root_observer:state().attached,
    "missing required root observables must reject attachment")
  assert(failed_runtime.observer_error,"required attachment failure must invalidate generation permission")
  missing_root_observer:detach()

  local failing_phrase=phrase("registration failure")
  local failing_observable=failing_phrase.visible_note_columns_observable
  function failing_observable:add_notifier() error("injected add failure") end
  local failing_instrument=instrument("failing instrument",{failing_phrase})
  local failing_song={instruments={failing_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local failed_observer=require("runtime.observers").new()
  attached=failed_observer:attach(failing_song,failed_runtime)
  assert(attached==false and not failed_observer:state().attached,
    "failed required property registration must unwind and reject attachment")
  assert(listener_total()==0,"partial attachment failure must unwind every installed listener")
  assert(failed_runtime.observer_error,"nested required registration failure must invalidate runtime")
  failed_observer:detach()

  local side_effect_phrase=phrase("partial notifier add")
  local side_effect_source=side_effect_phrase.visible_note_columns_observable
  local normal_add=side_effect_source.add_notifier
  function side_effect_source:add_notifier(handler)
    normal_add(self,handler)
    error("injected add failure after registration")
  end
  local side_effect_song={instruments={instrument("partial add",{side_effect_phrase})},
    instruments_observable=observable(),selected_instrument_observable=observable(),
    selected_phrase_observable=observable()}
  local side_effect_observer=require("runtime.observers").new()
  assert(not side_effect_observer:attach(side_effect_song,failed_runtime))
  assert(listener_total()==0,"add failure after native registration must unwind its side effect")
  side_effect_observer:detach()

  local side_effect_line_phrase=phrase("partial line notifier add")
  local normal_line_add=side_effect_line_phrase.add_line_notifier
  local normal_line_remove=side_effect_line_phrase.remove_line_notifier
  local fail_line_remove=true
  function side_effect_line_phrase:add_line_notifier(handler)
    normal_line_add(self,handler)
    error("injected line add failure after registration")
  end
  function side_effect_line_phrase:remove_line_notifier(handler)
    if fail_line_remove then error("injected line removal failure") end
    return normal_line_remove(self,handler)
  end
  local side_effect_line_song={instruments={instrument("partial line add",{side_effect_line_phrase})},
    instruments_observable=observable(),selected_instrument_observable=observable(),
    selected_phrase_observable=observable()}
  local side_effect_line_observer=require("runtime.observers").new()
  assert(not side_effect_line_observer:attach(side_effect_line_song,failed_runtime))
  assert(side_effect_line_phrase._line_changes:count_notifiers()==1 and
    side_effect_line_observer:state().listener_count>0,
    "failed line cleanup must retain evidence for an installed inert listener")
  fail_line_remove=false
  side_effect_line_observer:detach()
  assert(listener_total()==0 and side_effect_line_phrase._line_changes:count_notifiers()==0,
    "retained line notifier cleanup must retry successfully")

  local missing_line_phrase=phrase("missing line removal")
  missing_line_phrase.remove_line_notifier=nil
  local missing_line_song={instruments={instrument("missing line method",{missing_line_phrase})},
    instruments_observable=observable(),selected_instrument_observable=observable(),
    selected_phrase_observable=observable()}
  local missing_line_observer=require("runtime.observers").new()
  assert(not missing_line_observer:attach(missing_line_song,failed_runtime),
    "missing required line notifier methods must reject attachment")
  assert(listener_total()==0,"missing line notifier method must unwind prior listeners")
  missing_line_observer:detach()

  local unreadable_instrument=instrument("unreadable phrases",{})
  unreadable_instrument.phrases=nil
  setmetatable(unreadable_instrument,{__index=function(_,key)
    if key=="phrases" then error("injected phrases read failure") end
  end})
  local unreadable_song={instruments={unreadable_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local unreadable_observer=require("runtime.observers").new()
  local unreadable_attached,unreadable_error=unreadable_observer:attach(unreadable_song,failed_runtime)
  assert(not unreadable_attached and string.find(unreadable_error,"read failed",1,true),
    "required phrase list read failures must reject attachment with a diagnostic")
  assert(listener_total()==0,"phrase list read failure must unwind prior listeners")
  unreadable_observer:detach()

  for _,field in ipairs({"mapping","script"}) do
    local unreadable_phrase=phrase("unreadable "..field)
    unreadable_phrase[field]=nil
    setmetatable(unreadable_phrase,{__index=function(_,key)
      if key==field then error("injected "..field.." read failure") end
    end})
    local unreadable_phrase_song={instruments={instrument("unreadable phrase",{unreadable_phrase})},
      instruments_observable=observable(),selected_instrument_observable=observable(),
      selected_phrase_observable=observable()}
    local unreadable_phrase_observer=require("runtime.observers").new()
    local attached_phrase,phrase_error=unreadable_phrase_observer:attach(unreadable_phrase_song,failed_runtime)
    assert(not attached_phrase and string.find(phrase_error,field.." read failed",1,true),
      "unreadable optional "..field.." must fail closed")
    assert(listener_total()==0,"unreadable phrase metadata must unwind prior listeners")
    unreadable_phrase_observer:detach()
  end

end

-- A failed native removal remains visible and retryable. Its callback is
-- inert immediately, even when Renoise delivers a queued notification later.
do
  local retry_source=observable()
  local retry_phrase=phrase("failed removal")
  retry_phrase.lpb_observable=retry_source
  local retry_instrument=instrument("retry instrument",{retry_phrase})
  local retry_song={instruments={retry_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local retry_observer=require("runtime.observers").new()
  local retry_runtime={}
  function retry_runtime:mark_dirty() end
  function retry_runtime:notify_native_change(kind) if kind~="selection" then self:mark_dirty() end end
  function retry_runtime:set_observer_error(reason) self.observer_error=reason end
  local retry_changes=0
  retry_observer:attach(retry_song,retry_runtime,function() retry_changes=retry_changes+1 end)
  local remove=retry_source.remove_notifier
  local has_notifier=retry_source.has_notifier
  local fail_remove=true
  local source_live=true
  function retry_source:remove_notifier(handler)
    if fail_remove or not source_live then error("injected remove failure") end
    return remove(self,handler)
  end
  function retry_source:has_notifier(handler)
    if not source_live then error("injected unavailable source") end
    return has_notifier(self,handler)
  end
  retry_observer:detach()
  assert(retry_observer:state().listener_count>0,
    "failed removal must retain listener cleanup evidence")
  local before=retry_changes
  retry_source:fire()
  assert(retry_changes==before,"failed-removal callback must be inert after detach")
  local replacement_runtime={}
  function replacement_runtime:set_observer_error(reason) self.observer_error=reason end
  local replacement_song={instruments={instrument("replacement after cleanup failure",{})},
    instruments_observable=observable(),selected_instrument_observable=observable(),
    selected_phrase_observable=observable()}
  fail_remove=true
  local replacement_attached,replacement_error=retry_observer:attach(replacement_song,replacement_runtime)
  assert(not replacement_attached and replacement_error and replacement_runtime.observer_error,
    "failed cleanup must block the runtime supplied for the new attachment")
  source_live=false
  listeners[retry_source]={}
  retry_instrument.phrases={}
  local recovered_runtime={}
  function recovered_runtime:set_observer_error(reason) self.observer_error=reason end
  assert(retry_observer:attach(retry_song,recovered_runtime),
    "same live song inventory must retire an unavailable source whose phrase was removed")
  assert(retry_source:count_notifiers()==0 and not recovered_runtime.observer_error,
    "dead phrase listener cleanup must restore observer readiness")
  retry_observer:detach()
  assert(retry_observer:state().listener_count==0 and listener_total()==0,
    "repeated detach must retry failed native removals")
end

-- Replacing a released document must retire its unavailable sources using
-- the new live document identity without reading any old host fields.
do
  local old_source=observable()
  local old_phrase=phrase("released phrase")
  old_phrase.lpb_observable=old_source
  local old_instrument=instrument("released instrument",{old_phrase})
  local old_song={instruments={old_instrument},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local events=require("runtime.observers").new()
  local runtime={}
  function runtime:notify_native_change() end
  function runtime:set_observer_error(reason) self.observer_error=reason end
  assert(events:attach(old_song,runtime))
  local source_live=true
  local fail_remove=true
  local old_remove=old_source.remove_notifier
  local old_has=old_source.has_notifier
  function old_source:remove_notifier(handler)
    if fail_remove or not source_live then error("released observable") end
    return old_remove(self,handler)
  end
  function old_source:has_notifier(handler)
    if not source_live then error("released observable") end
    return old_has(self,handler)
  end
  events:detach()
  assert(events:state().listener_count>0,"unavailable cleanup evidence was not retained")

  source_live=false
  listeners[old_source]={}
  local old_field_reads=0
  old_song.instruments=nil
  setmetatable(old_song,{__index=function(_,key)
    old_field_reads=old_field_reads+1
    error("released song field: "..tostring(key))
  end})
  old_instrument.phrases=nil
  setmetatable(old_instrument,{__index=function(_,key)
    old_field_reads=old_field_reads+1
    error("released instrument field: "..tostring(key))
  end})
  rawset(old_source,"remove_notifier",nil)
  rawset(old_source,"has_notifier",nil)
  setmetatable(old_source,{__index=function() error("released observable field") end})

  local new_song={instruments={instrument("new live document",{})},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  assert(events:attach(new_song,runtime),
    "a different live document must retire unavailable sources owned by the released document")
  assert(old_field_reads==0,"cleanup read host fields from a released document")
  events:detach()
end

-- A phrase removed during an active render can invalidate its native
-- observables before the idle inventory rebind runs. A failed remove and
-- notifier probe retire the source only after exact owner absence is proven.
do
  local native_handlers={}
  local source_live=true
  local native_source={}
  function native_source:add_notifier(handler) native_handlers[handler]=true end
  function native_source:remove_notifier(handler)
    if not source_live then error("native observable is unavailable") end
    native_handlers[handler]=nil
  end
  function native_source:has_notifier(handler)
    if not source_live then error("native observable is unavailable") end
    return native_handlers[handler]==true
  end
  local removed_phrase=phrase("render stage")
  removed_phrase.lpb_observable=native_source
  local owner=instrument("render owner",{removed_phrase})
  local live_song={instruments={owner},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local live_observer=require("runtime.observers").new()
  local live_runtime={}
  function live_runtime:mutation_state() return {depth=0} end
  function live_runtime:notify_native_change() end
  function live_runtime:set_observer_error(reason) self.observer_error=reason end
  assert(live_observer:attach(live_song,live_runtime))
  assert(next(native_handlers)~=nil,"test source notifier was not attached")
  live_song.instruments[1].phrases={}
  source_live=false
  owner.phrases_observable:fire()
  live_observer:refresh()
  assert(live_observer:state().listener_count==listener_total(),
    "inaccessible source for a removed phrase must not remain in observer records")
  assert(live_observer:state().attached and not live_observer:state().error,
    "proven dead phrase sources must not fail the live observer attachment")
  live_observer:detach()
end

-- A failing owner inventory cannot prove that a source is dead. Keep the
-- failed listener record retryable until exact membership can be established.
do
  local source_live=true
  local source=observable()
  local remove=source.remove_notifier
  local has_notifier=source.has_notifier
  function source:remove_notifier(handler)
    if not source_live then error("native observable is unavailable") end
    return remove(self,handler)
  end
  function source:has_notifier(handler)
    if not source_live then error("native observable is unavailable") end
    return has_notifier(self,handler)
  end
  local candidate=phrase("uncertain owner")
  candidate.lpb_observable=source
  local owner=instrument("uncertain inventory",{candidate})
  local uncertain_song={instruments={owner},instruments_observable=observable(),
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local uncertain_observer=require("runtime.observers").new()
  local uncertain_runtime={}
  function uncertain_runtime:mutation_state() return {depth=0} end
  function uncertain_runtime:notify_native_change() end
  function uncertain_runtime:set_observer_error(reason) self.observer_error=reason end
  assert(uncertain_observer:attach(uncertain_song,uncertain_runtime))
  uncertain_song.instruments[1].phrases={}
  owner.phrases=nil
  setmetatable(owner,{__index=function(_,key)
    if key=="phrases" then error("injected inventory read failure") end
  end})
  source_live=false
  owner.phrases_observable:fire()
  assert(not uncertain_observer:refresh(),"unreadable owner inventory must fail closed")
  assert(uncertain_observer:state().listener_count>0,
    "uncertain owner membership must preserve retryable removal evidence")
  owner.phrases={}
  uncertain_observer:detach()
  assert(uncertain_observer:state().listener_count==0,
    "exactly absent owner membership must allow retry cleanup")
end

-- Mapping property sources retire only after the mapping itself leaves the
-- owning instrument inventory; the phrase can remain live. Live and unreadable
-- inventories retain retry records until exact mapping absence is established.
do
  local mapping_properties={"key_tracking","base_note","note_range","looping","loop_start","loop_end"}
  for _,mode in ipairs({"removed","live","unreadable"}) do
    local native_handlers={}
    local source_live=true
    local mapping={}
    for _,property in ipairs(mapping_properties) do
      local source={}
      function source:add_notifier(handler) native_handlers[handler]=true end
      function source:remove_notifier(handler)
        if not source_live then error("native mapping observable is unavailable") end
        native_handlers[handler]=nil
      end
      function source:has_notifier(handler)
        if not source_live then error("native mapping observable is unavailable") end
        return native_handlers[handler]==true
      end
      mapping[property.."_observable"]=source
    end
    local live_phrase=phrase("mapped phrase")
    live_phrase.mapping=mapping
    local owner=instrument("mapping owner",{live_phrase})
    owner.phrase_mappings={mapping}
    local live_song={instruments={owner},instruments_observable=observable(),
      selected_instrument_observable=observable(),selected_phrase_observable=observable()}
    local mapping_observer=require("runtime.observers").new()
    local listener_baseline=listener_total()
    local mapping_runtime={}
    function mapping_runtime:mutation_state() return {depth=0} end
    function mapping_runtime:notify_native_change() end
    function mapping_runtime:set_observer_error(reason) self.observer_error=reason end
    assert(mapping_observer:attach(live_song,mapping_runtime))
    local attached_records=mapping_observer:state().listener_count
    assert(next(native_handlers)~=nil,"mapping sources were not observed")
    source_live=false

    if mode=="removed" then
      owner.phrase_mappings={}
      live_phrase.mapping=nil
    elseif mode=="unreadable" then
      owner.phrase_mappings=nil
      setmetatable(owner,{__index=function(_,key)
        if key=="phrase_mappings" then error("injected mapping inventory read failure") end
      end})
    end
    owner.phrase_mappings_observable:fire()
    local refreshed=mapping_observer:refresh()
    if mode=="removed" then
      assert(refreshed,"exact mapping absence must permit cleanup")
      assert(mapping_observer:state().listener_count==attached_records-MAPPING_PROPERTY_COUNT,
        "inaccessible sources for a removed mapping must leave observer records")
      assert(mapping_observer:state().attached and not mapping_observer:state().error,
        "proven dead mapping sources must not fail the live observer attachment")
    else
      assert(not refreshed,"live or unreadable mapping membership must fail closed")
      assert(mapping_observer:state().listener_count==MAPPING_PROPERTY_COUNT+listener_total()-listener_baseline,
        "unproven mapping membership must preserve retryable removal records")
      rawset(owner,"phrase_mappings",{mapping})
      setmetatable(owner,nil)
      live_song.instruments_observable:fire()
      assert(not mapping_observer:refresh(),"a live mapping must remain retryable")
      assert(mapping_observer:state().listener_count==MAPPING_PROPERTY_COUNT+listener_total()-listener_baseline,
        "live mapping sources must retain cleanup records")
      owner.phrase_mappings={}
      live_phrase.mapping=nil
      live_song.instruments_observable:fire()
      assert(mapping_observer:refresh(),"readable exact mapping absence must permit retry cleanup")
      assert(mapping_observer:state().listener_count==attached_records-MAPPING_PROPERTY_COUNT,
        "retry cleanup must retire removed mapping records")
    end
    if mapping_observer:state().attached then mapping_observer:detach() end
  end
end

-- Silent native failures must satisfy the same safety contract as thrown failures.
do
  local source=observable()
  local live_song={instruments={},instruments_observable=source,
    selected_instrument_observable=observable(),selected_phrase_observable=observable()}
  local context={}
  function context:set_observer_error(reason) self.observer_error=reason end
  local observer=require("runtime.observers").new()
  local add,remove=source.add_notifier,source.remove_notifier
  function source:add_notifier() end
  assert(not observer:attach(live_song,context),"ineffective add must reject attachment")
  assert(context.observer_error and not observer:state().attached and observer:state().listener_count==0,
    "ineffective add must invalidate runtime and unwind attachment")
  function source:add_notifier(handler)
    add(self,handler)
    error("injected failure after subscription")
  end
  function source:remove_notifier() end
  assert(not observer:attach(live_song,context),"partial registration must reject attachment")
  assert(observer:state().listener_count==1 and source:count_notifiers()==1,
    "registration rollback must retain silently unremoved listeners")
  source.remove_notifier=remove
  assert(observer:detach(),"registration rollback cleanup must remain retryable")
  source.add_notifier=add
  local deliveries=0
  assert(observer:attach(live_song,context,function() deliveries=deliveries+1 end))
  function source:remove_notifier() end
  assert(not observer:detach(),"ineffective removal must fail detachment")
  assert(observer:state().listener_count==1 and source:count_notifiers()==1,
    "ineffective removal must retain exact cleanup evidence")
  source:fire()
  assert(deliveries==0,"retained callback must be inert")
  assert(not observer:attach(live_song,context),"unresolved removal must block attachment")
  source.remove_notifier=remove
  assert(observer:detach() and observer:state().listener_count==0 and source:count_notifiers()==0,
    "detachment must retry ineffective removal")
end

print("ACID runtime native observer lifecycle checks passed")
