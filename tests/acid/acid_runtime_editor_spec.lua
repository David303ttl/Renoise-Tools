local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local function fixture()
 local song,instrument,phrase,other,source=helper.fixture()
 local log={captures=0,sinks=0,requests={},done={},cancels=0}
 local ctx=context.new{writer={state=function()return 'idle',nil end},
  capture=function(trigger,token)
   log.captures=log.captures+1;return {trigger=trigger,token=token}
  end,sink=function(request,done)
   log.sinks=log.sinks+1;log.requests[#log.requests+1]=request
   log.done[#log.done+1]=done;return true
  end,cancel=function()log.cancels=log.cancels+1;return true end}
 ctx:attach_document(song);ctx:open_dialog();ctx:bind_phrase(instrument,phrase)
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0})
 return ctx,log,song,instrument,phrase,other,source
end
local function values(source)return {source=source,output_policy='play_once',pb_range=0}end
local function copy_edit(source,note)
 local copy=assert(seq.copy_source(source));copy.pitch_events[1]=seq.new_pitch(note,0,false,false)
 return copy
end

-- Source values and revision identities remain distinct through A -> B -> A.
do
 local ctx,log,song,instrument,phrase,other,source=fixture()
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
 assert(cache.get(song,instrument,phrase,ctx:draft_options()))
 ctx:bind_phrase(instrument,other)
 ctx:bind_phrase(instrument,phrase)
 assert(log.sinks==0,'navigation generated music')
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
 assert(log.sinks==1,'real armed edit did not use generation entry')
end

-- Arming intent is independent of a captured manual operation.
do
 local ctx,log,_,_,_,_,source=fixture()
 assert(ctx:request_generation('manual'))
 local token=log.requests[1].token
 ctx:transition('arm');ctx:transition('disarm')
 assert(token:is_current(),'disarm revoked manual authorization')
 assert(log.sinks==1)
 log.done[1]({kind='failed'})
 ctx:transition('arm');ctx:transition('edit',values(copy_edit(source,7)))
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
 copied.lines[512].note_columns[12].delay_value=1
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
print('ACID runtime editor transitions and guarded generation passed')
