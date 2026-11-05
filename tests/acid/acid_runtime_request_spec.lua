local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local context=require('runtime.context')
local seq=require('model.sequencer')
local cache=require('runtime.draft_cache')
local unreachable=dofile('tests/assert_unreachable.lua')

local function inspect_request(new,inspect)
 local song,instrument,phrase,other,source=helper.fixture(new and 'new')
 local checked,check_error,request
 local ctx
 ctx=context.new{writer={state=function()return 'idle',nil end,
  is_temporary=function()return false end},sink=function(captured,done)
   request=captured
   checked,check_error=pcall(inspect,captured,song,instrument,phrase,source,ctx)
   done({kind='failure',status='failed',token=captured.token,epoch=captured.epoch,
    reason='Request inspection complete'})
   return true
  end}
 ctx:attach_document(song);ctx:open_dialog()
 ctx:transition('target',{instrument=instrument,phrase=not new and phrase or nil,
  kind=new and 'new' or 'existing'})
 ctx:transition('programmatic',{source=source,output_policy='play_once',pb_range=0})
 assert(ctx:request_generation('manual'))
 assert(checked,check_error)
 ctx:release_document()
 assert(not request:is_current() and not request:validate_authorization_checkpoint())
 unreachable({request=request},{song=song,instrument=instrument,phrase=phrase,
  other=other,source=source})
end

for _,new in ipairs({false,true})do
 inspect_request(new,function(request,song,instrument,phrase,source)
  assert(request.kind==(new and 'create' or 'regenerate'))
  assert(rawequal(request.instrument,instrument))
  assert(request:is_current() and request:validate_authorization_checkpoint())
  assert(request.draft_capture and cache.is_current(song,request.draft_capture))
  if new then
   assert(request.phrase==nil and request.baseline==nil)
  else
   assert(rawequal(request.phrase,phrase) and request.id==101)
   assert(request.baseline.snapshot==nil,'request exposed a mutable full phrase snapshot')
  end
  source.pitch_events[1].accent=true
  assert(not request.source.pitch_events[1].accent,'captured source retained editor input')
 end)
end

-- Public request fields cannot replace the captured authority during dispatch.
for _,tamper in ipairs({'source','capabilities','baseline','prepared_source','prepared_record','prepared_provenance'})do
 inspect_request(tamper~='baseline',function(request)
  if tamper=='source' then request.source.length=9
  elseif tamper=='capabilities' then request.capabilities.sample=not request.capabilities.sample
  elseif tamper=='baseline' then request.baseline.snapshot={}
  elseif tamper=='prepared_source' then request.prepared_resolution.source.length=9
  elseif tamper=='prepared_record' then request.prepared_resolution.resolved_records[1].note=999
  else request.prepared_resolution.provenance={} end
  assert(not request:validate_authorization_checkpoint(),tamper..' escaped authorization validation')
 end)
end

-- Reentrant mutation is rejected; action failures unwind and revoke authority.
inspect_request(false,function(request,_,_,_,_,ctx)
 local ran=false
 assert(not pcall(function()ctx:mutate({},function()ran=true end)end) and not ran)
 local sentinel={reason='nested failure'}
 local ok,failure=pcall(function()request:mutate(request.token,function()
  assert(not pcall(function()request:mutate(request.token,function()ran=true end)end) and not ran)
  error(sentinel)
 end)end)
 assert(not ok and rawequal(failure,sentinel) and ctx:mutation_state().depth==0)
 assert(not request.token:is_current())
 assert(not pcall(function()request:mutate(request.token,function()ran=true end)end) and not ran)
end)

inspect_request(false,function(request,_,_,_,_,ctx)
 pcall(function()request:mutate(request.token,function()ctx:release_document()end)end)
 assert(ctx:mutation_state().depth==0,'release during mutation corrupted nesting depth')
 assert(not request.token:is_current())
end)
-- Request capture validates source; native output planning belongs to the writer.
do
 local planner=require('model.output_planner')
 local original=planner.plan
 planner.plan=function()error('request capture performed duplicate output planning')end
 local ok,failure=pcall(inspect_request,true,function(request)assert(seq.validate(request.source))end)
 planner.plan=original
 assert(ok,failure)
end

do
 local song,instrument,phrase,other,source=helper.fixture()
 local ctx=helper.runtime(song)
 assert(ctx:transition('target',{instrument=instrument,phrase=phrase,kind='existing'}).kind=='owned')
 assert(cache.put(song,instrument,phrase,seq.new_pattern(5),'play_once',0,ctx:draft_options()))
 local descriptor,guard=cache.capture(song,instrument,phrase,ctx:draft_options())
 assert(descriptor and guard(descriptor.token,descriptor.revision))
 cache.release(song)
 assert(not guard(descriptor.token,descriptor.revision) and not cache.is_current(song,descriptor))
 unreachable({descriptor=descriptor,guard=guard},{song=song,instrument=instrument,
  phrase=phrase,other=other,source=source})
 ctx:release_document()
end
print('ACID frozen runtime request and checkpoint guards passed')
