local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local NEWER_EDIT_NOTE=11
local OWNED_PHRASE_ID=101
local CREATED_PHRASE_ID=103
local function fixture(new)
 local song,instrument,phrase,other,source=helper.fixture(new and 'new')
 if new then
  phrase,other=helper.phrase(source,OWNED_PHRASE_ID),helper.phrase(source,CREATED_PHRASE_ID)
  phrase.name,other.name="Native phrase","Other native phrase"
  instrument.phrases={phrase,other}
 end
 local log={sinks=0,requests={},cancels=0}
 local ctx=context.new{writer={state=function()return 'idle',nil end},
  sink=function(request,done)
   log.sinks=log.sinks+1;log.requests[#log.requests+1]=request
   done({kind='failure',status='failed',token=request.token,epoch=request.epoch,request=request})
   return true
  end,cancel=function()log.cancels=log.cancels+1;return true end}
 ctx:attach_document(song);ctx:open_dialog()
 if new then ctx:transition("target",{instrument=instrument,kind="new"})else ctx:transition("target",{instrument=instrument,phrase=phrase,kind="existing"})end
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0})
 return ctx,log,song,instrument,phrase,other,source
end
local function values(source)return {source=source,output_policy='play_once',pb_range=0}end
local function copy_edit(source,note)
 local copy=assert(seq.copy_source(source));copy.pitch_events[1]=seq.new_pitch(note,0,false,false)
 return copy
end

-- A changed source is detached once to issue its prepared resolution snapshot.
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
 assert(validation_copies>=1,'edit did not issue a detached resolution snapshot')
end

-- Source values and revision identities remain distinct through A -> B -> A.
do
 local ctx,log,song,instrument,_,_,source=fixture(true)
 local before=ctx:revision_state()
 ctx:transition('edit',values(source))
 assert(ctx:revision_state().edit_revision==before.edit_revision and log.sinks==0,
   tostring(before.edit_revision).." -> "..tostring(ctx:revision_state().edit_revision).." sinks="..log.sinks)
 local changed=copy_edit(source,7)
 ctx:transition('edit',values(changed))
 local middle=ctx:revision_state()
 assert(middle.edit_revision==before.edit_revision+1)
 ctx:transition('edit',values(source))
 assert(ctx:revision_state().edit_revision==middle.edit_revision+1)
 local edited=ctx:editor_state()
 edited.source.length=9
 assert(ctx:editor_state().source.length==source.length)
 local draft=assert(cache.restore(song,instrument,nil,ctx:draft_options()))
 assert(draft.length==source.length)
 ctx:transition('arm')
 assert(log.sinks==0,'arming generated music')
 ctx:transition('reset',values(changed))
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
 local _,_,_,restored=cache.restore(song,instrument,phrase,ctx:draft_options())
 assert(restored and restored.origin=='committed')
 ctx:transition("target",{instrument=instrument,kind="new"})
 local _,_,_,new_restored=cache.restore(song,instrument,phrase,ctx:draft_options())
 assert(new_restored and new_restored.origin=='committed','clean navigation created a draft')
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

-- Owned navigation preserves drafts without generating music.
do
 local ctx,log,song,instrument,phrase,other=fixture()
 assert(cache.restore(song,instrument,phrase,ctx:draft_options()))
 ctx:transition("target",{instrument=instrument,phrase=other,kind="existing"})
 ctx:transition("target",{instrument=instrument,phrase=phrase,kind="existing"})
 assert(log.sinks==0,'navigation generated music')
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
 ctx:transition("target",{instrument=instrument,kind="new"})
 local invalid=seq.copy_source(source);invalid.length=0
 ctx:transition('edit',values(invalid))
 assert(log.sinks==0 and ctx:editor_state().source.length==0)
 assert(not ctx:request_generation('manual'))
 ctx:transition('programmatic',values(source))
 local released,warning=ctx:release_document()
 assert(released and warning=='Invalid ACID editor buffers are session-only and were released',
   'document release did not report the discarded invalid editor buffer')
end

-- Reorder/rename refresh preserves revisions; removal and native object changes invalidate.
do
 local ctx,log,song,instrument,phrase,other=fixture()
 local before=ctx:revision_state()
 instrument.phrases={other,phrase};instrument.name='Renamed'
 ctx:refresh_inventory()
 local after=ctx:revision_state()
 assert(after.target_revision==before.target_revision and log.sinks==0)
 ctx:transition('native_target',{instrument=instrument,phrase=other,kind='owned'})
 assert(rawequal(ctx:target_state().phrase,other))
 assert(log.sinks==0)
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
 assert(ctx:transition("target",{instrument=instrument,phrase=phrase,kind="existing"}).kind~='owned','duplicate ownership ID became writable')
 assert(not ctx:request_generation('manual'),'colliding ownership ID passed Generate admission')
 assert(log.sinks==0)
 copied.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns].delay_value=1
 assert(ctx:transition("target",{instrument=instrument,phrase=phrase,kind="existing"}).kind~='owned','modified collision holder became writable')
 assert(not ctx:request_generation('manual'),'modified collision holder passed Generate admission')
 assert(log.sinks==0)
end
do
 local ctx,log,song,instrument,phrase,other,source=fixture()
 assert(cache.put(song,instrument,other,seq.new_pattern(6),'play_once',0,ctx:draft_options()))
 local changed=copy_edit(source,7)
 ctx:transition('edit',values(changed))
 ctx:transition("target",{instrument=instrument,phrase=other,kind="existing"})
 assert(not ctx:request_generation('manual'),'unloaded target reused outgoing source')
 assert(log.sinks==0)
 assert(cache.restore(song,instrument,other,ctx:draft_options()).length==6,'outgoing editor overwrote another target draft')
 ctx:transition("target",{instrument=instrument,phrase=phrase,kind="existing"})
 assert(seq.same_source(ctx:editor_state().source,changed))
 assert(log.sinks==0)
end

print('ACID runtime editor transitions and guarded generation passed')
