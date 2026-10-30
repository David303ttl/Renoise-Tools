local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local seq=require('model.sequencer')
local store=require('renoise.pattern_store')
local cache=require('runtime.draft_cache')
local unreachable=dofile('tests/assert_unreachable.lua')
local function fixture(new)
 local song,instrument,phrase,other,source=helper.fixture(new and 'new')
 local writer={status='idle'}
 function writer:state()return self.status,self.token end
 function writer:is_temporary()return false end
 local log={sinks=0}
 local ctx=context.new{writer=writer,capture=function()error('runtime must own editor capture')end,
  sink=function(request,done)log.sinks=log.sinks+1;log.request=request;log.done=done;return true end,
  cancel=function()return true end}
 ctx:attach_document(song);ctx:open_dialog()
 if new then ctx:bind_new(instrument)else ctx:bind_phrase(instrument,phrase)end
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0})
 assert(ctx:request_generation('manual'))
 return ctx,log,writer,song,instrument,phrase,other,source
end

do
 local _,log,writer,song,instrument,phrase,_,source=fixture()
 local request=log.request
 assert(request.kind=='regenerate' and request.target_kind=='owned')
 assert(rawequal(request.instrument,instrument) and rawequal(request.phrase,phrase))
 assert(request.id==101 and request.baseline and request.planning_inputs)
 assert(request:is_current() and request:validate_checkpoint())
 assert(cache.is_current(song,request.draft_capture),'draft descriptor lost opaque identity')
 writer.status,writer.token='busy',request.token
 assert(request:validate_checkpoint(),'own occupied slot rejected its accepted request')
 writer.token={}
 assert(not request:validate_checkpoint(),'another job occupancy accepted')
 writer.status,writer.token='idle',nil
 source.pitch_events[1].accent=true
 assert(not request.source.pitch_events[1].accent,'captured source retained editor input')
end
-- A newer captured draft revision revokes the exact request guard.
do
 local ctx,log,_,song,instrument,phrase=fixture()
 assert(cache.put(song,instrument,phrase,seq.new_pattern(5),'play_once',0,ctx:draft_options()))
 assert(not log.request:is_current(),'draft revision change did not revoke exact capture')
 assert(not log.request:validate_checkpoint())
end

do
 local _,log=fixture(true)
 log.request.source.length=9
 assert(not log.request:validate_checkpoint(),'public request tampering escaped frozen comparison')
end

do
 local _,log=fixture(true)
 local profile=log.request.capabilities
 local key,value=next(profile)
 assert(key~=nil,'request capability profile is empty')
 profile[key]=type(value)=='boolean' and not value or type(value)=='number' and value+1 or 'changed'
 assert(not log.request:validate_checkpoint(),'public capability mutation escaped frozen comparison')
end

do
 local ctx,log=fixture(true)
 local policies=require('model.policies')
 local previous=policies.NORMAL_VOLUME
 policies.NORMAL_VOLUME=previous==0.7 and 0.6 or 0.7
 local valid=log.request:validate_checkpoint()
 policies.NORMAL_VOLUME=previous
 assert(not valid,'Live request reused a plan after its default volume changed')
end

local mutations={
 capability=function(ctx,log,writer,song,instrument)instrument.plugin_properties.plugin_loaded=true end,
 phrase_program=function(ctx,log,writer,song,instrument)instrument.phrase_program=2 end,
 pb_option=function()require('writers.phrase_pitch_bend').delivery_enabled=false end,
 source=function(ctx,log,writer,song,instrument,phrase,other,source)
  local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
  assert(store.save(song,101,changed,'play_once',0))
 end,
 replacement=function(ctx,log,writer,song,instrument,phrase,other,source)instrument.phrases[1]=helper.phrase(source,101)end,
 collision=function(ctx,log,writer,song,instrument,phrase,other,source)song.instruments[2]=helper.instrument({helper.phrase(source,101)})end,
 undo=function(ctx,log,writer,song)song.is_undo_redoing=function()return true end end,
 timing=function(ctx,log,writer,song)song.transport.timing_model=2 end,
 groove=function(ctx,log,writer,song)song.transport.groove_enabled=true end,
 close=function(ctx)ctx:close_dialog();ctx:open_dialog()end,
 edit=function(ctx,log,writer,song,instrument,phrase,other,source)
  local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
  ctx:transition('edit',{source=changed,output_policy='play_once',pb_range=0})
 end,
 draft=function(ctx,log,writer,song,instrument,phrase)
  assert(cache.put(song,instrument,phrase,seq.new_pattern(5),'play_once',0,ctx:draft_options()))
 end,
 blocker=function(ctx,log,writer,song,instrument,phrase)
  assert(ctx:record_blocker(log.request.token,{reason='Recovery required',instrument=instrument,
   phrase=phrase,baseline=log.request.baseline}))
 end,
}
-- Only destination-specific guards need the full owned-phrase baseline.
local owned_destination={source=true,replacement=true,collision=true,draft=true,blocker=true,phrase_program=true}
for name,mutate in pairs(mutations)do
 local args={fixture(not owned_destination[name])}
 local ctx,log=args[1],args[2]
 mutate((unpack or table.unpack)(args))
 local valid,reason=log.request:validate_checkpoint()
 assert(not valid and type(reason)=='string',name..' did not fail closed')
 assert(log.sinks==1,name..' started another sink')
 require('writers.phrase_pitch_bend').delivery_enabled=true
