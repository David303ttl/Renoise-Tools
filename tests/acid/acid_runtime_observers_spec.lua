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
runtime.inventory_proof=nil
function runtime:mutation_state() return {depth=depth} end
function runtime:mark_dirty(reason) dirty[#dirty+1]=reason end
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
p1.name_observable:fire()
assert(#changes==before_render_events,
  "busy writer staging phrase content and rename events must be filtered")
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
observer:refresh()
assert(#dirty==2,"selection notifications must not dirty a same-bound generation")
p2.lpb_observable:fire()
observer:refresh()
assert(#dirty==3,"content changes adjacent to selection must still dirty the runtime")
runtime.inventory_proof={subject=i1,kind="phrase_mappings"}
i1.phrase_mappings_observable:fire()
assert(changes[#changes].kind=="inventory" and changes[#changes].object==i1,
  "mapping list edits must report the native inventory change")
observer:refresh()
assert(#dirty==3,"an exact writer-owned mapping inventory notification must not dirty")
runtime.inventory_proof={subject=i1,kind="phrases"}
i1.phrase_mappings_observable:fire()
observer:refresh()
assert(#dirty==4,"an unmatched mapping inventory notification must remain external")
runtime.inventory_proof=nil

song.undoing=true
p2.looping_observable:fire()
assert(changes[#changes].kind=="undo","undo changes must be identified")
p2._line_changes:fire()
assert(changes[#changes].kind=="undo","line edits during undo must be identified")
assert(#dirty==4,"undo notifier callbacks should defer runtime work")
observer:refresh()
assert(#dirty==5,"undo changes should be coalesced into one dirty transition")
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

-- Delayed native inventory notifications from revoked writer cleanup use the
-- runtime's captured post-mutation identity proof. A later unrelated list
-- change must still invalidate a current request through the same observer.
do
  local helper=dofile("tests/acid/runtime_phrase_fixture.lua")
  local context=require("runtime.context")
  local cleanup_song,cleanup_instrument=helper.fixture("existing")
  cleanup_song.instruments_observable=observable()
  cleanup_song.selected_instrument_observable=observable()
  cleanup_song.selected_phrase_observable=observable()
  cleanup_instrument.phrase_mappings={}
  cleanup_instrument.phrases_observable=observable()
  cleanup_instrument.phrase_mappings_observable=observable()
  local request_count,first_done,first_request,second_request=0,nil,nil,nil
  local writer={status="idle",temporary=nil}
  function writer.state() return writer.status,nil end
  function writer.is_temporary(_,_,candidate) return rawequal(candidate,writer.temporary) end
  local runtime_context=context.new({writer=writer,
    capture=function(_,token) return {token=token} end,
    sink=function(request,done)
      request_count=request_count+1
      if request_count==1 then first_request,first_done=request,done else second_request=request end
      return true
    end})
  runtime_context:attach_document(cleanup_song)
  runtime_context:open_dialog()
  assert(runtime_context:bind_new(cleanup_instrument))
  local source=require("model.sequencer").new_pattern(4)
  assert(runtime_context:transition("programmatic",{source=source,
    output_policy="play_once",pb_range=0}))
  local events=require("runtime.observers").new()
  events:attach(cleanup_song,runtime_context)
  assert(runtime_context:request_generation("manual"))
  local revoked_request=assert(first_request)

  local token=revoked_request.token
  assert(runtime_context:revoke(token,"superseded by newer editor state"))
  local staging=dofile("tests/acid/complete_phrase_fixture.lua")(helper.limits)
  staging.name="ACID staging phrase"
  cleanup_instrument.phrases[#cleanup_instrument.phrases+1]=staging
  writer.temporary=staging
  assert(revoked_request:cleanup_mutate(token,function()
    for index,candidate in ipairs(cleanup_instrument.phrases) do
      if rawequal(candidate,staging) then table.remove(cleanup_instrument.phrases,index);return true end
    end
    return false
  end))
  assert(not require("renoise.phrase_ownership").membership(cleanup_song,cleanup_instrument,staging),
    "authorized cleanup retained the staging phrase")

  local proof_matches,proof_reason=runtime_context:matches_mutation_inventory(cleanup_instrument,"phrases")
  assert(proof_matches,"authorized cleanup inventory proof failed: "..tostring(proof_reason))
  local cleanup_revision=runtime_context:revision_state().operation_serial
  cleanup_instrument.phrases_observable:fire()
  events:refresh()
  assert(runtime_context:revision_state().operation_serial==cleanup_revision,
    "the delayed cleanup inventory event was attributed as external")

  assert(first_done({kind="failure",status="cancelled"}))
  assert(runtime_context:request_generation("manual"))
  local external={name="External phrase"}
  cleanup_instrument.phrases[#cleanup_instrument.phrases+1]=external
  cleanup_instrument.phrases_observable:fire()
  events:refresh()
  assert(not second_request:is_current(),
    "an unrelated inventory mismatch did not revoke the current request")
  table.remove(cleanup_instrument.phrases,#cleanup_instrument.phrases)
  cleanup_instrument.phrases_observable:fire()
  events:refresh()
  events:detach()
  runtime_context:release_document()
end

print("ACID runtime native observer lifecycle checks passed")
