local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local store=require('renoise.pattern_store')
local capabilities=require('renoise.target_capabilities')
local validator=require('writers.phrase_validator')
local pitch_bend=require('writers.phrase_pitch_bend')
local NEWER_EDIT_NOTE=11
local FIRST_COMMITTED_NOTE=9
local OWNED_PHRASE_ID=101
local CREATED_PHRASE_ID=103
local function fixture(new)
 local song,instrument,phrase,other,source=helper.fixture(new and 'new')
 local log={captures=0,sinks=0,requests={},done={},cancels=0}
 local ctx=context.new{writer={state=function()return 'idle',nil end},
  capture=function(trigger,token)
   log.captures=log.captures+1;return {trigger=trigger,token=token}
  end,sink=function(request,done)
   log.sinks=log.sinks+1;log.requests[#log.requests+1]=request
   log.done[#log.done+1]=done;return true
  end,cancel=function()log.cancels=log.cancels+1;return true end}
 ctx:attach_document(song);ctx:open_dialog()
 if new then ctx:bind_new(instrument)else ctx:bind_phrase(instrument,phrase)end
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0})
 return ctx,log,song,instrument,phrase,other,source
end
local function values(source)return {source=source,output_policy='play_once',pb_range=0}end
local function copy_edit(source,note)
 local copy=assert(seq.copy_source(source));copy.pitch_events[1]=seq.new_pitch(note,0,false,false)
 return copy
end

local function validated_baseline(song,instrument,phrase,id)
 local profile=assert(capabilities.inspect(instrument))
 local limits={max_lines=helper.limits.max_lines,max_note_columns=helper.limits.max_note_columns,
  max_effect_columns=helper.limits.max_effect_columns,
  play_pattern=renoise.InstrumentPhrase.PLAY_PATTERN,
  key_tracking_none=renoise.InstrumentPhrase.KEY_TRACKING_NONE}
 local classified=assert(validator.classify(song,instrument,phrase,
   profile,limits,{pitch_bend_delivery=pitch_bend.delivery_enabled}))
 return {id=id,source=classified.source,settings=classified.settings,
   snapshot=classified.baseline,planning_inputs=classified.planning_inputs}
end

local function verify_rebase(persistence_failure)
 local ctx,log,song,instrument,phrase,other,source=fixture()
 assert(ctx:transition('edit',{source=copy_edit(source,FIRST_COMMITTED_NOTE),
   output_policy='play_once',pb_range=0}))
 assert(ctx:request_generation('manual'))
 local request=log.requests[1]
 local newer=copy_edit(source,NEWER_EDIT_NOTE)
 local write_draft=store.write_draft
 if persistence_failure then
  store.write_draft=function()return false,'injected draft persistence failure'end
 end
 local edited,edit_error=ctx:transition('edit',{source=newer,output_policy='play_once',pb_range=0})
 assert(edited,edit_error or 'newer edit failed')
 local expected_warning=persistence_failure and 'injected draft persistence failure' or nil
 assert(ctx:editor_state().draft_warning==expected_warning,
   'newer draft persistence warning is incorrect')
 local draft_matches,before_rebind=cache.matches_values(song,instrument,phrase,newer,'play_once',0)
 assert(draft_matches and type(before_rebind)=='table','newer session draft metadata is unavailable')

 -- Model the committed request output and obtain its baseline from the production validator.
 local committed_phrase=helper.phrase(request.source,OWNED_PHRASE_ID)
 for key,value in pairs(committed_phrase)do phrase[key]=value end
 assert(store.save(song,OWNED_PHRASE_ID,request.source,request.output_policy,request.pb_range))
 local committed_baseline=validated_baseline(song,instrument,phrase,OWNED_PHRASE_ID)

 log.done[1]({kind='success',status='committed',verified=true,token=request.token,
   epoch=request.epoch,request=request,phrase=phrase,baseline=committed_baseline})
 store.write_draft=write_draft

 local state=ctx:generation_state()
 assert(not state.last_commit,'older editor revision was recorded as the current commit')
 assert(ctx:target_state().baseline.source.pitch_events[1].note==
   request.source.pitch_events[1].note,'committed baseline was not advanced')
 assert(ctx:editor_state().draft_warning==expected_warning,
   'rebase changed the draft persistence warning')
 assert(ctx:editor_state().source.pitch_events[1].note==seq.BASE_NOTE+NEWER_EDIT_NOTE,
   'newer editor source was replaced by committed output')
 local retained=cache.get(song,instrument,phrase,ctx:draft_options())
 assert(retained and retained.pitch_events[1].note==seq.BASE_NOTE+NEWER_EDIT_NOTE,
   'newer session draft was cleared after the committed baseline changed')
 local still_matches,after_rebind=cache.matches_values(song,instrument,phrase,newer,'play_once',0)
 assert(still_matches and after_rebind.token==before_rebind.token and
   after_rebind.revision==before_rebind.revision,
   'baseline rebind changed the session draft token or edit revision')
 assert(after_rebind.persistent==not persistence_failure and
   after_rebind.warning==expected_warning,
   'baseline rebind changed persistence state or warning metadata')
 assert(ctx:restore_editor_target(instrument,other))
 assert(ctx:restore_editor_target(instrument,phrase))
 assert(ctx:editor_state().source.pitch_events[1].note==seq.BASE_NOTE+NEWER_EDIT_NOTE,
   'navigation did not restore the newer rebased draft')