end

do
 local ctx,log,_,song,instrument,_,_,source=fixture()
 local request,token=log.request,log.request.token
 assert(not request:cleanup_authorized(token),'current write token acquired cleanup authority')
 assert(not pcall(function() request:cleanup_mutate(token,function()return true end) end),
  'cleanup-only mutation accepted a current write token')
 assert(ctx:revoke(token,'superseded'))
 assert(request:cleanup_authorized(token),'revoked current-operation cleanup authority was not retained')
 local called=false
 local temporary=helper.phrase(source,103)
 temporary.id=nil;temporary.name='ACID staging phrase'
 instrument.phrase_mappings=instrument.phrase_mappings or {}
 instrument.phrases[#instrument.phrases+1]=temporary
 assert(request:cleanup_mutate(token,function()
   called=true
   for index,phrase in ipairs(instrument.phrases) do
    if rawequal(phrase,temporary) then table.remove(instrument.phrases,index);return true end
   end
   return false
  end))
 assert(called,'revoked cleanup did not run inside a mutation scope')
 assert(not require('renoise.phrase_ownership').membership(song,instrument,temporary),
  'revoked cleanup left the staged phrase behind')
 local matched,match_reason=ctx:matches_mutation_inventory(instrument,'phrases')
 assert(matched,'the delayed phrase inventory notification was not matched to authorized cleanup: '..tostring(match_reason))
 ctx:release_document()
 assert(not pcall(function() request:cleanup_mutate(token,function()error('released cleanup ran')end) end),
  'cleanup mutation accessed a released document')
end

do
 local ctx,log,_,song,instrument,phrase,other,source=fixture(true)
 assert(log.request.kind=='create' and log.request.target_kind=='new')
 assert(log.request.phrase==nil and log.request.baseline==nil)
 assert(rawequal(log.request.instrument,instrument) and log.request:validate_checkpoint())
 assert(ctx:validate_checkpoint(log.request))
 assert(not log.request:cleanup_authorized(log.request.token))
 assert(ctx:revoke(log.request.token,'cancelled'))
 assert(log.request:cleanup_authorized(log.request.token))
 assert(not log.request:cleanup_authorized({}))
 log.request.baseline={id=101}
 assert(not log.request:validate_checkpoint(),'New acquired a forged existing baseline')
 log.request.baseline=nil
 ctx:release_document()
 assert(not log.request:is_current() and not log.request:validate_checkpoint())
 assert(not log.request:cleanup_authorized(log.request.token))
 unreachable({request=log.request,done=log.done},{song=song,instrument=instrument,
  phrase=phrase,other=other,source=source})
end

do
 local ctx,log,_,_,_,_,_,source=fixture(true)
 local request=log.request
 local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
 ctx:transition('edit',{source=changed,output_policy='play_once',pb_range=0})
 ctx:transition('edit',{source=source,output_policy='play_once',pb_range=0})
 assert(not request:is_current(),'A-B-A resurrected cheap captured revision guard')
 assert(not request:validate_checkpoint())
 assert(log.sinks==1)
end
-- A clean committed destination needs no session draft; rejected admission
-- must not write one, and successful regeneration must not invent one.
do
 local song,instrument,phrase,_,source=helper.fixture()
 local writer={status='idle'}
 function writer:state()return self.status,self.token end
 local sink_calls,accept,captured=0,false,nil
 local ctx=context.new{writer=writer,capture=function()error('runtime must own editor capture')end,
  sink=function(request,done)
   sink_calls=sink_calls+1
   if not accept then return false,'rejected by spec' end
   captured={request=request,done=done}
   return true
  end}
 local results={}
 ctx:attach_document(song);ctx:open_dialog(function(result)results[#results+1]=result end)
 ctx:bind_phrase(instrument,phrase)
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true})
 local before=song.tool_data
 assert(cache.get(song,instrument,phrase)==nil,'fixture retained a draft')
 assert(not ctx:request_generation('manual'),'rejected admission was accepted')
 assert(sink_calls==1 and song.tool_data==before,
   'rejected clean admission wrote durable draft data')
 assert(cache.get(song,instrument,phrase)==nil,'rejected clean admission retained a draft')
 accept=true
 assert(ctx:request_generation('manual'))
 assert(captured.request.draft_capture==nil,
   'clean committed source acquired a synthetic draft')
 writer.status,writer.token='busy',captured.request.token
 assert(captured.done({kind='success',status='committed',verified=true,
   token=captured.request.token,epoch=captured.request.epoch,phrase=phrase,
   baseline=captured.request.baseline}))
 writer.status,writer.token='idle',nil
 assert(#results==1 and results[1].kind=='success')
 assert(ctx:target_state().kind=='owned')
 assert(cache.get(song,instrument,phrase)==nil,'clean success retained a draft')
 local changed=seq.copy_source(source);changed.pitch_events[1]=seq.new_pitch(7,0,false,false)
 ctx:transition('edit',{source=changed,output_policy='play_once',pb_range=0})
 assert(store.read_draft(song,instrument,phrase)~=nil,
   'dirty source was not preserved before admission')
 accept=false
 assert(not ctx:request_generation('manual'))
 assert(store.read_draft(song,instrument,phrase)~=nil,
   'rejected dirty admission lost its recoverable draft')
end
-- New still captures its explicit scratch draft without an edit.
do
 local song,instrument,_,_,source=helper.fixture('new')
 local captured
 local ctx=context.new{writer={state=function()return 'idle',nil end},
  capture=function()error('runtime must own editor capture')end,
  sink=function(request,done)captured={request=request,done=done};return true end}
 ctx:attach_document(song);ctx:open_dialog();ctx:bind_new(instrument)
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0,restore=true})
 assert(ctx:request_generation('manual'))
 assert(captured.request.draft_capture~=nil,'New lost its scratch draft capture')
