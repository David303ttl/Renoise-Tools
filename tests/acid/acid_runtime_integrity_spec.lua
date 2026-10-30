local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')
local function fixture()
 local song,instrument,phrase=helper.fixture()
 local writer={status='idle'}
 function writer:state()return self.status,self.token end
 local log={captures=0,sinks=0,cancels=0}
 local ctx=context.new{writer=writer,capture=function(_,token)
  log.captures=log.captures+1;log.token=token;return {token=token}
 end,sink=function(_,done)log.sinks=log.sinks+1;log.done=done;return true end,
 cancel=function()log.cancels=log.cancels+1;return true end}
 ctx:attach_document(song);ctx:open_dialog()
 local baseline=assert(ctx:bind_phrase(instrument,phrase).baseline)
 assert(not ctx:revalidation_status().verified,'empty evidence cannot yield a recovery proof')
 assert(ctx:request_generation('manual'))
 return ctx,log,writer,song,instrument,phrase,baseline
end
local function evidence(instrument,phrase,baseline,recovery)
 return {reason='Destination rollback incomplete',instrument=instrument,phrase=phrase,
  baseline=baseline,recovery=recovery or {}}
end

-- An epoch blocker survives GUI reopen/navigation and cannot be cleared by settlement.
do
 local ctx,log,writer,song,instrument,phrase,baseline=fixture()
 assert(ctx:record_blocker(log.token,evidence(instrument,phrase,baseline)))
 local state=ctx:integrity_state()
 assert(state.blocked and state.reason=='Destination rollback incomplete')
 state.blocked=false;state.reason='changed'
 assert(ctx:integrity_state().blocked)
 log.done({kind='failed'})
 ctx:close_dialog();ctx:open_dialog();ctx:bind_new(instrument);ctx:refresh_inventory()
 assert(ctx:integrity_state().blocked)
 assert(not ctx:request_generation('manual'))
 assert(log.captures==1 and log.sinks==1)
 local before=song.tool_data
 local snapshot=assert(ownership.snapshot(phrase))
 local status,proof=ctx:revalidation_status()
 assert(status.verified and proof)
 assert(ctx:integrity_state().blocked,'read-only inspection cleared blocker')
 assert(song.tool_data==before and ownership.compare(snapshot,assert(ownership.snapshot(phrase))))
 assert(ctx:revalidate(proof))
 assert(not ctx:integrity_state().blocked and log.sinks==1,'revalidation retried old intent')
end