end

verify_rebase(true)
verify_rebase(false)

local function verify_create_transfer(failure)
 local ctx,log,song,instrument,_,_,source=fixture(true)
 assert(ctx:transition('edit',values(copy_edit(source,FIRST_COMMITTED_NOTE))))
 assert(ctx:request_generation('manual'))
 local request=log.requests[1]
 local newer=copy_edit(source,NEWER_EDIT_NOTE)
 assert(ctx:transition('edit',values(newer)))
 local draft_matches,new_metadata=cache.matches_values(song,instrument,nil,newer,'play_once',0)
 assert(draft_matches and type(new_metadata)=='table','newer New draft metadata is unavailable')
 local new_capture=assert(cache.capture(song,instrument,nil,ctx:draft_options()))
 local created=helper.phrase(request.source,CREATED_PHRASE_ID)
 instrument.phrases[#instrument.phrases+1]=created
 assert(store.save(song,CREATED_PHRASE_ID,request.source,request.output_policy,request.pb_range))
 local durable_before=song.tool_data
 local write_draft=store.write_draft
 local put=cache.put
 if failure=='persistence' then
  store.write_draft=function()return false,'injected destination draft persistence failure'end
 elseif failure=='session' then
  cache.put=function(target_song,target_instrument,target_phrase,...)
   if rawequal(target_phrase,created) then return nil,'injected destination session transfer failure'end
   return put(target_song,target_instrument,target_phrase,...)
  end
 end
 local baseline=validated_baseline(song,instrument,created,CREATED_PHRASE_ID)
 log.done[1]({kind='success',status='committed',verified=true,token=request.token,
  epoch=request.epoch,request=request,phrase=created,baseline=baseline})
 store.write_draft=write_draft
 cache.put=put
 assert(log.sinks==1,'newer create draft triggered a second render')
 if failure=='session' then
  local retained,new_metadata_after=cache.matches_values(song,instrument,nil,newer,'play_once',0)
  assert(retained and new_metadata_after.token==new_metadata.token and
   new_metadata_after.revision==new_metadata.revision and cache.is_current(song,new_capture),
   'failed destination session transfer consumed the newer New draft revision')
  assert(song.tool_data==durable_before,
   'failed destination session transfer changed durable New draft bytes')
  assert(ctx:editor_state().draft_warning=='injected destination session transfer failure',
   'failed destination session transfer warning was lost')
  local restored_new=assert(ctx:restore_editor_target(instrument,nil))
  assert(restored_new.source.pitch_events[1].note==seq.BASE_NOTE+NEWER_EDIT_NOTE,
   'failed destination session transfer did not restore the New draft')
 else
  assert(not cache.is_current(song,new_capture),
   'successful destination session copy did not clear the captured New revision')
  local scratch,scratch_policy,scratch_pb=store.read_draft(song,instrument,nil)
  assert(scratch and seq.same_source(scratch,newer) and scratch_policy=='play_once' and scratch_pb==0,
   'destination transfer changed durable New draft bytes')
  local expected_warning=failure=='persistence' and
   'injected destination draft persistence failure' or nil
  assert(ctx:editor_state().draft_warning==expected_warning,
   'create transfer did not preserve its persistence warning: '..tostring(failure)..'/'..
    tostring(ctx:editor_state().draft_warning)..' expected '..tostring(expected_warning))
  local restored=assert(ctx:restore_editor_target(instrument,created))
  assert(restored.source.pitch_events[1].note==seq.BASE_NOTE+NEWER_EDIT_NOTE,
   'successful create did not preserve the newer New draft on the created phrase')
  local matches,metadata=cache.matches_values(song,instrument,created,newer,'play_once',0)
  local persistent=failure~='persistence'
  assert(matches and metadata.persistent==persistent,
   'created phrase draft persistence state is incorrect')
  if failure=='persistence' then
   assert(song.tool_data==durable_before,
    'failed destination persistence changed durable New draft bytes')
  end
 end
end

verify_create_transfer(nil)
verify_create_transfer('persistence')
verify_create_transfer('session')

-- Runtime admission validates its detached editor buffer without an extra source copy.
do
 local ctx,_,_,_,_,_,source=fixture(true)
 local changed=copy_edit(source,7)
 local copy_source=seq.copy_source
 local put=cache.put
 local persistence_depth=0
 local validation_copies=0
 local unpack_values=unpack or table.unpack
 local function pack_values(...)return {n=select('#',...),...}end
 seq.copy_source=function(...)
  if persistence_depth==0 then validation_copies=validation_copies+1 end
  return copy_source(...)
 end
 cache.put=function(...)
  persistence_depth=persistence_depth+1
  local result=pack_values(pcall(put,...))
  persistence_depth=persistence_depth-1
  if not result[1] then error(result[2],0) end
  return unpack_values(result,2,result.n)
 end
 local called,edited,edit_error=pcall(ctx.transition,ctx,'edit',values(changed))
 seq.copy_source=copy_source
 cache.put=put
 assert(called and edited,edit_error or 'source edit transition failed')
 assert(validation_copies==0,'edit made a discarded validation copy outside draft persistence')
end

-- Source values and revision identities remain distinct through A -> B -> A.
do
 local ctx,log,song,instrument,_,_,source=fixture(true)
 local before=ctx:revision_state()
 ctx:transition('edit',values(source))
 assert(ctx:revision_state().edit_revision==before.edit_revision and log.sinks==0)
 local changed=copy_edit(source,7)
 ctx:transition('edit',values(changed))
 local middle=ctx:revision_state()
 assert(middle.edit_revision==before.edit_revision+1)
 ctx:transition('edit',values(source))
 assert(ctx:revision_state().edit_revision==middle.edit_revision+1)
 local edited=ctx:editor_state()
 edited.source.length=9
 assert(ctx:editor_state().source.length==source.length)
 assert(cache.get(song,instrument,nil,ctx:draft_options()))
 ctx:transition('arm')
 assert(log.sinks==0,'arming generated music')
 ctx:transition('reset',values(changed))
 ctx:transition('recovery',values(source))
 ctx:transition('programmatic',values(changed))
 assert(log.sinks==0,'guarded source load generated music')
 local revision=ctx:revision_state().edit_revision
 ctx:transition('edit',values(changed))
 assert(log.sinks==0 and ctx:revision_state().edit_revision==revision)
 ctx:transition('edit',values(source))
 assert(log.sinks==0 and ctx:generation_state().pending,'Live Edit did not queue without rendering in the edit callback')
 ctx:flush_pending()
 assert(log.sinks==1,'real armed edit did not use generation entry')
end

-- Restoring a committed source does not create a dirty draft.
do
 local ctx,log,song,instrument,phrase,_,source=fixture()
 cache.clear(song,instrument,phrase,ctx:draft_options())
 local restored=values(copy_edit(source,7));restored.restore=true
 ctx:transition('programmatic',restored)
 assert(cache.get(song,instrument,phrase,ctx:draft_options())==nil)
 ctx:bind_new(instrument)
 assert(cache.get(song,instrument,phrase,ctx:draft_options())==nil,'clean navigation created a draft')
 assert(log.sinks==0,'restoring source generated music')
end

-- Armed edits enter the runtime scheduler immediately.
do
 local ctx,log,_,_,_,_,source=fixture(true)
 ctx:transition('arm')
 local changed=values(copy_edit(source,7))
 local _,effects=ctx:transition('edit',changed)
 assert(effects.live_intent and effects.accepted==true and log.sinks==0 and ctx:generation_state().pending,
   'armed edit did not queue without rendering in the editor callback')
 ctx:flush_pending()
 assert(log.sinks==1 and log.requests[1].trigger=='live','idle scheduler did not admit the queued Live Edit')
end

-- Disarming drops only pending Live Edit; manual intent remains queued.
do
 local ctx,log,_,_,_,_,source=fixture(true)
 ctx:transition('arm')
 ctx:transition('edit',values(copy_edit(source,7)))
 ctx:flush_pending()
 local live=log.requests[1]
 ctx:request_generation('manual')
 assert(ctx:generation_state().pending,'manual intent was not queued')
 ctx:transition('disarm')
 ctx:transition('edit',values(copy_edit(source,8)))
 assert(not live.token:is_current() and log.sinks==1)
 log.done[1]({kind='failure',status='cancelled',verified=false,reason='cancel',
   token=live.token,epoch=live.epoch,request=live})
 ctx:flush_pending()
 assert(log.sinks==2 and log.requests[2].trigger=='manual',
   'disarming Live Edit discarded or ran an independent manual request')
end

-- Verified success adopts the writer baseline; unverified success cannot.
do
 local ctx,log,song,instrument,phrase,_,source=fixture()
 assert(ctx:request_generation('manual'))
 local request=log.requests[1]
 log.done[1]({kind='success',status='committed',verified=true,token=request.token,
   epoch=request.epoch,request=request,phrase=phrase,baseline=request.baseline})
 assert(ctx:generation_state().last_commit,'verified success was not recorded')
 assert(ctx:target_state().kind=='owned' and ctx:request_generation('manual'),
   'adopted baseline did not support the next request')
 local second=log.requests[2]
 log.done[2]({kind='success',status='committed',verified=false,token=second.token,
   epoch=second.epoch,request=second,phrase=phrase,baseline=second.baseline})
 assert(log.requests[2].token:is_current()==false)
end

-- A terminal tagged integrity_blocked is never adopted as clean success.
do
 local ctx,log,_,_,phrase,_,_=fixture()
 assert(ctx:request_generation('manual'))
 local request=log.requests[1]
 log.done[1]({kind='failure',status='integrity_blocked',verified=false,
   token=request.token,epoch=request.epoch,request=request,phrase=nil,
   baseline=request.baseline,message='recovery material retained'})
 local state=ctx:generation_state()
 assert(state.last_result and state.last_result.kind=='failure' and not state.last_commit,
   'integrity-blocked success was adopted as a clean commit')
end

-- Rapid Live Edits keep one latest pending request while the writer is busy.
do
 local ctx,log,_,_,_,_,source=fixture(true)
 ctx:transition('arm')
 ctx:transition('edit',values(copy_edit(source,7)))
 ctx:flush_pending()
 assert(log.sinks==1)
 local first_token=log.requests[1].token
 ctx:transition('edit',values(copy_edit(source,8)))
 ctx:transition('edit',values(copy_edit(source,9)))
 assert(log.sinks==1 and not first_token:is_current(),'newer edits did not supersede the active request')
 local state=ctx:generation_state()
 assert(state.pending and state.status=='DIRTY','latest Live Edit was not retained as pending')
 log.done[1]({kind='failure',status='cancelled',verified=false,reason='test cancel',
   token=first_token,epoch=log.requests[1].epoch,request=log.requests[1]})
 ctx:flush_pending()
 assert(log.sinks==2,'pending Live Edit did not dispatch after terminal completion')
 assert(log.requests[2].source.pitch_events[1].note==seq.BASE_NOTE+9,
   'pending dispatch did not capture the latest source')
end

-- Owned navigation preserves drafts without generating music.
do
 local ctx,log,song,instrument,phrase,other=fixture()
 assert(cache.get(song,instrument,phrase,ctx:draft_options()))
 ctx:bind_phrase(instrument,other)
 ctx:bind_phrase(instrument,phrase)
 assert(log.sinks==0,'navigation generated music')
end

-- Arming intent is independent of a captured manual operation.
do
 local ctx,log,_,_,_,_,source=fixture(true)
 assert(ctx:request_generation('manual'))
 local token=log.requests[1].token
 ctx:transition('arm');ctx:transition('disarm')
 assert(token:is_current(),'disarm revoked manual authorization')
 assert(log.sinks==1)
 log.done[1]({kind='failed'})
 ctx:transition('arm');ctx:transition('edit',values(copy_edit(source,7)))
 ctx:flush_pending()
 assert(log.sinks==2)
 local live=log.requests[2].token
 ctx:transition('disarm')
 assert(not live:is_current() and log.sinks==2)
end

-- Blocked/invalid source edits remain inspectable and cannot fall back to create.
do
 local ctx,log,song,instrument,phrase,_,source=fixture()
 ctx:transition('arm')
 phrase.name='Foreign phrase'
 ctx:refresh_inventory()
 ctx:transition('edit',values(copy_edit(source,7)))
 assert(log.sinks==0 and ctx:editor_state().source.pitch_events[1].note==seq.BASE_NOTE+7)
 assert(not ctx:musical_eligibility())
 assert(not ctx:request_generation('manual'))
 assert(#instrument.phrases==2 and log.sinks==0)
 ctx:bind_new(instrument)
 local invalid=seq.copy_source(source);invalid.length=0
 ctx:transition('edit',values(invalid))
 assert(log.sinks==0 and ctx:editor_state().source.length==0)
 assert(not ctx:request_generation('manual'))
 ctx:transition('programmatic',values(source))
 local recoverable=ctx:editor_recovery()
 assert(#recoverable>0 and recoverable[#recoverable].source.length==0)
 recoverable[#recoverable].source.length=17
 local pristine=ctx:editor_recovery()
 assert(pristine[#pristine].source.length==0,'invalid recovery projection was mutable')
end

-- Reorder/rename refresh preserves revisions; removal and native object changes revoke.
do
 local ctx,log,song,instrument,phrase,other=fixture()
 assert(ctx:request_generation('manual'))
 local token=log.requests[1].token
 local before=ctx:revision_state()
 instrument.phrases={other,phrase};instrument.name='Renamed'
 ctx:refresh_inventory()
 local after=ctx:revision_state()
 assert(after.target_revision==before.target_revision and token:is_current())
 ctx:transition('native_target',{instrument=instrument,phrase=other,kind='owned'})
 assert(not token:is_current() and rawequal(ctx:target_state().phrase,other))
 assert(log.sinks==1)
 ctx:transition('native_target',{instrument=instrument,phrase=nil})
 assert(ctx:target_state().kind=='unavailable','native missing phrase became New')
end
do
 local ctx,log,song,instrument,phrase,_,source=fixture()
 local copied=helper.phrase(source,101)
 local other=helper.instrument({copied})
 song.instruments[2]=other
 ctx:refresh_inventory()
 assert(not ctx:musical_eligibility())
 assert(ctx:independence_eligibility(),'matching collision should permit explicit resolution proof')
 assert(log.sinks==0)
 copied.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value=1
 assert(not ctx:independence_eligibility(),'modified collision holder qualified for resolution')
 assert(log.sinks==0)
end
do
 local ctx,log,song,instrument,phrase,other,source=fixture()
 assert(cache.put(song,instrument,other,seq.new_pattern(6),'play_once',0,ctx:draft_options()))
 local changed=copy_edit(source,7)
 ctx:transition('edit',values(changed))
 ctx:bind_phrase(instrument,other)
 assert(not ctx:request_generation('manual'),'unloaded target reused outgoing source')
 assert(log.sinks==0)
 assert(cache.get(song,instrument,other,ctx:draft_options()).length==6,'outgoing editor overwrote another target draft')
 ctx:bind_phrase(instrument,phrase)
 assert(seq.same_source(ctx:editor_state().source,changed))
 assert(log.sinks==0)
end

do
 local song,instrument,phrase,other,source=helper.fixture()
 song.selected_instrument,song.selected_phrase=instrument,other
 local writer={status='idle'}
 function writer:state() return self.status,nil end
 local temporary
 function writer.is_temporary(_,candidate_instrument,candidate_phrase)
  return rawequal(candidate_instrument,instrument) and rawequal(candidate_phrase,temporary)
 end
 local requests=0
 local ctx=context.new{writer=writer,capture=function(trigger,token)return {trigger=trigger,token=token}end,
  sink=function()requests=requests+1;return true end,cancel=function()return true end}
 ctx:attach_document(song);ctx:open_dialog();ctx:bind_phrase(instrument,phrase)
 ctx:transition('programmatic',values(source));ctx:transition('arm')
 ctx:transition('edit',values(copy_edit(source,7)))
 assert(ctx:generation_state().pending,'armed edit was not queued')
 writer.status='busy'
 song.selected_phrase=phrase
 ctx:reconcile()
 assert(ctx:generation_state().pending,'same-target native selection canceled the queued edit')
 temporary={name='ACID staging phrase'}
 song.selected_phrase=temporary
 ctx:reconcile()
 assert(ctx:generation_state().pending,'writer staging selection canceled the queued edit')
 song.selected_phrase=phrase
 temporary=nil
 writer.status='idle'
 ctx:reconcile()
 assert(ctx:generation_state().pending,'restored native selection canceled the queued edit')
 assert(ctx:flush_pending() and requests==1,'queued latest edit did not dispatch after writer became idle')
end
print('ACID runtime editor transitions and guarded generation passed')