end
do
 local ctx,log,_,song,instrument,phrase,other,source=fixture()
 ctx:release_document()
 assert(not log.request:is_current() and not log.request:validate_checkpoint())
 unreachable({request=log.request,done=log.done},{song=song,instrument=instrument,
  phrase=phrase,other=other,source=source})
end
for _,fault in ipairs({'timing','groove','source'})do
 local song,instrument,phrase,_,source=helper.fixture('new')
 local sinks=0
 local ctx=context.new{writer={state=function()return 'idle',nil end},
  capture=function()error('runtime must own editor capture')end,
  sink=function()sinks=sinks+1;return true end}
 ctx:attach_document(song);ctx:open_dialog();ctx:bind_new(instrument)
 if fault=='timing'then song.transport.timing_model=2
 elseif fault=='groove'then song.transport.groove_enabled=nil
 else source.length=0 end
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0})
 assert(not ctx:request_generation('manual'),fault..' invalid capture accepted')
 assert(sinks==0 and #instrument.phrases==2)
 -- A guarded load may persist its editable draft; rejected admission itself cannot write.
 local captured=song.tool_data
 assert(not ctx:request_generation('manual'))
 assert(song.tool_data==captured)
end
do
 local song,instrument,phrase,other,source=helper.fixture()
 local ctx=helper.runtime(song)
 assert(ctx:bind_phrase(instrument,phrase).kind=='owned')
 assert(cache.put(song,instrument,phrase,seq.new_pattern(5),'play_once',0,ctx:draft_options()))
 local descriptor,guard=cache.capture(song,instrument,phrase,ctx:draft_options())
 assert(descriptor and guard(descriptor.token,descriptor.revision))
 cache.release(song)
 assert(not guard(descriptor.token,descriptor.revision))
 assert(not cache.is_current(song,descriptor))
 unreachable({descriptor=descriptor,guard=guard},{song=song,instrument=instrument,
  phrase=phrase,other=other,source=source})
 ctx:release_document()
end
do
 local ctx,log,_,_,_,phrase=fixture()
 local cell=phrase.lines[helper.limits.max_lines].note_columns[helper.limits.max_note_columns]
 cell.delay_value=1
 local valid,reason=log.request:validate_checkpoint()
 assert(not valid and type(reason)=='string','hidden content did not fail closed')
 assert(log.sinks==1,'hidden content started another sink')
 cell.delay_value=0
 assert(not log.request:validate_checkpoint(),'restoring external data resurrected failed operation')
 assert(not log.request:is_current(),'failed checkpoint did not revoke cheap authorization')
 assert(not log.request.token:is_current(),'failed checkpoint retained writer token authorization')
end
print('ACID frozen runtime request and checkpoint guards passed')