-- Recovery identity is checked globally; labels are captured and removal must be native.
do
 local ctx,log,_,song,instrument,phrase,baseline=fixture()
 local recovery={name='Neutral recovery'}
 local other=helper.instrument({recovery})
 song.instruments[2]=other
 assert(ctx:record_blocker(log.token,evidence(instrument,phrase,baseline,
  {{instrument=instrument,phrase=recovery,role='backup',label='Captured recovery'}})))
 recovery.name='Renamed natively'
 log.done({kind='failed'})
 local state=ctx:integrity_state()
 assert(state.recovery[1].label=='Captured recovery')
 assert(state.recovery[1].phrase==nil and state.recovery[1].instrument==nil)
 local status=ctx:revalidation_status()
 assert(not status.verified and #other.phrases==1)
 other.phrases={}
 local valid,proof=ctx:revalidation_status()
 assert(valid.verified)
 -- Host mutation after inspection invalidates an otherwise authentic proof.
 phrase.base_note=phrase.base_note+1
 assert(not ctx:revalidate(proof))
 assert(ctx:integrity_state().blocked)
end

-- Proofs are bound to exact blocker versions; a new report retains prior evidence.
do
 local ctx,log,_,_,instrument,phrase,baseline=fixture()
 assert(ctx:record_blocker(log.token,evidence(instrument,phrase,baseline)))
 local _,proof=ctx:revalidation_status()
 assert(not proof,'unsettled accepted operation must prevent revalidation')
 assert(ctx:record_blocker(log.token,evidence(instrument,phrase,baseline)))
 log.done({kind='failed'})
 local valid,current=ctx:revalidation_status()
 assert(valid.verified and current)
 assert(not ctx:revalidate({}),'forged proof accepted')
 ctx:release_document()
 local next_song=helper.fixture()
 ctx:attach_document(next_song);ctx:open_dialog()
 assert(not ctx:integrity_state().blocked)
 assert(not ctx:revalidate(current),'prior-epoch proof accepted')
end

-- Native occupancy persists across cancellation/release until matching terminal delivery.
do
 local ctx,log,writer,_,instrument,phrase,baseline=fixture()
 writer.status,writer.token='busy',log.token
 assert(ctx:record_blocker(log.token,evidence(instrument,phrase,baseline)))
 assert(ctx:occupancy_state(log.token).status=='busy')
 assert(not ctx:revalidation_status().verified)
 ctx:close_dialog();ctx:release_document()
 local next_song=helper.fixture()
 ctx:attach_document(next_song);ctx:open_dialog()
 assert(not ctx:request_generation('manual'))
 assert(log.cancels>0 and log.sinks==1)
 for _=1,3 do ctx:state();ctx:occupancy_state()end
 assert(not ctx:request_generation('manual'),'inspection released missing callback occupancy')
 writer.status,writer.token='idle',nil
 local old_done=log.done
 old_done({kind='canceled'})
 assert(not ctx:integrity_state().blocked)
 assert(ctx:request_generation('manual'))
 local current=log.token
 old_done({kind='committed'})
 assert(rawequal(ctx:state().token,current),'old terminal retired the newer job')
 assert(not ctx:record_blocker({},evidence(instrument,phrase,baseline)))
 assert(rawequal(log.token,current) and not ctx:integrity_state().blocked)
end

-- Lower-level evidence versions and draft guards remain exact while host checks stay read-only.
do
 local song,instrument,phrase=helper.fixture()
 local ctx=helper.runtime(song)
 local baseline=assert(ctx:bind_phrase(instrument,phrase).baseline)
 local descriptor={revision=1}
 local current=true
 local checked=0
 local owner=require('runtime.integrity').new(song,{is_current=function(actual_song,actual)
  assert(rawequal(actual_song,song) and rawequal(actual,descriptor))
  checked=checked+1;return current
 end},function()return true end)
 local report=evidence(instrument,phrase,baseline)
 report.draft_capture=descriptor
 assert(owner:record(report))
 baseline.source.length=9
 local first,stale=owner:status()
 assert(first.verified and stale and checked>0,'evidence baseline was not copied')
 local fresh_baseline=assert(ctx:target_state().baseline)
 assert(owner:record(evidence(instrument,phrase,fresh_baseline)))
 assert(not owner:clear(stale),'older blocker proof cleared newer evidence')
 local valid,proof=owner:status()
 assert(valid.verified and proof)
 current=false
 assert(not owner:clear(proof),'draft revision changed after proof')
 assert(owner:state().blocked)
 current=true
 local _,latest=owner:status()
 assert(owner:clear(latest))
 assert(not owner:state().blocked)
end
do
 local ctx,log,_,song,instrument,phrase,baseline=fixture()
 local cache=require('runtime.draft_cache')
 local seq=require('model.sequencer')
 assert(cache.put(song,instrument,phrase,seq.new_pattern(5),'play_once',0,ctx:draft_options()))
 local descriptor=assert(cache.capture(song,instrument,phrase,ctx:draft_options()))
 local report=evidence(instrument,phrase,baseline)
 report.draft_capture=descriptor
 assert(ctx:record_blocker(log.token,report))
 log.done({kind='failed'})
 local valid,proof=ctx:revalidation_status()
 assert(valid.verified and proof,'real opaque draft descriptor was copied or lost')
 assert(cache.put(song,instrument,phrase,seq.new_pattern(6),'play_once',0,ctx:draft_options()))
 assert(not ctx:revalidate(proof),'newer real draft revision did not block revalidation')
 assert(ctx:integrity_state().blocked)
end
print('ACID runtime integrity blocker and read-only revalidation passed')
