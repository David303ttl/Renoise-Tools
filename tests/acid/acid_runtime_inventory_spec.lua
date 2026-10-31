local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local ownership=require('renoise.phrase_ownership')
local store=require('renoise.pattern_store')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local fixture,phrase,instrument,runtime=helper.fixture,helper.phrase,helper.instrument,helper.runtime

-- Real classifier proofs establish detached baselines; identical content is not identity.
do
 local song,inst,a,b,source=fixture()
 local ctx=runtime(song,b)
 local target=ctx:bind_phrase(inst,a)
 assert(target.kind=='owned' and rawequal(target.phrase,a),tostring(target.reason))
 assert(target.baseline.id==101 and seq.same_source(target.baseline.source,source))
 target.baseline.source.length=8;target.baseline.settings.pb_range=24
 target.baseline.snapshot.properties.lpb=1
 target.baseline.planning_inputs.capacities.max_lines=1
 target.baseline.planning_inputs.capabilities.sample=false
 local pristine=ctx:target_state()
 assert(pristine.baseline.source.length==4 and pristine.baseline.settings.pb_range==0)
 assert(pristine.baseline.snapshot.properties.lpb~=1)
 assert(pristine.baseline.planning_inputs.capacities.max_lines==helper.limits.max_lines)
 assert(pristine.baseline.planning_inputs.capabilities.sample==true)
 local choices=assert(ctx:phrase_choices(inst))
 for _,choice in ipairs(choices)do assert(not rawequal(choice.phrase,b))end
 assert(cache.put(song,inst,a,seq.new_pattern(5),'play_once',0,ctx:draft_options()))
 assert(cache.put(song,inst,b,seq.new_pattern(6),'play_once',0,ctx:draft_options()))
 assert(cache.get(song,inst,a,ctx:draft_options()).length==5)
 assert(cache.get(song,inst,b,ctx:draft_options()).length==6)
 inst.phrases={b,a};inst.name='Renamed';a.name=a.name
 assert(ctx:refresh_inventory().phrase_index==2)
 assert(rawequal(ctx:target_state().phrase,a))
 local replacement=phrase(source,103)
 inst.phrases={b,replacement}
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(rawequal(ctx:target_state().phrase,a))
 assert(ctx:bind_new(inst).kind=='new')
 song.selected_phrase=b;song.selected_instrument=inst
 assert(ctx:refresh_inventory().kind=='new')
 assert(ctx:bind_phrase(inst,nil).kind=='unavailable')
 assert(helper.eq_calls()==0,'inventory/drafts must use raw phrase identity')
end

-- Clean editor edits persist against the retained draft baseline without
-- streaming the native phrase cells on each keystroke.
do
 local song,inst,a,_,source=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 local validator=require('writers.phrase_validator')
 local original_classify,original_against=validator.classify,validator.classify_against
 local original_matches=ownership.matches_snapshot
 local full_checks=0
 validator.classify=function(...)full_checks=full_checks+1;return original_classify(...)end
 validator.classify_against=function(...)full_checks=full_checks+1;return original_against(...)end
 ownership.matches_snapshot=function(...)full_checks=full_checks+1;return original_matches(...)end
 local edited=seq.copy_source(source)
 edited.pitch_events[1]=seq.new_pitch(3,0,false,false)
 assert(ctx:transition('edit',{source=edited,output_policy='repeat',pb_range=0}))
 local later=seq.copy_source(edited)
 later.pitch_events[1]=seq.new_pitch(6,0,false,false)
 assert(ctx:transition('edit',{source=later,output_policy='repeat',pb_range=0}))
 validator.classify,validator.classify_against=original_classify,original_against
 ownership.matches_snapshot=original_matches
 assert(full_checks==0,'clean editor persistence streamed a fresh native phrase proof')
 local stored=assert(store.read_draft(song,inst,a))
 assert(seq.same_source(stored,later),'cached editor path did not persist the latest source')
 ctx:release_document()

 local busy='idle'
 local live=require('runtime.context').new({writer={state=function()return busy,nil end,
   is_temporary=function()return false end},capture=function()error('edit must not capture')end,
   sink=function()error('edit must not dispatch synchronously')end})
 live:attach_document(song);live:open_dialog();assert(live:bind_phrase(inst,a).kind=='owned')
 full_checks=0
 validator.classify=function(...)full_checks=full_checks+1;return original_classify(...)end
 validator.classify_against=function(...)full_checks=full_checks+1;return original_against(...)end
 ownership.matches_snapshot=function(...)full_checks=full_checks+1;return original_matches(...)end
 busy='busy'
 local latest=seq.copy_source(later)
 latest.pitch_events[1]=seq.new_pitch(9,0,false,false)
 assert(live:transition('edit',{source=latest,output_policy='repeat',pb_range=0}))
 validator.classify,validator.classify_against=original_classify,original_against
 ownership.matches_snapshot=original_matches
 assert(full_checks==0,'busy editor persistence streamed a fresh native phrase proof')
 assert(seq.same_source(assert(store.read_draft(song,inst,a)),latest),
   'busy editor persistence did not save the latest source')
 live:release_document()
