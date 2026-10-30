dofile('tests/bootstrap.lua')('acid')
local context=require('runtime.context')
local ownership=require('renoise.phrase_ownership')
local validator=require('writers.phrase_validator')
local phrase_fixture=dofile('tests/acid/complete_phrase_fixture.lua')
local function fixture()
 local source=phrase_fixture();source.name=assert(ownership.make_name(source,1))
 local instrument={name='Sampler',phrases={source}}
 local song={instruments={instrument},selected_instrument=instrument,selected_phrase=source}
 local temporaries={}
 local writer={status='idle'}
 function writer:state()return self.status,self.token end
 function writer.is_temporary(_,_,phrase)return temporaries[phrase]==true end
 local log={captures=0,sinks=0,cancels=0}
 local ctx=context.new{writer=writer,capture=function(_,token)
  log.captures=log.captures+1;log.token=token;return {token=token}
 end,sink=function(_,done)log.sinks=log.sinks+1;log.done=done;return true end,
 cancel=function()log.cancels=log.cancels+1;return true end}
 ctx:attach_document(song);ctx:open_dialog();assert(ctx:bind_new(instrument).kind=='new')
 assert(ctx:request_generation('manual'))
 return ctx,log,song,instrument,source,temporaries
end

-- Copy/name/list callbacks remain synchronous dirtiness; only neutral outer exit reconciles.
do
 local ctx,log,song,instrument,source,temporaries=fixture()
 local classified=0
 local classify=validator.classify
 validator.classify=function(...)classified=classified+1;return classify(...)end
 local first,second,third=ctx:mutate(log.token,function()
  local backup={name=source.name}
  instrument.phrases[2]=backup;temporaries[backup]=true
  ctx:mark_dirty('phrase inserted')
  assert(ctx:mutation_state().depth==1)
  assert(ctx:target_state().kind=='unavailable')
  assert(not ctx:phrase_choices(instrument))
  assert(not ctx:draft_options().validate(song,instrument,source))
  local reconciled=ctx:reconcile()
  assert(not reconciled or reconciled.kind=='unavailable')
  assert(classified==0,'classification ran during unfinished copy')
  ctx:mutate(log.token,function()
   assert(ctx:mutation_state().depth==2)
   local ran=false
   pcall(function()ctx:mutate({},function()ran=true end)end)
   assert(not ran,'foreign nested token executed')
   backup.name='ACID backup';ctx:mark_dirty('neutral name')
  end)
  assert(ctx:mutation_state().depth==1)
  song.selected_phrase=backup
  return 'value',nil,3
 end)
 validator.classify=classify
 assert(first=='value' and second==nil and third==3,'scope lost return values')
 local state=ctx:mutation_state()
 assert(state.depth==0 and state.pending and state.dirty and not state.failed)
 state.depth=20;state.failed=true
 assert(ctx:mutation_state().depth==0 and not ctx:mutation_state().failed)
 assert(log.token:is_current(),'internal notifications revoked the request')
 assert(ctx:reconcile().kind=='new','internal native temporary must not replace explicit New')
 assert(not ctx:mutation_state().pending)
 ctx:reconcile()
 assert(log.captures==1 and log.sinks==1)
 ctx:mark_dirty('delayed native callback')
 assert(not log.token:is_current(),'out-of-scope notification was treated as internal')
 assert(log.captures==1 and log.sinks==1)
end

-- Unneutralized temporary ownership cannot leave a successful mutation scope.
do
 local ctx,log,song,instrument,source,temporaries=fixture()
 local ok=pcall(function()ctx:mutate(log.token,function()
  local backup={name=source.name};instrument.phrases[2]=backup;temporaries[backup]=true
  ctx:mark_dirty('copy')
 end)end)
 assert(not ok and ctx:mutation_state().failed)
 assert(ctx:mutation_state().depth==0 and not log.token:is_current())
 assert(ctx:target_state().kind=='unavailable')
 assert(not ctx:draft_options().validate(song,instrument,source))
 assert(log.captures==1 and log.sinks==1)
 local reconciled=ctx:reconcile()
 assert(not reconciled or reconciled.kind=='unavailable','failed scope reconciled unfinished copy')
end

-- Nested errors unwind depth and revoke; stale/foreign tokens never execute an action.
do
 local ctx,log=fixture()
 local ran=false
 local ok=pcall(function()ctx:mutate({},function()ran=true end)end)
 assert(not ran)
 local sentinel={reason='nested failure'}
 local result,failure=pcall(function()ctx:mutate(log.token,function()
  ctx:mutate(log.token,function()error(sentinel)end)
 end)end)
 assert(not result and rawequal(failure,sentinel) and ctx:mutation_state().depth==0)
 assert(not log.token:is_current())
 pcall(function()ctx:mutate(log.token,function()ran=true end)end)
 assert(not ran)
 assert(log.captures==1 and log.sinks==1)
end
do
 local ctx,log=fixture()
 pcall(function()ctx:mutate(log.token,function()ctx:release_document()end)end)
 assert(ctx:mutation_state().depth==0,'release during scope corrupted nesting depth')
 assert(not log.token:is_current())
end
print('ACID synchronous runtime mutation and reconciliation passed')