end

-- Even a newly valid source/output pair cannot replace an established session baseline.
do
 local song,inst,a,b,source=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
 local replacement=phrase(changed,101)
 for key,value in pairs(replacement)do a[key]=value end
 assert(store.save(song,101,changed,'play_once',0))
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(ctx:bind_phrase(inst,a).kind=='unavailable')
 -- A cold wrapper gets a fresh proof from persisted data, with no old index/session.
 local cold_phrase=phrase(changed,101)
 local cold_inst=instrument({cold_phrase})
 local cold_song={tool_data=song.tool_data,instruments={cold_inst}}
 local before=cold_song.tool_data
 local cold=runtime(cold_song)
 local classified=cold:bind_phrase(cold_inst,cold_phrase)
 assert(classified.kind=='owned' and seq.same_source(classified.baseline.source,changed))
 assert(cold_song.tool_data==before and #cold_inst.phrases==1)
end

-- Negative persisted fixtures stay blocked and never become implicit New.
for _,fault in ipairs({'missing','corrupt','incompatible','content','collision','inaccessible','foreign'})do
 local song,inst,a,_,source=fixture()
 if fault=='missing' then song.tool_data=''
 elseif fault=='corrupt' then song.tool_data='invalid ACID store'
 elseif fault=='incompatible' then
  local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
  assert(store.save(song,101,changed,'play_once',0))
 elseif fault=='content' then a.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value=1
 elseif fault=='collision' then song.instruments[2]=instrument({phrase(source,101)})
 elseif fault=='inaccessible' then a.script=setmetatable({},{__index=function()error('unreadable script')end})
 elseif fault=='foreign' then a.name='Native phrase' end
 local before=song.tool_data
 local target=runtime(song):bind_phrase(inst,a)
 assert(target.kind==(fault=='foreign' and 'foreign' or 'unavailable'),fault)
 assert(type(target.reason)=='string' and #target.reason>0,fault..' needs a concrete reason')
 assert(song.tool_data==before and #inst.phrases==2)
end

-- Instrument removal and changed receiver planning inputs revoke the saved proof.
do
 local song,inst,a=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 inst.plugin_properties.plugin_loaded=true
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(ctx:bind_new(inst).kind=='new')
 song.instruments={instrument({})}
 assert(ctx:refresh_inventory().kind=='unavailable')
 assert(rawequal(ctx:target_state().instrument,inst))
end

-- The compact native matcher still reads receiver capabilities afresh.
do
 local song,inst,a=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 local original_snapshot,original_status=ownership.snapshot,ownership.status
 local snapshot_calls,status_calls=0,0
 ownership.snapshot=function(...)snapshot_calls=snapshot_calls+1;return original_snapshot(...)end
 ownership.status=function(...)status_calls=status_calls+1;return original_status(...)end
 local fresh=ctx:target_state()
 assert(fresh.kind=='owned' and snapshot_calls==0 and status_calls==0,
  'fresh exact native proof rebuilt a snapshot or repeated its seal hash')
 ownership.snapshot,ownership.status=original_snapshot,original_status
 inst.plugin_properties.plugin_loaded=true
 local changed=ctx:target_state()
 assert(changed.kind=='unavailable' and changed.baseline==nil,
  'fresh receiver capability change reused the cached phrase snapshot as authorization')
end

-- A retained draft validator cannot keep the released document alive or prove it current.
do
 local song,inst,a=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 local options=ctx:draft_options()
 assert(options.validate(song,inst,a))
 ctx:release_document()
 assert(not options.validate(song,inst,a))
 local next_song,next_inst,next_phrase=fixture()
 ctx:attach_document(next_song)
 assert(not options.validate(song,inst,a))
 assert(options.validate(next_song,next_inst,next_phrase))
end

-- Display projections and clean idle reconciliation reuse metadata; mutation
-- invalidation and explicit eligibility checks perform fresh classification.
do
 local song,inst,a=fixture()
 local ctx=runtime(song)
 local validator=require('writers.phrase_validator')
 local classify=validator.classify
 local classify_against=validator.classify_against
 local calls=0
 validator.classify=function(...)
  calls=calls+1
  return classify(...)
 end
 validator.classify_against=function(...)
  calls=calls+1
  return classify_against(...)
 end
 local target=ctx:bind_phrase(inst,a)
 assert(target.kind=='owned')
 local after_bind=calls
 for _=1,25 do
  local projection=ctx:target_projection()
  assert(projection.kind=='owned' and projection.baseline==nil)
  assert(ctx:reconcile().kind=='owned')
 end
 assert(calls==after_bind,'clean projections or idle reconciliation repeated phrase classification')
 ctx:mark_dirty('fixture mutation')
 assert(ctx:reconcile().kind=='owned')
 assert(calls==after_bind+1,'dirty reconciliation did not refresh the eligibility baseline')
 local after_refresh=calls
 assert(ctx:target_projection().kind=='owned' and calls==after_refresh)
 assert(ctx:target_state().kind=='owned' and calls==after_refresh+1,
  'explicit target checks must remain fresh')
 validator.classify=classify
 validator.classify_against=classify_against
 ctx:release_document()
end

-- Projection recapture discards native ownership data, so it does not detach a baseline.
do
 local song,inst,a=fixture()
 local ctx=runtime(song)
 assert(ctx:bind_phrase(inst,a).kind=='owned')
 ctx:mark_dirty('projection cache invalidation')
 local original_copy=ownership.copy_snapshot
 local baseline_copies=0
 ownership.copy_snapshot=function(value,...)
  if type(value)=='table' and value.snapshot~=nil then baseline_copies=baseline_copies+1 end
  return original_copy(value,...)
 end
 local ok,projection_or_error=pcall(function()
  local projection=ctx:target_projection()
  assert(projection.kind=='owned' and projection.baseline==nil)
  assert(baseline_copies==0,'projection recapture copied a baseline it discards')
  local target=ctx:target_state()
  assert(target.kind=='owned' and target.baseline~=nil)
  assert(baseline_copies==1,'explicit target state did not detach its baseline')
  target.baseline.snapshot.properties.lpb=1
  local fresh=ctx:target_state()
  assert(fresh.baseline.snapshot.properties.lpb~=1,
   'explicit target state shared its detached baseline')
  assert(baseline_copies==2,'repeated explicit target state skipped baseline detachment')
  a.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value=1
  ctx:mark_dirty('hidden phrase field changed')
  local blocked=ctx:target_projection()
  assert(blocked.kind=='unavailable' and blocked.baseline==nil,
   'projection recapture reused ownership after a hidden phrase field changed')
  assert(baseline_copies==2,'blocked projection copied a baseline it discards')
 end)
 ownership.copy_snapshot=original_copy
 assert(ok,projection_or_error)
end

-- Target restoration reuses its fresh committed proof for draft validation and
-- editor installation without returning the private baseline to the caller.
do
 local song,inst,a,b,source=fixture()
 local ctx=runtime(song)
 local draft=assert(seq.copy_source(source));draft.pitch_events[1]=seq.new_pitch(3,0,false,false)
 assert(cache.put(song,inst,a,draft,'repeat',12,ctx:draft_options()))
 local restored=assert(ctx:restore_editor_target(inst,a))
 assert(restored.target.kind=='owned' and restored.target.baseline==nil)
 assert(restored.source_available==true)
 assert(restored.draft and seq.same_source(restored.source,draft))
 assert(restored.output_policy=='repeat' and restored.pb_range==12)
 assert(seq.same_source(ctx:editor_state().source,draft))
 local original_compare,semantic_compares=ownership.compare,0
 local validator=require('writers.phrase_validator')
 local original_classify,original_classify_against=validator.classify,validator.classify_against
 local proof_calls=0
 validator.classify=function(...)proof_calls=proof_calls+1;return original_classify(...)end
 validator.classify_against=function(...)proof_calls=proof_calls+1;return original_classify_against(...)end
 ownership.compare=function(left,right)
  if type(left)=='table' and type(right)=='table' and left.kind~=nil and right.kind~=nil and
      (left.baseline~=nil or right.baseline~=nil) then semantic_compares=semantic_compares+1 end
  return original_compare(left,right)
 end
 assert(ctx:restore_editor_target(inst,a))
 ownership.compare=original_compare
 validator.classify,validator.classify_against=original_classify,original_classify_against
 assert(semantic_compares==0,'identical private target proofs must skip full semantic baseline comparison')
 assert(proof_calls==1,'same-target restoration must reuse its single fresh target proof')
 local edited=assert(seq.copy_source(draft));edited.pitch_events[1]=seq.new_pitch(6,0,false,false)
 assert(ctx:transition('edit',{source=edited,output_policy='repeat',pb_range=12}))
 proof_calls=0
 validator.classify=function(...)proof_calls=proof_calls+1;return original_classify(...)end
 validator.classify_against=function(...)proof_calls=proof_calls+1;return original_classify_against(...)end
 assert(ctx:restore_editor_target(inst,b))
 validator.classify,validator.classify_against=original_classify,original_classify_against
 assert(proof_calls==1,'durably saved editor draft must avoid revalidating the old target on navigation')
 assert(seq.same_source(cache.get(song,inst,a,ctx:draft_options()),edited),
  'skipping old-target proof must preserve the already durable draft')
 ctx:release_document()
end

-- Hiding a temporary from UI choices never hides its copied ID from ownership inventory.
do
 local song,inst,a,_,source=fixture()
 local temporary=phrase(source,101)
 local other=instrument({temporary})
 song.instruments[2]=other
 local ctx=runtime(song,temporary)
 assert(ctx:bind_phrase(inst,a).kind=='unavailable')
 assert(#assert(ctx:phrase_choices(other))==1)
 assert(not ctx:draft_options().validate(song,inst,a))
end
-- Display projection does not consume a pending native selection change;
-- explicit idle reconciliation still rebinds the selected phrase.
do
 local song,inst,a,b=fixture()
 song.selected_instrument,song.selected_phrase=inst,a
 local ctx=runtime(song)
 ctx:bind_new(inst)
 song.selected_phrase=b
 assert(ctx:target_projection().kind=='new')
 assert(rawequal(ctx:reconcile().phrase,b))
 song.selected_phrase=a
 assert(rawequal(ctx:reconcile().phrase,a))
end
print('ACID runtime object inventory and baseline projection passed')


